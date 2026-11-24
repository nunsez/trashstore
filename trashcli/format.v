module trashcli

import internal.format
import math
import os
import term

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

fn json_entry(entry Entry) JsonEntry {
	return JsonEntry{
		id:            entry.id
		original_path: entry.original_path
		deleted_at:    entry.trashed_at.format_rfc3339()
		kind:          entry.kind.label()
		size:          entry.size
		size_known:    entry.size_known
	}
}

fn json_entries(entries []Entry) []JsonEntry {
	mut result := []JsonEntry{}
	for entry in entries {
		result << json_entry(entry)
	}
	return result
}

// WhereItem pairs a trashed entry with its payload location in the store.
pub struct WhereItem {
pub:
	entry    Entry
	location string
}

pub struct JsonWhere {
pub:
	id            string
	location      string
	original_path string
	deleted_at    string
	kind          string
	size          u64
	size_known    bool
}

fn json_wheres(items []WhereItem) []JsonWhere {
	mut result := []JsonWhere{}
	for item in items {
		entry := item.entry
		result << JsonWhere{
			id:            entry.id
			location:      item.location
			original_path: entry.original_path
			deleted_at:    entry.trashed_at.format_rfc3339()
			kind:          entry.kind.label()
			size:          entry.size
			size_known:    entry.size_known
		}
	}
	return result
}

struct WhereRow {
	id       string
	when     string
	size     string
	location string
	path     string
}

// where_table_lines renders the locator output: full id, deletion time, size,
// the payload path inside the store, and the original path.
fn where_table_lines(items []WhereItem, p Palette) []string {
	mut rows := []WhereRow{cap: items.len}
	for item in items {
		entry := item.entry
		rows << WhereRow{
			id:       entry.id
			when:     format.format_time(entry.trashed_at)
			size:     if entry.size_known { format.format_size(entry.size) } else { '-' }
			location: item.location
			path:     entry.original_path
		}
	}
	mut id_width := 'ID'.len
	mut when_width := 'DELETED'.len
	mut size_width := 'SIZE'.len
	mut location_width := 'LOCATION'.len
	for row in rows {
		id_width = max_width(id_width, row.id)
		when_width = max_width(when_width, row.when)
		size_width = max_width(size_width, row.size)
		location_width = max_width(location_width, row.location)
	}
	mut lines := []string{cap: rows.len + 1}
	lines << p.dim('${pad_right('ID', id_width)}  ${pad_right('DELETED', when_width)}  ${pad_left('SIZE', size_width)}  ${pad_right('LOCATION', location_width)}  ORIGINAL')
	for row in rows {
		lines << '${p.dim(pad_right(row.id, id_width))}  ${pad_right(row.when, when_width)}  ${pad_left(row.size, size_width)}  ${pad_right(row.location, location_width)}  ${row.path}'
	}
	return lines
}

fn print_where_table(items []WhereItem, p Palette) {
	for line in where_table_lines(items, p) {
		println(line)
	}
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

fn print_table(entries []Entry, cwd string, long bool, p Palette) {
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
