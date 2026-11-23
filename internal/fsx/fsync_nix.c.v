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

// fsync_fd retries EINTR and reports the path on failure.
pub fn fsync_fd(fd int, path string) ! {
	for {
		if C.fsync(fd) == 0 {
			return
		}
		e := C.errno
		if e == C.EINTR {
			continue
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
