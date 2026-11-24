module trash

import internal.fsx
import os
import rand

pub struct EmptyBatch {
pub mut:
	emptied  int
	failures []BatchFailure
}

// empty_entries permanently deletes already resolved entries and then cleans .gc.
pub fn (s Store) empty_entries(entries []Entry) !int {
	batch := s.empty_batch(entries)!
	if batch.failures.len > 0 {
		return error(batch.failures[0].message)
	}
	if batch.emptied > 0 {
		s.gc()!
	}
	return batch.emptied
}

// empty_batch moves entries into .gc under one shared lock and reports
// per-item failures without losing successful results. Call gc() afterwards.
pub fn (s Store) empty_batch(entries []Entry) !EmptyBatch {
	mut fl := s.lock_shared()!
	defer {
		fl.release()
	}
	mut batch := EmptyBatch{}
	mut emptied_ids := []string{}
	for entry in entries {
		s.empty_one_locked(entry) or {
			batch.failures << batch_failure(entry.id, 'empty', err)
			continue
		}
		batch.emptied++
		emptied_ids << entry.id
	}
	if emptied_ids.len > 0 {
		s.delete_items(emptied_ids)!
	}
	s.sync_dir(s.items_dir())!
	s.sync_dir(s.gc_dir())!
	return batch
}

fn (s Store) empty_one_locked(entry Entry) ! {
	if !is_safe_id(entry.id) {
		return invalid_target_error('invalid item id `${entry.id}`')
	}
	if os.is_link(s.gc_dir()) {
		return invalid_target_error('garbage directory must not be a symlink')
	}
	if os.is_link(s.item_dir(entry.id)) {
		return invalid_target_error('item directory `${s.item_dir(entry.id)}` must not be a symlink')
	}
	s.get_item(entry.id)!
	s.set_item_state(entry.id, .pending_empty)!
	dest := os.join_path(s.gc_dir(), '${entry.id}-${s.next_id()}')
	fsx.rename_noreplace(s.item_dir(entry.id), dest) or {
		s.set_item_state(entry.id, .trashed) or {}
		return err
	}
	failpoint('empty:after-rename')!
}

// empty atomically detaches the whole items tree and recreates an empty one.
// By default .gc is cleaned later; use empty_wait(true) to wait for deletion.
pub fn (s Store) empty() !int {
	return s.empty_wait(false)
}

// empty_wait detaches items and optionally waits for .gc cleanup.
pub fn (s Store) empty_wait(wait bool) !int {
	for dir in [s.items_dir(), s.gc_dir()] {
		if os.is_link(dir) {
			return invalid_target_error('store directory `${dir}` must not be a symlink')
		}
	}
	mut fl := s.lock_exclusive()!
	defer {
		fl.release()
	}
	s.recover_locked()!
	count := s.item_count()!
	s.db.exec('UPDATE items SET state = ${int(EntryState.pending_empty)}')!
	suffix := rand.uuid_v7()
	items_gc := os.join_path(s.gc_dir(), 'empty-${suffix}-items')
	fsx.rename_noreplace(s.items_dir(), items_gc)!
	if os.is_dir(s.inflight_dir()) && !os.is_link(s.inflight_dir()) {
		inflight_gc := os.join_path(s.gc_dir(), 'empty-${suffix}-inflight')
		fsx.rename_noreplace(s.inflight_dir(), inflight_gc)!
	}
	s.sync_dir(s.gc_dir())!
	failpoint('empty:after-detach')!
	for dir in [s.items_dir()] {
		os.mkdir(dir, mode: int(s.mode)) or {
			if !os.is_dir(dir) {
				return err
			}
		}
	}
	s.sync_dir(s.root)!
	s.delete_all_items()!
	fl.release()
	if wait {
		s.gc()!
	}
	return int(count)
}
