# trash

A safe `rm` replacement for Unix and macOS. Files are moved into a private
item store, so they can be listed, restored, purged, or emptied later.

The repository is also a small V library (`module trash`) with a thin,
non-interactive `Store` API for embedding the same semantics in other programs.

## Features

- Atomic same-filesystem moves; a safe copy path across filesystems.
- Metadata and payload live together in `items/<uuidv7>/`.
- Restore by id, unique id prefix, original path, or "last deleted".
- Directories require `-r`; symlinks to directories do not.
- Guards against trashing `/`, `.`/`..`, the trash root, its ancestors, and the
  current directory or its ancestors. Refuses `/` and world-writable roots as
  the trash directory.
- Restore never overwrites: conflicts become `name~1`, `name~2`, ...
  `renameat2(RENAME_NOREPLACE)` / `renamex_np(RENAME_EXCL)` is used with no
  check-then-rename fallback.
- Crash recovery through `inflight/` markers and atomic metadata writes.
- `fsync` on metadata, payload files, and both sides of every rename.
- Batch operations group directory fsyncs and prepare all item directories before
  moving payloads.
- Restore journal records the payload/target inode so recovery can recognize an
  already completed move.
- macOS regular files use `clonefile` when available, with a copy fallback.
- Cross-device copy to a unique temporary name, fsync, no-replace rename, then
  source removal.
- One store scan per CLI command; batch put/restore/purge without O(n²) rescans.
- Batch operations report per-item failures and keep successful results.
- `list` filters by kind/path/age, sorts by date/size/path/kind, and shows
  relative ages.
- `restore --select` picks an item interactively.
- Retention policies: `purge --older-than`, `empty --older-than`, `empty --keep`.
- `doctor` reports broken items, repairs id mismatches, pending/restoring
  state, invalid timestamps/kinds, and corrupt metadata when the payload still
  exists. Recovered items without a usable original path are restored to
  `$GRAVEYARD/recovered/<id>`. `--doctor-purge` removes broken items.
- `empty` detaches items under the exclusive lock and defers `.gc` cleanup;
  use `empty --wait` to wait for permanent deletion.
- `--dry-run`, `--json`, and non-interactive `--yes` for scripting.
- `--no-sync` explicitly disables fsync for filesystems that cannot provide it;
  this is unsafe and prints a warning.
- Typed `TrashError` with `ErrorKind`, operation, path, error code, and cause.

## Build

```sh
v -o trash ./cmd/trash
```

Install the man page and completions if desired:

```sh
install -m 755 trash /usr/local/bin/trash
install -m 644 trash.1 /usr/local/share/man/man1/trash.1
install -m 644 completions/trash.bash /usr/local/share/bash-completion/completions/trash
install -m 644 completions/trash.zsh /usr/local/share/zsh/site-functions/_trash
install -m 644 completions/trash.fish /usr/local/share/fish/vendor_completions.d/trash.fish
```

## Usage

```sh
# Move files to the trash
trash report.txt old-dir/another-file

# A directory needs -r
trash -r build/

# Preview without changing anything
trash --dry-run report.txt

# List items deleted from the current directory
trash list

# List the current directory and its subtree
trash list -r

# List the whole trash, with full ids
trash list --all --long

# Filter and sort
trash list --all --kind file --grep report --sort size
trash list --all --older-than 30d

# Interactively pick one item to restore
trash restore --select

# JSON output
trash list --json

# Restore the newest item
trash restore

# Restore a specific item (full id or unique prefix)
trash restore 01a203aa

# Restore every item deleted from this path
trash restore --all ./report.txt

# Restore exactly what `trash list` shows
trash restore --from-cwd

# Permanently delete one item
trash purge 01a203aa

# Permanently empty the trash (asks on a TTY)
trash empty

# Retention: purge old items, or keep the newest 10
trash purge --older-than 30d --yes
trash empty --keep 10 --yes

# Wait for permanent deletion instead of deferring GC
trash empty --yes --wait

# Report or repair broken items
trash doctor
trash doctor --repair

# Scripted empty
trash empty --yes

# Show the store location and item count
trash where
```

The default store is `$XDG_DATA_HOME/trash`, falling back to
`~/.local/share/trash`. Override it with `--graveyard` or `$GRAVEYARD`.
`--graveyard` may appear before or after the command.

Run `trash help <command>` for command-specific flags and examples.

## JSON output

`--json` is supported by `list`, `restore`, `purge`, `empty`, `where`, and
`doctor`.

- `list` → array of `{ id, original_path, deleted_at, kind, size }`.
- `restore` → array of `{ id, original_path, restored_to }`.
- `purge` → `{ purged, failed }`; with `--dry-run`,
  `{ would_purge, items }`.
- `empty` → `{ emptied, dry_run }`.
- `where` → `{ root, items, broken, size, oldest, newest }`.
- `doctor` → `{ broken, repaired, purged, items }`, where each item has
  `{ id, reason, action }`.

JSON is never coloured. Errors still go to stderr and set a non-zero exit
status.


## Store layout

```
<root>/
  items/<id>/
    meta.json
    data
  inflight/          # in-progress operation markers
  .gc/               # renamed here before permanent deletion
  .lock              # shared for put/restore, exclusive for empty/gc
```

`meta.json` stores the id, state (`pending`, `trashed`, `restoring`),
percent-encoded original path, RFC3339 deletion time, kind, size, and the
restore target for crash recovery. Metadata is validated on read: id mismatch,
unknown state/kind, relative path, or invalid timestamp marks the item broken.

## Recovery model

- `put`: create item dir -> marker -> write `pending` metadata -> move payload
  -> write `trashed` metadata -> remove marker.
- `restore`: marker -> write `restoring` metadata with the final target -> move
  payload -> remove item dir -> remove marker.
- `purge`: marker -> no-replace rename item dir into `.gc/` -> remove marker.
- `empty`: exclusive lock -> recover -> no-replace rename `items/` and
  `inflight/` into `.gc/` -> recreate empty directories -> release lock. GC is
  deferred unless `--wait` is used.

Recovery is explicit: `open()` prepares the layout, and the CLI calls
`recover_if_needed()` before each command. A pending item with a payload is
finalized; a pending item without a payload is rolled back. A restoring item
with a payload is returned to `trashed`; one without a payload is considered
already restored. Broken items are reported by `list`/`restore` and skipped,
but an orphaned payload is never deleted automatically.

## Library API

```v
import trash

store := trash.open('/path/to/trash')!
report := store.recover_if_needed()!
for warning in report.warnings {
    eprintln(warning)
}

entry := store.put('/tmp/report.txt', trash.PutOptions{})!
put_batch := store.put_many(['/tmp/a.txt', '/tmp/b.txt'], trash.PutOptions{})!
println('${put_batch.entries.len} trashed, ${put_batch.failures.len} failed')
for item in store.list(trash.ListFilter{}) {
    println('${item.id} ${item.original_path}')
}
results := store.restore(entry.id, trash.RestoreOptions{})!

// Batch operations keep successful results and report failures.
batch := store.restore_batch(store.scan().entries)!
println('${batch.results.len} restored, ${batch.failures.len} failed')
```

Public operations return `TrashError` for semantic failures, with
`ErrorKind` values such as `not_found`, `ambiguous`, `in_progress`,
`invalid_target`, `not_restorable`, `io`, `permission`, `conflict`,
`not_empty`, `unsupported`, and `unsupported_fs`. Errors also carry `op`,
`path`, `error_code`, and `cause`. Use `store.scan()` when you need entries and
broken items in one pass, `store.stats()` for aggregate counts, and
`put_many()` / `restore_batch()` / `purge_batch()` for batch work. Use
`open_with()` and `StoreOptions` to control creation, mode, owner checks, id
injection, and clock injection. Existing roots must be owned by the current
user unless `allow_foreign_owner` is set. `StoreOptions.sync = false` disables
fsync for filesystems that cannot provide it; this is unsafe.

The core library never prints, prompts, or exits.

## Source layout

```text
*.v                 public `module trash` library: Store, operations, metadata
internal/errs/      typed errors
internal/pathx/     path canonicalisation, percent encoding, target guards
internal/fsx/       fsync, copy, move, rename_noreplace, clonefile
internal/format/    shared size/age/time/id formatting for CLI and future UIs
trashcli/           CLI parsing and rendering, separate from the library
cmd/trash/          thin main
```

The library never imports the CLI. `internal/*` is implementation detail and is
not part of the public API.

## Testing

```sh
make ci
# or manually:
v fmt -verify .
v vet .
v test .
v -prod test .
v -prod -o /tmp/trash-prod ./cmd/trash
```

`scripts/concurrency_test.sh` exercises parallel put/restore/purge/empty
operations against one store. `scripts/cross_device_test.sh` uses `/dev/shm`
or a macOS RAM disk to exercise cross-device put/restore and the crash journal. `v run bench/bench.v 1000` measures put, scan,
full-id find, and batch restore. Tests include deterministic fuzz-style checks for percent encoding and metadata
JSON. Crash points can be injected with `TRASH_TEST_FAILPOINTS=1` and
`TRASH_FAILPOINT=put:after-move`, `restore:after-move`,
`restore:after-target-rename`, `purge:after-rename`, or
`empty:after-detach`.

## Limitations

- Unix/macOS only. `rename_noreplace` is implemented for Linux and macOS; on
  other platforms the operation fails clearly rather than silently weakening
  the guarantee.
- The layout is intentionally not the Freedesktop Trash specification, so
  items do not appear in desktop file managers.
- Cross-filesystem moves preserve data and permissions, but not hardlinks,
  ACLs, xattrs, or timestamps.
- Restore journals the payload inode (same device) or the temporary target
  inode (cross device), so a crash between rename and item cleanup finishes the
  restore instead of creating a duplicate.
- Cross-device put can leave the source in place if source removal fails after
  a successful copy; the item is still safely trashed.
- `rename_noreplace` requires filesystem support. On filesystems without
  `RENAME_NOREPLACE` / `RENAME_EXCL`, restore and purge fail instead of
  falling back to an unsafe overwrite.

## License

AGPLv3. See [LICENSE](LICENSE).
