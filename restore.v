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
	mut restored_ids := []string{}
	for entry in entries {
		result := s.restore_one_locked(entry) or {
			batch.failures << batch_failure(entry.id, 'restore', err)
			continue
		}
		batch.results << result
		restored_ids << entry.id
	}
	if restored_ids.len > 0 {
		s.delete_items(restored_ids)!
	}
	s.sync_dir(s.items_dir())!
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

fn (s Store) move_restore_data_cross(entry_id string, dst fsx.Dir, parent string, dst_name string, mut item IndexItem) ! {
	// Cross-device copy: the temporary copy must live on the target filesystem,
	// next to the final name, so the last step is an atomic renameat. The
	// inode is journaled before the rename so recovery can recognize an already
	// completed target.
	tmp_name := '${dst_name}.trash-tmp-${entry_id}'
	marker_name := '${tmp_name}.owner'
	tmp := os.join_path(parent, tmp_name)
	marker := os.join_path(parent, marker_name)
	// Record that the temporary copy belongs to this item before creating it.
	// Recovery only removes a temp path whose marker matches, so a crafted
	// restore_to cannot make it delete an unrelated file.
	dst.write_child_new(marker_name, entry_id)!
	mut copied := false
	defer {
		if copied {
			dst.remove_child_any(tmp_name, tmp) or {}
		}
		dst.remove_child_any(marker_name, marker) or {}
	}
	fsx.copy_path_sync(s.data_path(entry_id), tmp)!
	copied = true
	st := os.lstat(tmp)!
	item.target_dev = st.dev
	item.target_ino = st.inode
	s.update_item(item)!
	fsx.renameat_noreplace(dst.fd, tmp_name, dst.fd, dst_name)!
	failpoint('restore:after-target-rename')!
	fsx.remove_any(s.data_path(entry_id))!
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
	parent := os.dir(safe_original)
	base := os.file_name(safe_original)
	data := s.data_path(entry.id)
	st := os.lstat(data)!
	// Both directories are opened by component with O_NOFOLLOW and every move
	// below is relative to these descriptors, so a parent swapped for a
	// symlink after the check above cannot redirect the payload.
	src := fsx.open_dir(s.item_dir(entry.id))!
	defer {
		src.close()
	}
	dst := fsx.open_or_create_dir(parent) or {
		return invalid_target_error('refusing to restore `${item.original_path}`: parent directory `${parent}` cannot be opened safely: ${err.msg()}')
	}
	defer {
		dst.close()
	}
	mut target := ''
	mut moved := false
	for attempt in 0 .. 100 {
		candidate := if attempt == 0 { base } else { '${base}~${attempt}' }
		target = os.join_path(parent, candidate)
		item.state = .restoring
		item.restore_to = percent_encode_path(target)
		item.data_dev = st.dev
		item.data_ino = st.inode
		item.target_dev = 0
		item.target_ino = 0
		if !s.update_item(item)! {
			return not_restorable_error('item `${entry.id}` disappeared while restoring')
		}
		fsx.renameat_noreplace(src.fd, 'data', dst.fd, candidate) or {
			if err.code() == 18 {
				// EXDEV: the payload lives on another filesystem.
				s.move_restore_data_cross(entry.id, dst, parent, candidate, mut item) or {
					if err.code() == 17 {
						continue
					}
					return err
				}
				moved = true
				break
			}
			if err.code() == 17 {
				// EEXIST: the name was taken after we chose it; try the next suffix.
				continue
			}
			if os.exists(target) || os.is_link(target) {
				if restore_target_matches(item, target) {
					// The move reached the target but a later step failed. The
					// pending row lets recovery finish without a duplicate.
					return err
				}
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
	src.sync(s.item_dir(entry.id))!
	dst.sync(parent)!
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
