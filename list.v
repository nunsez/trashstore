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
	limit              int
	sort               string
	kind               string
	grep               string
	older_than_seconds i64
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

fn data_exists(s Store, id string) bool {
	// Never follow a symlinked item directory: its payload belongs to someone
	// else, and treating it as ours would let a crafted store leak files.
	if os.is_link(s.item_dir(id)) {
		return false
	}
	return os.exists(s.data_path(id)) || os.is_link(s.data_path(id))
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
	result.entries.sort(a.id > b.id)
	return result
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
// preserves the incoming order (newest first for a fresh scan).
pub fn sort_entries(entries []Entry, sort string) []Entry {
	mut result := entries.clone()
	match sort {
		'size' { result.sort(a.size > b.size) }
		'path' { result.sort(a.original_path < b.original_path) }
		'kind' { result.sort(a.kind.label() < b.kind.label()) }
		else {}
	}
	return result
}

// limit_entries truncates the list after ordering. A non-positive limit keeps
// every entry.
pub fn limit_entries(entries []Entry, limit int) []Entry {
	if limit > 0 && entries.len > limit {
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
	scoped := filter_scope(s.scan().entries, filter.cwd, filter.recursive, filter.all)
	filtered := filter_criteria(scoped, filter)
	measured := if filter.sort == 'size' { s.fill_sizes(filtered) } else { filtered }
	return limit_entries(sort_entries(measured, filter.sort), filter.limit)
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
		} else if short.starts_with(ref) {
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
