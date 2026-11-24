module trashcli

import trash

fn general_help() string {
	table := flag_table()
	mut lines := []string{}
	lines << 'trash ${trash.app_version} - safe rm replacement with recovery'
	lines << ''
	lines << 'Usage:'
	lines << '  trash [OPTIONS] <path>...'
	lines << '  trash <command> [OPTIONS] [ARGS]'
	lines << ''
	lines << 'Commands:'
	commands := command_specs()
	mut width := 0
	for spec in commands {
		width = max_width(width, spec.cmd.label())
	}
	for spec in commands {
		lines << '  ${pad_right(spec.cmd.label(), width + 3)}${spec.summary}'
	}
	lines << ''
	lines << 'Global options:'
	lines << option_lines(table.specs.filter(it.commands.len == 0))
	lines << ''
	lines << 'Examples:'
	for example in general_examples() {
		lines << '  ${example}'
	}
	return lines.join('\n') + '\n'
}

fn command_help(c Command) string {
	spec := command_spec(c) or { return 'Usage: trash ${c.label()}\n' }
	mut lines := []string{}
	lines << 'Usage: ${spec.usage}'
	lines << ''
	for line in spec.description.split_into_lines() {
		lines << line
	}
	if c in [.help, .version] {
		return lines.join('\n') + '\n'
	}
	table := flag_table()
	mut specs := []FlagSpec{}
	for flag in table.specs {
		if c in flag.commands {
			specs << flag
		}
	}
	// --store is global but accepted by every command, so keep it listed.
	specs << table.spec(.store)
	lines << ''
	lines << 'Options:'
	lines << option_lines(specs)
	if spec.examples.len > 0 {
		lines << ''
		lines << 'Examples:'
		for example in spec.examples {
			lines << '  ${example}'
		}
	}
	return lines.join('\n') + '\n'
}

// option_lines renders a help block with the flag labels aligned.
fn option_lines(specs []FlagSpec) []string {
	mut width := 0
	for spec in specs {
		width = max_width(width, spec.label())
	}
	mut lines := []string{}
	for spec in specs {
		lines << '  ${pad_right(spec.label(), width + 2)}${spec.help}'
	}
	return lines
}

fn print_help(cli Cli) {
	if cmd := cli.help_command {
		print(command_help(cmd))
	} else {
		print(general_help())
	}
}
