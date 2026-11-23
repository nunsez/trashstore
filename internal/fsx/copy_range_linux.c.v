module fsx

#flag -D_GNU_SOURCE
#include <unistd.h>
#include <errno.h>

fn C.copy_file_range(fd_in int, off_in voidptr, fd_out int, off_out voidptr, len u64, flags u32) i64
