module trash

import internal.fsx
import internal.sqlite
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
	allow_foreign_owner bool
	// allow_insecure permits a store that is writable by the group or others.
	allow_insecure bool
	id_gen         ?IdGen
	clock          ?Clock
}

// RecoveryReport describes what recover_if_needed() changed.
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
	mode u32
mut:
	db         sqlite.Db
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
		if st.mode & 0o022 != 0 && !opts.allow_insecure {
			return invalid_target_error('trash directory `${resolved}` is writable by group or others (mode 0${st.mode & 0o777:o}); use mode 0700 or pass allow_insecure')
		}
	}
	os.mkdir_all(resolved, mode: int(opts.mode)) or {
		if !os.is_dir(resolved) {
			return context_error(.io, 'create trash directory', resolved, err)
		}
	}
	actual_mode := if root_existed { os.stat(resolved)!.mode & 0o777 } else { opts.mode }
	mut s := Store{
		root:  resolved
		mode:  actual_mode
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
	for dir in [os.join_path(resolved, items_dirname), os.join_path(resolved, gc_dirname)] {
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
		if created {
			os.chmod(dir, int(opts.mode)) or {}
		}
		// Re-check after mkdir/chmod: a component could have been swapped for a
		// symlink between the first check and now.
		if os.is_link(dir) {
			return invalid_target_error('store directory `${dir}` must not be a symlink')
		}
		if created {
			created_any = true
		}
	}
	if !root_existed {
		os.chmod(resolved, int(opts.mode)) or {}
	}
	os.chmod(s.lock_path(), 0o600) or {}
	if created_any {
		fsx.fsync_dir(resolved)!
		if !root_existed {
			fsx.fsync_dir(os.dir(resolved))!
		}
	}
	s.db = s.open_index()!
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

fn (s Store) data_path(id string) string {
	return os.join_path(s.item_dir(id), 'data')
}

// payload_path returns the absolute path of an item's payload inside the store.
// The id is not validated: use payload_path_checked when it comes from outside
// the store (for example from a library caller).
pub fn (s Store) payload_path(id string) string {
	return s.data_path(id)
}

// payload_path_checked is payload_path with an id validation guard.
pub fn (s Store) payload_path_checked(id string) !string {
	if !is_safe_id(id) {
		return invalid_target_error('invalid item id `${id}`')
	}
	return s.data_path(id)
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
	fsx.fsync_dir(path)!
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

// recover_if_needed runs recovery only when pending rows or garbage exist.
// It returns an empty report if another process is already handling recovery.
// recover_if_needed runs recovery when there is work to do. If another process
// holds the exclusive lock, recovery is deferred: the report is empty and the
// lock holder (or the next run) finishes it.
pub fn (s Store) recover_if_needed() !RecoveryReport {
	pending := s.pending_items() or { []IndexItem{} }
	garbage := os.ls(s.gc_dir()) or { []string{} }
	if pending.len == 0 && garbage.len == 0 {
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
	mut report := RecoveryReport{}
	for item in s.pending_items()! {
		if os.is_link(s.item_dir(item.id)) {
			report.warnings << 'item ${item.id}: item directory is a symlink; left for doctor'
			continue
		}
		match item.state {
			.pending {
				s.recover_put(item)!
				report.recovered++
			}
			.restoring {
				s.recover_restore(item)!
				report.recovered++
			}
			.pending_empty {
				s.recover_empty(item)!
				report.recovered++
			}
			else {}
		}
	}
	return report
}

fn is_safe_id(id string) bool {
	return id != '' && id != '.' && id != '..' && !id.contains('/') && !id.contains('\\')
		&& !id.contains('\x00')
}

fn (s Store) remove_item_dir_if_empty(id string) ! {
	dir := s.item_dir(id)
	if os.is_link(dir) {
		// Never follow a symlinked item directory.
		return
	}
	if os.is_dir(dir) {
		os.rmdir_all(dir)!
		s.sync_dir(s.items_dir())!
	}
}

fn (s Store) recover_put(item IndexItem) ! {
	if os.is_link(s.item_dir(item.id)) {
		return
	}
	if os.exists(s.data_path(item.id)) || os.is_link(s.data_path(item.id)) {
		s.set_item_state(item.id, .trashed)!
		return
	}
	s.delete_item(item.id)!
	s.remove_item_dir_if_empty(item.id)!
}

fn (s Store) recover_restore(item IndexItem) ! {
	if os.is_link(s.item_dir(item.id)) {
		return
	}
	if item.restore_to != '' {
		target := percent_decode_path(item.restore_to) or { '' }
		if target != '' {
			fsx.remove_any('${target}.trash-tmp-${item.id}') or {}
			if os.exists(target) || os.is_link(target) {
				if restore_target_matches(item, target) {
					// The rename completed before the crash; the target is our
					// payload, so finish the restore instead of duplicating it.
					s.delete_item(item.id)!
					s.remove_item_dir_if_empty(item.id)!
					return
				}
			}
		}
	}
	if os.exists(s.data_path(item.id)) || os.is_link(s.data_path(item.id)) {
		mut restored := item
		restored.state = .trashed
		restored.restore_to = ''
		restored.target_dev = 0
		restored.target_ino = 0
		s.update_item(restored)!
	} else {
		s.delete_item(item.id)!
		s.remove_item_dir_if_empty(item.id)!
	}
}

fn (s Store) recover_empty(item IndexItem) ! {
	dir := s.item_dir(item.id)
	if os.is_link(dir) {
		return
	}
	if os.is_dir(dir) {
		if os.is_link(s.gc_dir()) {
			return invalid_target_error('garbage directory must not be a symlink')
		}
		dest := os.join_path(s.gc_dir(), '${item.id}-recovered-${s.next_id()}')
		fsx.rename_noreplace(dir, dest)!
		s.sync_dir(s.items_dir())!
		s.sync_dir(s.gc_dir())!
	}
	s.delete_item(item.id)!
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
	mut failures := []string{}
	for entry in entries {
		path := os.join_path(s.gc_dir(), entry)
		if !os.exists(path) && !os.is_link(path) {
			continue
		}
		fsx.remove_any(path) or {
			failures << '${entry}: ${err.msg()}'
			continue
		}
	}
	s.sync_dir(s.gc_dir())!
	if failures.len > 0 {
		return io_error('could not remove ${failures.len} garbage item(s): ${failures.join('; ')}')
	}
}

// count_items returns the number of rows in the index.
pub fn (s Store) count_items() int {
	return int(s.item_count() or { 0 })
}

@[params]
pub struct DoctorOptions {
pub:
	repair          bool
	purge           bool
	integrity_check bool
	compact         bool
	backup          bool
	rebuild         bool
	reindex         bool
}

pub struct DoctorItem {
pub:
	id     string
	reason string
	action string
}

pub struct DoctorReport {
pub mut:
	broken    int
	repaired  int
	purged    int
	sized     int
	unknown   int
	integrity string
	backup    string
	rebuilt   int
	compacted bool
	reindexed bool
	items     []DoctorItem
}

// doctor inspects broken items under an exclusive lock and optionally recovers
// pending operations or detaches broken items into the garbage directory.
pub fn (s Store) doctor(opts DoctorOptions) !DoctorReport {
	if os.is_link(s.gc_dir()) {
		return invalid_target_error('garbage directory `${s.gc_dir()}` must not be a symlink')
	}
	if os.is_link(s.items_dir()) {
		return invalid_target_error('items directory `${s.items_dir()}` must not be a symlink')
	}
	mut fl := s.lock_exclusive()!
	defer {
		fl.release()
	}
	mut report := DoctorReport{}
	if opts.rebuild {
		report.rebuilt = s.rebuild_index_locked()!
	}
	if opts.reindex {
		s.reindex_locked()!
		report.reindexed = true
	}
	if opts.repair {
		recovery := s.recover_locked()!
		report.repaired = recovery.recovered
	}
	if opts.compact {
		s.compact_locked()!
		report.compacted = true
	}
	if opts.integrity_check {
		report.integrity = s.integrity_check_locked()!
	}
	if opts.backup {
		report.backup = s.backup_locked()!
	}
	scan := s.scan()
	report.broken = scan.broken.len
	for broken in scan.broken {
		mut action := 'reported'
		if !is_safe_id(broken.id) || os.is_link(s.item_dir(broken.id)) {
			// A symlinked item directory is evidence of tampering: report it and
			// leave it for the user instead of following or silently removing it.
			action = 'skipped: symlinked item'
		} else if opts.purge {
			s.delete_item(broken.id) or {}
			dir := s.item_dir(broken.id)
			if os.is_dir(dir) {
				dest := os.join_path(s.gc_dir(), 'doctor-${broken.id}-${s.next_id()}')
				fsx.rename_noreplace(dir, dest) or { action = 'purge failed' }
			}
			if action != 'purge failed' {
				action = 'purged'
				report.purged++
				s.sync_dir(s.items_dir())!
				s.sync_dir(s.gc_dir())!
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
