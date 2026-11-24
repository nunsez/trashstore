# SQLite amalgamation (vendored)

- Version: **3.53.4**
- Source: <https://sqlite.org/2026/sqlite-amalgamation-3530400.zip>
- Archive size: 2 946 650 bytes
- Archive SHA3-256: `628a44cfe82c66aed1ccbbe85a562d2e33ebe64b3288981ed76285612227934e`
- Files used: `sqlite3.c`, `sqlite3.h`
- Extracted SHA3-256:
  - `sqlite3.c`: `67f423e9ebbbdc473cbc4772c872ee6b89f31fde4ed0279a5c25d5f65c043a16`
  - `sqlite3.h`: `89d0de498b1012938bb78dc18b68fea52e26f7f7b6db6347d126a2e58b86a05c`
- License: public domain, <https://sqlite.org/copyright.html>

## Why vendored

The build must work offline and be reproducible. The V toolchain keeps its own
copy in `@VEXEROOT/thirdparty/sqlite`, but that directory is not tracked by the
V repository and is only created by a network install script
(`vlib/db/sqlite/install_thirdparty_sqlite.vsh`). Taking the amalgamation from
`@VEXEROOT` would make the build depend on how V was installed.

The version matches the one pinned by V 0.5.2 (see the comment in that install
script): 3.54.0 needs `SRWLOCK` on Windows, which tcc's `windows.h` does not
declare.

## Updating

Edit the pin at the top of `scripts/update_sqlite.vsh` and run it. The script
verifies the archive size and SHA3-256 before copying anything into the tree.
`v run scripts/update_sqlite.vsh --check` verifies the checked-in files against the
pinned SHA3-256 values without using the network.

Do not edit `sqlite3.c` or `sqlite3.h` by hand.

## Build flags

The flags live in `internal/sqlite/sqlite.v` (`#flag -D...`). Keep them
conservative: aggressive `SQLITE_OMIT_*` flags can break the amalgamation (for
example `SQLITE_OMIT_WINDOWFUNC`, `SQLITE_OMIT_VIRTUALTABLE` and
`SQLITE_OMIT_JSON` leave undefined symbols in the parser).
