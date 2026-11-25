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

struct StatsRootReport {
	root    string
	items   int
	broken  int
	size    u64
	unknown int
	oldest  string
	newest  string
}

struct StatsReport {
mut:
	root    string
	roots   []StatsRootReport
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

struct DoctorStoreReport {
	root   string
	report trash.DoctorReport
}

struct DoctorAllReport {
mut:
	roots     []DoctorStoreReport
	broken    int
	repaired  int
	purged    int
	sized     int
	unknown   int
	rebuilt   int
	compacted bool
	reindexed bool
}

struct PutPlan {
	target string
	store  TargetStore
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

	spec := resolve_store_spec(cli.store)!
	mut set := new_store_set(cli, spec)!
	defer {
		set.close()
		set.diag.flush()
	}
	match cli.command {
		.put {
			run_put(mut set, cli)!
		}
		.list {
			cwd := current_dir()!
			set.open_for_read(cli, cwd)!
			run_list(mut set, cli, cwd)!
		}
		.restore {
			cwd := current_dir()!
			set.open_for_read(cli, cwd)!
			run_restore(mut set, cli, cwd)!
		}
		.empty {
			cwd := current_dir()!
			set.open_for_read(cli, cwd)!
			run_empty(mut set, cli, cwd)!
		}
		.where {
			cwd := current_dir()!
			set.open_for_read(cli, cwd)!
			run_where(mut set, cli)!
		}
		.stats {
			cwd := current_dir()!
			set.open_for_read(cli, cwd)!
			run_stats(mut set, cli)!
		}
		.doctor {
			cwd := current_dir()!
			set.open_for_read(cli, cwd)!
			run_doctor(mut set, cli)!
		}
		.help, .version {}
	}
}

fn current_dir() !string {
	cwd := os.getwd()
	if cwd == '' {
		return error('cannot determine the current directory; use an absolute path or change to a valid directory')
	}
	return pathx.canonical_path(cwd)
}

fn run_put(mut set StoreSet, cli Cli) ! {
	interactive := cli.preview || cli.interactive
	if interactive && !cli.yes && os.is_atty(0) == 0 {
		return error('-i/--interactive requires a terminal; use --yes to skip the prompt')
	}
	mut plans := []PutPlan{}
	mut failures := []string{}
	for target in cli.targets {
		if cli.force && !os.exists(target) && !os.is_link(target) {
			continue
		}
		chosen := set.target_store(target, cli) or {
			if cli.force && err is trash.TrashError && err.kind == .not_found {
				continue
			}
			failures << 'Failed to trash ${target}: ${err.msg()}'
			continue
		}
		plans << PutPlan{
			target: target
			store:  chosen
		}
	}
	if interactive {
		mut registered := map[string]bool{}
		for plan in plans {
			store := set.stores[plan.store.root] or {
				failures << 'Failed to trash ${plan.target}: store `${plan.store.root}` is not open'
				continue
			}
			planned := store.plan_put(plan.target, recursive: cli.recursive) or {
				if cli.force && err is trash.TrashError && err.kind == .not_found {
					continue
				}
				failures << 'Failed to trash ${plan.target}: ${err.msg()}'
				continue
			}
			print_preview_info(planned.original_path)
			if !cli.yes {
				ans := os.input('Send ${planned.original_path} to the trash? (y/n) ').trim_space().to_lower()
				if ans != 'y' && ans != 'yes' {
					continue
				}
			}
			entry := store.put(plan.target, recursive: cli.recursive) or {
				if cli.force && err is trash.TrashError && err.kind == .not_found {
					continue
				}
				failures << 'Failed to trash ${plan.target}: ${err.msg()}'
				continue
			}
			if !registered[plan.store.root] {
				set.register_target(plan.store)
				registered[plan.store.root] = true
			}
			if cli.verbose {
				println('Trashed ${sanitize_display(entry.original_path)} (${sanitize_display(format.short_id(entry.id))})')
			}
		}
	} else {
		mut order := []string{}
		mut groups := map[string][]PutPlan{}
		for plan in plans {
			if plan.store.root !in groups {
				order << plan.store.root
			}
			groups[plan.store.root] << plan
		}
		for root in order {
			store := set.stores[root] or {
				failures << 'Failed to trash: store `${root}` is not open'
				continue
			}
			mut targets := []string{cap: groups[root].len}
			for plan in groups[root] {
				targets << plan.target
			}
			batch := store.put_many(targets, recursive: cli.recursive)!
			if cli.verbose {
				for entry in batch.entries {
					println('Trashed ${sanitize_display(entry.original_path)} (${sanitize_display(format.short_id(entry.id))})')
				}
			}
			for failure in batch.failures {
				if cli.force && failure.kind == .not_found {
					continue
				}
				failures << 'Failed to trash ${failure.subject}: ${failure.message}'
			}
			set.register_target(groups[root][0].store)
		}
	}
	if failures.len > 0 {
		return error(failures.join('\n'))
	}
}

fn run_list(mut set StoreSet, cli Cli, cwd string) ! {
	scan := set.scan_all()
	set.warn_broken(scan.broken)
	mut entries := select_entries(&set, scan, cli, cwd)!
	if cli.ids {
		for entry in entries {
			println(entry.id)
		}
		return
	}
	if !cli.no_size {
		entries = fill_sizes(&set, scan.roots, entries)
	}
	if cli.json {
		println(json2.encode(json_entries(entries), escape_unicode: true))
		return
	}
	if entries.len == 0 {
		if cli.all {
			println('Trash is empty.')
		} else {
			println('No items trashed from ${sanitize_display(cwd)}.')
		}
		return
	}
	print_table(entries, cwd, cli.long, cli.palette(), scan_total(scan))
}

// select_entries resolves the common selection used by list, restore and empty.
// The store-backed filler measures sizes lazily, before sorting and limiting.
fn select_entries(set &StoreSet, scan ScanAll, cli Cli, cwd string) ![]trash.Entry {
	roots := scan.roots
	fill := fn [set, roots] (candidates []trash.Entry) []trash.Entry {
		return fill_sizes(set, roots, candidates)
	}
	return select(scan.entries, selection_options(cli, cwd), fill)
}

fn run_restore(mut set StoreSet, cli Cli, cwd string) ! {
	scan := set.scan_all()
	set.warn_broken(scan.broken)
	mut selected := select_entries(&set, scan, cli, cwd)!
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
		selected = prompt_selection(selected, scan_total(scan))!
		if selected.len == 0 {
			return
		}
	}
	if !confirm_action(selected.len, 'Restore', selection_scope(cli, cwd), cli, false)! {
		println('Aborted.')
		return
	}
	order, groups := group_entries(selected, scan.roots)
	mut result_by_id := map[string]trash.RestoreResult{}
	mut failures := []trash.BatchFailure{}
	for root in order {
		store := set.stores[root] or {
			return error('store `${root}` is not open')
		}
		batch := store.restore_batch(groups[root])!
		for result in batch.results {
			result_by_id[result.entry.id] = result
		}
		failures << batch.failures
	}
	mut results := []trash.RestoreResult{cap: selected.len}
	for entry in selected {
		result := result_by_id[entry.id] or { continue }
		results << result
	}
	if cli.json {
		mut plans := []RestorePlan{cap: results.len}
		for result in results {
			plans << RestorePlan{
				id:            result.entry.id
				original_path: result.entry.original_path
				restored_to:   result.restored_to
			}
		}
		println(json2.encode(plans, escape_unicode: true))
	} else {
		for result in results {
			println('Restored ${sanitize_display(result.entry.original_path)} -> ${sanitize_display(result.restored_to)}')
		}
	}
	if failures.len > 0 {
		for failure in failures {
			eprintln(cli.palette().red('error:') + ' ${sanitize_display(failure.subject)}: ${sanitize_message(failure.message)}')
		}
		return error('${failures.len} item(s) could not be restored')
	}
}

fn run_empty(mut set StoreSet, cli Cli, cwd string) ! {
	scan := set.scan_all()
	set.warn_broken(scan.broken)
	mut selected := select_entries(&set, scan, cli, cwd)!
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
		selected = prompt_selection(selected, scan_total(scan))!
		if selected.len == 0 {
			return
		}
	}
	total := selected.len + broken_targets
	if !confirm_action(total, 'Permanently delete', selection_scope(cli, cwd), cli, true)! {
		println('Aborted.')
		return
	}
	order, groups := group_entries(selected, scan.roots)
	mut emptied := 0
	mut emptied_by_root := map[string]int{}
	mut failures := []trash.BatchFailure{}
	for root in order {
		store := set.stores[root] or {
			return error('store `${root}` is not open')
		}
		batch := store.empty_batch(groups[root])!
		emptied += batch.emptied
		emptied_by_root[root] = batch.emptied
		failures << batch.failures
	}
	mut purged_any := false
	if cli.include_broken {
		// doctor --purge detaches broken item directories into .gc and cleans up.
		for root in set.roots {
			store := set.stores[root] or { continue }
			report := store.doctor(purge: true)!
			if report.purged > 0 {
				// doctor already collected .gc, including the payloads emptied above.
				purged_any = true
			}
			for item in report.items {
				if item.action != 'purged' {
					set.diag.warn('could not remove broken item ${broken_id_label(item.id)}: ${item.reason} (${item.action})')
				}
			}
		}
	}
	// --wait is independent of --include-broken: emptied payloads must be
	// collected even when no broken item needed purging.
	if emptied > 0 && cli.wait {
		for root in order {
			if emptied_by_root[root] > 0 {
				store := set.stores[root] or { continue }
				store.gc()!
			}
		}
	}
	if cli.json {
		println(json2.encode(EmptyReport{ emptied: emptied }, escape_unicode: true))
	} else {
		println(empty_result_message(emptied, cli.wait || purged_any))
	}
	if failures.len > 0 {
		for failure in failures {
			eprintln(cli.palette().red('error:') + ' ${sanitize_display(failure.subject)}: ${sanitize_message(failure.message)}')
		}
		return error('${failures.len} item(s) could not be deleted')
	}
}

// empty_result_message describes where the payloads went. Without --wait the
// items are only moved into .gc, so claiming they were permanently deleted
// would be wrong until a later GC pass actually removes them.
fn empty_result_message(emptied int, wait bool) string {
	if emptied == 0 {
		return 'No items deleted.'
	}
	if wait {
		return 'Permanently deleted ${emptied} item(s).'
	}
	return 'Moved ${emptied} item(s) to `.gc`; they will be deleted later (use --wait to delete now).'
}

// stats_time parses the RFC3339 timestamp stored in StoreStats. A parse failure
// means the value is corrupt; substituting the current time would make `stats`
// report a plausible but wrong oldest/newest, so the error is surfaced instead.
fn stats_time(value string) !time.Time {
	return time.parse_rfc3339(value) or {
		return error('invalid timestamp `${value}` in stats: ${err.msg()}')
	}
}

fn run_stats(mut set StoreSet, cli Cli) ! {
	mut report := StatsReport{
		root: set.spec.root
	}
	for root in set.roots {
		store := set.stores[root] or { continue }
		stats := store.stats()
		report.roots << StatsRootReport{
			root:    root
			items:   stats.items
			broken:  stats.broken
			size:    stats.size
			unknown: stats.unknown
			oldest:  stats.oldest
			newest:  stats.newest
		}
		report.items += stats.items
		report.broken += stats.broken
		report.size += stats.size
		report.unknown += stats.unknown
		if stats.oldest != '' && (report.oldest == '' || stats.oldest < report.oldest) {
			report.oldest = stats.oldest
		}
		if stats.newest != '' && stats.newest > report.newest {
			report.newest = stats.newest
		}
	}
	if cli.json {
		println(json2.encode(report, escape_unicode: true))
		return
	}
	for i, root_report in report.roots {
		if report.roots.len > 1 {
			if i > 0 {
				println('')
			}
			println(sanitize_display(root_report.root))
		} else {
			println(sanitize_display(root_report.root))
		}
		println('${root_report.items} item(s), ${format.format_size(root_report.size)}${unknown_suffix(root_report.unknown)}')
		if root_report.oldest != '' {
			oldest := format.format_time(stats_time(root_report.oldest)!)
			newest := format.format_time(stats_time(root_report.newest)!)
			println('oldest ${oldest}  newest ${newest}')
		}
		if root_report.broken > 0 {
			println(cli.palette().red('${root_report.broken} broken item(s)'))
		}
	}
	if report.roots.len > 1 {
		println('')
		println('total: ${report.items} item(s), ${format.format_size(report.size)}${unknown_suffix(report.unknown)}')
		if report.oldest != '' {
			oldest := format.format_time(stats_time(report.oldest)!)
			newest := format.format_time(stats_time(report.newest)!)
			println('oldest ${oldest}  newest ${newest}')
		}
		if report.broken > 0 {
			println(cli.palette().red('${report.broken} broken item(s)'))
		}
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
		// Keep the reference byte-for-byte: a path may legitimately contain
		// leading or trailing spaces. Only the CRLF line ending is stripped.
		ref := line.trim_right('\r')
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

fn run_where(mut set StoreSet, cli Cli) ! {
	scan := set.scan_all()
	set.warn_broken(scan.broken)
	input := read_where_input(cli)!
	resolution := resolve_refs(scan.entries, input.refs, cli.recursive, input.from_stdin)!
	for warning in resolution.warnings {
		set.diag.warn(warning)
	}
	selected := trash.filter_criteria(resolution.entries, trash.ListFilter{
		kind:               cli.kind
		grep:               cli.grep
		older_than_seconds: cli.older_than_seconds
	})
	mut locations := []JsonLocation{cap: selected.len}
	for entry in selected {
		root := scan.roots[entry.id] or { continue }
		store := set.stores[root] or { continue }
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

fn run_doctor(mut set StoreSet, cli Cli) ! {
	if cli.doctor_purge && !confirm_doctor_purge(&set, cli)! {
		println('Aborted.')
		return
	}
	mut all := DoctorAllReport{}
	for root in set.roots {
		store := set.stores[root] or { continue }
		report := store.doctor(
			repair:          cli.doctor_repair
			purge:           cli.doctor_purge
			integrity_check: cli.doctor_integrity
			compact:         cli.doctor_compact
			backup:          cli.doctor_backup
			rebuild:         cli.doctor_rebuild
			reindex:         cli.doctor_reindex
		)!
		all.roots << DoctorStoreReport{
			root:   root
			report: report
		}
		all.broken += report.broken
		all.repaired += report.repaired
		all.purged += report.purged
		all.sized += report.sized
		all.unknown += report.unknown
		all.rebuilt += report.rebuilt
		all.compacted = all.compacted || report.compacted
		all.reindexed = all.reindexed || report.reindexed
	}
	if cli.json {
		println(json2.encode(all, escape_unicode: true))
		return
	}
	for i, scoped in all.roots {
		if all.roots.len > 1 {
			if i > 0 {
				println('')
			}
			println(sanitize_display(scoped.root))
		}
		set.print_doctor_report(scoped.report, cli)
	}
}

// confirm_doctor_purge asks before --doctor-purge detaches broken payloads.
// Purging is destructive, so it is confirmed even for a single item and
// requires --yes when stdin is not a terminal.
fn confirm_doctor_purge(set &StoreSet, cli Cli) !bool {
	if cli.yes {
		return true
	}
	mut count := 0
	for root in set.roots {
		store := set.stores[root] or { continue }
		count += store.scan().broken.len
	}
	if count == 0 {
		return true
	}
	return confirm_action(count, 'Purge', '', cli, true)
}

fn (mut set StoreSet) print_doctor_report(report trash.DoctorReport, cli Cli) {
	mut printed := false
	for warning in report.warnings {
		set.diag.warn(warning)
	}
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
		println('Backup written to ${sanitize_display(report.backup)}.')
		printed = true
	}
	if report.broken == 0 {
		if !printed {
			println('No broken items found.')
		}
	} else {
		for item in report.items {
			println('${sanitize_display(broken_id_label(item.id))}  ${sanitize_display(item.reason)}  [${sanitize_display(item.action)}]')
		}
		println('${report.broken} broken item(s), ${report.repaired} repaired, ${report.purged} purged.')
	}
	if cli.doctor_repair {
		println('${report.sized} size(s) measured, ${report.unknown} size(s) unknown.')
	}
}

fn open_store_or_reset(path string, cli Cli) !&trash.Store {
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
		eprintln(sanitize_message(err.msg()))
		eprintln('Wiping `${sanitize_display(path)}` permanently deletes every trashed item.')
		eprint('Wipe the store and start fresh? [y/N] ')
		answer := os.get_line().trim_space().to_lower()
		if answer != 'y' && answer != 'yes' {
			return error('store left unchanged; install the previous version of trash to keep using it')
		}
	}
	trash.reset_store(path)!
}
