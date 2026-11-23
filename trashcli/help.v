module trashcli

fn general_help() string {
	return 'trash ${app_version} - safe rm replacement with recovery\n\n' +
		'Usage:\n' +
		'  trash [OPTIONS] <path>...\n' +
		'  trash <command> [OPTIONS] [ARGS]\n\n' +
		'Commands:\n' +
		'  put       Move files to the trash (default when no command is given)\n' +
		'  list      List trashed items (direct children of cwd by default)\n' +
		'  restore   Restore the last item, a path, or an id/prefix\n' +
		'  purge     Permanently delete matching items\n' +
		'  empty     Permanently empty the whole trash\n' +
		'  where     Show the trash location and item count\n' +
		'  doctor    Report or repair broken trash items\n' +
		'  help      Show help for a command\n' +
		'  version   Show program version\n\n' +
		'Global options:\n' +
		'  --graveyard PATH   Store files in PATH\n' +
		'  --verbose          Explain what is happening\n' +
		'  --quiet            Suppress non-error output\n' +
		'  --no-color         Disable colours\n' +
		'  --no-sync          Disable fsync durability (unsafe)\n' +
		'  -h, --help         Show this help\n' +
		'  -V, --version      Show program version\n\n' +
		'Examples:\n' +
		'  trash report.txt\n' +
		'  trash -r build/\n' +
		'  trash list -r\n' +
		'  trash restore --from-cwd\n' +
		'  trash purge --all ./report.txt\n' +
		'  trash empty --yes\n'
}

fn command_help(c Command) string {
	return match c {
		.put {
			'Usage: trash [put] [OPTIONS] <path>...\n\n' +
				'Moves files and directories to the trash.\n\n' +
				'Options:\n' +
				'  -r, --recursive   Required to trash a directory\n' +
				'  -i, --inspect     Show a preview and ask for confirmation\n' +
				'  --dry-run         Show what would be trashed\n' +
				'  -y, --yes         Assume yes for -i prompts\n' +
				'  --graveyard PATH  Store files in PATH\n\n' +
				'Examples:\n' +
				'  trash report.txt\n' +
				'  trash -r build/\n' +
				'  trash --dry-run report.txt\n'
		}
		.list {
			'Usage: trash list [OPTIONS]\n\n' +
				'Lists items deleted from the current directory. Use -r for the\n' +
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
				'  --graveyard PATH  Use PATH as the trash\n\n' +
				'Examples:\n' +
				'  trash list\n' +
				'  trash list -r\n' +
				'  trash list --all --json\n'
		}
		.restore {
			'Usage: trash restore [OPTIONS] [<id|prefix|path>...]\n\n' +
				'Restores the newest item when no argument is given. Paths restore\n' +
				'the newest matching item; --all restores every match.\n\n' +
				'Options:\n' +
				'  --from-cwd        Restore exactly what `trash list` shows\n' +
				'  --all             Restore every match for each path\n' +
				'  --select          Interactively choose one item\n' +
				'  --dry-run         Show what would be restored\n' +
				'  --json            Print machine-readable JSON\n' +
				'  -y, --yes         Assume yes for prompts\n' +
				'  --graveyard PATH  Use PATH as the trash\n\n' +
				'Examples:\n' +
				'  trash restore\n' +
				'  trash restore 01a203aa\n' +
				'  trash restore --from-cwd\n' +
				'  trash restore --all ./report.txt\n'
		}
		.purge {
			'Usage: trash purge [OPTIONS] [<id|prefix|path>...]\n\n' +
				'Permanently deletes matching items. This cannot be undone.\n\n' +
				'Options:\n' +
				'  --all             Purge every match for each path\n' +
				'  --older-than AGE  Purge items older than e.g. 30d\n' +
				'  --grep PATTERN    Purge items whose path matches\n' +
				'  --kind KIND       Purge only file/dir/symlink/other\n' +
				'  --dry-run         Show what would be purged\n' +
				'  --json            Print machine-readable JSON\n' +
				'  -y, --yes         Do not ask before a multi-item purge\n' +
				'  --graveyard PATH  Use PATH as the trash\n\n' +
				'Examples:\n' +
				'  trash purge 01a203aa\n' +
				'  trash purge --all ./report.txt\n'
		}
		.empty {
			'Usage: trash empty [OPTIONS]\n\n' +
				'Permanently deletes everything in the trash, or only items selected by\nretention filters.\n\n' +
				'Options:\n' +
				'  --dry-run         Show how many items would be deleted\n' +
				'  --json            Print machine-readable JSON\n' +
				'  -y, --yes         Do not ask for confirmation\n' +
				'  --wait            Wait for permanent deletion instead of deferring GC\n' +
				'  --older-than AGE  Purge items older than e.g. 30d\n' +
				'  --keep N          Keep the newest N items\n' +
				'  --grep PATTERN    Purge items whose path matches\n' +
				'  --kind KIND       Purge only file/dir/symlink/other\n' +
				'  --graveyard PATH  Use PATH as the trash\n'
		}
		.where {
			'Usage: trash where [OPTIONS]\n\n' +
				'Shows the trash location and item count.\n\n' +
				'Options:\n' +
				'  --json            Print machine-readable JSON\n' +
				'  --graveyard PATH  Use PATH as the trash\n'
		}
		.doctor {
			'Usage: trash doctor [OPTIONS]\n\n' +
				'Reports broken trash items. With --repair it fixes id mismatches;\n' +
				'with --doctor-purge (or --purge) it removes broken items.\n\n' +
				'Options:\n' +
				'  --repair          Repair metadata where possible\n' +
				'  --doctor-purge    Permanently remove broken items\n' +
				'  --json            Print machine-readable JSON\n' +
				'  --graveyard PATH  Use PATH as the trash\n'
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
