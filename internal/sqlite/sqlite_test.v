module sqlite

import os

fn smoke_db_path() string {
	return os.join_path(os.temp_dir(), 'trash_sqlite_smoke_${os.getpid()}.db')
}

fn cleanup(path string) {
	os.rm(path) or {}
	os.rm('${path}-wal') or {}
	os.rm('${path}-shm') or {}
	os.rm('${path}-journal') or {}
}

fn test_open_crud_and_types() {
	path := smoke_db_path()
	cleanup(path)
	defer {
		cleanup(path)
	}
	mut db := open(path)!
	defer {
		db.close()
	}
	assert db.version() == '3.53.4'
	db.exec('PRAGMA journal_mode=WAL')!
	db.exec('PRAGMA synchronous=FULL')!
	db.exec('CREATE TABLE t (id TEXT PRIMARY KEY, n INTEGER, s TEXT)')!

	mut ins := db.prepare('INSERT INTO t (id, n, s) VALUES (?, ?, ?)')!
	defer {
		ins.finalize()
	}
	ins.bind_text(1, 'a')!
	ins.bind_int(2, 42)!
	ins.bind_text(3, 'hello')!
	assert !ins.step()!
	assert db.changes() == 1

	ins.reset()
	ins.clear_bindings()
	ins.bind_text(1, 'b')!
	ins.bind_null(2)!
	ins.bind_text(3, '')!
	assert !ins.step()!

	mut sel := db.prepare('SELECT id, n, s FROM t ORDER BY id')!
	defer {
		sel.finalize()
	}
	assert sel.column_count() == 3
	assert sel.step()!
	assert sel.column_text(0) == 'a'
	assert sel.column_int(1) == 42
	assert sel.column_text(2) == 'hello'
	assert sel.step()!
	assert sel.column_text(0) == 'b'
	assert sel.column_is_null(1)
	assert sel.column_text(2) == ''
	assert !sel.step()!
}

fn test_transaction_rolls_back() {
	path := smoke_db_path()
	cleanup(path)
	defer {
		cleanup(path)
	}
	mut db := open(path)!
	defer {
		db.close()
	}
	db.exec('CREATE TABLE t (id INTEGER PRIMARY KEY)')!
	db.begin()!
	db.exec('INSERT INTO t DEFAULT VALUES')!
	db.rollback()
	mut sel := db.prepare('SELECT COUNT(*) FROM t')!
	defer {
		sel.finalize()
	}
	assert sel.step()!
	assert sel.column_int(0) == 0
}

fn test_errors_are_reported() {
	path := smoke_db_path()
	cleanup(path)
	defer {
		cleanup(path)
	}
	mut db := open(path)!
	defer {
		db.close()
	}
	mut failed := false
	db.exec('NOT SQL') or {
		failed = true
		assert err.msg().contains('sqlite error')
	}
	assert failed
	mut st := db.prepare('SELECT ?')!
	defer {
		st.finalize()
	}
	mut bind_failed := false
	st.bind_text(99, 'x') or { bind_failed = true }
	assert bind_failed
}
