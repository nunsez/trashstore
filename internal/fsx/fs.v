module fsx

import os
import internal.errs

// remove_any removes a file, symlink or directory tree if it exists.
pub fn remove_any(path string) ! {
	if !os.exists(path) && !os.is_link(path) {
		return
	}
	if os.is_link(path) || !os.is_dir(path) {
		os.rm(path)!
		return
	}
	os.rmdir_all(path)!
}

fn fsync_parent(path string) ! {
	fsync_dir(os.dir(path))!
}

fn C.read(fd int, buf voidptr, count u64) i64
fn C.write(fd int, buf voidptr, count u64) i64

fn fsync_path(path string) ! {
	fd := C.open(&char(path.str), C.O_RDONLY | C.O_CLOEXEC, 0)
	if fd < 0 {
		return errs.io_error('cannot open `${path}` for fsync: ${os.get_error_msg(C.errno)}')
	}
	defer {
		C.close(fd)
	}
	fsync_fd(fd, path)!
}

fn copy_file_sync(src string, dst string, mode u32) ! {
	$if macos {
		if !os.exists(dst) && !os.is_link(dst) {
			if C.clonefile(&char(src.str), &char(dst.str), 0) == 0 {
				fsync_path(dst)!
				os.chmod(dst, int(mode & 0o777))!
				return
			}
			e := C.errno
			if e != C.EXDEV && e != C.ENOTSUP && e != C.EINVAL && e != C.ENOSYS {
				return errs.io_error('clonefile `${src}` -> `${dst}`: ${os.get_error_msg(e)}')
			}
		}
	}
	in_fd := C.open(&char(src.str), C.O_RDONLY | C.O_CLOEXEC, 0)
	if in_fd < 0 {
		return errs.io_error('cannot open `${src}` for reading: ${os.get_error_msg(C.errno)}')
	}
	defer {
		C.close(in_fd)
	}
	out_fd := C.open(&char(dst.str), C.O_WRONLY | C.O_CREAT | C.O_EXCL | C.O_CLOEXEC, 0o600)
	if out_fd < 0 {
		return errs.io_error('cannot create `${dst}`: ${os.get_error_msg(C.errno)}')
	}
	defer {
		C.close(out_fd)
	}
	$if linux {
		mut copied := false
		for {
			n := C.copy_file_range(in_fd, unsafe { nil }, out_fd, unsafe { nil }, u64(1024 * 1024), 0)
			if n > 0 {
				continue
			}
			if n == 0 {
				copied = true
				break
			}
			e := C.errno
			if e == C.EINTR {
				continue
			}
			// EINVAL/ENOSYS/EXDEV: fall back to portable read/write below.
			if e == C.EINVAL || e == C.ENOSYS || e == C.EXDEV || e == C.EOPNOTSUPP {
				break
			}
			return errs.io_error('copy `${src}` -> `${dst}`: ${os.get_error_msg(e)}')
		}
		if copied {
			fsync_fd(out_fd, dst)!
			os.chmod(dst, int(mode & 0o777))!
			return
		}
	}
	mut buf := []u8{len: 1024 * 1024}
	for {
		n := C.read(in_fd, buf.data, u64(buf.len))
		if n < 0 {
			e := C.errno
			if e == C.EINTR {
				continue
			}
			return errs.io_error('read `${src}`: ${os.get_error_msg(e)}')
		}
		if n == 0 {
			break
		}
		mut off := 0
		for off < n {
			w := C.write(out_fd, unsafe { &buf[off] }, u64(n - off))
			if w < 0 {
				e := C.errno
				if e == C.EINTR {
					continue
				}
				return errs.io_error('write `${dst}`: ${os.get_error_msg(e)}')
			}
			off += int(w)
		}
	}
	fsync_fd(out_fd, dst)!
	os.chmod(dst, int(mode & 0o777))!
}

// copy_path_sync copies a file, symlink or directory tree without replacing dst.
pub fn copy_path_sync(src string, dst string) ! {
	st := os.lstat(src)!
	if os.is_link(src) {
		target := os.readlink(src)!
		os.symlink(target, dst)!
		fsync_parent(dst)!
		return
	}
	if os.is_dir(src) {
		// Populate with a permissive mode first; a directory with mode 000
		// could not receive its children.
		os.mkdir(dst, mode: 0o700)!
		for entry in os.ls(src)! {
			copy_path_sync(os.join_path(src, entry), os.join_path(dst, entry))!
		}
		fsync_dir(dst)!
		os.chmod(dst, int(st.mode & 0o777))!
		return
	}
	if !os.is_file(src) {
		return errs.unsupported_error('cannot copy special file `${src}` across filesystems')
	}
	copy_file_sync(src, dst, st.mode)!
}

// same_device reports whether src and dst share a filesystem.
pub fn same_device(src string, dst string) !bool {
	src_st := os.lstat(src)!
	dst_parent_st := os.stat(os.dir(dst))!
	return src_st.dev == dst_parent_st.dev
}

// move_path_sync renames src to dst without ever replacing dst. Across
// filesystems it copies to a unique temporary name, fsyncs, renames without
// replacement, and only then removes the source.
pub fn move_path_sync(src string, dst string, tmp_suffix string) ! {
	if same_device(src, dst)! {
		rename_noreplace(src, dst)!
		fsync_parent(src)!
		if os.dir(src) != os.dir(dst) {
			fsync_parent(dst)!
		}
		return
	}
	tmp := '${dst}.trash-tmp-${tmp_suffix}'
	defer {
		remove_any(tmp) or {}
	}
	remove_any(tmp) or {}
	copy_path_sync(src, tmp)!
	rename_noreplace(tmp, dst)!
	fsync_parent(dst)!
	remove_any(src)!
	fsync_parent(src)!
}
