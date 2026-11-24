module trash

import internal.errs

pub type ErrorKind = errs.ErrorKind
pub type TrashError = errs.TrashError

fn context_error(kind ErrorKind, op string, path string, err IError) TrashError {
	return errs.context_error(kind, op, path, err)
}

fn not_found_error(msg string) TrashError {
	return errs.not_found_error(msg)
}

fn ambiguous_error(msg string) TrashError {
	return errs.ambiguous_error(msg)
}

fn in_progress_error(msg string) TrashError {
	return errs.in_progress_error(msg)
}

fn invalid_target_error(msg string) TrashError {
	return errs.invalid_target_error(msg)
}

fn not_restorable_error(msg string) TrashError {
	return errs.not_restorable_error(msg)
}

fn permission_error(msg string) TrashError {
	return errs.permission_error(msg)
}

fn io_error(msg string) TrashError {
	return errs.io_error(msg)
}

fn schema_mismatch_error(msg string, path string) TrashError {
	return errs.schema_mismatch_error(msg, path)
}
