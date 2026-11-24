module trashcli

import internal.pathx
import os
import strconv

pub enum Command {
	put
	list
	restore
	empty
	where
	stats
	doctor
	help
	version
}

// label returns the user-facing command name.
pub fn (c Command) label() string {
	return match c {
		.put { 'put' }
		.list { 'list' }
		.restore { 'restore' }
		.empty { 'empty' }
		.where { 'where' }
		.stats { 'stats' }
		.doctor { 'doctor' }
		.help { 'help' }
		.version { 'version' }
	}
}

fn command_from_name(name string) ?Command {
	return match name {
		'put' { .put }
		'list', 'ls' { .list }
		'restore' { .restore }
		'empty' { .empty }
		'where' { .where }
		'stats' { .stats }
		'doctor' { .doctor }
		'help' { .help }
		'version' { .version }
		else { none }
	}
}

pub struct Cli {
pub mut:
	command            Command = .put
	help_command       ?Command
	store              string
	verbose            bool
	no_color           bool
	reset_store        bool
	json               bool
	all                bool
	recursive          bool
	preview            bool
	interactive        bool
	dry_run            bool
	yes                bool
	long               bool
	ids                bool
	limit              int
	limit_set          bool
	sort               string
	kind               string
	grep               string
	older_than_seconds i64
	older_than_set     bool
	wait               bool
	keep               int
	keep_set           bool
	no_size            bool
	include_broken     bool
	doctor_purge       bool
	doctor_repair      bool
	doctor_integrity   bool
	doctor_compact     bool
	doctor_backup      bool
	doctor_rebuild     bool
	doctor_reindex     bool
	targets            []string
mut:
	// set_flags records the flags that were actually given, in argument order.
	// Validation uses it so that a flag is checked by presence, not by value.
	set_flags []FlagKind
}

struct CommandMatch {
	cmd Command
	idx int
}

// split_flag_token splits `--name=value` into its name and value parts.
fn split_flag_token(token string) (string, string, bool) {
	idx := token.index_u8(`=`)
	if idx > 0 {
		return token[..idx], token[idx + 1..], true
	}
	return token, '', false
}

// find_command locates the first command token while skipping flag values.
fn find_command(table FlagTable, args []string) ?CommandMatch {
	mut i := 1
	for i < args.len {
		arg := args[i]
		if arg == '--' {
			return none
		}
		if arg.starts_with('-') {
			name, _, has_value := split_flag_token(arg)
			if spec := table.lookup(name) {
				if spec.value != .none && !has_value {
					i += 2
				} else {
					i++
				}
			} else {
				i++
			}
			continue
		}
		if cmd := command_from_name(arg) {
			return CommandMatch{
				cmd: cmd
				idx: i
			}
		}
		return none
	}
	return none
}

// Cli.parse parses argv. A known command may appear after global flags; otherwise
// the invocation is the default `put` command.
pub fn Cli.parse(args []string) !Cli {
	table := flag_table()
	mut cli := Cli{}
	if args.len < 2 {
		cli.command = .help
		return cli
	}
	mut explicit_command := false
	mut command_idx := -1
	if found := find_command(table, args) {
		cli.command = found.cmd
		explicit_command = true
		command_idx = found.idx
	}
	if cli.command == .help {
		if command_idx + 1 < args.len {
			if help_cmd := command_from_name(args[command_idx + 1]) {
				cli.help_command = help_cmd
			}
		}
		return cli
	}
	if cli.command == .version {
		return cli
	}
	mut stop_flags := false
	mut i := 1
	for i < args.len {
		if i == command_idx {
			i++
			continue
		}
		arg := args[i]
		if stop_flags {
			cli.targets << arg
			i++
			continue
		}
		if arg == '--' {
			stop_flags = true
			i++
			continue
		}
		if !arg.starts_with('-') {
			cli.targets << arg
			i++
			continue
		}
		name, inline_value, has_value := split_flag_token(arg)
		spec := table.lookup(name) or {
			return error('unknown flag `${arg}`\nhint: run `trash help ${cli.command.label()}`')
		}
		if spec.kind == .help {
			current := cli.command
			cli.command = .help
			if explicit_command {
				cli.help_command = current
			}
			return cli
		}
		if spec.kind == .version {
			cli.command = .version
			return cli
		}
		mut value := ''
		if spec.value != .none {
			if has_value {
				value = inline_value
			} else {
				if i + 1 >= args.len {
					return error('`--${spec.long}` requires ${spec.requires_hint}')
				}
				value = args[i + 1]
				i++
			}
		} else if has_value {
			return error('`--${spec.long}` does not take a value')
		}
		cli.apply(spec, value)!
		i++
	}
	cli.validate(table)!
	return cli
}

// apply stores a parsed flag in the Cli struct.
fn (mut cli Cli) apply(spec FlagSpec, value string) ! {
	cli.set_flags << spec.kind
	match spec.kind {
		.store {
			if value == '' {
				return error('`--store` requires a path')
			}
			cli.store = value
		}
		.verbose { cli.verbose = true }
		.no_color { cli.no_color = true }
		.reset_store { cli.reset_store = true }
		.recursive { cli.recursive = true }
		.preview { cli.preview = true }
		.interactive { cli.interactive = true }
		.dry_run { cli.dry_run = true }
		.yes { cli.yes = true }
		.all { cli.all = true }
		.json { cli.json = true }
		.long { cli.long = true }
		.ids { cli.ids = true }
		.no_size { cli.no_size = true }
		.wait { cli.wait = true }
		.include_broken { cli.include_broken = true }
		.doctor_repair { cli.doctor_repair = true }
		.doctor_purge { cli.doctor_purge = true }
		.doctor_integrity { cli.doctor_integrity = true }
		.doctor_compact { cli.doctor_compact = true }
		.doctor_backup { cli.doctor_backup = true }
		.doctor_rebuild { cli.doctor_rebuild = true }
		.doctor_reindex { cli.doctor_reindex = true }
		.limit {
			cli.limit = parse_count(spec, value)!
			cli.limit_set = true
		}
		.keep {
			cli.keep = parse_count(spec, value)!
			cli.keep_set = true
		}
		.older_than {
			cli.older_than_seconds = parse_duration(value)!
			cli.older_than_set = true
		}
		.sort { cli.sort = value }
		.kind { cli.kind = value }
		.grep { cli.grep = value }
		.help, .version {}
	}
}

fn parse_count(spec FlagSpec, value string) !int {
	count := strconv.atoi(value) or {
		return error('`--${spec.long}` must be a number')
	}
	if count < 0 {
		return error('`--${spec.long}` must not be negative')
	}
	return count
}

// validate checks flag applicability and the relations declared in the table.
fn (cli Cli) validate(table FlagTable) ! {
	for kind in cli.set_flags {
		spec := table.spec(kind)
		if spec.commands.len > 0 && cli.command !in spec.commands {
			return error('`--${spec.long}` is not supported by `${cli.command.label()}`')
		}
		for required in spec.requires {
			if required !in cli.set_flags {
				return error('`--${spec.long}` requires `--${table.spec(required).long}`')
			}
		}
		for forbidden in spec.forbids {
			if forbidden in cli.set_flags {
				return error('`--${spec.long}` cannot be combined with `--${table.spec(forbidden).long}`')
			}
		}
	}
	if cli.sort != '' && cli.sort !in ['date', 'size', 'path', 'kind'] {
		return error('--sort must be one of: date, size, path, kind')
	}
	if cli.kind != '' && cli.kind !in ['file', 'dir', 'symlink', 'other'] {
		return error('--kind must be one of: file, dir, symlink, other')
	}
	if cli.no_size && cli.sort == 'size' {
		return error('--no-size cannot be combined with --sort size')
	}
	if cli.all && cli.targets.len > 0 {
		return error('--all cannot be combined with targets')
	}
	match cli.command {
		.put {
			if cli.targets.len == 0 {
				return error('no files or directories specified\nhint: run `trash help put`')
			}
		}
		.list, .stats, .doctor {
			if cli.targets.len > 0 {
				return error('`${cli.command.label()}` does not accept targets')
			}
		}
		.restore, .empty, .where {}
		.help, .version {}
	}
}

// palette returns terminal colours for this invocation.
pub fn (cli Cli) palette() Palette {
	return new_palette(cli.no_color)
}

// resolve_store resolves --store / $TRASH_STORE / $XDG_DATA_HOME / ~/.local/share/trash.
pub fn resolve_store(cli_path string) !string {
	if cli_path != '' {
		return pathx.canonical_path(cli_path)
	}
	env_store := os.getenv('TRASH_STORE')
	if env_store != '' {
		return pathx.canonical_path(env_store)
	}
	xdg_data := os.getenv('XDG_DATA_HOME')
	if xdg_data != '' {
		return pathx.canonical_path(os.join_path(xdg_data, 'trash'))
	}
	home := os.home_dir()
	if home != '' {
		return pathx.canonical_path(os.join_path(home, '.local', 'share', 'trash'))
	}
	return error('cannot determine home directory; pass --store')
}

fn parse_duration(value string) !i64 {
	if value.len < 2 {
		return error('invalid duration `${value}`; use e.g. 30d, 12h, 5m')
	}
	number := value[..value.len - 1]
	unit := value[value.len - 1..]
	amount := strconv.atoi(number) or {
		return error('invalid duration `${value}`; use e.g. 30d, 12h, 5m')
	}
	if amount < 0 {
		return error('duration must not be negative')
	}
	multiplier := match unit {
		's' { i64(1) }
		'm' { i64(60) }
		'h' { i64(3600) }
		'd' { i64(86400) }
		'w' { i64(604800) }
		else {
			return error('invalid duration unit `${unit}`; use s, m, h, d or w')
		}
	}
	return i64(amount) * multiplier
}
