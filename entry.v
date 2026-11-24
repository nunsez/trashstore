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
	pending_empty
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

// label returns the stable name for an entry state.
pub fn (s EntryState) label() string {
	return match s {
		.pending { 'pending' }
		.trashed { 'trashed' }
		.restoring { 'restoring' }
		.pending_empty { 'pending_empty' }
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
