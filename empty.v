module trash

import internal.fsx
import os

pub struct EmptyBatch {
pub mut:
	emptied  int
	failures []BatchFailure
}

// empty_entries permanently deletes already resolved entries and then cleans .gc.
// Garbage is collected even when some items failed, so a partial run does not
// leave successfully emptied payloads behind in .gc until the next command.
pub fn (s Store) empty_entries(entries []Entry) !int {
	batch := s.empty_batch(entries)!
	gc_err := s.gc()
	if batch.failures.len > 0 {
		return batch_failure_error(batch.failures[0])
	}
	gc_err!
	return batch.emptied
}

// empty_batch moves entries into .gc under one exclusive lock and reports
// per-item failures without losing successful results. Call gc() afterwards.
// Entries that another process already removed are skipped, so concurrent
// `empty --all` runs are idempotent.
//
// Items are processed in chunks: each chunk is journaled as `pending_empty` in
// one transaction, moved, synced, and deleted from the index in one transaction.
// A crash between the phases makes recovery finish the empty the user asked for,
// while the happy path pays a few commits per chunk instead of one per item.
pub fn (s Store) empty_batch(entries []Entry) !EmptyBatch {
	mut fl := s.lock_exclusive()!
	defer {
		fl.release()
	}
	mut batch := EmptyBatch{}
	for start := 0; start < entries.len; start += batch_chunk_size {
		end := if start + batch_chunk_size > entries.len {
			entries.len
		} else {
			start + batch_chunk_size
		}
		s.empty_chunk_locked(entries[start..end], mut batch) or {
			return classify_error(err, 'empty', 'batch')
		}
	}
	return batch
}

fn (s Store) empty_chunk_locked(entries []Entry, mut batch EmptyBatch) ! {
	mut selected := []Entry{}
	for entry in entries {
		if !is_safe_id(entry.id) {
			batch.failures << batch_failure(entry.id, 'empty', invalid_target_error('invalid item id `${entry.id}`'))
			continue
		}
		item := s.get_item(entry.id) or {
			if err is TrashError && err.kind == .not_found {
				continue
			}
			batch.failures << batch_failure(entry.id, 'empty', err)
			continue
		}
		if item.state != .trashed {
			// Recovery or another process owns this row now.
			continue
		}
		selected << entry
	}
	if selected.len == 0 {
		return
	}
	mut ids := []string{cap: selected.len}
	for entry in selected {
		ids << entry.id
	}
	s.set_items_state(ids, .pending_empty)!
	mut emptied_ids := []string{}
	mut rollback_ids := []string{}
	for entry in selected {
		s.empty_one_locked(entry) or {
			batch.failures << batch_failure(entry.id, 'empty', err)
			// A failed rename leaves the item directory in place; return the row
			// to trashed. If the rename already happened, the committed
			// `pending_empty` row is what lets recovery finish the empty.
			if os.is_dir(s.item_dir(entry.id)) || os.is_link(s.item_dir(entry.id)) {
				rollback_ids << entry.id
			}
			continue
		}
		batch.emptied++
		emptied_ids << entry.id
	}
	if rollback_ids.len > 0 {
		s.set_items_state(rollback_ids, .trashed)!
	}
	if emptied_ids.len > 0 {
		// Persist the moves before their rows disappear: a crash must not
		// resurrect a payload whose row is already gone.
		s.sync_dir(s.items_dir())!
		s.sync_dir(s.gc_dir())!
		s.delete_items(emptied_ids)!
	}
}

// empty_one_locked moves one already journaled item into .gc. The caller owns
// the pending_empty state and rolls it back if this fails. The move is relative
// to the items/ and .gc/ descriptors, exactly like recover_empty(), so a
// directory component swapped for a symlink cannot redirect the rename.
fn (s Store) empty_one_locked(entry Entry) ! {
	if !is_safe_id(entry.id) {
		return invalid_target_error('invalid item id `${entry.id}`')
	}
	if os.is_link(s.gc_dir()) {
		return invalid_target_error('garbage directory must not be a symlink')
	}
	if os.is_link(s.items_dir()) {
		return invalid_target_error('items directory must not be a symlink')
	}
	if os.is_link(s.item_dir(entry.id)) {
		return invalid_target_error('item directory `${s.item_dir(entry.id)}` must not be a symlink')
	}
	new_id := s.next_id()
	if !is_safe_id(new_id) {
		return invalid_target_error('id generator returned an unsafe id `${new_id}`')
	}
	mut items := fsx.open_dir(s.items_dir())!
	defer {
		items.close()
	}
	mut gc := fsx.open_dir(s.gc_dir())!
	defer {
		gc.close()
	}
	dest_name := '${entry.id}-${new_id}'
	fsx.renameat_noreplace(items.fd, entry.id, gc.fd, dest_name) or {
		if err.code() == fsx.enoent {
			// The payload is already gone; the item is empty, not a failure.
			return
		}
		return err
	}
	failpoint('empty:after-rename')!
}

// empty permanently deletes every trashed item and then cleans .gc.
// Orphan payloads (directories without an index row) are never deleted
// automatically; use doctor --purge or `empty --all --include-broken` for that.
pub fn (s Store) empty() !int {
	return s.empty_entries(s.scan().entries)
}
