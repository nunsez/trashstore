module fsx

$if !linux && !macos {
	pub fn rename_noreplace(src string, dst string) ! {
		return error('rename without replacement is not implemented on this platform')
	}
}
