module trashcli

fn general_help() string {
	return 'trash ${app_version} - safe rm replacement with recovery\n\n' +
		'Usage:\n' +
		'  trash [OPTIONS] <path>...\n' +
		'  trash <command> [OPTIONS] [ARGS]\n\n' +
		'Commands:\n' +
		'  put       Move files to the trash (default when no command is given)\n' +
		'  list      List trashed items (direct children of cwd by default)\n' +
		'  restore   Restore trashed items (direct children of cwd by default)\n' +
		'  empty     Permanently delete trashed items (cwd by default)\n' +
		'  where     Show the trash location and item count\n' +
		'  doctor    Report or repair broken trash items\n' +
		'  help      Show help for a command\n' +
		'  version   Show program version\n\n' +
		'Global options:\n' +
		'  --store PATH       Use PATH as the trash store\n' +
		'  --verbose          Explain what is happening\n' +
		'  --no-color         Disable colours\n' +
		'  --no-sync          Disable fsync durability (unsafe)\n' +
		'  -h, --help         Show this help\n' +
		'  -V, --version      Show program version\n\n' +
		'Examples:\n' +
		'  trash report.txt\n' +
		'  trash -r build/\n' +
		'  trash list -r\n' +
		'  trash restore -i\n' +
		'  trash restore --all --limit 1\n' +
		'  trash empty --all --yes\n'
}

fn command_help(c Command) string {
	return match c {
		.put {
			'Usage: trash [put] [OPTIONS] <path>...\n\n' +
				'Moves files and directories to the trash.\n\n' +
				'Options:\n' +
				'  -r, --recursive   Required to trash a directory\n' +
				'  --preview         Show a preview and ask for confirmation\n' +
				'  -i, --interactive Confirm each file before trashing\n' +
				'  --dry-run         Show what would be trashed\n' +
				'  -y, --yes         Assume yes for prompts\n' +
				'  --store PATH      Use PATH as the trash store\n\n' +
				'Examples:\n' +
				'  trash report.txt\n' +
				'  trash -r build/\n' +
				'  trash --preview report.txt\n' +
				'  trash --dry-run report.txt\n'
		}
		.list {
			'Usage: trash list [OPTIONS]\n\n' +
				'Lists items trashed from the current directory. Use -r for the\n' +
				'whole subtree and --all for the whole trash.\n\n' +
				'Options:\n' +
				'  -r, --recursive   Include the current directory subtree\n' +
				'  --all             List the whole trash\n' +
				'  --json            Print machine-readable JSON\n' +
				'  --long, --full-id Show full ids, kinds and full timestamps\n' +
				'  --limit N         Show at most N items\n' +
				'  --sort MODE       date, size, path or kind\n' +
				'  --kind KIND       file, dir, symlink or other\n' +
				'  --grep PATTERN    Filter by original path substring\n' +
				'  --older-than AGE  e.g. 30d, 12h, 5m\n' +
				'  --store PATH      Use PATH as the trash store\n\n' +
				'Examples:\n' +
				'  trash list\n' +
				'  trash list -r\n' +
				'  trash list --all --json\n'
		}
		.restore {
			'Usage: trash restore [OPTIONS] [<id|prefix|path>...]\n\n' +
				'Restores the selected items. With no arguments, restores everything\n' +
				'trashed from the current directory; use --all for the whole trash.\n\n' +
				'Options:\n' +
				'  -r, --recursive   Include the current directory subtree\n' +
				'  --all             Use the whole trash\n' +
				'  --limit N         Restore at most N items\n' +
				'  --sort MODE       date, size, path or kind\n' +
				'  --kind KIND       file, dir, symlink or other\n' +
				'  --grep PATTERN    Filter by original path substring\n' +
				'  --older-than AGE  e.g. 30d, 12h, 5m\n' +
				'  -i, --interactive Interactively choose items\n' +
				'  --dry-run         Show what would be restored\n' +
				'  --json            Print machine-readable JSON\n' +
				'  -y, --yes         Skip the confirmation prompt\n' +
				'  --store PATH      Use PATH as the trash store\n\n' +
				'Examples:\n' +
				'  trash restore\n' +
				'  trash restore 01a203aa\n' +
				'  trash restore --all --limit 1\n' +
				'  trash restore -i\n' +
				'  trash restore ./report.txt\n'
		}
		.empty {
			'Usage: trash empty [OPTIONS] [<id|prefix|path>...]\n\n' +
				'Permanently deletes the selected items. With no arguments, deletes\n' +
				'items trashed from the current directory; use --all for the whole\n' +
				'trash. This cannot be undone.\n\n' +
				'Options:\n' +
				'  -r, --recursive   Include the current directory subtree\n' +
				'  --all             Use the whole trash\n' +
				'  --keep N          Never delete the N newest items\n' +
				'  --limit N         Delete at most N items\n' +
				'  --sort MODE       date, size, path or kind\n' +
				'  --kind KIND       file, dir, symlink or other\n' +
				'  --grep PATTERN    Filter by original path substring\n' +
				'  --older-than AGE  e.g. 30d, 12h, 5m\n' +
				'  -i, --interactive Interactively choose items\n' +
				'  --dry-run         Show what would be deleted\n' +
				'  --json            Print machine-readable JSON\n' +
				'  -y, --yes         Skip the confirmation prompt\n' +
				'  --wait            Wait for permanent deletion instead of deferring GC\n' +
				'  --store PATH      Use PATH as the trash store\n\n' +
				'Examples:\n' +
				'  trash empty\n' +
				'  trash empty --all --yes\n' +
				'  trash empty --older-than 30d --keep 5\n' +
				'  trash empty 01a203aa\n'
		}
		.where {
			'Usage: trash where [OPTIONS]\n\n' +
				'Shows the trash location and item count.\n\n' +
				'Options:\n' +
				'  --json            Print machine-readable JSON\n' +
				'  --store PATH      Use PATH as the trash store\n'
		}
		.doctor {
			'Usage: trash doctor [OPTIONS]\n\n' +
				'Reports broken trash items. With --repair it fixes id mismatches;\n' +
				'with --doctor-purge it removes broken items.\n\n' +
				'Options:\n' +
				'  --repair          Repair metadata where possible\n' +
				'  --doctor-purge    Permanently remove broken items\n' +
				'  --json            Print machine-readable JSON\n' +
				'  --store PATH      Use PATH as the trash store\n'
		}
		.help {
			'Usage: trash help [command]\n'
		}
		.version {
			'Usage: trash version\n'
		}
	}
}

fn print_help(cli Cli) {
	if cmd := cli.help_command {
		print(command_help(cmd))
	} else {
		print(general_help())
	}
}
