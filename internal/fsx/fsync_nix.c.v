module fsx

import os
import internal.errs

#flag -D_GNU_SOURCE
#include <fcntl.h>
#include <sys/file.h>
#include <unistd.h>

fn C.open(path &char, flags int, ...int) int
fn C.close(fd int) int
fn C.fsync(fd int) int
fn C.flock(fd int, operation int) int

// is_unsupported_fsync_error reports whether fsync failed because the
// filesystem cannot flush this kind of descriptor, rather than because the
// write itself failed. Network filesystems (NFS, SMB) commonly return EINVAL or
// ENOTSUP for a directory; treating that as a hard error would make every
// command fail on such a mount even though the metadata was written.
pub fn is_unsupported_fsync_error(errno int) bool {
	return errno == C.EINVAL || errno == C.ENOTSUP || errno == C.EOPNOTSUPP
}

// fsync_fd retries EINTR and reports the path on failure. An unsupported fsync
// is not an error: the descriptor was opened and written, only the durability
// guarantee is weaker on that filesystem.
pub fn fsync_fd(fd int, path string) ! {
	for {
		if C.fsync(fd) == 0 {
			return
		}
		e := C.errno
		if e == C.EINTR {
			continue
		}
		if is_unsupported_fsync_error(e) {
			return
		}
		return errs.io_error('fsync `${path}`: ${os.get_error_msg(e)}')
	}
}

// fsync_dir flushes directory metadata so renames/creations survive a crash.
pub fn fsync_dir(path string) ! {
	fd := C.open(&char(path.str), C.O_RDONLY | C.O_CLOEXEC, 0)
	if fd < 0 {
		return errs.io_error('cannot open directory `${path}` for fsync: ${os.get_error_msg(C.errno)}')
	}
	defer {
		C.close(fd)
	}
	fsync_fd(fd, path)!
}

// FileLock is an advisory flock on a store lock file. It owns the descriptor,
// so callers never need to touch C.open/C.flock directly.
pub struct FileLock {
mut:
	fd   int = -1
	path string
}

// open_lock opens path with O_NOFOLLOW and rejects anything that is not a
// regular file, so a directory or a device node cannot stand in for the lock.
// It creates the file when it is missing.
pub fn open_lock(path string) !FileLock {
	fd := C.open(&char(path.str), C.O_RDWR | C.O_CREAT | C.O_CLOEXEC | C.O_NOFOLLOW, 0o600)
	return lock_from_fd(fd, path)
}

// open_lock_existing is open_lock without O_CREAT. It is used by callers that
// promised not to create any file in the store (open_with(create:false)).
pub fn open_lock_existing(path string) !FileLock {
	fd := C.open(&char(path.str), C.O_RDWR | C.O_CLOEXEC | C.O_NOFOLLOW, 0)
	return lock_from_fd(fd, path)
}

fn lock_from_fd(fd int, path string) !FileLock {
	if fd < 0 {
		return errs.io_error('cannot open lock file `${path}`: ${os.get_error_msg(C.errno)}')
	}
	if !fd_is_regular(fd) {
		C.close(fd)
		return errs.invalid_target_error('lock file `${path}` must be a regular file')
	}
	return FileLock{
		fd:   fd
		path: path
	}
}

// lock_shared takes a shared advisory lock.
pub fn (mut l FileLock) lock_shared() ! {
	if C.flock(l.fd, C.LOCK_SH) != 0 {
		return errs.io_error('cannot acquire shared lock on `${l.path}`: ${os.get_error_msg(C.errno)}')
	}
}

// lock_exclusive takes an exclusive advisory lock, blocking until it is free.
pub fn (mut l FileLock) lock_exclusive() ! {
	if C.flock(l.fd, C.LOCK_EX) != 0 {
		return errs.io_error('cannot acquire exclusive lock on `${l.path}`: ${os.get_error_msg(C.errno)}')
	}
}

// try_lock_exclusive takes an exclusive advisory lock without blocking. It
// reports false when another process holds the lock.
pub fn (mut l FileLock) try_lock_exclusive() bool {
	return C.flock(l.fd, C.LOCK_EX | C.LOCK_NB) == 0
}

// release unlocks and closes the descriptor. It is idempotent.
pub fn (mut l FileLock) release() {
	if l.fd >= 0 {
		C.flock(l.fd, C.LOCK_UN)
		C.close(l.fd)
		l.fd = -1
	}
}
