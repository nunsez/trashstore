module trash

import internal.fsx
import json2
import os
import rand
import time

const items_dirname = 'items'
const inflight_dirname = 'inflight'
const gc_dirname = '.gc'
const lock_filename = '.lock'

pub type IdGen = fn () string
pub type Clock = fn () time.Time

// StoreOptions controls how a store is opened.
@[params]
pub struct StoreOptions {
pub:
	create              bool = true
	mode                u32  = 0o700
	sync                bool = true
	allow_foreign_owner bool
	id_gen              ?IdGen
	clock               ?Clock
}

// RecoveryReport describes work done by recover()/recover_if_needed().
pub struct RecoveryReport {
pub mut:
	recovered int
	warnings  []string
}

// Store owns one trash directory. All operations are safe to call from
// multiple processes; individual items are isolated by their id.
pub struct Store {
pub:
	root string
	sync bool
mut:
	id_gen     ?IdGen
	id_session &rand.UUIDSession = &rand.UUIDSession{}
	clock      Clock             = time.now
}

// next_id returns a new item id. Injected generators take precedence; the
// default UUIDv7 session keeps ids monotonic within the same millisecond, so
// lexicographic ordering reflects creation order.
fn (s Store) next_id() string {
	if gen := s.id_gen {
		return gen()
	}
	return s.id_session.next()
}

// open prepares a trash directory with default options.
pub fn open(root string) !Store {
	return open_with(root)
}

// open_with prepares a trash directory. Recovery is explicit via recover_if_needed().
pub fn open_with(root string, opts StoreOptions) !Store {
	if root.trim_space() == '' {
		return invalid_target_error('trash directory path must not be empty')
	}
	resolved := canonical_path(root)
	if resolved == '/' {
		return invalid_target_error('refusing to use the filesystem root as the trash directory')
	}
	root_existed := os.is_dir(resolved)
	if !root_existed && !opts.create {
		return not_found_error('trash directory `${resolved}` does not exist')
	}
	if root_existed {
		st := os.stat(resolved)!
		if st.uid != os.geteuid() && os.geteuid() != 0 && !opts.allow_foreign_owner {
			return permission_error('trash directory `${resolved}` is owned by uid ${st.uid}; use a directory owned by the current user')
		}
		if st.mode & 0o002 != 0 {
			return invalid_target_error('trash directory `${resolved}` is world-writable; use a private subdirectory')
		}
	}
	os.mkdir_all(resolved, mode: int(opts.mode)) or {
		if !os.is_dir(resolved) {
			return context_error(.io, 'create trash directory', resolved, err)
		}
	}
	mut s := Store{
		root:  resolved
		sync:  opts.sync
		clock: time.now
	}
	if gen := opts.id_gen {
		s.id_gen = gen
	}
	if clock := opts.clock {
		s.clock = clock
	}
	if os.is_link(s.lock_path()) {
		return invalid_target_error('lock file `${s.lock_path()}` must not be a symlink')
	}
	lock_existed := os.exists(s.lock_path())
	mut fl := s.lock_shared()!
	defer {
		fl.release()
	}
	mut created_any := !root_existed || !lock_existed
	for dir in [os.join_path(resolved, items_dirname), os.join_path(resolved, inflight_dirname),
		os.join_path(resolved, gc_dirname)] {
		if os.is_link(dir) {
			return invalid_target_error('store directory `${dir}` must not be a symlink')
		}
		mut created := true
		os.mkdir(dir, mode: int(opts.mode)) or {
			created = false
			if os.is_link(dir) {
				return invalid_target_error('store directory `${dir}` must not be a symlink')
			}
			if !os.is_dir(dir) {
				return context_error(.io, 'create store directory', dir, err)
			}
		}
		os.chmod(dir, int(opts.mode)) or {}
		if created {
			created_any = true
		}
	}
	if !root_existed {
		os.chmod(resolved, int(opts.mode)) or {}
	}
	os.chmod(s.lock_path(), 0o600) or {}
	if created_any && s.sync {
		fsx.fsync_dir(resolved)!
		if !root_existed {
			fsx.fsync_dir(os.dir(resolved))!
		}
	}
	fl.release()
	return s
}

fn (s Store) items_dir() string {
	return os.join_path(s.root, items_dirname)
}

fn (s Store) inflight_dir() string {
	return os.join_path(s.root, inflight_dirname)
}

fn (s Store) gc_dir() string {
	return os.join_path(s.root, gc_dirname)
}

fn (s Store) lock_path() string {
	return os.join_path(s.root, lock_filename)
}

fn (s Store) item_dir(id string) string {
	return os.join_path(s.items_dir(), id)
}

fn (s Store) meta_path(id string) string {
	return os.join_path(s.item_dir(id), 'meta.json')
}

fn (s Store) data_path(id string) string {
	return os.join_path(s.item_dir(id), 'data')
}

struct StoreLock {
mut:
	fd int = -1
}

fn (s Store) open_lock_file() !int {
	fd := C.open(&char(s.lock_path().str), C.O_RDWR | C.O_CREAT | C.O_CLOEXEC | C.O_NOFOLLOW, 0o600)
	if fd < 0 {
		return io_error('cannot open lock file `${s.lock_path()}`: ${os.get_error_msg(C.errno)}')
	}
	return fd
}

fn (mut l StoreLock) release() {
	if l.fd >= 0 {
		C.flock(l.fd, C.LOCK_UN)
		C.close(l.fd)
		l.fd = -1
	}
}

fn (s Store) lock_shared() !StoreLock {
	fd := s.open_lock_file()!
	if C.flock(fd, C.LOCK_SH) != 0 {
		C.close(fd)
		return io_error('cannot acquire shared lock on `${s.lock_path()}`: ${os.get_error_msg(C.errno)}')
	}
	return StoreLock{
		fd: fd
	}
}

fn (s Store) lock_exclusive() !StoreLock {
	fd := s.open_lock_file()!
	if C.flock(fd, C.LOCK_EX) != 0 {
		C.close(fd)
		return io_error('cannot acquire exclusive lock on `${s.lock_path()}`: ${os.get_error_msg(C.errno)}')
	}
	return StoreLock{
		fd: fd
	}
}

fn (s Store) try_lock_exclusive() ?StoreLock {
	fd := s.open_lock_file() or { return none }
	if C.flock(fd, C.LOCK_EX | C.LOCK_NB) != 0 {
		C.close(fd)
		return none
	}
	return StoreLock{
		fd: fd
	}
}

fn (s Store) sync_dir(path string) ! {
	if s.sync {
		fsx.fsync_dir(path)!
	}
}

fn failpoint(name string) ! {
	if os.getenv('TRASH_TEST_FAILPOINTS') != '1' {
		return
	}
	if os.getenv('TRASH_FAILPOINT') == name {
		return io_error('injected failure at `${name}`')
	}
}

fn unique_dirs(dirs []string) []string {
	mut seen := map[string]bool{}
	mut result := []string{}
	for dir in dirs {
		if dir == '' || seen[dir] {
			continue
		}
		seen[dir] = true
		result << dir
	}
	return result
}

fn (s Store) create_marker(op string, id string) !string {
	return s.create_marker_opts(op, id, true)
}

fn (s Store) create_marker_opts(op string, id string, sync bool) !string {
	if os.is_link(s.inflight_dir()) {
		return invalid_target_error('inflight directory must not be a symlink')
	}
	path := os.join_path(s.inflight_dir(), '${op}-${id}')
	os.mkdir(path, mode: 0o700)!
	if sync {
		s.sync_dir(s.inflight_dir())!
	}
	return path
}

fn (s Store) remove_marker(path string) {
	s.remove_marker_opts(path, true)
}

fn (s Store) remove_marker_opts(path string, sync bool) {
	fsx.remove_any(path) or {}
	if sync {
		s.sync_dir(s.inflight_dir()) or {}
	}
}

fn (s Store) write_meta_atomic(item_dir string, meta Meta) ! {
	return s.write_meta_atomic_opts(item_dir, meta, s.sync, s.sync)
}

fn (s Store) write_meta_atomic_opts(item_dir string, meta Meta, sync_file bool, sync_dir bool) ! {
	text := json2.encode(meta, escape_unicode: true) + '\n'
	tmp := os.join_path(item_dir, 'meta.json.tmp')
	mut f := os.create(tmp)!
	f.write_string(text) or {
		f.close()
		os.rm(tmp) or {}
		return err
	}
	f.flush()
	if s.sync && sync_file {
		fsx.fsync_fd(f.fd, tmp) or {
			f.close()
			os.rm(tmp) or {}
			return err
		}
	}
	f.close()
	os.rename(tmp, os.join_path(item_dir, 'meta.json')) or {
		os.rm(tmp) or {}
		return err
	}
	if sync_dir {
		s.sync_dir(item_dir)!
	}
}

fn (s Store) read_meta_unchecked(id string) !Meta {
	path := s.meta_path(id)
	text := os.read_file(path) or {
		return context_error(.io, 'read metadata', path, err)
	}
	return json2.decode[Meta](text) or {
		return context_error(.io, 'decode metadata', path, err)
	}
}

fn (s Store) read_meta_raw(id string) !Meta {
	meta := s.read_meta_unchecked(id)!
	if meta.id != id {
		return io_error('metadata id mismatch for `${id}`: found `${meta.id}`')
	}
	return meta
}

fn (s Store) read_meta(id string) !Meta {
	meta := s.read_meta_raw(id)!
	meta.to_entry() or {
		return io_error('invalid metadata for `${id}`: ${err.msg()}')
	}
	return meta
}

// read_entry parses and validates metadata exactly once.
fn (s Store) read_entry(id string) !Entry {
	meta := s.read_meta_raw(id)!
	return meta.to_entry() or {
		return io_error('invalid metadata for `${id}`: ${err.msg()}')
	}
}

fn (s Store) write_meta(id string, meta Meta) ! {
	s.write_meta_atomic(s.item_dir(id), meta)!
}

// recover_if_needed runs recovery only when in-flight markers or garbage exist.
// It returns an empty report if another process is already handling recovery.
pub fn (s Store) recover_if_needed() !RecoveryReport {
	inflight := os.ls(s.inflight_dir()) or { []string{} }
	garbage := os.ls(s.gc_dir()) or { []string{} }
	if inflight.len == 0 && garbage.len == 0 {
		return RecoveryReport{}
	}
	mut fl := s.try_lock_exclusive() or { return RecoveryReport{} }
	defer {
		fl.release()
	}
	report := s.recover_locked()!
	s.gc_locked()!
	return report
}

// recover finishes or rolls back operations interrupted by a crash.
pub fn (s Store) recover() !RecoveryReport {
	mut fl := s.lock_exclusive()!
	defer {
		fl.release()
	}
	report := s.recover_locked()!
	s.gc_locked()!
	return report
}

fn (s Store) recover_locked() !RecoveryReport {
	if os.is_link(s.inflight_dir()) {
		return invalid_target_error('inflight directory `${s.inflight_dir()}` must not be a symlink')
	}
	mut report := RecoveryReport{}
	markers := os.ls(s.inflight_dir()) or { []string{} }
	for name in markers {
		marker := os.join_path(s.inflight_dir(), name)
		idx := name.index('-') or {
			report.warnings << 'removed malformed marker `${name}`'
			s.remove_marker(marker)
			continue
		}
		op := name[..idx]
		id := name[idx + 1..]
		if !is_safe_id(id) {
			report.warnings << 'removed unsafe marker `${name}`'
			s.remove_marker(marker)
			continue
		}
		match op {
			'put' {
				s.recover_put(id)!
				report.recovered++
			}
			'restore' {
				s.recover_restore(id)!
				report.recovered++
			}
			'empty' {
				s.recover_empty(id)!
				report.recovered++
			}
			'size' {
				// An interrupted size measurement leaves the item valid; the size
				// is measured again on demand.
			}
			else {
				report.warnings << 'removed unknown marker `${name}`'
			}
		}
		s.remove_marker(marker)
	}
	return report
}

fn is_safe_id(id string) bool {
	return id != '' && id != '.' && id != '..' && !id.contains('/') && !id.contains('\\')
}

fn (s Store) recover_put(id string) ! {
	item := s.item_dir(id)
	if os.is_link(item) || !os.is_dir(item) {
		return
	}
	mut meta := s.read_meta(id) or {
		// Keep an orphaned payload for manual recovery if the metadata is gone.
		if !os.exists(s.data_path(id)) && !os.is_link(s.data_path(id)) {
			os.rmdir_all(item)!
			s.sync_dir(s.items_dir())!
		}
		return
	}
	if meta.state != 'pending' {
		return
	}
	if os.exists(s.data_path(id)) || os.is_link(s.data_path(id)) {
		meta.state = 'trashed'
		s.write_meta(id, meta)!
	} else {
		os.rmdir_all(item)!
		s.sync_dir(s.items_dir())!
	}
}

fn (s Store) recover_restore(id string) ! {
	item := s.item_dir(id)
	if os.is_link(item) || !os.is_dir(item) {
		return
	}
	mut meta := s.read_meta(id) or {
		// Keep an orphaned payload for manual recovery if the metadata is gone.
		if !os.exists(s.data_path(id)) && !os.is_link(s.data_path(id)) {
			os.rmdir_all(item)!
			s.sync_dir(s.items_dir())!
		}
		return
	}
	if meta.state != 'restoring' {
		return
	}
	mut target_path := ''
	if meta.restore_to != '' {
		if target := percent_decode_path(meta.restore_to) {
			target_path = target
			fsx.remove_any('${target}.trash-tmp-${id}') or {}
		}
	}
	if target_path != '' {
		if target_st := os.lstat(target_path) {
			same_inode := (meta.data_ino != 0 && target_st.dev == meta.data_dev
				&& target_st.inode == meta.data_ino)
				|| (meta.target_ino != 0 && target_st.dev == meta.target_dev
					&& target_st.inode == meta.target_ino)
			if same_inode {
				// The rename completed before the crash; the target is our
				// payload, so finish the restore instead of duplicating it.
				os.rmdir_all(item)!
				s.sync_dir(s.items_dir())!
				return
			}
		}
	}
	if os.exists(s.data_path(id)) || os.is_link(s.data_path(id)) {
		meta.state = 'trashed'
		meta.restore_to = ''
		s.write_meta(id, meta)!
	} else {
		os.rmdir_all(item)!
		s.sync_dir(s.items_dir())!
	}
}

fn (s Store) recover_empty(id string) ! {
	if os.is_link(s.gc_dir()) {
		return invalid_target_error('garbage directory must not be a symlink')
	}
	item := s.item_dir(id)
	if os.is_link(item) || !os.is_dir(item) {
		return
	}
	dest := os.join_path(s.gc_dir(), '${id}-recovered-${s.next_id()}')
	fsx.rename_noreplace(item, dest)!
	s.sync_dir(s.items_dir())!
	s.sync_dir(s.gc_dir())!
}

// gc removes garbage left by completed or interrupted destructive operations.
pub fn (s Store) gc() ! {
	mut fl := s.lock_exclusive()!
	defer {
		fl.release()
	}
	s.gc_locked()!
}

fn (s Store) gc_locked() ! {
	if os.is_link(s.gc_dir()) {
		return invalid_target_error('garbage directory `${s.gc_dir()}` must not be a symlink')
	}
	entries := os.ls(s.gc_dir()) or { []string{} }
	for entry in entries {
		path := os.join_path(s.gc_dir(), entry)
		if !os.exists(path) && !os.is_link(path) {
			continue
		}
		fsx.remove_any(path)!
	}
	s.sync_dir(s.gc_dir())!
}

// count_items returns the number of item directories currently in the store.
pub fn (s Store) count_items() int {
	ids := os.ls(s.items_dir()) or { return 0 }
	mut count := 0
	for id in ids {
		if os.is_dir(s.item_dir(id)) {
			count++
		}
	}
	return count
}

@[params]
pub struct DoctorOptions {
pub:
	repair bool
	purge  bool
}

pub struct DoctorItem {
pub:
	id     string
	reason string
	action string
}

pub struct DoctorReport {
pub mut:
	broken   int
	repaired int
	purged   int
	sized    int
	unknown  int
	items    []DoctorItem
}

fn (s Store) repair_broken_meta(id string) string {
	data := s.data_path(id)
	has_data := os.exists(data) || os.is_link(data)
	mut fixed := Meta{}
	mut changed := false
	if meta := s.read_meta_unchecked(id) {
		fixed = meta
		if fixed.id != id {
			fixed.id = id
			changed = true
		}
		if has_data {
			if fixed.state != 'trashed' {
				fixed.state = 'trashed'
				fixed.restore_to = ''
				changed = true
			}
			if _ := kind_from_label(fixed.kind) {
			} else {
				fixed.kind = detect_kind(data).label()
				changed = true
			}
			mut path_ok := false
			if decoded := percent_decode_path(fixed.original_path) {
				path_ok = decoded.starts_with('/')
			}
			if !path_ok {
				fixed.original_path = percent_encode_path(os.join_path(s.root, 'recovered', id))
				changed = true
			}
			if _ := time.parse_rfc3339(fixed.trashed_at) {
			} else {
				fixed.trashed_at = s.clock().format_rfc3339()
				changed = true
			}
			if !fixed.size_known {
				if kind := kind_from_label(fixed.kind) {
					size, ok := measure_path(data, kind)
					if ok {
						fixed.size = size
						fixed.size_known = true
						changed = true
					}
				}
			}
		} else {
			changed = false
		}
	} else if has_data {
		kind := detect_kind(data)
		size, size_ok := measure_path(data, kind)
		fixed = Meta{
			id:            id
			state:         'trashed'
			original_path: percent_encode_path(os.join_path(s.root, 'recovered', id))
			trashed_at:    s.clock().format_rfc3339()
			kind:          kind.label()
			size:          size
			size_known:    size_ok
		}
		changed = true
	}
	if !changed {
		return 'not repairable'
	}
	fixed.to_entry() or { return 'not repairable' }
	s.write_meta(id, fixed) or { return 'repair failed' }
	return 'repaired'
}

// doctor inspects broken items under an exclusive lock and optionally repairs
// metadata or detaches broken items into the garbage directory.
pub fn (s Store) doctor(opts DoctorOptions) !DoctorReport {
	mut fl := s.lock_exclusive()!
	defer {
		fl.release()
	}
	scan := s.scan()
	mut report := DoctorReport{
		broken: scan.broken.len
	}
	for broken in scan.broken {
		mut action := 'reported'
		if opts.repair && is_safe_id(broken.id) {
			action = s.repair_broken_meta(broken.id)
			if action == 'repaired' {
				report.repaired++
			}
		}
		if opts.purge && is_safe_id(broken.id) {
			dest := os.join_path(s.gc_dir(), 'doctor-${broken.id}-${s.next_id()}')
			fsx.rename_noreplace(s.item_dir(broken.id), dest) or {
				action = 'purge failed'
			}
			if action != 'purge failed' {
				s.sync_dir(s.items_dir()) or {}
				s.sync_dir(s.gc_dir()) or {}
				action = 'purged'
				report.purged++
			}
		}
		report.items << DoctorItem{
			id:     broken.id
			reason: broken.reason
			action: action
		}
	}
	if opts.repair {
		for entry in scan.entries {
			if entry.size_known {
				continue
			}
			if s.fill_size(entry).size_known {
				report.sized++
			} else {
				report.unknown++
			}
		}
	}
	if report.purged > 0 {
		s.gc_locked()!
	}
	return report
}
