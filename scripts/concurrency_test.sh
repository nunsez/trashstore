#!/usr/bin/env bash
set -euo pipefail

TRASH_BIN=${1:-./trash}
TRASH_BIN=$(cd "$(dirname "$TRASH_BIN")" && pwd)/$(basename "$TRASH_BIN")
N=${N:-60}
WORK=$(mktemp -d)
STORE="$WORK/trash"
trap 'rm -rf "$WORK"' EXIT

cd "$WORK"
for ((i = 1; i <= N; i++)); do
    printf 'file %s\n' "$i" > "file$i"
done

seq 1 "$N" | xargs -P 8 -I{} "$TRASH_BIN" --store "$STORE" "file{}"
test "$(find "$WORK" -maxdepth 1 -name 'file*' | wc -l | tr -d ' ')" = "0"
test "$(find "$STORE/items" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" = "$N"

"$TRASH_BIN" --store "$STORE" restore --all --yes
test "$(find "$WORK" -maxdepth 1 -name 'file*' | wc -l | tr -d ' ')" = "$N"

for ((i = 1; i <= N; i++)); do
    "$TRASH_BIN" --store "$STORE" "file$i"
done
seq 1 4 | xargs -P 4 -I{} "$TRASH_BIN" --store "$STORE" empty --all --yes --wait
test "$(find "$STORE/items" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" = "0"

echo "concurrency test passed (${N} items)"
