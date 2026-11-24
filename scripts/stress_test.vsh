// Mixed multi-process stress: concurrent put, list, restore and empty.
// Fails on SQLITE_BUSY, lost items, or a failed integrity check.
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
		eprintln('stress test failed: ${err.msg()}')
		exit(1)
	}
}

fn run() ! {
	bin := resolve_bin(os.args[1] or { './trash' })!
	workers := (os.getenv_opt('WORKERS') or { '8' }).int()
	per := (os.getenv_opt('PER') or { '10' }).int()
	readers := (os.getenv_opt('READERS') or { '20' }).int()
	if workers <= 0 || per <= 0 || readers <= 0 {
		return error('WORKERS, PER and READERS must be positive integers')
	}
	work := work_dir('trash-stress')
	defer {
		os.rmdir_all(work) or {}
	}
	store := os.join_path(work, 'trash')

	for w in 1 .. workers + 1 {
		worker_dir := os.join_path(work, 'w${w}')
		os.mkdir_all(worker_dir)!
		for i in 1 .. per + 1 {
			os.write_file(os.join_path(worker_dir, 'f${i}'), 'worker ${w} file ${i}\n')!
		}
	}

	// Readers run while the writers work; WAL must keep them consistent.
	sem := chan bool{cap: workers + 1}
	results := chan ProcResult{cap: workers + 1}
	sem <- true
	spawn run_reader(bin, store, readers, 'read.log', sem, results)

	mut put_tasks := []Task{}
	for w in 1 .. workers + 1 {
		mut args := [bin, '--store', store]
		for i in 1 .. per + 1 {
			args << os.join_path(work, 'w${w}', 'f${i}')
		}
		put_tasks << Task{
			label: 'put w${w}'
			log:   'put${w}.log'
			args:  args
			env:   map[string]string{}
		}
	}
	for task in put_tasks {
		sem <- true
		spawn run_task(task, sem, results)
	}
	mut all := []ProcResult{cap: workers + 1}
	for _ in 0 .. workers + 1 {
		all << <-results
	}
	write_logs(work, all)
	check_results(all, 'put/read')!
	check_logs(work)!

	expected := workers * per
	mut got := count_item_dirs(store)
	if got != expected {
		return error('expected ${expected} items, got ${got}')
	}

	// Restore each worker's own files by original path, concurrently.
	mut restore_tasks := []Task{}
	for w in 1 .. workers + 1 {
		mut args := [bin, '--store', store, 'restore', '--yes']
		for i in 1 .. per + 1 {
			args << os.join_path(work, 'w${w}', 'f${i}')
		}
		restore_tasks << Task{
			label: 'restore w${w}'
			log:   'restore${w}.log'
			args:  args
			env:   map[string]string{}
		}
	}
	run_logged(restore_tasks, workers, work)!

	for w in 1 .. workers + 1 {
		for i in 1 .. per + 1 {
			path := os.join_path(work, 'w${w}', 'f${i}')
			if !os.is_file(path) {
				return error('missing restored ${path}')
			}
		}
	}
	got = count_item_dirs(store)
	if got != 0 {
		return error('expected an empty store after restore, got ${got}')
	}

	// Put everything again and race several empty --all processes.
	mut put_again := []Task{}
	for w in 1 .. workers + 1 {
		mut args := [bin, '--store', store]
		for i in 1 .. per + 1 {
			args << os.join_path(work, 'w${w}', 'f${i}')
		}
		put_again << Task{
			label: 'put2 w${w}'
			log:   'put2-${w}.log'
			args:  args
			env:   map[string]string{}
		}
	}
	run_logged(put_again, workers, work)!

	mut empty_tasks := []Task{}
	for w in 1 .. workers + 1 {
		empty_tasks << Task{
			label: 'empty${w}'
			log:   'empty${w}.log'
			args:  [bin, '--store', store, 'empty', '--all', '--yes', '--wait']
			env:   map[string]string{}
		}
	}
	run_logged(empty_tasks, workers, work)!

	got = count_item_dirs(store)
	if got != 0 {
		return error('expected an empty store after empty --all, got ${got}')
	}
	gc := os.ls(os.join_path(store, '.gc')) or { []string{} }
	if gc.len != 0 {
		return error('.gc was not cleaned: ${gc.join(', ')}')
	}

	code, out, err := run_capture([bin, '--store', store, 'doctor', '--integrity-check'], '',
		map[string]string{})
	os.write_file(os.join_path(work, 'doctor.log'), err) or {}
	if code != 0 || !out.contains('integrity: ok') {
		return error('integrity check failed (${code}): ${out}${err}')
	}

	println('stress test passed (${workers} workers x ${per} items, ${readers} readers)')
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

fn run_logged(tasks []Task, parallelism int, work string) ![]ProcResult {
	results := run_tasks(tasks, parallelism)
	write_logs(work, results)
	check_results(results, 'command')!
	check_logs(work)!
	return results
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

fn run_reader(bin string, store string, iterations int, log string, sem chan bool, results chan ProcResult) {
	mut out_all := ''
	mut err_all := ''
	mut code := 0
	for _ in 0 .. iterations {
		list_code, list_out, list_err := run_capture([bin, '--store', store, 'list', '--all'], '',
			map[string]string{})
		out_all += list_out
		err_all += list_err
		code = list_code
		if code != 0 {
			break
		}
		stats_code, stats_out, stats_err := run_capture([bin, '--store', store, 'stats'], '',
			map[string]string{})
		out_all += stats_out
		err_all += stats_err
		code = stats_code
		if code != 0 {
			break
		}
	}
	_ = <-sem
	results <- ProcResult{
		label: 'reader'
		log:   log
		code:  code
		out:   out_all
		err:   err_all
	}
}

fn write_logs(work string, results []ProcResult) {
	for result in results {
		os.write_file(os.join_path(work, result.log), result.err) or {}
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

fn check_logs(work string) ! {
	needles := ['SQLITE_BUSY', 'database is locked', 'sqlite error 5']
	for log in os.walk_ext(work, '.log') {
		content := os.read_file(log) or { continue }
		for needle in needles {
			if content.contains(needle) {
				return error('busy error in ${log}: ${needle}')
			}
		}
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
