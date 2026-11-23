module trash

import internal.pathx

fn canonical_path(path string) string {
	return pathx.canonical_path(path)
}

fn canonical_target_path(path string) string {
	return pathx.canonical_target_path(path)
}

fn is_path_within(path string, base string) bool {
	return pathx.is_path_within(path, base)
}

// percent_encode_path encodes a path for metadata storage.
pub fn percent_encode_path(path string) string {
	return pathx.percent_encode_path(path)
}

// percent_decode_path decodes a percent-encoded metadata path.
pub fn percent_decode_path(encoded string) !string {
	return pathx.percent_decode_path(encoded)
}

fn resolve_name_conflict(base string) string {
	return pathx.resolve_name_conflict(base)
}

fn check_trash_target(target string, root string, cwd string) ! {
	return pathx.check_trash_target(target, root, cwd)
}
