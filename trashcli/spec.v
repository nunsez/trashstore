module trashcli

// FlagKind identifies the Cli field (or action) a flag controls. It is the key
// that ties the flag table, the parser and the validator together.
enum FlagKind {
	help
	version
	store
	verbose
	quiet
	no_color
	reset_store
	recursive
	preview
	interactive
	force
	yes
	all
	json
	limit
	sort
	kind
	grep
	older_than
	long
	ids
	no_size
	keep
	wait
	include_broken
	doctor_repair
	doctor_purge
	doctor_integrity
	doctor_compact
	doctor_backup
	doctor_rebuild
	doctor_reindex
}

// ValueKind is how the value of a flag is parsed.
enum ValueKind {
	none
	text
	count
	duration
}

// FlagSpec is the single source of truth for one command-line flag: how it is
// spelled, whether it takes a value, which commands accept it, its relations
// with other flags and the text used by help.
struct FlagSpec {
	kind          FlagKind
	long          string
	short         string
	aliases       []string
	value         ValueKind
	value_name    string
	requires_hint string
	commands      []Command
	requires      []FlagKind
	forbids       []FlagKind
	help          string
}

// names returns every accepted spelling of the flag.
fn (s FlagSpec) names() []string {
	mut names := []string{}
	if s.short != '' {
		names << '-${s.short}'
	}
	names << '--${s.long}'
	for alias in s.aliases {
		names << '--${alias}'
	}
	return names
}

// label renders the flag as shown in help, e.g. `-r, --recursive` or
// `--store PATH`.
fn (s FlagSpec) label() string {
	mut parts := []string{}
	if s.short != '' {
		parts << '-${s.short}'
	}
	parts << '--${s.long}'
	for alias in s.aliases {
		parts << '--${alias}'
	}
	label := parts.join(', ')
	if s.value != .none {
		return '${label} ${s.value_name}'
	}
	return label
}

// flag_specs is the flag table. Global flags have an empty `commands` list.
fn flag_specs() []FlagSpec {
	return [
		FlagSpec{
			kind:          .store
			long:          'store'
			value:         .text
			value_name:    'PATH'
			requires_hint: 'a path'
			help:          'Use PATH as the trash store'
		},
		FlagSpec{
			kind:    .verbose
			long:    'verbose'
			forbids: [.quiet]
			help:    'Explain what is happening and show every warning'
		},
		FlagSpec{
			kind:    .quiet
			long:    'quiet'
			forbids: [.verbose]
			help:    'Suppress warnings'
		},
		FlagSpec{
			kind: .no_color
			long: 'no-color'
			help: 'Disable colours'
		},
		FlagSpec{
			kind: .reset_store
			long: 'reset-store'
			help: 'Wipe the store if its index schema is incompatible'
		},
		FlagSpec{
			kind:  .help
			long:  'help'
			short: 'h'
			help:  'Show this help'
		},
		FlagSpec{
			kind:  .version
			long:  'version'
			short: 'V'
			help:  'Show program version'
		},
		FlagSpec{
			kind:     .recursive
			long:     'recursive'
			short:    'r'
			commands: [.put, .list, .restore, .empty, .where]
			help:     'Allow directories, or include the subtree for selections'
		},
		FlagSpec{
			kind:     .preview
			long:     'preview'
			commands: [.put]
			help:     'Show a preview and ask for confirmation'
		},
		FlagSpec{
			kind:     .interactive
			long:     'interactive'
			short:    'i'
			commands: [.put, .restore, .empty]
			forbids:  [.json]
			help:     'Choose items interactively'
		},
		FlagSpec{
			kind:     .force
			long:     'force'
			short:    'f'
			commands: [.put]
			help:     'Ignore targets that do not exist'
		},
		FlagSpec{
			kind:     .yes
			long:     'yes'
			short:    'y'
			commands: [.put, .restore, .empty, .doctor]
			help:     'Do not ask for confirmation'
		},
		FlagSpec{
			kind:     .all
			long:     'all'
			commands: [.list, .restore, .empty]
			forbids:  [.recursive]
			help:     'Use the whole trash instead of the current directory'
		},
		FlagSpec{
			kind:     .json
			long:     'json'
			commands: [.list, .restore, .empty, .where, .stats, .doctor]
			help:     'Print machine-readable JSON'
		},
		FlagSpec{
			kind:     .long
			long:     'long'
			aliases:  ['full-id']
			commands: [.list]
			help:     'Show full ids, kinds and full timestamps'
		},
		FlagSpec{
			kind:     .ids
			long:     'ids'
			commands: [.list]
			forbids:  [.json, .long]
			help:     'Print only full ids, one per line'
		},
		FlagSpec{
			kind:          .limit
			long:          'limit'
			value:         .count
			value_name:    'N'
			requires_hint: 'a number'
			commands:      [.list, .restore, .empty]
			help:          'Use at most N items after sorting (0 selects nothing)'
		},
		FlagSpec{
			kind:          .sort
			long:          'sort'
			value:         .text
			value_name:    'MODE'
			requires_hint: 'a value'
			commands:      [.list, .restore, .empty]
			help:          'Sort by date, size, path or kind'
		},
		FlagSpec{
			kind:          .kind
			long:          'kind'
			value:         .text
			value_name:    'KIND'
			requires_hint: 'a value'
			commands:      [.list, .restore, .empty, .where]
			help:          'Filter by file, dir, symlink or other'
		},
		FlagSpec{
			kind:          .grep
			long:          'grep'
			value:         .text
			value_name:    'PATTERN'
			requires_hint: 'a pattern'
			commands:      [.list, .restore, .empty, .where]
			help:          'Filter by a substring of the original path'
		},
		FlagSpec{
			kind:          .older_than
			long:          'older-than'
			value:         .duration
			value_name:    'AGE'
			requires_hint: 'a duration, e.g. 30d'
			commands:      [.list, .restore, .empty, .where]
			help:          'Filter items older than an age such as 30d, 12h, 5m'
		},
		FlagSpec{
			kind:     .no_size
			long:     'no-size'
			commands: [.list]
			help:     'Skip measuring unknown item sizes'
		},
		FlagSpec{
			kind:          .keep
			long:          'keep'
			value:         .count
			value_name:    'N'
			requires_hint: 'a number'
			commands:      [.empty]
			help:          'Never delete the N newest items'
		},
		FlagSpec{
			kind:     .wait
			long:     'wait'
			commands: [.empty]
			help:     'Wait for permanent deletion instead of deferring GC'
		},
		FlagSpec{
			kind:     .include_broken
			long:     'include-broken'
			commands: [.empty]
			requires: [.all]
			help:     'With --all, also delete broken and orphan payloads'
		},
		FlagSpec{
			kind:     .doctor_repair
			long:     'repair'
			commands: [.doctor]
			help:     'Finish interrupted operations and measure sizes'
		},
		FlagSpec{
			kind:     .doctor_purge
			long:     'doctor-purge'
			commands: [.doctor]
			help:     'Permanently remove broken items'
		},
		FlagSpec{
			kind:     .doctor_integrity
			long:     'integrity-check'
			commands: [.doctor]
			help:     'Run PRAGMA integrity_check'
		},
		FlagSpec{
			kind:     .doctor_compact
			long:     'compact'
			commands: [.doctor]
			help:     'VACUUM the index and release free pages'
		},
		FlagSpec{
			kind:     .doctor_backup
			long:     'backup'
			commands: [.doctor]
			help:     'Write a consistent index.backup.db'
		},
		FlagSpec{
			kind:     .doctor_rebuild
			long:     'rebuild'
			commands: [.doctor]
			help:     'Recreate rows from payloads (original paths are lost)'
		},
		FlagSpec{
			kind:     .doctor_reindex
			long:     'reindex'
			commands: [.doctor]
			help:     'Rebuild the index b-trees'
		},
	]
}

// FlagTable indexes the flag specs by spelling and by kind.
struct FlagTable {
	specs   []FlagSpec
	by_name map[string]int
	by_kind map[FlagKind]int
}

fn flag_table() FlagTable {
	specs := flag_specs()
	mut by_name := map[string]int{}
	mut by_kind := map[FlagKind]int{}
	for i, spec in specs {
		by_kind[spec.kind] = i
		for name in spec.names() {
			by_name[name] = i
		}
	}
	return FlagTable{
		specs:   specs
		by_name: by_name
		by_kind: by_kind
	}
}

fn (t FlagTable) lookup(token string) ?FlagSpec {
	idx := t.by_name[token] or { return none }
	return t.specs[idx]
}

fn (t FlagTable) spec(kind FlagKind) FlagSpec {
	idx := t.by_kind[kind] or { panic('missing flag spec for ${kind}') }
	return t.specs[idx]
}

// CommandSpec is the help text of one command, split into reusable parts.
struct CommandSpec {
	cmd         Command
	usage       string
	summary     string
	description string
	examples    []string
}

fn command_specs() []CommandSpec {
	return [
		CommandSpec{
			cmd:         .put
			usage:       'trash [put] [OPTIONS] <path>...'
			summary:     'Move files to the trash (default when no command is given)'
			description: 'Moves files and directories to the trash.'
			examples:    ['trash report.txt', 'trash -r build/', 'trash --preview report.txt']
		},
		CommandSpec{
			cmd:         .list
			usage:       'trash list [OPTIONS]'
			summary:     'List trashed items (direct children of cwd by default)'
			description: 'Lists items trashed from the current directory. Use -r for the\nwhole subtree and --all for the whole trash.'
			examples:    ['trash list', 'trash list -r', 'trash list --all --json',
				'trash list --all --ids | trash where']
		},
		CommandSpec{
			cmd:         .restore
			usage:       'trash restore [OPTIONS] [<id|prefix|path>...]'
			summary:     'Restore trashed items (direct children of cwd by default)'
			description: 'Restores the selected items. With no arguments, restores everything\ntrashed from the current directory; use --all for the whole trash.'
			examples:    ['trash restore', 'trash restore 01a203aa', 'trash restore --all --limit 1',
				'trash restore -i', 'trash restore ./report.txt']
		},
		CommandSpec{
			cmd:         .empty
			usage:       'trash empty [OPTIONS] [<id|prefix|path>...]'
			summary:     'Permanently delete trashed items (cwd by default)'
			description: 'Permanently deletes the selected items. With no arguments, deletes\nitems trashed from the current directory; use --all for the whole\ntrash. Broken items and orphan payloads (directories without an index\nrow) are never deleted unless --include-broken is given. This cannot\nbe undone.'
			examples:    ['trash empty', 'trash empty --all --yes',
				'trash empty --older-than 30d --keep 5', 'trash empty 01a203aa']
		},
		CommandSpec{
			cmd:         .where
			usage:       'trash where [OPTIONS] [<id|prefix|path>...]'
			summary:     'Print payload paths of selected items (locator)'
			description: 'Prints the payload path of each selected item inside the trash, one\nper line. Refs are resolved from the arguments or, when stdin is not a\nterminal, from one ref per line on stdin. Multiple refs produce one\npath per match, in argument order; use `list` for metadata.'
			examples:    ['trash where 01a203aa', 'trash where ./report.txt ./notes.txt',
				'trash list --all --grep report --ids | trash where']
		},
		CommandSpec{
			cmd:         .stats
			usage:       'trash stats [OPTIONS]'
			summary:     'Show the trash location, item count and known size'
			description: 'Shows the trash location, the item count and the total size of the\nitems whose size is known. Sizes are measured lazily by `list` and\n`doctor --repair`.'
		},
		CommandSpec{
			cmd:         .doctor
			usage:       'trash doctor [OPTIONS]'
			summary:     'Report or repair broken trash items'
			description: 'Reports broken trash items and maintains the SQLite index. --repair\nfinishes interrupted put/restore/empty operations and measures unknown\nsizes; --doctor-purge removes broken items.'
		},
		CommandSpec{
			cmd:     .help
			usage:   'trash help [command]'
			summary: 'Show help for a command'
		},
		CommandSpec{
			cmd:     .version
			usage:   'trash version'
			summary: 'Show program version'
		},
	]
}

fn command_spec(c Command) ?CommandSpec {
	for spec in command_specs() {
		if spec.cmd == c {
			return spec
		}
	}
	return none
}

// general_examples are shown by `trash help`.
fn general_examples() []string {
	return [
		'trash report.txt',
		'trash -r build/',
		'trash list -r',
		'trash list --ids | trash where',
		'trash restore -i',
		'trash restore --all --limit 1',
		'trash empty --all --yes',
	]
}
