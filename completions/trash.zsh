#compdef trash

_trash() {
    local -a commands
    commands=(
        'put:Move files to the trash'
        'list:List trashed items'
        'restore:Restore trashed items'
        'purge:Permanently delete items'
        'empty:Permanently empty the trash'
        'where:Show trash location'
        'doctor:Report or repair broken items'
        'help:Show help'
        'version:Show version'
    )

    _arguments -C \
        '--graveyard[use PATH as the trash]:path:_files -/' \
        '--verbose[explain what is happening]' \
        '--quiet[suppress non-error output]' \
        '--no-color[disable colours]' '--no-sync[disable fsync durability]' \
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
                        '--limit[limit results]:number:' \
                        '--sort[sort mode]:mode:(date size path kind)' \
                        '--kind[filter kind]:kind:(file dir symlink other)' \
                        '--grep[filter path]:pattern:' '--older-than[minimum age]:age:'
                    ;;
                restore)
                    _arguments '--from-cwd[restore what list shows]' '--all[restore all matches]' '--select[interactively choose]' \
                        '--dry-run[show plan]' '--json[JSON output]' '-y[assume yes]' '--yes[assume yes]'
                    ;;
                purge)
                    _arguments '--all[purge all matches]' '--older-than[minimum age]:age:' '--grep[filter path]:pattern:' '--kind[filter kind]:kind:(file dir symlink other)' '--dry-run[show plan]' '--json[JSON output]' \
                        '-y[assume yes]' '--yes[assume yes]'
                    ;;
                empty)
                    _arguments '--dry-run[show plan]' '--json[JSON output]' '-y[assume yes]' '--yes[assume yes]' '--wait[wait for GC]' '--keep[keep newest N]:number:' '--older-than[minimum age]:age:' '--grep[filter path]:pattern:' '--kind[filter kind]:kind:(file dir symlink other)'
                    ;;
                where)
                    _arguments '--json[JSON output]'
                    ;;
                doctor)
                    _arguments '--repair[repair metadata]' '--doctor-purge[remove broken items]' '--json[JSON output]'
                    ;;
                put|*)
                    _arguments '(-r --recursive)'{-r,--recursive}'[allow directories]' \
                        '(-i --inspect)'{-i,--inspect}'[preview and confirm]' \
                        '--dry-run[show plan]' '-y[assume yes]' '--yes[assume yes]' '*:file:_files'
                    ;;
            esac
            ;;
    esac
}

_trash "$@"
