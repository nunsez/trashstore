module trashcli

import os

fn is_flag_char(ch u8) bool {
	return (ch >= `a` && ch <= `z`) || (ch >= `0` && ch <= `9`) || ch == `-`
}

// docs_scan_flags extracts every `--long-name` occurrence from text. Roff
// escapes and the `\fB` markup are stripped by the caller.
fn docs_scan_flags(text string) []string {
	mut found := []string{}
	mut i := 0
	for i < text.len {
		if text[i] == `-` && i + 1 < text.len && text[i + 1] == `-` {
			mut j := i + 2
			for j < text.len && (is_flag_char(text[j])) {
				j++
			}
			if j > i + 2 {
				found << text[i + 2..j]
			}
			i = j
			continue
		}
		i++
	}
	return found
}

// man_flags returns the long flags mentioned by the man page.
fn man_flags(text string) []string {
	mut plain := text.replace('\\fB', '').replace('\\fR', '').replace('\\fI', '').replace('\\fP', '')
	plain = plain.replace('\\f[C]', '').replace('\\', '')
	return docs_scan_flags(plain)
}

// completion_flags returns the long flags mentioned by a completion script.
// Fish spells long options as `-l name` instead of `--name`.
fn completion_flags(path string, text string) []string {
	if path.ends_with('.fish') {
		mut found := []string{}
		for line in text.split_into_lines() {
			if !line.starts_with('complete ') {
				continue
			}
			if idx := line.index(' -l ') {
				rest := line[idx + 4..].trim_space()
				name := rest.split(' ')[0].trim_space()
				if name != '' {
					found << name
				}
			}
		}
		return found
	}
	return docs_scan_flags(text)
}

fn flag_names() []string {
	mut names := []string{}
	for spec in flag_specs() {
		names << spec.long
		for alias in spec.aliases {
			names << alias
		}
	}
	return names
}

fn test_flag_table_names_are_unique() {
	mut seen := map[string]bool{}
	for spec in flag_specs() {
		for name in spec.names() {
			assert !seen[name], 'duplicate flag spelling ${name}'
			seen[name] = true
		}
	}
	mut kinds := map[FlagKind]bool{}
	for spec in flag_specs() {
		assert !kinds[spec.kind], 'duplicate flag kind ${spec.kind}'
		kinds[spec.kind] = true
	}
}

fn test_docs_mention_every_flag() {
	names := flag_names()
	man := man_flags(os.read_file(os.join_path(@VMODROOT, 'trash.1')) or { panic(err) })
	for name in names {
		assert name in man, 'trash.1 does not mention --${name}'
	}
	for name in man {
		assert name in names, 'trash.1 mentions unknown flag --${name}'
	}
	for script in ['trash.bash', 'trash.zsh', 'trash.fish'] {
		path := os.join_path(@VMODROOT, 'completions', script)
		documented := completion_flags(path, os.read_file(path) or { panic(err) })
		for name in names {
			assert name in documented, '${script} does not complete --${name}'
		}
		for name in documented {
			assert name in names, '${script} completes unknown flag --${name}'
		}
	}
}

fn test_help_mentions_every_flag() {
	general := general_help()
	for spec in flag_specs() {
		if spec.commands.len == 0 {
			assert general.contains('--${spec.long}'), 'general help misses --${spec.long}'
			continue
		}
		for command in spec.commands {
			assert command_help(command).contains('--${spec.long}'), 'help ${command.label()} misses --${spec.long}'
		}
	}
}

fn test_help_has_a_command_spec_for_every_command() {
	for command in [Command.put, .list, .restore, .empty, .where, .stats, .doctor, .help, .version] {
		if _ := command_spec(command) {
			continue
		}
		assert false, 'missing help spec for ${command.label()}'
	}
}

struct ParseCase {
	args    []string
	command Command
	targets []string
}

fn test_parse_table_forms() {
	cases := [
		ParseCase{['trash', '--store=/x', 'list'], .list, []},
		ParseCase{['trash', '--store', '/x', 'list'], .list, []},
		ParseCase{['trash', '--limit=3', 'list'], .list, []},
		ParseCase{['trash', '--sort=size', 'restore'], .restore, []},
		ParseCase{['trash', '--grep', 'list', 'list'], .list, []},
		ParseCase{['trash', '--kind=file', 'where'], .where, []},
		ParseCase{['trash', 'ls'], .list, []},
		ParseCase{['trash', '-r', 'dir'], .put, ['dir']},
		ParseCase{['trash', '--', '-r'], .put, ['-r']},
		ParseCase{['trash', 'purge', 'x'], .put, ['purge', 'x']},
	]
	for case in cases {
		cli := Cli.parse(case.args) or { panic('${case.args}: ${err}') }
		assert cli.command == case.command, '${case.args} parsed as ${cli.command.label()}'
		assert cli.targets == case.targets, '${case.args} targets ${cli.targets}'
	}
	with_value := Cli.parse(['trash', '--store=/x', '--limit=3', '--kind=file', 'list']) or {
		panic(err)
	}
	assert with_value.store == '/x'
	assert with_value.limit == 3 && with_value.limit_set
	assert with_value.kind == 'file'
}

fn test_parse_rejects_value_on_boolean_flag() {
	mut failed := false
	Cli.parse(['trash', 'list', '--json=1']) or { failed = true }
	assert failed
}

fn test_parse_requires_value() {
	for args in [['trash', 'list', '--limit'], ['trash', 'list', '--sort'], [
		'trash',
		'list',
		'--kind',
	], ['trash', 'list', '--grep'], ['trash', 'list', '--older-than']] {
		mut failed := false
		Cli.parse(args) or { failed = true }
		assert failed, '${args} should fail'
	}
}

// sample_value returns a value accepted by the flag.
fn sample_value(spec FlagSpec) string {
	return match spec.kind {
		.limit, .keep { '1' }
		.older_than { '1d' }
		.sort { 'date' }
		.kind { 'file' }
		.store { '/tmp/x' }
		else { 'x' }
	}
}

fn flag_args(spec FlagSpec) []string {
	if spec.value == .none {
		return ['--${spec.long}']
	}
	return ['--${spec.long}', sample_value(spec)]
}

fn test_parse_accepts_every_flag_in_its_commands() {
	table := flag_table()
	for spec in table.specs {
		if spec.kind in [.help, .version] {
			continue
		}
		commands := if spec.commands.len == 0 { [Command.put] } else { spec.commands }
		for command in commands {
			mut args := ['trash', command.label()]
			args << flag_args(spec)
			if spec.kind == .include_broken {
				args << '--all'
			}
			if command == .put {
				args << 'file.txt'
			}
			Cli.parse(args) or { panic('${args} should parse: ${err}') }
		}
	}
}

fn test_parse_relations_from_table() {
	table := flag_table()
	for spec in table.specs {
		if spec.requires.len == 0 && spec.forbids.len == 0 {
			continue
		}
		command := spec.commands[0]
		mut args := ['trash', command.label()]
		args << flag_args(spec)
		if command == .put {
			args << 'file.txt'
		}
		for required in spec.requires {
			mut failed := false
			Cli.parse(args) or { failed = true }
			assert failed, '${args} should require --${table.spec(required).long}'
			args << flag_args(table.spec(required))
		}
		for forbidden in spec.forbids {
			mut forbidden_args := args.clone()
			forbidden_args << flag_args(table.spec(forbidden))
			mut failed := false
			Cli.parse(forbidden_args) or { failed = true }
			assert failed, '${forbidden_args} should be rejected'
		}
		Cli.parse(args) or { panic('${args} should parse: ${err}') }
	}
}
