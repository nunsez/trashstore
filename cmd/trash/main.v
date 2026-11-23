module main

import trashcli
import os

fn main() {
	c := trashcli.Cli.parse(os.args) or {
		eprintln('trash: ${err.msg()}')
		exit(2)
	}
	trashcli.run(c) or {
		eprintln('trash: ${err.msg()}')
		exit(1)
	}
}
