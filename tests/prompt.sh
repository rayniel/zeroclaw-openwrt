#!/bin/sh
set -eu
ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT HUP INT TERM
ZC_ROOT="$TEST_DIR/card/zeroclaw"
ZC_STATE="$ZC_ROOT/state"
TEMPLATE="$ROOT/openwrt/files/openwrt-prompt.txt"
PROPERTIES="$TEST_DIR/properties"
QUICKSTART_FAIL=0
CUSTOM_WORKSPACE='<unset>'
AUTHORED_PROMPT=0
export ROOT TEST_DIR ZC_ROOT ZC_STATE TEMPLATE PROPERTIES QUICKSTART_FAIL CUSTOM_WORKSPACE AUTHORED_PROMPT
mkdir -p "$ZC_ROOT/bin" "$ZC_STATE/config"
cat > "$ZC_ROOT/bin/zeroclaw" <<'EOF'
#!/bin/sh
set -eu
[ "$1" = --config-dir ]
[ "$2" = "$ZC_STATE/config" ]
shift 2
case "$*" in
    'quickstart --help') echo quickstart-help ;;
    'config complete agents.') cat "$PROPERTIES" ;;
    config\ get\ agents.*.workspace.path) printf '%s\n' "$CUSTOM_WORKSPACE" ;;
    quickstart*)
        [ "$QUICKSTART_FAIL" -eq 0 ] || exit 7
        printf '%s\n' agents.ops.model_provider agents.ops.risk_profile >> "$PROPERTIES"
        if [ "$AUTHORED_PROMPT" -eq 1 ]; then
            mkdir -p "$ZC_STATE/config/agents/ops/workspace"
            echo user-authored > "$ZC_STATE/config/agents/ops/workspace/AGENTS.md"
        fi
        ;;
    *) echo "Unexpected command: $*" >&2; exit 1 ;;
esac
EOF
chmod 755 "$ZC_ROOT/bin/zeroclaw"
cat > "$TEST_DIR/runtime.sh" <<'EOF'
zc_load_paths() { :; }
zc_check_storage() { :; }
zc_check_binary() { :; }
EOF
sed -e 's|^\. /lib/functions.sh$|:|' \
    -e 's|^\. /usr/libexec/zeroclaw-common.sh$|. "$TEST_DIR/runtime.sh"|' \
    -e 's|\. /usr/libexec/zeroclaw-prompt.sh|. "$ROOT/openwrt/files/zeroclaw-prompt.sh"|' \
    -e 's|/usr/share/zeroclaw/openwrt-prompt.txt|"$TEMPLATE"|' \
    "$ROOT/openwrt/files/zeroclaw" > "$TEST_DIR/launcher"
printf '%s\n' agents.old.model_provider > "$PROPERTIES"
sh "$TEST_DIR/launcher" quickstart --help
[ ! -e "$ZC_STATE/config/agents" ]
touch "$ZC_STATE/config/config.toml"
QUICKSTART_FAIL=1
status=0
sh "$TEST_DIR/launcher" quickstart || status=$?
[ "$status" -eq 7 ]
[ ! -d "$ZC_STATE/config/agents" ]
QUICKSTART_FAIL=0
sh "$TEST_DIR/launcher" quickstart
TARGET="$ZC_STATE/config/agents/ops/workspace/AGENTS.md"
cmp "$TARGET" "$TEMPLATE"
[ ! -e "$ZC_STATE/config/agents/old/workspace/AGENTS.md" ]
echo customized > "$TARGET"
sh "$TEST_DIR/launcher" openwrt-prompt ops
grep -Fx customized "$TARGET"
if sh "$TEST_DIR/launcher" openwrt-prompt missing; then
    echo "FAIL: an unknown agent must not get a prompt" >&2
    exit 1
fi
[ ! -d "$ZC_STATE/config/agents/missing" ]
if sh "$TEST_DIR/launcher" openwrt-prompt '../escape'; then
    echo "FAIL: unsafe agent aliases must not form file paths" >&2
    exit 1
fi
if sh "$TEST_DIR/launcher" openwrt-prompt; then
    echo "FAIL: the agent alias is required" >&2
    exit 1
fi
rm "$TARGET"
CUSTOM_WORKSPACE="$TEST_DIR/custom-workspace"
sh "$TEST_DIR/launcher" openwrt-prompt ops
[ ! -e "$TARGET" ] && [ ! -e "$CUSTOM_WORKSPACE" ]
CUSTOM_WORKSPACE='<unset>'
AUTHORED_PROMPT=1
printf '%s\n' agents.old.model_provider > "$PROPERTIES"
sh "$TEST_DIR/launcher" quickstart
grep -Fx user-authored "$TARGET"
AUTHORED_PROMPT=0
rm "$TARGET"
TEMPLATE="$TEST_DIR/missing-template"
if sh "$TEST_DIR/launcher" openwrt-prompt ops; then
    echo "FAIL: a missing packaged prompt must be reported" >&2
    exit 1
fi
[ ! -e "$TARGET" ]
echo "OpenWrt prompt tests passed"
