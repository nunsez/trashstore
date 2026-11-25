module trash

import internal.fsx
import internal.sqlite
import os
import rand
import sync
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
	// create allows open_with to initialize a missing store. With create:
	// false the store directory, items/, .gc/ and index.db must already exist;
	// nothing is created and a missing piece is a not_found error.
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

// StoreDb is the heap-allocated connection state shared by every copy of a
// Store. Keeping it behind a pointer makes close() idempotent and lets a copy
// notice that the connection is gone instead of dereferencing a freed handle.
struct StoreDb {
mut:
	db     sqlite.Db
	closed bool
}

// Store owns one trash directory. All operations are safe to call from
// multiple processes; individual items are isolated by their id.
//
// A Store is returned as a pointer and must not be copied by value. Copies
// share the same SQLite connection: close() on any of them closes the store for
// all of them, after which every operation returns a "store is closed" error
// instead of touching freed memory.
pub struct Store {
pub:
	root string
mut:
	db         &StoreDb = unsafe { nil }
	id_gen     ?IdGen
	id_session &rand.UUIDSession = &rand.UUIDSession{}
	id_mu      &sync.Mutex       = &sync.Mutex{}
	clock      Clock             = time.now
}

// conn returns the live SQLite connection or an error when the store has been
// closed. Every database access goes through it, so a closed Store can never
// dereference a freed handle.
fn (s Store) conn() !&sqlite.Db {
	if s.db == unsafe { nil } || s.db.closed {
		return io_error('trash store `${s.root}` is closed')
	}
	return &s.db.db
}

// next_id returns a new item id. Injected generators take precedence; the
// default UUIDv7 session keeps ids monotonic within the same millisecond, so
// lexicographic ordering reflects creation order.
fn (s Store) next_id() string {
	if gen := s.id_gen {
		return gen()
	}
	s.id_mu.lock()
	defer {
		s.id_mu.unlock()
	}
	return s.id_session.next()
}

// open prepares a trash directory with default options.
pub fn open(root string) !&Store {
	return open_with(root)
}

// open_with prepares a trash directory. Recovery is explicit via recover_if_needed().
pub fn open_with(root string, opts StoreOptions) !&Store {
	if root.trim_space() == '' {
		return invalid_target_error('trash directory path must not be empty')
	}
	if opts.mode > 0o777 {
		return invalid_target_error('store mode 0${opts.mode:o} is invalid; use a mode within 0700')
	}
	if opts.mode & 0o077 != 0 && !opts.allow_insecure {
		return invalid_target_error('store mode 0${opts.mode:o} is accessible by group or others; use mode 0700 or pass allow_insecure')
	}
	resolved := canonical_path(root)
	if resolved == '/' {
		return invalid_target_error('refusing to use the filesystem root as the trash directory')
	}
	root_existed := os.is_dir(resolved)
	if !opts.create {
		if !root_existed {
			return not_found_error('trash directory `${resolved}` does not exist')
		}
		for name in [index_filename, items_dirname, gc_dirname] {
			path := os.join_path(resolved, name)
			if !os.exists(path) && !os.is_link(path) {
				return not_found_error('trash store `${resolved}` is incomplete: `${path}` is missing')
			}
		}
	}
	if root_existed {
		st := os.stat(resolved) or {
			return context_error(.io, 'stat trash directory', resolved, err)
		}
		if st.uid != os.geteuid() && os.geteuid() != 0 && !opts.allow_foreign_owner {
			return permission_error('trash directory `${resolved}` is owned by uid ${st.uid}; use a directory owned by the current user')
		}
		if st.mode & 0o077 != 0 && !opts.allow_insecure {
			return invalid_target_error('trash directory `${resolved}` is accessible by group or others (mode 0${st.mode & 0o777:o}); use mode 0700 or pass allow_insecure')
		}
	}
	os.mkdir_all(resolved, mode: int(opts.mode)) or {
		if !os.is_dir(resolved) {
			return context_error(.io, 'create trash directory', resolved, err)
		}
	}
	mut s := &Store{
		root:  resolved
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
		} else if !opts.allow_insecure {
			mode := (os.stat(dir) or {
				return context_error(.io, 'stat store directory', dir, err)
			}).mode & 0o777
			if mode & 0o077 != 0 {
				return invalid_target_error('store directory `${dir}` is accessible by group or others (mode 0${mode:o}); use mode 0700 or pass allow_insecure')
			}
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
	s.db = &StoreDb{
		db: s.open_index()!
	}
	fl.release()
	return s
}

fn (s Store) items_dir() string {
	return os.join_path(s.root, items_dirname)
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

fn (s Store) lock_shared() !fsx.FileLock {
	mut l := fsx.open_lock(s.lock_path())!
	l.lock_shared()!
	return l
}

fn (s Store) lock_exclusive() !fsx.FileLock {
	mut l := fsx.open_lock(s.lock_path())!
	l.lock_exclusive()!
	return l
}

fn (s Store) try_lock_exclusive() ?fsx.FileLock {
	mut l := fsx.open_lock(s.lock_path()) or { return none }
	if !l.try_lock_exclusive() {
		l.release()
		return none
	}
	return l
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
	pending := s.pending_items()!
	garbage := os.ls(s.gc_dir()) or { []string{} }
	if pending.len == 0 && garbage.len == 0 {
		return RecoveryReport{}
	}
	mut fl := s.try_lock_exclusive() or { return RecoveryReport{} }
	defer {
		fl.release()
	}
	mut report := s.recover_locked()!
	report.warnings << s.gc_locked_warnings()!
	return report
}

// recover finishes or rolls back operations interrupted by a crash.
pub fn (s Store) recover() !RecoveryReport {
	mut fl := s.lock_exclusive()!
	defer {
		fl.release()
	}
	mut report := s.recover_locked()!
	report.warnings << s.gc_locked_warnings()!
	return report
}

fn (s Store) recover_locked() !RecoveryReport {
	mut report := RecoveryReport{}
	for item in s.pending_items()! {
		if item.parse_error != '' {
			report.warnings << 'item ${item.id}: ${item.parse_error}; left untouched'
			continue
		}
		if !is_safe_id(item.id) {
			// An id read from the index must never be turned into a path: it could
			// point outside items/. Leave the row for doctor and keep going.
			report.warnings << 'item ${item.id}: invalid item id; left untouched'
			continue
		}
		if os.is_link(s.item_dir(item.id)) {
			report.warnings << 'item ${item.id}: item directory is a symlink; left for doctor'
			continue
		}
		match item.state {
			.pending {
				s.recover_put(item) or {
					report.warnings << 'item ${item.id}: ${err.msg()}'
					continue
				}
				report.recovered++
			}
			.restoring {
				warning := s.recover_restore(item) or {
					report.warnings << 'item ${item.id}: ${err.msg()}'
					continue
				}
				if warning != '' {
					report.warnings << warning
				}
				report.recovered++
			}
			.pending_empty {
				s.recover_empty(item) or {
					report.warnings << 'item ${item.id}: ${err.msg()}'
					continue
				}
				report.recovered++
			}
			.unknown {
				// A state this build does not understand must never trigger a
				// destructive action: leave the payload and the row for doctor.
				report.warnings << 'item ${item.id}: unknown state ${item.state.code()}; left untouched'
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

// remove_item_dir removes an item directory and anything left in it. The items
// directory is opened with O_NOFOLLOW and the removal is descriptor-relative,
// so an item path swapped for a symlink cannot redirect the deletion outside
// items/. A missing item directory is not an error.
fn (s Store) remove_item_dir(id string) ! {
	if !is_safe_id(id) {
		return invalid_target_error('invalid item id `${id}`')
	}
	if os.is_link(s.items_dir()) {
		return invalid_target_error('items directory `${s.items_dir()}` must not be a symlink')
	}
	mut items := fsx.open_dir(s.items_dir())!
	defer {
		items.close()
	}
	items.remove_child_any(id, s.item_dir(id))!
	items.sync(s.items_dir())!
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
	s.remove_item_dir(item.id)!
}

// is_safe_restore_target reports whether a journaled restore target can be
// trusted. A tampered index must never make recovery touch a path outside the
// store, so the target has to be absolute, already normalised and name a real
// entry rather than the root or a `.`/`..` component.
fn is_safe_restore_target(target string) bool {
	if target == '' || target.contains('\x00') || !os.is_abs_path(target) {
		return false
	}
	if os.abs_path(target) != target {
		return false
	}
	return target != '/' && os.file_name(target) !in ['.', '..']
}

// recover_restore_target inspects a journaled target. It returns true when the
// item was already fully restored, in which case the row is gone.
fn (s Store) recover_restore_target(item IndexItem, target string) !(bool, string) {
	parent_path := os.dir(target)
	mut parent := fsx.open_dir(parent_path) or {
		return false, 'item ${item.id}: cannot open restore target parent `${parent_path}` safely: ${err.msg()}'
	}
	defer {
		parent.close()
	}
	tmp_name := '${os.file_name(target)}.trash-tmp-${item.id}'
	marker_name := '${tmp_name}.owner'
	// Only remove a temp path that carries our marker. Without it the path may
	// belong to someone else, and restore_to comes from the index.
	marker := parent.read_child(marker_name, 256) or { '' }
	if marker == item.id {
		parent.remove_child_any(tmp_name, os.join_path(parent_path, tmp_name)) or {
			return false, 'item ${item.id}: cannot remove stale restore temporary file: ${err.msg()}'
		}
		parent.remove_child_any(marker_name, os.join_path(parent_path, marker_name)) or {
			return false, 'item ${item.id}: cannot remove stale restore marker: ${err.msg()}'
		}
	}
	if restore_target_matches(item, target) {
		// The rename completed before the crash; the target is our payload, so
		// finish the restore instead of duplicating it.
		s.delete_item(item.id)!
		s.remove_item_dir(item.id)!
		return true, ''
	}
	return false, ''
}

fn (s Store) recover_restore(item IndexItem) !string {
	if os.is_link(s.item_dir(item.id)) {
		return ''
	}
	mut warning := ''
	if item.restore_to != '' {
		target := percent_decode_path(item.restore_to) or { '' }
		if is_safe_restore_target(target) {
			finished, target_warning := s.recover_restore_target(item, target)!
			if finished {
				return target_warning
			}
			if target_warning != '' {
				warning = target_warning
			}
		} else {
			warning = 'item ${item.id}: invalid restore target in index; rolled back to trashed'
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
		s.remove_item_dir(item.id)!
	}
	return warning
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
		new_id := s.next_id()
		if !is_safe_id(new_id) {
			return invalid_target_error('id generator returned an unsafe id `${new_id}`')
		}
		mut items := fsx.open_dir(s.items_dir())!
		defer {
			items.close()
		}
		mut gc := fsx.open_dir(s.gc_dir())!
		defer {
			gc.close()
		}
		dest_name := '${item.id}-recovered-${new_id}'
		fsx.renameat_noreplace(items.fd, item.id, gc.fd, dest_name)!
		items.sync(s.items_dir())!
		gc.sync(s.gc_dir())!
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

// gc_locked removes garbage and returns one warning per entry it could not
// remove. A single stubborn entry must not turn into a fatal error: the caller
// keeps working and surfaces the warnings instead.
fn (s Store) gc_locked_warnings() ![]string {
	if os.is_link(s.gc_dir()) {
		return invalid_target_error('garbage directory `${s.gc_dir()}` must not be a symlink')
	}
	if !os.is_dir(s.gc_dir()) {
		return []string{}
	}
	mut gc := fsx.open_dir(s.gc_dir())!
	defer {
		gc.close()
	}
	entries := os.ls(s.gc_dir()) or { []string{} }
	mut warnings := []string{}
	for entry in entries {
		failpoint('gc:remove-${entry}') or {
			warnings << '${entry}: ${err.msg()}'
			continue
		}
		gc.remove_child_any(entry, os.join_path(s.gc_dir(), entry)) or {
			warnings << '${entry}: ${err.msg()}'
			continue
		}
	}
	gc.sync(s.gc_dir())!
	return warnings
}

fn (s Store) gc_locked() ! {
	warnings := s.gc_locked_warnings()!
	if warnings.len > 0 {
		return io_error('could not remove ${warnings.len} garbage item(s): ${warnings.join('; ')}')
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
	warnings  []string
}

// purge_broken_locked detaches one broken item. The payload is moved into .gc
// first, and only then is the index row removed: a failed rename leaves both
// the row and the payload untouched, while a failed delete leaves the payload
// in .gc (still recoverable) and keeps the row. The returned string is the
// action shown in the doctor report.
fn (s Store) purge_broken_locked(id string) string {
	mut items := fsx.open_dir(s.items_dir()) or { return 'purge failed' }
	defer {
		items.close()
	}
	mut gc := fsx.open_dir(s.gc_dir()) or { return 'purge failed' }
	defer {
		gc.close()
	}
	if os.is_dir(s.item_dir(id)) {
		new_id := s.next_id()
		if !is_safe_id(new_id) {
			return 'purge failed'
		}
		dest_name := 'doctor-${id}-${new_id}'
		fsx.renameat_noreplace(items.fd, id, gc.fd, dest_name) or { return 'purge failed' }
	}
	s.delete_item(id) or { return 'purge failed' }
	items.sync(s.items_dir()) or { return 'purge failed' }
	gc.sync(s.gc_dir()) or { return 'purge failed' }
	return 'purged'
}

// doctor inspects broken items and optionally mutates the store.
//
// Read-only reports (including --integrity-check) run under a shared lock, so
// they do not block put/restore/empty. Operations that move payloads or rewrite
// the index (--repair, --purge, --compact, --backup, --rebuild, --reindex) take
// the exclusive lock. Size measurement writes only the size columns, so --repair
// fills sizes under a shared lock after the exclusive phase.
pub fn (s Store) doctor(opts DoctorOptions) !DoctorReport {
	return s.doctor_impl(opts) or { return classify_error(err, 'doctor', s.root) }
}

fn (s Store) doctor_impl(opts DoctorOptions) !DoctorReport {
	if os.is_link(s.gc_dir()) {
		return invalid_target_error('garbage directory `${s.gc_dir()}` must not be a symlink')
	}
	if os.is_link(s.items_dir()) {
		return invalid_target_error('items directory `${s.items_dir()}` must not be a symlink')
	}
	mutating := opts.repair || opts.purge || opts.compact || opts.backup || opts.rebuild || opts.reindex
	mut report := DoctorReport{}
	if mutating {
		mut fl := s.lock_exclusive()!
		s.doctor_locked(opts, mut report) or {
			fl.release()
			return err
		}
		fl.release()
	} else {
		mut fl := s.lock_shared()!
		s.doctor_locked(opts, mut report) or {
			fl.release()
			return err
		}
		fl.release()
	}
	if opts.repair {
		// Only size columns are written here; this does not need the exclusive
		// store lock, so other commands are not blocked while trees are measured.
		mut fl := s.lock_shared()!
		s.fill_doctor_sizes(mut report)
		fl.release()
	}
	return report
}

fn (s Store) doctor_locked(opts DoctorOptions, mut report DoctorReport) ! {
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
		if !is_safe_id(broken.id) {
			action = 'skipped: invalid id'
		} else if os.is_link(s.item_dir(broken.id)) {
			// A symlinked item directory is evidence of tampering: report it and
			// leave it for the user instead of following or silently removing it.
			action = 'skipped: symlinked item'
		} else if opts.purge {
			action = s.purge_broken_locked(broken.id)
			if action == 'purged' {
				report.purged++
			}
		}
		report.items << DoctorItem{
			id:     broken.id
			reason: broken.reason
			action: action
		}
	}
	if report.purged > 0 {
		report.warnings << s.gc_locked_warnings()!
	}
}

// fill_doctor_sizes measures unknown sizes after the exclusive repair phase.
// Sizes are written with one batched transaction per store.
fn (s Store) fill_doctor_sizes(mut report DoctorReport) {
	mut unknown := []Entry{}
	for entry in s.scan().entries {
		if !entry.size_known {
			unknown << entry
		}
	}
	for entry in s.fill_sizes(unknown) {
		if entry.size_known {
			report.sized++
		} else {
			report.unknown++
		}
	}
}
