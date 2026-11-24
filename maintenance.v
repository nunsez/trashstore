module trash

import internal.fsx
import os
import time

const backup_filename = 'index.backup.db'

fn sql_quote(value string) string {
	return "'" + value.replace("'", "''") + "'"
}

// has_item reports whether the index already contains id.
fn (s Store) has_item(id string) !bool {
	s.get_item(id) or {
		if err is TrashError && err.kind == .not_found {
			return false
		}
		return err
	}
	return true
}

// rebuild_index_locked recreates rows for payloads that have no row. It is
// deliberately lossy: the original path is not stored anywhere else, so
// rebuilt items get an empty original_path and cannot be restored in place.
fn (s Store) rebuild_index_locked() !int {
	if os.is_link(s.items_dir()) {
		return invalid_target_error('items directory must not be a symlink')
	}
	mut rebuilt := 0
	for id in os.ls(s.items_dir()) or { return err } {
		if !is_safe_id(id) || os.is_link(s.item_dir(id)) || !os.is_dir(s.item_dir(id)) {
			continue
		}
		if s.has_item(id)! {
			continue
		}
		data := s.data_path(id)
		if !os.exists(data) && !os.is_link(data) {
			continue
		}
		st := os.lstat(data)!
		s.insert_item(IndexItem{
			id:            id
			original_path: ''
			trashed_at:    time.unix(st.mtime)
			kind:          detect_kind(data)
			state:         .trashed
		})!
		rebuilt++
	}
	if rebuilt > 0 {
		s.sync_dir(s.items_dir())!
	}
	return rebuilt
}

// integrity_check_locked runs SQLite's integrity check and returns "ok" or the
// concatenated problems.
fn (s Store) integrity_check_locked() !string {
	mut db := s.db
	rows := db.query('PRAGMA integrity_check')!
	mut messages := []string{}
	for row in rows {
		if row.vals.len > 0 {
			messages << row.vals[0]
		}
	}
	if messages.len == 1 && messages[0] == 'ok' {
		return 'ok'
	}
	return messages.join('; ')
}

// compact_locked rebuilds the database file and returns free pages to the OS.
fn (s Store) compact_locked() ! {
	s.db.exec('VACUUM')!
	// auto_vacuum=INCREMENTAL is set when the index is created; this releases
	// the pages that VACUUM left on the free list.
	s.db.exec('PRAGMA incremental_vacuum')!
}

fn (s Store) reindex_locked() ! {
	s.db.exec('REINDEX')!
}

// backup_locked writes a consistent snapshot of the index next to it.
fn (s Store) backup_locked() !string {
	path := os.join_path(s.root, backup_filename)
	if os.is_link(path) {
		return invalid_target_error('backup path `${path}` must not be a symlink')
	}
	tmp := '${path}.tmp'
	if os.is_link(tmp) {
		return invalid_target_error('backup path `${tmp}` must not be a symlink')
	}
	if os.exists(tmp) {
		os.rm(tmp)!
	}
	// Build the snapshot next to the old one and swap it in, so a failed
	// VACUUM does not destroy the previous backup.
	s.db.exec('VACUUM INTO ${sql_quote(tmp)}')!
	os.mv(tmp, path)!
	fsx.fsync_dir(s.root)!
	return path
}
