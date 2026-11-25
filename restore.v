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
		return batch_failure_error(batch.failures[0])
	}
	return batch.results
}

// PendingRestore is a validated restore whose journal row was written before
// any payload was moved. The move itself may still fail per item; the caller
// rolls those rows back.
struct PendingRestore {
	entry Entry
mut:
	item   IndexItem
	parent string
	base   string
}

// restore_batch restores entries under one shared lock and reports per-item
// failures without losing successful results.
//
// Items are processed in chunks: each chunk is validated, journaled as
// `restoring` in one transaction, moved, synced and deleted from the index in
// one transaction. A crash between the phases leaves a recoverable row per
// item, while the happy path pays a handful of commits instead of several per
// item.
pub fn (s Store) restore_batch(entries []Entry) !RestoreBatch {
	mut fl := s.lock_shared()!
	defer {
		fl.release()
	}
	mut batch := RestoreBatch{}
	for start := 0; start < entries.len; start += batch_chunk_size {
		end := if start + batch_chunk_size > entries.len {
			entries.len
		} else {
			start + batch_chunk_size
		}
		s.restore_chunk_locked(entries[start..end], mut batch) or {
			return classify_error(err, 'restore', 'batch')
		}
	}
	s.sync_dir(s.items_dir()) or { return classify_error(err, 'restore', s.items_dir()) }
	return batch
}

fn (s Store) restore_chunk_locked(entries []Entry, mut batch RestoreBatch) ! {
	mut pending := []PendingRestore{}
	for entry in entries {
		p := s.plan_restore_locked(entry) or {
			batch.failures << batch_failure(entry.id, 'restore', err)
			continue
		}
		pending << p
	}
	if pending.len == 0 {
		return
	}
	mut journal := []IndexItem{cap: pending.len}
	for p in pending {
		journal << p.item
	}
	s.journal_restores(journal)!
	mut restored_ids := []string{}
	mut rollback_ids := []string{}
	mut restored_parents := []string{}
	for mut p in pending {
		result := s.execute_restore_locked(mut p) or {
			batch.failures << batch_failure(p.entry.id, 'restore', err)
			// Leave the committed `restoring` row alone when the payload already
			// reached the target (a cross-device copy can leave the source in
			// place); recovery finishes it without creating a duplicate. Otherwise
			// roll the row back to trashed.
			target := percent_decode_path(p.item.restore_to) or { '' }
			if target != '' && restore_target_matches(p.item, target) {
				continue
			}
			data := s.data_path(p.entry.id)
			if os.exists(data) || os.is_link(data) {
				rollback_ids << p.entry.id
			}
			continue
		}
		batch.results << result
		restored_ids << p.entry.id
		restored_parents << p.parent
	}
	// Persist the restored payloads before their index rows disappear: syncing
	// each distinct target directory once replaces two fsyncs per item.
	for parent in unique_dirs(restored_parents) {
		s.sync_dir(parent)!
	}
	s.clear_restore_states(rollback_ids)!
	if restored_ids.len > 0 {
		s.delete_items(restored_ids)!
	}
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

fn (s Store) move_restore_data_cross(entry_id string, src fsx.Dir, dst fsx.Dir, parent string, dst_name string, mut item IndexItem) ! {
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
	src.copy_child_tree('data', s.data_path(entry_id), dst, tmp_name, tmp)!
	copied = true
	st := os.lstat(tmp)!
	item.target_dev = st.dev
	item.target_ino = st.inode
	s.update_item(item)!
	fsx.renameat_noreplace(dst.fd, tmp_name, dst.fd, dst_name)!
	failpoint('restore:after-target-rename')!
	src.remove_child_any('data', s.data_path(entry_id))!
}

// plan_restore_locked validates one restore and computes the journal row that
// the batch commits before any payload is moved.
fn (s Store) plan_restore_locked(entry Entry) !PendingRestore {
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
	target := os.join_path(parent, base)
	item.state = .restoring
	item.restore_to = percent_encode_path(target)
	item.data_dev = st.dev
	item.data_ino = st.inode
	item.target_dev = 0
	item.target_ino = 0
	return PendingRestore{
		entry:  entry
		item:   item
		parent: parent
		base:   base
	}
}

// execute_restore_locked moves the payload of an already journaled restore.
// Both directories are opened by component with O_NOFOLLOW and every move is
// relative to these descriptors, so a parent swapped for a symlink after the
// validation in plan_restore_locked cannot redirect the payload.
fn (s Store) execute_restore_locked(mut p PendingRestore) !RestoreResult {
	mut item := p.item
	defer {
		// The caller inspects the journaled row after a failure, so keep it in
		// sync with retries and the cross-device target inode.
		p.item = item
	}
	src := fsx.open_dir(s.item_dir(p.entry.id))!
	defer {
		src.close()
	}
	dst := fsx.open_or_create_dir(p.parent) or {
		return invalid_target_error('refusing to restore `${item.original_path}`: parent directory `${p.parent}` cannot be opened safely: ${err.msg()}')
	}
	defer {
		dst.close()
	}
	mut target := ''
	mut moved := false
	for attempt in 0 .. 100 {
		candidate := if attempt == 0 { p.base } else { '${p.base}~${attempt}' }
		target = os.join_path(p.parent, candidate)
		if attempt > 0 {
			// The batch journal recorded the first candidate; a retry must record
			// the name it is about to use so recovery finishes on the same path.
			item.restore_to = percent_encode_path(target)
			if !s.update_item(item)! {
				return not_restorable_error('item `${p.entry.id}` disappeared while restoring')
			}
		}
		fsx.renameat_noreplace(src.fd, 'data', dst.fd, candidate) or {
			if err.code() == 18 {
				// EXDEV: the payload lives on another filesystem.
				s.move_restore_data_cross(p.entry.id, src, dst, p.parent, candidate, mut item) or {
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
	// The target directory is synced once per batch by restore_batch. The item
	// directory is about to be removed and its parent is synced at the end, so
	// syncing it here would only add a per-item fsync.
	s.remove_item_dir(p.entry.id)!
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
