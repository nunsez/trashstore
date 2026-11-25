module sqlite

// Minimal, allocation-light bindings to the vendored SQLite amalgamation.
//
// Only the calls the trash store needs are exposed. The bindings are built with
// SQLITE_THREADSAFE=1 and every connection is opened with FULLMUTEX, so a
// connection may be used from different threads without a data race in the C
// layer. SQLite's file locking still provides cross-process safety.
#flag -I@VMODROOT/thirdparty/sqlite
#flag -DSQLITE_THREADSAFE=1
#flag -DSQLITE_DISABLE_INTRINSIC
#flag -DSQLITE_OMIT_LOAD_EXTENSION
#flag -DSQLITE_OMIT_UTF16
#flag -DSQLITE_OMIT_DEPRECATED
#flag -DSQLITE_DQS=0
#flag -DSQLITE_DEFAULT_FOREIGN_KEYS=1
#flag -DSQLITE_TEMP_STORE=2
#flag @VMODROOT/thirdparty/sqlite/sqlite3.c

#include "sqlite3.h"

pub const sqlite_ok = 0
pub const sqlite_row = 100
pub const sqlite_done = 101
pub const sqlite_null = 5

// sqlite_transient tells SQLite to copy bound text, so the V string does not
// have to outlive the bind call.
const sqlite_transient = voidptr(-1)

const open_readonly_flag = 0x00000001
const open_readwrite = 0x00000002
const open_create = 0x00000004
const open_fullmutex = 0x00010000
// SQLITE_OPEN_NOFOLLOW refuses a database path that is a symlink. It protects
// the main file; SQLite opens WAL/SHM/journal sidecars itself, so callers must
// still reject symlinked sidecars before opening.
const open_nofollow = 0x01000000

fn C.sqlite3_open_v2(&char, &&C.sqlite3, i32, &char) i32
fn C.sqlite3_close_v2(&C.sqlite3) i32
fn C.sqlite3_errmsg(&C.sqlite3) &char
fn C.sqlite3_busy_timeout(&C.sqlite3, i32) i32
fn C.sqlite3_exec(&C.sqlite3, &char, voidptr, voidptr, &&char) i32
fn C.sqlite3_prepare_v2(&C.sqlite3, &char, i32, &&C.sqlite3_stmt, &&char) i32
fn C.sqlite3_step(&C.sqlite3_stmt) i32
fn C.sqlite3_reset(&C.sqlite3_stmt) i32
fn C.sqlite3_clear_bindings(&C.sqlite3_stmt) i32
fn C.sqlite3_finalize(&C.sqlite3_stmt) i32
fn C.sqlite3_bind_int64(&C.sqlite3_stmt, i32, i64) i32
fn C.sqlite3_bind_text(&C.sqlite3_stmt, i32, voidptr, i32, voidptr) i32
fn C.sqlite3_bind_null(&C.sqlite3_stmt, i32) i32
fn C.sqlite3_column_type(&C.sqlite3_stmt, i32) i32
fn C.sqlite3_column_int64(&C.sqlite3_stmt, i32) i64
fn C.sqlite3_column_text(&C.sqlite3_stmt, i32) &u8
fn C.sqlite3_column_name(&C.sqlite3_stmt, i32) &char
fn C.sqlite3_column_bytes(&C.sqlite3_stmt, i32) i32
fn C.sqlite3_column_count(&C.sqlite3_stmt) i32
fn C.sqlite3_changes(&C.sqlite3) i32
fn C.sqlite3_libversion() &char

// Db is one connection. It must not be copied: closing both copies would
// double-free the handle.
pub struct Db {
mut:
	conn &C.sqlite3 = unsafe { nil }
}

// open opens (and creates) a database file with a 5 second busy timeout.
pub fn open(path string) !Db {
	return open_with(path, open_readwrite | open_create | open_fullmutex)
}

// open_readonly opens an existing database without creating it.
pub fn open_readonly(path string) !Db {
	return open_with(path, open_readonly_flag | open_fullmutex)
}

// open_nofollow opens (and creates) a database file and refuses the path if it
// is a symlink. SQLite also rejects a symlinked parent component, so callers
// must canonicalise the path first; the trash store does.
pub fn open_nofollow(path string) !Db {
	return open_with(path, open_readwrite | open_create | open_fullmutex | open_nofollow)
}

fn open_with(path string, flags int) !Db {
	mut conn := &C.sqlite3(unsafe { nil })
	code := C.sqlite3_open_v2(&char(path.str), &conn, i32(flags), unsafe { nil })
	if code != sqlite_ok {
		msg := if conn != unsafe { nil } {
			unsafe { cstring_to_vstring(&char(C.sqlite3_errmsg(conn))) }
		} else {
			'cannot allocate a connection'
		}
		if conn != unsafe { nil } {
			C.sqlite3_close_v2(conn)
		}
		return error_with_code('sqlite: cannot open `${path}`: ${msg}', code)
	}
	C.sqlite3_busy_timeout(conn, 5000)
	mut db := Db{
		conn: conn
	}
	// Defensive mode rejects dangerous schema changes such as
	// PRAGMA writable_schema and writes to shadow tables.
	db.exec('PRAGMA defensive=ON') or {
		db.close()
		return error('sqlite: cannot enable defensive mode: ${err}')
	}
	return db
}

// close releases the connection. Statements must be finalized first.
pub fn (mut db Db) close() {
	if db.conn != unsafe { nil } {
		C.sqlite3_close_v2(db.conn)
		db.conn = unsafe { nil }
	}
}

// errmsg returns the last error message of the connection.
pub fn (db &Db) errmsg() string {
	if db.conn == unsafe { nil } {
		return 'connection is closed'
	}
	return unsafe { cstring_to_vstring(&char(C.sqlite3_errmsg(db.conn))) }
}

fn (db &Db) error(code int, query string) IError {
	suffix := if query == '' { '' } else { ' while running `${query}`' }
	return error_with_code('sqlite error ${code}: ${db.errmsg()}${suffix}', code)
}

// exec runs one or more statements and ignores any result rows.
pub fn (db &Db) exec(query string) ! {
	code := C.sqlite3_exec(db.conn, &char(query.str), unsafe { nil }, unsafe { nil },
		unsafe { nil })
	if code != sqlite_ok {
		return db.error(code, query)
	}
}

// changes returns the number of rows changed by the last statement.
pub fn (db &Db) changes() int {
	return C.sqlite3_changes(db.conn)
}

// version returns the SQLite library version, for diagnostics.
pub fn version() string {
	return unsafe { cstring_to_vstring(C.sqlite3_libversion()) }
}

// version returns the SQLite library version, for diagnostics.
pub fn (db &Db) version() string {
	return version()
}

// begin starts an immediate transaction (takes the write lock at once).
pub fn (db &Db) begin() ! {
	db.exec('BEGIN IMMEDIATE')!
}

// commit makes the current transaction durable.
pub fn (db &Db) commit() ! {
	db.exec('COMMIT')!
}

// rollback aborts the current transaction; it is a no-op outside one.
pub fn (db &Db) rollback() {
	db.exec('ROLLBACK') or {}
}

// Stmt is a prepared statement. finalize() must be called exactly once; use
// `defer { stmt.finalize() }` at the call site.
pub struct Stmt {
	db &Db = unsafe { nil }
mut:
	stmt &C.sqlite3_stmt = unsafe { nil }
}

// prepare compiles a statement. The caller must finalize it.
pub fn (db &Db) prepare(query string) !Stmt {
	mut stmt := &C.sqlite3_stmt(unsafe { nil })
	code := C.sqlite3_prepare_v2(db.conn, &char(query.str), i32(query.len), &stmt,
		unsafe { nil })
	if code != sqlite_ok {
		return db.error(code, query)
	}
	return Stmt{
		db:   db
		stmt: stmt
	}
}

fn (s &Stmt) check(code int, what string) ! {
	if code != sqlite_ok {
		return s.db.error(code, what)
	}
}

// bind_int binds a 64-bit integer to a 1-based parameter index.
pub fn (mut s Stmt) bind_int(idx int, v i64) ! {
	s.check(C.sqlite3_bind_int64(s.stmt, i32(idx), v), 'bind_int')!
}

// bind_text binds a text value; SQLite copies it (SQLITE_TRANSIENT).
pub fn (mut s Stmt) bind_text(idx int, v string) ! {
	s.check(C.sqlite3_bind_text(s.stmt, i32(idx), voidptr(v.str), i32(v.len),
		sqlite_transient), 'bind_text')!
}

// bind_null binds NULL to a 1-based parameter index.
pub fn (mut s Stmt) bind_null(idx int) ! {
	s.check(C.sqlite3_bind_null(s.stmt, i32(idx)), 'bind_null')!
}

// step advances the statement. It returns true when a row is available and
// false when the statement has finished.
pub fn (mut s Stmt) step() !bool {
	code := C.sqlite3_step(s.stmt)
	if code == sqlite_row {
		return true
	}
	if code == sqlite_done {
		return false
	}
	return s.db.error(code, '')
}

// reset makes the statement ready for another run with the same bindings.
pub fn (mut s Stmt) reset() {
	C.sqlite3_reset(s.stmt)
}

// clear_bindings drops all bound values so the statement can be reused.
pub fn (mut s Stmt) clear_bindings() {
	C.sqlite3_clear_bindings(s.stmt)
}

// finalize releases the compiled statement. Safe to call twice.
pub fn (mut s Stmt) finalize() {
	if s.stmt != unsafe { nil } {
		C.sqlite3_finalize(s.stmt)
		s.stmt = unsafe { nil }
	}
}

// column_is_null reports whether a 0-based result column is NULL.
pub fn (s &Stmt) column_is_null(idx int) bool {
	return C.sqlite3_column_type(s.stmt, i32(idx)) == sqlite_null
}

// column_int reads a 0-based result column as a 64-bit integer.
pub fn (s &Stmt) column_int(idx int) i64 {
	return C.sqlite3_column_int64(s.stmt, i32(idx))
}

// column_text reads a 0-based result column as text; NULL becomes `''`.
pub fn (s &Stmt) column_text(idx int) string {
	if s.column_is_null(idx) {
		return ''
	}
	p := C.sqlite3_column_text(s.stmt, i32(idx))
	if p == unsafe { nil } {
		return ''
	}
	n := C.sqlite3_column_bytes(s.stmt, i32(idx))
	// The pointer is owned by SQLite and is invalidated by the next step(), so
	// copy the bytes into a V-owned string.
	return unsafe { (&char(p)).vstring_with_len(n) }.clone()
}

// column_count returns the number of result columns.
pub fn (s &Stmt) column_count() int {
	return C.sqlite3_column_count(s.stmt)
}

// Row is one result row: column names and text values (NULL becomes `''`).
pub struct Row {
pub:
	names []string
	vals  []string
}

// query runs the first statement in `text` and returns every row as text.
// Strings are copied out of SQLite's memory, so they stay valid after the next
// step().
pub fn (mut db Db) query(text string) ![]Row {
	mut st := db.prepare(text)!
	defer {
		st.finalize()
	}
	cols := st.column_count()
	mut names := []string{cap: cols}
	for i in 0 .. cols {
		name := C.sqlite3_column_name(st.stmt, i32(i))
		names << if name != unsafe { nil } {
			unsafe { cstring_to_vstring(name) }
		} else {
			''
		}
	}
	mut rows := []Row{}
	for {
		if !st.step()! {
			break
		}
		mut vals := []string{cap: cols}
		for i in 0 .. cols {
			vals << st.column_text(i)
		}
		rows << Row{
			names: names
			vals:  vals
		}
	}
	return rows
}
