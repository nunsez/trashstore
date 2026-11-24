module pathx

import os
import internal.errs

const percent_hex = '0123456789ABCDEF'

// canonical_path resolves symlinks in every existing component of `path`.
// Unlike os.real_path it also works when the path itself does not exist yet.
pub fn canonical_path(path string) string {
	if path == '' {
		return ''
	}
	abs := os.abs_path(path)
	resolved := os.real_path(abs)
	if resolved != abs || os.exists(abs) || os.is_link(abs) {
		return resolved
	}
	parent := os.dir(abs)
	if parent == abs {
		return abs
	}
	return os.join_path(canonical_path(parent), os.file_name(abs))
}

// canonical_target_path canonicalises the parent of `path` but keeps the final
// component as is, so symlinks themselves are moved/restored instead of their targets.
pub fn canonical_target_path(path string) string {
	if path == '' {
		return ''
	}
	abs := os.abs_path(path)
	name := os.file_name(abs)
	if name == '' {
		return canonical_path(abs)
	}
	return os.join_path(canonical_path(os.dir(abs)), name)
}

// is_path_within reports whether `path` is `base` itself or lies below it.
// The comparison is component-aware, so /tmp/graveyard does not match /tmp/grave.
pub fn is_path_within(path string, base string) bool {
	if path == base {
		return true
	}
	prefix := base.trim_right('/') + '/'
	return path.starts_with(prefix)
}

fn is_unreserved(c u8) bool {
	return c.is_alnum() || c == `-` || c == `.` || c == `_` || c == `~`
}

// percent_encode_path encodes a raw filesystem path for storage in metadata.
// Unreserved characters and '/' are kept as is; every other byte becomes %XX.
pub fn percent_encode_path(path string) string {
	mut out := []u8{cap: path.len + 16}
	for c in path.bytes() {
		if is_unreserved(c) || c == `/` {
			out << c
		} else {
			out << `%`
			out << percent_hex[c >> 4]
			out << percent_hex[c & 0x0F]
		}
	}
	return out.bytestr()
}

fn hex_value(c u8) ?u8 {
	if c >= `0` && c <= `9` {
		return c - `0`
	}
	if c >= `a` && c <= `f` {
		return c - `a` + 10
	}
	if c >= `A` && c <= `F` {
		return c - `A` + 10
	}
	return none
}

// percent_decode_path decodes a value produced by percent_encode_path.
pub fn percent_decode_path(encoded string) !string {
	mut out := []u8{cap: encoded.len}
	mut i := 0
	for i < encoded.len {
		c := encoded[i]
		if c != `%` {
			out << c
			i++
			continue
		}
		if i + 2 >= encoded.len {
			return error('invalid percent-encoding: truncated escape')
		}
		hi := hex_value(encoded[i + 1]) or {
			return error('invalid percent-encoding: bad hex digit')
		}
		lo := hex_value(encoded[i + 2]) or {
			return error('invalid percent-encoding: bad hex digit')
		}
		b := u8(hi << 4 | lo)
		if b == 0 {
			return error('invalid percent-encoding: NUL byte')
		}
		out << b
		i += 3
	}
	return out.bytestr()
}

// resolve_name_conflict returns `base` or the first free `base~N` variant.
pub fn resolve_name_conflict(base string) string {
	if !os.exists(base) && !os.is_link(base) {
		return base
	}
	mut counter := 1
	for {
		candidate := '${base}~${counter}'
		if !os.exists(candidate) && !os.is_link(candidate) {
			return candidate
		}
		counter++
	}
	return base
}

// check_trash_target rejects targets that are unsafe to move into the trash:
// the root, the trash directory itself, its ancestors, or the current directory
// and its ancestors.
pub fn check_trash_target(target string, root string, cwd string) ! {
	if target == '/' {
		return errs.invalid_target_error('refusing to trash the root directory')
	}
	name := os.file_name(target)
	if name == '.' || name == '..' {
		return errs.invalid_target_error('refusing to trash `.` or `..`')
	}
	if is_path_within(target, root) {
		return errs.invalid_target_error('refusing to trash a path inside the trash directory')
	}
	if is_path_within(root, target) {
		return errs.invalid_target_error('refusing to trash an ancestor of the trash directory')
	}
	if is_path_within(cwd, target) {
		return errs.invalid_target_error('refusing to trash the current directory or one of its ancestors')
	}
}
