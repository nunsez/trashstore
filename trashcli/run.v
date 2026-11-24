module trashcli

import internal.format
import internal.pathx
import json2
import os
import time
import trash

struct EmptyReport {
	emptied int
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
			println('${trash.app_name} ${trash.app_version} (sqlite ${trash.engine_version()})')
			return
		}
		else {}
	}
	if cli.command == .put && cli.force {
		mut any_target := false
		for target in cli.targets {
			if os.exists(target) || os.is_link(target) {
				any_target = true
				break
			}
		}
		if !any_target {
			return
		}
	}

	store_path := resolve_store(cli.store)!
	mut store := open_store_or_reset(store_path, cli)!
	defer {
		store.close()
	}
	recovery := store.recover_if_needed()!
	for warning in recovery.warnings {
		eprintln(cli.palette().red('warning:') + ' ' + warning)
	}
	if recovery.recovered > 0 && cli.verbose {
		eprintln('Recovered ${recovery.recovered} interrupted trash operation(s).')
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

fn warn_broken(broken []trash.BrokenItem, cli Cli) {
	p := cli.palette()
	for item in broken {
		eprintln(p.red('warning:') + ' broken trash item ${format.short_id(item.id)}: ${item.reason}')
	}
}

fn run_put(store trash.Store, cli Cli) ! {
	interactive := cli.preview || cli.interactive
	if !interactive {
		batch := store.put_many(cli.targets, recursive: cli.recursive)!
		if cli.verbose {
			for entry in batch.entries {
				println('Trashed ${entry.original_path} (${format.short_id(entry.id)})')
			}
		}
		if batch.failures.len > 0 {
			mut failures := []string{}
			for failure in batch.failures {
				if cli.force && failure.kind == .not_found {
					continue
				}
				failures << 'Failed to trash ${failure.subject}: ${failure.message}'
			}
			if failures.len > 0 {
				return error(failures.join('\n'))
			}
		}
		return
	}
	if interactive && !cli.yes && os.is_atty(0) == 0 {
		return error('-i/--interactive requires a terminal; use --yes to skip the prompt')
	}
	mut failures := []string{}
	for target in cli.targets {
		planned := store.plan_put(target, recursive: cli.recursive) or {
			if cli.force && err is trash.TrashError && err.kind == .not_found {
				continue
			}
			failures << 'Failed to trash ${target}: ${err.msg()}'
			continue
		}
		if interactive {
			print_preview_info(planned.original_path)
		}
		if interactive && !cli.yes {
			ans := os.input('Send ${planned.original_path} to the trash? (y/n) ').trim_space().to_lower()
			if ans != 'y' && ans != 'yes' {
				continue
			}
		}
		entry := store.put(target, recursive: cli.recursive) or {
			if cli.force && err is trash.TrashError && err.kind == .not_found {
				continue
			}
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

fn run_list(store trash.Store, cli Cli) ! {
	scan := store.scan()
	warn_broken(scan.broken, cli)
	cwd := pathx.canonical_path(os.getwd())
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
// The store-backed filler measures sizes lazily, before sorting and limiting.
fn select_entries(store trash.Store, entries []trash.Entry, cli Cli, cwd string) ![]trash.Entry {
	fill := fn [store] (candidates []trash.Entry) []trash.Entry {
		return store.fill_sizes(candidates)
	}
	return select(entries, selection_options(cli, cwd), fill)
}

fn run_restore(store trash.Store, cli Cli) ! {
	scan := store.scan()
	warn_broken(scan.broken, cli)
	cwd := pathx.canonical_path(os.getwd())
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
			eprintln(cli.palette().red('error:') + ' ${failure.subject}: ${failure.message}')
		}
		return error('${batch.failures.len} item(s) could not be restored')
	}
}

fn run_empty(store trash.Store, cli Cli) ! {
	scan := store.scan()
	warn_broken(scan.broken, cli)
	cwd := pathx.canonical_path(os.getwd())
	mut selected := select_entries(store, scan.entries, cli, cwd)!
	// Broken items (orphan payloads, rows without a payload) are never deleted
	// unless --include-broken explicitly asks for it.
	broken_targets := if cli.include_broken { scan.broken.len } else { 0 }
	if selected.len == 0 && broken_targets == 0 {
		if cli.json {
			println(json2.encode(EmptyReport{ emptied: 0 }, escape_unicode: true))
		} else {
			if cli.all {
				println('Trash is empty.')
			} else {
				println('No items trashed from ${cwd}.')
			}
		}
		return
	}
	if cli.interactive && selected.len > 0 {
		selected = prompt_selection(selected)!
		if selected.len == 0 {
			return
		}
	}
	total := selected.len + broken_targets
	if !confirm_action(total, 'Permanently delete', selection_scope(cli, cwd), cli, true)! {
		println('Aborted.')
		return
	}
	batch := store.empty_batch(selected)!
	if cli.include_broken {
		// doctor --purge detaches broken item directories into .gc and cleans up.
		report := store.doctor(purge: true)!
		for item in report.items {
			if item.action != 'purged' {
				eprintln(cli.palette().red('warning:') + ' could not remove broken item ${format.short_id(item.id)}: ${item.reason} (${item.action})')
			}
		}
	} else if batch.emptied > 0 && cli.wait {
		store.gc()!
	}
	if cli.json {
		println(json2.encode(EmptyReport{ emptied: batch.emptied }, escape_unicode: true))
	} else {
		println('Permanently deleted ${batch.emptied} item(s).')
	}
	if batch.failures.len > 0 {
		for failure in batch.failures {
			eprintln(cli.palette().red('error:') + ' ${failure.subject}: ${failure.message}')
		}
		return error('${batch.failures.len} item(s) could not be deleted')
	}
}

fn run_stats(store trash.Store, cli Cli) ! {
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

fn run_where(store trash.Store, cli Cli) ! {
	scan := store.scan()
	warn_broken(scan.broken, cli)
	input := read_where_input(cli)!
	resolution := resolve_refs(scan.entries, input.refs, cli.recursive, input.from_stdin)!
	for warning in resolution.warnings {
		eprintln(cli.palette().red('warning:') + ' ' + warning)
	}
	selected := trash.filter_criteria(resolution.entries, trash.ListFilter{
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

fn run_doctor(store trash.Store, cli Cli) ! {
	report := store.doctor(
		repair:          cli.doctor_repair
		purge:           cli.doctor_purge
		integrity_check: cli.doctor_integrity
		compact:         cli.doctor_compact
		backup:          cli.doctor_backup
		rebuild:         cli.doctor_rebuild
		reindex:         cli.doctor_reindex
	)!
	if cli.json {
		println(json2.encode(report, escape_unicode: true))
		return
	}
	mut printed := false
	if report.integrity != '' {
		println('integrity: ${report.integrity}')
		printed = true
	}
	if report.rebuilt > 0 {
		println('Rebuilt ${report.rebuilt} item(s) from payloads; their original paths are unknown.')
		printed = true
	}
	if report.reindexed {
		println('Reindexed.')
		printed = true
	}
	if report.compacted {
		println('Compacted.')
		printed = true
	}
	if report.backup != '' {
		println('Backup written to ${report.backup}.')
		printed = true
	}
	if report.broken == 0 {
		if !printed {
			println('No broken items found.')
		}
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

fn open_store_or_reset(path string, cli Cli) !trash.Store {
	return trash.open_with(path) or {
		if err is trash.TrashError && err.kind == .schema_mismatch {
			if cli.reset_store {
				confirm_reset(path, err, true)!
			} else if os.is_atty(0) != 0 {
				confirm_reset(path, err, false)!
			} else {
				return error('${err.msg()}\nhint: re-run interactively to wipe the store, or pass --reset-store')
			}
			return trash.open_with(path)
		}
		return err
	}
}

fn confirm_reset(path string, err IError, assume_yes bool) ! {
	if !assume_yes {
		eprintln(err.msg())
		eprintln('Wiping `${path}` permanently deletes every trashed item.')
		eprint('Wipe the store and start fresh? [y/N] ')
		answer := os.get_line().trim_space().to_lower()
		if answer != 'y' && answer != 'yes' {
			return error('store left unchanged; install the previous version of trash to keep using it')
		}
	}
	trash.reset_store(path)!
}
