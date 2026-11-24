module trash

import os
import time

fn index_test_store(name string) (string, &Store) {
	root := canonical_path(os.join_path(os.temp_dir(), 'v_trash_index_${os.getpid()}_${name}'))
	os.rmdir_all(root) or {}
	os.mkdir_all(root) or { panic(err) }
	store := open(os.join_path(root, 'trash')) or { panic(err) }
	return root, store
}

fn test_index_insert_get_update_delete() {
	root, store := index_test_store('crud')
	defer {
		os.rmdir_all(root) or {}
	}
	stamp := time.unix_nano(1_700_000_000_123_456_789)
	item := IndexItem{
		id:            'id-1'
		original_path: '/tmp/a b/файл'
		trashed_at:    stamp
		kind:          .file
		size:          1234
		size_known:    true
		state:         .pending
		restore_to:    '/tmp/restore target'
		data_dev:      7
		data_ino:      42
	}
	store.insert_item(item)!
	got := store.get_item('id-1')!
	assert got.id == item.id
	assert got.original_path == item.original_path
	assert got.trashed_at.unix_nano() == stamp.unix_nano()
	assert got.kind == .file
	assert got.size == 1234
	assert got.size_known
	assert got.state == .pending
	assert got.restore_to == item.restore_to
	assert got.data_dev == 7
	assert got.data_ino == 42

	mut updated := got
	updated.state = .trashed
	updated.size = 999
	updated.size_known = false
	updated.restore_to = ''
	assert store.update_item(updated)!
	got2 := store.get_item('id-1')!
	assert got2.state == .trashed
	assert got2.size == 999
	assert !got2.size_known
	assert got2.restore_to == ''

	assert store.set_item_state('id-1', .restoring)!
	restoring := store.get_item('id-1')!
	assert restoring.state == .restoring
	assert store.set_item_size('id-1', 5)!
	measured := store.get_item('id-1')!
	assert measured.size == 5
	assert measured.size_known
	// A second measurement must not overwrite the first one.
	assert !store.set_item_size('id-1', 6)!

	assert store.delete_item('id-1')!
	assert !store.delete_item('id-1')!
	mut failed := false
	store.get_item('id-1') or { failed = true }
	assert failed
}

fn test_index_lists_by_state() {
	root, store := index_test_store('lists')
	defer {
		os.rmdir_all(root) or {}
	}
	stamp := time.unix_nano(1_700_000_000_000_000_000)
	items := [
		IndexItem{
			id:            'a'
			original_path: '/tmp/a'
			trashed_at:    stamp
			kind:          .file
			state:         .pending
		},
		IndexItem{
			id:            'b'
			original_path: '/tmp/b'
			trashed_at:    stamp
			kind:          .dir
			state:         .trashed
		},
		IndexItem{
			id:            'c'
			original_path: '/tmp/c'
			trashed_at:    stamp
			kind:          .symlink
			state:         .pending_empty
		},
	]
	for item in items {
		store.insert_item(item)!
	}
	all := store.all_items()!
	assert all.len == 3
	trashed := store.trashed_items()!
	assert trashed.len == 1
	assert trashed[0].id == 'b'
	pending := store.pending_items()!
	assert pending.len == 2
	assert store.item_count()! == 3
	store.delete_all_items()!
	count := store.item_count()!
	assert count == 0
}

fn test_index_transaction_rollback() {
	root, store := index_test_store('tx')
	defer {
		os.rmdir_all(root) or {}
	}
	mut db := store.conn()!
	db.begin()!
	store.insert_item(IndexItem{
		id:            'tx'
		original_path: '/tmp/tx'
		trashed_at:    time.unix_nano(1_700_000_000_000_000_000)
		kind:          .file
		state:         .trashed
	})!
	db.rollback()
	count := store.item_count()!
	assert count == 0
}

fn test_index_batch_rolls_back_on_error() {
	root, store := index_test_store('batch-rollback')
	defer {
		os.rmdir_all(root) or {}
	}
	item := IndexItem{
		id:            'dup'
		original_path: '/tmp/dup'
		trashed_at:    time.unix_nano(1_700_000_000_000_000_000)
		kind:          .file
		state:         .trashed
	}
	mut failed := false
	store.insert_items_batch([item, item]) or {
		failed = true
		assert err.msg().contains('UNIQUE')
	}
	assert failed
	// Nothing from the aborted batch is visible.
	count := store.item_count()!
	assert count == 0
	// The failed batch must have rolled back, not left an open transaction:
	// a fresh BEGIN IMMEDIATE would otherwise fail with
	// "cannot start a transaction within a transaction".
	mut db := store.conn()!
	db.begin()!
	db.rollback()
	// The connection is usable afterwards.
	store.insert_item(item)!
	assert store.item_count()! == 1
}

fn test_index_table_is_strict() {
	root, store := index_test_store('strict')
	defer {
		os.rmdir_all(root) or {}
	}
	mut db := store.conn()!
	rows := db.query("SELECT strict FROM pragma_table_list WHERE name = 'items'")!
	assert rows.len == 1
	assert rows[0].vals[0] == '1'
	// STRICT rejects a TEXT value in an INTEGER column instead of coercing it.
	mut failed := false
	db.exec("INSERT INTO items (id, original_path, trashed_at, kind, state, restore_to) VALUES ('bad', '/bad', 'not-a-number', 0, 1, '')") or {
		failed = true
		assert err.msg().contains('cannot store TEXT')
	}
	assert failed
	count := store.item_count()!
	assert count == 0
}

// The numeric kind/state codes are the on-disk format. Pin them so that
// reordering an enum cannot silently reinterpret existing rows.
fn test_entry_kind_and_state_codes_are_stable() {
	assert EntryKind.file.code() == 0
	assert EntryKind.dir.code() == 1
	assert EntryKind.symlink.code() == 2
	assert EntryKind.other.code() == 3
	assert entry_kind_from_code(0) == .file
	assert entry_kind_from_code(1) == .dir
	assert entry_kind_from_code(2) == .symlink
	assert entry_kind_from_code(3) == .other
	assert entry_kind_from_code(99) == .other

	assert EntryState.pending.code() == 0
	assert EntryState.trashed.code() == 1
	assert EntryState.restoring.code() == 2
	assert EntryState.pending_empty.code() == 3
	assert EntryState.unknown.code() == -1
	assert entry_state_from_code(0) == .pending
	assert entry_state_from_code(1) == .trashed
	assert entry_state_from_code(2) == .restoring
	assert entry_state_from_code(3) == .pending_empty
	assert entry_state_from_code(99) == .unknown
}

fn test_index_reads_explicit_numeric_codes() {
	root, store := index_test_store('codes')
	defer {
		os.rmdir_all(root) or {}
	}
	mut db := store.conn()!
	db.exec("INSERT INTO items (id, original_path, trashed_at, kind, state, restore_to) VALUES ('raw', '/raw', 0, 2, 3, '')")!
	item := store.get_item('raw')!
	assert item.kind == .symlink
	assert item.state == .pending_empty
}
