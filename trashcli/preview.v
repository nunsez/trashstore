module trashcli

import internal.fsx
import os

// print_preview_info describes a put target before the confirmation prompt. The
// target path, symlink target, directory entries and file contents all come
// from the filesystem, so every value is sanitized: a crafted file must not be
// able to rewrite the prompt with terminal escape sequences.
fn print_preview_info(target string) {
	display := sanitize_display(target)
	if os.is_link(target) {
		link := os.readlink(target) or { '?' }
		println('${display}: symlink -> ${sanitize_display(link)}')
		return
	}
	if os.is_dir(target) {
		entries := os.ls(target) or { []string{} }
		println('${display}: directory, ${entries.len} entries')
		limit := if entries.len > 10 { 10 } else { entries.len }
		for entry in entries[..limit] {
			println('  > ${sanitize_display(entry)}')
		}
		if entries.len > limit {
			println('  > ...')
		}
		return
	}
	st := os.lstat(target) or {
		println('${display}: unreadable')
		return
	}
	kind := st.get_filetype()
	label := if kind == .regular { 'file' } else { '${kind}' }
	println('${display}: ${label}, ${st.size} bytes')
	if kind != .regular {
		// A FIFO or a device would block or consume data if opened; report the
		// type and leave the content alone.
		return
	}
	for line in preview_file_lines(target) {
		println('  > ${sanitize_display(line)}')
	}
}

// preview_file_lines returns the first lines of a regular file for --preview.
// The read is descriptor-relative and refuses anything that is not a regular
// file, so a path swapped for a FIFO or a device cannot block the prompt.
fn preview_file_lines(target string) []string {
	text := fsx.read_regular_head(target, 4096) or { return []string{} }
	if text.contains('\x00') {
		return ['binary data']
	}
	lines := text.split_into_lines()
	limit := if lines.len > 20 { 20 } else { lines.len }
	return lines[..limit]
}
