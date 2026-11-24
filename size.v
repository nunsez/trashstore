module trash

import os

// measure_path returns the apparent size of a payload: the size of a regular
// file, or the sum of the sizes of the regular files inside a directory tree.
// Symlinks are never followed and special files contribute nothing. The second
// result reports whether the walk completed; a partial walk is reported as
// unknown so a half-measured tree is never stored as an exact size.
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

fn measure_dir(path string) (u64, bool) {
	st := os.lstat(path) or { return 0, false }
	if st.get_filetype() != .directory {
		return 0, false
	}
	names := os.ls(path) or { return 0, false }
	mut total := u64(0)
	for name in names {
		child := os.join_path(path, name)
		child_st := os.lstat(child) or { return 0, false }
		match child_st.get_filetype() {
			.directory {
				size, ok := measure_dir(child)
				if !ok {
					return 0, false
				}
				total += size
			}
			.regular { total += child_st.size }
			else {}
		}
	}
	return total, true
}

// fill_size measures an item whose size is still unknown and persists the
// result in its metadata. It is best-effort: an item that disappeared, is being
// restored or cannot be read keeps its unknown size instead of failing.
pub fn (s Store) fill_size(entry Entry) Entry {
	if entry.size_known || entry.kind !in [.file, .dir] {
		return entry
	}
	size, ok := measure_path(s.data_path(entry.id), entry.kind)
	if !ok {
		return entry
	}
	return s.store_size(entry.id, size) or { entry }
}

// fill_sizes fills the size of every entry that is still unknown.
pub fn (s Store) fill_sizes(entries []Entry) []Entry {
	mut result := []Entry{cap: entries.len}
	for entry in entries {
		result << s.fill_size(entry)
	}
	return result
}

// store_size writes a measured size while holding the item marker, so a
// concurrent restore or empty cannot interleave with the metadata update.
fn (s Store) store_size(id string, size u64) ?Entry {
	marker := s.create_marker_opts('size', id, false) or { return none }
	defer {
		s.remove_marker_opts(marker, false)
	}
	mut meta := s.read_meta(id) or { return none }
	if meta.state != 'trashed' {
		return none
	}
	entry := meta.to_entry() or { return none }
	if entry.size_known {
		// Another process measured the item first.
		return entry
	}
	meta.size = size
	meta.size_known = true
	s.write_meta(id, meta) or { return none }
	mut updated := entry
	updated.size = size
	updated.size_known = true
	return updated
}
