#!/bin/sh
# Re-vendor the SQLite amalgamation.
#
# Usage:
#   scripts/update_sqlite.sh          # download, verify and replace the files
#   scripts/update_sqlite.sh --check  # verify the checked-in files (offline)
#
# To move to a new version, edit version/zip_name/url/size/sha3 and the two
# extracted hashes below. The hashes use SHA3-256, the same algorithm V's
# install script uses for its own pin.
set -eu

version=3.53.4
zip_name=sqlite-amalgamation-3530400.zip
url=https://sqlite.org/2026/${zip_name}
size=2946650
sha3=628a44cfe82c66aed1ccbbe85a562d2e33ebe64b3288981ed76285612227934e
c_sha3=67f423e9ebbbdc473cbc4772c872ee6b89f31fde4ed0279a5c25d5f65c043a16
h_sha3=89d0de498b1012938bb78dc18b68fea52e26f7f7b6db6347d126a2e58b86a05c

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

sha3_of() {
	cat > "${tmp}/sha3.v" <<'EOF'
import crypto.sha3
import os

fn main() {
	println(sha3.sum256(os.read_bytes(os.args[1])!).hex())
}
EOF
	v run "${tmp}/sha3.v" "$1"
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

if [ "${1:-}" = "--check" ]; then
	for pair in "sqlite3.c ${c_sha3}" "sqlite3.h ${h_sha3}"; do
		file=${pair% *}
		want=${pair#* }
		got=$(sha3_of "${root}/thirdparty/sqlite/${file}")
		if [ "${got}" != "${want}" ]; then
			echo "${file}: sha3 mismatch: ${got} != ${want}" >&2
			exit 1
		fi
	done
	echo "thirdparty/sqlite matches ${version}"
	exit 0
fi

echo "> downloading ${url}"
curl -fsSL -o "${tmp}/${zip_name}" "${url}"

actual_size=$(wc -c < "${tmp}/${zip_name}" | tr -d ' ')
if [ "${actual_size}" != "${size}" ]; then
	echo "size mismatch: ${actual_size} != ${size}" >&2
	exit 1
fi

actual_sha3=$(sha3_of "${tmp}/${zip_name}")
if [ "${actual_sha3}" != "${sha3}" ]; then
	echo "sha3 mismatch: ${actual_sha3} != ${sha3}" >&2
	exit 1
fi

unzip -q "${tmp}/${zip_name}" -d "${tmp}"
mkdir -p "${root}/thirdparty/sqlite"
cp "${tmp}/sqlite-amalgamation-3530400/sqlite3.c" "${root}/thirdparty/sqlite/sqlite3.c"
cp "${tmp}/sqlite-amalgamation-3530400/sqlite3.h" "${root}/thirdparty/sqlite/sqlite3.h"
echo "> updated thirdparty/sqlite to ${version}"
