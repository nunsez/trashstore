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

fn test_copy_child_tree_preserves_tree_and_symlinks() ! {
	root := dirfd_root('copy_tree')
	defer {
		os.rmdir_all(root) or {}
	}
	src := os.join_path(root, 'src')
	os.mkdir_all(os.join_path(src, 'sub'))!
	os.write_file(os.join_path(src, 'a.txt'), 'a')!
	os.write_file(os.join_path(src, 'sub', 'b.txt'), 'b')!
	outside := os.join_path(root, 'outside.txt')
	os.write_file(outside, 'outside')!
	os.symlink(outside, os.join_path(src, 'link'))!
	dst := os.join_path(root, 'dst')
	os.mkdir(dst)!

	src_dir := open_dir(root)!
	defer {
		src_dir.close()
	}
	dst_dir := open_dir(dst)!
	defer {
		dst_dir.close()
	}
	src_dir.copy_child_tree('src', src, dst_dir, 'copy', os.join_path(dst, 'copy'))!

	copy := os.join_path(dst, 'copy')
	assert os.read_file(os.join_path(copy, 'a.txt'))! == 'a'
	assert os.read_file(os.join_path(copy, 'sub', 'b.txt'))! == 'b'
	assert os.is_link(os.join_path(copy, 'link'))
	assert os.readlink(os.join_path(copy, 'link'))! == outside
	// The symlink must be recreated, not followed.
	assert !os.exists(os.join_path(copy, 'outside.txt'))
}

fn test_copy_child_tree_ignores_swapped_parent_symlink() ! {
	root := dirfd_root('copy_swap')
	defer {
		os.rmdir_all(root) or {}
	}
	item := os.join_path(root, 'item')
	os.mkdir(item)!
	os.write_file(os.join_path(item, 'data'), 'real')!
	victim := os.join_path(root, 'victim')
	os.mkdir(victim)!
	os.write_file(os.join_path(victim, 'data'), 'victim')!
	dst := os.join_path(root, 'dst')
	os.mkdir(dst)!

	src_dir := open_dir(item)!
	defer {
		src_dir.close()
	}
	dst_dir := open_dir(dst)!
	defer {
		dst_dir.close()
	}
	// Replace the path we validated with a symlink to the victim while the
	// descriptor still points at the real item directory.
	os.mv(item, os.join_path(root, 'item-original'))!
	os.symlink(victim, item)!

	src_dir.copy_child_tree('data', os.join_path(item, 'data'), dst_dir, 'data',
		os.join_path(dst, 'data'))!
	assert os.read_file(os.join_path(dst, 'data'))! == 'real'
	assert os.read_file(os.join_path(victim, 'data'))! == 'victim'
}
