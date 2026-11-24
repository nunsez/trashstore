module fsx

$if !linux && !macos {
	pub fn rename_noreplace(src string, dst string) ! {
		return error('rename without replacement is not implemented on this platform')
	}
}

$if !linux && !macos {
	pub fn renameat_noreplace(old_dirfd int, old_name string, new_dirfd int, new_name string) ! {
		return error('rename without replacement is not implemented on this platform')
	}
}
