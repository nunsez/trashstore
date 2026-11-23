_trash() {
    local cur prev words cword
    _init_completion || return

    local commands="put list restore purge empty where doctor help version"
    local global_opts="--graveyard --verbose --quiet --no-color --no-sync -h --help -V --version"

    if [[ $cword -eq 1 ]]; then
        COMPREPLY=( $(compgen -W "$commands $global_opts" -- "$cur") )
        return
    fi

    case "${words[1]}" in
        list)
            COMPREPLY=( $(compgen -W "--recursive --all --json --long --full-id --limit --sort --kind --grep --older-than $global_opts" -- "$cur") )
            ;;
        restore)
            COMPREPLY=( $(compgen -W "--from-cwd --all --select --dry-run --json --yes --wait --keep --older-than --grep --kind $global_opts" -- "$cur") )
            ;;
        purge)
            COMPREPLY=( $(compgen -W "--all --older-than --grep --kind --dry-run --json --yes --wait --keep --older-than --grep --kind $global_opts" -- "$cur") )
            ;;
        empty)
            COMPREPLY=( $(compgen -W "--dry-run --json --yes --wait --keep --older-than --grep --kind $global_opts" -- "$cur") )
            ;;
        where)
            COMPREPLY=( $(compgen -W "--json $global_opts" -- "$cur") )
            ;;
        doctor)
            COMPREPLY=( $(compgen -W "--repair --doctor-purge --json $global_opts" -- "$cur") )
            ;;
        put|*)
            COMPREPLY=( $(compgen -W "--recursive --inspect --dry-run --yes $global_opts" -- "$cur") )
            _filedir
            ;;
    esac
}
complete -F _trash trash
