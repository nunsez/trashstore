module trashcli

import os

fn print_inspect_info(target string) {
	if os.is_link(target) {
		link := os.readlink(target) or { '?' }
		println('${target}: symlink -> ${link}')
		return
	}
	if os.is_dir(target) {
		entries := os.ls(target) or { []string{} }
		println('${target}: directory, ${entries.len} entries')
		limit := if entries.len > 10 { 10 } else { entries.len }
		for entry in entries[..limit] {
			println('  > ${entry}')
		}
		if entries.len > limit {
			println('  > ...')
		}
		return
	}
	st := os.lstat(target) or {
		println('${target}: unreadable')
		return
	}
	println('${target}: ${detect_kind(target).label()}, ${st.size} bytes')
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
		println('  > ${line}')
	}
}
