import os
import time

struct Task {
	label string
	log   string
	args  []string
	env   map[string]string
}

struct ProcResult {
	label string
	log   string
	code  int
	out   string
	err   string
}

fn main() {
	run() or {
		eprintln('concurrency test failed: ${err.msg()}')
		exit(1)
	}
}

fn run() ! {
	bin := resolve_bin(os.args[1] or { './trash' })!
	n := (os.getenv_opt('N') or { '60' }).int()
	if n <= 0 {
		return error('N must be a positive integer')
	}
	work := work_dir('trash-concurrency')
	defer {
		os.rmdir_all(work) or {}
	}
	store := os.join_path(work, 'trash')

	for i in 1 .. n + 1 {
		os.write_file(os.join_path(work, 'file${i}'), 'file ${i}\n')!
	}

	mut put_tasks := []Task{}
	for i in 1 .. n + 1 {
		put_tasks << Task{
			label: 'put file${i}'
			log:   'put${i}.log'
			args:  [bin, '--store', store, os.join_path(work, 'file${i}')]
			env:   map[string]string{}
		}
	}
	results := run_tasks(put_tasks, 8)
	check_results(results, 'parallel put')!

	if count_files(work, 'file') != 0 {
		return error('put left source files in place')
	}
	if count_item_dirs(store) != n {
		return error('expected ${n} items after put, got ${count_item_dirs(store)}')
	}

	restore_code, _, restore_err := run_capture([bin, '--store', store, 'restore', '--all', '--yes'],
		'', map[string]string{})
	if restore_code != 0 {
		return error('restore --all failed (${restore_code}): ${restore_err}')
	}
	if count_files(work, 'file') != n {
		return error('expected ${n} restored files, got ${count_files(work, 'file')}')
	}

	for i in 1 .. n + 1 {
		put_code, _, put_err := run_capture([bin, '--store', store, os.join_path(work, 'file${i}')],
			'', map[string]string{})
		if put_code != 0 {
			return error('sequential put file${i} failed (${put_code}): ${put_err}')
		}
	}

	mut empty_tasks := []Task{}
	for i in 1 .. 5 {
		empty_tasks << Task{
			label: 'empty${i}'
			log:   'empty${i}.log'
			args:  [bin, '--store', store, 'empty', '--all', '--yes', '--wait']
			env:   map[string]string{}
		}
	}
	empty_results := run_tasks(empty_tasks, 4)
	check_results(empty_results, 'parallel empty')!
	if count_item_dirs(store) != 0 {
		return error('expected an empty store after empty --all, got ${count_item_dirs(store)} items')
	}

	println('concurrency test passed (${n} items)')
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

fn count_files(dir string, prefix string) int {
	names := os.ls(dir) or { return 0 }
	mut count := 0
	for name in names {
		if name.starts_with(prefix) && os.is_file(os.join_path(dir, name)) {
			count++
		}
	}
	return count
}

fn count_item_dirs(store string) int {
	items := os.join_path(store, 'items')
	names := os.ls(items) or { return 0 }
	mut count := 0
	for name in names {
		path := os.join_path(items, name)
		if os.is_dir(path) && !os.is_link(path) {
			count++
		}
	}
	return count
}

fn run_tasks(tasks []Task, parallelism int) []ProcResult {
	limit := if parallelism > 0 { parallelism } else { 1 }
	sem := chan bool{cap: limit}
	results := chan ProcResult{cap: tasks.len}
	for task in tasks {
		sem <- true
		spawn run_task(task, sem, results)
	}
	mut out := []ProcResult{cap: tasks.len}
	for _ in 0 .. tasks.len {
		out << <-results
	}
	return out
}

fn run_task(task Task, sem chan bool, results chan ProcResult) {
	code, out, err := run_capture(task.args, '', task.env)
	_ = <-sem
	results <- ProcResult{
		label: task.label
		log:   task.log
		code:  code
		out:   out
		err:   err
	}
}

fn check_results(results []ProcResult, what string) ! {
	mut failed := false
	for result in results {
		if result.code != 0 {
			failed = true
			eprintln('${what}: ${result.label} failed (${result.code}): ${result.err}')
		}
	}
	if failed {
		return error('${what} failed')
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
