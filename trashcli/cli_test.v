module trashcli

import os
import time
import internal.format

fn C.dup(fd int) int
fn C.dup2(oldfd int, newfd int) int

fn cli_dir(name string) string {
	dir := canonical_path(os.join_path(os.temp_dir(), 'v_trash_cli_${os.getpid()}_${name}'))
	os.rmdir_all(dir) or {}
	os.mkdir_all(dir) or { panic(err) }
	return dir
}

fn cli_cleanup(dir string) {
	os.rmdir_all(dir) or {}
}

fn cli_write(path string, content string) {
	os.mkdir_all(os.dir(path)) or { panic(err) }
	os.write_file(path, content) or { panic(err) }
}

fn stdin_to_devnull() int {
	$if !windows {
		old := C.dup(0)
		fd := C.open(&char(c'/dev/null'), C.O_RDONLY)
		if fd >= 0 {
			C.dup2(fd, 0)
			C.close(fd)
		}
		return old
	}
	return -1
}

fn stdin_restore(old int) {
	$if !windows {
		if old >= 0 {
			C.dup2(old, 0)
			C.close(old)
		}
	}
}

fn cli_parse(args []string) Cli {
	return Cli.parse(args) or { panic(err) }
}

fn cli_run(args []string) ! {
	cli := Cli.parse(args)!
	run(cli)!
}

fn test_canonical_path_resolves_existing_symlink_directory() {
	$if !windows {
		root := cli_dir('canonical')
		defer {
			cli_cleanup(root)
		}
		real := os.join_path(root, 'real')
		os.mkdir(real) or { panic(err) }
		link := os.join_path(root, 'link')
		os.symlink(real, link) or { panic(err) }
		assert canonical_path(link) == canonical_path(real)
		assert canonical_target_path(link) == link
	}
}

fn test_resolve_name_conflict_free_and_taken() {
	root := cli_dir('conflict')
	defer {
		cli_cleanup(root)
	}
	base := os.join_path(root, 'a')
	assert resolve_name_conflict(base) == base
	cli_write(base, 'x')
	assert resolve_name_conflict(base) == '${base}~1'
	cli_write('${base}~1', 'x')
	assert resolve_name_conflict(base) == '${base}~2'
}

fn test_resolve_store_prefers_cli_path() {
	path := os.join_path(os.temp_dir(), 'trash-cli-grave')
	assert (resolve_store(path) or { panic(err) }) == canonical_path(path)
}

fn test_resolve_store_uses_environment() {
	old := os.getenv('TRASH_STORE')
	path := os.join_path(os.temp_dir(), 'trash-env-grave')
	os.setenv('TRASH_STORE', path, true)
	defer {
		if old == '' {
			os.unsetenv('TRASH_STORE')
		} else {
			os.setenv('TRASH_STORE', old, true)
		}
	}
	assert (resolve_store('') or { panic(err) }) == canonical_path(path)
}

fn test_resolve_store_uses_xdg_data_home() {
	old_grave := os.getenv('TRASH_STORE')
	old_xdg := os.getenv('XDG_DATA_HOME')
	os.unsetenv('TRASH_STORE')
	xdg := os.join_path(os.temp_dir(), 'trash-xdg')
	os.setenv('XDG_DATA_HOME', xdg, true)
	defer {
		if old_grave != '' {
			os.setenv('TRASH_STORE', old_grave, true)
		}
		if old_xdg == '' {
			os.unsetenv('XDG_DATA_HOME')
		} else {
			os.setenv('XDG_DATA_HOME', old_xdg, true)
		}
	}
	assert (resolve_store('') or { panic(err) }) == canonical_path(os.join_path(xdg, 'trash'))
}

fn test_parse_finds_command_after_global_flags() {
	cli := cli_parse(['trash', '--store', '/tmp/g', 'list', '-r', '--json'])
	assert cli.command == .list
	assert cli.store == '/tmp/g'
	assert cli.recursive
	assert cli.json
}

fn test_parse_no_sync() {
	cli := Cli.parse(['trash', '--no-sync', 'list']) or { panic(err) }
	assert cli.no_sync
	assert cli.command == .list
}

fn test_parse_default_command_is_put() {
	cli := cli_parse(['trash', '--store', '/tmp/g', '-r', 'a', 'b'])
	assert cli.command == .put
	assert cli.recursive
	assert cli.targets == ['a', 'b']
}

fn test_parse_stops_at_double_dash() {
	cli := cli_parse(['trash', '--', '-weird', '--store'])
	assert cli.command == .put
	assert cli.targets == ['-weird', '--store']
}

fn test_parse_rejects_unknown_flag() {
	mut failed := false
	Cli.parse(['trash', '--nope']) or { failed = true }
	assert failed
}

fn test_parse_command_help() {
	cli := cli_parse(['trash', 'list', '-h'])
	assert cli.command == .help
	assert cli.help_command? == .list
}

fn test_parse_rejects_invalid_combinations() {
	mut failed := false
	Cli.parse(['trash', 'list', 'x']) or { failed = true }
	assert failed

	failed = false
	Cli.parse(['trash', 'empty', '--all', 'x']) or { failed = true }
	assert failed

	failed = false
	Cli.parse(['trash', 'restore', '--all', '--recursive']) or { failed = true }
	assert failed

	failed = false
	Cli.parse(['trash', 'restore', '-i', '--json']) or { failed = true }
	assert failed

	put_purge := cli_parse(['trash', 'purge', 'x'])
	assert put_purge.command == .put
	assert put_purge.targets == ['purge', 'x']
}

fn test_run_returns_error_for_missing_target() {
	root := cli_dir('run_missing')
	defer {
		cli_cleanup(root)
	}
	mut failed := false
	cli_run(['trash', '--store', os.join_path(root, 'trash'), os.join_path(root, 'missing')]) or {
		failed = true
	}
	assert failed
}

fn test_run_put_and_restore() {
	root := cli_dir('run_put')
	defer {
		cli_cleanup(root)
	}
	store_path := os.join_path(root, 'trash')
	file := os.join_path(root, 'a.txt')
	cli_write(file, 'hello')

	cli_run(['trash', '--store', store_path, file]) or { panic(err) }
	assert !os.exists(file)

	store := open(store_path) or { panic(err) }
	assert store.list().len == 1

	cli_run(['trash', '--store', store_path, 'restore', '--all']) or { panic(err) }
	assert (os.read_file(file) or { '' }) == 'hello'
}

fn test_run_directory_requires_recursive() {
	root := cli_dir('run_dir')
	defer {
		cli_cleanup(root)
	}
	store_path := os.join_path(root, 'trash')
	dir := os.join_path(root, 'dir')
	os.mkdir(dir) or { panic(err) }

	mut failed := false
	cli_run(['trash', '--store', store_path, dir]) or { failed = true }
	assert failed
	assert os.is_dir(dir)

	cli_run(['trash', '--store', store_path, '-r', dir]) or { panic(err) }
	assert !os.exists(dir)
}

fn test_run_empty_target() {
	root := cli_dir('run_empty_target')
	defer {
		cli_cleanup(root)
	}
	store_path := os.join_path(root, 'trash')
	file := os.join_path(root, 'a.txt')
	cli_write(file, 'x')
	cli_run(['trash', '--store', store_path, file]) or { panic(err) }

	store := open(store_path) or { panic(err) }
	entry := store.list()[0]
	cli_run(['trash', '--store', store_path, 'empty', '--yes', entry.id]) or { panic(err) }
	assert store.list().len == 0
}

fn test_run_empty_requires_yes_when_not_interactive() {
	old_stdin := stdin_to_devnull()
	defer {
		stdin_restore(old_stdin)
	}
	root := cli_dir('run_empty')
	defer {
		cli_cleanup(root)
	}
	store_path := os.join_path(root, 'trash')
	file := os.join_path(root, 'a.txt')
	cli_write(file, 'x')
	cli_run(['trash', '--store', store_path, file]) or { panic(err) }

	mut failed := false
	cli_run(['trash', '--store', store_path, 'empty', '--all']) or { failed = true }
	assert failed

	store := open(store_path) or { panic(err) }
	assert store.list().len == 1

	cli_run(['trash', '--store', store_path, 'empty', '--all', '--yes']) or { panic(err) }
	assert store.list().len == 0
}

fn test_run_restore_default_scope() {
	root := cli_dir('run_default_scope')
	defer {
		cli_cleanup(root)
	}
	store_path := os.join_path(root, 'trash')
	work := os.join_path(root, 'work')
	os.mkdir(work) or { panic(err) }
	file := os.join_path(work, 'a.txt')
	cli_write(file, 'x')

	old_cwd := os.getwd()
	os.chdir(work) or { panic(err) }
	defer {
		os.chdir(old_cwd) or {}
	}

	cli_run(['trash', '--store', store_path, file]) or { panic(err) }
	assert !os.exists(file)

	cli_run(['trash', '--store', store_path, 'restore']) or { panic(err) }
	assert os.exists(file)
}

fn test_run_restore_by_prefix() {
	root := cli_dir('run_prefix')
	defer {
		cli_cleanup(root)
	}
	store_path := os.join_path(root, 'trash')
	file := os.join_path(root, 'a.txt')
	cli_write(file, 'x')
	cli_run(['trash', '--store', store_path, file]) or { panic(err) }
	store := open(store_path) or { panic(err) }
	id := store.list()[0].id
	cli_run(['trash', '--store', store_path, 'restore', id[..8]]) or { panic(err) }
	assert os.exists(file)
}

fn test_run_dry_run_does_not_move() {
	root := cli_dir('run_dry')
	defer {
		cli_cleanup(root)
	}
	store_path := os.join_path(root, 'trash')
	file := os.join_path(root, 'a.txt')
	cli_write(file, 'x')
	cli_run(['trash', '--store', store_path, '--dry-run', file]) or { panic(err) }
	assert os.exists(file)
	store := open(store_path) or { panic(err) }
	assert store.list().len == 0
}

fn test_run_where() {
	root := cli_dir('run_where')
	defer {
		cli_cleanup(root)
	}
	store_path := os.join_path(root, 'trash')
	cli_run(['trash', '--store', store_path, 'where', '--json']) or { panic(err) }
}

fn test_parse_filters_after_global_flags() {
	cli := cli_parse(['trash', '--sort', 'size', 'list', '--kind', 'file', '--older-than', '30d'])
	assert cli.command == .list
	assert cli.sort == 'size'
	assert cli.kind == 'file'
	assert cli.older_than_seconds == 86400 * 30
}

fn test_parse_rejects_invalid_duration() {
	mut failed := false
	Cli.parse(['trash', 'list', '--older-than', '30x']) or { failed = true }
	assert failed
}

fn test_parse_rejects_interactive_outside_selection() {
	mut failed := false
	Cli.parse(['trash', 'list', '--interactive']) or { failed = true }
	assert failed
}

fn test_doctor_repairs_id_mismatch() {
	root := cli_dir('doctor_repair')
	defer {
		cli_cleanup(root)
	}
	store_path := os.join_path(root, 'trash')
	store := open(store_path) or { panic(err) }
	file := os.join_path(root, 'a.txt')
	cli_write(file, 'x')
	entry := store.put(file) or { panic(err) }
	mut meta := store.read_meta(entry.id) or { panic(err) }
	meta.id = '00000000-0000-7000-8000-000000000099'
	store.write_meta(entry.id, meta) or { panic(err) }
	assert store.scan().broken.len == 1
	cli_run(['trash', '--store', store_path, 'doctor', '--repair'])!
	assert store.scan().broken.len == 0
}

fn test_doctor_purge_removes_broken_item() {
	root := cli_dir('doctor_purge')
	defer {
		cli_cleanup(root)
	}
	store_path := os.join_path(root, 'trash')
	store := open(store_path) or { panic(err) }
	file := os.join_path(root, 'a.txt')
	cli_write(file, 'x')
	entry := store.put(file) or { panic(err) }
	os.write_file(store.meta_path(entry.id), 'not json') or { panic(err) }
	assert store.scan().broken.len == 1
	cli_run(['trash', '--store', store_path, 'doctor', '--doctor-purge'])!
	assert store.scan().broken.len == 0
	assert !os.is_dir(store.item_dir(entry.id))
}

fn test_parse_selection_input() {
	assert (parse_selection_input('', 5) or { panic(err) }) == []int{}
	assert (parse_selection_input('q', 5) or { panic(err) }) == []int{}
	assert (parse_selection_input('a', 3) or { panic(err) }) == [0, 1, 2]
	assert (parse_selection_input('1,3-4', 5) or { panic(err) }) == [0, 2, 3]
	assert (parse_selection_input('3,3,1', 5) or { panic(err) }) == [2, 0]

	mut failed := false
	parse_selection_input('0', 5) or { failed = true }
	assert failed

	failed = false
	parse_selection_input('6', 5) or { failed = true }
	assert failed

	failed = false
	parse_selection_input('4-2', 5) or { failed = true }
	assert failed
}

fn test_resolve_selection_scope_parity() {
	root := cli_dir('selection_scope')
	defer {
		cli_cleanup(root)
	}
	store_path := os.join_path(root, 'trash')
	work := os.join_path(root, 'work')
	other := os.join_path(root, 'other')
	os.mkdir_all(work) or { panic(err) }
	os.mkdir_all(other) or { panic(err) }
	a := os.join_path(work, 'a.txt')
	b := os.join_path(other, 'b.txt')
	cli_write(a, 'a')
	cli_write(b, 'b')
	cli_run(['trash', '--store', store_path, a]) or { panic(err) }
	cli_run(['trash', '--store', store_path, b]) or { panic(err) }

	store := open(store_path) or { panic(err) }
	entries := store.scan().entries
	from_work := resolve_selection(entries, SelectionOptions{ cwd: work })!
	assert from_work.len == 1
	assert from_work[0].original_path == canonical_target_path(a)
	whole := resolve_selection(entries, SelectionOptions{ cwd: work, all: true })!
	assert whole.len == 2
}

fn test_run_empty_keep() {
	root := cli_dir('run_empty_keep')
	defer {
		cli_cleanup(root)
	}
	store_path := os.join_path(root, 'trash')
	work := os.join_path(root, 'work')
	os.mkdir(work) or { panic(err) }
	old_cwd := os.getwd()
	os.chdir(work) or { panic(err) }
	defer {
		os.chdir(old_cwd) or {}
	}
	for name in ['a.txt', 'b.txt', 'c.txt'] {
		path := os.join_path(work, name)
		cli_write(path, name)
		cli_run(['trash', '--store', store_path, path]) or { panic(err) }
	}
	cli_run(['trash', '--store', store_path, 'empty', '--keep', '1', '--yes']) or { panic(err) }
	store := open(store_path) or { panic(err) }
	left := store.list()
	assert left.len == 1
	assert left[0].original_path == canonical_target_path(os.join_path(work, 'c.txt'))
}

fn test_resolve_selection_recursive_target() {
	root := cli_dir('selection_recursive_target')
	defer {
		cli_cleanup(root)
	}
	store_path := os.join_path(root, 'trash')
	work := os.join_path(root, 'work')
	sub := os.join_path(work, 'sub')
	file := os.join_path(sub, 'c.txt')
	cli_write(file, 'c')
	cli_run(['trash', '--store', store_path, file]) or { panic(err) }

	store := open(store_path) or { panic(err) }
	entries := store.scan().entries
	mut failed := false
	resolve_selection(entries, SelectionOptions{
		targets: [sub]
		cwd:     work
	}) or { failed = true }
	assert failed

	selected := resolve_selection(entries, SelectionOptions{
		targets:   [sub]
		cwd:       work
		recursive: true
	})!
	assert selected.len == 1
	assert selected[0].original_path == canonical_target_path(file)
}

fn table_test_entries() []Entry {
	now := time.now()
	return [
		Entry{
			id:            '01a20888-4019-7800-9e03-53368bd42d97'
			original_path: '/tmp/t/report.txt'
			trashed_at:    now.add(-2 * time.hour)
			kind:          .file
			size:          12 * 1024
			size_known:    true
			state:         .trashed
		},
		Entry{
			id:            '01a20888-4032-7600-a8eb-2a3b7cb182b1'
			original_path: '/tmp/t/build'
			trashed_at:    now.add(-5 * 24 * time.hour)
			kind:          .dir
			size:          3 * 1024 * 1024
			state:         .trashed
		},
		Entry{
			id:            '01a20888-401b-7881-9b09-b1b4c691f1fa'
			original_path: '/tmp/t/notes/old.md'
			trashed_at:    now.add(-360 * 24 * time.hour)
			kind:          .file
			size:          900
			size_known:    true
			state:         .trashed
		},
	]
}

fn test_table_header_and_alignment() {
	entries := table_test_entries()
	lines := table_lines(entries, '/tmp/t', false, Palette{})
	assert lines.len == entries.len + 1
	assert lines[0] == 'ID        AGE         SIZE  PATH'
	assert lines[1] == '8bd42d97  2h ago    12 KiB  report.txt'
	assert lines[2] == '7cb182b1  5d ago         -  build'
	assert lines[3] == 'c691f1fa  12mo ago   900 B  notes/old.md'
	// Every row must start its path at the same column as the header, otherwise
	// the size and path columns drift from row to row.
	path_col := lines[0].index('PATH') or { -1 }
	assert path_col > 0
	for i, entry in entries {
		line := lines[i + 1]
		path := display_path(entry.original_path, '/tmp/t')
		assert line.len == path_col + path.len
		assert line[path_col..] == path
		assert line[path_col - 2..path_col] == '  '
		short := format.short_id(entry.id)
		assert line[0..short.len] == short
	}
}

fn test_table_wide_size_keeps_columns() {
	mut entries := table_test_entries()
	entries << Entry{
		id:            'deadbeef0000000000000000000000ff'
		original_path: '/tmp/t/big.iso'
		trashed_at:    time.now().add(-90 * time.second)
		kind:          .file
		size:          u64(1024) * 1024 * 1024 * 1024
		size_known:    true
		state:         .trashed
	}
	lines := table_lines(entries, '/tmp/t', false, Palette{})
	assert lines[entries.len].contains('1024 GiB')
	path_col := lines[0].index('PATH') or { -1 }
	assert path_col > 0
	for i, entry in entries {
		path := display_path(entry.original_path, '/tmp/t')
		assert lines[i + 1].len == path_col + path.len
		assert lines[i + 1][path_col..] == path
	}
}

fn test_table_long_layout() {
	entries := table_test_entries()
	lines := table_lines(entries, '/tmp/t', true, Palette{})
	assert lines.len == entries.len + 1
	assert lines[0].starts_with('ID')
	assert lines[0].contains('DELETED')
	assert lines[0].contains('KIND')
	assert lines[0].ends_with('SIZE  PATH')
	// --long prints full ids and kinds.
	assert lines[1].starts_with(entries[0].id)
	assert lines[1].contains('file')
	assert lines[2].contains('dir')
	path_col := lines[0].index('PATH') or { -1 }
	for i, entry in entries {
		path := display_path(entry.original_path, '/tmp/t')
		assert lines[i + 1].len == path_col + path.len
		assert lines[i + 1][path_col..] == path
	}
}

fn test_padding_uses_printable_width() {
	assert pad_right('界', 3) == '界 '
	assert pad_left('界', 3) == ' 界'
	assert pad_right('e\u0301', 2) == 'e\u0301 '
	assert pad_left('e\u0301', 2) == ' e\u0301'
	assert pad_right('\x1b[31mred\x1b[0m', 5) == '\x1b[31mred\x1b[0m  '
	assert pad_left('\x1b[31mred\x1b[0m', 5) == '  \x1b[31mred\x1b[0m'
	assert pad_right('界', 1) == '界'
	assert pad_left('界', 1) == '界'
	assert max_width(0, '界') == 2
	assert max_width(5, '界') == 5
}

fn test_parse_rejects_removed_quiet_flag() {
	mut failed := false
	Cli.parse(['trash', 'list', '--quiet']) or { failed = true }
	assert failed
}

fn test_parse_rejects_no_size_with_sort_size() {
	mut failed := false
	Cli.parse(['trash', 'list', '--no-size', '--sort', 'size']) or { failed = true }
	assert failed
}

fn test_parse_rejects_no_size_outside_list() {
	mut failed := false
	Cli.parse(['trash', 'where', '--no-size']) or { failed = true }
	assert failed
}

fn test_run_list_no_size_keeps_sizes_unknown() {
	root := cli_dir('list_no_size')
	defer {
		cli_cleanup(root)
	}
	store_path := os.join_path(root, 'trash')
	file := os.join_path(root, 'a.txt')
	cli_write(file, 'hello')
	cli_run(['trash', '--store', store_path, file]) or { panic(err) }
	store := open(store_path) or { panic(err) }
	id := store.list()[0].id
	assert !store.read_entry(id)!.size_known

	cli_run(['trash', '--store', store_path, 'list', '--all', '--no-size']) or { panic(err) }
	assert !store.read_entry(id)!.size_known
}

fn test_run_list_measures_unknown_sizes() {
	$if !windows {
		root := cli_dir('list_sizes')
		defer {
			cli_cleanup(root)
		}
		store_path := os.join_path(root, 'trash')
		dir := os.join_path(root, 'tree')
		cli_write(os.join_path(dir, 'a.txt'), '12345')
		cli_write(os.join_path(dir, 'sub', 'b.txt'), '123')
		cli_run(['trash', '--store', store_path, '-r', dir]) or { panic(err) }
		store := open(store_path) or { panic(err) }
		id := store.list()[0].id
		assert !store.read_entry(id)!.size_known

		cli_run(['trash', '--store', store_path, 'list', '--all']) or { panic(err) }
		entry := store.read_entry(id)!
		assert entry.size_known
		assert entry.size == 8
		assert store.stats().unknown == 0
	}
}

fn test_run_doctor_repair_measures_sizes() {
	root := cli_dir('doctor_sizes')
	defer {
		cli_cleanup(root)
	}
	store_path := os.join_path(root, 'trash')
	file := os.join_path(root, 'a.txt')
	cli_write(file, 'hello')
	cli_run(['trash', '--store', store_path, file]) or { panic(err) }
	store := open(store_path) or { panic(err) }
	assert store.stats().unknown == 1

	cli_run(['trash', '--store', store_path, 'doctor', '--repair']) or { panic(err) }
	assert store.stats().unknown == 0
	assert store.stats().size == 5
}

fn test_table_shows_known_directory_size() {
	entries := [
		Entry{
			id:            '01a20888-4032-7600-a8eb-2a3b7cb182b1'
			original_path: '/tmp/t/build'
			trashed_at:    time.now().add(-5 * 24 * time.hour)
			kind:          .dir
			size:          2048
			size_known:    true
			state:         .trashed
		},
	]
	lines := table_lines(entries, '/tmp/t', false, Palette{})
	assert lines[1].contains('2 KiB')
}

fn test_run_restore_sort_size_measures_before_sorting() {
	root := cli_dir('restore_sort_size')
	defer {
		cli_cleanup(root)
	}
	store_path := os.join_path(root, 'trash')
	small := os.join_path(root, 'small.txt')
	big := os.join_path(root, 'big.txt')
	cli_write(small, '1')
	cli_write(big, '1234567890')
	cli_run(['trash', '--store', store_path, small, big]) or { panic(err) }

	cli_run(['trash', '--store', store_path, 'restore', '--all', '--sort', 'size', '--limit', '1']) or {
		panic(err)
	}
	assert os.exists(big)
	assert !os.exists(small)
}
