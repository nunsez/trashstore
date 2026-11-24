module trash

import internal.sqlite

pub const app_name = 'trash'
pub const app_version = '0.1.0'

// batch_chunk_size bounds how many index rows a batch path journals before it
// commits. It is deliberately small: one huge transaction grows the WAL and
// makes the commit checkpoint a large burst, which is slower than incremental
// checkpoints even though it issues fewer fsyncs. Thirty-two still turns one
// commit per item into one commit per chunk.
const batch_chunk_size = 32

// engine_version returns the SQLite version the store is built with.
pub fn engine_version() string {
	return sqlite.version()
}
