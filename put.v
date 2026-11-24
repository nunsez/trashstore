module trash

import internal.fsx
import os

@[params]
pub struct PutOptions {
pub:
	recursive bool
}

pub struct PutBatch {
pub mut:
	entries  []Entry
	failures []BatchFailure
}

// detect_kind classifies a path without following a final symlink.
pub fn detect_kind(path string) EntryKind {
	if os.is_link(path) {
		return .symlink
	}
	if os.is_dir(path) {
		return .dir
	}
	if os.is_file(path) {
		return .file
	}
	return .other
}

fn (s Store) create_item_dir() !(string, string) {
	return s.create_item_dir_opts(true)
}

fn (s Store) create_item_dir_opts(sync bool) !(string, string) {
	if os.is_link(s.items_dir()) {
		return invalid_target_error('items directory must not be a symlink')
	}
	for _ in 0 .. 100 {
		id := s.next_id()
		dir := s.item_dir(id)
		os.mkdir(dir, mode: 0o700) or {
			if os.exists(dir) {
				continue
			}
			return err
		}
		if sync {
			s.sync_dir(s.items_dir())!
		}
		return id, dir
	}
	return io_error('could not allocate a unique item id')
}

// plan_put validates a target and returns the entry that put() would create.
// It is used by put_many() and by --preview / -i/--interactive before asking
// for confirmation.
pub fn (s Store) plan_put(path string, opts PutOptions) !Entry {
	target := canonical_target_path(path)
	if !os.exists(target) && !os.is_link(target) {
		return not_found_error('file or directory does not exist: `${path}`')
	}
	kind := detect_kind(target)
	if kind == .dir && !opts.recursive {
		return invalid_target_error('refusing to trash directory `${path}` without --recursive\nhint: use `trash -r ${path}`')
	}
	check_trash_target(target, s.root, canonical_path(os.getwd()))!

	// The size is measured lazily from the payload once it is in the trash.
	return Entry{
		original_path: target
		kind:          kind
		state:         .pending
	}
}

fn new_put_entry(s Store, planned Entry, id string) Entry {
	return Entry{
		id:            id
		original_path: planned.original_path
		trashed_at:    s.clock()
		kind:          planned.kind
		size:          planned.size
		size_known:    planned.kind in [.symlink, .other]
		state:         .pending
	}
}

// put moves a file, directory or symlink into the trash.
pub fn (s Store) put(path string, opts PutOptions) !Entry {
	mut fl := s.lock_shared()!
	defer {
		fl.release()
	}
	return s.put_locked(path, opts)
}

// put_many moves several paths under one shared lock and reports per-item
// failures. It prepares and fsyncs all item directories before moving any
// payload, then marks the moved items trashed in one transaction.
pub fn (s Store) put_many(paths []string, opts PutOptions) !PutBatch {
	mut fl := s.lock_shared()!
	defer {
		fl.release()
	}
	mut batch := PutBatch{}
	mut prepared := []PreparedPut{}
	mut new_items := []IndexItem{}
	for path in paths {
		planned := s.plan_put(path, opts) or {
			batch.failures << batch_failure(path, 'put', err)
			continue
		}
		id, item := s.create_item_dir_opts(false) or {
			batch.failures << batch_failure(path, 'put', err)
			continue
		}
		entry := new_put_entry(s, planned, id)
		new_items << entry.to_index_item()
		prepared << PreparedPut{
			entry: entry
			item:  item
		}
	}
	s.insert_items_batch(new_items) or {
		// Nothing was moved yet; remove the empty item directories so a failed
		// bulk insert does not leave orphans behind.
		for p in prepared {
			os.rmdir_all(p.item) or {}
		}
		return err
	}
	// Make the new item directories durable before any source path is moved.
	s.sync_dir(s.items_dir())!

	mut final_dirs := []string{}
	mut moved := []Entry{}
	for p in prepared {
		mut entry := p.entry
		data := s.data_path(entry.id)
		move_put_payload(entry.original_path, p.item) or {
			if os.exists(data) || os.is_link(data) {
				// Keep the pending row so recovery can finalize it.
				final_dirs << p.item
				final_dirs << os.dir(entry.original_path)
				batch.failures << batch_failure(entry.original_path, 'put', err)
				continue
			}
			s.delete_item(entry.id) or {}
			os.rmdir_all(p.item) or {}
			batch.failures << batch_failure(entry.original_path, 'put', err)
			continue
		}
		failpoint('put:after-move') or {
			final_dirs << p.item
			final_dirs << os.dir(entry.original_path)
			batch.failures << batch_failure(entry.original_path, 'put', err)
			continue
		}
		entry.state = .trashed
		moved << entry
	}
	if moved.len > 0 {
		mut moved_ids := []string{cap: moved.len}
		for entry in moved {
			moved_ids << entry.id
		}
		s.set_items_state(moved_ids, .trashed)!
	}
	final_dirs << s.items_dir()
	for dir in unique_dirs(final_dirs) {
		s.sync_dir(dir)!
	}
	batch.entries << moved
	return batch
}

// move_put_payload moves a validated target into its item directory. The
// source parent and the item directory are opened component by component with
// O_NOFOLLOW and the final rename is done with renameat, so a component
// swapped for a symlink after validation cannot redirect the move.
fn move_put_payload(src_path string, item_dir string) ! {
	src := fsx.open_dir(os.dir(src_path))!
	defer {
		src.close()
	}
	dst := fsx.open_dir(item_dir)!
	defer {
		dst.close()
	}
	name := os.file_name(src_path)
	fsx.renameat_noreplace(src.fd, name, dst.fd, 'data') or {
		if err.code() != 18 {
			return err
		}
		// EXDEV: copy into the item directory, then place it with renameat.
		tmp_name := '.put-tmp'
		tmp := os.join_path(item_dir, tmp_name)
		fsx.remove_any(tmp) or {}
		defer {
			fsx.remove_any(tmp) or {}
		}
		fsx.copy_path_sync(src_path, tmp)!
		fsx.renameat_noreplace(dst.fd, tmp_name, dst.fd, 'data')!
		fsx.remove_any(src_path)!
	}
	src.sync(os.dir(src_path))!
	dst.sync(item_dir)!
}

struct PreparedPut {
	entry Entry
	item  string
}

fn (s Store) put_locked(path string, opts PutOptions) !Entry {
	planned := s.plan_put(path, opts)!
	id, item := s.create_item_dir()!
	mut entry := new_put_entry(s, planned, id)
	s.insert_item(entry.to_index_item()) or {
		os.rmdir_all(item) or {}
		return err
	}

	data := s.data_path(id)
	move_put_payload(planned.original_path, item) or {
		if os.exists(data) || os.is_link(data) {
			// The payload reached the item directory; keep the pending row so
			// recovery can finalize it on the next run.
			return err
		}
		s.delete_item(id) or {}
		os.rmdir_all(item) or {}
		return err
	}

	failpoint('put:after-move')!
	entry.state = .trashed
	s.set_item_state(id, .trashed) or {
		// The payload is already in the trash; the pending row lets recovery
		// finalize the item instead of hiding it forever.
		return err
	}
	return entry
}
