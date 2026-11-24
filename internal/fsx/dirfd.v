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
fn C.unlinkat(dirfd int, path &char, flags int) int

const enoent = 2
const eexist = 17
const enotdir = 20
const eloop = 62

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

// remove_child_any removes a file, symlink or directory tree below d. Every
// destructive call is relative to d.fd, so a component swapped for a symlink
// cannot redirect the removal. `path` is only used to enumerate the children of
// a directory; each unlink still goes through the descriptor of its parent.
// A missing child is not an error, so removal is idempotent.
pub fn (d Dir) remove_child_any(name string, path string) ! {
	if name == '' || name == '.' || name == '..' || name.contains('/') {
		return errs.io_error('invalid child name `${name}`')
	}
	child := d.open_child(name) or {
		e := err.code()
		if e == enoent {
			return
		}
		if e == enotdir || e == eloop {
			// A regular file or a symlink: unlink it without following it.
			if C.unlinkat(d.fd, &char(name.str), 0) != 0 {
				ue := C.errno
				if ue == enoent {
					return
				}
				return errs.io_error('cannot remove `${path}`: ${os.get_error_msg(ue)}')
			}
			return
		}
		return err
	}
	defer {
		child.close()
	}
	for entry in os.ls(path) or { []string{} } {
		child.remove_child_any(entry, os.join_path(path, entry))!
	}
	if C.unlinkat(d.fd, &char(name.str), C.AT_REMOVEDIR) != 0 {
		e := C.errno
		if e == enoent {
			return
		}
		return errs.io_error('cannot remove directory `${path}`: ${os.get_error_msg(e)}')
	}
}

// read_child reads a small regular file below d without following symlinks.
pub fn (d Dir) read_child(name string, max_bytes int) !string {
	fd := C.openat(d.fd, &char(name.str), C.O_RDONLY | C.O_NOFOLLOW | C.O_CLOEXEC, 0)
	if fd < 0 {
		e := C.errno
		return error_with_code('cannot open `${name}`: ${os.get_error_msg(e)}', e)
	}
	defer {
		C.close(fd)
	}
	mut buf := []u8{len: max_bytes + 1}
	n := C.read(fd, buf.data, u64(buf.len))
	if n < 0 {
		return errs.io_error('cannot read `${name}`: ${os.get_error_msg(C.errno)}')
	}
	if n > max_bytes {
		return errs.io_error('`${name}` is too large')
	}
	return buf[..int(n)].bytestr()
}

// write_child_new creates a new file below d and writes content to it. The
// file is created with O_EXCL|O_NOFOLLOW and fsynced, so a symlink cannot
// redirect the write and a stale marker is never silently reused.
pub fn (d Dir) write_child_new(name string, content string) ! {
	fd := C.openat(d.fd, &char(name.str), C.O_WRONLY | C.O_CREAT | C.O_EXCL | C.O_CLOEXEC | C.O_NOFOLLOW, 0o600)
	if fd < 0 {
		e := C.errno
		return error_with_code('cannot create `${name}`: ${os.get_error_msg(e)}', e)
	}
	defer {
		C.close(fd)
	}
	bytes := content.bytes()
	mut off := 0
	for off < bytes.len {
		w := C.write(fd, unsafe { &bytes[off] }, u64(bytes.len - off))
		if w < 0 {
			e := C.errno
			if e == C.EINTR {
				continue
			}
			return errs.io_error('cannot write `${name}`: ${os.get_error_msg(e)}')
		}
		off += int(w)
	}
	fsync_fd(fd, name)!
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
