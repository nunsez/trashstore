module trashcli

import os
import strconv

pub enum Command {
	put
	list
	restore
	empty
	where
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
	no_sync            bool
	json               bool
	all                bool
	recursive          bool
	preview            bool
	interactive        bool
	dry_run            bool
	yes                bool
	long               bool
	limit              int
	sort               string
	kind               string
	grep               string
	older_than_seconds i64
	wait               bool
	keep               int
	no_size            bool
	doctor_purge       bool
	doctor_repair      bool
	targets            []string
}

struct CommandMatch {
	cmd Command
	idx int
}

// find_command locates the first command token while skipping global flag values.
fn find_command(args []string) ?CommandMatch {
	mut i := 1
	for i < args.len {
		arg := args[i]
		if arg == '--' {
			return none
		}
		if arg in ['--store', '--limit', '--sort', '--kind', '--grep', '--older-than', '--keep'] {
			i += 2
			continue
		}
		if arg.starts_with('--store=') || arg.starts_with('--limit=')
			|| arg.starts_with('--sort=') || arg.starts_with('--kind=')
			|| arg.starts_with('--grep=') || arg.starts_with('--older-than=')
			|| arg.starts_with('--keep=') {
			i++
			continue
		}
		if arg.starts_with('-') {
			i++
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
	mut cli := Cli{}
	if args.len < 2 {
		cli.command = .help
		return cli
	}
	mut parse_args := args.clone()
	mut explicit_command := false
	mut command_idx := -1
	if found := find_command(args) {
		cli.command = found.cmd
		explicit_command = true
		command_idx = found.idx
		parse_args = [args[0]]
		parse_args << args[1..found.idx]
		parse_args << args[found.idx + 1..]
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
	mut i := 1
	mut stop_flags := false
	for i < parse_args.len {
		arg := parse_args[i]
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
		if arg == '-h' || arg == '--help' {
			current := cli.command
			cli.command = .help
			if explicit_command {
				cli.help_command = current
			}
			return cli
		}
		if arg == '-V' || arg == '--version' {
			cli.command = .version
			return cli
		}
		if arg == '--store' {
			if i + 1 >= parse_args.len {
				return error('--store requires a path')
			}
			cli.store = parse_args[i + 1]
			i += 2
			continue
		}
		if arg.starts_with('--store=') {
			value := arg['--store='.len..]
			if value == '' {
				return error('--store requires a path')
			}
			cli.store = value
			i++
			continue
		}
		if arg == '--keep' || arg.starts_with('--keep=') {
			value := if arg == '--keep' {
				if i + 1 >= parse_args.len {
					return error('--keep requires a number')
				}
				v := parse_args[i + 1]
				i += 2
				v
			} else {
				i++
				arg['--keep='.len..]
			}
			cli.keep = strconv.atoi(value) or {
				return error('--keep must be a number')
			}
			if cli.keep < 0 {
				return error('--keep must not be negative')
			}
			continue
		}
		if arg == '--sort' || arg.starts_with('--sort=') {
			if arg == '--sort' {
				if i + 1 >= parse_args.len {
					return error('--sort requires a value')
				}
				cli.sort = parse_args[i + 1]
				i += 2
			} else {
				cli.sort = arg['--sort='.len..]
				i++
			}
			continue
		}
		if arg == '--kind' || arg.starts_with('--kind=') {
			if arg == '--kind' {
				if i + 1 >= parse_args.len {
					return error('--kind requires a value')
				}
				cli.kind = parse_args[i + 1]
				i += 2
			} else {
				cli.kind = arg['--kind='.len..]
				i++
			}
			continue
		}
		if arg == '--grep' || arg.starts_with('--grep=') {
			if arg == '--grep' {
				if i + 1 >= parse_args.len {
					return error('--grep requires a pattern')
				}
				cli.grep = parse_args[i + 1]
				i += 2
			} else {
				cli.grep = arg['--grep='.len..]
				i++
			}
			continue
		}
		if arg == '--older-than' || arg.starts_with('--older-than=') {
			value := if arg == '--older-than' {
				if i + 1 >= parse_args.len {
					return error('--older-than requires a duration, e.g. 30d')
				}
				v := parse_args[i + 1]
				i += 2
				v
			} else {
				i++
				arg['--older-than='.len..]
			}
			cli.older_than_seconds = parse_duration(value)!
			continue
		}
		if arg == '--limit' {
			if i + 1 >= parse_args.len {
				return error('--limit requires a number')
			}
			cli.limit = strconv.atoi(parse_args[i + 1]) or {
				return error('--limit must be a number')
			}
			if cli.limit < 0 {
				return error('--limit must not be negative')
			}
			i += 2
			continue
		}
		if arg.starts_with('--limit=') {
			cli.limit = strconv.atoi(arg['--limit='.len..]) or {
				return error('--limit must be a number')
			}
			if cli.limit < 0 {
				return error('--limit must not be negative')
			}
			i++
			continue
		}
		match arg {
			'--verbose' { cli.verbose = true }
			'--no-color' { cli.no_color = true }
			'--no-sync' { cli.no_sync = true }
			'--json' { cli.json = true }
			'--all' { cli.all = true }
			'-r', '--recursive' { cli.recursive = true }
			'-i', '--interactive' { cli.interactive = true }
			'--preview' { cli.preview = true }
			'--dry-run' { cli.dry_run = true }
			'-y', '--yes' { cli.yes = true }
			'--long', '--full-id' { cli.long = true }
			'--wait' { cli.wait = true }
			'--no-size' { cli.no_size = true }
			'--repair' { cli.doctor_repair = true }
			'--doctor-purge' { cli.doctor_purge = true }
			else {
				if arg.starts_with('-') {
					return error('unknown flag `${arg}`\nhint: run `trash help ${cli.command.label()}`')
				}
				cli.targets << arg
			}
		}
		i++
	}
	cli.validate()!
	return cli
}

fn (cli Cli) validate() ! {
	if cli.json && !(cli.command in [.list, .restore, .empty, .where, .doctor]) {
		return error('--json is not supported by `${cli.command.label()}`')
	}
	if cli.all && !(cli.command in [.list, .restore, .empty]) {
		return error('--all is not supported by `${cli.command.label()}`')
	}
	if cli.recursive && !(cli.command in [.put, .list, .restore, .empty]) {
		return error('--recursive is not supported by `${cli.command.label()}`')
	}
	if cli.preview && cli.command != .put {
		return error('--preview is only supported by `put`')
	}
	if cli.interactive && !(cli.command in [.put, .restore, .empty]) {
		return error('--interactive is only supported by `put`, `restore` and `empty`')
	}
	if cli.dry_run && !(cli.command in [.put, .restore, .empty]) {
		return error('--dry-run is not supported by `${cli.command.label()}`')
	}
	if cli.yes && !(cli.command in [.put, .restore, .empty]) {
		return error('--yes is not supported by `${cli.command.label()}`')
	}
	if cli.long && cli.command != .list {
		return error('--long is only supported by `list`')
	}
	if cli.limit > 0 && !(cli.command in [.list, .restore, .empty]) {
		return error('--limit is only supported by `list`, `restore` and `empty`')
	}
	if cli.sort != '' && !(cli.command in [.list, .restore, .empty]) {
		return error('--sort is only supported by `list`, `restore` and `empty`')
	}
	if (cli.kind != '' || cli.grep != '' || cli.older_than_seconds > 0)
		&& !(cli.command in [.list, .restore, .empty]) {
		return error('--kind, --grep and --older-than are only supported by `list`, `restore` and `empty`')
	}
	if cli.sort != '' && cli.sort !in ['date', 'size', 'path', 'kind'] {
		return error('--sort must be one of: date, size, path, kind')
	}
	if cli.no_size && cli.command != .list {
		return error('--no-size is only supported by `list`')
	}
	if cli.no_size && cli.sort == 'size' {
		return error('--no-size cannot be combined with --sort size')
	}
	if cli.kind != '' && cli.kind !in ['file', 'dir', 'symlink', 'other'] {
		return error('--kind must be one of: file, dir, symlink, other')
	}
	if cli.wait && cli.command != .empty {
		return error('--wait is only supported by `empty`')
	}
	if cli.keep > 0 && cli.command != .empty {
		return error('--keep is only supported by `empty`')
	}
	if (cli.doctor_purge || cli.doctor_repair) && cli.command != .doctor {
		return error('--repair and --doctor-purge are only supported by `doctor`')
	}
	if cli.interactive && cli.json {
		return error('--interactive cannot be combined with --json')
	}
	if cli.all && cli.targets.len > 0 {
		return error('--all cannot be combined with targets')
	}
	if cli.all && cli.recursive {
		return error('--all and --recursive cannot be combined')
	}
	match cli.command {
		.put {
			if cli.targets.len == 0 {
				return error('no files or directories specified\nhint: run `trash help put`')
			}
		}
		.list, .where, .doctor {
			if cli.targets.len > 0 {
				return error('`${cli.command.label()}` does not accept targets')
			}
		}
		.restore, .empty {}
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
		return canonical_path(cli_path)
	}
	env_store := os.getenv('TRASH_STORE')
	if env_store != '' {
		return canonical_path(env_store)
	}
	xdg_data := os.getenv('XDG_DATA_HOME')
	if xdg_data != '' {
		return canonical_path(os.join_path(xdg_data, 'trash'))
	}
	home := os.home_dir()
	if home != '' {
		return canonical_path(os.join_path(home, '.local', 'share', 'trash'))
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
