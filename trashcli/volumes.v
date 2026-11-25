module trashcli

import internal.fsx
import internal.pathx
import os
import strconv

const store_dirname = 'trashstore'
const volume_store_prefix = '.trashstore-'
const volumes_filename = 'volumes'

// StoreSpec is the resolved default store plus whether it was chosen
// explicitly. Explicit stores (--store / $TRASH_STORE) disable per-volume
// stores and always use a single store.
struct StoreSpec {
	root     string
	explicit bool
}

// VolumeRecord is one entry of the per-user volume registry kept in the home
// store. It lets read commands find volume stores without enumerating mounts.
struct VolumeRecord {
	dev   u64
	mount string
	root  string
}

// TargetStore is the store chosen for one put target.
struct TargetStore {
	root  string
	mount string
	dev   u64
}

fn resolve_store_spec(cli_path string) !StoreSpec {
	if cli_path != '' {
		return StoreSpec{
			root:     pathx.canonical_path(cli_path)
			explicit: true
		}
	}
	env_store := os.getenv('TRASH_STORE')
	if env_store != '' {
		return StoreSpec{
			root:     pathx.canonical_path(env_store)
			explicit: true
		}
	}
	return StoreSpec{
		root: resolve_home_store()!
	}
}

// resolve_store resolves --store / $TRASH_STORE / the default home store.
pub fn resolve_store(cli_path string) !string {
	return resolve_store_spec(cli_path)!.root
}

fn resolve_home_store() !string {
	xdg_data := os.getenv('XDG_DATA_HOME')
	if xdg_data != '' {
		return pathx.canonical_path(os.join_path(xdg_data, store_dirname))
	}
	home := os.home_dir()
	if home != '' {
		return pathx.canonical_path(os.join_path(home, '.local', 'share', store_dirname))
	}
	return error('cannot determine home directory; pass --store')
}

fn volume_store_root(mount string, uid int) string {
	return os.join_path(mount, '${volume_store_prefix}${uid}')
}

// mount_point returns the mount point of the filesystem containing path. It
// walks up until the device id changes, which is portable and does not need
// platform-specific mount tables.
fn mount_point(path string) !string {
	canonical := pathx.canonical_target_path(path)
	st := os.lstat(canonical)!
	dev := st.dev
	mut current := canonical
	if st.get_filetype() != .directory {
		current = os.dir(canonical)
	}
	mut p := current
	for {
		parent := os.dir(p)
		if parent == p {
			break
		}
		parent_st := os.stat(parent) or { break }
		if parent_st.dev != dev {
			break
		}
		p = parent
	}
	return p
}

// check_not_mount_point refuses to trash the root of a mounted filesystem.
// Moving a mount point is either impossible or would detach a whole volume.
fn check_not_mount_point(target string) ! {
	canonical := pathx.canonical_target_path(target)
	st := os.lstat(canonical)!
	if st.get_filetype() != .directory {
		return
	}
	if canonical == mount_point(canonical)! {
		return error('refusing to trash the mount point `${canonical}`')
	}
}

// target_store_root chooses the store for a put target. Targets on the home
// filesystem use the home store; other filesystems get a per-volume store at
// <mount>/.trashstore-$uid.
fn target_store_root(target string, home_root string, home_dev u64) !TargetStore {
	check_not_mount_point(target)!
	canonical := pathx.canonical_target_path(target)
	st := os.lstat(canonical)!
	if st.dev == home_dev {
		return TargetStore{
			root: home_root
			dev:  st.dev
		}
	}
	mount := mount_point(canonical)!
	return TargetStore{
		root:  volume_store_root(mount, os.geteuid())
		mount: mount
		dev:   st.dev
	}
}

fn cwd_volume_root(cwd string, home_dev u64) ?string {
	st := os.lstat(cwd) or { return none }
	if st.dev == home_dev {
		return none
	}
	mount := mount_point(cwd) or { return none }
	return volume_store_root(mount, os.geteuid())
}

fn volumes_file(home_root string) string {
	return os.join_path(home_root, volumes_filename)
}

fn read_volume_records(home_root string) []VolumeRecord {
	text := os.read_file(volumes_file(home_root)) or { return []VolumeRecord{} }
	mut records := []VolumeRecord{}
	for line in text.split_into_lines() {
		if line.trim_space() == '' {
			continue
		}
		parts := line.split('\t')
		if parts.len != 3 {
			continue
		}
		dev := strconv.atoi64(parts[0]) or { continue }
		mount := pathx.percent_decode_path(parts[1]) or { continue }
		root := pathx.percent_decode_path(parts[2]) or { continue }
		records << VolumeRecord{
			dev:   u64(dev)
			mount: mount
			root:  root
		}
	}
	return records
}

// write_volume_records replaces the registry atomically. The temporary file is
// fsynced and the directory is synced after the rename, so a crash cannot leave
// a truncated registry that silently loses every volume store.
fn write_volume_records(home_root string, records []VolumeRecord) ! {
	mut lines := []string{cap: records.len}
	for record in records {
		lines << '${record.dev}\t${pathx.percent_encode_path(record.mount)}\t${pathx.percent_encode_path(record.root)}'
	}
	content := if lines.len > 0 { lines.join('\n') + '\n' } else { '' }
	path := volumes_file(home_root)
	tmp := '${path}.tmp-${os.getpid()}'
	os.write_file(tmp, content)!
	mut f := os.open(tmp)!
	mut renamed := false
	defer {
		f.close()
		if !renamed {
			os.rm(tmp) or {}
		}
	}
	fsx.fsync_fd(f.fd, tmp)!
	os.rename(tmp, path)!
	renamed = true
	fsx.fsync_dir(home_root)!
}

// volumes_lock serializes the read-modify-write of the registry, so two
// concurrent puts on different volumes do not lose each other's record.
fn volumes_lock(home_root string) !fsx.FileLock {
	mut l := fsx.open_lock('${volumes_file(home_root)}.lock')!
	l.lock_exclusive()!
	return l
}

fn register_volume(home_root string, record VolumeRecord) ! {
	mut fl := volumes_lock(home_root)!
	defer {
		fl.release()
	}
	mut records := read_volume_records(home_root)
	mut found := false
	for i, existing in records {
		if existing.root == record.root || (existing.dev == record.dev && existing.mount == record.mount) {
			records[i] = record
			found = true
			break
		}
	}
	if !found {
		records << record
	}
	write_volume_records(home_root, records)!
}

fn registered_roots(home_root string) []string {
	mut roots := []string{}
	for record in read_volume_records(home_root) {
		if os.is_dir(record.root) {
			roots << record.root
		}
	}
	return roots
}

fn dedupe_roots(roots []string) []string {
	mut seen := map[string]bool{}
	mut result := []string{cap: roots.len}
	for root in roots {
		if seen[root] {
			continue
		}
		seen[root] = true
		result << root
	}
	return result
}

// roots_for_read chooses the stores a read command has to scan. Commands that
// operate on the whole trash, resolve arbitrary ids, or summarise the store
// scan every registered volume store. Scope-based commands only need the home
// store and the store of the current directory.
fn roots_for_read(spec StoreSpec, cli Cli, cwd string, home_dev u64) []string {
	if spec.explicit {
		return [spec.root]
	}
	mut roots := [spec.root]
	all := cli.command in [.stats, .doctor, .where]
		|| (cli.command in [.list, .restore, .empty] && cli.all)
		|| (cli.command in [.restore, .empty] && cli.targets.len > 0)
	if all {
		roots << registered_roots(spec.root)
	}
	if volume_root := cwd_volume_root(cwd, home_dev) {
		if os.is_dir(volume_root) {
			roots << volume_root
		}
	}
	return dedupe_roots(roots)
}
