module trash

import os
import time

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
	return os.exists(s.data_path(id)) || os.is_link(s.data_path(id))
}

// scan loads the store once, returning valid trashed entries and broken items.
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
	ids := os.ls(s.items_dir()) or {
		return ScanResult{
			broken: [
				BrokenItem{
					id:     '.'
					reason: 'cannot read items directory: ${err.msg()}'
				},
			]
		}
	}
	mut result := ScanResult{}
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
		if !os.is_dir(s.item_dir(id)) {
			continue
		}
		entry := s.read_entry(id) or {
			result.broken << BrokenItem{
				id:     id
				reason: err.msg()
			}
			continue
		}
		if entry.state != .trashed {
			result.broken << BrokenItem{
				id:     id
				reason: 'item is in `${entry.state.label()}` state'
			}
			continue
		}
		if !data_exists(s, entry.id) {
			result.broken << BrokenItem{
				id:     id
				reason: 'payload is missing'
			}
			continue
		}
		result.entries << entry
	}
	result.entries.sort(a.id > b.id)
	return result
}

// filter_entries applies cwd/recursive/limit filtering to an already scanned list.
pub fn filter_entries(entries []Entry, filter ListFilter) []Entry {
	mut result := []Entry{}
	cwd := canonical_path(filter.cwd)
	cutoff := if filter.older_than_seconds > 0 {
		time.now().unix() - filter.older_than_seconds
	} else {
		i64(0)
	}
	for entry in entries {
		if filter.cwd != '' && !filter.all {
			matches := if filter.recursive {
				is_path_within(entry.original_path, cwd)
			} else {
				os.dir(entry.original_path) == cwd
			}
			if !matches {
				continue
			}
		}
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
	match filter.sort {
		'size' { result.sort(a.size > b.size) }
		'path' { result.sort(a.original_path < b.original_path) }
		'kind' { result.sort(a.kind.label() < b.kind.label()) }
		else {}
	}
	if filter.limit > 0 && result.len > filter.limit {
		return result[..filter.limit]
	}
	return result
}

// list returns trashed items, optionally limited to the current directory or
// its subtree.
pub fn (s Store) list(filter ListFilter) []Entry {
	return filter_entries(s.scan().entries, filter)
}

// find_in resolves an item by full id, unique id prefix, or original path
// against an already scanned entry list. The result is ordered newest first.
pub fn find_in(entries []Entry, ref string) ![]Entry {
	if ref == '' {
		if entries.len == 0 {
			return not_found_error('trash is empty')
		}
		return [entries[0]]
	}
	mut exact := []Entry{}
	mut prefixed := []Entry{}
	for entry in entries {
		if entry.id == ref {
			exact << entry
		} else if entry.id.starts_with(ref) {
			prefixed << entry
		}
	}
	if exact.len > 0 {
		return exact
	}
	if prefixed.len > 1 {
		return ambiguous_error('ambiguous id prefix `${ref}`; use a longer prefix')
	}
	if prefixed.len == 1 {
		return prefixed
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

// find resolves an item by full id, unique id prefix, or original path.
pub fn (s Store) find(ref string) ![]Entry {
	if ref != '' && is_safe_id(ref) && !os.is_link(s.item_dir(ref)) && os.is_dir(s.item_dir(ref)) {
		entry := s.read_entry(ref)!
		if entry.state != .trashed || !data_exists(s, entry.id) {
			return not_found_error('item `${ref}` is not restorable')
		}
		return [entry]
	}
	return find_in(s.scan().entries, ref)
}

// latest returns the newest trashed item.
pub fn (s Store) latest() !Entry {
	entries := s.scan().entries
	if entries.len == 0 {
		return not_found_error('trash is empty')
	}
	return entries[0]
}

pub struct StoreStats {
pub:
	items  int
	broken int
	size   u64
	oldest string
	newest string
}

// stats returns aggregate information with one store scan.
pub fn (s Store) stats() StoreStats {
	scan := s.scan()
	mut size := u64(0)
	for entry in scan.entries {
		size += entry.size
	}
	mut oldest := ''
	mut newest := ''
	if scan.entries.len > 0 {
		oldest = scan.entries.last().trashed_at.format_rfc3339()
		newest = scan.entries[0].trashed_at.format_rfc3339()
	}
	return StoreStats{
		items:  scan.entries.len + scan.broken.len
		broken: scan.broken.len
		size:   size
		oldest: oldest
		newest: newest
	}
}
