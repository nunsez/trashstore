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

// empty_batch renames entries into .gc under one shared lock and reports
// per-item failures without losing successful results. Call gc() afterwards.
pub fn (s Store) empty_batch(entries []Entry) !EmptyBatch {
	mut fl := s.lock_shared()!
	defer {
		fl.release()
	}
	mut batch := EmptyBatch{}
	for entry in entries {
		s.empty_one_locked(entry) or {
			batch.failures << batch_failure(entry.id, 'empty', err)
			continue
		}
		batch.emptied++
	}
	s.sync_dir(s.items_dir())!
	s.sync_dir(s.gc_dir())!
	s.sync_dir(s.inflight_dir())!
	return batch
}

fn (s Store) empty_one_locked(entry Entry) ! {
	if os.is_link(s.gc_dir()) {
		return invalid_target_error('garbage directory must not be a symlink')
	}
	marker := s.create_marker_opts('empty', entry.id, false) or {
		return in_progress_error('item `${entry.id}` is already being restored or emptied')
	}
	mut done := false
	mut renamed := false
	defer {
		if !done && !renamed {
			s.remove_marker_opts(marker, false)
		}
	}
	dest := os.join_path(s.gc_dir(), '${entry.id}-${s.next_id()}')
	fsx.rename_noreplace(s.item_dir(entry.id), dest)!
	renamed = true
	failpoint('empty:after-rename')!
	s.remove_marker_opts(marker, false)
	done = true
}

// empty atomically detaches the whole items tree and recreates an empty one.
// By default .gc is cleaned later; use empty_wait(true) to wait for deletion.
pub fn (s Store) empty() !int {
	return s.empty_wait(false)
}

// empty_wait detaches items and optionally waits for .gc cleanup.
pub fn (s Store) empty_wait(wait bool) !int {
	for dir in [s.items_dir(), s.inflight_dir(), s.gc_dir()] {
		if os.is_link(dir) {
			return invalid_target_error('store directory `${dir}` must not be a symlink')
		}
	}
	mut fl := s.lock_exclusive()!
	defer {
		fl.release()
	}
	_ := s.recover_locked()!
	ids := os.ls(s.items_dir()) or { []string{} }
	suffix := rand.uuid_v7()
	items_gc := os.join_path(s.gc_dir(), 'empty-${suffix}-items')
	inflight_gc := os.join_path(s.gc_dir(), 'empty-${suffix}-inflight')
	fsx.rename_noreplace(s.items_dir(), items_gc)!
	fsx.rename_noreplace(s.inflight_dir(), inflight_gc)!
	s.sync_dir(s.gc_dir())!
	failpoint('empty:after-detach')!
	for dir in [s.items_dir(), s.inflight_dir()] {
		os.mkdir(dir, mode: 0o700) or {
			if !os.is_dir(dir) {
				return err
			}
		}
	}
	s.sync_dir(s.root)!
	fl.release()
	if wait {
		s.gc()!
	}
	return ids.len
}
