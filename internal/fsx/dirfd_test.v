module fsx

import os

fn dirfd_root(name string) string {
	base := os.real_path(os.temp_dir())
	root := os.join_path(base, 'fsx_${name}_${os.getpid()}')
	os.rmdir_all(root) or {}
	os.mkdir_all(root) or { panic(err) }
	return os.real_path(root)
}

fn test_open_dir_rejects_symlink_component() ! {
	root := dirfd_root('open_symlink')
	defer {
		os.rmdir_all(root) or {}
	}
	real := os.join_path(root, 'real')
	os.mkdir(real)!
	os.mkdir(os.join_path(real, 'sub'))!
	os.symlink(real, os.join_path(root, 'link'))!

	dir := open_dir(real)!
	dir.close()
	child := open_dir(os.join_path(real, 'sub'))!
	child.close()

	mut failed := false
	open_dir(os.join_path(root, 'link', 'sub')) or { failed = true }
	assert failed, 'open_dir must not follow a symlink component'
}

fn test_open_or_create_dir_creates_missing_components() ! {
	root := dirfd_root('create')
	defer {
		os.rmdir_all(root) or {}
	}
	deep := os.join_path(root, 'a', 'b', 'c')
	dir := open_or_create_dir(deep)!
	dir.close()
	assert os.is_dir(deep)

	again := open_or_create_dir(deep)!
	again.close()
}

fn test_renameat_noreplace_refuses_existing_destination() ! {
	root := dirfd_root('renameat')
	defer {
		os.rmdir_all(root) or {}
	}
	src_dir := os.join_path(root, 'src')
	dst_dir := os.join_path(root, 'dst')
	os.mkdir(src_dir)!
	os.mkdir(dst_dir)!
	os.write_file(os.join_path(src_dir, 'a'), 'new')!
	os.write_file(os.join_path(dst_dir, 'a'), 'old')!

	src := open_dir(src_dir)!
	defer {
		src.close()
	}
	dst := open_dir(dst_dir)!
	defer {
		dst.close()
	}
	mut failed := false
	renameat_noreplace(src.fd, 'a', dst.fd, 'a') or {
		assert err.code() == eexist
		failed = true
	}
	assert failed
	assert os.read_file(os.join_path(dst_dir, 'a'))! == 'old'

	renameat_noreplace(src.fd, 'a', dst.fd, 'b')!
	assert !os.exists(os.join_path(src_dir, 'a'))
	assert os.read_file(os.join_path(dst_dir, 'b'))! == 'new'
}
