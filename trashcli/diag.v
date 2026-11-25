module trashcli

// warn_limit is how many warnings one invocation shows by default. A store with
// thousands of broken rows must not flood the terminal, but the count is still
// reported so the problem stays visible.
const warn_limit = 20

// Diagnostics collects the non-fatal warnings of one invocation and prints them
// to stderr when the run finishes. Warnings never change the exit code and are
// never printed instead of an error, so a failed command still fails loudly.
//
// --verbose lifts the cap and shows every warning, --quiet drops them all; the
// two flags are mutually exclusive. Warnings are buffered and written once at
// the end, so they never interleave with machine-readable output on stdout.
struct Diagnostics {
mut:
	palette Palette
	quiet   bool
	// limit is the maximum number of warnings to print; 0 means unlimited.
	limit  int
	lines  []string
	hidden int // warnings dropped after the limit was reached
}

fn new_diagnostics(cli Cli) Diagnostics {
	return Diagnostics{
		palette: cli.palette()
		quiet:   cli.quiet
		limit:   if cli.verbose { 0 } else { warn_limit }
	}
}

// warn records one warning, or drops it when warnings are suppressed or the cap
// has been reached. The message is sanitized here, at the single boundary where
// store-controlled text reaches the terminal: a crafted index row or `.gc`
// entry name must not be able to emit an escape sequence.
fn (mut d Diagnostics) warn(message string) {
	if d.quiet {
		return
	}
	if d.limit > 0 && d.lines.len >= d.limit {
		d.hidden++
		return
	}
	d.lines << sanitize_display(message)
}

// flush writes the collected warnings to stderr, followed by one summary line
// when the cap hid the rest.
fn (mut d Diagnostics) flush() {
	for line in d.lines {
		eprintln(d.palette.red('warning:') + ' ' + line)
	}
	d.lines = []
	if d.hidden > 0 {
		eprintln(d.palette.red('warning:') + ' ${d.hidden} more warning(s) suppressed; use --verbose to see them all')
		d.hidden = 0
	}
}
