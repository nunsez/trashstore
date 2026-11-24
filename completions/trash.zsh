#compdef trash

_trash() {
    local -a commands
    commands=(
        'put:Move files to the trash'
        'list:List trashed items'
        'restore:Restore trashed items'
        'empty:Permanently delete trashed items'
        'where:Show where selected items are stored'
        'stats:Show trash location and size'
        'doctor:Report or repair broken items'
        'help:Show help'
        'version:Show version'
    )

    _arguments -C \
        '--store[use PATH as the trash store]:path:_files -/' \
        '--verbose[explain what is happening]' \
        '--no-color[disable colours]' \
        '--reset-store[wipe the store if the index schema is incompatible]' \
        '(-h --help)'{-h,--help}'[show help]' \
        '(-V --version)'{-V,--version}'[show version]' \
        '1:command:->command' \
        '*::arg:->args'

    case $state in
        command)
            _describe 'command' commands
            ;;
        args)
            case $words[1] in
                list)
                    _arguments '(-r --recursive)'{-r,--recursive}'[include subtree]' \
                        '--all[list whole trash]' '--json[JSON output]' '--long[long output]' '--full-id[full ids]' \
                        '--ids[print only full ids]' \
                        '--limit[limit results]:number:' \
                        '--sort[sort mode]:mode:(date size path kind)' \
                        '--kind[filter kind]:kind:(file dir symlink other)' \
                        '--grep[filter path]:pattern:' '--older-than[minimum age]:age:'
                    ;;
                restore)
                    _arguments '(-r --recursive)'{-r,--recursive}'[include subtree]' \
                        '--all[use whole trash]' '--limit[restore at most N]:number:' \
                        '--sort[sort mode]:mode:(date size path kind)' \
                        '--kind[filter kind]:kind:(file dir symlink other)' \
                        '--grep[filter path]:pattern:' '--older-than[minimum age]:age:' \
                        '(-i --interactive)'{-i,--interactive}'[choose items]' \
                        '--dry-run[show plan]' '--json[JSON output]' '-y[skip confirmation]' '--yes[skip confirmation]'
                    ;;
                empty)
                    _arguments '(-r --recursive)'{-r,--recursive}'[include subtree]' \
                        '--all[use whole trash]' '--keep[keep newest N]:number:' '--limit[delete at most N]:number:' \
                        '--sort[sort mode]:mode:(date size path kind)' \
                        '--kind[filter kind]:kind:(file dir symlink other)' \
                        '--grep[filter path]:pattern:' '--older-than[minimum age]:age:' \
                        '(-i --interactive)'{-i,--interactive}'[choose items]' \
                        '--dry-run[show plan]' '--json[JSON output]' '-y[skip confirmation]' '--yes[skip confirmation]' \
                        '--wait[wait for GC]'
                    ;;
                where)
                    _arguments '(-r --recursive)'{-r,--recursive}'[include target subtree]' \
                        '--kind[filter kind]:kind:(file dir symlink other)' \
                        '--grep[filter path]:pattern:' '--older-than[minimum age]:age:' \
                        '--json[JSON output]' '*:ref:'
                    ;;
                stats)
                    _arguments '--json[JSON output]'
                    ;;
                doctor)
                    _arguments '--repair[finish interrupted operations and measure sizes]' '--doctor-purge[remove broken items]' '--integrity-check[run integrity_check]' '--compact[VACUUM the index]' '--backup[write index.backup.db]' '--rebuild[rebuild rows from payloads]' '--reindex[rebuild index b-trees]' '--json[JSON output]'
                    ;;
                put|*)
                    _arguments '(-r --recursive)'{-r,--recursive}'[allow directories]' \
                        '--preview[preview and confirm]' \
                        '(-i --interactive)'{-i,--interactive}'[confirm each file]' \
                        '--dry-run[show plan]' '-y[assume yes]' '--yes[assume yes]' '*:file:_files'
                    ;;
            esac
            ;;
    esac
}

_trash "$@"
