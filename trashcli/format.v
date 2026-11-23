module trashcli

import internal.format
import os

pub struct Palette {
pub:
	enabled bool
}

fn new_palette(no_color bool) Palette {
	return Palette{
		enabled: !no_color && os.getenv('NO_COLOR') == '' && os.is_atty(1) != 0
	}
}

fn (p Palette) dim(s string) string {
	if p.enabled {
		return '\x1b[2m${s}\x1b[0m'
	}
	return s
}

fn (p Palette) bold(s string) string {
	if p.enabled {
		return '\x1b[1m${s}\x1b[0m'
	}
	return s
}

fn (p Palette) red(s string) string {
	if p.enabled {
		return '\x1b[31m${s}\x1b[0m'
	}
	return s
}

fn (p Palette) green(s string) string {
	if p.enabled {
		return '\x1b[32m${s}\x1b[0m'
	}
	return s
}

fn display_path(path string, cwd string) string {
	if path == cwd {
		return '.'
	}
	prefix := cwd.trim_right('/') + '/'
	if path.starts_with(prefix) {
		return path[prefix.len..]
	}
	return path
}

fn pad_left(s string, width int) string {
	if s.len >= width {
		return s
	}
	return ' '.repeat(width - s.len) + s
}

fn pad_right(s string, width int) string {
	if s.len >= width {
		return s
	}
	return s + ' '.repeat(width - s.len)
}

pub struct JsonEntry {
pub:
	id            string
	original_path string
	deleted_at    string
	kind          string
	size          u64
}

fn json_entry(entry Entry) JsonEntry {
	return JsonEntry{
		id:            entry.id
		original_path: entry.original_path
		deleted_at:    entry.trashed_at.format_rfc3339()
		kind:          entry.kind.label()
		size:          entry.size
	}
}

fn json_entries(entries []Entry) []JsonEntry {
	mut result := []JsonEntry{}
	for entry in entries {
		result << json_entry(entry)
	}
	return result
}

fn print_table(entries []Entry, cwd string, long bool, p Palette) {
	mut total := u64(0)
	for entry in entries {
		total += entry.size
	}
	for entry in entries {
		id := if long { entry.id } else { format.short_id(entry.id) }
		size := if entry.kind == .dir { '-' } else { format.format_size(entry.size) }
		if long {
			println('${p.dim(id)}  ${format.format_time(entry.trashed_at)}  ${pad_right(entry.kind.label(), 8)}  ${pad_left(size, 9)}  ${display_path(entry.original_path, cwd)}')
		} else {
			println('${p.dim(id)}  ${format.format_age(entry.trashed_at)}  ${pad_left(size, 9)}  ${display_path(entry.original_path, cwd)}')
		}
	}
	println(p.dim('${entries.len} item(s), ${format.format_size(total)}'))
}
