module fsx

#include <sys/clonefile.h>

fn C.clonefile(src &char, dst &char, flags int) int
