module fsx

#flag -D_GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <unistd.h>

fn C.renameat2(oldfd int, oldpath &char, newfd int, newpath &char, flags u32) int
fn C.strerror(errnum int) &char

// rename_noreplace renames src to dst only if dst does not exist.
// There is deliberately no check-then-rename fallback: if the platform or
// filesystem cannot provide the guarantee, the operation fails.
pub fn rename_noreplace(src string, dst string) ! {
	rc := C.renameat2(C.AT_FDCWD, &char(src.str), C.AT_FDCWD, &char(dst.str), u32(1))
	if rc != 0 {
		errno := C.errno
		return error_with_code('cannot rename `${src}` to `${dst}` without replacing: ${unsafe {
			cstring_to_vstring(C.strerror(errno))
		}}', errno)
	}
}

// renameat_noreplace is rename_noreplace relative to two directory descriptors.
pub fn renameat_noreplace(old_dirfd int, old_name string, new_dirfd int, new_name string) ! {
	rc := C.renameat2(old_dirfd, &char(old_name.str), new_dirfd, &char(new_name.str),
		u32(1))
	if rc != 0 {
		errno := C.errno
		return error_with_code('cannot rename `${old_name}` to `${new_name}` without replacing: ${unsafe {
			cstring_to_vstring(C.strerror(errno))
		}}', errno)
	}
}
