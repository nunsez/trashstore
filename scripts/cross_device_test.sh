#!/usr/bin/env bash
set -euo pipefail

BIN=${1:-./trash}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/trash-cross.XXXXXX")
CROSS_ROOT=""
RAM_MOUNT=""
RAM_DEV=""

cleanup() {
    if [[ -n "$RAM_MOUNT" ]]; then
        diskutil unmount force "$RAM_MOUNT" >/dev/null 2>&1 || true
    fi
    if [[ -n "$RAM_DEV" ]]; then
        hdiutil detach "$RAM_DEV" >/dev/null 2>&1 || true
    fi
    rm -rf "$WORK"
    if [[ -n "$CROSS_ROOT" && "$CROSS_ROOT" == /dev/shm/* ]]; then
        rm -rf "$CROSS_ROOT"
    fi
}
trap cleanup EXIT

case "$(uname -s)" in
Linux)
    if [[ -d /dev/shm ]]; then
        work_dev=$(stat -c %d "$WORK")
        shm_dev=$(stat -c %d /dev/shm)
        if [[ "$work_dev" != "$shm_dev" ]]; then
            CROSS_ROOT=$(mktemp -d /dev/shm/trash-cross.XXXXXX)
        fi
    fi
    ;;
Darwin)
    if RAM_DEV=$(hdiutil attach -nobrowse -nomount ram://1048576 2>/dev/null | awk 'NR == 1 { print $1 }'); then
        RAM_MOUNT="/Volumes/TrashCross$$"
        if diskutil erasevolume HFS+ "TrashCross$$" "$RAM_DEV" >/dev/null 2>&1; then
            CROSS_ROOT="$RAM_MOUNT"
        else
            hdiutil detach "$RAM_DEV" >/dev/null 2>&1 || true
            RAM_DEV=""
            RAM_MOUNT=""
        fi
    fi
    ;;
esac

if [[ -z "$CROSS_ROOT" ]]; then
    echo "cross-device test skipped: no separate filesystem available"
    exit 0
fi

STORE="$WORK/store"
SRC="$CROSS_ROOT/file.txt"

printf 'cross-device payload\n' >"$SRC"
"$BIN" --store "$STORE" "$SRC"
if [[ -e "$SRC" ]]; then
    echo "cross-device put left the source in place" >&2
    exit 1
fi
"$BIN" --store "$STORE" restore "$SRC"
if [[ "$(cat "$SRC")" != "cross-device payload" ]]; then
    echo "cross-device restore did not preserve payload" >&2
    exit 1
fi

mkdir "$CROSS_ROOT/dir"
printf 'directory payload\n' >"$CROSS_ROOT/dir/child.txt"
"$BIN" --store "$STORE" -r "$CROSS_ROOT/dir"
if [[ -e "$CROSS_ROOT/dir" ]]; then
    echo "cross-device directory put left the source in place" >&2
    exit 1
fi
"$BIN" --store "$STORE" restore "$CROSS_ROOT/dir"
if [[ "$(cat "$CROSS_ROOT/dir/child.txt")" != "directory payload" ]]; then
    echo "cross-device directory restore did not preserve payload" >&2
    exit 1
fi

printf 'crash journal payload\n' >"$SRC"
"$BIN" --store "$STORE" "$SRC"
if TRASH_TEST_FAILPOINTS=1 TRASH_FAILPOINT=restore:after-target-rename \
    "$BIN" --store "$STORE" restore "$SRC" >/dev/null 2>&1; then
    echo "restore failpoint did not fail" >&2
    exit 1
fi
if [[ ! -f "$SRC" ]]; then
    echo "crash journal target is missing" >&2
    exit 1
fi
if [[ -e "$SRC~1" ]]; then
    echo "crash journal produced a duplicate target" >&2
    exit 1
fi
"$BIN" --store "$STORE" list --all --json >"$WORK/list.json"
if [[ "$(cat "$WORK/list.json")" != "[]" ]]; then
    echo "crash journal recovery left items behind" >&2
    cat "$WORK/list.json" >&2
    exit 1
fi

echo "cross-device test passed"
