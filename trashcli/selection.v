module trashcli

import internal.format
import os
import strconv

@[params]
pub struct SelectionOptions {
pub:
	targets            []string
	all                bool
	recursive          bool
	kind               string
	grep               string
	older_than_seconds i64
	sort               string
	limit              int
	keep               int
	cwd                string
}

// selection_options builds SelectionOptions from parsed CLI flags.
fn selection_options(cli Cli, cwd string) SelectionOptions {
	return SelectionOptions{
		targets:            cli.targets
		all:                cli.all
		recursive:          cli.recursive
		kind:               cli.kind
		grep:               cli.grep
		older_than_seconds: cli.older_than_seconds
		sort:               cli.sort
		limit:              cli.limit
		keep:               cli.keep
		cwd:                cwd
	}
}

// resolve_selection builds the common item set used by list, restore and empty.
// Items are ordered newest first unless --sort changes the order.
pub fn resolve_selection(entries []Entry, opts SelectionOptions) ![]Entry {
	if opts.all && opts.targets.len > 0 {
		return error('--all cannot be combined with targets')
	}
	if opts.all && opts.recursive {
		return error('--all and --recursive cannot be combined')
	}
	mut base := if opts.targets.len > 0 {
		collect_targets(entries, opts.targets, opts.recursive)!
	} else {
		filter_entries(entries,
			cwd:       if opts.all { '' } else { opts.cwd }
			recursive: opts.recursive
			all:       opts.all
		)
	}
	// --keep protects the newest N items of the base set before filters run,
	// so retention never deletes the newest items even when a filter matches.
	if opts.keep > 0 {
		base = if base.len > opts.keep { base[opts.keep..] } else { []Entry{} }
	}
	return filter_entries(base,
		all:                true
		kind:               opts.kind
		grep:               opts.grep
		older_than_seconds: opts.older_than_seconds
		sort:               opts.sort
		limit:              opts.limit
	)
}

struct RefResolution {
mut:
	entries  []Entry
	warnings []string
	failed   int
}

// resolve_refs resolves targets in argument order. Within one target the
// matched entries keep their store order (newest first) and duplicates across
// targets are dropped. When tolerant is false an unresolvable target aborts
// with the regular not-found/ambiguous error; when it is true the ref is
// reported as a warning, skipped, and counted in failed.
fn resolve_refs(entries []Entry, refs []string, recursive bool, tolerant bool) !RefResolution {
	mut selected := []Entry{}
	mut seen := map[string]bool{}
	mut warnings := []string{}
	mut failed := 0
	for ref in refs {
		candidate := canonical_target_path(ref)
		mut failure := ''
		mut matched := find_in(entries, ref) or {
			failure = err.msg()
			[]Entry{}
		}
		if recursive {
			for entry in entries {
				if is_path_within(entry.original_path, candidate) {
					matched << entry
				}
			}
		}
		if matched.len == 0 {
			if !tolerant {
				// Surface the regular not-found/ambiguous error for this target.
				_ := find_in(entries, ref)!
			}
			if failure != '' {
				warnings << '${failure} (skipped)'
				failed++
			}
			continue
		}
		for entry in matched {
			if entry.id in seen {
				continue
			}
			seen[entry.id] = true
			selected << entry
		}
	}
	return RefResolution{
		entries:  selected
		warnings: warnings
		failed:   failed
	}
}

fn collect_targets(entries []Entry, targets []string, recursive bool) ![]Entry {
	res := resolve_refs(entries, targets, recursive, false)!
	mut selected := res.entries.clone()
	selected.sort(a.id > b.id)
	return selected
}

// parse_selection_input parses "1,3-5" / "a" / "q" into zero-based indices.
fn parse_selection_input(answer string, count int) ![]int {
	text := answer.trim_space().to_lower()
	if text == '' || text == 'q' || text == 'quit' {
		return []int{}
	}
	if text == 'a' || text == 'all' {
		mut all := []int{cap: count}
		for i in 0 .. count {
			all << i
		}
		return all
	}
	mut picked := []int{}
	mut seen := map[int]bool{}
	for part in text.split(',') {
		piece := part.trim_space()
		if piece == '' {
			return error('invalid selection `${answer}`')
		}
		if piece.contains('-') {
			bounds := piece.split('-')
			if bounds.len != 2 {
				return error('invalid selection `${piece}`')
			}
			start := strconv.atoi(bounds[0].trim_space()) or {
				return error('invalid selection `${piece}`')
			}
			end := strconv.atoi(bounds[1].trim_space()) or {
				return error('invalid selection `${piece}`')
			}
			if start < 1 || end < start || end > count {
				return error('selection out of range `${piece}`')
			}
			stop := end + 1
			for index in start .. stop {
				if (index - 1) in seen {
					continue
				}
				seen[index - 1] = true
				picked << index - 1
			}
		} else {
			index := strconv.atoi(piece) or {
				return error('invalid selection `${piece}`')
			}
			if index < 1 || index > count {
				return error('selection out of range `${index}`')
			}
			if (index - 1) in seen {
				continue
			}
			seen[index - 1] = true
			picked << index - 1
		}
	}
	return picked
}

// prompt_selection prints the candidate list and asks for a multi-selection.
fn prompt_selection(entries []Entry) ![]Entry {
	if os.is_atty(0) == 0 {
		return error('-i/--interactive requires a terminal')
	}
	if entries.len == 0 {
		return []Entry{}
	}
	for i, entry in entries {
		println('${i + 1:3}) ${format.short_id(entry.id)}  ${format.format_age(entry.trashed_at)}  ${entry.original_path}')
	}
	mut done := false
	mut picked := []Entry{}
	for !done {
		answer := os.input('Select items (1,3-5), a=all, q=quit: ')
		indices := parse_selection_input(answer, entries.len) or {
			eprintln('error: ${err.msg()}')
			continue
		}
		done = true
		for index in indices {
			picked << entries[index]
		}
	}
	return picked
}

// selection_scope describes the selected area for confirmation prompts.
fn selection_scope(cli Cli, cwd string) string {
	if cli.all {
		return ' from the whole trash'
	}
	if cli.targets.len > 0 {
		return ''
	}
	if cli.recursive {
		return ' from ${cwd} and its subdirectories'
	}
	return ' from ${cwd}'
}

// confirm_action asks for confirmation unless --yes is set. Single-item
// restores are not confirmed; destructive actions always are.
fn confirm_action(count int, verb string, scope string, cli Cli, always bool) !bool {
	if cli.yes {
		return true
	}
	if !always && count <= 1 {
		return true
	}
	if os.is_atty(0) == 0 {
		return error('refusing to ${verb.to_lower()} ${count} item(s) without --yes in non-interactive mode')
	}
	answer := os.input('${verb} ${count} item(s)${scope}? [y/N] ').trim_space().to_lower()
	return answer == 'y' || answer == 'yes'
}
