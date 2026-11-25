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

// classify_error turns an unclassified error from a public operation into a
// TrashError, so callers can always use `err is TrashError` and inspect the
// ErrorKind instead of parsing a message.
fn classify_error(err IError, op string, subject string) TrashError {
	if err is TrashError {
		return err
	}
	return context_error(.io, op, subject, err)
}

// batch_failure_error preserves the classification of a per-item failure when a
// batch API collapses to a single error.
fn batch_failure_error(failure BatchFailure) TrashError {
	return TrashError{
		kind: failure.kind
		msg:  failure.message
		op:   failure.op
		path: failure.subject
	}
}
