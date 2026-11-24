module trash

import internal.fsx
import os

@[params]
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
	// subject is the item id for restore/empty and the original path for put.
	subject string
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
	mut restored_ids := []string{}
	for entry in entries {
		result := s.restore_one_locked(entry) or {
			batch.failures << batch_failure(entry.id, 'restore', err)
			continue
		}
		batch.results << result
		restored_ids << entry.id
		sync_dirs << os.dir(result.restored_to)
	}
	if restored_ids.len > 0 {
		s.delete_items(restored_ids)!
	}
	sync_dirs << s.items_dir()
	for dir in unique_dirs(sync_dirs) {
		s.sync_dir(dir)!
	}
	return batch
}

fn restore_target_matches(item IndexItem, target string) bool {
	st := os.lstat(target) or { return false }
	return (item.data_ino != 0 && st.dev == item.data_dev && st.inode == item.data_ino)
		|| (item.target_ino != 0 && st.dev == item.target_dev && st.inode == item.target_ino)
}

// restore_target_path rejects an original path whose parent directory no longer
// resolves to itself (CWE-59). original_path is stored canonicalised, so a
// difference means a component was replaced with a symlink or renamed after the
// item was trashed. Legitimate symlinks (e.g. /tmp -> /private/tmp) were
// resolved at put time and therefore compare equal.
fn restore_target_path(original string) !string {
	abs := os.abs_path(original)
	parent := os.dir(abs)
	resolved := canonical_path(parent)
	if resolved != parent {
		return invalid_target_error('refusing to restore `${original}`: parent directory `${parent}` resolves to `${resolved}`; restore it manually')
	}
	return abs
}

fn (s Store) move_restore_data(entry_id string, data string, target string, mut item IndexItem) ! {
	// Same-device rename is the common case; the caller batches the directory
	// fsyncs. EXDEV (18) means the payload lives on another filesystem.
	fsx.rename_noreplace(data, target) or {
		if err.code() != 18 {
			return err
		}
		return s.move_restore_data_cross(entry_id, data, target, mut item)
	}
}

fn (s Store) move_restore_data_cross(entry_id string, data string, target string, mut item IndexItem) ! {
	// Cross-device copy: journal the temporary target inode before renaming it
	// into place, so recovery can recognize an already completed target.
	tmp := '${target}.trash-tmp-${entry_id}'
	fsx.remove_any(tmp) or {}
	defer {
		fsx.remove_any(tmp) or {}
	}
	fsx.copy_path_sync(data, tmp)!
	st := os.lstat(tmp)!
	item.target_dev = st.dev
	item.target_ino = st.inode
	s.update_item(item)!
	fsx.rename_noreplace(tmp, target)!
	s.sync_dir(os.dir(target))!
	failpoint('restore:after-target-rename')!
	fsx.remove_any(data)!
	s.sync_dir(os.dir(data))!
}

fn (s Store) restore_one_locked(entry Entry) !RestoreResult {
	if !is_safe_id(entry.id) {
		return invalid_target_error('invalid item id `${entry.id}`')
	}
	if os.is_link(s.item_dir(entry.id)) {
		return invalid_target_error('item directory `${s.item_dir(entry.id)}` must not be a symlink')
	}
	mut item := s.get_item(entry.id)!
	if item.state != .trashed {
		return not_restorable_error('item `${entry.id}` is not in a restorable state')
	}
	if item.original_path == '' {
		return invalid_target_error('item `${entry.id}` was rebuilt from its payload and has no original path; use `trash where ${entry.id}` to locate it')
	}
	safe_original := restore_target_path(item.original_path)!
	mut target := resolve_name_conflict(safe_original)
	mut moved := false
	for _ in 0 .. 100 {
		item.state = .restoring
		item.restore_to = percent_encode_path(target)
		st := os.lstat(s.data_path(entry.id))!
		item.data_dev = st.dev
		item.data_ino = st.inode
		updated := s.update_item(item)!
		if !updated {
			return not_restorable_error('item `${entry.id}` disappeared while restoring')
		}
		os.mkdir_all(os.dir(target))!
		// Narrow the race window: re-check after creating the parents.
		resolved_parent := canonical_path(os.dir(target))
		if resolved_parent != os.dir(target) {
			return invalid_target_error('refusing to restore `${item.original_path}`: parent directory `${os.dir(target)}` resolves to `${resolved_parent}`')
		}
		s.move_restore_data(entry.id, s.data_path(entry.id), target, mut item) or {
			if os.exists(target) || os.is_link(target) {
				if restore_target_matches(item, target) {
					// The move reached the target but a later step failed. The
					// pending row lets recovery finish without a duplicate.
					return err
				}
				target = resolve_name_conflict(safe_original)
				continue
			}
			return err
		}
		moved = true
		failpoint('restore:after-move')!
		break
	}
	if !moved {
		return io_error('could not find a free restore target for `${item.original_path}`')
	}
	os.rmdir_all(s.item_dir(entry.id))!
	return RestoreResult{
		entry:       item.to_entry()
		restored_to: target
	}
}

fn batch_failure(subject string, op string, err IError) BatchFailure {
	return BatchFailure{
		subject: subject
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
