module main

import os
import trashcli

fn main() {
	c := trashcli.Cli.parse(os.args) or {
		eprintln('trash: ${trashcli.sanitize_message(err.msg())}')
		exit(2)
	}
	trashcli.run(c) or {
		eprintln('trash: ${trashcli.sanitize_message(err.msg())}')
		exit(1)
	}
}
