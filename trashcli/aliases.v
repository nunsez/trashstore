module trashcli

import internal.pathx
import trash

pub type Store = trash.Store
pub type StoreOptions = trash.StoreOptions
pub type Entry = trash.Entry
pub type EntryKind = trash.EntryKind
pub type EntryState = trash.EntryState
pub type ErrorKind = trash.ErrorKind
pub type TrashError = trash.TrashError
pub type PutOptions = trash.PutOptions
pub type PutBatch = trash.PutBatch
pub type ListFilter = trash.ListFilter
pub type ScanResult = trash.ScanResult
pub type BrokenItem = trash.BrokenItem
pub type RestoreOptions = trash.RestoreOptions
pub type RestoreResult = trash.RestoreResult
pub type RestoreBatch = trash.RestoreBatch
pub type EmptyBatch = trash.EmptyBatch
pub type BatchFailure = trash.BatchFailure
pub type RecoveryReport = trash.RecoveryReport
pub type StoreStats = trash.StoreStats
pub type DoctorOptions = trash.DoctorOptions
pub type DoctorItem = trash.DoctorItem
pub type DoctorReport = trash.DoctorReport

const app_name = 'trash'
const app_version = trash.app_version

fn open(root string) !Store {
	return trash.open(root)
}

fn open_with(root string, opts StoreOptions) !Store {
	return trash.open_with(root, opts)
}

fn detect_kind(path string) EntryKind {
	return trash.detect_kind(path)
}

fn filter_entries(entries []Entry, filter ListFilter) []Entry {
	return trash.filter_entries(entries, filter)
}

fn find_in(entries []Entry, ref string) ![]Entry {
	return trash.find_in(entries, ref)
}

fn canonical_path(path string) string {
	return pathx.canonical_path(path)
}

fn canonical_target_path(path string) string {
	return pathx.canonical_target_path(path)
}

fn resolve_name_conflict(base string) string {
	return pathx.resolve_name_conflict(base)
}

fn is_path_within(path string, base string) bool {
	return pathx.is_path_within(path, base)
}
