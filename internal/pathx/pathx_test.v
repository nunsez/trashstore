module pathx

fn test_canonical_path_empty() {
	assert canonical_path('') == ''
	assert canonical_target_path('') == ''
}

fn test_canonical_path_root() {
	assert canonical_path('/') == '/'
	assert canonical_target_path('/') == '/'
}
