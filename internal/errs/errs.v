module errs

// ErrorKind classifies failures so library users can react without parsing
// human-readable messages.
pub enum ErrorKind {
	not_found
	ambiguous
	in_progress
	invalid_target
	not_restorable
	io
	permission
	conflict
	not_empty
	unsupported
	unsupported_fs
}

// TrashError is the typed error returned by public Store operations.
pub struct TrashError {
pub:
	kind       ErrorKind
	msg        string
	op         string
	path       string
	error_code int
	cause      IError = none
}

// msg returns the human-readable error message.
pub fn (e TrashError) msg() string {
	return e.msg
}

// code returns the ErrorKind as an integer for CLI exit-code mapping.
pub fn (e TrashError) code() int {
	return int(e.kind)
}

// trash_error constructs a typed error with a message.
pub fn trash_error(kind ErrorKind, msg string) TrashError {
	return TrashError{
		kind: kind
		msg:  msg
	}
}

// context_error wraps an operation and path around an underlying error.
pub fn context_error(kind ErrorKind, op string, path string, err IError) TrashError {
	return TrashError{
		kind:       kind
		msg:        '${op} `${path}`: ${err.msg()}'
		op:         op
		path:       path
		error_code: err.code()
		cause:      err
	}
}

// not_found_error reports a missing item or path.
pub fn not_found_error(msg string) TrashError {
	return trash_error(.not_found, msg)
}

// ambiguous_error reports an ambiguous id prefix.
pub fn ambiguous_error(msg string) TrashError {
	return trash_error(.ambiguous, msg)
}

// in_progress_error reports a conflicting in-flight operation.
pub fn in_progress_error(msg string) TrashError {
	return trash_error(.in_progress, msg)
}

// invalid_target_error reports an unsafe target.
pub fn invalid_target_error(msg string) TrashError {
	return trash_error(.invalid_target, msg)
}

// not_restorable_error reports an item that cannot be restored.
pub fn not_restorable_error(msg string) TrashError {
	return trash_error(.not_restorable, msg)
}

// permission_error reports an ownership or permission problem.
pub fn permission_error(msg string) TrashError {
	return trash_error(.permission, msg)
}

// io_error reports a filesystem failure.
pub fn io_error(msg string) TrashError {
	return trash_error(.io, msg)
}

// unsupported_error reports an unsupported operation.
pub fn unsupported_error(msg string) TrashError {
	return trash_error(.unsupported, msg)
}
