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

struct TableRow {
	id   string
	when string
	kind string
	size string
	path string
}

fn max_width(current int, value string) int {
	return if value.len > current { value.len } else { current }
}

// table_lines renders the header and one line per row. Every cell is padded to
// the column width, so the header and all rows share the same column offsets.
fn table_lines(entries []Entry, cwd string, long bool, p Palette) []string {
	mut rows := []TableRow{cap: entries.len}
	for entry in entries {
		rows << TableRow{
			id:   if long { entry.id } else { format.short_id(entry.id) }
			when: if long {
				format.format_time(entry.trashed_at)
			} else {
				format.format_age(entry.trashed_at)
			}
			kind: entry.kind.label()
			size: if entry.kind == .dir { '-' } else { format.format_size(entry.size) }
			path: display_path(entry.original_path, cwd)
		}
	}
	// Column widths are derived from the header labels and the rows, so a wide
	// value never shifts the columns that follow it.
	when_header := if long { 'DELETED' } else { 'AGE' }
	mut id_width := 'ID'.len
	mut when_width := when_header.len
	mut kind_width := 'KIND'.len
	mut size_width := 'SIZE'.len
	for row in rows {
		id_width = max_width(id_width, row.id)
		when_width = max_width(when_width, row.when)
		kind_width = max_width(kind_width, row.kind)
		size_width = max_width(size_width, row.size)
	}
	mut lines := []string{cap: rows.len + 1}
	if long {
		lines << p.dim('${pad_right('ID', id_width)}  ${pad_right(when_header, when_width)}  ${pad_right('KIND', kind_width)}  ${pad_left('SIZE', size_width)}  PATH')
	} else {
		lines << p.dim('${pad_right('ID', id_width)}  ${pad_right(when_header, when_width)}  ${pad_left('SIZE', size_width)}  PATH')
	}
	for row in rows {
		id := p.dim(pad_right(row.id, id_width))
		if long {
			lines << '${id}  ${pad_right(row.when, when_width)}  ${pad_right(row.kind, kind_width)}  ${pad_left(row.size, size_width)}  ${row.path}'
		} else {
			lines << '${id}  ${pad_right(row.when, when_width)}  ${pad_left(row.size, size_width)}  ${row.path}'
		}
	}
	return lines
}

fn print_table(entries []Entry, cwd string, long bool, p Palette) {
	mut total := u64(0)
	for entry in entries {
		total += entry.size
	}
	for line in table_lines(entries, cwd, long, p) {
		println(line)
	}
	println(p.dim('${entries.len} item(s), ${format.format_size(total)}'))
}
