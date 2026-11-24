module fsx

#include <errno.h>
#include <stdio.h>
#include <sys/stdio.h>

fn C.renamex_np(oldpath &char, newpath &char, flags u32) int
fn C.strerror(errnum int) &char

// rename_noreplace renames src to dst only if dst does not exist.
// There is deliberately no check-then-rename fallback.
pub fn rename_noreplace(src string, dst string) ! {
	rc := C.renamex_np(&char(src.str), &char(dst.str), u32(0x00000004)) // RENAME_EXCL
	if rc != 0 {
		errno := C.errno
		return error_with_code('cannot rename `${src}` to `${dst}` without replacing: ${unsafe {
			cstring_to_vstring(C.strerror(errno))
		}}', errno)
	}
}

fn C.renameatx_np(olddirfd int, oldpath &char, newdirfd int, newpath &char, flags u32) int

// renameat_noreplace is rename_noreplace relative to two directory descriptors.
pub fn renameat_noreplace(old_dirfd int, old_name string, new_dirfd int, new_name string) ! {
	rc := C.renameatx_np(old_dirfd, &char(old_name.str), new_dirfd, &char(new_name.str),
		u32(0x00000004)) // RENAME_EXCL
	if rc != 0 {
		errno := C.errno
		return error_with_code('cannot rename `${old_name}` to `${new_name}` without replacing: ${unsafe {
			cstring_to_vstring(C.strerror(errno))
		}}', errno)
	}
}
