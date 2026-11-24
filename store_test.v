module trash

import internal.format
import internal.fsx
import internal.sqlite
import os
import sync
import time

fn core_dir(name string) string {
	dir := canonical_path(os.join_path(os.temp_dir(), 'v_trash_core_${os.getpid()}_${name}'))
	os.rmdir_all(dir) or {}
	os.mkdir_all(dir) or { panic(err) }
	return dir
}

fn core_cleanup(dir string) {
	os.rmdir_all(dir) or {}
}

fn core_write(path string, content string) {
	os.mkdir_all(os.dir(path)) or { panic(err) }
	os.write_file(path, content) or { panic(err) }
}

fn core_put(store Store, path string, recursive bool) Entry {
	return store.put(path, recursive: recursive) or { panic(err) }
}

fn core_insert(store Store, id string, state EntryState, original string) {
	store.insert_item(IndexItem{
		id:            id
		original_path: original
		trashed_at:    time.now()
		kind:          .file
		state:         state
	}) or { panic(err) }
}

fn core_insert_kind(store Store, id string, state EntryState, original string, kind EntryKind) {
	store.insert_item(IndexItem{
		id:            id
		original_path: original
		trashed_at:    time.now()
		kind:          kind
		state:         state
	}) or { panic(err) }
}

fn restore_env(name string, prev string) {
	if prev == '' {
		os.unsetenv(name)
	} else {
		os.setenv(name, prev, true)
	}
}

// with_failpoint runs f with the failpoint enabled and restores the previous
// environment afterwards, so tests cannot leak failpoints into each other.
fn with_failpoint(name string, f fn () !) ! {
	prev_enabled := os.getenv('TRASH_TEST_FAILPOINTS')
	prev_name := os.getenv('TRASH_FAILPOINT')
	os.setenv('TRASH_TEST_FAILPOINTS', '1', true)
	os.setenv('TRASH_FAILPOINT', name, true)
	defer {
		restore_env('TRASH_TEST_FAILPOINTS', prev_enabled)
		restore_env('TRASH_FAILPOINT', prev_name)
	}
	f()!
}

// run_parallel runs independent tasks in parallel and waits for all of them.
// Tasks must not mutate shared state; they are expected to touch the filesystem
// through their own Store instance.
fn run_parallel(tasks []fn ()) {
	mut wg := sync.new_waitgroup()
	wg.add(tasks.len)
	for task in tasks {
		spawn fn [task, mut wg] () {
			defer {
				wg.done()
			}
			task()
		}()
	}
	wg.wait()
}

// store_temp_files returns temporary files left behind by interrupted writes.
fn store_temp_files(root string) []string {
	mut dirs := [root, os.join_path(root, 'items'), os.join_path(root, '.gc')]
	for id in os.ls(os.join_path(root, 'items')) or { []string{} } {
		dirs << os.join_path(root, 'items', id)
	}
	mut found := []string{}
	for dir in dirs {
		for name in os.ls(dir) or { []string{} } {
			if name.ends_with('.tmp') || name.contains('.trash-tmp-') {
				found << os.join_path(dir, name)
			}
		}
	}
	return found
}

fn assert_no_temp_files(root string) {
	files := store_temp_files(root)
	assert files.len == 0, 'temporary files left in store: ${files}'
}

fn test_parallel_put_is_consistent() {
	root := core_dir('parallel_put')
	defer {
		core_cleanup(root)
	}
	trash := os.join_path(root, 'trash')
	open(trash) or { panic(err) }
	mut tasks := []fn (){}
	for i in 0 .. 8 {
		tasks << fn [root, trash, i] () {
			store := open(trash) or { panic(err) }
			file := os.join_path(root, 'f${i}')
			core_write(file, 'x')
			store.put(file) or { panic(err) }
		}
	}
	run_parallel(tasks)
	store := open(trash) or { panic(err) }
	assert store.list().len == 8
	assert store.count_items() == 8
	assert_no_temp_files(store.root)
}

fn test_put_restore_empty_leave_no_temp_files() {
	root := core_dir('no_temp_files')
	defer {
		core_cleanup(root)
	}
	store := open(os.join_path(root, 'trash')) or { panic(err) }
	file := os.join_path(root, 'a.txt')
	core_write(file, 'x')
	entry := core_put(store, file, false)
	assert_no_temp_files(store.root)
	store.restore(entry.id) or { panic(err) }
	assert_no_temp_files(store.root)
	entry2 := core_put(store, file, false)
	store.empty_entries([entry2]) or { panic(err) }
	assert_no_temp_files(store.root)
}

fn test_percent_path_round_trip() {
	for path in ['/home/u/a.txt', '/home/u/a b.txt', '/home/u/100%.txt', '/home/u/a\tb\nc', '/home/u/\xff'] {
		encoded := percent_encode_path(path)
		decoded := percent_decode_path(encoded) or { panic(err) }
		assert decoded == path
	}
}

fn test_percent_path_keeps_slashes() {
	assert percent_encode_path('/a b/c') == '/a%20b/c'
	assert percent_encode_path('/a%b') == '/a%25b'
}

fn test_percent_path_rejects_bad_input() {
	mut failed := false
	percent_decode_path('/a%') or { failed = true }
	assert failed
	failed = false
	percent_decode_path('/a%zz') or { failed = true }
	assert failed
}

fn test_path_within_is_component_aware() {
	assert is_path_within('/tmp/grave/a', '/tmp/grave')
	assert is_path_within('/tmp/grave', '/tmp/grave')
	assert !is_path_within('/tmp/graveyard', '/tmp/grave')
	assert !is_path_within('/tmp/graver', '/tmp/grave')
}

fn test_check_trash_target_guards() {
	mut failed := false
	check_trash_target('/', '/home/u/trash', '/home/u/project') or { failed = true }
	assert failed
	failed = false
	check_trash_target('/home/u/trash', '/home/u/trash', '/home/u/project') or { failed = true }
	assert failed
	failed = false
	check_trash_target('/home/u', '/home/u/trash', '/home/u/project') or { failed = true }
	assert failed
	failed = false
	check_trash_target('/home/u/project', '/home/u/trash', '/home/u/project') or { failed = true }
	assert failed
	failed = false
	check_trash_target('/home/u/trash/x', '/home/u/trash', '/home/u/project') or { failed = true }
	assert failed
	check_trash_target('/home/u/project/a.txt', '/home/u/trash', '/home/u/project') or { panic(err) }
}

fn test_open_creates_layout() {
	root := core_dir('open')
	defer {
		core_cleanup(root)
	}
	store := open(os.join_path(root, 'trash')) or { panic(err) }
	assert os.is_dir(store.items_dir())
	assert os.is_dir(store.gc_dir())
	assert os.exists(store.lock_path())
}

// regression: S3 — a store writable by the group allows symlink planting.
fn test_open_rejects_group_or_world_writable_store() {
	root := core_dir('perm')
	defer {
		core_cleanup(root)
	}
	trash := os.join_path(root, 'trash')
	os.mkdir_all(trash) or { panic(err) }

	for mode in [0o770, 0o777, 0o702, 0o755, 0o750, 0o705] {
		os.chmod(trash, mode) or { panic(err) }
		mut failed := false
		open(trash) or { failed = true }
		assert failed, 'mode 0${mode:o} must be rejected'
	}

	os.chmod(trash, 0o770) or { panic(err) }
	open_with(trash, allow_insecure: true) or { panic(err) }

	os.chmod(trash, 0o700) or { panic(err) }
	open(trash) or { panic(err) }
}

// regression: library mode must not bypass allow_insecure.
fn test_open_validates_store_options_mode() {
	root := core_dir('opt_mode')
	defer {
		core_cleanup(root)
	}
	trash := os.join_path(root, 'trash')
	for mode in [0o777, 0o755, 0o750, 0o1700] {
		mut failed := false
		open_with(trash, mode: mode) or { failed = true }
		assert failed, 'mode 0${mode:o} must be rejected'
		assert !os.exists(trash), 'rejected mode 0${mode:o} must not create the store'
	}
	os.mkdir_all(trash) or { panic(err) }
	os.chmod(trash, 0o700) or { panic(err) }
	insecure := open_with(trash, mode: 0o770, allow_insecure: true) or { panic(err) }
	assert (os.stat(insecure.items_dir()) or { panic(err) }).mode & 0o777 == 0o770
	assert (os.stat(insecure.gc_dir()) or { panic(err) }).mode & 0o777 == 0o770
}

// regression: index and its SQLite sidecars must be owner-only.
fn test_index_files_are_private() {
	$if !windows {
		root := core_dir('index_perm')
		defer {
			core_cleanup(root)
		}
		store := open(os.join_path(root, 'trash')) or { panic(err) }
		file := os.join_path(root, 'a.txt')
		core_write(file, 'x')
		core_put(store, file, false)
		for path in [store.index_path(), '${store.index_path()}-wal', '${store.index_path()}-shm'] {
			if os.exists(path) {
				assert (os.stat(path) or { panic(err) }).mode & 0o777 == 0o600, '${path} must be 0600'
			}
		}
		assert (os.stat(store.index_path()) or { panic(err) }).mode & 0o777 == 0o600
		report := store.doctor(backup: true) or { panic(err) }
		assert (os.stat(report.backup) or { panic(err) }).mode & 0o777 == 0o600
	}
}

// regression: S4 — an unsafe Entry.id used to rename the whole items/ tree.
fn test_batch_apis_reject_unsafe_ids() {
	root := core_dir('unsafe_ids')
	defer {
		core_cleanup(root)
	}
	store := open(os.join_path(root, 'trash')) or { panic(err) }
	file := os.join_path(root, 'a.txt')
	core_write(file, 'x')
	entry := core_put(store, file, false)
	for id in ['', '.', '..', '../x', 'x/y', 'x\\y', 'x\x00y'] {
		bad := Entry{
			id:            id
			original_path: '/tmp/x'
			trashed_at:    time.now()
			kind:          .file
			size:          0
			size_known:    false
			state:         .trashed
		}
		empty := store.empty_batch([bad]) or { panic(err) }
		assert empty.failures.len == 1, 'empty_batch must reject id `${id}`'
		assert empty.emptied == 0
		restored := store.restore_batch([bad]) or { panic(err) }
		assert restored.failures.len == 1, 'restore_batch must reject id `${id}`'
		assert restored.results.len == 0
		assert store.list().len == 1
		assert (os.ls(store.gc_dir()) or { []string{} }).len == 0
	}
	// The valid item survived and is still restorable.
	assert store.list()[0].id == entry.id
	store.restore(entry.id) or { panic(err) }
	assert (os.read_file(file) or { '' }) == 'x'
}

fn test_index_schema_and_pragmas() {
	root := core_dir('index_schema')
	defer {
		core_cleanup(root)
	}
	store := open(os.join_path(root, 'trash')) or { panic(err) }
	assert os.is_file(store.index_path())
	assert store.index_pragma('PRAGMA journal_mode')! == 'wal'
	assert store.index_pragma('PRAGMA page_size')! == '8192'
	assert store.index_pragma('PRAGMA auto_vacuum')! == '2'
	assert store.index_pragma('PRAGMA foreign_keys')! == '1'
	assert store.index_pragma('PRAGMA synchronous')! == '2'
	assert store.index_pragma('PRAGMA trusted_schema')! == '0'
	assert store.index_pragma('PRAGMA application_id')! == '${index_application_id}'
	assert store.index_pragma("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='items'")! == '1'
	assert store.index_pragma('PRAGMA user_version')! == '2'
	// Reopening is idempotent: the schema version does not change.
	store2 := open(os.join_path(root, 'trash')) or { panic(err) }
	assert store2.index_pragma('PRAGMA user_version')! == '2'
}

fn test_index_rejects_unknown_schema_version() {
	root := core_dir('index_version')
	defer {
		core_cleanup(root)
	}
	trash := os.join_path(root, 'trash')
	store := open(trash) or { panic(err) }
	mut db := store.db
	db.exec('PRAGMA user_version = 99')!
	db.close()
	mut failed := false
	open(trash) or {
		failed = true
		assert err.msg().contains('schema version 99')
		assert err is TrashError
		if err is TrashError {
			assert err.kind == .schema_mismatch
		}
	}
	assert failed
}

fn test_reset_store_removes_only_store_entries() {
	root := core_dir('reset_store')
	defer {
		core_cleanup(root)
	}
	trash_path := os.join_path(root, 'trash')
	store := open(trash_path) or { panic(err) }
	item_dir := store.item_dir('abc')
	os.mkdir_all(item_dir) or { panic(err) }
	os.write_file(os.join_path(item_dir, 'data'), 'payload') or { panic(err) }
	keep := os.join_path(trash_path, 'keep.txt')
	os.write_file(keep, 'keep') or { panic(err) }
	mut db := store.db
	db.exec('PRAGMA user_version = 99')!
	db.close()
	reset_store(trash_path)!
	assert !os.exists(store.items_dir())
	assert !os.exists(store.index_path())
	assert !os.exists(store.lock_path())
	assert os.exists(keep)
	store2 := open(trash_path) or { panic(err) }
	assert store2.index_pragma('PRAGMA user_version')! == '2'
	assert store2.index_pragma('SELECT COUNT(*) FROM items')! == '0'
}

fn test_index_rejects_foreign_database_and_garbage() {
	root := core_dir('index_foreign')
	defer {
		core_cleanup(root)
	}
	trash := os.join_path(root, 'trash')
	os.mkdir_all(trash) or { panic(err) }
	os.chmod(trash, 0o700) or { panic(err) }
	mut db := sqlite.open(os.join_path(trash, 'index.db'))!
	db.exec('CREATE TABLE t (x INTEGER)')!
	db.close()
	mut failed := false
	open(trash) or {
		failed = true
		assert err.msg().contains('not a trash index')
	}
	assert failed

	os.rm(os.join_path(trash, 'index.db')) or { panic(err) }
	os.write_file(os.join_path(trash, 'index.db'), 'definitely not sqlite') or { panic(err) }
	failed = false
	open(trash) or {
		failed = true
		assert err.msg().contains('not a usable trash index')
	}
	assert failed
}

fn test_index_rejects_symlink() {
	root := core_dir('index_symlink')
	defer {
		core_cleanup(root)
	}
	trash := os.join_path(root, 'trash')
	os.mkdir_all(trash) or { panic(err) }
	os.chmod(trash, 0o700) or { panic(err) }
	outside := os.join_path(root, 'outside.db')
	os.write_file(outside, '') or { panic(err) }
	os.symlink(outside, os.join_path(trash, 'index.db')) or { panic(err) }
	mut failed := false
	open(trash) or {
		failed = true
		assert err.msg().contains('must not be a symlink')
	}
	assert failed
}

fn test_put_file_moves_payload_and_indexes() {
	root := core_dir('put_file')
	defer {
		core_cleanup(root)
	}
	store := open(os.join_path(root, 'trash')) or { panic(err) }
	file := os.join_path(root, 'a.txt')
	core_write(file, 'hello')

	entry := core_put(store, file, false)

	assert entry.id != ''
	assert entry.kind == .file
	assert entry.state == .trashed
	// Sizes are measured lazily from the payload, so a fresh entry has none.
	assert !entry.size_known
	assert entry.size == 0
	assert !os.exists(file)
	assert (os.read_file(store.data_path(entry.id)) or { '' }) == 'hello'
	filled := store.fill_size(entry)
	assert filled.size_known
	assert filled.size == 5
	stored := store.entry(entry.id)!
	assert stored.size == 5
	assert stored.size_known
	assert stored.state == .trashed
	assert stored.original_path == file
}

fn test_put_directory_requires_recursive() {
	root := core_dir('put_dir_guard')
	defer {
		core_cleanup(root)
	}
	store := open(os.join_path(root, 'trash')) or { panic(err) }
	dir := os.join_path(root, 'dir')
	os.mkdir(dir) or { panic(err) }

	mut failed := false
	store.put(dir) or { failed = true }
	assert failed
	assert os.is_dir(dir)

	entry := core_put(store, dir, true)
	assert entry.kind == .dir
	assert !os.exists(dir)
	assert os.is_dir(store.data_path(entry.id))
}

fn test_put_symlink_to_directory_does_not_require_recursive() {
	$if !windows {
		root := core_dir('put_symlink_dir')
		defer {
			core_cleanup(root)
		}
		store := open(os.join_path(root, 'trash')) or { panic(err) }
		target := os.join_path(root, 'target')
		os.mkdir(target) or { panic(err) }
		link := os.join_path(root, 'link')
		os.symlink(target, link) or { panic(err) }

		entry := core_put(store, link, false)
		assert entry.kind == .symlink
		assert !os.exists(link)
		assert os.is_link(store.data_path(entry.id))
	}
}

fn test_put_missing_path_fails() {
	root := core_dir('put_missing')
	defer {
		core_cleanup(root)
	}
	store := open(os.join_path(root, 'trash')) or { panic(err) }
	mut failed := false
	store.put(os.join_path(root, 'missing')) or { failed = true }
	assert failed
}

fn test_put_refuses_trash_root() {
	root := core_dir('put_root')
	defer {
		core_cleanup(root)
	}
	store := open(os.join_path(root, 'trash')) or { panic(err) }
	mut failed := false
	store.put(store.root, recursive: true) or { failed = true }
	assert failed
}

fn test_put_refuses_path_inside_trash() {
	root := core_dir('put_inside')
	defer {
		core_cleanup(root)
	}
	store := open(os.join_path(root, 'trash')) or { panic(err) }
	inside := os.join_path(store.items_dir(), 'fake')
	core_write(inside, 'x')
	mut failed := false
	store.put(inside) or { failed = true }
	assert failed
}

fn test_list_direct_and_recursive() {
	root := core_dir('list')
	defer {
		core_cleanup(root)
	}
	store := open(os.join_path(root, 'trash')) or { panic(err) }
	work := os.join_path(root, 'work')
	a := os.join_path(work, 'a.txt')
	b := os.join_path(work, 'sub', 'b.txt')
	core_write(a, 'a')
	core_write(b, 'b')
	core_put(store, a, false)
	core_put(store, b, false)

	direct := store.list(cwd: work)
	assert direct.len == 1
	assert direct[0].original_path == a

	recursive := store.list(
		cwd:       work
		recursive: true
	)
	assert recursive.len == 2
}

fn test_list_skips_broken_items() {
	root := core_dir('list_broken')
	defer {
		core_cleanup(root)
	}
	store := open(os.join_path(root, 'trash')) or { panic(err) }
	id := 'broken'
	os.mkdir_all(store.item_dir(id)) or { panic(err) }
	core_insert(store, id, .pending, os.join_path(root, 'missing.txt'))
	assert store.list().len == 0

	// metadata says trashed, but payload is missing
	file := os.join_path(root, 'a.txt')
	core_write(file, 'a')
	entry := core_put(store, file, false)
	os.rm(store.data_path(entry.id)) or { panic(err) }
	assert store.list().len == 0
}

// regression: S1 — restore must not write through a symlinked parent directory.
fn test_restore_refuses_symlink_parent() {
	root := core_dir('restore_symlink_parent')
	defer {
		core_cleanup(root)
	}
	store := open(os.join_path(root, 'trash')) or { panic(err) }
	work := os.join_path(root, 'work')
	dir := os.join_path(work, 'dir')
	os.mkdir_all(dir) or { panic(err) }
	file := os.join_path(dir, 'a.txt')
	core_write(file, 'x')
	entry := core_put(store, file, false)

	outside := os.join_path(root, 'outside')
	os.mkdir_all(outside) or { panic(err) }
	os.rmdir_all(dir) or { panic(err) }
	os.symlink(outside, dir) or { panic(err) }

	mut failed := false
	store.restore(entry.id) or {
		failed = true
		assert err.msg().contains('resolves to')
	}
	assert failed
	assert !os.exists(os.join_path(outside, 'a.txt'))
	assert store.list().len == 1

	os.rm(dir) or { panic(err) }
	os.mkdir_all(dir) or { panic(err) }
	store.restore(entry.id) or { panic(err) }
	assert (os.read_file(file) or { '' }) == 'x'
}

fn test_restore_recreates_missing_parent_directory() {
	root := core_dir('restore_missing_parent')
	defer {
		core_cleanup(root)
	}
	store := open(os.join_path(root, 'trash')) or { panic(err) }
	file := os.join_path(root, 'work', 'nested', 'dir', 'a.txt')
	core_write(file, 'x')
	entry := core_put(store, file, false)
	os.rmdir_all(os.join_path(root, 'work')) or { panic(err) }

	store.restore(entry.id) or { panic(err) }
	assert os.is_dir(os.join_path(root, 'work', 'nested', 'dir'))
	assert (os.read_file(file) or { '' }) == 'x'
}

fn test_put_through_symlinked_parent_uses_canonical_path() {
	root := core_dir('put_symlink_parent')
	defer {
		core_cleanup(root)
	}
	store := open(os.join_path(root, 'trash')) or { panic(err) }
	real := os.join_path(root, 'real', 'dir')
	os.mkdir_all(real) or { panic(err) }
	os.symlink(os.join_path(root, 'real'), os.join_path(root, 'link')) or { panic(err) }
	file := os.join_path(real, 'a.txt')
	core_write(file, 'x')

	entry := core_put(store, os.join_path(root, 'link', 'dir', 'a.txt'), false)
	assert entry.original_path == file
	store.restore(entry.id) or { panic(err) }
	assert (os.read_file(file) or { '' }) == 'x'
}

fn test_restore_by_id() {
	root := core_dir('restore_id')
	defer {
		core_cleanup(root)
	}
	store := open(os.join_path(root, 'trash')) or { panic(err) }
	file := os.join_path(root, 'a.txt')
	core_write(file, 'hello')
	entry := core_put(store, file, false)

	results := store.restore(entry.id) or { panic(err) }
	assert results.len == 1
	assert results[0].restored_to == file
	assert (os.read_file(file) or { '' }) == 'hello'
	assert !os.is_dir(store.item_dir(entry.id))
}

fn test_restore_last_and_by_path() {
	root := core_dir('restore_path')
	defer {
		core_cleanup(root)
	}
	store := open(os.join_path(root, 'trash')) or { panic(err) }
	a := os.join_path(root, 'a.txt')
	b := os.join_path(root, 'b.txt')
	core_write(a, 'a')
	core_put(store, a, false)
	core_write(b, 'b')
	core_put(store, b, false)

	last := store.restore('') or { panic(err) }
	assert last[0].restored_to == b
	assert os.exists(b)
	assert !os.exists(a)

	by_path := store.restore(a) or { panic(err) }
	assert by_path[0].restored_to == a
	assert os.exists(a)
}

fn test_restore_uses_suffix_on_conflict() {
	root := core_dir('restore_conflict')
	defer {
		core_cleanup(root)
	}
	store := open(os.join_path(root, 'trash')) or { panic(err) }
	file := os.join_path(root, 'a.txt')
	core_write(file, 'old')
	entry := core_put(store, file, false)
	core_write(file, 'new')

	results := store.restore(entry.id) or { panic(err) }
	assert results[0].restored_to == '${file}~1'
	assert (os.read_file(file) or { '' }) == 'new'
	assert (os.read_file('${file}~1') or { '' }) == 'old'
}

fn test_restore_directory() {
	root := core_dir('restore_dir')
	defer {
		core_cleanup(root)
	}
	store := open(os.join_path(root, 'trash')) or { panic(err) }
	dir := os.join_path(root, 'dir')
	core_write(os.join_path(dir, 'a.txt'), 'a')
	entry := core_put(store, dir, true)

	store.restore(entry.id) or { panic(err) }
	assert (os.read_file(os.join_path(dir, 'a.txt')) or { '' }) == 'a'
}

fn test_restore_all_matching_path() {
	root := core_dir('restore_all')
	defer {
		core_cleanup(root)
	}
	store := open(os.join_path(root, 'trash')) or { panic(err) }
	file := os.join_path(root, 'a.txt')
	core_write(file, 'one')
	core_put(store, file, false)
	core_write(file, 'two')
	core_put(store, file, false)

	results := store.restore(file, all: true) or { panic(err) }
	assert results.len == 2
	assert os.exists(file)
	assert os.exists('${file}~1')
}

fn test_empty_removes_item() {
	root := core_dir('empty_item')
	defer {
		core_cleanup(root)
	}
	store := open(os.join_path(root, 'trash')) or { panic(err) }
	file := os.join_path(root, 'a.txt')
	core_write(file, 'a')
	entry := core_put(store, file, false)

	count := store.empty_entries([entry]) or { panic(err) }
	assert count == 1
	assert !os.is_dir(store.item_dir(entry.id))
	assert (os.ls(store.gc_dir()) or { []string{} }).len == 0
}

fn test_empty_removes_everything() {
	root := core_dir('empty')
	defer {
		core_cleanup(root)
	}
	store := open(os.join_path(root, 'trash')) or { panic(err) }
	for name in ['a.txt', 'b.txt'] {
		file := os.join_path(root, name)
		core_write(file, name)
		core_put(store, file, false)
	}
	count := store.empty() or { panic(err) }
	assert count == 2
	assert (os.ls(store.items_dir()) or { []string{} }).len == 0
	assert (os.ls(store.gc_dir()) or { []string{} }).len == 0
}

fn test_failpoint_restore_after_move_is_recovered() {
	root := core_dir('failpoint_restore')
	defer {
		core_cleanup(root)
	}
	store := open(os.join_path(root, 'trash')) or { panic(err) }
	file := os.join_path(root, 'a.txt')
	core_write(file, 'x')
	entry := core_put(store, file, false)
	mut failed := false
	with_failpoint('restore:after-move', fn [store, entry] () ! {
		store.restore(entry.id)!
	}) or { failed = true }
	assert failed
	assert os.getenv('TRASH_FAILPOINT') == ''
	store.recover_if_needed() or { panic(err) }
	assert (os.read_file(file) or { '' }) == 'x'
	assert store.list().len == 0
	assert !os.exists('${file}~1')
	assert_no_temp_files(store.root)
}

fn test_failpoint_empty_after_rename_is_recovered() {
	root := core_dir('failpoint_empty_item')
	defer {
		core_cleanup(root)
	}
	store := open(os.join_path(root, 'trash')) or { panic(err) }
	file := os.join_path(root, 'a.txt')
	core_write(file, 'x')
	entry := core_put(store, file, false)
	os.setenv('TRASH_TEST_FAILPOINTS', '1', true)
	os.setenv('TRASH_FAILPOINT', 'empty:after-rename', true)
	defer {
		os.unsetenv('TRASH_FAILPOINT')
		os.unsetenv('TRASH_TEST_FAILPOINTS')
	}
	mut failed := false
	store.empty_entries([entry]) or { failed = true }
	assert failed
	os.unsetenv('TRASH_FAILPOINT')
	store.recover_if_needed() or { panic(err) }
	assert store.list().len == 0
}

fn test_failpoint_put_after_move_is_recovered() {
	root := core_dir('failpoint_put')
	defer {
		core_cleanup(root)
	}
	store := open(os.join_path(root, 'trash')) or { panic(err) }
	file := os.join_path(root, 'a.txt')
	core_write(file, 'x')
	os.setenv('TRASH_TEST_FAILPOINTS', '1', true)
	os.setenv('TRASH_FAILPOINT', 'put:after-move', true)
	defer {
		os.unsetenv('TRASH_FAILPOINT')
		os.unsetenv('TRASH_TEST_FAILPOINTS')
	}
	mut failed := false
	store.put(file) or { failed = true }
	assert failed
	os.unsetenv('TRASH_FAILPOINT')
	store.recover_if_needed() or { panic(err) }
	assert store.list().len == 1
	assert !os.exists(file)
}

// regression: S2 — doctor must never write through an item-directory symlink.
// regression: S2/S3 — every store directory must be a real directory.
fn test_open_rejects_symlinked_store_dirs() {
	mut roots := []string{}
	defer {
		for root in roots {
			core_cleanup(root)
		}
	}
	for dirname in ['items', '.gc'] {
		root := core_dir('symlink_dir_${dirname.replace('.', 'dot')}')
		roots << root
		outside := os.join_path(root, 'outside')
		os.mkdir_all(outside) or { panic(err) }
		trash := os.join_path(root, 'trash')
		os.mkdir_all(trash) or { panic(err) }
		os.chmod(trash, 0o700) or { panic(err) }
		os.symlink(outside, os.join_path(trash, dirname)) or { panic(err) }
		mut failed := false
		open(trash) or { failed = true }
		assert failed, 'open must reject a symlinked ${dirname}'
		assert (os.ls(outside) or { []string{} }).len == 0
	}
}

// regression: S2 — a crafted symlinked item must not be restored through.
fn test_restore_refuses_symlinked_item_dir() {
	root := core_dir('symlink_item_restore')
	defer {
		core_cleanup(root)
	}
	store := open(os.join_path(root, 'trash')) or { panic(err) }
	outside := os.join_path(root, 'outside')
	os.mkdir_all(outside) or { panic(err) }
	core_write(os.join_path(outside, 'data'), 'evil')
	id := 'evil'
	core_insert(store, id, .trashed, os.join_path(root, 'stolen.txt'))
	os.symlink(outside, store.item_dir(id)) or { panic(err) }
	bad := Entry{
		id:            id
		original_path: os.join_path(root, 'stolen.txt')
		trashed_at:    time.now()
		kind:          .file
		size:          0
		size_known:    false
		state:         .trashed
	}
	batch := store.restore_batch([bad]) or { panic(err) }
	assert batch.failures.len == 1
	assert batch.results.len == 0
	assert (os.read_file(os.join_path(outside, 'data')) or { '' }) == 'evil'
	assert !os.exists(os.join_path(root, 'stolen.txt'))
}

fn test_gc_does_not_follow_symlinks() {
	root := core_dir('gc_symlink')
	defer {
		core_cleanup(root)
	}
	store := open(os.join_path(root, 'trash')) or { panic(err) }
	outside := os.join_path(root, 'outside')
	os.mkdir_all(outside) or { panic(err) }
	core_write(os.join_path(outside, 'keep'), 'x')

	os.symlink(outside, os.join_path(store.gc_dir(), 'link')) or { panic(err) }
	store.gc() or { panic(err) }
	assert !os.is_link(os.join_path(store.gc_dir(), 'link'))
	assert (os.read_file(os.join_path(outside, 'keep')) or { '' }) == 'x'

	os.rmdir_all(store.gc_dir()) or { panic(err) }
	os.symlink(outside, store.gc_dir()) or { panic(err) }
	mut failed := false
	store.gc() or { failed = true }
	assert failed
	assert (os.read_file(os.join_path(outside, 'keep')) or { '' }) == 'x'
}

fn test_doctor_does_not_follow_item_symlink() {
	root := core_dir('doctor_item_symlink')
	defer {
		core_cleanup(root)
	}
	store := open(os.join_path(root, 'trash')) or { panic(err) }
	outside := os.join_path(root, 'outside')
	os.mkdir_all(outside) or { panic(err) }
	core_write(os.join_path(outside, 'data'), 'x')
	id := 'symlink-item'
	os.symlink(outside, store.item_dir(id)) or { panic(err) }

	report := store.doctor(repair: true) or { panic(err) }
	assert report.broken == 1
	assert report.repaired == 0
	assert os.is_link(store.item_dir(id))

	report2 := store.doctor(repair: true, purge: true) or { panic(err) }
	assert report2.repaired == 0
	assert (os.read_file(os.join_path(outside, 'data')) or { '' }) == 'x'
	assert os.is_link(store.item_dir(id))
}

fn test_doctor_reports_orphan_payload() {
	root := core_dir('doctor_orphan')
	defer {
		core_cleanup(root)
	}
	store := open(os.join_path(root, 'trash')) or { panic(err) }
	id := 'doctor-orphan'
	item := store.item_dir(id)
	os.mkdir_all(item) or { panic(err) }
	core_write(store.data_path(id), 'precious')

	report := store.doctor(repair: true) or { panic(err) }
	assert report.broken == 1
	assert report.purged == 0
	assert store.list().len == 0
	assert (os.read_file(store.data_path(id)) or { '' }) == 'precious'

	purged := store.doctor(purge: true) or { panic(err) }
	assert purged.purged == 1
	assert !os.is_dir(item)
}

fn test_doctor_repairs_pending_item() {
	root := core_dir('doctor_pending')
	defer {
		core_cleanup(root)
	}
	store := open(os.join_path(root, 'trash')) or { panic(err) }
	id := 'doctor-pending'
	os.mkdir_all(store.item_dir(id)) or { panic(err) }
	core_write(store.data_path(id), 'x')
	core_insert(store, id, .pending, os.join_path(root, 'a.txt'))

	report := store.doctor(repair: true) or { panic(err) }
	assert report.repaired == 1
	assert store.entry(id)!.state == .trashed
	assert store.list().len == 1
}

fn test_recover_put_pending_with_data() {
	root := core_dir('recover_put_ok')
	defer {
		core_cleanup(root)
	}
	store := open(os.join_path(root, 'trash')) or { panic(err) }
	id := 'recover-put-ok'
	os.mkdir_all(store.item_dir(id)) or { panic(err) }
	core_write(store.data_path(id), 'x')
	core_insert(store, id, .pending, os.join_path(root, 'a.txt'))

	store.recover() or { panic(err) }
	assert store.entry(id)!.state == .trashed
}

fn test_recover_put_pending_without_data_removes_item() {
	root := core_dir('recover_put_missing')
	defer {
		core_cleanup(root)
	}
	store := open(os.join_path(root, 'trash')) or { panic(err) }
	id := 'recover-put-missing'
	item := store.item_dir(id)
	os.mkdir_all(item) or { panic(err) }
	core_insert(store, id, .pending, os.join_path(root, 'a.txt'))

	store.recover() or { panic(err) }
	assert !os.is_dir(item)
	mut failed := false
	store.entry(id) or { failed = true }
	assert failed
}

fn test_recover_restore_with_data_rolls_back_to_trashed() {
	root := core_dir('recover_restore_data')
	defer {
		core_cleanup(root)
	}
	store := open(os.join_path(root, 'trash')) or { panic(err) }
	id := 'recover-restore-data'
	target := os.join_path(root, 'a.txt')
	os.mkdir_all(store.item_dir(id)) or { panic(err) }
	core_write(store.data_path(id), 'x')
	core_insert(store, id, .restoring, target)
	mut item := store.get_item(id)!
	item.restore_to = percent_encode_path(target)
	store.update_item(item)!

	store.recover() or { panic(err) }
	assert store.entry(id)!.state == .trashed
	assert store.get_item(id)!.restore_to == ''
}

fn test_recover_restore_completes_same_device_rename() {
	root := core_dir('recover_restore_inode')
	defer {
		core_cleanup(root)
	}
	store := open(os.join_path(root, 'trash')) or { panic(err) }
	id := 'recover-restore-inode'
	item := store.item_dir(id)
	os.mkdir_all(item) or { panic(err) }
	data := store.data_path(id)
	core_write(data, 'x')
	target := os.join_path(root, 'a.txt')
	st := os.lstat(data) or { panic(err) }
	core_insert(store, id, .restoring, target)
	mut indexed := store.get_item(id)!
	indexed.restore_to = percent_encode_path(target)
	indexed.data_dev = st.dev
	indexed.data_ino = st.inode
	store.update_item(indexed)!
	os.rename(data, target) or { panic(err) }

	store.recover() or { panic(err) }
	assert !os.is_dir(item)
	assert (os.read_file(target) or { '' }) == 'x'
}

fn test_recover_restore_completes_journaled_copy_target() {
	root := core_dir('recover_restore_target_inode')
	defer {
		core_cleanup(root)
	}
	store := open(os.join_path(root, 'trash')) or { panic(err) }
	id := 'recover-restore-target'
	item := store.item_dir(id)
	os.mkdir_all(item) or { panic(err) }
	data := store.data_path(id)
	core_write(data, 'x')
	target := os.join_path(root, 'a.txt')
	core_write(target, 'x')
	data_st := os.lstat(data) or { panic(err) }
	target_st := os.lstat(target) or { panic(err) }
	core_insert(store, id, .restoring, target)
	mut indexed := store.get_item(id)!
	indexed.restore_to = percent_encode_path(target)
	indexed.data_dev = data_st.dev
	indexed.data_ino = data_st.inode
	indexed.target_dev = target_st.dev
	indexed.target_ino = target_st.inode
	store.update_item(indexed)!

	store.recover() or { panic(err) }
	assert !os.is_dir(item)
	assert (os.read_file(target) or { '' }) == 'x'
}

fn test_recover_restore_without_data_removes_item() {
	root := core_dir('recover_restore_missing')
	defer {
		core_cleanup(root)
	}
	store := open(os.join_path(root, 'trash')) or { panic(err) }
	id := 'recover-restore-missing'
	item := store.item_dir(id)
	os.mkdir_all(item) or { panic(err) }
	target := os.join_path(root, 'a.txt')
	core_insert(store, id, .restoring, target)
	mut indexed := store.get_item(id)!
	indexed.restore_to = percent_encode_path(target)
	store.update_item(indexed)!

	store.recover() or { panic(err) }
	assert !os.is_dir(item)
}

fn test_recover_empty_moves_to_gc() {
	root := core_dir('recover_empty')
	defer {
		core_cleanup(root)
	}
	store := open(os.join_path(root, 'trash')) or { panic(err) }
	id := 'recover-empty'
	item := store.item_dir(id)
	os.mkdir_all(item) or { panic(err) }
	core_write(store.data_path(id), 'x')
	core_insert(store, id, .pending_empty, os.join_path(root, 'a.txt'))

	store.recover() or { panic(err) }
	assert !os.is_dir(item)
	assert (os.ls(store.gc_dir()) or { []string{} }).len == 0
}

fn test_gc_removes_garbage() {
	root := core_dir('gc')
	defer {
		core_cleanup(root)
	}
	store := open(os.join_path(root, 'trash')) or { panic(err) }
	core_write(os.join_path(store.gc_dir(), 'junk', 'a.txt'), 'x')
	store.gc() or { panic(err) }
	assert (os.ls(store.gc_dir()) or { []string{} }).len == 0
}

fn test_put_path_with_spaces_and_tabs() {
	root := core_dir('put_special')
	defer {
		core_cleanup(root)
	}
	store := open(os.join_path(root, 'trash')) or { panic(err) }
	file := os.join_path(root, 'a b\tc.txt')
	core_write(file, 'x')
	entry := core_put(store, file, false)
	assert entry.original_path == file
	assert store.entry(entry.id)!.original_path == file
}

fn test_put_ids_are_monotonic() {
	root := core_dir('ids_monotonic')
	defer {
		core_cleanup(root)
	}
	store := open(os.join_path(root, 'trash')) or { panic(err) }
	mut ids := []string{}
	for i in 0 .. 100 {
		file := os.join_path(root, 'f${i}.txt')
		core_write(file, 'x')
		ids << core_put(store, file, false).id
	}
	for i in 1 .. ids.len {
		assert ids[i - 1] < ids[i]
	}
	// Newest items must sort first, so `restore last` picks the last put.
	entries := store.scan().entries
	assert entries[0].id == ids.last()
	assert entries.last().id == ids[0]
}

fn test_percent_path_rejects_nul() {
	mut failed := false
	percent_decode_path('/a%00b') or { failed = true }
	assert failed
}

fn test_recover_keeps_orphan_payload() {
	root := core_dir('recover_orphan')
	defer {
		core_cleanup(root)
	}
	store := open(os.join_path(root, 'trash')) or { panic(err) }
	id := 'recover-orphan'
	item := store.item_dir(id)
	os.mkdir_all(item) or { panic(err) }
	core_write(store.data_path(id), 'precious')

	store.recover() or { panic(err) }
	assert os.is_dir(item)
	assert (os.read_file(store.data_path(id)) or { '' }) == 'precious'
}

fn test_find_rejects_ambiguous_id_prefix() {
	root := core_dir('find_ambiguous')
	defer {
		core_cleanup(root)
	}
	store := open(os.join_path(root, 'trash')) or { panic(err) }
	for id in ['aaa1', 'aaa2'] {
		core_insert(store, id, .trashed, os.join_path(root, '${id}.txt'))
		core_write(store.data_path(id), 'x')
	}
	mut failed := false
	store.find('aaa') or { failed = true }
	assert failed
}

fn test_short_id_resolves_by_trailing_hex() {
	root := core_dir('short_id_find')
	defer {
		core_cleanup(root)
	}
	store := open(os.join_path(root, 'trash')) or { panic(err) }
	path := os.join_path(root, 'a.txt')
	core_write(path, 'a')
	entry := core_put(store, path, false)
	short := format.short_id(entry.id)
	assert short.len == 8
	assert short == entry.id.replace('-', '')[24..]
	found := store.find(short)!
	assert found.len == 1
	assert found[0].id == entry.id
	// A prefix of the short id resolves as well.
	prefixed := store.find(short[..4])!
	assert prefixed.len == 1
	assert prefixed[0].id == entry.id
	// The full id keeps working.
	by_full := store.find(entry.id)!
	assert by_full.len == 1
	assert by_full[0].id == entry.id
}

fn test_short_ids_stay_distinct_within_one_second() {
	root := core_dir('short_id_distinct')
	defer {
		core_cleanup(root)
	}
	store := open(os.join_path(root, 'trash')) or { panic(err) }
	mut shorts := map[string]bool{}
	mut ids := []string{}
	for name in ['a.txt', 'b.txt', 'c.txt', 'd.txt'] {
		path := os.join_path(root, name)
		core_write(path, name)
		entry := core_put(store, path, false)
		short := format.short_id(entry.id)
		assert short !in shorts
		shorts[short] = true
		ids << entry.id
	}
	for id in ids {
		found := store.find(format.short_id(id))!
		assert found.len == 1
		assert found[0].id == id
	}
}

fn test_restore_by_short_id() {
	root := core_dir('short_id_restore')
	defer {
		core_cleanup(root)
	}
	store := open(os.join_path(root, 'trash')) or { panic(err) }
	path := os.join_path(root, 'a.txt')
	core_write(path, 'a')
	entry := core_put(store, path, false)
	assert !os.exists(path)
	result := store.restore(format.short_id(entry.id))!
	assert result.len == 1
	assert os.read_file(path) or { '' } == 'a'
}

fn test_find_rejects_ambiguous_short_id() {
	root := core_dir('short_id_ambiguous')
	defer {
		core_cleanup(root)
	}
	store := open(os.join_path(root, 'trash')) or { panic(err) }
	for id in ['aaaa-1111-2222-3333-4444deadbeef', 'bbbb-1111-2222-3333-5555deadbeef'] {
		core_insert(store, id, .trashed, os.join_path(root, '${id}.txt'))
		core_write(store.data_path(id), 'x')
	}
	mut failed := false
	store.find('deadbeef') or { failed = true }
	assert failed
	failed = false
	store.find('dead') or { failed = true }
	assert failed
}

fn test_copy_path_preserves_tree_and_modes() {
	$if !windows {
		root := core_dir('copy_tree')
		defer {
			core_cleanup(root)
		}
		src := os.join_path(root, 'src')
		os.mkdir(src) or { panic(err) }
		file := os.join_path(src, 'a.txt')
		core_write(file, 'hello')
		os.chmod(file, 0o640) or { panic(err) }
		os.mkdir(os.join_path(src, 'sub')) or { panic(err) }
		core_write(os.join_path(src, 'sub', 'b.txt'), 'nested')
		os.symlink('a.txt', os.join_path(src, 'link')) or { panic(err) }

		dst := os.join_path(root, 'dst')
		fsx.copy_path_sync(src, dst) or { panic(err) }
		assert (os.read_file(os.join_path(dst, 'a.txt')) or { '' }) == 'hello'
		assert (os.stat(os.join_path(dst, 'a.txt')) or { panic(err) }).mode & 0o777 == 0o640
		assert (os.read_file(os.join_path(dst, 'sub', 'b.txt')) or { '' }) == 'nested'
		assert os.is_link(os.join_path(dst, 'link'))
		assert os.readlink(os.join_path(dst, 'link')) or { '' } == 'a.txt'
	}
}

fn test_rename_noreplace_refuses_existing_destination() {
	root := core_dir('rename_noreplace')
	defer {
		core_cleanup(root)
	}
	src := os.join_path(root, 'src')
	dst := os.join_path(root, 'dst')
	core_write(src, 'src')
	core_write(dst, 'dst')
	mut failed := false
	fsx.rename_noreplace(src, dst) or { failed = true }
	assert failed
	assert (os.read_file(src) or { '' }) == 'src'
	assert (os.read_file(dst) or { '' }) == 'dst'

	free := os.join_path(root, 'free')
	fsx.rename_noreplace(src, free) or { panic(err) }
	assert !os.exists(src)
	assert (os.read_file(free) or { '' }) == 'src'
}

fn test_scan_reports_entries_and_broken_items() {
	root := core_dir('scan_broken')
	defer {
		core_cleanup(root)
	}
	store := open(os.join_path(root, 'trash')) or { panic(err) }
	good := os.join_path(root, 'good.txt')
	core_write(good, 'good')
	entry := core_put(store, good, false)

	bad_id := 'broken-item'
	core_insert(store, bad_id, .pending, os.join_path(root, 'broken.txt'))

	scan := store.scan()
	assert scan.entries.len == 1
	assert scan.entries[0].id == entry.id
	assert scan.broken.len == 1
	assert scan.broken[0].id == bad_id
}

fn test_typed_find_errors() {
	root := core_dir('typed_find')
	defer {
		core_cleanup(root)
	}
	store := open(os.join_path(root, 'trash')) or { panic(err) }
	store.find('missing') or {
		assert err.code() == int(ErrorKind.not_found)
	}
	for id in ['aaa1', 'aaa2'] {
		core_insert(store, id, .trashed, os.join_path(root, '${id}.txt'))
		core_write(store.data_path(id), 'x')
	}
	store.find('aaa') or {
		assert err.code() == int(ErrorKind.ambiguous)
	}
}

fn test_batch_restore_and_empty() {
	root := core_dir('batch')
	defer {
		core_cleanup(root)
	}
	store := open(os.join_path(root, 'trash')) or { panic(err) }
	mut paths := []string{}
	for name in ['a.txt', 'b.txt', 'c.txt'] {
		path := os.join_path(root, name)
		core_write(path, name)
		core_put(store, path, false)
		paths << path
	}
	entries := store.scan().entries
	assert entries.len == 3
	restored := store.restore_entries(entries[..2]) or { panic(err) }
	assert restored.len == 2
	for result in restored {
		assert os.exists(result.entry.original_path)
	}
	remaining := store.scan().entries
	assert remaining.len == 1
	emptied := store.empty_entries(remaining) or { panic(err) }
	assert emptied == 1
	assert store.scan().entries.len == 0
}

fn test_recover_if_needed_returns_false_when_clean() {
	root := core_dir('recover_needed_clean')
	defer {
		core_cleanup(root)
	}
	store := open(os.join_path(root, 'trash')) or { panic(err) }
	report := store.recover_if_needed() or { panic(err) }
	assert report.recovered == 0
	assert report.warnings.len == 0
}

fn test_recover_if_needed_finishes_pending_put() {
	root := core_dir('recover_needed_put')
	defer {
		core_cleanup(root)
	}
	store := open(os.join_path(root, 'trash')) or { panic(err) }
	file := os.join_path(root, 'a.txt')
	core_write(file, 'x')
	entry := core_put(store, file, false)
	mut item := store.get_item(entry.id)!
	item.state = .pending
	store.update_item(item)!
	report := store.recover_if_needed() or { panic(err) }
	assert report.recovered == 1
	assert store.entry(entry.id)!.state == .trashed
	second := store.recover_if_needed() or { panic(err) }
	assert second.recovered == 0
}

fn test_copy_path_copies_large_file() {
	root := core_dir('copy_large')
	defer {
		core_cleanup(root)
	}
	src := os.join_path(root, 'large.bin')
	content := '0123456789abcdef'.repeat(16 * 1024)
	core_write(src, content)
	dst := os.join_path(root, 'copy.bin')
	fsx.copy_path_sync(src, dst) or { panic(err) }
	assert (os.read_file(dst) or { '' }).len == content.len
	assert (os.stat(dst) or { panic(err) }).size == u64(content.len)
}

fn test_recover_restore_removes_stale_tmp() {
	root := core_dir('recover_tmp')
	defer {
		core_cleanup(root)
	}
	store := open(os.join_path(root, 'trash')) or { panic(err) }
	file := os.join_path(root, 'a.txt')
	core_write(file, 'x')
	entry := core_put(store, file, false)
	mut item := store.get_item(entry.id)!
	item.state = .restoring
	item.restore_to = percent_encode_path(file)
	store.update_item(item)!
	stale := '${file}.trash-tmp-${entry.id}'
	core_write(stale, 'partial')
	core_write('${stale}.owner', entry.id)
	store.recover() or { panic(err) }
	assert !os.exists(stale)
	assert !os.exists('${stale}.owner')
	assert store.entry(entry.id)!.state == .trashed
}

// regression: recovery never removes a temp path it did not create.
fn test_recover_restore_keeps_foreign_tmp_without_marker() {
	root := core_dir('recover_tmp_foreign')
	defer {
		core_cleanup(root)
	}
	store := open(os.join_path(root, 'trash')) or { panic(err) }
	file := os.join_path(root, 'a.txt')
	core_write(file, 'x')
	entry := core_put(store, file, false)
	mut item := store.get_item(entry.id)!
	item.state = .restoring
	item.restore_to = percent_encode_path(file)
	store.update_item(item)!
	foreign := '${file}.trash-tmp-${entry.id}'
	core_write(foreign, 'not ours')
	store.recover() or { panic(err) }
	assert (os.read_file(foreign) or { '' }) == 'not ours'
	assert store.entry(entry.id)!.state == .trashed
}

fn test_open_refuses_filesystem_root() {
	mut failed := false
	open('/') or { failed = true }
	assert failed
}

fn test_open_with_can_refuse_creation() {
	root := core_dir('open_no_create')
	defer {
		core_cleanup(root)
	}
	mut failed := false
	open_with(os.join_path(root, 'missing'), create: false) or { failed = true }
	assert failed
}

fn test_put_many_and_stats() {
	root := core_dir('put_many')
	defer {
		core_cleanup(root)
	}
	store := open(os.join_path(root, 'trash')) or { panic(err) }
	mut paths := []string{}
	for name in ['a.txt', 'b.txt', 'c.txt'] {
		path := os.join_path(root, name)
		core_write(path, name)
		paths << path
	}
	batch := store.put_many(paths) or { panic(err) }
	assert batch.entries.len == 3
	assert batch.failures.len == 0
	stats := store.stats()
	assert stats.items == 3
	assert stats.size == u64(0)
	assert stats.unknown == 3
	_ := store.fill_sizes(batch.entries)
	sized := store.stats()
	assert sized.size == u64(15)
	assert sized.unknown == 0
}

fn test_restore_batch_reports_partial_failure() {
	root := core_dir('restore_batch_fail')
	defer {
		core_cleanup(root)
	}
	store := open(os.join_path(root, 'trash')) or { panic(err) }
	a := os.join_path(root, 'a.txt')
	b := os.join_path(root, 'b.txt')
	core_write(a, 'a')
	core_write(b, 'b')
	ea := core_put(store, a, false)
	eb := core_put(store, b, false)
	os.rm(store.data_path(eb.id)) or { panic(err) }
	batch := store.restore_batch([ea, eb]) or { panic(err) }
	assert batch.results.len == 1
	assert batch.failures.len == 1
	assert os.exists(a)
}

fn test_filter_entries_by_kind_grep_and_age() {
	root := core_dir('filter')
	defer {
		core_cleanup(root)
	}
	store := open(os.join_path(root, 'trash')) or { panic(err) }
	file := os.join_path(root, 'report.txt')
	dir := os.join_path(root, 'build')
	core_write(file, 'x')
	os.mkdir(dir) or { panic(err) }
	core_put(store, file, false)
	core_put(store, dir, true)
	entries := store.scan().entries
	assert filter_entries(entries, all: true, kind: 'file').len == 1
	assert filter_entries(entries, all: true, grep: 'report').len == 1
	assert filter_entries(entries, all: true, older_than_seconds: 3600).len == 0
	sorted := filter_entries(entries, all: true, sort: 'path')
	assert sorted[0].original_path < sorted[1].original_path
}

fn test_empty_cleans_gc() {
	root := core_dir('empty_gc')
	defer {
		core_cleanup(root)
	}
	store := open(os.join_path(root, 'trash')) or { panic(err) }
	file := os.join_path(root, 'a.txt')
	core_write(file, 'x')
	core_put(store, file, false)
	assert (store.empty() or { panic(err) }) == 1
	assert (os.ls(store.items_dir()) or { []string{} }).len == 0
	assert (os.ls(store.gc_dir()) or { []string{} }).len == 0
}

fn test_copy_path_refuses_existing_destination() {
	root := core_dir('copy_excl')
	defer {
		core_cleanup(root)
	}
	src := os.join_path(root, 'src.txt')
	dst := os.join_path(root, 'dst.txt')
	core_write(src, 'new')
	core_write(dst, 'old')
	mut failed := false
	fsx.copy_path_sync(src, dst) or { failed = true }
	assert failed
	assert (os.read_file(dst) or { '' }) == 'old'
}

fn test_open_with_injects_id_and_clock() {
	root := core_dir('inject')
	defer {
		core_cleanup(root)
	}
	store := open_with(os.join_path(root, 'trash'),
		id_gen: fn () string {
			return '00000000-0000-7000-8000-000000000001'
		}
	) or { panic(err) }
	file := os.join_path(root, 'a.txt')
	core_write(file, 'x')
	entry := core_put(store, file, false)
	assert entry.id == '00000000-0000-7000-8000-000000000001'
}

fn test_percent_round_trip_fuzzish() {
	mut state := u64(0x9e3779b97f4a7c15)
	for _ in 0 .. 500 {
		state = state * 6364136223846793005 + 1442695040888963407
		length := int((state >> 32) % 64)
		mut bytes := []u8{cap: length}
		for _ in 0 .. length {
			state = state * 6364136223846793005 + 1442695040888963407
			byte := u8((state >> 24) & 0xff)
			if byte != 0 {
				bytes << byte
			}
		}
		path := bytes.bytestr()
		encoded := percent_encode_path(path)
		decoded := percent_decode_path(encoded) or { panic(err) }
		assert decoded == path
	}
}

fn test_percent_decode_random_input_does_not_panic() {
	alphabet := '%0123456789ABCDEFabcdefxyz/._- '
	mut state := u64(0x123456789abcdef)
	for _ in 0 .. 2000 {
		state = state * 6364136223846793005 + 1442695040888963407
		length := int((state >> 32) % 48)
		mut bytes := []u8{cap: length}
		for _ in 0 .. length {
			state = state * 6364136223846793005 + 1442695040888963407
			bytes << alphabet[int((state >> 24) % alphabet.len)]
		}
		percent_decode_path(bytes.bytestr()) or {}
	}
}

fn test_measure_path_sums_regular_files_only() {
	$if !windows {
		root := core_dir('measure_tree')
		defer {
			core_cleanup(root)
		}
		dir := os.join_path(root, 'tree')
		core_write(os.join_path(dir, 'a.txt'), '12345')
		core_write(os.join_path(dir, 'sub', 'b.txt'), '123')
		os.mkdir_all(os.join_path(dir, 'empty')) or { panic(err) }
		os.symlink(os.join_path(dir, 'a.txt'), os.join_path(dir, 'link')) or { panic(err) }

		size, ok := measure_path(dir, .dir)
		assert ok
		assert size == 8
		file_size, file_ok := measure_path(os.join_path(dir, 'a.txt'), .file)
		assert file_ok
		assert file_size == 5
		link_size, link_ok := measure_path(os.join_path(dir, 'link'), .symlink)
		assert link_ok
		assert link_size == 0
	}
}

fn test_measure_path_reports_unreadable_subdir() {
	$if !windows {
		if os.geteuid() == 0 {
			return
		}
		root := core_dir('measure_unreadable')
		defer {
			core_cleanup(root)
		}
		dir := os.join_path(root, 'tree')
		core_write(os.join_path(dir, 'a.txt'), '1')
		hidden := os.join_path(dir, 'hidden')
		core_write(os.join_path(hidden, 'b.txt'), '22')
		os.chmod(hidden, 0o000) or { panic(err) }
		defer {
			os.chmod(hidden, 0o700) or {}
		}

		_, ok := measure_path(dir, .dir)
		assert !ok
	}
}

fn test_fill_size_persists_directory_size() {
	$if !windows {
		root := core_dir('fill_dir')
		defer {
			core_cleanup(root)
		}
		store := open(os.join_path(root, 'trash')) or { panic(err) }
		dir := os.join_path(root, 'tree')
		core_write(os.join_path(dir, 'a.txt'), '12345')
		core_write(os.join_path(dir, 'sub', 'b.txt'), '123')
		entry := core_put(store, dir, true)
		assert !entry.size_known

		filled := store.fill_size(entry)
		assert filled.size_known
		assert filled.size == 8
		stored := store.entry(entry.id)!
		assert stored.size_known
		assert stored.size == 8

		// A second fill must not walk the payload again.
		again := store.fill_size(filled)
		assert again.size == 8
	}
}

fn test_fill_size_leaves_missing_payload_unknown() {
	root := core_dir('fill_missing')
	defer {
		core_cleanup(root)
	}
	store := open(os.join_path(root, 'trash')) or { panic(err) }
	file := os.join_path(root, 'a.txt')
	core_write(file, 'hello')
	entry := core_put(store, file, false)
	os.rm(store.data_path(entry.id)) or { panic(err) }

	filled := store.fill_size(entry)
	assert !filled.size_known
	assert filled.size == 0
}

fn test_list_sort_size_measures_candidates() {
	root := core_dir('list_sort_size')
	defer {
		core_cleanup(root)
	}
	store := open(os.join_path(root, 'trash')) or { panic(err) }
	small := os.join_path(root, 'small.txt')
	big := os.join_path(root, 'big.txt')
	core_write(small, '1')
	core_write(big, '1234567890')
	small_entry := core_put(store, small, false)
	core_put(store, big, false)

	entries := store.list(sort: 'size')
	assert entries.len == 2
	assert entries[0].original_path == big
	assert entries[0].size == 10
	assert entries[1].original_path == small
	assert store.entry(small_entry.id)!.size_known
}

fn test_doctor_repair_measures_unknown_sizes() {
	$if !windows {
		root := core_dir('doctor_sizes')
		defer {
			core_cleanup(root)
		}
		store := open(os.join_path(root, 'trash')) or { panic(err) }
		dir := os.join_path(root, 'tree')
		core_write(os.join_path(dir, 'a.txt'), '1234')
		core_write(os.join_path(dir, 'sub', 'b.txt'), '123')
		core_put(store, dir, true)
		file := os.join_path(root, 'c.txt')
		core_write(file, '12345')
		core_put(store, file, false)

		before := store.stats()
		assert before.unknown == 2
		assert before.size == 0

		report := store.doctor(repair: true) or { panic(err) }
		assert report.sized == 2
		assert report.unknown == 0

		after := store.stats()
		assert after.unknown == 0
		assert after.size == 12
	}
}

fn test_failpoint_put_recovers_to_trashed() {
	root := core_dir('fail_put')
	defer {
		core_cleanup(root)
	}
	store := open(os.join_path(root, 'trash')) or { panic(err) }
	file := os.join_path(root, 'a.txt')
	core_write(file, 'x')
	mut failed := false
	with_failpoint('put:after-move', fn [store, file] () ! {
		store.put(file)!
	}) or { failed = true }
	assert failed
	assert !os.exists(file)
	// The payload is in the trash, so recovery must keep it.
	store.recover() or { panic(err) }
	entries := store.list()
	assert entries.len == 1
	assert entries[0].state == .trashed
}

fn test_failpoint_restore_recovers_by_finishing() {
	root := core_dir('fail_restore')
	defer {
		core_cleanup(root)
	}
	store := open(os.join_path(root, 'trash')) or { panic(err) }
	file := os.join_path(root, 'a.txt')
	core_write(file, 'x')
	entry := core_put(store, file, false)
	mut failed := false
	with_failpoint('restore:after-move', fn [store, entry] () ! {
		store.restore_entries([entry])!
	}) or { failed = true }
	assert failed
	assert os.exists(file)
	store.recover() or { panic(err) }
	assert store.count_items() == 0
	assert !os.is_dir(store.item_dir(entry.id))
	assert (os.read_file(file) or { '' }) == 'x'
}

fn test_failpoint_empty_recovers_by_finishing() {
	root := core_dir('fail_empty')
	defer {
		core_cleanup(root)
	}
	store := open(os.join_path(root, 'trash')) or { panic(err) }
	file := os.join_path(root, 'a.txt')
	core_write(file, 'x')
	entry := core_put(store, file, false)
	mut failed := false
	with_failpoint('empty:after-rename', fn [store, entry] () ! {
		store.empty_entries([entry])!
	}) or { failed = true }
	assert failed
	store.recover() or { panic(err) }
	assert store.count_items() == 0
	assert !os.is_dir(store.item_dir(entry.id))
	assert (os.ls(store.gc_dir()) or { []string{} }).len == 0
}

fn test_parallel_open_of_fresh_store() {
	root := core_dir('parallel_open')
	defer {
		core_cleanup(root)
	}
	trash := os.join_path(root, 'trash')
	mut tasks := []fn (){}
	for _ in 0 .. 8 {
		tasks << fn [trash] () {
			open(trash) or { panic(err) }
		}
	}
	run_parallel(tasks)
	store := open(trash) or { panic(err) }
	assert store.count_items() == 0
	assert store.index_pragma('PRAGMA user_version')! == '${latest_schema_version}'
}

fn test_doctor_integrity_and_backup() {
	root := core_dir('doctor_backup')
	defer {
		core_cleanup(root)
	}
	store := open(os.join_path(root, 'trash')) or { panic(err) }
	for name in ['a.txt', 'b.txt'] {
		file := os.join_path(root, name)
		core_write(file, name)
		core_put(store, file, false)
	}
	report := store.doctor(integrity_check: true, backup: true) or { panic(err) }
	assert report.integrity == 'ok'
	assert report.backup.ends_with('index.backup.db')
	assert os.exists(report.backup)

	mut backup := sqlite.open_readonly(report.backup) or { panic(err) }
	rows := backup.query('SELECT COUNT(*) FROM items')!
	assert rows.len == 1
	assert rows[0].vals[0] == '2'
	version := backup.query('PRAGMA user_version')!
	assert version[0].vals[0] == '${latest_schema_version}'
	backup.close()

	// A second backup replaces the first one instead of failing.
	again := store.doctor(backup: true) or { panic(err) }
	assert again.backup == report.backup
	assert store.count_items() == 2
}

fn test_doctor_compact_and_reindex() {
	root := core_dir('doctor_compact')
	defer {
		core_cleanup(root)
	}
	store := open(os.join_path(root, 'trash')) or { panic(err) }
	mut entries := []Entry{}
	for name in ['a.txt', 'b.txt', 'c.txt'] {
		file := os.join_path(root, name)
		core_write(file, name)
		entries << core_put(store, file, false)
	}
	// Delete one item so VACUUM has something to reclaim.
	store.empty_entries([entries[0]]) or { panic(err) }
	assert store.count_items() == 2
	report := store.doctor(compact: true, reindex: true) or { panic(err) }
	assert report.compacted
	assert report.reindexed
	assert store.count_items() == 2
	check := store.doctor(integrity_check: true) or { panic(err) }
	assert check.integrity == 'ok'
}

fn test_doctor_rebuild_from_payload() {
	root := core_dir('doctor_rebuild')
	defer {
		core_cleanup(root)
	}
	trash := os.join_path(root, 'trash')
	mut store := open(trash) or { panic(err) }
	for name in ['a.txt', 'b.txt'] {
		file := os.join_path(root, name)
		core_write(file, name)
		core_put(store, file, false)
	}
	index := store.index_path()
	store.close()
	os.rm(index) or { panic(err) }
	os.rm('${index}-wal') or {}
	os.rm('${index}-shm') or {}

	reopened := open(trash) or { panic(err) }
	assert reopened.count_items() == 0
	report := reopened.doctor(rebuild: true) or { panic(err) }
	assert report.rebuilt == 2
	entries := reopened.list()
	assert entries.len == 2
	for entry in entries {
		assert entry.original_path == ''
		assert entry.state == .trashed
	}
	// A rebuilt item has no original path, so restore must refuse it.
	mut failed := false
	reopened.restore_entries([entries[0]]) or { failed = true }
	assert failed
	assert reopened.count_items() == 2
	assert (os.read_file(reopened.payload_path(entries[0].id)) or { '' }) in ['a.txt', 'b.txt']
}

fn test_stats_excludes_broken_and_uses_trashed_at() {
	root := core_dir('stats_times')
	defer {
		core_cleanup(root)
	}
	store := open(os.join_path(root, 'trash')) or { panic(err) }
	for item in [
		IndexItem{
			id:            'id-new'
			original_path: '/tmp/new'
			trashed_at:    time.unix(2000)
			kind:          .file
			state:         .trashed
		},
		IndexItem{
			id:            'id-old'
			original_path: '/tmp/old'
			trashed_at:    time.unix(1000)
			kind:          .file
			state:         .trashed
		},
	] {
		os.mkdir_all(store.item_dir(item.id)) or { panic(err) }
		core_write(store.data_path(item.id), 'x')
		store.insert_item(item) or { panic(err) }
	}
	// A row without a payload is broken and must not inflate `items`.
	store.insert_item(IndexItem{
		id:            'id-broken'
		original_path: '/tmp/broken'
		trashed_at:    time.unix(500)
		kind:          .file
		state:         .trashed
	}) or { panic(err) }

	stats := store.stats()
	assert stats.items == 2
	assert stats.broken == 1
	assert stats.unknown == 2
	assert stats.oldest == time.unix(1000).format_rfc3339()
	assert stats.newest == time.unix(2000).format_rfc3339()
}

fn test_doctor_repair_then_purge_keeps_repaired_item() {
	root := core_dir('repair_purge')
	defer {
		core_cleanup(root)
	}
	store := open(os.join_path(root, 'trash')) or { panic(err) }
	id := store.next_id()
	os.mkdir_all(store.item_dir(id)) or { panic(err) }
	core_write(store.data_path(id), 'payload')
	store.insert_item(IndexItem{
		id:            id
		original_path: os.join_path(root, 'repaired.txt')
		trashed_at:    time.now()
		kind:          .file
		state:         .pending
	}) or { panic(err) }

	report := store.doctor(repair: true, purge: true) or { panic(err) }
	assert report.repaired == 1
	assert report.purged == 0
	assert report.broken == 0
	assert (store.item_count() or { panic(err) }) == 1
	assert (store.get_item(id) or { panic(err) }).state == .trashed
	assert os.exists(store.data_path(id))
}

fn test_put_many_failure_reports_the_path() {
	root := core_dir('put_failure_path')
	defer {
		core_cleanup(root)
	}
	dir := os.join_path(root, 'readonly')
	os.mkdir_all(dir) or { panic(err) }
	file := os.join_path(dir, 'a.txt')
	core_write(file, 'x')
	os.chmod(dir, 0o500) or { panic(err) }
	defer {
		os.chmod(dir, 0o700) or {}
	}
	store := open(os.join_path(root, 'trash')) or { panic(err) }
	batch := store.put_many([file]) or { panic(err) }
	assert batch.failures.len == 1
	assert batch.failures[0].subject == file
	assert batch.failures[0].op == 'put'
	assert os.exists(file)
}

fn test_recovery_warns_about_symlinked_item_dir() {
	root := core_dir('recovery_symlink_warn')
	defer {
		core_cleanup(root)
	}
	store := open(os.join_path(root, 'trash')) or { panic(err) }
	id := store.next_id()
	outside := os.join_path(root, 'outside')
	os.mkdir_all(outside) or { panic(err) }
	os.symlink(outside, store.item_dir(id)) or { panic(err) }
	store.insert_item(IndexItem{
		id:            id
		original_path: os.join_path(root, 'a.txt')
		trashed_at:    time.now()
		kind:          .file
		state:         .pending
	}) or { panic(err) }

	report := store.recover() or { panic(err) }
	assert report.recovered == 0
	assert report.warnings.len == 1
	assert report.warnings[0].contains(id)
	assert (store.item_count() or { panic(err) }) == 1
}

fn test_copy_path_strips_setuid_bits() {
	$if !windows {
		root := core_dir('copy_setuid')
		defer {
			core_cleanup(root)
		}
		src := os.join_path(root, 'src')
		dst := os.join_path(root, 'dst')
		core_write(src, 'x')
		os.chmod(src, 0o4755) or { panic(err) }
		fsx.copy_path_sync(src, dst) or { panic(err) }
		mode := (os.stat(dst) or { panic(err) }).mode & 0o7777
		assert mode & 0o7000 == 0
		assert mode & 0o777 == 0o755
	}
}

fn test_reopen_rejects_group_accessible_store_dirs() {
	$if !windows {
		root := core_dir('dir_mode')
		defer {
			core_cleanup(root)
		}
		store_path := os.join_path(root, 'trash')
		store := open(store_path) or { panic(err) }
		os.chmod(store.items_dir(), 0o750) or { panic(err) }
		mut failed := false
		open(store_path) or { failed = true }
		assert failed, 'group-accessible items/ must be rejected'
		os.chmod(store.items_dir(), 0o700) or { panic(err) }
		os.chmod(store.root, 0o750) or { panic(err) }
		failed = false
		open(store_path) or { failed = true }
		assert failed, 'group-accessible store root must be rejected'
		os.chmod(store.root, 0o700) or { panic(err) }
		reopened := open(store_path) or { panic(err) }
		assert reopened.mode & 0o777 == 0o700
	}
}

fn test_empty_leaves_orphan_payload_for_doctor() {
	root := core_dir('empty_orphan')
	defer {
		core_cleanup(root)
	}
	store := open(os.join_path(root, 'trash')) or { panic(err) }
	file := os.join_path(root, 'a.txt')
	core_write(file, 'x')
	core_put(store, file, false)
	orphan := '00000000-0000-7000-8000-000000000000'
	os.mkdir_all(store.item_dir(orphan)) or { panic(err) }
	core_write(store.data_path(orphan), 'orphan')
	assert store.scan().broken.len == 1
	count := store.empty() or { panic(err) }
	assert count == 1
	assert os.exists(store.data_path(orphan))
	report := store.doctor(purge: true) or { panic(err) }
	assert report.purged == 1
	assert !os.exists(store.item_dir(orphan))
}

fn test_gc_reports_unremovable_items_and_retries() {
	$if !windows {
		root := core_dir('gc_locked')
		defer {
			core_cleanup(root)
		}
		store := open(os.join_path(root, 'trash')) or { panic(err) }
		garbage := os.join_path(store.gc_dir(), 'blocked')
		core_write(garbage, 'x')
		os.chmod(store.gc_dir(), 0o500) or { panic(err) }
		mut failed := false
		store.gc() or { failed = true }
		assert failed
		assert os.exists(garbage)

		os.chmod(store.gc_dir(), 0o700) or { panic(err) }
		store.gc() or { panic(err) }
		assert !os.exists(garbage)
	}
}

// regression: a garbage item that cannot be removed is reported as a
// warning and does not block normal commands.
fn test_gc_failure_is_a_warning_not_fatal() {
	root := core_dir('gc_warning')
	defer {
		core_cleanup(root)
	}
	store := open(os.join_path(root, 'trash')) or { panic(err) }
	garbage := os.join_path(store.gc_dir(), 'blocked')
	core_write(garbage, 'x')
	os.setenv('TRASH_TEST_FAILPOINTS', '1', true)
	os.setenv('TRASH_FAILPOINT', 'gc:remove-blocked', true)
	report := store.recover_if_needed() or {
		os.unsetenv('TRASH_FAILPOINT')
		os.unsetenv('TRASH_TEST_FAILPOINTS')
		panic(err)
	}
	os.unsetenv('TRASH_FAILPOINT')
	os.unsetenv('TRASH_TEST_FAILPOINTS')
	assert report.warnings.len == 1
	assert report.warnings[0].contains('blocked')
	assert os.exists(garbage)
	// Read paths keep working while garbage is stuck.
	assert store.count_items() == 0
	assert store.scan().broken.len == 0
	store.gc() or { panic(err) }
	assert !os.exists(garbage)
}

// regression: recovery keeps processing items after one of them fails.
fn test_recovery_continues_after_item_error() {
	$if !windows {
		root := core_dir('recover_continue')
		defer {
			core_cleanup(root)
		}
		store := open(os.join_path(root, 'trash')) or { panic(err) }
		first := 'a-pending-empty'
		os.mkdir_all(store.item_dir(first)) or { panic(err) }
		core_write(store.data_path(first), 'x')
		core_insert(store, first, .pending_empty, os.join_path(root, 'a.txt'))
		second := 'b-pending-put'
		core_insert(store, second, .pending, os.join_path(root, 'b.txt'))

		os.chmod(store.gc_dir(), 0o500) or { panic(err) }
		report := store.recover() or {
			os.chmod(store.gc_dir(), 0o700) or {}
			panic(err)
		}
		os.chmod(store.gc_dir(), 0o700) or { panic(err) }

		assert report.warnings.len >= 1
		// The first item could not be moved into .gc; its row is kept.
		assert store.get_item(first)!.state == .pending_empty
		assert os.exists(store.data_path(first))
		// The second item was still recovered despite the first failure.
		store.get_item(second) or { return }
		panic('second item should have been recovered')
	}
}

// regression: an unknown on-disk state is broken, never pending_empty.
fn test_unknown_index_state_is_broken_not_pending_empty() {
	root := core_dir('unknown_state')
	defer {
		core_cleanup(root)
	}
	store := open(os.join_path(root, 'trash')) or { panic(err) }
	id := 'unknown-state'
	os.mkdir_all(store.item_dir(id)) or { panic(err) }
	core_write(store.data_path(id), 'keep')
	core_insert(store, id, .trashed, os.join_path(root, 'a.txt'))
	mut db := store.db
	// The schema CHECK constraint rejects state=99, so simulate a corrupt or
	// future index row by bypassing it for this update.
	db.exec('PRAGMA ignore_check_constraints = ON')!
	db.exec("UPDATE items SET state = 99 WHERE id = '${id}'")!
	db.exec('PRAGMA ignore_check_constraints = OFF')!

	scan := store.scan()
	assert scan.entries.len == 0
	assert scan.broken.len == 1
	assert scan.broken[0].id == id
	assert scan.broken[0].reason.contains('unknown')

	report := store.recover() or { panic(err) }
	assert report.recovered == 0
	assert report.warnings.len == 1
	assert report.warnings[0].contains('unknown state')
	// Nothing was moved into .gc and the payload is untouched.
	garbage := os.ls(store.gc_dir()) or { []string{} }
	assert garbage.len == 0
	assert (os.read_file(store.data_path(id)) or { '' }) == 'keep'
	assert store.get_item(id)!.state == .unknown
}

// regression: ids read from the index are never turned into paths.
fn test_scan_and_recovery_reject_unsafe_index_ids() {
	root := core_dir('unsafe_index_ids')
	defer {
		core_cleanup(root)
	}
	store := open(os.join_path(root, 'trash')) or { panic(err) }
	// `items/../../victim` resolves to root/victim for id "../../victim".
	victim := os.join_path(root, 'victim')
	core_write(os.join_path(victim, 'keep.txt'), 'keep')
	for id in ['../../victim', 'a/b', '.'] {
		core_insert(store, id, .pending_empty, os.join_path(root, 'x'))
	}
	scan := store.scan()
	assert scan.entries.len == 0
	assert scan.broken.len == 3
	for broken in scan.broken {
		assert broken.reason == 'invalid item id'
	}
	report := store.recover() or { panic(err) }
	assert report.recovered == 0
	assert report.warnings.len == 3
	assert (os.read_file(os.join_path(victim, 'keep.txt')) or { '' }) == 'keep'
	assert os.is_dir(victim)
	// The unsafe rows are left for doctor, not deleted.
	assert store.pending_items()!.len == 3
}

// regression: a relative restore_to is not trusted by recovery.
fn test_recovery_rejects_relative_restore_to() {
	root := core_dir('restore_to_relative')
	defer {
		core_cleanup(root)
	}
	store := open(os.join_path(root, 'trash')) or { panic(err) }
	id := 'restore-relative'
	os.mkdir_all(store.item_dir(id)) or { panic(err) }
	core_write(store.data_path(id), 'x')
	sentinel := os.join_path(root, 'victim')
	core_write(sentinel, 'keep')
	core_insert(store, id, .restoring, os.join_path(root, 'a.txt'))
	mut item := store.get_item(id)!
	item.restore_to = percent_encode_path('../../victim')
	store.update_item(item)!

	report := store.recover() or { panic(err) }
	assert report.warnings.len == 1
	assert report.warnings[0].contains('invalid restore target')
	assert (os.read_file(sentinel) or { '' }) == 'keep'
	// The payload is still in the store, so the row is rolled back to trashed.
	assert store.get_item(id)!.state == .trashed
	assert store.get_item(id)!.restore_to == ''
	assert (os.read_file(store.data_path(id)) or { '' }) == 'x'
}

// regression: an unnormalised restore_to is not trusted by recovery.
fn test_recovery_rejects_unnormalised_restore_to() {
	root := core_dir('restore_to_unnormalised')
	defer {
		core_cleanup(root)
	}
	store := open(os.join_path(root, 'trash')) or { panic(err) }
	id := 'restore-unnormalised'
	os.mkdir_all(store.item_dir(id)) or { panic(err) }
	core_write(store.data_path(id), 'x')
	os.mkdir_all(os.join_path(root, 'sub')) or { panic(err) }
	target := os.join_path(root, 'sub', '..', 'victim')
	// The stale temporary path that an unvalidated remove_any() would delete.
	stale := '${target}.trash-tmp-${id}'
	core_write(stale, 'keep')
	core_insert(store, id, .restoring, target)
	mut item := store.get_item(id)!
	item.restore_to = percent_encode_path(target)
	store.update_item(item)!

	report := store.recover() or { panic(err) }
	assert report.warnings.len == 1
	assert (os.read_file(stale) or { '' }) == 'keep'
	assert store.get_item(id)!.state == .trashed
}

// regression: public lookups reject unsafe ids before SQL/paths.
fn test_get_item_rejects_unsafe_id() {
	root := core_dir('get_unsafe_id')
	defer {
		core_cleanup(root)
	}
	store := open(os.join_path(root, 'trash')) or { panic(err) }
	for id in ['', '.', '..', '../x', 'x/y', 'x\\y', 'x\x00y'] {
		mut failed := false
		store.get_item(id) or { failed = true }
		assert failed, 'get_item must reject id `${id}`'
	}
}

// regression: fill_size never measures a path built from an unsafe id.
fn test_fill_size_ignores_unsafe_id() {
	root := core_dir('fill_unsafe_id')
	defer {
		core_cleanup(root)
	}
	store := open(os.join_path(root, 'trash')) or { panic(err) }
	entry := Entry{
		id:            '../../etc'
		original_path: '/etc'
		kind:          .dir
		state:         .trashed
	}
	got := store.fill_size(entry)
	assert !got.size_known
	assert got.size == 0
}

// regression: doctor reports an unsafe id but never purges it.
fn test_doctor_does_not_purge_invalid_id() {
	root := core_dir('doctor_invalid_id')
	defer {
		core_cleanup(root)
	}
	store := open(os.join_path(root, 'trash')) or { panic(err) }
	victim := os.join_path(root, 'victim')
	core_write(os.join_path(victim, 'keep.txt'), 'keep')
	core_insert(store, '../../victim', .trashed, os.join_path(root, 'x'))
	report := store.doctor(purge: true) or { panic(err) }
	assert report.purged == 0
	assert report.broken == 1
	assert report.items.len == 1
	assert report.items[0].action == 'skipped: invalid id'
	assert (os.read_file(os.join_path(victim, 'keep.txt')) or { '' }) == 'keep'
	assert store.all_items()!.len == 1
}

// regression: a failed rename must leave both the row and the payload.
fn test_doctor_purge_rename_failure_keeps_row_and_payload() {
	root := core_dir('doctor_purge_rename_fail')
	defer {
		core_cleanup(root)
	}
	store := open_with(os.join_path(root, 'trash'),
		id_gen: fn () string {
			return 'fixed-new-id'
		}
	) or { panic(err) }
	id := 'broken-item'
	os.mkdir_all(store.item_dir(id)) or { panic(err) }
	core_write(store.data_path(id), 'precious')
	core_insert(store, id, .pending, os.join_path(root, 'x'))
	// Occupying the destination makes renameat_noreplace fail with EEXIST.
	blocker := os.join_path(store.gc_dir(), 'doctor-${id}-fixed-new-id')
	core_write(blocker, 'blocker')

	report := store.doctor(purge: true) or { panic(err) }
	assert report.broken == 1
	assert report.purged == 0
	assert report.items[0].action == 'purge failed'
	assert (store.get_item(id) or { panic(err) }).id == id
	assert (os.read_file(store.data_path(id)) or { '' }) == 'precious'
	assert (os.read_file(blocker) or { '' }) == 'blocker'
}

// regression: a failed delete must not count the item as purged; the
// payload is already in .gc and must remain readable.
fn test_doctor_purge_delete_failure_keeps_payload() {
	root := core_dir('doctor_purge_delete_fail')
	defer {
		core_cleanup(root)
	}
	store := open(os.join_path(root, 'trash')) or { panic(err) }
	id := 'broken-item'
	os.mkdir_all(store.item_dir(id)) or { panic(err) }
	core_write(store.data_path(id), 'precious')
	core_insert(store, id, .pending, os.join_path(root, 'x'))
	os.setenv('TRASH_TEST_FAILPOINTS', '1', true)
	os.setenv('TRASH_FAILPOINT', 'index:delete-item', true)
	defer {
		os.unsetenv('TRASH_FAILPOINT')
		os.unsetenv('TRASH_TEST_FAILPOINTS')
	}

	report := store.doctor(purge: true) or { panic(err) }
	assert report.broken == 1
	assert report.purged == 0
	assert report.items[0].action == 'purge failed'
	assert (store.get_item(id) or { panic(err) }).id == id
	assert !os.exists(store.item_dir(id))
	mut moved := ''
	for entry in os.ls(store.gc_dir()) or { []string{} } {
		if entry.starts_with('doctor-${id}-') {
			moved = os.join_path(store.gc_dir(), entry)
		}
	}
	assert moved != ''
	assert (os.read_file(os.join_path(moved, 'data')) or { '' }) == 'precious'
}

// regression: an unsafe generated id must not move anything.
fn test_doctor_purge_rejects_unsafe_generated_id() {
	root := core_dir('doctor_purge_unsafe_id')
	defer {
		core_cleanup(root)
	}
	store := open_with(os.join_path(root, 'trash'),
		id_gen: fn () string {
			return '../escape'
		}
	) or { panic(err) }
	id := 'broken-item'
	os.mkdir_all(store.item_dir(id)) or { panic(err) }
	core_write(store.data_path(id), 'precious')
	core_insert(store, id, .pending, os.join_path(root, 'x'))

	report := store.doctor(purge: true) or { panic(err) }
	assert report.purged == 0
	assert report.items[0].action == 'purge failed'
	assert (store.get_item(id) or { panic(err) }).id == id
	assert (os.read_file(store.data_path(id)) or { '' }) == 'precious'
	assert !os.exists(os.join_path(root, 'escape'))
}
