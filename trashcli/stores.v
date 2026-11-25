module trashcli

import internal.format
import os
import trash

// ScopedBroken is a broken item together with the store that reported it.
struct ScopedBroken {
	root string
	item trash.BrokenItem
}

// ScanAll is the merged view of every store in a StoreSet.
struct ScanAll {
mut:
	entries []trash.Entry
	broken  []ScopedBroken
	roots   map[string]string
}

// StoreSet owns the home store and, when per-volume mode is enabled, the
// stores of the volumes the current command needs.
struct StoreSet {
mut:
	spec     StoreSpec
	home_dev u64
	roots    []string
	stores   map[string]&trash.Store
	// diag collects warnings for the whole invocation, including those emitted
	// while opening stores, and flushes them once the command finishes.
	diag Diagnostics
}

fn new_store_set(cli Cli, spec StoreSpec) !StoreSet {
	mut set := StoreSet{
		spec:   spec
		stores: map[string]&trash.Store{}
		diag:   new_diagnostics(cli)
	}
	set.open_one(spec.root, cli, false)!
	set.home_dev = os.stat(spec.root)!.dev
	return set
}

fn (mut set StoreSet) open_one(root string, cli Cli, best_effort bool) ! {
	if root in set.stores {
		return
	}
	mut store := open_store_or_reset(root, cli) or {
		if best_effort {
			set.diag.warn('skipping store ${root}: ${err.msg()}')
			return
		}
		return err
	}
	recovery := store.recover_if_needed() or {
		store.close()
		if best_effort {
			set.diag.warn('skipping store ${root}: ${err.msg()}')
			return
		}
		return err
	}
	for warning in recovery.warnings {
		set.diag.warn('${root}: ${warning}')
	}
	if recovery.recovered > 0 && cli.verbose {
		eprintln('Recovered ${recovery.recovered} interrupted trash operation(s) in ${sanitize_display(root)}.')
	}
	set.stores[root] = store
	set.roots << root
}

fn (mut set StoreSet) open_for_read(cli Cli, cwd string) ! {
	for root in roots_for_read(set.spec, cli, cwd, set.home_dev) {
		if root !in set.stores {
			set.open_one(root, cli, true)!
		}
	}
}

// target_store resolves the store for one put target. If a volume store cannot
// be opened, the target falls back to the home store (cross-device copy).
fn (mut set StoreSet) target_store(target string, cli Cli) !TargetStore {
	if set.spec.explicit {
		check_not_mount_point(target)!
		return TargetStore{
			root: set.spec.root
			dev:  set.home_dev
		}
	}
	chosen := target_store_root(target, set.spec.root, set.home_dev)!
	if chosen.root == set.spec.root {
		return chosen
	}
	if chosen.root !in set.stores {
		set.open_one(chosen.root, cli, true)!
	}
	if chosen.root in set.stores {
		return chosen
	}
	set.diag.warn('using ${set.spec.root} for ${target}')
	return TargetStore{
		root: set.spec.root
		dev:  set.home_dev
	}
}

fn (set &StoreSet) register_target(chosen TargetStore) {
	if set.spec.explicit || chosen.root == set.spec.root || chosen.mount == '' {
		return
	}
	register_volume(set.spec.root, VolumeRecord{
		dev:   chosen.dev
		mount: chosen.mount
		root:  chosen.root
	}) or {
		set.diag.warn('cannot register volume ${chosen.mount}: ${err.msg()}')
	}
}

fn (mut set StoreSet) scan_all() ScanAll {
	mut result := ScanAll{
		roots: map[string]string{}
	}
	for root in set.roots {
		store := set.stores[root] or { continue }
		scan := store.scan()
		for item in scan.broken {
			result.broken << ScopedBroken{
				root: root
				item: item
			}
		}
		for entry in scan.entries {
			if entry.id in result.roots {
				set.diag.warn('duplicate item id ${entry.id} in ${root}; skipping')
				continue
			}
			result.roots[entry.id] = root
			result.entries << entry
		}
	}
	return result
}

// scan_total is the number of ids the scanned stores know about, including
// broken ones. It is the width basis for adaptive short ids: a page-limited
// listing must not shrink ids that are ambiguous across the whole store.
fn scan_total(scan ScanAll) int {
	return scan.entries.len + scan.broken.len
}

fn fill_sizes(set &StoreSet, roots map[string]string, entries []trash.Entry) []trash.Entry {
	mut result := entries.clone()
	// Group entries by their owning store so each store measures and persists
	// its sizes in one transaction instead of one commit per item.
	mut by_root := map[string][]int{}
	for i, entry in entries {
		root := roots[entry.id] or { continue }
		by_root[root] << i
	}
	for root, indexes in by_root {
		store := set.stores[root] or { continue }
		mut group := []trash.Entry{cap: indexes.len}
		for i in indexes {
			group << entries[i]
		}
		filled := store.fill_sizes(group)
		for j, i in indexes {
			result[i] = filled[j]
		}
	}
	return result
}

fn (mut set StoreSet) close() {
	for root in set.roots {
		mut store := set.stores[root] or { continue }
		store.close()
	}
}

// group_entries groups selected entries by their owning store, preserving the
// order in which the stores first appear in the selection.
fn group_entries(entries []trash.Entry, roots map[string]string) ([]string, map[string][]trash.Entry) {
	mut order := []string{}
	mut groups := map[string][]trash.Entry{}
	for entry in entries {
		root := roots[entry.id] or { continue }
		if root !in groups {
			order << root
		}
		groups[root] << entry
	}
	return order, groups
}

// broken_id_label renders the id of a broken item for diagnostics. A store-wide
// problem has no id, and an unsafe id is quoted verbatim instead of being
// truncated into something that looks like a real item id.
fn broken_id_label(id string) string {
	if id == '' {
		return 'store'
	}
	if !trash.is_safe_id(id) {
		return '`${id}` (invalid id)'
	}
	return format.short_id(id)
}

// broken_subject names the thing a broken item describes, so a store-wide
// problem reads as "broken trash store" instead of a nameless item.
fn broken_subject(id string) string {
	if id == '' {
		return 'broken trash store'
	}
	return 'broken trash item ${broken_id_label(id)}'
}

// warn_broken reports every broken item found by scan_all. The store name is
// included only when more than one store was scanned. Diagnostics sanitizes the
// message before it reaches the terminal.
fn (mut set StoreSet) warn_broken(broken []ScopedBroken) {
	multi := set.roots.len > 1
	for scoped in broken {
		prefix := if multi { '${scoped.root}: ' } else { '' }
		set.diag.warn('${prefix}${broken_subject(scoped.item.id)}: ${scoped.item.reason}')
	}
}
