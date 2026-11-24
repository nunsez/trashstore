module trash

import internal.sqlite
import os

// index_filename is the SQLite index inside the trash store.
pub const index_filename = 'index.db'
// index_application_id marks index.db as ours ("TRAS"), so pointing --store at
// an unrelated SQLite database fails with a clear error.
pub const index_application_id = 0x54524153
// latest_schema_version is bumped whenever schema_v2 changes.
pub const latest_schema_version = 2

// schema_v2 is the whole schema of a fresh index. Every table is STRICT: a
// value of the wrong type is an error instead of a silent coercion. There is deliberately no
// migration runner: the app is pre-1.0, so a schema change is handled by
// bumping latest_schema_version and asking the user to start with a new store.
// Once the format is public, replace this with ordered migrations.
const schema_v2 = '
CREATE TABLE items (
	id TEXT PRIMARY KEY NOT NULL,
	original_path TEXT NOT NULL,
	trashed_at INTEGER NOT NULL,
	kind INTEGER NOT NULL CHECK (kind IN (0, 1, 2, 3)),
	size INTEGER NOT NULL DEFAULT 0,
	size_known INTEGER NOT NULL DEFAULT 0 CHECK (size_known IN (0, 1)),
	state INTEGER NOT NULL CHECK (state IN (0, 1, 2, 3)),
	restore_to TEXT NOT NULL,

	data_dev INTEGER NOT NULL DEFAULT 0,
	data_ino INTEGER NOT NULL DEFAULT 0,
	target_dev INTEGER NOT NULL DEFAULT 0,
	target_ino INTEGER NOT NULL DEFAULT 0
) STRICT;
CREATE INDEX items_trashed_at ON items(trashed_at);
CREATE INDEX items_original_path ON items(original_path);
CREATE INDEX items_state ON items(state);
'

fn (s Store) index_path() string {
	return os.join_path(s.root, index_filename)
}

fn pragma_value(mut db sqlite.Db, query string) !string {
	rows := db.query(query)!
	if rows.len == 0 || rows[0].vals.len == 0 {
		return ''
	}
	return rows[0].vals[0]
}

// index_pragma reads one value from the index; it is used by tests and doctor.
fn (s Store) index_pragma(query string) !string {
	mut db := s.db
	return pragma_value(mut db, query)
}

fn pragma_int(mut db sqlite.Db, query string) !i64 {
	value := pragma_value(mut db, query)!
	return value.i64()
}

fn index_is_fresh(mut db sqlite.Db) !bool {
	return pragma_int(mut db, "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table'")! == 0
}

// index_schema_version reads PRAGMA user_version (0 for a new index). It is a
// header read, so opening a store does not take a write lock.
fn index_schema_version(mut db sqlite.Db) !int {
	return int(pragma_int(mut db, 'PRAGMA user_version')!)
}

fn (s Store) configure_index(mut db sqlite.Db, fresh bool) ! {
	if fresh {
		// These pragmas are persistent and must be set before the first table.
		db.exec('PRAGMA page_size = 8192')!
		db.exec('PRAGMA auto_vacuum = INCREMENTAL')!
		mode := pragma_value(mut db, 'PRAGMA journal_mode = WAL')!
		if mode != 'wal' {
			// Network filesystems often refuse WAL; a rollback journal still
			// gives atomic commits, just without concurrent readers.
			db.exec('PRAGMA journal_mode = TRUNCATE')!
		}
	}
	// Never switch journal_mode on an existing index: it needs an exclusive
	// lock and a second connection could downgrade a WAL database mid-flight,
	// which loses commits. The mode chosen at creation is the mode for life.
	db.exec('PRAGMA foreign_keys = ON')!
	db.exec('PRAGMA trusted_schema = OFF')!
	db.exec('PRAGMA cache_size = -8192')!
	db.exec('PRAGMA temp_store = MEMORY')!
	db.exec('PRAGMA synchronous = FULL')!
}

fn (s Store) prepare_index(mut db sqlite.Db) ! {
	fresh := index_is_fresh(mut db)!
	s.configure_index(mut db, fresh)!
	if fresh {
		db.exec('PRAGMA application_id = ${index_application_id}')!
		return
	}
	app_id := pragma_int(mut db, 'PRAGMA application_id')!
	if app_id != index_application_id {
		return invalid_target_error('`${s.index_path()}` is a SQLite database but not a trash index (application_id ${app_id}); move it away or use another --store')
	}
}

fn (s Store) ensure_schema(mut db sqlite.Db) ! {
	version := index_schema_version(mut db)!
	if version == latest_schema_version {
		return
	}
	if version == 0 && index_is_fresh(mut db)! {
		// DDL and the version bump are one transaction: no half-created schema.
		// BEGIN IMMEDIATE takes the write lock, so a second process opening the
		// same fresh store waits and then finds the schema already created.
		db.begin()!
		locked_version := index_schema_version(mut db)!
		locked_fresh := index_is_fresh(mut db)!
		if locked_version == latest_schema_version {
			db.rollback()
			return
		}
		if locked_version != 0 || !locked_fresh {
			db.rollback()
			return schema_mismatch_error('index `${s.index_path()}` changed while opening; re-run the command', s.root)
		}
		db.exec(schema_v2) or {
			db.rollback()
			return err
		}
		db.exec('PRAGMA user_version = ${latest_schema_version}') or {
			db.rollback()
			return err
		}
		db.commit()!
		return
	}
	return schema_mismatch_error('index `${s.index_path()}` has schema version ${version}, but this build expects ${latest_schema_version}', s.root)
}

fn map_index_error(err IError, path string) IError {
	if err is TrashError {
		// Already classified (schema_mismatch, invalid_target, ...).
		return err
	}
	code := err.code() & 0xff
	if code == 11 || code == 26 {
		return invalid_target_error('`${path}` is not a usable trash index (${err.msg()}); run `trash doctor` or move the file away')
	}
	return err
}

// open_index opens index.db, applies connection pragmas and pending migrations.
fn (s Store) open_index() !sqlite.Db {
	path := s.index_path()
	if os.is_link(path) {
		return invalid_target_error('index file `${path}` must not be a symlink')
	}
	if os.exists(path) && !os.is_file(path) {
		return invalid_target_error('index path `${path}` is not a regular file')
	}
	mut db := sqlite.open(path) or { return map_index_error(err, path) }
	s.prepare_index(mut db) or {
		db.close()
		return map_index_error(err, path)
	}
	s.ensure_schema(mut db) or {
		db.close()
		return map_index_error(err, path)
	}
	return db
}

// reset_store wipes the trash after the user confirmed an incompatible index
// schema. Only entries owned by trash are removed; unrelated files in the store
// directory are left alone. The store directory itself is kept.
pub fn reset_store(root string) ! {
	resolved := canonical_path(root)
	for name in [items_dirname, inflight_dirname, gc_dirname] {
		path := os.join_path(resolved, name)
		if os.is_link(path) {
			os.rm(path)!
			continue
		}
		if os.is_dir(path) {
			os.rmdir_all(path)!
		}
	}
	for name in [index_filename, '${index_filename}-wal', '${index_filename}-shm', backup_filename,
		lock_filename] {
		path := os.join_path(resolved, name)
		if os.is_link(path) || os.exists(path) {
			os.rm(path)!
		}
	}
}

// close releases the index connection. The store must not be used afterwards.
pub fn (mut s Store) close() {
	s.db.close()
}
