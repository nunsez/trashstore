module trashcli

import internal.format
import json2
import os
import strconv
import time

struct PurgeReport {
	purged int
	failed int
}

struct EmptyReport {
	emptied int
	dry_run bool
}

struct WhereReport {
	root   string
	items  int
	broken int
	size   u64
	oldest string
	newest string
}

struct RestorePlan {
	id            string
	original_path string
	restored_to   string
}

struct PurgePlan {
	would_purge int
	items       []JsonEntry
}

// run executes the parsed command.
pub fn run(cli Cli) ! {
	match cli.command {
		.help {
			print_help(cli)
			return
		}
		.version {
			println('${app_name} ${app_version}')
			return
		}
		else {}
	}

	store := open_with(resolve_graveyard(cli.graveyard)!, StoreOptions{
		sync: !cli.no_sync
	})!
	if cli.no_sync {
		eprintln(cli.palette().red('warning:') + ' --no-sync disables fsync durability guarantees')
	}
	recovery := store.recover_if_needed()!
	if recovery.recovered > 0 && cli.verbose && !cli.quiet {
		eprintln('Recovered ${recovery.recovered} interrupted trash operation(s).')
	}
	if !cli.quiet {
		for warning in recovery.warnings {
			eprintln(cli.palette().red('warning:') + ' ' + warning)
		}
	}

	match cli.command {
		.put { run_put(store, cli)! }
		.list { run_list(store, cli)! }
		.restore { run_restore(store, cli)! }
		.purge { run_purge(store, cli)! }
		.empty { run_empty(store, cli)! }
		.where { run_where(store, cli)! }
		.doctor { run_doctor(store, cli)! }
		.help, .version {}
	}
}

fn warn_broken(broken []BrokenItem, cli Cli) {
	if cli.quiet {
		return
	}
	p := cli.palette()
	for item in broken {
		eprintln(p.red('warning:') + ' broken trash item ${format.short_id(item.id)}: ${item.reason}')
	}
}

fn run_put(store Store, cli Cli) ! {
	if !cli.dry_run && !cli.inspect {
		batch := store.put_many(cli.targets, PutOptions{ recursive: cli.recursive })!
		if cli.verbose && !cli.quiet {
			for entry in batch.entries {
				println('Trashed ${entry.original_path} (${format.short_id(entry.id)})')
			}
		}
		if batch.failures.len > 0 {
			mut failures := []string{}
			for failure in batch.failures {
				failures << 'Failed to trash ${failure.id}: ${failure.message}'
			}
			return error(failures.join('\n'))
		}
		return
	}
	mut failures := []string{}
	for target in cli.targets {
		planned := store.plan_put(target, PutOptions{ recursive: cli.recursive }) or {
			failures << 'Failed to trash ${target}: ${err.msg()}'
			continue
		}
		if cli.dry_run {
			if !cli.quiet {
				println('Would trash ${planned.original_path}')
			}
			continue
		}
		if cli.inspect {
			if !cli.yes && os.is_atty(0) == 0 {
				return error('--inspect requires a terminal; use --yes to skip the prompt')
			}
			print_inspect_info(planned.original_path)
			if !cli.yes {
				ans := os.input('Send ${planned.original_path} to the trash? (y/n) ').trim_space().to_lower()
				if ans != 'y' && ans != 'yes' {
					continue
				}
			}
		}
		entry := store.put(target, PutOptions{ recursive: cli.recursive }) or {
			failures << 'Failed to trash ${target}: ${err.msg()}'
			continue
		}
		if cli.verbose && !cli.quiet {
			println('Trashed ${entry.original_path} (${format.short_id(entry.id)})')
		}
	}
	if failures.len > 0 {
		return error(failures.join('\n'))
	}
}

fn run_list(store Store, cli Cli) ! {
	scan := store.scan()
	warn_broken(scan.broken, cli)
	cwd := canonical_path(os.getwd())
	entries := filter_entries(scan.entries, ListFilter{
		cwd:                if cli.all { '' } else { cwd }
		recursive:          cli.recursive
		all:                cli.all
		limit:              cli.limit
		sort:               cli.sort
		kind:               cli.kind
		grep:               cli.grep
		older_than_seconds: cli.older_than_seconds
	})
	if cli.json {
		println(json2.encode(json_entries(entries), escape_unicode: true))
		return
	}
	if entries.len == 0 {
		if !cli.quiet {
			if cli.all {
				println('Trash is empty.')
			} else {
				println('No items trashed from ${cwd}.')
			}
		}
		return
	}
	print_table(entries, cwd, cli.long, cli.palette())
}

fn collect_matches(entries []Entry, targets []string, all bool) ![]Entry {
	mut selected := []Entry{}
	mut seen := map[string]bool{}
	for target in targets {
		matches := find_in(entries, target)!
		chosen := if all { matches } else { [matches[0]] }
		for entry in chosen {
			if seen[entry.id] {
				continue
			}
			seen[entry.id] = true
			selected << entry
		}
	}
	return selected
}

fn run_restore(store Store, cli Cli) ! {
	scan := store.scan()
	warn_broken(scan.broken, cli)
	mut selected := []Entry{}
	if cli.from_cwd {
		cwd := canonical_path(os.getwd())
		selected = filter_entries(scan.entries, ListFilter{
			cwd:       cwd
			recursive: cli.recursive
		})
		if selected.len == 0 {
			if !cli.quiet {
				println('No items trashed from ${cwd}.')
			}
			return
		}
	} else if cli.targets.len == 0 {
		selected = find_in(scan.entries, '')!
	} else {
		selected = collect_matches(scan.entries, cli.targets, cli.all)!
	}
	if cli.select {
		selected = select_entries(selected, cli)!
	}
	if cli.dry_run {
		mut plans := []RestorePlan{}
		for entry in selected {
			target := resolve_name_conflict(entry.original_path)
			plans << RestorePlan{
				id:            entry.id
				original_path: entry.original_path
				restored_to:   target
			}
			if !cli.json && !cli.quiet {
				println('Would restore ${entry.original_path} -> ${target}')
			}
		}
		if cli.json {
			println(json2.encode(plans, escape_unicode: true))
		}
		return
	}
	batch := store.restore_batch(selected)!
	if cli.json {
		mut plans := []RestorePlan{}
		for result in batch.results {
			plans << RestorePlan{
				id:            result.entry.id
				original_path: result.entry.original_path
				restored_to:   result.restored_to
			}
		}
		println(json2.encode(plans, escape_unicode: true))
	} else if !cli.quiet {
		for result in batch.results {
			println('Restored ${result.entry.original_path} -> ${result.restored_to}')
		}
	}
	if batch.failures.len > 0 {
		for failure in batch.failures {
			eprintln(cli.palette().red('error:') + ' ${failure.id}: ${failure.message}')
		}
		return error('${batch.failures.len} item(s) could not be restored')
	}
}

fn run_purge(store Store, cli Cli) ! {
	scan := store.scan()
	warn_broken(scan.broken, cli)
	mut selected := if cli.targets.len == 0 {
		filter_entries(scan.entries, ListFilter{
			all:                true
			older_than_seconds: cli.older_than_seconds
			kind:               cli.kind
			grep:               cli.grep
		})
	} else {
		collect_matches(scan.entries, cli.targets, cli.all)!
	}
	if cli.targets.len > 0 {
		if cli.older_than_seconds > 0 {
			cutoff := time.now().unix() - cli.older_than_seconds
			selected = selected.filter(it.trashed_at.unix() <= cutoff)
		}
		if cli.kind != '' {
			selected = selected.filter(it.kind.label() == cli.kind)
		}
		if cli.grep != '' {
			selected = selected.filter(it.original_path.contains(cli.grep))
		}
	}
	if cli.dry_run {
		if cli.json {
			println(json2.encode(PurgePlan{
				would_purge: selected.len
				items:       json_entries(selected)
			}, escape_unicode: true))
		} else if !cli.quiet {
			for entry in selected {
				println('Would purge ${entry.original_path}')
			}
			println('Would purge ${selected.len} item(s).')
		}
		return
	}
	if selected.len > 1 && !cli.yes {
		if os.is_atty(0) == 0 {
			return error('refusing to purge ${selected.len} items without --yes in non-interactive mode')
		}
		ans := os.input('Permanently delete ${selected.len} items? [y/N] ').trim_space().to_lower()
		if ans != 'y' && ans != 'yes' {
			println('Aborted.')
			return
		}
	}
	batch := store.purge_batch(selected)!
	if batch.purged > 0 {
		store.gc()!
	}
	if cli.json {
		println(json2.encode(PurgeReport{
			purged: batch.purged
			failed: batch.failures.len
		}, escape_unicode: true))
	} else if !cli.quiet {
		println('Purged ${batch.purged} item(s).')
	}
	if batch.failures.len > 0 {
		for failure in batch.failures {
			eprintln(cli.palette().red('error:') + ' ${failure.id}: ${failure.message}')
		}
		return error('${batch.failures.len} item(s) could not be purged')
	}
}

fn run_empty(store Store, cli Cli) ! {
	if cli.keep > 0 || cli.older_than_seconds > 0 {
		return run_selective_empty(store, cli)
	}
	count := store.count_items()
	if cli.dry_run {
		if cli.json {
			println(json2.encode(EmptyReport{ emptied: count, dry_run: true }, escape_unicode: true))
		} else if !cli.quiet {
			println('Would permanently delete ${count} item(s) from ${store.root}.')
		}
		return
	}
	if count == 0 {
		if cli.json {
			println(json2.encode(EmptyReport{ emptied: 0, dry_run: false }, escape_unicode: true))
		} else if !cli.quiet {
			println('Trash is already empty.')
		}
		return
	}
	if !cli.yes {
		if os.is_atty(0) == 0 {
			return error('refusing to empty the trash without --yes in non-interactive mode')
		}
		ans := os.input('Empty the trash at ${store.root} (${count} item(s))? [y/N] ').trim_space().to_lower()
		if ans != 'y' && ans != 'yes' {
			println('Aborted.')
			return
		}
	}
	n := store.empty_wait(cli.wait)!
	if cli.json {
		println(json2.encode(EmptyReport{ emptied: n, dry_run: false }, escape_unicode: true))
	} else if !cli.quiet {
		println('Emptied ${n} item(s) from ${store.root}.')
	}
}

fn run_selective_empty(store Store, cli Cli) ! {
	scan := store.scan()
	mut selected := filter_entries(scan.entries, ListFilter{
		all:                true
		older_than_seconds: cli.older_than_seconds
		kind:               cli.kind
		grep:               cli.grep
	})
	if cli.keep > 0 {
		selected = if selected.len > cli.keep { selected[cli.keep..] } else { []Entry{} }
	}
	if cli.dry_run {
		if cli.json {
			println(json2.encode(EmptyReport{ emptied: selected.len, dry_run: true },
				escape_unicode: true
			))
		} else if !cli.quiet {
			for entry in selected {
				println('Would purge ${entry.original_path}')
			}
			println('Would permanently delete ${selected.len} selected item(s).')
		}
		return
	}
	if selected.len == 0 {
		if cli.json {
			println(json2.encode(EmptyReport{ emptied: 0, dry_run: false }, escape_unicode: true))
		} else if !cli.quiet {
			println('No items match the retention policy.')
		}
		return
	}
	if !cli.yes {
		if os.is_atty(0) == 0 {
			return error('refusing to purge selected items without --yes in non-interactive mode')
		}
		ans := os.input('Permanently delete ${selected.len} selected item(s)? [y/N] ').trim_space().to_lower()
		if ans != 'y' && ans != 'yes' {
			println('Aborted.')
			return
		}
	}
	batch := store.purge_batch(selected)!
	if batch.purged > 0 {
		store.gc()!
	}
	if cli.json {
		println(json2.encode(EmptyReport{
			emptied: batch.purged
			dry_run: false
		}, escape_unicode: true))
	} else if !cli.quiet {
		println('Purged ${batch.purged} selected item(s).')
	}
	if batch.failures.len > 0 {
		return error('${batch.failures.len} item(s) could not be purged')
	}
}

fn run_where(store Store, cli Cli) ! {
	stats := store.stats()
	report := WhereReport{
		root:   store.root
		items:  stats.items
		broken: stats.broken
		size:   stats.size
		oldest: stats.oldest
		newest: stats.newest
	}
	if cli.json {
		println(json2.encode(report, escape_unicode: true))
		return
	}
	println('${report.root}')
	println('${report.items} item(s), ${format.format_size(report.size)}')
	if report.oldest != '' {
		println('oldest ${format.format_time((time.parse(report.oldest) or { time.now() }).local())}  newest ${format.format_time((time.parse(report.newest) or { time.now() }).local())}')
	}
	if report.broken > 0 {
		println(cli.palette().red('${report.broken} broken item(s)'))
	}
}

fn run_doctor(store Store, cli Cli) ! {
	report := store.doctor(DoctorOptions{
		repair: cli.doctor_repair
		purge:  cli.doctor_purge
	})!
	if cli.json {
		println(json2.encode(report, escape_unicode: true))
		return
	}
	if report.broken == 0 {
		println('No broken items found.')
		return
	}
	for item in report.items {
		println('${format.short_id(item.id)}  ${item.reason}  [${item.action}]')
	}
	println('${report.broken} broken item(s), ${report.repaired} repaired, ${report.purged} purged.')
}

fn select_entries(entries []Entry, cli Cli) ![]Entry {
	if cli.yes {
		return entries
	}
	if os.is_atty(0) == 0 {
		return error('--select requires a terminal; use --yes to restore all matches')
	}
	for i, entry in entries {
		println('${i + 1:3}) ${format.short_id(entry.id)}  ${format.format_age(entry.trashed_at)}  ${entry.original_path}')
	}
	ans := os.input('Select item number, `a` for all, or `q` to quit: ').trim_space().to_lower()
	if ans == 'q' || ans == '' {
		return []
	}
	if ans == 'a' || ans == 'all' {
		return entries
	}
	index := strconv.atoi(ans) or {
		return error('invalid selection `${ans}`')
	}
	if index < 1 || index > entries.len {
		return error('selection out of range: ${index}')
	}
	return [entries[index - 1]]
}
