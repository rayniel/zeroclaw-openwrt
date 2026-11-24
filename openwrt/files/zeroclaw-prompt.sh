#!/bin/sh

zc_prompt_agent_paths() {
    zc_prompt_paths="$("$ZC_ROOT/bin/zeroclaw" --config-dir "$ZC_STATE/config" config complete agents.)" || {
        echo "zeroclaw: cannot enumerate agents for the OpenWrt prompt" >&2
        return 1
    }
    printf '%s\n' "$zc_prompt_paths" | awk '/^agents\.[^.]+\.model_provider$/'
}

zc_seed_openwrt_prompt() (
    zc_alias="$1"
    case "$zc_alias" in
        ''|*[!a-zA-Z0-9_-]*)
            echo "zeroclaw: OpenWrt prompt requires a simple agent alias (letters, digits, _ or -)" >&2
            exit 1
            ;;
    esac
    zc_known="$(zc_prompt_agent_paths)" || exit 1
    if ! printf '%s\n' "$zc_known" | grep -Fx "agents.$zc_alias.model_provider" >/dev/null; then
        echo "zeroclaw: unknown agent: $zc_alias" >&2
        exit 1
    fi
    zc_workspace="$("$ZC_ROOT/bin/zeroclaw" --config-dir "$ZC_STATE/config" \
        config get "agents.$zc_alias.workspace.path")" || exit 1
    case "$zc_workspace" in
        ''|'<unset>') zc_workspace="$ZC_STATE/config/agents/$zc_alias/workspace" ;;
        *)
            echo "zeroclaw: custom workspace for $zc_alias; apply the packaged OpenWrt prompt manually if wanted" >&2
            exit 0
            ;;
    esac
    for zc_directory in "$ZC_STATE/config/agents" "$ZC_STATE/config/agents/$zc_alias" "$zc_workspace"; do
        if [ -L "$zc_directory" ]; then
            echo "zeroclaw: refusing to seed a prompt through a symlink: $zc_directory" >&2
            exit 1
        fi
    done
    zc_target="$zc_workspace/AGENTS.md"
    if [ -e "$zc_target" ] || [ -L "$zc_target" ]; then
        echo "zeroclaw: keeping existing AGENTS.md for $zc_alias" >&2
        exit 0
    fi
    if [ ! -s "$2" ]; then
        echo "zeroclaw: packaged OpenWrt prompt is missing or empty: $2" >&2
        exit 1
    fi
    mkdir -p "$zc_workspace" || exit 1
    (set -C; cat "$2" > "$zc_target") || {
        echo "zeroclaw: could not create OpenWrt AGENTS.md for $zc_alias" >&2
        exit 1
    }
    echo "zeroclaw: installed OpenWrt prompt for $zc_alias: $zc_target" >&2
)

zc_prompt_after_quickstart() {
    zc_after="$(zc_prompt_agent_paths)" || return 1
    printf '%s\n' "$zc_after" | while IFS= read -r zc_property; do
        [ -n "$zc_property" ] || continue
        if printf '%s\n' "$1" | grep -Fx "$zc_property" >/dev/null; then
            continue
        fi
        zc_new_alias="${zc_property#agents.}"
        zc_new_alias="${zc_new_alias%.model_provider}"
        zc_seed_openwrt_prompt "$zc_new_alias" "$2" || return 1
    done
}
