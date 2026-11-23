module format

import time

// short_id returns the last eight hex characters of an item id, without
// dashes. Item ids are UUIDv7, whose leading bits are a millisecond timestamp,
// so the leading characters are shared by every item trashed within ~65
// seconds. The trailing characters carry the random part and stay distinct.
pub fn short_id(id string) string {
	hex := id.replace('-', '')
	if hex.len <= 8 {
		return hex
	}
	return hex[hex.len - 8..]
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
