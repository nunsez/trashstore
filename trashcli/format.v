module trashcli

import internal.format
import math
import os
import term
import trash

pub struct Palette {
pub:
	enabled bool
}

fn new_palette(no_color bool) Palette {
	return Palette{
		enabled: !no_color && os.getenv('NO_COLOR') == '' && term.can_show_color_on_stdout()
	}
}

fn (p Palette) dim(s string) string {
	if p.enabled {
		return term.dim(s)
	}
	return s
}

fn (p Palette) bold(s string) string {
	if p.enabled {
		return term.bold(s)
	}
	return s
}

fn (p Palette) red(s string) string {
	if p.enabled {
		return term.red(s)
	}
	return s
}

fn (p Palette) green(s string) string {
	if p.enabled {
		return term.green(s)
	}
	return s
}

// sanitize_display escapes C0 control bytes and DEL as \xNN. Paths and ids come
// from the store and may contain terminal escape sequences; JSON and `where`
// keep the raw value for scripts, but human-readable output must not.
fn sanitize_display(value string) string {
	mut out := []u8{cap: value.len}
	for c in value.bytes() {
		if c < 0x20 || c == 0x7f {
			out << `\\`
			out << `x`
			out << hex_digit(c >> 4)
			out << hex_digit(c & 0x0f)
		} else {
			out << c
		}
	}
	return out.bytestr()
}

fn hex_digit(value u8) u8 {
	if value < 10 {
		return u8(0x30 + value)
	}
	return u8(0x61 + value - 10)
}

fn display_path(path string, cwd string) string {
	if path == '' {
		return '(unknown)'
	}
	if path == cwd {
		return '.'
	}
	prefix := cwd.trim_right('/') + '/'
	if path.starts_with(prefix) {
		return sanitize_display(path[prefix.len..])
	}
	return sanitize_display(path)
}

fn pad_left(s string, width int) string {
	n := term.printable_len(s)
	if n >= width {
		return s
	}
	return ' '.repeat(width - n) + s
}

fn pad_right(s string, width int) string {
	n := term.printable_len(s)
	if n >= width {
		return s
	}
	return s + ' '.repeat(width - n)
}

pub struct JsonEntry {
pub:
	id            string
	original_path string
	deleted_at    string
	kind          string
	size          u64
	size_known    bool
}

fn json_entry(entry trash.Entry) JsonEntry {
	return JsonEntry{
		id:            entry.id
		original_path: entry.original_path
		deleted_at:    entry.trashed_at.format_rfc3339()
		kind:          entry.kind.label()
		size:          entry.size
		size_known:    entry.size_known
	}
}

fn json_entries(entries []trash.Entry) []JsonEntry {
	mut result := []JsonEntry{}
	for entry in entries {
		result << json_entry(entry)
	}
	return result
}

// JsonLocation is the machine-readable form of a locator result.
pub struct JsonLocation {
pub:
	id       string
	location string
}

struct TableRow {
	id   string
	when string
	kind string
	size string
	path string
}

fn max_width(current int, value string) int {
	return math.max(current, term.printable_len(value))
}

// table_lines renders the header and one line per row. Every cell is padded to
// the column width, so the header and all rows share the same column offsets.
fn table_lines(entries []trash.Entry, cwd string, long bool, p Palette) []string {
	id_len := format.short_id_length(entries.len)
	mut rows := []TableRow{cap: entries.len}
	for entry in entries {
		rows << TableRow{
			id:   sanitize_display(if long {
				entry.id
			} else {
				format.short_id_len(entry.id, id_len)
			})
			when: if long {
				format.format_time(entry.trashed_at)
			} else {
				format.format_age(entry.trashed_at)
			}
			kind: entry.kind.label()
			size: if entry.size_known { format.format_size(entry.size) } else { '-' }
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

fn print_table(entries []trash.Entry, cwd string, long bool, p Palette) {
	mut total := u64(0)
	mut unknown := 0
	for entry in entries {
		if entry.size_known {
			total += entry.size
		} else {
			unknown++
		}
	}
	for line in table_lines(entries, cwd, long, p) {
		println(line)
	}
	println(p.dim('${entries.len} item(s), ${format.format_size(total)}${unknown_suffix(unknown)}'))
}

// unknown_suffix explains that the printed total leaves items out.
fn unknown_suffix(unknown int) string {
	if unknown == 0 {
		return ''
	}
	return ' (${unknown} unknown)'
}
