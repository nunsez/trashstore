// Re-vendor the SQLite amalgamation.
//
// Usage:
//   v run scripts/update_sqlite.vsh          # download, verify and replace the files
//   v run scripts/update_sqlite.vsh --check  # verify the checked-in files (offline)
//
// To move to a new version, edit version/zip_name/url/size/sha3 and the two
// extracted hashes below. The hashes use SHA3-256, the same algorithm V's
// install script uses for its own pin.
import compress.szip
import crypto.sha3
import net.http
import os
import time

const version = '3.53.4'
const zip_name = 'sqlite-amalgamation-3530400.zip'
const url = 'https://sqlite.org/2026/${zip_name}'
const size = 2946650
const sha3_sum = '628a44cfe82c66aed1ccbbe85a562d2e33ebe64b3288981ed76285612227934e'
const c_sha3 = '67f423e9ebbbdc473cbc4772c872ee6b89f31fde4ed0279a5c25d5f65c043a16'
const h_sha3 = '89d0de498b1012938bb78dc18b68fea52e26f7f7b6db6347d126a2e58b86a05c'

fn main() {
	run() or {
		eprintln('update_sqlite: ${err.msg()}')
		exit(1)
	}
}

fn run() ! {
	root := os.real_path(os.join_path(os.dir(@FILE), '..'))
	if os.args.len > 1 && os.args[1] == '--check' {
		check_files(root)!
		println('thirdparty/sqlite matches ${version}')
		return
	}
	if os.args.len > 1 {
		return error('usage: update_sqlite.vsh [--check]')
	}

	tmp := os.join_path(os.temp_dir(), 'trash-sqlite-${os.getpid()}-${time.now().unix_nano()}')
	os.mkdir_all(tmp)!
	defer {
		os.rmdir_all(tmp) or {}
	}

	println('> downloading ${url}')
	response := http.get(url)!
	if response.status_code != 200 {
		return error('download failed: HTTP ${response.status_code}')
	}
	if response.body.len != size {
		return error('size mismatch: ${response.body.len} != ${size}')
	}
	actual_sha3 := sha3.sum256(response.body.bytes()).hex()
	if actual_sha3 != sha3_sum {
		return error('sha3 mismatch: ${actual_sha3} != ${sha3_sum}')
	}

	zip_path := os.join_path(tmp, zip_name)
	os.write_file(zip_path, response.body)!
	szip.extract_zip_to_dir(zip_path, tmp)!
	src_dir := os.join_path(tmp, 'sqlite-amalgamation-3530400')
	dest_dir := os.join_path(root, 'thirdparty', 'sqlite')
	os.mkdir_all(dest_dir)!
	for file in ['sqlite3.c', 'sqlite3.h'] {
		data := os.read_bytes(os.join_path(src_dir, file))!
		os.write_bytes(os.join_path(dest_dir, file), data)!
	}
	println('> updated thirdparty/sqlite to ${version}')
}

fn check_files(root string) ! {
	pairs := [['sqlite3.c', c_sha3], ['sqlite3.h', h_sha3]]
	for pair in pairs {
		path := os.join_path(root, 'thirdparty', 'sqlite', pair[0])
		actual := sha3.sum256(os.read_bytes(path)!).hex()
		if actual != pair[1] {
			return error('${pair[0]}: sha3 mismatch: ${actual} != ${pair[1]}')
		}
	}
}
