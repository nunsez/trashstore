module trashcli

import internal.format
import internal.pathx
import os
import strconv
import trash

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
	// limit is the maximum number of entries after ordering. Negative means no
	// limit; zero selects nothing.
	limit int = -1
	keep  int
	cwd   string
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
		limit:              if cli.limit_set { cli.limit } else { -1 }
		keep:               cli.keep
		cwd:                cwd
	}
}

fn identity_sizes(entries []trash.Entry) []trash.Entry {
	return entries
}

// select applies the shared selection pipeline used by list, restore and empty:
// resolve refs -> scope -> keep -> predicates -> size -> sort -> limit. The
// tail (predicates -> size -> sort -> limit) is trash.select_entries, so the
// library and the CLI cannot drift apart. Sizes are measured only after
// predicates and only when sorting by size, and always before the limit so
// `--limit 1 --sort size` returns the largest match.
pub fn select(entries []trash.Entry, opts SelectionOptions, fill trash.SizeFiller) ![]trash.Entry {
	if opts.all && opts.targets.len > 0 {
		return error('--all cannot be combined with targets')
	}
	if opts.all && opts.recursive {
		return error('--all and --recursive cannot be combined')
	}
	base := if opts.targets.len > 0 {
		collect_targets(entries, opts.targets, opts.recursive)!
	} else {
		trash.filter_scope(entries, opts.cwd, opts.recursive, opts.all)
	}
	// --keep protects the newest N items of the base set before filters run,
	// so retention never deletes the newest items even when a filter matches.
	kept := if opts.keep > 0 {
		if base.len > opts.keep { base[opts.keep..] } else { []trash.Entry{} }
	} else {
		base
	}
	return trash.select_entries(kept, trash.ListFilter{
		kind:               opts.kind
		grep:               opts.grep
		older_than_seconds: opts.older_than_seconds
		sort:               opts.sort
		limit:              opts.limit
	}, fill)
}

// resolve_selection is the store-less variant of select, kept for callers that
// already have sizes (or do not sort by size).
pub fn resolve_selection(entries []trash.Entry, opts SelectionOptions) ![]trash.Entry {
	return select(entries, opts, identity_sizes)
}

struct RefResolution {
mut:
	entries  []trash.Entry
	warnings []string
	failed   int
}

// resolve_refs resolves targets in argument order. Within one target the
// matched entries keep their store order (newest first) and duplicates across
// targets are dropped. When tolerant is false an unresolvable target aborts
// with the regular not-found/ambiguous error; when it is true the ref is
// reported as a warning, skipped, and counted in failed.
fn resolve_refs(entries []trash.Entry, refs []string, recursive bool, tolerant bool) !RefResolution {
	mut selected := []trash.Entry{}
	mut seen := map[string]bool{}
	mut warnings := []string{}
	mut failed := 0
	for ref in refs {
		candidate := pathx.canonical_target_path(ref)
		mut failure := ''
		mut matched := trash.find_in(entries, ref) or {
			failure = err.msg()
			[]trash.Entry{}
		}
		if recursive {
			for entry in entries {
				if pathx.is_path_within(entry.original_path, candidate) {
					matched << entry
				}
			}
		}
		if matched.len == 0 {
			if !tolerant {
				// Surface the regular not-found/ambiguous error for this target.
				_ := trash.find_in(entries, ref)!
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

fn collect_targets(entries []trash.Entry, targets []string, recursive bool) ![]trash.Entry {
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
fn prompt_selection(entries []trash.Entry) ![]trash.Entry {
	if os.is_atty(0) == 0 {
		return error('-i/--interactive requires a terminal')
	}
	if entries.len == 0 {
		return []trash.Entry{}
	}
	id_len := format.short_id_length(entries.len)
	for i, entry in entries {
		println('${i + 1:3}) ${sanitize_display(format.short_id_len(entry.id, id_len))}  ${format.format_age(entry.trashed_at)}  ${sanitize_display(entry.original_path)}')
	}
	mut done := false
	mut picked := []trash.Entry{}
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
