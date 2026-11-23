module trash

import internal.fsx
import os

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
// It is used by --dry-run and by -i before asking for confirmation.
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

	st := os.lstat(target)!
	size := if kind == .file { st.size } else { u64(0) }
	return Entry{
		original_path: target
		kind:          kind
		size:          size
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

// put_many moves several paths under one shared lock and reports per-item failures.
// It prepares and fsyncs all item directories before moving any payload, then
// groups the final directory fsyncs after all payloads have been moved.
pub fn (s Store) put_many(paths []string, opts PutOptions) !PutBatch {
	mut fl := s.lock_shared()!
	defer {
		fl.release()
	}
	mut batch := PutBatch{}
	mut prepared := []PreparedPut{}
	mut prep_dirs := []string{}
	for path in paths {
		planned := s.plan_put(path, opts) or {
			batch.failures << batch_failure(path, 'put', err)
			continue
		}
		id, item := s.create_item_dir_opts(false) or {
			batch.failures << batch_failure(path, 'put', err)
			continue
		}
		marker := s.create_marker_opts('put', id, false) or {
			os.rmdir_all(item) or {}
			batch.failures << batch_failure(path, 'put', err)
			continue
		}
		entry := Entry{
			id:            id
			original_path: planned.original_path
			trashed_at:    s.clock()
			kind:          planned.kind
			size:          planned.size
			state:         .pending
		}
		meta := meta_from_entry(entry, '')
		s.write_meta_atomic_opts(item, meta, s.sync, false) or {
			s.remove_marker_opts(marker, false)
			os.rmdir_all(item) or {}
			batch.failures << batch_failure(path, 'put', err)
			continue
		}
		prepared << PreparedPut{
			entry:  entry
			item:   item
			marker: marker
		}
		prep_dirs << s.items_dir()
		prep_dirs << s.inflight_dir()
		prep_dirs << item
	}
	// Make all item directories, markers and pending metadata durable before
	// any source path is moved.
	for dir in unique_dirs(prep_dirs) {
		s.sync_dir(dir)!
	}
	mut final_dirs := []string{}
	for p in prepared {
		mut entry := p.entry
		data := s.data_path(entry.id)
		fsx.move_path_sync(entry.original_path, data, entry.id, false) or {
			if os.exists(data) || os.is_link(data) {
				// Keep the marker and the item directory so recovery can finalize it.
				final_dirs << p.item
				final_dirs << os.dir(entry.original_path)
				batch.failures << batch_failure(entry.id, 'put', err)
				continue
			}
			s.remove_marker_opts(p.marker, false)
			os.rmdir_all(p.item) or {}
			batch.failures << batch_failure(entry.id, 'put', err)
			continue
		}
		failpoint('put:after-move') or {
			final_dirs << p.item
			final_dirs << os.dir(entry.original_path)
			batch.failures << batch_failure(entry.id, 'put', err)
			continue
		}
		entry.state = .trashed
		s.write_meta_atomic_opts(p.item, meta_from_entry(entry, ''), s.sync, false) or {
			// The payload is already in the trash; keep the marker for recovery.
			final_dirs << p.item
			final_dirs << os.dir(entry.original_path)
			batch.failures << batch_failure(entry.id, 'put', err)
			continue
		}
		s.remove_marker_opts(p.marker, false)
		final_dirs << p.item
		final_dirs << os.dir(entry.original_path)
		batch.entries << entry
	}
	final_dirs << s.items_dir()
	final_dirs << s.inflight_dir()
	for dir in unique_dirs(final_dirs) {
		s.sync_dir(dir)!
	}
	return batch
}

struct PreparedPut {
	entry  Entry
	item   string
	marker string
}

fn (s Store) put_locked(path string, opts PutOptions) !Entry {
	planned := s.plan_put(path, opts)!

	id, item := s.create_item_dir()!
	marker := s.create_marker('put', id) or {
		os.rmdir_all(item) or {}
		return err
	}
	mut entry := Entry{
		id:            id
		original_path: planned.original_path
		trashed_at:    s.clock()
		kind:          planned.kind
		size:          planned.size
		state:         .pending
	}
	meta := meta_from_entry(entry, '')
	s.write_meta_atomic(item, meta) or {
		s.remove_marker(marker)
		os.rmdir_all(item) or {}
		return err
	}

	data := s.data_path(id)
	fsx.move_path_sync(planned.original_path, data, id, s.sync) or {
		// If the payload already reached the item directory, a later fsync or
		// cleanup error must not make us delete it. Keep the marker so recovery
		// can finalize the item on the next run.
		if os.exists(data) || os.is_link(data) {
			return err
		}
		s.remove_marker(marker)
		os.rmdir_all(item) or {}
		return err
	}

	failpoint('put:after-move')!
	entry.state = .trashed
	s.write_meta_atomic(item, meta_from_entry(entry, '')) or {
		// The payload is already in the trash. Keep the marker so the next
		// open() can finalize the item instead of hiding it forever.
		return err
	}
	s.remove_marker(marker)
	return entry
}
