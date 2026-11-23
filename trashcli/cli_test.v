module trashcli

import os

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

fn test_resolve_graveyard_prefers_cli_path() {
	path := os.join_path(os.temp_dir(), 'trash-cli-grave')
	assert (resolve_graveyard(path) or { panic(err) }) == canonical_path(path)
}

fn test_resolve_graveyard_uses_environment() {
	old := os.getenv('GRAVEYARD')
	path := os.join_path(os.temp_dir(), 'trash-env-grave')
	os.setenv('GRAVEYARD', path, true)
	defer {
		if old == '' {
			os.unsetenv('GRAVEYARD')
		} else {
			os.setenv('GRAVEYARD', old, true)
		}
	}
	assert (resolve_graveyard('') or { panic(err) }) == canonical_path(path)
}

fn test_resolve_graveyard_uses_xdg_data_home() {
	old_grave := os.getenv('GRAVEYARD')
	old_xdg := os.getenv('XDG_DATA_HOME')
	os.unsetenv('GRAVEYARD')
	xdg := os.join_path(os.temp_dir(), 'trash-xdg')
	os.setenv('XDG_DATA_HOME', xdg, true)
	defer {
		if old_grave != '' {
			os.setenv('GRAVEYARD', old_grave, true)
		}
		if old_xdg == '' {
			os.unsetenv('XDG_DATA_HOME')
		} else {
			os.setenv('XDG_DATA_HOME', old_xdg, true)
		}
	}
	assert (resolve_graveyard('') or { panic(err) }) == canonical_path(os.join_path(xdg, 'trash'))
}

fn test_parse_finds_command_after_global_flags() {
	cli := cli_parse(['trash', '--graveyard', '/tmp/g', 'list', '-r', '--json'])
	assert cli.command == .list
	assert cli.graveyard == '/tmp/g'
	assert cli.recursive
	assert cli.json
}

fn test_parse_no_sync() {
	cli := Cli.parse(['trash', '--no-sync', 'list']) or { panic(err) }
	assert cli.no_sync
	assert cli.command == .list
}

fn test_parse_default_command_is_put() {
	cli := cli_parse(['trash', '--graveyard', '/tmp/g', '-r', 'a', 'b'])
	assert cli.command == .put
	assert cli.recursive
	assert cli.targets == ['a', 'b']
}

fn test_parse_stops_at_double_dash() {
	cli := cli_parse(['trash', '--', '-weird', '--graveyard'])
	assert cli.command == .put
	assert cli.targets == ['-weird', '--graveyard']
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
	Cli.parse(['trash', 'empty', '--all']) or { failed = true }
	assert failed

	failed = false
	Cli.parse(['trash', 'restore', '--recursive']) or { failed = true }
	assert failed

	failed = false
	Cli.parse(['trash', 'restore', '--from-cwd', 'x']) or { failed = true }
	assert failed
}

fn test_run_returns_error_for_missing_target() {
	root := cli_dir('run_missing')
	defer {
		cli_cleanup(root)
	}
	mut failed := false
	cli_run(['trash', '--graveyard', os.join_path(root, 'trash'), os.join_path(root, 'missing')]) or {
		failed = true
	}
	assert failed
}

fn test_run_put_and_restore_last() {
	root := cli_dir('run_put')
	defer {
		cli_cleanup(root)
	}
	graveyard := os.join_path(root, 'trash')
	file := os.join_path(root, 'a.txt')
	cli_write(file, 'hello')

	cli_run(['trash', '--graveyard', graveyard, file]) or { panic(err) }
	assert !os.exists(file)

	store := open(graveyard) or { panic(err) }
	assert store.list(ListFilter{}).len == 1

	cli_run(['trash', '--graveyard', graveyard, 'restore']) or { panic(err) }
	assert (os.read_file(file) or { '' }) == 'hello'
}

fn test_run_directory_requires_recursive() {
	root := cli_dir('run_dir')
	defer {
		cli_cleanup(root)
	}
	graveyard := os.join_path(root, 'trash')
	dir := os.join_path(root, 'dir')
	os.mkdir(dir) or { panic(err) }

	mut failed := false
	cli_run(['trash', '--graveyard', graveyard, dir]) or { failed = true }
	assert failed
	assert os.is_dir(dir)

	cli_run(['trash', '--graveyard', graveyard, '-r', dir]) or { panic(err) }
	assert !os.exists(dir)
}

fn test_run_purge() {
	root := cli_dir('run_purge')
	defer {
		cli_cleanup(root)
	}
	graveyard := os.join_path(root, 'trash')
	file := os.join_path(root, 'a.txt')
	cli_write(file, 'x')
	cli_run(['trash', '--graveyard', graveyard, file]) or { panic(err) }

	store := open(graveyard) or { panic(err) }
	entry := store.list(ListFilter{})[0]
	cli_run(['trash', '--graveyard', graveyard, 'purge', entry.id]) or { panic(err) }
	assert store.list(ListFilter{}).len == 0
}

fn test_run_empty_requires_yes_when_not_interactive() {
	root := cli_dir('run_empty')
	defer {
		cli_cleanup(root)
	}
	graveyard := os.join_path(root, 'trash')
	file := os.join_path(root, 'a.txt')
	cli_write(file, 'x')
	cli_run(['trash', '--graveyard', graveyard, file]) or { panic(err) }

	mut failed := false
	cli_run(['trash', '--graveyard', graveyard, 'empty']) or { failed = true }
	assert failed

	store := open(graveyard) or { panic(err) }
	assert store.list(ListFilter{}).len == 1

	cli_run(['trash', '--graveyard', graveyard, 'empty', '--yes']) or { panic(err) }
	assert store.list(ListFilter{}).len == 0
}

fn test_run_restore_from_cwd() {
	root := cli_dir('run_from_cwd')
	defer {
		cli_cleanup(root)
	}
	graveyard := os.join_path(root, 'trash')
	work := os.join_path(root, 'work')
	os.mkdir(work) or { panic(err) }
	file := os.join_path(work, 'a.txt')
	cli_write(file, 'x')

	old_cwd := os.getwd()
	os.chdir(work) or { panic(err) }
	defer {
		os.chdir(old_cwd) or {}
	}

	cli_run(['trash', '--graveyard', graveyard, file]) or { panic(err) }
	assert !os.exists(file)

	cli_run(['trash', '--graveyard', graveyard, 'restore', '--from-cwd']) or { panic(err) }
	assert os.exists(file)
}

fn test_run_restore_by_prefix() {
	root := cli_dir('run_prefix')
	defer {
		cli_cleanup(root)
	}
	graveyard := os.join_path(root, 'trash')
	file := os.join_path(root, 'a.txt')
	cli_write(file, 'x')
	cli_run(['trash', '--graveyard', graveyard, file]) or { panic(err) }
	store := open(graveyard) or { panic(err) }
	id := store.list(ListFilter{})[0].id
	cli_run(['trash', '--graveyard', graveyard, 'restore', id[..8]]) or { panic(err) }
	assert os.exists(file)
}

fn test_run_dry_run_does_not_move() {
	root := cli_dir('run_dry')
	defer {
		cli_cleanup(root)
	}
	graveyard := os.join_path(root, 'trash')
	file := os.join_path(root, 'a.txt')
	cli_write(file, 'x')
	cli_run(['trash', '--graveyard', graveyard, '--dry-run', file]) or { panic(err) }
	assert os.exists(file)
	store := open(graveyard) or { panic(err) }
	assert store.list(ListFilter{}).len == 0
}

fn test_run_where() {
	root := cli_dir('run_where')
	defer {
		cli_cleanup(root)
	}
	graveyard := os.join_path(root, 'trash')
	cli_run(['trash', '--graveyard', graveyard, 'where', '--json']) or { panic(err) }
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

fn test_parse_rejects_select_outside_restore() {
	mut failed := false
	Cli.parse(['trash', 'list', '--select']) or { failed = true }
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
	entry := store.put(file, PutOptions{}) or { panic(err) }
	mut meta := store.read_meta(entry.id) or { panic(err) }
	meta.id = '00000000-0000-7000-8000-000000000099'
	store.write_meta(entry.id, meta) or { panic(err) }
	assert store.scan().broken.len == 1
	cli_run(['trash', '--graveyard', store_path, 'doctor', '--repair'])!
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
	entry := store.put(file, PutOptions{}) or { panic(err) }
	os.write_file(store.meta_path(entry.id), 'not json') or { panic(err) }
	assert store.scan().broken.len == 1
	cli_run(['trash', '--graveyard', store_path, 'doctor', '--doctor-purge'])!
	assert store.scan().broken.len == 0
	assert !os.is_dir(store.item_dir(entry.id))
}
