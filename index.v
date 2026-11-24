module trash

import internal.sqlite
import time

// IndexItem is one row of the items table: the durable source of truth for a
// trashed item. Entry is the public, read-only projection of it.
struct IndexItem {
mut:
	id            string
	original_path string
	trashed_at    time.Time
	kind          EntryKind
	size          u64
	size_known    bool
	state         EntryState
	restore_to    string
	data_dev      i64
	data_ino      u64
	target_dev    i64
	target_ino    u64
}

const item_columns = 'id, original_path, trashed_at, kind, size, size_known, state, restore_to, data_dev, data_ino, target_dev, target_ino'

fn (e Entry) to_index_item() IndexItem {
	return IndexItem{
		id:            e.id
		original_path: e.original_path
		trashed_at:    e.trashed_at
		kind:          e.kind
		size:          e.size
		size_known:    e.size_known
		state:         e.state
	}
}

fn (item IndexItem) to_entry() Entry {
	return Entry{
		id:            item.id
		original_path: item.original_path
		trashed_at:    item.trashed_at
		kind:          item.kind
		size:          item.size
		size_known:    item.size_known
		state:         item.state
	}
}

fn index_u64(value i64) u64 {
	return if value < 0 { u64(0) } else { u64(value) }
}

fn index_kind(value i64) EntryKind {
	return match value {
		0 { .file }
		1 { .dir }
		2 { .symlink }
		else { .other }
	}
}

fn index_state(value i64) EntryState {
	return match value {
		0 { .pending }
		1 { .trashed }
		2 { .restoring }
		else { .pending_empty }
	}
}

fn index_item_from_stmt(st &sqlite.Stmt) !IndexItem {
	original_path := percent_decode_path(st.column_text(1)) or {
		return io_error('invalid original_path in index: ${err.msg()}')
	}
	restore_to := percent_decode_path(st.column_text(7)) or { '' }
	return IndexItem{
		id:            st.column_text(0)
		original_path: original_path
		trashed_at:    time.unix_nano(st.column_int(2))
		kind:          index_kind(st.column_int(3))
		size:          index_u64(st.column_int(4))
		size_known:    st.column_int(5) != 0
		state:         index_state(st.column_int(6))
		restore_to:    restore_to
		data_dev:      st.column_int(8)
		data_ino:      index_u64(st.column_int(9))
		target_dev:    st.column_int(10)
		target_ino:    index_u64(st.column_int(11))
	}
}

fn bind_item_values(mut st sqlite.Stmt, item IndexItem, first int) ! {
	st.bind_text(first, percent_encode_path(item.original_path))!
	st.bind_int(first + 1, item.trashed_at.unix_nano())!
	st.bind_int(first + 2, i64(int(item.kind)))!
	st.bind_int(first + 3, i64(item.size))!
	st.bind_int(first + 4, if item.size_known { i64(1) } else { i64(0) })!
	st.bind_int(first + 5, i64(int(item.state)))!
	st.bind_text(first + 6, percent_encode_path(item.restore_to))!
	st.bind_int(first + 7, item.data_dev)!
	st.bind_int(first + 8, i64(item.data_ino))!
	st.bind_int(first + 9, item.target_dev)!
	st.bind_int(first + 10, i64(item.target_ino))!
}

// insert_item adds a row. The caller commits the surrounding transaction.
fn (s Store) insert_item(item IndexItem) ! {
	mut db := s.db
	mut st := db.prepare('INSERT INTO items (${item_columns}) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)')!
	defer {
		st.finalize()
	}
	st.bind_text(1, item.id)!
	bind_item_values(mut st, item, 2)!
	st.step()!
}

// update_item rewrites every mutable column of an existing row.
fn (s Store) update_item(item IndexItem) !bool {
	mut db := s.db
	mut st := db.prepare('UPDATE items SET original_path = ?, trashed_at = ?, kind = ?, size = ?, size_known = ?, state = ?, restore_to = ?, data_dev = ?, data_ino = ?, target_dev = ?, target_ino = ? WHERE id = ?')!
	defer {
		st.finalize()
	}
	bind_item_values(mut st, item, 1)!
	st.bind_text(12, item.id)!
	st.step()!
	return db.changes() > 0
}

fn (s Store) set_item_state(id string, state EntryState) !bool {
	mut db := s.db
	mut st := db.prepare('UPDATE items SET state = ? WHERE id = ?')!
	defer {
		st.finalize()
	}
	st.bind_int(1, i64(int(state)))!
	st.bind_text(2, id)!
	st.step()!
	return db.changes() > 0
}

fn (s Store) set_item_size(id string, size u64) !bool {
	mut db := s.db
	mut st := db.prepare('UPDATE items SET size = ?, size_known = 1 WHERE id = ? AND size_known = 0')!
	defer {
		st.finalize()
	}
	st.bind_int(1, i64(size))!
	st.bind_text(2, id)!
	st.step()!
	return db.changes() > 0
}

fn (s Store) delete_item(id string) !bool {
	failpoint('index:delete-item')!
	mut db := s.db
	mut st := db.prepare('DELETE FROM items WHERE id = ?')!
	defer {
		st.finalize()
	}
	st.bind_text(1, id)!
	st.step()!
	return db.changes() > 0
}

// with_transaction runs f inside BEGIN IMMEDIATE and commits only when f
// succeeds. Any error rolls the transaction back, so a failed batch never
// leaves the connection holding an open write transaction.
fn (s Store) with_transaction(f fn () !) ! {
	mut db := s.db
	db.begin()!
	mut committed := false
	defer {
		if !committed {
			db.rollback()
		}
	}
	f()!
	db.commit()!
	committed = true
}

// insert_items_batch inserts many rows with one prepared statement and one
// commit, which matters for bulk put_many.
fn (s Store) insert_items_batch(items []IndexItem) ! {
	if items.len == 0 {
		return
	}
	s.with_transaction(fn [s, items] () ! {
		mut st := s.db.prepare('INSERT INTO items (${item_columns}) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)')!
		defer {
			st.finalize()
		}
		for item in items {
			st.reset()
			st.clear_bindings()
			st.bind_text(1, item.id)!
			bind_item_values(mut st, item, 2)!
			st.step()!
		}
	})!
}

// set_items_state updates many rows in one transaction.
fn (s Store) set_items_state(ids []string, state EntryState) ! {
	if ids.len == 0 {
		return
	}
	s.with_transaction(fn [s, ids, state] () ! {
		mut st := s.db.prepare('UPDATE items SET state = ? WHERE id = ?')!
		defer {
			st.finalize()
		}
		for id in ids {
			st.reset()
			st.clear_bindings()
			st.bind_int(1, i64(int(state)))!
			st.bind_text(2, id)!
			st.step()!
		}
	})!
}

// delete_items removes many rows in one transaction. Callers that already
// committed a pending state use it to avoid one fsync per item.
fn (s Store) delete_items(ids []string) ! {
	if ids.len == 0 {
		return
	}
	s.with_transaction(fn [s, ids] () ! {
		mut st := s.db.prepare('DELETE FROM items WHERE id = ?')!
		defer {
			st.finalize()
		}
		for id in ids {
			st.reset()
			st.clear_bindings()
			st.bind_text(1, id)!
			st.step()!
		}
	})!
}

fn (s Store) delete_all_items() ! {
	s.db.exec('DELETE FROM items')!
}

// get_item returns one row; a missing id is not_found. An unsafe id is
// rejected before it reaches SQL or any path-building code.
fn (s Store) get_item(id string) !IndexItem {
	if !is_safe_id(id) {
		return invalid_target_error('invalid item id `${id}`')
	}
	mut db := s.db
	mut st := db.prepare('SELECT ${item_columns} FROM items WHERE id = ?')!
	defer {
		st.finalize()
	}
	st.bind_text(1, id)!
	if !st.step()! {
		return not_found_error('item `${id}` is not in the index')
	}
	return index_item_from_stmt(st)!
}

// entry returns the public view of one indexed item.
pub fn (s Store) entry(id string) !Entry {
	return s.get_item(id)!.to_entry()
}

fn (s Store) all_items() ![]IndexItem {
	mut db := s.db
	mut st := db.prepare('SELECT ${item_columns} FROM items')!
	defer {
		st.finalize()
	}
	mut items := []IndexItem{}
	for {
		if !st.step()! {
			break
		}
		items << index_item_from_stmt(st)!
	}
	return items
}

fn (s Store) trashed_items() ![]IndexItem {
	mut db := s.db
	mut st := db.prepare('SELECT ${item_columns} FROM items WHERE state = ? ORDER BY id DESC')!
	defer {
		st.finalize()
	}
	st.bind_int(1, i64(int(EntryState.trashed)))!
	mut items := []IndexItem{}
	for {
		if !st.step()! {
			break
		}
		items << index_item_from_stmt(st)!
	}
	return items
}

fn (s Store) pending_items() ![]IndexItem {
	mut db := s.db
	mut st := db.prepare('SELECT ${item_columns} FROM items WHERE state != ? ORDER BY id')!
	defer {
		st.finalize()
	}
	st.bind_int(1, i64(int(EntryState.trashed)))!
	mut items := []IndexItem{}
	for {
		if !st.step()! {
			break
		}
		items << index_item_from_stmt(st)!
	}
	return items
}

fn (s Store) item_count() !i64 {
	mut db := s.db
	rows := db.query('SELECT COUNT(*) FROM items')!
	if rows.len == 0 {
		return 0
	}
	return rows[0].vals[0].i64()
}
