module trash

import os
import time
import internal.format

@[params]
pub struct ListFilter {
pub:
	cwd                string
	recursive          bool
	all                bool
	sort               string
	kind               string
	grep               string
	older_than_seconds i64
	// limit is the maximum number of entries to return after ordering. A
	// negative value means no limit; zero selects nothing.
	limit int = -1
}

pub struct BrokenItem {
pub:
	id     string
	reason string
}

pub struct ScanResult {
pub mut:
	entries []Entry
	broken  []BrokenItem
}

// data_exists reports whether an item has a payload, without following a
// symlinked item directory. One lstat for the item directory guards the path
// walk, and one for the payload replaces the old is_link/exists/is_link triple.
fn data_exists(s Store, id string) bool {
	if !is_safe_id(id) {
		return false
	}
	// Never follow a symlinked item directory: its payload belongs to someone
	// else, and treating it as ours would let a crafted store leak files.
	dir_st := os.lstat(s.item_dir(id)) or { return false }
	if dir_st.get_filetype() != .directory {
		return false
	}
	// lstat, not stat: a dangling symlink payload still counts as present.
	os.lstat(s.data_path(id)) or { return false }
	return true
}

// scan loads the index once, returning valid trashed entries and broken items.
// Orphan payloads (directories without a row) are reported, never deleted.
pub fn (s Store) scan() ScanResult {
	if os.is_link(s.items_dir()) {
		return ScanResult{
			broken: [
				BrokenItem{
					id:     '.'
					reason: 'items directory is a symlink'
				},
			]
		}
	}
	items := s.all_items() or {
		return ScanResult{
			broken: [
				BrokenItem{
					id:     '.'
					reason: 'cannot read index: ${err.msg()}'
				},
			]
		}
	}
	mut result := ScanResult{}
	mut seen := map[string]bool{}
	for item in items {
		if item.parse_error != '' {
			result.broken << BrokenItem{
				id:     item.id
				reason: 'corrupt index row: ${item.parse_error}'
			}
			continue
		}
		if !is_safe_id(item.id) {
			result.broken << BrokenItem{
				id:     item.id
				reason: 'invalid item id'
			}
			continue
		}
		seen[item.id] = true
		if item.state != .trashed {
			result.broken << BrokenItem{
				id:     item.id
				reason: 'item is in `${item.state.label()}` state'
			}
			continue
		}
		if !data_exists(s, item.id) {
			result.broken << BrokenItem{
				id:     item.id
				reason: 'payload is missing'
			}
			continue
		}
		result.entries << item.to_entry()
	}
	ids := os.ls(s.items_dir()) or { return result }
	for id in ids {
		if !is_safe_id(id) {
			result.broken << BrokenItem{
				id:     id
				reason: 'invalid item id'
			}
			continue
		}
		if os.is_link(s.item_dir(id)) {
			result.broken << BrokenItem{
				id:     id
				reason: 'item directory is a symlink'
			}
			continue
		}
		if !os.is_dir(s.item_dir(id)) || id in seen {
			continue
		}
		reason := if data_exists(s, id) {
			'payload has no index row'
		} else {
			'empty item directory'
		}
		result.broken << BrokenItem{
			id:     id
			reason: reason
		}
	}
	// all_items() orders by id DESC, so entries are already newest first.
	return result
}

fn kind_from_label(label string) ?EntryKind {
	return match label {
		'file' { EntryKind.file }
		'dir' { EntryKind.dir }
		'symlink' { EntryKind.symlink }
		'other' { EntryKind.other }
		else { none }
	}
}

// like_escape makes a value literal inside a LIKE pattern. Encoded paths
// contain '%' escapes, which would otherwise be wildcards.
fn like_escape(value string) string {
	mut out := []u8{cap: value.len + 8}
	for c in value.bytes() {
		if c == `\\` || c == `%` || c == `_` {
			out << `\\`
		}
		out << c
	}
	return out.bytestr()
}

// filtered_items loads only the rows that can match the filter. kind, age and
// the cwd scope are pushed into SQL so `list` does not load the whole index;
// grep still runs in V because it matches the decoded path.
fn (s Store) filtered_items(filter ListFilter) ![]IndexItem {
	mut db := s.conn()!
	mut clauses := ['state = ?']
	mut binds := []SqlBind{}
	binds << i64(EntryState.trashed.code())
	if filter.kind != '' {
		kind := kind_from_label(filter.kind) or { return []IndexItem{} }
		clauses << 'kind = ?'
		binds << i64(kind.code())
	}
	if filter.older_than_seconds > 0 {
		cutoff := time.now().unix() - filter.older_than_seconds
		// Match filter_criteria: keep rows whose whole-second timestamp is not
		// greater than the cutoff.
		clauses << 'trashed_at < ?'
		binds << (cutoff + 1) * 1_000_000_000
	}
	if filter.cwd != '' && !filter.all {
		base := canonical_path(filter.cwd)
		prefix := base.trim_right('/') + '/'
		encoded_prefix := like_escape(percent_encode_path(prefix))
		if filter.recursive {
			clauses << "(original_path = ? OR original_path LIKE ? ESCAPE '\\')"
			binds << percent_encode_path(base)
			binds << encoded_prefix + '%'
		} else {
			clauses << "(original_path LIKE ? ESCAPE '\\' AND original_path NOT LIKE ? ESCAPE '\\')"
			binds << encoded_prefix + '%'
			binds << encoded_prefix + '%/%'
		}
	}
	query := 'SELECT ${item_columns} FROM items WHERE ${clauses.join(' AND ')} ORDER BY id DESC'
	mut st := db.prepare(query)!
	defer {
		st.finalize()
	}
	for i, bind in binds {
		match bind {
			i64 { st.bind_int(i + 1, bind)! }
			string { st.bind_text(i + 1, bind)! }
		}
	}
	mut items := []IndexItem{}
	for {
		if !st.step()! {
			break
		}
		items << index_item_from_stmt(st)
	}
	return items
}

// filter_scope keeps the entries trashed from cwd, or from its subtree when
// recursive is set. all (or an empty cwd) disables the scope stage.
pub fn filter_scope(entries []Entry, cwd string, recursive bool, all bool) []Entry {
	if cwd == '' || all {
		return entries.clone()
	}
	base := canonical_path(cwd)
	mut result := []Entry{}
	for entry in entries {
		matches := if recursive {
			is_path_within(entry.original_path, base)
		} else {
			os.dir(entry.original_path) == base
		}
		if matches {
			result << entry
		}
	}
	return result
}

// filter_criteria applies kind/grep/age predicates. Scope, ordering and the
// limit are separate stages; this keeps the pipeline order explicit.
pub fn filter_criteria(entries []Entry, filter ListFilter) []Entry {
	cutoff := if filter.older_than_seconds > 0 {
		time.now().unix() - filter.older_than_seconds
	} else {
		i64(0)
	}
	mut result := []Entry{}
	for entry in entries {
		if filter.kind != '' && entry.kind.label() != filter.kind {
			continue
		}
		if filter.grep != '' && !entry.original_path.contains(filter.grep) {
			continue
		}
		if cutoff > 0 && entry.trashed_at.unix() > cutoff {
			continue
		}
		result << entry
	}
	return result
}

// sort_entries orders entries by the requested key. An empty or unknown key
// preserves the incoming order (newest first for a fresh scan). `date` sorts by
// the recorded trashed_at rather than by id, because ids are only monotonic for
// the default UUIDv7 generator: a rebuilt store or a custom clock can produce
// rows whose id order disagrees with their timestamps.
pub fn sort_entries(entries []Entry, sort string) []Entry {
	mut result := entries.clone()
	match sort {
		'date' {
			result.sort_with_compare(fn (a &Entry, b &Entry) int {
				a_nanos := a.trashed_at.unix_nano()
				b_nanos := b.trashed_at.unix_nano()
				if a_nanos != b_nanos {
					return if a_nanos > b_nanos { -1 } else { 1 }
				}
				if a.id == b.id {
					return 0
				}
				return if a.id > b.id { -1 } else { 1 }
			})
		}
		'size' { result.sort(a.size > b.size) }
		'path' { result.sort(a.original_path < b.original_path) }
		'kind' { result.sort(a.kind.label() < b.kind.label()) }
		else {}
	}
	return result
}

// limit_entries truncates the list after ordering. A negative limit keeps
// every entry; zero keeps none. This gives `--limit N` the literal "at most N"
// meaning, while an unset library filter uses -1 for "no limit".
pub fn limit_entries(entries []Entry, limit int) []Entry {
	if limit >= 0 && entries.len > limit {
		return entries[..limit]
	}
	return entries
}

// filter_entries applies scope, predicates, ordering and the limit in that
// order to an already scanned list.
pub fn filter_entries(entries []Entry, filter ListFilter) []Entry {
	scoped := filter_scope(entries, filter.cwd, filter.recursive, filter.all)
	filtered := filter_criteria(scoped, filter)
	return limit_entries(sort_entries(filtered, filter.sort), filter.limit)
}

// list returns trashed items, optionally limited to the current directory or
// its subtree. Ordering by size measures every candidate first, because sizes
// are filled lazily.
pub fn (s Store) list(filter ListFilter) []Entry {
	items := s.filtered_items(filter) or { return []Entry{} }
	mut entries := []Entry{cap: items.len}
	for item in items {
		if item.parse_error != '' || !is_safe_id(item.id) {
			continue
		}
		if !data_exists(s, item.id) {
			continue
		}
		if filter.grep != '' && !item.original_path.contains(filter.grep) {
			continue
		}
		entries << item.to_entry()
	}
	measured := if filter.sort == 'size' { s.fill_sizes(entries) } else { entries }
	return limit_entries(sort_entries(measured, filter.sort), filter.limit)
}

// short_id_matches reports whether ref is a prefix of the trailing hex part of
// id, showing at least the default short-id width. It accepts the eight-char
// short id and the longer adaptive ids displayed for large stores.
fn short_id_matches(id string, ref string) bool {
	if ref == '' {
		return false
	}
	hex := id.replace('-', '')
	width := if ref.len > format.short_id_min_length { ref.len } else { format.short_id_min_length }
	if hex.len <= width {
		return hex.starts_with(ref)
	}
	return hex[hex.len - width..].starts_with(ref)
}

// find_in resolves an item by full id, short id (as shown by `trash list`),
// a unique prefix of either, or original path, against an already scanned entry
// list. The result is ordered newest first.
pub fn find_in(entries []Entry, ref string) ![]Entry {
	if ref == '' {
		if entries.len == 0 {
			return not_found_error('trash is empty')
		}
		return [entries[0]]
	}
	mut exact_id := []Entry{}
	mut exact_short := []Entry{}
	mut id_prefix := []Entry{}
	mut short_prefix := []Entry{}
	for entry in entries {
		short := format.short_id(entry.id)
		if entry.id == ref {
			exact_id << entry
		} else if short == ref {
			exact_short << entry
		} else if entry.id.starts_with(ref) {
			id_prefix << entry
		} else if short_id_matches(entry.id, ref) {
			short_prefix << entry
		}
	}
	// Prefer the most specific interpretation: an exact id beats an exact short
	// id, which beats any prefix match.
	for matches in [exact_id, exact_short, id_prefix, short_prefix] {
		if matches.len == 0 {
			continue
		}
		if matches.len > 1 {
			return ambiguous_error('ambiguous id `${ref}` matches ${matches.len} items; run `trash list --long` to see full ids')
		}
		return matches
	}
	candidate := canonical_target_path(ref)
	mut by_path := []Entry{}
	for entry in entries {
		if entry.original_path == candidate {
			by_path << entry
		}
	}
	if by_path.len == 0 {
		return not_found_error('no trashed item matches `${ref}`; run `trash list` to see items')
	}
	return by_path
}

// find resolves an item by full id, short id, unique id prefix, or original path.
pub fn (s Store) find(ref string) ![]Entry {
	if ref != '' && is_safe_id(ref) {
		item := s.get_item(ref) or {
			if err is TrashError && err.kind == .not_found {
				return find_in(s.scan().entries, ref)
			}
			return err
		}
		if item.state != .trashed || !data_exists(s, item.id) {
			return not_found_error('item `${ref}` is not restorable')
		}
		return [item.to_entry()]
	}
	return find_in(s.scan().entries, ref)
}

pub struct StoreStats {
pub:
	items   int
	broken  int
	size    u64
	unknown int
	oldest  string
	newest  string
}

// stats returns aggregate information with one store scan. size sums the known
// sizes only; unknown counts the items whose size was not measured yet.
pub fn (s Store) stats() StoreStats {
	scan := s.scan()
	mut size := u64(0)
	mut unknown := 0
	for entry in scan.entries {
		if entry.size_known {
			size += entry.size
		} else {
			unknown++
		}
	}
	mut oldest := ''
	mut newest := ''
	mut oldest_unix := i64(0)
	mut newest_unix := i64(0)
	for i, entry in scan.entries {
		unix := entry.trashed_at.unix()
		if i == 0 || unix < oldest_unix {
			oldest_unix = unix
			oldest = entry.trashed_at.format_rfc3339()
		}
		if i == 0 || unix > newest_unix {
			newest_unix = unix
			newest = entry.trashed_at.format_rfc3339()
		}
	}
	return StoreStats{
		items:   scan.entries.len
		broken:  scan.broken.len
		size:    size
		unknown: unknown
		oldest:  oldest
		newest:  newest
	}
}
