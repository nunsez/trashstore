# trash

A safe `rm` replacement for Unix and macOS. Instead of deleting files, `trash`
moves them into a private store where they can be listed, restored, or emptied
later. The same core is available as a small V library (`module trash`) with a
non-interactive `Store` API.

## Features

- Restore never overwrites: conflicts become `name~1`, `name~2`, ...
- Crash-safe: every item is a row in a transactional SQLite index. A small
  state machine (`pending`, `trashed`, `restoring`, `pending_empty`) lets
  `trash` finish or roll back interrupted put/restore/empty operations.
- Atomic same-filesystem moves; safe copies across filesystems (`clonefile` on
  macOS when available).
- Guards against trashing `/`, `.`/`..`, the store itself, its ancestors, and
  the current directory.
- `list`, `restore`, and `empty` share one selection model: cwd by default,
  `-r` for the subtree, `--all` for the whole store, plus targets, filters,
  sorting, and limits. `where` resolves refs to their payload location, and
  `stats` summarises the store.
- `list --ids` prints one full id per line, so `trash list ... --ids | trash
  where` locates a filtered selection without parsing a table.
- Batch operations keep successful results and report per-item failures.
- `--dry-run`, `--json`, and `--yes` for scripting.
- `doctor` finds and optionally repairs broken items.

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
# Move to trash (directories need -r)
trash report.txt old-dir/another-file
trash -r build/

# Preview without changing anything
trash --dry-run report.txt

# List items from the current directory, its subtree, or the whole store
trash list
trash list -r
trash list --all --long

# Filter and sort
trash list --all --kind file --grep report --sort size
trash list --all --older-than 30d

# Restore the current directory selection, an item, or a path
trash restore
trash restore -i
trash restore 8bd42d97
trash restore ./report.txt
trash restore --all --limit 1

# Permanently delete an item, a selection, or the whole store
trash empty --yes 8bd42d97
trash empty
trash empty --all

# Retention: delete old items or keep the newest 10
trash empty --all --older-than 30d --yes
trash empty --all --keep 10 --yes

# Defer or wait for permanent deletion
trash empty --all --yes
trash empty --all --yes --wait

# Also remove broken items and orphan payloads (explicit consent)
trash empty --all --include-broken --yes

# Diagnostics and scripting
trash stats
trash where 8bd42d97
trash where ./report.txt
trash list --all --grep report --ids | trash where
trash doctor
trash doctor --repair
trash doctor --integrity-check
trash doctor --compact --reindex
trash doctor --backup
trash doctor --rebuild
trash list --json
```

The first non-flag argument is always a command, so a file named `list` must be
trashed as `trash ./list` (and `trash -- ./list` also works). `where` is a
locator: it accepts full ids, short ids, unique id prefixes, and
original paths, either as arguments or as one ref per line on stdin, and prints
the payload path of each match inside the store, one per line. It prints no
metadata; use `list` for that. Multiple refs produce one path per match, in
argument order, with duplicates dropped. When stdin is not a terminal and no
targets are given, `where` reads refs from stdin; unresolvable refs are
reported as warnings and skipped, and the command exits non-zero if any were
skipped. With explicit targets an unresolvable ref is an error and nothing is
printed.

`stats` prints the store location, item count, total known size, and the oldest
and newest deletion times.

`list` shows the last eight hex characters of each item id. `restore` and
`empty` accept that short id, any unique prefix of it, a unique prefix of the
full id, or the full id printed by `--long`.

Sizes are measured lazily: `put` only moves the payload, and the size of an
item (the apparent size of a file, or the sum of the apparent sizes of the
files inside a directory) is measured the first time `list` shows it and stored
in the index. Items whose size is not known yet show `-`, and the total
below the table only sums the known sizes, with an `(N unknown)` suffix.
`list --no-size` skips measuring (it cannot be combined with `--sort size`),
`--sort size` measures every candidate before sorting, and
`trash doctor --repair` measures every item that is still unknown.

`doctor` also maintains the index: `--integrity-check` runs SQLite's
`integrity_check`, `--compact` vacuums the file and releases free pages,
`--reindex` rebuilds the b-trees, and `--backup` writes a consistent snapshot to
`index.backup.db`. `--rebuild` recreates rows from the payloads when `index.db`
was lost; original paths are not stored anywhere else, so rebuilt items have no
original path and cannot be restored in place (use `trash where <id>` to find
the payload).

The default store is `$XDG_DATA_HOME/trash`, falling back to
`~/.local/share/trash`. Override it with `--store` or `$TRASH_STORE`; `--store`
may appear before or after the command. Run `trash help <command>` for
command-specific flags.

## JSON output

`--json` is supported by `list`, `restore`, `empty`, `where`, `stats`, and
`doctor`. Output is never coloured; errors still go to stderr with a non-zero
exit status. The main shapes are:

- `list` → `{ id, original_path, deleted_at, kind, size, size_known }[]`
- `restore` → `{ id, original_path, restored_to }[]`
- `empty` → `{ emptied, dry_run }` (plus `items` with `--dry-run`)
- `where` → `{ id, location }[]`
- `stats` → `{ root, items, broken, size, unknown, oldest, newest }`
- `doctor` → `{ broken, repaired, purged, sized, unknown, integrity, backup, rebuilt, compacted, reindexed, items: [{ id, reason, action }] }`

`size` is only meaningful when `size_known` is true; `stats` reports the total
of the known sizes and the number of items whose size was not measured yet.

## Library API

```v
import trash

store := trash.open('/path/to/trash')!
report := store.recover_if_needed()!
for warning in report.warnings {
    eprintln(warning)
}

entry := store.put('/tmp/report.txt')!
put_batch := store.put_many(['/tmp/a.txt', '/tmp/b.txt'])!
println('${put_batch.entries.len} trashed, ${put_batch.failures.len} failed')

for item in store.list() {
    println('${item.id} ${item.original_path}')
}

results := store.restore(entry.id)!

// Batch operations keep successful results and report failures.
batch := store.restore_batch(store.scan().entries)!
println('${batch.results.len} restored, ${batch.failures.len} failed')
```

Errors are `TrashError` with an `ErrorKind`. Use `scan()`, `stats()`, and the
`*_batch()` methods for bulk work. `Entry.size` is only valid when
`Entry.size_known` is true; call `fill_size(entry)` or `fill_sizes(entries)` to
measure unknown sizes and persist them in the item metadata.

The core library never prints, prompts, or exits. Ids from outside the store
should be passed to `payload_path_checked()` instead of `payload_path()`, which
returns the path without validating the id. A deliberately shared store can be
opened with `allow_insecure: true`; the CLI never does that.

## Security

The store is private by design:

- It must be owned by the current user and must not be writable by the group or
  others (mode `0700`). `open` rejects `0770`/`0777` stores; the library can opt
  in with `allow_insecure: true`.
- `items/`, `.gc/` and the lock file must be real files and
  directories, never symlinks. A symlinked item directory is reported as broken
  and is never repaired, restored, or purged through.
- `restore` refuses to write when the parent of the original path no longer
  resolves to itself, for example because a component was replaced with a
  symlink or renamed after the item was trashed. The error names both the
  original path and the resolved parent.
- Batch APIs validate ids from library callers: `restore_batch` and
  `empty_batch` reject `''`, `.`, `..`, `a/b`, `a\b` and ids containing NUL.
- `index.db` and `index.backup.db` contain original paths, sizes and ids. They
  are protected by the private store directory (`0700`), not encrypted; treat
  them as sensitive metadata. WAL/SHM files can contain recently deleted rows
  and are removed when the store is closed cleanly.
- If `index.db` was written by a different schema version, `trash` refuses to
  open the store. An interactive run asks whether to wipe the store;
  `--reset-store` answers yes without a prompt. Wiping permanently deletes
  every trashed item.

Threat model: this protects a user's files from other local users and from
mistakes, not from the owner or root. Trashing is not secure erasure: payload
bytes may remain on disk until overwritten.

## Crash recovery

Every mutation is a short transaction on `index.db` plus a rename of the
payload. Before touching a payload, `trash` commits a `pending`/`restoring`/
`pending_empty` row; after the rename it commits the final state (or deletes the
row). `recover_if_needed()` looks at the payload to decide whether to finish or
roll back an interrupted operation. If another process already holds the
exclusive recovery lock, the call returns an empty report and the lock holder
(or the next run) finishes the work. Broken items are reported by
`list`/`restore` and skipped; an orphaned payload (a directory without a row) is
never deleted automatically. `empty --all` only deletes valid items; pass
`--include-broken` to also remove broken items and orphan payloads (the same
work `doctor --doctor-purge` does).

`put` and `restore` take a shared store lock; `empty` takes the exclusive lock,
so a wipe waits for in-flight operations instead of racing them, and concurrent
`empty --all` runs are idempotent. GC continues past an item it cannot remove and reports the remainder, so
one unreadable entry does not block the rest.

## Design notes

A store is one directory:

```text
<store>/
  index.db          SQLite index, one row per item (STRICT tables, schema v2)
  index.db-wal      write-ahead log, present while the store is in use
  index.db-shm      shared-memory file for WAL
  index.backup.db   optional snapshot written by `doctor --backup`
  items/<id>/data   payload
  .gc/              items being permanently deleted
  .lock             advisory lock for destructive operations
```

`index.db` is the single source of truth; the payload directory is the evidence
used by crash recovery. Rows move through `pending -> trashed -> restoring /
pending_empty` (see "Crash recovery"). `doctor --rebuild` can recreate rows from
payloads if `index.db` is lost, but the original path is not stored anywhere
else, so rebuilt items cannot be restored in place; `trash where <id>` still
finds their payload.

SQLite is vendored as a C amalgamation under `thirdparty/sqlite/` and compiled
into the binary. There are no external runtime dependencies and no network
access at build time; the only build dependency is the V toolchain. The
amalgamation is pinned to 3.53.4, and `scripts/update_sqlite.sh --check`
verifies the checked-in files against the pinned hashes.

Back up the index with `trash doctor --backup`, which writes a consistent
`VACUUM INTO` snapshot to `index.backup.db`; `doctor --integrity-check` and
`--compact` check and shrink the live database. Do not copy `index.db` while
`trash` is running: either use `doctor --backup`, or copy the whole store while
no process is active. `index.db-wal` and `index.db-shm` belong to a live
database and are not disposable caches.

## Limitations

- Unix/macOS only. `rename_noreplace` is implemented for Linux and macOS; on
  other platforms the operation fails clearly instead of silently weakening the
  guarantee.
- The layout is intentionally not the Freedesktop Trash specification, so items
  do not appear in desktop file managers.
- Cross-filesystem moves preserve data and permissions, but not hardlinks,
  ACLs, xattrs, or timestamps.
- Cross-device put can leave the source in place if source removal fails after a
  successful copy; the item is still safely trashed.
- `rename_noreplace` requires filesystem support. Without
  `RENAME_NOREPLACE` / `RENAME_EXCL`, restore and empty fail rather than falling
  back to an unsafe overwrite.
- A failed restore can leave newly created (empty) parent directories behind;
  `trash` does not remove them because it cannot know whether another process
  started using them.

## Testing

```sh
make ci
```

`scripts/concurrency_test.sh` exercises parallel put/restore/empty operations,
`scripts/cross_device_test.sh` covers cross-device moves and the crash journal,
and `v run bench/bench.v 1000` benchmarks the hot paths. Crash points can be
injected with `TRASH_TEST_FAILPOINTS=1` and `TRASH_FAILPOINT`.
