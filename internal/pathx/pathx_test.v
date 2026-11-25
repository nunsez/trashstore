module pathx

fn test_canonical_path_empty() {
	assert canonical_path('') == ''
	assert canonical_target_path('') == ''
}

fn test_canonical_path_root() {
	assert canonical_path('/') == '/'
	assert canonical_target_path('/') == '/'
}

fn test_is_path_within_rejects_empty_arguments() {
	// An empty base used to become the prefix `/` and match every absolute
	// path, which turned `-r ""` into "the whole store".
	assert !is_path_within('/tmp/a', '')
	assert !is_path_within('', '/tmp')
	assert !is_path_within('', '')
	assert is_path_within('/tmp/a', '/tmp')
	assert is_path_within('/tmp', '/tmp')
	assert !is_path_within('/tmp/graveyard', '/tmp/grave')
}
