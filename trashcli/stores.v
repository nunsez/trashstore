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
	stores   map[string]trash.Store
}

fn new_store_set(cli Cli, spec StoreSpec) !StoreSet {
	mut set := StoreSet{
		spec:   spec
		stores: map[string]trash.Store{}
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
			eprintln(cli.palette().red('warning:') + ' skipping store ${root}: ${err.msg()}')
			return
		}
		return err
	}
	recovery := store.recover_if_needed() or {
		store.close()
		if best_effort {
			eprintln(cli.palette().red('warning:') + ' skipping store ${root}: ${err.msg()}')
			return
		}
		return err
	}
	for warning in recovery.warnings {
		eprintln(cli.palette().red('warning:') + ' ${root}: ${warning}')
	}
	if recovery.recovered > 0 && cli.verbose {
		eprintln('Recovered ${recovery.recovered} interrupted trash operation(s) in ${root}.')
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
	eprintln(cli.palette().red('warning:') + ' using ${set.spec.root} for ${target}')
	return TargetStore{
		root: set.spec.root
		dev:  set.home_dev
	}
}

fn (set &StoreSet) register_target(chosen TargetStore, cli Cli) {
	if set.spec.explicit || chosen.root == set.spec.root || chosen.mount == '' {
		return
	}
	register_volume(set.spec.root, VolumeRecord{
		dev:   chosen.dev
		mount: chosen.mount
		root:  chosen.root
	}) or {
		eprintln(cli.palette().red('warning:') + ' cannot register volume ${chosen.mount}: ${err.msg()}')
	}
}

fn (mut set StoreSet) scan_all(cli Cli) ScanAll {
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
				eprintln(cli.palette().red('warning:') + ' duplicate item id ${entry.id} in ${root}; skipping')
				continue
			}
			result.roots[entry.id] = root
			result.entries << entry
		}
	}
	return result
}

fn fill_sizes(set &StoreSet, roots map[string]string, entries []trash.Entry) []trash.Entry {
	mut result := []trash.Entry{cap: entries.len}
	for entry in entries {
		root := roots[entry.id] or {
			result << entry
			continue
		}
		store := set.stores[root] or {
			result << entry
			continue
		}
		result << store.fill_size(entry)
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

fn warn_scoped_broken(broken []ScopedBroken, cli Cli, multi bool) {
	p := cli.palette()
	for scoped in broken {
		prefix := if multi { '${scoped.root}: ' } else { '' }
		eprintln(p.red('warning:') + ' ${prefix}broken trash item ${format.short_id(scoped.item.id)}: ${scoped.item.reason}')
	}
}
