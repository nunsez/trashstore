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
	// unknown marks a state read from the index that this build does not
	// recognise. It is never written; recovery and scan treat it as broken
	// instead of guessing a destructive action.
	unknown
}

// The numeric codes below are the on-disk format of the index. They are
// explicit so that reordering an enum can never reinterpret an existing row.
// Never reuse or change a code without a schema version bump.
pub const entry_kind_file = 0
pub const entry_kind_dir = 1
pub const entry_kind_symlink = 2
pub const entry_kind_other = 3

pub const entry_state_pending = 0
pub const entry_state_trashed = 1
pub const entry_state_restoring = 2
pub const entry_state_pending_empty = 3

// code returns the stable on-disk code of an entry kind.
pub fn (k EntryKind) code() int {
	return match k {
		.file { entry_kind_file }
		.dir { entry_kind_dir }
		.symlink { entry_kind_symlink }
		.other { entry_kind_other }
	}
}

// entry_kind_from_code decodes an on-disk kind. Unknown values fall back to
// `other`, which is non-destructive.
pub fn entry_kind_from_code(code int) EntryKind {
	if code == entry_kind_file {
		return .file
	}
	if code == entry_kind_dir {
		return .dir
	}
	if code == entry_kind_symlink {
		return .symlink
	}
	return .other
}

// code returns the stable on-disk code of an entry state. `unknown` is never
// written; it maps to a value outside the schema CHECK range on purpose.
pub fn (s EntryState) code() int {
	return match s {
		.pending { entry_state_pending }
		.trashed { entry_state_trashed }
		.restoring { entry_state_restoring }
		.pending_empty { entry_state_pending_empty }
		.unknown { -1 }
	}
}

// entry_state_from_code decodes an on-disk state. A value this build does not
// know becomes `unknown`, never a destructive default.
pub fn entry_state_from_code(code int) EntryState {
	if code == entry_state_pending {
		return .pending
	}
	if code == entry_state_trashed {
		return .trashed
	}
	if code == entry_state_restoring {
		return .restoring
	}
	if code == entry_state_pending_empty {
		return .pending_empty
	}
	return .unknown
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
		.unknown { 'unknown' }
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
