import os
import time

struct CrossCleanup {
	work       string
	cross_root string
	ram_mount  string
	ram_dev    string
}

fn main() {
	run() or {
		eprintln('cross-device test failed: ${err.msg()}')
		exit(1)
	}
}

fn run() ! {
	bin := resolve_bin(os.args[1] or { './trash' })!
	work := work_dir('trash-cross')
	mut cross_root := ''
	mut ram_mount := ''
	mut ram_dev := ''

	$if linux {
		if os.is_dir('/dev/shm') {
			work_dev := os.stat(work)!.dev
			shm_dev := os.stat('/dev/shm')!.dev
			if work_dev != shm_dev {
				cross_root = os.join_path('/dev/shm', 'trash-cross-${os.getpid()}-${time.now().unix_nano()}')
				os.mkdir_all(cross_root)!
			}
		}
	} $else $if macos {
		attach_code, attach_out, _ := run_capture(['hdiutil', 'attach', '-nobrowse', '-nomount',
			'ram://1048576'], '', map[string]string{})
		if attach_code == 0 {
			lines := attach_out.split_into_lines()
			if lines.len > 0 {
				fields := lines[0].fields()
				if fields.len > 0 {
					ram_dev = fields[0]
				}
			}
			if ram_dev != '' {
				ram_mount = '/Volumes/TrashCross${os.getpid()}'
				erase_code, _, _ := run_capture(['diskutil', 'erasevolume', 'HFS+',
					'TrashCross${os.getpid()}', ram_dev], '', map[string]string{})
				if erase_code == 0 {
					cross_root = ram_mount
				} else {
					run_capture(['hdiutil', 'detach', ram_dev], '', map[string]string{})
					ram_dev = ''
					ram_mount = ''
				}
			}
		}
	}

	cleanup := CrossCleanup{
		work:       work
		cross_root: cross_root
		ram_mount:  ram_mount
		ram_dev:    ram_dev
	}
	defer {
		cleanup_cross(cleanup)
	}

	if cross_root == '' {
		println('cross-device test skipped: no separate filesystem available')
		return
	}

	store := os.join_path(work, 'store')
	src := os.join_path(cross_root, 'file.txt')
	os.write_file(src, 'cross-device payload\n')!
	put_code, _, put_err := run_trash(bin, store, [src], map[string]string{})
	if put_code != 0 {
		return error('cross-device put failed (${put_code}): ${put_err}')
	}
	if os.exists(src) {
		return error('cross-device put left the source in place')
	}
	restore_code, _, restore_err := run_trash(bin, store, ['restore', src], map[string]string{})
	if restore_code != 0 {
		return error('cross-device restore failed (${restore_code}): ${restore_err}')
	}
	if os.read_file(src)! != 'cross-device payload\n' {
		return error('cross-device restore did not preserve payload')
	}

	payload_dir := os.join_path(cross_root, 'dir')
	os.mkdir(payload_dir)!
	os.write_file(os.join_path(payload_dir, 'child.txt'), 'directory payload\n')!
	dir_put_code, _, dir_put_err := run_trash(bin, store, ['-r', payload_dir], map[string]string{})
	if dir_put_code != 0 {
		return error('cross-device directory put failed (${dir_put_code}): ${dir_put_err}')
	}
	if os.exists(payload_dir) {
		return error('cross-device directory put left the source in place')
	}
	dir_restore_code, _, dir_restore_err := run_trash(bin, store, ['restore', payload_dir], map[string]string{})
	if dir_restore_code != 0 {
		return error('cross-device directory restore failed (${dir_restore_code}): ${dir_restore_err}')
	}
	if os.read_file(os.join_path(payload_dir, 'child.txt'))! != 'directory payload\n' {
		return error('cross-device directory restore did not preserve payload')
	}

	os.write_file(src, 'crash journal payload\n')!
	put2_code, _, put2_err := run_trash(bin, store, [src], map[string]string{})
	if put2_code != 0 {
		return error('crash journal put failed (${put2_code}): ${put2_err}')
	}
	mut fail_env := os.environ()
	fail_env['TRASH_TEST_FAILPOINTS'] = '1'
	fail_env['TRASH_FAILPOINT'] = 'restore:after-target-rename'
	fail_code, _, _ := run_trash(bin, store, ['restore', src], fail_env)
	if fail_code == 0 {
		return error('restore failpoint did not fail')
	}
	if !os.is_file(src) {
		return error('crash journal target is missing')
	}
	if os.exists(src + '~1') {
		return error('crash journal produced a duplicate target')
	}
	list_code, list_out, list_err := run_trash(bin, store, ['list', '--all', '--json'], map[string]string{})
	if list_code != 0 {
		return error('list after crash recovery failed (${list_code}): ${list_err}')
	}
	if list_out.trim_space() != '[]' {
		return error('crash journal recovery left items behind: ${list_out}')
	}

	println('cross-device test passed')
}

fn run_trash(bin string, store string, args []string, env map[string]string) (int, string, string) {
	return run_capture([bin, '--store', store, ...args], '', env)
}

fn resolve_bin(path string) !string {
	abs := os.real_path(path)
	if !os.is_file(abs) {
		return error('trash binary not found: ${abs}')
	}
	return abs
}

fn work_dir(prefix string) string {
	work := os.join_path(os.temp_dir(), '${prefix}-${os.getpid()}-${time.now().unix_nano()}')
	os.mkdir_all(work) or { panic(err) }
	return work
}

fn cleanup_cross(state CrossCleanup) {
	if state.ram_mount != '' {
		run_capture(['diskutil', 'unmount', 'force', state.ram_mount], '', map[string]string{})
	}
	if state.ram_dev != '' {
		run_capture(['hdiutil', 'detach', state.ram_dev], '', map[string]string{})
	}
	if state.work != '' {
		os.rmdir_all(state.work) or {}
	}
	if state.cross_root.starts_with('/dev/shm/') {
		os.rmdir_all(state.cross_root) or {}
	}
}

fn run_capture(args []string, work_folder string, env map[string]string) (int, string, string) {
	mut process := os.new_process(args[0])
	process.set_args(args[1..])
	if work_folder != '' {
		process.set_work_folder(work_folder)
	}
	if env.len > 0 {
		process.set_environment(env)
	}
	process.set_redirect_stdio()
	process.run()
	if process.err != '' {
		err := process.err
		process.close()
		return -1, '', err
	}
	out_ch := chan string{cap: 1}
	err_ch := chan string{cap: 1}
	spawn read_stdout(mut process, out_ch)
	spawn read_stderr(mut process, err_ch)
	process.wait()
	out := <-out_ch
	err := <-err_ch
	code := process.code
	process.close()
	return code, out, err
}

fn read_stdout(mut process os.Process, ch chan string) {
	ch <- process.stdout_slurp()
}

fn read_stderr(mut process os.Process, ch chan string) {
	ch <- process.stderr_slurp()
}
