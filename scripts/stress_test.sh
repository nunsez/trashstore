#!/usr/bin/env bash
# Mixed 8-process stress: concurrent put, list, restore and empty.
# Fails on SQLITE_BUSY, lost items, or a failed integrity check.
set -euo pipefail

TRASH_BIN=${1:-./trash}
TRASH_BIN=$(cd "$(dirname "$TRASH_BIN")" && pwd)/$(basename "$TRASH_BIN")
WORKERS=${WORKERS:-8}
PER=${PER:-10}
READERS=${READERS:-20}
WORK=$(mktemp -d)
STORE="$WORK/trash"
trap 'rm -rf "$WORK"' EXIT

fail() {
    echo "stress test failed: $*" >&2
    exit 1
}

check_logs() {
    if grep -R -E 'SQLITE_BUSY|database is locked|sqlite error 5' "$WORK"/*.log 2>/dev/null; then
        fail "busy error surfaced"
    fi
}

for ((w = 1; w <= WORKERS; w++)); do
    mkdir -p "$WORK/w$w"
    for ((i = 1; i <= PER; i++)); do
        printf 'worker %s file %s\n' "$w" "$i" >"$WORK/w$w/f$i"
    done
done

# Readers run while the writers work; WAL must keep them consistent.
(
    for _ in $(seq 1 "$READERS"); do
        "$TRASH_BIN" --store "$STORE" list --all >/dev/null 2>>"$WORK/read.log"
        "$TRASH_BIN" --store "$STORE" stats >/dev/null 2>>"$WORK/read.log"
    done
) &
READER_PID=$!

for ((w = 1; w <= WORKERS; w++)); do
    (
        args=()
        for ((i = 1; i <= PER; i++)); do
            args+=("$WORK/w$w/f$i")
        done
        "$TRASH_BIN" --store "$STORE" "${args[@]}" >/dev/null 2>"$WORK/put$w.log"
    ) &
done
wait
wait "$READER_PID" 2>/dev/null || true
check_logs

EXPECTED=$((WORKERS * PER))
GOT=$(find "$STORE/items" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
[ "$GOT" = "$EXPECTED" ] || fail "expected $EXPECTED items, got $GOT"

# Restore each worker's own files by original path, concurrently.
for ((w = 1; w <= WORKERS; w++)); do
    (
        args=()
        for ((i = 1; i <= PER; i++)); do
            args+=("$WORK/w$w/f$i")
        done
        "$TRASH_BIN" --store "$STORE" restore --yes "${args[@]}" >/dev/null 2>"$WORK/restore$w.log"
    ) &
done
wait
check_logs

for ((w = 1; w <= WORKERS; w++)); do
    for ((i = 1; i <= PER; i++)); do
        [ -f "$WORK/w$w/f$i" ] || fail "missing restored $WORK/w$w/f$i"
    done
done
GOT=$(find "$STORE/items" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
[ "$GOT" = "0" ] || fail "expected an empty store after restore, got $GOT"

# Put everything again and race several empty --all processes.
for ((w = 1; w <= WORKERS; w++)); do
    (
        args=()
        for ((i = 1; i <= PER; i++)); do
            args+=("$WORK/w$w/f$i")
        done
        "$TRASH_BIN" --store "$STORE" "${args[@]}" >/dev/null 2>"$WORK/put2-$w.log"
    ) &
done
wait
check_logs

for ((w = 1; w <= WORKERS; w++)); do
    "$TRASH_BIN" --store "$STORE" empty --all --yes --wait >/dev/null 2>"$WORK/empty$w.log" &
done
wait
check_logs

GOT=$(find "$STORE/items" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
[ "$GOT" = "0" ] || fail "expected an empty store after empty --all, got $GOT"
[ -z "$(find "$STORE/.gc" -mindepth 1 -maxdepth 1 2>/dev/null)" ] || fail ".gc was not cleaned"

"$TRASH_BIN" --store "$STORE" doctor --integrity-check 2>"$WORK/doctor.log" | grep -q 'integrity: ok' \
    || fail "integrity check failed"

echo "stress test passed (${WORKERS} workers x ${PER} items, ${READERS} readers)"
