module trash

import internal.sqlite

pub const app_name = 'trash'
pub const app_version = '0.1.0'

// engine_version returns the SQLite version the store is built with.
pub fn engine_version() string {
	return sqlite.version()
}
