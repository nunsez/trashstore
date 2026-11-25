module trashcli

import os
import trash

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
	println('${display}: ${trash.detect_kind(target).label()}, ${st.size} bytes')
	mut f := os.open(target) or { return }
	mut buf := []u8{len: 4096}
	n := f.read(mut buf) or { 0 }
	f.close()
	text := buf[..n].bytestr()
	if text.contains('\x00') {
		println('  > binary data')
		return
	}
	lines := text.split_into_lines()
	limit := if lines.len > 20 { 20 } else { lines.len }
	for line in lines[..limit] {
		println('  > ${sanitize_display(line)}')
	}
}
