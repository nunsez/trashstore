module trash

import time

pub enum EntryKind {
	file
	dir
	symlink
	other
}

pub enum EntryState {
	pending
	trashed
	restoring
}

// label returns the stable on-disk name for an entry kind.
pub fn (k EntryKind) label() string {
	return match k {
		.file { 'file' }
		.dir { 'dir' }
		.symlink { 'symlink' }
		.other { 'other' }
	}
}

// label returns the stable on-disk name for an entry state.
pub fn (s EntryState) label() string {
	return match s {
		.pending { 'pending' }
		.trashed { 'trashed' }
		.restoring { 'restoring' }
	}
}

fn kind_from_label(label string) !EntryKind {
	return match label {
		'file' { .file }
		'dir' { .dir }
		'symlink' { .symlink }
		'other' { .other }
		else { return error('unknown entry kind `${label}`') }
	}
}

fn state_from_label(label string) !EntryState {
	return match label {
		'pending' { .pending }
		'trashed' { .trashed }
		'restoring' { .restoring }
		else { return error('unknown entry state `${label}`') }
	}
}

// Entry is the public view of one item stored in the trash. size is only
// meaningful when size_known is true; unknown sizes are measured lazily and
// persisted by fill_size().
pub struct Entry {
pub mut:
	id            string
	original_path string
	trashed_at    time.Time
	kind          EntryKind
	size          u64
	size_known    bool
	state         EntryState
}

// Meta is the on-disk metadata format for one item.
pub struct Meta {
pub mut:
	id            string
	state         string
	original_path string
	trashed_at    string
	kind          string
	size          u64
	size_known    bool
	restore_to    string
	data_dev      i64
	data_ino      u64
	target_dev    i64
	target_ino    u64
}

fn (m Meta) to_entry() !Entry {
	trashed_at := time.parse_rfc3339(m.trashed_at) or {
		return error('invalid trashed_at for item `${m.id}`: ${err}')
	}
	original_path := percent_decode_path(m.original_path) or {
		return error('invalid original_path for item `${m.id}`: ${err}')
	}
	if !original_path.starts_with('/') {
		return error('invalid original_path for item `${m.id}`: path is not absolute')
	}
	kind := kind_from_label(m.kind)!
	return Entry{
		id:            m.id
		original_path: original_path
		trashed_at:    trashed_at
		kind:          kind
		size:          m.size
		size_known:    size_is_known(m)
		state:         state_from_label(m.state)!
	}
}

// size_is_known decides whether a stored size can be trusted. Metadata written
// before the size_known field existed carries exact sizes for files with a
// non-zero size and nothing useful for directories.
fn size_is_known(m Meta) bool {
	if m.size_known {
		return true
	}
	return match m.kind {
		'file' { m.size > 0 }
		'symlink', 'other' { true }
		else { false }
	}
}

fn meta_from_entry(e Entry, restore_to string) Meta {
	return Meta{
		id:            e.id
		state:         e.state.label()
		original_path: percent_encode_path(e.original_path)
		trashed_at:    e.trashed_at.format_rfc3339()
		kind:          e.kind.label()
		size:          e.size
		size_known:    e.size_known
		restore_to:    percent_encode_path(restore_to)
	}
}
