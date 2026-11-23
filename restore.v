module trash

import internal.fsx
import os

pub struct RestoreOptions {
pub:
	all bool
}

pub struct RestoreResult {
pub:
	entry       Entry
	restored_to string
}

pub struct BatchFailure {
pub:
	id      string
	op      string
	message string
	kind    ErrorKind
}

pub struct RestoreBatch {
pub mut:
	results  []RestoreResult
	failures []BatchFailure
}

// restore brings one or more items back to their original paths.
// Existing paths are never overwritten: a ~N suffix is used instead.
pub fn (s Store) restore(ref string, opts RestoreOptions) ![]RestoreResult {
	matches := s.find(ref)!
	selected := if opts.all { matches } else { [matches[0]] }
	return s.restore_entries(selected)
}

// restore_entries restores already resolved entries without rescanning the store.
pub fn (s Store) restore_entries(entries []Entry) ![]RestoreResult {
	batch := s.restore_batch(entries)!
	if batch.failures.len > 0 {
		return error(batch.failures[0].message)
	}
	return batch.results
}

// restore_batch restores entries under one shared lock and reports per-item
// failures without losing successful results.
pub fn (s Store) restore_batch(entries []Entry) !RestoreBatch {
	mut fl := s.lock_shared()!
	defer {
		fl.release()
	}
	mut batch := RestoreBatch{}
	mut sync_dirs := []string{}
	for entry in entries {
		result := s.restore_one_locked(entry) or {
			batch.failures << batch_failure(entry.id, 'restore', err)
			continue
		}
		batch.results << result
		sync_dirs << os.dir(result.restored_to)
	}
	sync_dirs << s.items_dir()
	sync_dirs << s.inflight_dir()
	for dir in unique_dirs(sync_dirs) {
		s.sync_dir(dir)!
	}
	return batch
}

fn restore_target_matches(meta Meta, target string) bool {
	st := os.lstat(target) or { return false }
	return (meta.data_ino != 0 && st.dev == meta.data_dev && st.inode == meta.data_ino)
		|| (meta.target_ino != 0 && st.dev == meta.target_dev && st.inode == meta.target_ino)
}

fn (s Store) move_restore_data(entry_id string, data string, target string, mut meta Meta) ! {
	if fsx.same_device(data, target)! {
		fsx.move_path_sync(data, target, entry_id, s.sync)!
		return
	}
	// Cross-device copy: journal the temporary target inode before renaming it
	// into place, so recovery can recognize an already completed target.
	tmp := '${target}.trash-tmp-${entry_id}'
	fsx.remove_any(tmp) or {}
	defer {
		fsx.remove_any(tmp) or {}
	}
	fsx.copy_path_sync(data, tmp, s.sync)!
	st := os.lstat(tmp)!
	meta.target_dev = st.dev
	meta.target_ino = st.inode
	s.write_meta_atomic_opts(s.item_dir(entry_id), meta, s.sync, s.sync)!
	fsx.rename_noreplace(tmp, target)!
	s.sync_dir(os.dir(target))!
	failpoint('restore:after-target-rename')!
	fsx.remove_any(data)!
	s.sync_dir(os.dir(data))!
}

fn (s Store) restore_one_locked(entry Entry) !RestoreResult {
	marker := s.create_marker_opts('restore', entry.id, false) or {
		return in_progress_error('item `${entry.id}` is already being restored or purged')
	}
	mut done := false
	mut started := false
	defer {
		if !done && !started {
			s.remove_marker_opts(marker, false)
		}
	}
	mut meta := s.read_meta(entry.id)!
	if meta.state != 'trashed' {
		return not_restorable_error('item `${entry.id}` is not in a restorable state')
	}
	mut target := resolve_name_conflict(entry.original_path)
	mut moved := false
	for _ in 0 .. 100 {
		started = true
		meta.state = 'restoring'
		meta.restore_to = percent_encode_path(target)
		st := os.lstat(s.data_path(entry.id))!
		meta.data_dev = st.dev
		meta.data_ino = st.inode
		s.write_meta_atomic_opts(s.item_dir(entry.id), meta, s.sync, s.sync)!
		os.mkdir_all(os.dir(target))!
		s.move_restore_data(entry.id, s.data_path(entry.id), target, mut meta) or {
			if os.exists(target) || os.is_link(target) {
				if restore_target_matches(meta, target) {
					// The move reached the target but a later step failed. Leave
					// the marker for recovery instead of creating a duplicate.
					return err
				}
				target = resolve_name_conflict(entry.original_path)
				continue
			}
			return err
		}
		moved = true
		failpoint('restore:after-move')!
		break
	}
	if !moved {
		return io_error('could not find a free restore target for `${entry.original_path}`')
	}
	os.rmdir_all(s.item_dir(entry.id))!
	s.remove_marker_opts(marker, false)
	done = true
	return RestoreResult{
		entry:       entry
		restored_to: target
	}
}

fn batch_failure(id string, op string, err IError) BatchFailure {
	return BatchFailure{
		id:      id
		op:      op
		message: err.msg()
		kind:    error_kind(err)
	}
}

fn error_kind(err IError) ErrorKind {
	if err is TrashError {
		return err.kind
	}
	return .io
}
