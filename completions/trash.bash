_trash() {
    local cur prev words cword
    _init_completion || return

    local commands="put list restore empty where stats doctor help version"
    local global_opts="--store --verbose --quiet --no-color --reset-store -h --help -V --version"

    # The command is the first non-flag word, not necessarily words[1]:
    # `trash --store x list` must complete `list`'s flags.
    if [[ "${words[cword-1]}" == "--store" || "$cur" == --store=* ]]; then
        _filedir -d
        return
    fi
    local command="" i
    for (( i = 1; i < cword; i++ )); do
        case "${words[i]}" in
            --store) (( i++ )) ;;
            --store=*|-*) ;;
            *) command="${words[i]}"; break ;;
        esac
    done

    if [[ -z "$command" ]]; then
        COMPREPLY=( $(compgen -W "$commands $global_opts" -- "$cur") )
        return
    fi

    case "$command" in
        list)
            COMPREPLY=( $(compgen -W "--recursive --all --json --long --full-id --ids --limit --sort --kind --grep --older-than --no-size $global_opts" -- "$cur") )
            ;;
        restore)
            COMPREPLY=( $(compgen -W "--recursive --all --limit --sort --kind --grep --older-than --interactive --json --yes $global_opts" -- "$cur") )
            ;;
        empty)
            COMPREPLY=( $(compgen -W "--recursive --all --keep --limit --sort --kind --grep --older-than --interactive --json --yes --wait --include-broken $global_opts" -- "$cur") )
            ;;
        where)
            COMPREPLY=( $(compgen -W "--recursive --kind --grep --older-than --json $global_opts" -- "$cur") )
            ;;
        stats)
            COMPREPLY=( $(compgen -W "--json $global_opts" -- "$cur") )
            ;;
        doctor)
            COMPREPLY=( $(compgen -W "--repair --doctor-purge --integrity-check --compact --backup --rebuild --reindex --json $global_opts" -- "$cur") )
            ;;
        put|*)
            COMPREPLY=( $(compgen -W "--recursive --preview --interactive --force --yes $global_opts" -- "$cur") )
            _filedir
            ;;
    esac
}
complete -F _trash trash
