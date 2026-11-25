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
fn C.fstatat(dirfd int, path &char, buf &C.stat, flags int) int
fn C.fstat(fd int, buf &C.stat) int
fn C.fchmod(fd int, mode int) int
fn C.symlinkat(target &char, newdirfd int, linkpath &char) int
fn C.readlinkat(dirfd int, path &char, buf &char, bufsiz u64) i64

// Errno values shared with callers that branch on the C error code. They are
// named here so restore/empty do not hard-code magic numbers.
pub const enoent = 2
pub const eexist = 17
pub const exdev = 18
pub const enotdir = 20
pub const eloop = 62

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
// The name must be a single, real path component: NUL, separators and the
// special `.`/`..` entries are rejected before they reach the C layer, where a
// NUL would silently truncate the name.
pub fn (d Dir) open_child(name string) !Dir {
	if !valid_child_name(name) {
		return errs.io_error('invalid child name `${name}`')
	}
	fd := C.openat(d.fd, &char(name.str), dir_open_flags(), 0)
	if fd < 0 {
		e := C.errno
		return error_with_code('cannot open child `${name}`: ${os.get_error_msg(e)}', e)
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
	if !valid_child_name(name) {
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

// child_exists reports whether a child name exists below d without following a
// symlink and without opening it. It is used to refuse a temporary path that we
// did not create, so cleanup never removes someone else's file.
pub fn (d Dir) child_exists(name string) bool {
	if !valid_child_name(name) {
		return false
	}
	mut st := C.stat{}
	return C.fstatat(d.fd, &char(name.str), &st, C.AT_SYMLINK_NOFOLLOW) == 0
}

// fd_is_regular reports whether fd refers to a regular file. It is used to
// reject a lock file that was replaced by a directory or a device node between
// open() and the first use of the descriptor.
pub fn fd_is_regular(fd int) bool {
	mut st := C.stat{}
	if C.fstat(fd, &st) != 0 {
		return false
	}
	return u32(st.st_mode) & s_ifmt == s_ifreg
}

// measure_child measures a payload below d. A regular file contributes its
// size, a directory contributes the sum of the regular files below it, and
// anything else (a symlink, a device node, a socket) contributes nothing. The
// child is stat'ed relative to the descriptor with AT_SYMLINK_NOFOLLOW, so a
// payload swapped for a symlink is never followed and cannot report a size that
// belongs to someone else. `path` is only used for messages and for listing a
// directory tree.
pub fn (d Dir) measure_child(name string, path string) !u64 {
	if !valid_child_name(name) {
		return errs.io_error('invalid child name `${name}`')
	}
	mut st := C.stat{}
	if C.fstatat(d.fd, &char(name.str), &st, C.AT_SYMLINK_NOFOLLOW) != 0 {
		e := C.errno
		return error_with_code('cannot stat `${path}`: ${os.get_error_msg(e)}', e)
	}
	match u32(st.st_mode) & s_ifmt {
		s_ifreg {
			return u64(st.st_size)
		}
		s_ifdir {
			child := d.open_child(name)!
			defer {
				child.close()
			}
			return child.measure_tree(path)
		}
		else {
			return 0
		}
	}
}

// measure_tree sums the apparent size of the regular files below d without
// following symlinks. `path` is only used to enumerate a directory; every stat
// and open is relative to the descriptor, so a child swapped for a symlink
// after it was listed cannot redirect the walk outside the tree.
pub fn (d Dir) measure_tree(path string) !u64 {
	names := os.ls(path) or { return err }
	mut total := u64(0)
	for name in names {
		if !valid_child_name(name) {
			continue
		}
		mut st := C.stat{}
		if C.fstatat(d.fd, &char(name.str), &st, C.AT_SYMLINK_NOFOLLOW) != 0 {
			e := C.errno
			if e == enoent {
				// The entry vanished between listing and stat.
				continue
			}
			return error_with_code('cannot stat `${path}/${name}`: ${os.get_error_msg(e)}', e)
		}
		match u32(st.st_mode) & s_ifmt {
			s_ifdir {
				child := d.open_child(name)!
				child_size := child.measure_tree(os.join_path(path, name)) or {
					child.close()
					return err
				}
				child.close()
				total += child_size
			}
			s_ifreg {
				total += u64(st.st_size)
			}
			else {}
		}
	}
	return total
}

// read_child reads a small regular file below d without following symlinks.
pub fn (d Dir) read_child(name string, max_bytes int) !string {
	if !valid_child_name(name) {
		return errs.io_error('invalid child name `${name}`')
	}
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
	if !valid_child_name(name) {
		return errs.io_error('invalid child name `${name}`')
	}
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

fn valid_child_name(name string) bool {
	return name != '' && name != '.' && name != '..' && !name.contains('/') && !name.contains('\x00')
}

const s_ifmt = 0o170000
const s_iflnk = 0o120000
const s_ifdir = 0o040000
const s_ifreg = 0o100000

// copy_child_tree copies src_name below d to dst_name below dst without
// following symlinks. src_path and dst_path are used only to enumerate the
// children of directories: every stat, open, create and unlink is relative to
// the already-open descriptors, so replacing either parent with a symlink
// cannot redirect the copy.
pub fn (d Dir) copy_child_tree(src_name string, src_path string, dst Dir, dst_name string, dst_path string) ! {
	if !valid_child_name(src_name) || !valid_child_name(dst_name) {
		return errs.io_error('invalid child name `${src_name}` -> `${dst_name}`')
	}
	mut st := C.stat{}
	if C.fstatat(d.fd, &char(src_name.str), &st, C.AT_SYMLINK_NOFOLLOW) != 0 {
		e := C.errno
		return error_with_code('cannot stat `${src_path}`: ${os.get_error_msg(e)}', e)
	}
	mode := u32(st.st_mode)
	match mode & s_ifmt {
		s_iflnk {
			mut buf := []u8{len: 4097}
			n := C.readlinkat(d.fd, &char(src_name.str), &char(buf.data), u64(buf.len - 1))
			if n < 0 {
				e := C.errno
				return error_with_code('cannot read symlink `${src_path}`: ${os.get_error_msg(e)}',
					e)
			}
			target := buf[..int(n)].bytestr()
			if C.symlinkat(&char(target.str), dst.fd, &char(dst_name.str)) != 0 {
				e := C.errno
				return error_with_code('cannot create symlink `${dst_path}`: ${os.get_error_msg(e)}',
					e)
			}
		}
		s_ifdir {
			if C.mkdirat(dst.fd, &char(dst_name.str), 0o700) != 0 {
				e := C.errno
				return error_with_code('cannot create directory `${dst_path}`: ${os.get_error_msg(e)}',
					e)
			}
			mut src_child := d.open_child(src_name)!
			defer {
				src_child.close()
			}
			mut dst_child := dst.open_child(dst_name)!
			defer {
				dst_child.close()
			}
			for entry in os.ls(src_path) or {
				return errs.io_error('cannot list `${src_path}`: ${err.msg()}')
			} {
				src_child.copy_child_tree(entry, os.join_path(src_path, entry), dst_child,
					entry, os.join_path(dst_path, entry))!
			}
			if C.fchmod(dst_child.fd, int(mode & 0o777)) != 0 {
				e := C.errno
				return errs.io_error('cannot set mode on `${dst_path}`: ${os.get_error_msg(e)}')
			}
			dst_child.sync(dst_path)!
		}
		s_ifreg {
			in_fd := C.openat(d.fd, &char(src_name.str), C.O_RDONLY | C.O_NOFOLLOW | C.O_CLOEXEC, 0)
			if in_fd < 0 {
				e := C.errno
				return error_with_code('cannot open `${src_path}` for reading: ${os.get_error_msg(e)}',
					e)
			}
			defer {
				C.close(in_fd)
			}
			out_fd := C.openat(dst.fd, &char(dst_name.str), C.O_WRONLY | C.O_CREAT | C.O_EXCL | C.O_CLOEXEC | C.O_NOFOLLOW, 0o600)
			if out_fd < 0 {
				e := C.errno
				return error_with_code('cannot create `${dst_path}`: ${os.get_error_msg(e)}',
					e)
			}
			defer {
				C.close(out_fd)
			}
			copy_fds_sync(in_fd, out_fd, mode, src_path, dst_path)!
		}
		else {
			return errs.unsupported_error('cannot copy special file `${src_path}` across filesystems')
		}
	}
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
