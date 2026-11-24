module fsx

import internal.errs
import os

#flag -D_GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

fn C.openat(dirfd int, path &char, flags int, ...int) int
fn C.mkdirat(dirfd int, path &char, mode int) int

const enoent = 2
const eexist = 17

fn dir_open_flags() int {
	return C.O_RDONLY | C.O_DIRECTORY | C.O_NOFOLLOW | C.O_CLOEXEC
}

// Dir is an open directory descriptor. Paths are resolved one component at a
// time with O_NOFOLLOW, so a component that is (or becomes) a symlink cannot
// redirect an operation outside the directory that was validated.
pub struct Dir {
pub:
	fd int
}

// close releases the descriptor.
pub fn (d Dir) close() {
	C.close(d.fd)
}

// sync flushes the directory metadata. `label` is only used in error messages.
pub fn (d Dir) sync(label string) ! {
	fsync_fd(d.fd, label)!
}

// open_child opens a subdirectory relative to d without following symlinks.
pub fn (d Dir) open_child(name string) !Dir {
	fd := C.openat(d.fd, &char(name.str), dir_open_flags(), 0)
	if fd < 0 {
		e := C.errno
		return error_with_code('cannot open `${name}` in `${d.fd}`: ${os.get_error_msg(e)}',
			e)
	}
	return Dir{
		fd: fd
	}
}

// open_dir opens an absolute, canonical path by walking its components from
// `/`. Every component must be a real directory: a symlink makes it fail with
// ELOOP, so callers must resolve legitimate symlinks (e.g. /tmp on macOS)
// before calling.
pub fn open_dir(path string) !Dir {
	if !path.starts_with('/') {
		return errs.io_error('expected an absolute directory path, got `${path}`')
	}
	mut dir := open_root()!
	for component in path.split('/') {
		if component == '' {
			continue
		}
		child := dir.open_child(component) or {
			dir.close()
			return err
		}
		dir.close()
		dir = child
	}
	return dir
}

// open_or_create_dir is open_dir that creates missing components with mkdirat,
// so the parents of a restored path can be recreated without path races.
pub fn open_or_create_dir(path string) !Dir {
	if !path.starts_with('/') {
		return errs.io_error('expected an absolute directory path, got `${path}`')
	}
	mut dir := open_root()!
	for component in path.split('/') {
		if component == '' {
			continue
		}
		child := dir.open_child(component) or {
			if err.code() != enoent {
				dir.close()
				return err
			}
			if C.mkdirat(dir.fd, &char(component.str), 0o700) != 0 {
				e := C.errno
				if e != eexist {
					dir.close()
					return error_with_code('cannot create directory `${component}`: ${os.get_error_msg(e)}',
						e)
				}
			}
			created := dir.open_child(component) or {
				dir.close()
				return err
			}
			created
		}
		dir.close()
		dir = child
	}
	return dir
}

fn open_root() !Dir {
	root := '/'
	fd := C.open(&char(root.str), dir_open_flags(), 0)
	if fd < 0 {
		return errs.io_error('cannot open `/`: ${os.get_error_msg(C.errno)}')
	}
	return Dir{
		fd: fd
	}
}
