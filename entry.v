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

// Entry is the public view of one item stored in the trash.
pub struct Entry {
pub mut:
	id            string
	original_path string
	trashed_at    time.Time
	kind          EntryKind
	size          u64
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
	return Entry{
		id:            m.id
		original_path: original_path
		trashed_at:    trashed_at
		kind:          kind_from_label(m.kind)!
		size:          m.size
		state:         state_from_label(m.state)!
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
		restore_to:    percent_encode_path(restore_to)
	}
}
