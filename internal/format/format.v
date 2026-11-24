module format

import time

// short_id_min_length is the number of trailing hex characters shown for a
// small store: 32 bits, enough while the store holds at most 2^16 items.
pub const short_id_min_length = 8

// short_id_max_length is the length of a UUID's hex form. A short id never
// grows past the full id.
pub const short_id_max_length = 32

// short_id_length returns the trailing-hex width needed for a store with
// `count` items. The birthday bound for 8 hex characters is 2^16 items, so the
// width grows by one hex digit for every doubling beyond that. This keeps
// displayed ids short for normal stores and unambiguous for huge ones.
pub fn short_id_length(count int) int {
	mut length := short_id_min_length
	mut capacity := u64(1) << 16
	n := if count > 0 { u64(count) } else { u64(0) }
	for n > capacity && length < short_id_max_length {
		length++
		capacity <<= 1
	}
	return length
}

// short_id_len returns the last `length` hex characters of an item id, without
// dashes. Item ids are UUIDv7, whose leading bits are a millisecond timestamp,
// so the leading characters are shared by every item trashed within ~65
// seconds. The trailing characters carry the random part and stay distinct.
pub fn short_id_len(id string, length int) string {
	hex := id.replace('-', '')
	if length <= 0 || hex.len <= length {
		return hex
	}
	return hex[hex.len - length..]
}

// short_id returns the default eight-character short id.
pub fn short_id(id string) string {
	return short_id_len(id, short_id_min_length)
}

// format_size returns a compact human-readable byte size.
pub fn format_size(size u64) string {
	if size < 1024 {
		return '${size} B'
	}
	if size < 1024 * 1024 {
		return '${size / 1024} KiB'
	}
	if size < 1024 * 1024 * 1024 {
		return '${size / (1024 * 1024)} MiB'
	}
	return '${size / (1024 * 1024 * 1024)} GiB'
}

// format_time returns a local timestamp with seconds precision.
pub fn format_time(t time.Time) string {
	return t.local().format_ss()
}

// format_age returns a compact relative age.
pub fn format_age(t time.Time) string {
	mut diff := time.now().unix() - t.unix()
	if diff < 0 {
		diff = 0
	}
	if diff < 60 {
		return '${diff}s ago'
	}
	if diff < 3600 {
		return '${diff / 60}m ago'
	}
	if diff < 86400 {
		return '${diff / 3600}h ago'
	}
	if diff < 86400 * 30 {
		return '${diff / 86400}d ago'
	}
	if diff < 86400 * 365 {
		return '${diff / (86400 * 30)}mo ago'
	}
	return '${diff / (86400 * 365)}y ago'
}
