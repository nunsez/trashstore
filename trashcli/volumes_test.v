module trashcli

import internal.pathx
import os

fn test_volume_store_root_name() {
	assert volume_store_root('/mnt/disk', 501) == '/mnt/disk/.trashstore-501'
}

fn test_mount_point_is_a_prefix() {
	root := vol_dir('vol_mount')
	defer {
		vol_cleanup(root)
	}
	file := os.join_path(root, 'a.txt')
	vol_write(file, 'x')
	file_mount := mount_point(file) or { panic(err) }
	root_mount := mount_point(root) or { panic(err) }
	assert file_mount == root_mount
	assert pathx.is_path_within(pathx.canonical_target_path(file), file_mount)
}

fn test_check_not_mount_point() {
	mut failed := false
	check_not_mount_point('/') or { failed = true }
	assert failed

	root := vol_dir('vol_not_mount')
	defer {
		vol_cleanup(root)
	}
	file := os.join_path(root, 'a.txt')
	vol_write(file, 'x')
	check_not_mount_point(file) or { panic(err) }
}

fn test_target_store_root_uses_home_store_on_same_device() {
	root := vol_dir('vol_target_home')
	defer {
		vol_cleanup(root)
	}
	home := os.join_path(root, 'home')
	os.mkdir_all(home) or { panic(err) }
	file := os.join_path(root, 'a.txt')
	vol_write(file, 'x')
	chosen := target_store_root(file, home, os.stat(home) or { panic(err) }.dev) or {
		panic(err)
	}
	assert chosen.root == home
	assert chosen.mount == ''
}

fn test_volume_registry_roundtrip() {
	root := vol_dir('vol_registry')
	defer {
		vol_cleanup(root)
	}
	home := os.join_path(root, 'home')
	mount := os.join_path(root, 'mnt')
	store := os.join_path(mount, '.trashstore-501')
	os.mkdir_all(home) or { panic(err) }
	os.mkdir_all(store) or { panic(err) }
	record := VolumeRecord{
		dev:   42
		mount: mount
		root:  store
	}
	register_volume(home, record) or { panic(err) }
	register_volume(home, record) or { panic(err) }

	records := read_volume_records(home)
	assert records.len == 1
	assert records[0].dev == 42
	assert records[0].mount == mount
	assert records[0].root == store
	assert registered_roots(home) == [store]
	// The registry is replaced under an exclusive lock and its temporary file
	// never survives a successful write.
	assert os.exists('${volumes_file(home)}.lock')
	for name in os.ls(home) or { []string{} } {
		assert !name.contains('.tmp-'), 'leftover registry temporary `${name}`'
	}
}

fn test_roots_for_read_explicit_store() {
	path := os.join_path(os.temp_dir(), 'trash-explicit-read')
	cli := Cli.parse(['trash', '--store', path, 'list']) or { panic(err) }
	spec := resolve_store_spec(path) or { panic(err) }
	roots := roots_for_read(spec, cli, os.temp_dir(), 0)
	assert roots == [pathx.canonical_path(path)]
}

fn test_roots_for_read_includes_registered_volumes() {
	root := vol_dir('vol_roots')
	defer {
		vol_cleanup(root)
	}
	home := os.join_path(root, 'home')
	mount := os.join_path(root, 'mnt')
	store := os.join_path(mount, '.trashstore-501')
	os.mkdir_all(home) or { panic(err) }
	os.mkdir_all(store) or { panic(err) }
	register_volume(home, VolumeRecord{
		dev:   42
		mount: mount
		root:  store
	}) or { panic(err) }

	cli := Cli.parse(['trash', 'stats']) or { panic(err) }
	spec := StoreSpec{
		root: home
	}
	roots := roots_for_read(spec, cli, root, os.stat(home) or { panic(err) }.dev)
	assert home in roots
	assert store in roots

	list_cli := Cli.parse(['trash', 'list']) or { panic(err) }
	list_roots := roots_for_read(spec, list_cli, root, os.stat(home) or { panic(err) }.dev)
	assert list_roots == [home]
}

fn vol_dir(name string) string {
	path := os.join_path(os.temp_dir(), 'trash_vol_${name}_${os.getpid()}')
	os.mkdir_all(path) or { panic(err) }
	return path
}

fn vol_cleanup(path string) {
	os.rmdir_all(path) or {}
}

fn vol_write(path string, content string) {
	os.write_file(path, content) or { panic(err) }
}
