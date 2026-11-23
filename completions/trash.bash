_trash() {
    local cur prev words cword
    _init_completion || return

    local commands="put list restore empty where doctor help version"
    local global_opts="--store --verbose --no-color --no-sync -h --help -V --version"

    if [[ $cword -eq 1 ]]; then
        COMPREPLY=( $(compgen -W "$commands $global_opts" -- "$cur") )
        return
    fi

    case "${words[1]}" in
        list)
            COMPREPLY=( $(compgen -W "--recursive --all --json --long --full-id --limit --sort --kind --grep --older-than $global_opts" -- "$cur") )
            ;;
        restore)
            COMPREPLY=( $(compgen -W "--recursive --all --limit --sort --kind --grep --older-than --interactive --dry-run --json --yes $global_opts" -- "$cur") )
            ;;
        empty)
            COMPREPLY=( $(compgen -W "--recursive --all --keep --limit --sort --kind --grep --older-than --interactive --dry-run --json --yes --wait $global_opts" -- "$cur") )
            ;;
        where)
            COMPREPLY=( $(compgen -W "--json $global_opts" -- "$cur") )
            ;;
        doctor)
            COMPREPLY=( $(compgen -W "--repair --doctor-purge --json $global_opts" -- "$cur") )
            ;;
        put|*)
            COMPREPLY=( $(compgen -W "--recursive --preview --interactive --dry-run --yes $global_opts" -- "$cur") )
            _filedir
            ;;
    esac
}
complete -F _trash trash
