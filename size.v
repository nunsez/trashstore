module trash

import internal.fsx
import os

// measure_path returns the apparent size of a payload: the size of a regular
// file, or the sum of the sizes of the regular files inside a directory tree.
// Symlinks are never followed and special files contribute nothing. The second
// result reports whether the walk completed; a partial walk is reported as
// unknown so a half-measured tree is never stored as an exact size.
//
// measure_path works on a plain path. Store operations use measure_entry, which
// opens the item directory descriptor-relative and cannot be redirected by a
// symlinked item directory.
pub fn measure_path(path string, kind EntryKind) (u64, bool) {
	if kind == .file {
		st := os.lstat(path) or { return 0, false }
		return st.size, true
	}
	if kind == .dir {
		return measure_dir(path)
	}
	return 0, true
}

// measure_entry measures an item's payload without following a symlinked item
// directory. The item directory is opened one component at a time with
// O_NOFOLLOW, and the payload is measured relative to that descriptor, so a
// store entry that was swapped for a symlink reports an unknown size instead of
// reading files outside the store.
fn (s Store) measure_entry(entry Entry) (u64, bool) {
	if !is_safe_id(entry.id) || entry.kind !in [.file, .dir] {
		return 0, false
	}
	mut dir := fsx.open_dir(s.item_dir(entry.id)) or { return 0, false }
	defer {
		dir.close()
	}
	size := dir.measure_child('data', s.data_path(entry.id)) or { return 0, false }
	return size, true
}

fn measure_dir(path string) (u64, bool) {
	if os.is_link(path) {
		return 0, false
	}
	mut dir := fsx.open_dir(path) or { return 0, false }
	defer {
		dir.close()
	}
	size := dir.measure_tree(path) or { return 0, false }
	return size, true
}

// fill_size measures an item whose size is still unknown and persists the
// result in the index. It is best-effort: an item that disappeared, is being
// restored or cannot be read keeps its unknown size instead of failing.
pub fn (s Store) fill_size(entry Entry) Entry {
	if entry.size_known {
		return entry
	}
	size, ok := s.measure_entry(entry)
	if !ok {
		return entry
	}
	stored := s.set_item_size(entry.id, size) or { false }
	if !stored {
		return entry
	}
	mut updated := entry
	updated.size = size
	updated.size_known = true
	return updated
}

struct MeasuredSize {
mut:
	index  int
	id     string
	size   u64
	stored bool
}

// store_measured_sizes writes every measured size in one transaction and
// records per row whether the update applied, so a concurrent writer that
// already filled the size is not reported as ours.
fn (s Store) store_measured_sizes(mut measured []MeasuredSize) ! {
	mut db := s.conn()!
	db.begin()!
	mut committed := false
	defer {
		if !committed {
			db.rollback()
		}
	}
	mut st := db.prepare('UPDATE items SET size = ?, size_known = 1 WHERE id = ? AND size_known = 0')!
	defer {
		st.finalize()
	}
	for i in 0 .. measured.len {
		st.reset()
		st.clear_bindings()
		st.bind_int(1, i64(measured[i].size))!
		st.bind_text(2, measured[i].id)!
		st.step()!
		measured[i].stored = db.changes() > 0
	}
	db.commit()!
	committed = true
}

// fill_sizes fills the size of every entry that is still unknown. Every
// payload is measured first, then all results are persisted with a single
// commit, which removes one fsync per item from `list --sort size`.
pub fn (s Store) fill_sizes(entries []Entry) []Entry {
	mut result := entries.clone()
	mut measured := []MeasuredSize{}
	for i, entry in entries {
		if entry.size_known {
			continue
		}
		size, ok := s.measure_entry(entry)
		if !ok {
			continue
		}
		measured << MeasuredSize{
			index: i
			id:    entry.id
			size:  size
		}
	}
	if measured.len == 0 {
		return result
	}
	s.store_measured_sizes(mut measured) or {
		// Best-effort: keep the entries unknown when the write fails.
		return result
	}
	for m in measured {
		if m.stored {
			result[m.index].size = m.size
			result[m.index].size_known = true
		}
	}
	return result
}
