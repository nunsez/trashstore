module main

import os
import time
import trash

fn elapsed_ms(start time.Time) f64 {
	return f64(time.now().unix_milli() - start.unix_milli())
}

fn main() {
	n := if os.args.len > 1 { os.args[1].int() } else { 1000 }
	work := os.join_path(os.temp_dir(), 'trash-bench-${os.getpid()}')
	store_root := os.join_path(work, 'trash')
	defer {
		os.rmdir_all(work) or {}
	}
	os.mkdir_all(work) or { panic(err) }

	mut paths := []string{}
	for i in 0 .. n {
		path := os.join_path(work, 'file-${i}.txt')
		os.write_file(path, 'x') or { panic(err) }
		paths << path
	}

	store := trash.open(store_root) or { panic(err) }
	mut start := time.now()
	put_batch := store.put_many(paths) or { panic(err) }
	if put_batch.failures.len > 0 {
		panic(put_batch.failures[0].message)
	}
	put_ms := elapsed_ms(start)

	start = time.now()
	entries := store.scan().entries
	scan_ms := elapsed_ms(start)
	if entries.len != n {
		panic('expected ${n} entries, got ${entries.len}')
	}

	start = time.now()
	_ := store.find(entries[0].id) or { panic(err) }
	find_ms := elapsed_ms(start)

	// The first list measures every unknown size; the second one reuses the
	// sizes stored in the item metadata.
	start = time.now()
	first := store.list(all: true)
	list_fill_ms := elapsed_ms(start)

	start = time.now()
	second := store.list(all: true)
	list_cached_ms := elapsed_ms(start)
	if first.len != n || second.len != n {
		panic('expected ${n} listed entries, got ${first.len} and ${second.len}')
	}

	start = time.now()
	restore_batch := store.restore_batch(entries) or { panic(err) }
	if restore_batch.failures.len > 0 {
		panic(restore_batch.failures[0].message)
	}
	restore_ms := elapsed_ms(start)

	println('items=${n} put=${put_ms:.1f}ms scan=${scan_ms:.1f}ms find_full_id=${find_ms:.1f}ms list_fill=${list_fill_ms:.1f}ms list_cached=${list_cached_ms:.1f}ms batch_restore=${restore_ms:.1f}ms')
}
