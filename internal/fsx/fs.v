module fsx

import os
import internal.errs

// remove_any removes a file, symlink or directory tree if it exists. The
// parent is opened with O_NOFOLLOW and the removal itself is relative to that
// descriptor, so a component swapped for a symlink cannot redirect it.
pub fn remove_any(path string) ! {
	name := os.file_name(path)
	if name == '' || name == '.' || name == '..' {
		return errs.io_error('invalid path `${path}`')
	}
	parent_path := os.real_path(os.dir(path))
	mut parent := open_dir(parent_path)!
	defer {
		parent.close()
	}
	parent.remove_child_any(name, path)!
	parent.sync(parent_path)!
}

fn C.read(fd int, buf voidptr, count u64) i64
fn C.write(fd int, buf voidptr, count u64) i64

// copy_fds_sync copies between already-open descriptors. It never touches a
// path, so it can be used by dirfd-relative callers that must not follow a
// symlink swapped in after validation.
fn copy_fds_sync(in_fd int, out_fd int, mode u32, src string, dst string) ! {
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
			if C.fchmod(out_fd, int(mode & 0o777)) != 0 {
				return errs.io_error('cannot set mode on `${dst}`: ${os.get_error_msg(C.errno)}')
			}
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
	if C.fchmod(out_fd, int(mode & 0o777)) != 0 {
		return errs.io_error('cannot set mode on `${dst}`: ${os.get_error_msg(C.errno)}')
	}
}

// copy_path_sync copies a file, symlink or directory tree without replacing
// dst. Both parents are opened component by component with O_NOFOLLOW and the
// whole copy is descriptor-relative, so a path swapped for a symlink after it
// was validated cannot make the copy read or write outside those parents.
pub fn copy_path_sync(src string, dst string) ! {
	src_parent_path := os.real_path(os.dir(src))
	dst_parent_path := os.real_path(os.dir(dst))
	mut src_parent := open_dir(src_parent_path)!
	defer {
		src_parent.close()
	}
	mut dst_parent := open_dir(dst_parent_path)!
	defer {
		dst_parent.close()
	}
	src_name := os.file_name(src)
	dst_name := os.file_name(dst)
	src_parent.copy_child_tree(src_name, os.join_path(src_parent_path, src_name), dst_parent,
		dst_name, os.join_path(dst_parent_path, dst_name))!
	dst_parent.sync(dst_parent_path)!
}
