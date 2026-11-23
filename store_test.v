module trash

import internal.fsx
import json2
import os
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

fn core_meta(store Store, id string) Meta {
	return store.read_meta(id) or { panic(err) }
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
	assert os.is_dir(store.inflight_dir())
	assert os.is_dir(store.gc_dir())
	assert os.exists(store.lock_path())
}

fn test_put_file_moves_payload_and_writes_meta() {
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
	assert entry.size == 5
	assert !os.exists(file)
	assert (os.read_file(store.data_path(entry.id)) or { '' }) == 'hello'
	meta := core_meta(store, entry.id)
	assert meta.state == 'trashed'
	assert percent_decode_path(meta.original_path) or { '' } == file
	assert meta.restore_to == ''
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
	item := store.item_dir(id)
	os.mkdir_all(item) or { panic(err) }
	core_write(store.meta_path(id), 'not json')
	assert store.list().len == 0

	// metadata says trashed, but payload is missing
	file := os.join_path(root, 'a.txt')
	core_write(file, 'a')
	entry := core_put(store, file, false)
	os.rm(store.data_path(entry.id)) or { panic(err) }
	assert store.list().len == 0
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
	count := store.empty_wait(true) or { panic(err) }
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
	os.setenv('TRASH_TEST_FAILPOINTS', '1', true)
	os.setenv('TRASH_FAILPOINT', 'restore:after-move', true)
	defer {
		os.unsetenv('TRASH_FAILPOINT')
		os.unsetenv('TRASH_TEST_FAILPOINTS')
	}
	mut failed := false
	store.restore(entry.id) or { failed = true }
	assert failed
	os.unsetenv('TRASH_FAILPOINT')
	store.recover_if_needed() or { panic(err) }
	assert (os.read_file(file) or { '' }) == 'x'
	assert store.list().len == 0
	assert !os.exists('${file}~1')
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

fn test_failpoint_empty_after_detach_is_recovered() {
	root := core_dir('failpoint_empty')
	defer {
		core_cleanup(root)
	}
	store := open(os.join_path(root, 'trash')) or { panic(err) }
	file := os.join_path(root, 'a.txt')
	core_write(file, 'x')
	core_put(store, file, false)
	os.setenv('TRASH_TEST_FAILPOINTS', '1', true)
	os.setenv('TRASH_FAILPOINT', 'empty:after-detach', true)
	defer {
		os.unsetenv('TRASH_FAILPOINT')
		os.unsetenv('TRASH_TEST_FAILPOINTS')
	}
	mut failed := false
	store.empty() or { failed = true }
	assert failed
	os.unsetenv('TRASH_FAILPOINT')
	store2 := open(store.root) or { panic(err) }
	store2.recover_if_needed() or { panic(err) }
	assert store2.list().len == 0
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

fn test_doctor_recovers_invalid_metadata() {
	root := core_dir('doctor_invalid_meta')
	defer {
		core_cleanup(root)
	}
	store := open(os.join_path(root, 'trash')) or { panic(err) }
	id := 'doctor-invalid-meta'
	item := store.item_dir(id)
	os.mkdir_all(item) or { panic(err) }
	core_write(store.data_path(id), 'x')
	os.write_file(store.meta_path(id), '{not json') or { panic(err) }

	report := store.doctor(repair: true) or { panic(err) }
	assert report.repaired == 1
	entry := store.list()[0]
	assert entry.id == id
	assert entry.original_path.ends_with('/recovered/${id}')
}

fn test_doctor_repairs_invalid_metadata_fields() {
	root := core_dir('doctor_invalid_fields')
	defer {
		core_cleanup(root)
	}
	store := open(os.join_path(root, 'trash')) or { panic(err) }
	id := 'doctor-invalid-fields'
	item := store.item_dir(id)
	os.mkdir_all(item) or { panic(err) }
	core_write(store.data_path(id), 'x')
	meta := Meta{
		id:            id
		state:         'bogus'
		original_path: '%ZZ'
		trashed_at:    'not-a-time'
		kind:          'bogus'
	}
	store.write_meta_atomic(item, meta) or { panic(err) }

	report := store.doctor(repair: true) or { panic(err) }
	assert report.repaired == 1
	entry := store.list()[0]
	assert entry.state == .trashed
	assert entry.kind == .file
	assert entry.original_path.ends_with('/recovered/${id}')
}

fn test_doctor_repairs_pending_item() {
	root := core_dir('doctor_pending')
	defer {
		core_cleanup(root)
	}
	store := open(os.join_path(root, 'trash')) or { panic(err) }
	id := 'doctor-pending'
	item := store.item_dir(id)
	os.mkdir_all(item) or { panic(err) }
	core_write(store.data_path(id), 'x')
	meta := Meta{
		id:            id
		state:         'pending'
		original_path: percent_encode_path(os.join_path(root, 'a.txt'))
		trashed_at:    time.now().format_rfc3339()
		kind:          'file'
	}
	store.write_meta_atomic(item, meta) or { panic(err) }

	report := store.doctor(repair: true) or { panic(err) }
	assert report.repaired == 1
	assert core_meta(store, id).state == 'trashed'
	assert store.list().len == 1
}

fn test_recover_put_pending_with_data() {
	root := core_dir('recover_put_ok')
	defer {
		core_cleanup(root)
	}
	store := open(os.join_path(root, 'trash')) or { panic(err) }
	id := 'recover-put-ok'
	item := store.item_dir(id)
	os.mkdir_all(item) or { panic(err) }
	core_write(store.data_path(id), 'x')
	meta := Meta{
		id:            id
		state:         'pending'
		original_path: percent_encode_path(os.join_path(root, 'a.txt'))
		trashed_at:    time.now().format_rfc3339()
		kind:          'file'
		size:          1
	}
	store.write_meta_atomic(item, meta) or { panic(err) }
	marker := store.create_marker('put', id) or { panic(err) }

	store.recover() or { panic(err) }
	assert core_meta(store, id).state == 'trashed'
	assert !os.exists(marker)
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
	meta := Meta{
		id:            id
		state:         'pending'
		original_path: percent_encode_path(os.join_path(root, 'a.txt'))
		trashed_at:    time.now().format_rfc3339()
		kind:          'file'
	}
	store.write_meta_atomic(item, meta) or { panic(err) }
	store.create_marker('put', id) or { panic(err) }

	store.recover() or { panic(err) }
	assert !os.is_dir(item)
}

fn test_recover_restore_with_data_rolls_back_to_trashed() {
	root := core_dir('recover_restore_data')
	defer {
		core_cleanup(root)
	}
	store := open(os.join_path(root, 'trash')) or { panic(err) }
	id := 'recover-restore-data'
	item := store.item_dir(id)
	os.mkdir_all(item) or { panic(err) }
	core_write(store.data_path(id), 'x')
	meta := Meta{
		id:            id
		state:         'restoring'
		original_path: percent_encode_path(os.join_path(root, 'a.txt'))
		trashed_at:    time.now().format_rfc3339()
		kind:          'file'
		restore_to:    percent_encode_path(os.join_path(root, 'a.txt'))
	}
	store.write_meta_atomic(item, meta) or { panic(err) }
	store.create_marker('restore', id) or { panic(err) }

	store.recover() or { panic(err) }
	meta_after := core_meta(store, id)
	assert meta_after.state == 'trashed'
	assert meta_after.restore_to == ''
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
	meta := Meta{
		id:            id
		state:         'restoring'
		original_path: percent_encode_path(target)
		trashed_at:    time.now().format_rfc3339()
		kind:          'file'
		restore_to:    percent_encode_path(target)
		data_dev:      st.dev
		data_ino:      st.inode
	}
	store.write_meta_atomic(item, meta) or { panic(err) }
	store.create_marker('restore', id) or { panic(err) }
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
	meta := Meta{
		id:            id
		state:         'restoring'
		original_path: percent_encode_path(target)
		trashed_at:    time.now().format_rfc3339()
		kind:          'file'
		restore_to:    percent_encode_path(target)
		data_dev:      data_st.dev
		data_ino:      data_st.inode
		target_dev:    target_st.dev
		target_ino:    target_st.inode
	}
	store.write_meta_atomic(item, meta) or { panic(err) }
	store.create_marker('restore', id) or { panic(err) }

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
	meta := Meta{
		id:            id
		state:         'restoring'
		original_path: percent_encode_path(os.join_path(root, 'a.txt'))
		trashed_at:    time.now().format_rfc3339()
		kind:          'file'
		restore_to:    percent_encode_path(os.join_path(root, 'a.txt'))
	}
	store.write_meta_atomic(item, meta) or { panic(err) }
	store.create_marker('restore', id) or { panic(err) }

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
	store.create_marker('empty', id) or { panic(err) }

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
	meta := core_meta(store, entry.id)
	assert percent_decode_path(meta.original_path) or { '' } == file
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

fn test_recover_keeps_orphan_payload_without_meta() {
	root := core_dir('recover_orphan')
	defer {
		core_cleanup(root)
	}
	store := open(os.join_path(root, 'trash')) or { panic(err) }
	id := 'recover-orphan'
	item := store.item_dir(id)
	os.mkdir_all(item) or { panic(err) }
	core_write(store.data_path(id), 'precious')
	store.create_marker('put', id) or { panic(err) }

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
		item := store.item_dir(id)
		os.mkdir_all(item) or { panic(err) }
		core_write(store.data_path(id), 'x')
		meta := Meta{
			id:            id
			state:         'trashed'
			original_path: percent_encode_path(os.join_path(root, '${id}.txt'))
			trashed_at:    time.now().format_rfc3339()
			kind:          'file'
			size:          1
		}
		store.write_meta_atomic(item, meta) or { panic(err) }
	}
	mut failed := false
	store.find('aaa') or { failed = true }
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
		fsx.copy_path_sync(src, dst, true) or { panic(err) }
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
	bad_item := store.item_dir(bad_id)
	os.mkdir_all(bad_item) or { panic(err) }
	core_write(store.meta_path(bad_id), 'not json')

	scan := store.scan()
	assert scan.entries.len == 1
	assert scan.entries[0].id == entry.id
	assert scan.broken.len == 1
	assert scan.broken[0].id == bad_id
}

fn test_meta_id_mismatch_is_rejected() {
	root := core_dir('meta_mismatch')
	defer {
		core_cleanup(root)
	}
	store := open(os.join_path(root, 'trash')) or { panic(err) }
	id := 'item-id'
	item := store.item_dir(id)
	os.mkdir_all(item) or { panic(err) }
	core_write(store.data_path(id), 'x')
	meta := Meta{
		id:            'other-id'
		state:         'trashed'
		original_path: percent_encode_path(os.join_path(root, 'x'))
		trashed_at:    time.now().format_rfc3339()
		kind:          'file'
		size:          1
	}
	store.write_meta_atomic(item, meta) or { panic(err) }
	mut failed := false
	store.read_meta(id) or { failed = true }
	assert failed
	assert store.scan().broken.len == 1
}

fn test_meta_unknown_state_is_rejected() {
	root := core_dir('meta_state')
	defer {
		core_cleanup(root)
	}
	store := open(os.join_path(root, 'trash')) or { panic(err) }
	id := 'item-state'
	item := store.item_dir(id)
	os.mkdir_all(item) or { panic(err) }
	core_write(store.data_path(id), 'x')
	meta := Meta{
		id:            id
		state:         'garbage'
		original_path: percent_encode_path(os.join_path(root, 'x'))
		trashed_at:    time.now().format_rfc3339()
		kind:          'file'
		size:          1
	}
	store.write_meta_atomic(item, meta) or { panic(err) }
	assert store.scan().broken.len == 1
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
		item := store.item_dir(id)
		os.mkdir_all(item) or { panic(err) }
		core_write(store.data_path(id), 'x')
		meta := Meta{
			id:            id
			state:         'trashed'
			original_path: percent_encode_path(os.join_path(root, '${id}.txt'))
			trashed_at:    time.now().format_rfc3339()
			kind:          'file'
			size:          1
		}
		store.write_meta_atomic(item, meta) or { panic(err) }
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
	mut meta := core_meta(store, entry.id)
	meta.state = 'pending'
	store.write_meta(entry.id, meta) or { panic(err) }
	store.create_marker('put', entry.id) or { panic(err) }
	report := store.recover_if_needed() or { panic(err) }
	assert report.recovered == 1
	assert core_meta(store, entry.id).state == 'trashed'
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
	fsx.copy_path_sync(src, dst, true) or { panic(err) }
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
	mut meta := core_meta(store, entry.id)
	meta.state = 'restoring'
	meta.restore_to = percent_encode_path(file)
	store.write_meta(entry.id, meta) or { panic(err) }
	store.create_marker('restore', entry.id) or { panic(err) }
	stale := '${file}.trash-tmp-${entry.id}'
	core_write(stale, 'partial')
	store.recover() or { panic(err) }
	assert !os.exists(stale)
	assert core_meta(store, entry.id).state == 'trashed'
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
	assert stats.size == u64(15)
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

fn test_empty_defers_gc_until_requested() {
	root := core_dir('empty_defer')
	defer {
		core_cleanup(root)
	}
	store := open(os.join_path(root, 'trash')) or { panic(err) }
	file := os.join_path(root, 'a.txt')
	core_write(file, 'x')
	core_put(store, file, false)
	assert (store.empty() or { panic(err) }) == 1
	assert (os.ls(store.items_dir()) or { []string{} }).len == 0
	assert (os.ls(store.gc_dir()) or { []string{} }).len > 0
	store.gc() or { panic(err) }
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
	fsx.copy_path_sync(src, dst, true) or { failed = true }
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

fn test_open_with_can_disable_sync() {
	root := core_dir('no_sync')
	defer {
		core_cleanup(root)
	}
	store := open_with(os.join_path(root, 'trash'), sync: false) or { panic(err) }
	assert !store.sync
	file := os.join_path(root, 'a.txt')
	core_write(file, 'x')
	entry := core_put(store, file, false)
	assert store.scan().entries.len == 1
	assert entry.original_path == file
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

fn test_meta_json_random_input_does_not_panic() {
	alphabet := '{}[]",:0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ \n'
	mut state := u64(0xdeadbeefcafebabe)
	for _ in 0 .. 1000 {
		state = state * 6364136223846793005 + 1442695040888963407
		length := int((state >> 32) % 80)
		mut bytes := []u8{cap: length}
		for _ in 0 .. length {
			state = state * 6364136223846793005 + 1442695040888963407
			bytes << alphabet[int((state >> 24) % alphabet.len)]
		}
		json2.decode[Meta](bytes.bytestr()) or {}
	}
}
