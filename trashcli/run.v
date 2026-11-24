module trashcli

import internal.format
import json2
import os
import time

struct EmptyReport {
	emptied int
	dry_run bool
}

struct EmptyPlan {
	emptied int
	dry_run bool
	items   []JsonEntry
}

struct StatsReport {
	root    string
	items   int
	broken  int
	size    u64
	unknown int
	oldest  string
	newest  string
}

struct RestorePlan {
	id            string
	original_path string
	restored_to   string
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

	store := open_with(resolve_store(cli.store)!, sync: !cli.no_sync)!
	if cli.no_sync {
		eprintln(cli.palette().red('warning:') + ' --no-sync disables fsync durability guarantees')
	}
	recovery := store.recover_if_needed()!
	if recovery.recovered > 0 && cli.verbose {
		eprintln('Recovered ${recovery.recovered} interrupted trash operation(s).')
	}
	for warning in recovery.warnings {
		eprintln(cli.palette().red('warning:') + ' ' + warning)
	}

	match cli.command {
		.put { run_put(store, cli)! }
		.list { run_list(store, cli)! }
		.restore { run_restore(store, cli)! }
		.empty { run_empty(store, cli)! }
		.where { run_where(store, cli)! }
		.stats { run_stats(store, cli)! }
		.doctor { run_doctor(store, cli)! }
		.help, .version {}
	}
}

fn warn_broken(broken []BrokenItem, cli Cli) {
	p := cli.palette()
	for item in broken {
		eprintln(p.red('warning:') + ' broken trash item ${format.short_id(item.id)}: ${item.reason}')
	}
}

fn run_put(store Store, cli Cli) ! {
	interactive := cli.preview || cli.interactive
	if !cli.dry_run && !interactive {
		batch := store.put_many(cli.targets, recursive: cli.recursive)!
		if cli.verbose {
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
	if interactive && !cli.yes && !cli.dry_run && os.is_atty(0) == 0 {
		return error('-i/--interactive requires a terminal; use --yes to skip the prompt')
	}
	mut failures := []string{}
	for target in cli.targets {
		planned := store.plan_put(target, recursive: cli.recursive) or {
			failures << 'Failed to trash ${target}: ${err.msg()}'
			continue
		}
		if interactive {
			print_preview_info(planned.original_path)
		}
		if cli.dry_run {
			println('Would trash ${planned.original_path}')
			continue
		}
		if interactive && !cli.yes {
			ans := os.input('Send ${planned.original_path} to the trash? (y/n) ').trim_space().to_lower()
			if ans != 'y' && ans != 'yes' {
				continue
			}
		}
		entry := store.put(target, recursive: cli.recursive) or {
			failures << 'Failed to trash ${target}: ${err.msg()}'
			continue
		}
		if cli.verbose {
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
	mut entries := select_entries(store, scan.entries, cli, cwd)!
	if cli.ids {
		for entry in entries {
			println(entry.id)
		}
		return
	}
	if !cli.no_size {
		entries = store.fill_sizes(entries)
	}
	if cli.json {
		println(json2.encode(json_entries(entries), escape_unicode: true))
		return
	}
	if entries.len == 0 {
		if cli.all {
			println('Trash is empty.')
		} else {
			println('No items trashed from ${cwd}.')
		}
		return
	}
	print_table(entries, cwd, cli.long, cli.palette())
}

// select_entries resolves the common selection used by list, restore and empty.
// Sorting by size measures every candidate first, because sizes are filled
// lazily and would otherwise all sort as zero.
fn select_entries(store Store, entries []Entry, cli Cli, cwd string) ![]Entry {
	if cli.sort == 'size' {
		return size_ordered_selection(store, entries, cli, cwd)
	}
	return resolve_selection(entries, selection_options(cli, cwd))
}

// size_ordered_selection resolves the selection and measures every candidate
// before applying --sort size.
fn size_ordered_selection(store Store, entries []Entry, cli Cli, cwd string) ![]Entry {
	opts := selection_options(cli, cwd)
	candidates := resolve_selection(entries, SelectionOptions{
		targets:            opts.targets
		all:                opts.all
		recursive:          opts.recursive
		kind:               opts.kind
		grep:               opts.grep
		older_than_seconds: opts.older_than_seconds
		keep:               opts.keep
		cwd:                opts.cwd
	})!
	measured := store.fill_sizes(candidates)
	return filter_entries(measured, ListFilter{
		all:                true
		kind:               opts.kind
		grep:               opts.grep
		older_than_seconds: opts.older_than_seconds
		sort:               opts.sort
		limit:              opts.limit
	})
}

fn run_restore(store Store, cli Cli) ! {
	scan := store.scan()
	warn_broken(scan.broken, cli)
	cwd := canonical_path(os.getwd())
	mut selected := select_entries(store, scan.entries, cli, cwd)!
	if selected.len == 0 {
		if cli.json {
			println('[]')
		} else {
			if cli.all {
				println('Trash is empty.')
			} else {
				println('No items trashed from ${cwd}.')
			}
		}
		return
	}
	if cli.interactive {
		selected = prompt_selection(selected)!
		if selected.len == 0 {
			return
		}
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
			if !cli.json {
				println('Would restore ${entry.original_path} -> ${target}')
			}
		}
		if cli.json {
			println(json2.encode(plans, escape_unicode: true))
		}
		return
	}
	if !confirm_action(selected.len, 'Restore', selection_scope(cli, cwd), cli, false)! {
		println('Aborted.')
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
	} else {
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

fn run_empty(store Store, cli Cli) ! {
	scan := store.scan()
	warn_broken(scan.broken, cli)
	cwd := canonical_path(os.getwd())
	if empty_whole_trash(cli) && !cli.dry_run {
		return run_empty_whole(store, cli, cwd)
	}
	mut selected := select_entries(store, scan.entries, cli, cwd)!
	if selected.len == 0 {
		if cli.json {
			if cli.dry_run {
				println(json2.encode(EmptyPlan{
					emptied: 0
					dry_run: true
					items:   []JsonEntry{}
				}, escape_unicode: true))
			} else {
				println(json2.encode(EmptyReport{ emptied: 0, dry_run: false },
					escape_unicode: true
				))
			}
		} else {
			if cli.all {
				println('Trash is empty.')
			} else {
				println('No items trashed from ${cwd}.')
			}
		}
		return
	}
	if cli.interactive {
		selected = prompt_selection(selected)!
		if selected.len == 0 {
			return
		}
	}
	if cli.dry_run {
		if cli.json {
			println(json2.encode(EmptyPlan{
				emptied: selected.len
				dry_run: true
				items:   json_entries(selected)
			}, escape_unicode: true))
		} else {
			for entry in selected {
				println('Would permanently delete ${entry.original_path}')
			}
			println('Would permanently delete ${selected.len} item(s)${selection_scope(cli, cwd)}.')
		}
		return
	}
	if !confirm_action(selected.len, 'Permanently delete', selection_scope(cli, cwd), cli, true)! {
		println('Aborted.')
		return
	}
	batch := store.empty_batch(selected)!
	if batch.emptied > 0 && cli.wait {
		store.gc()!
	}
	if cli.json {
		println(json2.encode(EmptyReport{
			emptied: batch.emptied
			dry_run: false
		}, escape_unicode: true))
	} else {
		println('Permanently deleted ${batch.emptied} item(s).')
	}
	if batch.failures.len > 0 {
		for failure in batch.failures {
			eprintln(cli.palette().red('error:') + ' ${failure.id}: ${failure.message}')
		}
		return error('${batch.failures.len} item(s) could not be deleted')
	}
}

// empty_whole_trash reports whether the selection covers the entire trash,
// so the concurrency-safe whole-store empty path can be used.
fn empty_whole_trash(cli Cli) bool {
	return cli.all && cli.targets.len == 0 && !cli.recursive && !cli.interactive
		&& cli.kind == '' && cli.grep == '' && cli.older_than_seconds == 0 && cli.keep == 0
		&& cli.limit == 0
}

fn run_empty_whole(store Store, cli Cli, cwd string) ! {
	count := store.count_items()
	if count == 0 {
		if cli.json {
			println(json2.encode(EmptyReport{ emptied: 0, dry_run: false }, escape_unicode: true))
		} else {
			println('Trash is already empty.')
		}
		return
	}
	if !confirm_action(count, 'Permanently delete', selection_scope(cli, cwd), cli, true)! {
		println('Aborted.')
		return
	}
	n := store.empty_wait(cli.wait)!
	if cli.json {
		println(json2.encode(EmptyReport{ emptied: n, dry_run: false }, escape_unicode: true))
	} else {
		println('Emptied ${n} item(s) from ${store.root}.')
	}
}

fn run_stats(store Store, cli Cli) ! {
	stats := store.stats()
	report := StatsReport{
		root:    store.root
		items:   stats.items
		broken:  stats.broken
		size:    stats.size
		unknown: stats.unknown
		oldest:  stats.oldest
		newest:  stats.newest
	}
	if cli.json {
		println(json2.encode(report, escape_unicode: true))
		return
	}
	println('${report.root}')
	println('${report.items} item(s), ${format.format_size(report.size)}${unknown_suffix(report.unknown)}')
	if report.oldest != '' {
		println('oldest ${format.format_time(time.parse(report.oldest) or { time.now() })}  newest ${format.format_time(time.parse(report.newest) or { time.now() })}')
	}
	if report.broken > 0 {
		println(cli.palette().red('${report.broken} broken item(s)'))
	}
}

struct WhereInput {
	refs       []string
	from_stdin bool
}

// read_where_input decides where the refs to resolve come from. Explicit
// positional targets always win; otherwise piped stdin is read. A terminal
// with neither is an error, because `where` is a locator, not a selection.
fn read_where_input(cli Cli) !WhereInput {
	if cli.targets.len > 0 {
		return WhereInput{
			refs:       cli.targets
			from_stdin: false
		}
	}
	if os.is_atty(0) != 0 {
		return error('`where` requires a target or refs on stdin\nhint: use `trash list --ids | trash where`, or `trash stats` for a summary')
	}
	mut refs := []string{}
	text := os.fd_slurp(0).join('')
	for line in text.split_into_lines() {
		ref := line.trim_space()
		if ref != '' {
			refs << ref
		}
	}
	if refs.len == 0 {
		return error('no targets and no refs on stdin')
	}
	return WhereInput{
		refs:       refs
		from_stdin: true
	}
}

fn run_where(store Store, cli Cli) ! {
	scan := store.scan()
	warn_broken(scan.broken, cli)
	input := read_where_input(cli)!
	resolution := resolve_refs(scan.entries, input.refs, cli.recursive, input.from_stdin)!
	selected := filter_entries(resolution.entries, ListFilter{
		all:                true
		kind:               cli.kind
		grep:               cli.grep
		older_than_seconds: cli.older_than_seconds
	})
	mut locations := []JsonLocation{cap: selected.len}
	for entry in selected {
		locations << JsonLocation{
			id:       entry.id
			location: store.payload_path(entry.id)
		}
	}
	if cli.json {
		println(json2.encode(locations, escape_unicode: true))
	} else {
		for item in locations {
			println(item.location)
		}
	}
	if resolution.failed > 0 {
		return error('${resolution.failed} ref(s) could not be resolved')
	}
}

fn run_doctor(store Store, cli Cli) ! {
	report := store.doctor(
		repair: cli.doctor_repair
		purge:  cli.doctor_purge
	)!
	if cli.json {
		println(json2.encode(report, escape_unicode: true))
		return
	}
	if report.broken == 0 {
		println('No broken items found.')
	} else {
		for item in report.items {
			println('${format.short_id(item.id)}  ${item.reason}  [${item.action}]')
		}
		println('${report.broken} broken item(s), ${report.repaired} repaired, ${report.purged} purged.')
	}
	if cli.doctor_repair {
		println('${report.sized} size(s) measured, ${report.unknown} size(s) unknown.')
	}
}
