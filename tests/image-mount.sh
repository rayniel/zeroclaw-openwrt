#!/bin/sh
set -eu

if [ "$(id -u)" -ne 0 ] || [ "$#" -ne 2 ]; then
    echo "Usage (Linux root): sh tests/image-mount.sh /path/to/ARMv7/zeroclaw /path/to/ARMv7/zerocode" >&2
    exit 1
fi
BIN="$1"
ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
CARD="$TEST_DIR/card"
STATE="$CARD/zeroclaw/state"
card_mounted=0
cleanup() {
    if [ "$card_mounted" -eq 1 ]; then
        if awk -v path="$STATE" '$2 == path { found = 1 } END { exit !found }' /proc/mounts; then
            umount "$STATE" || return 1
        fi
        umount "$CARD" || return 1
    fi
    rm -rf "$TEST_DIR"
}
trap cleanup 0
trap 'exit 1' HUP INT TERM

mkdir -p "$CARD"
truncate -s 512M "$TEST_DIR/card.fat"
mkfs.vfat -F 32 "$TEST_DIR/card.fat"
mount -t vfat -o loop,rw,exec,uid=0,gid=0,fmask=0000,dmask=0000 "$TEST_DIR/card.fat" "$CARD"
card_mounted=1
mkdir -p "$CARD/unpack/openwrt/files"
cp "$ROOT/scripts/prepare-state-image.sh" "$CARD/unpack/"
cp "$ROOT/openwrt/files/zeroclaw-common.sh" "$CARD/unpack/openwrt/files/"
sh "$CARD/unpack/prepare-state-image.sh" "$CARD/"
. "$ROOT/openwrt/files/zeroclaw-common.sh"
ZC_MOUNT="$CARD"
ZC_STORAGE_MODE=image
zc_check_storage
[ "$(stat -c %s "$ZC_IMAGE")" -eq 268435456 ]
printf '%s\n' persisted > "$STATE/persisted"
image_inode="$(stat -c %i "$ZC_IMAGE")"
sh "$CARD/unpack/prepare-state-image.sh" "$CARD"
[ "$(stat -c %i "$ZC_IMAGE")" = "$image_inode" ]
grep -Fx persisted "$STATE/persisted"

# Exercise the pinned ARM binary's actual encrypted-secret persistence on ext4.
token='image-smoke-test-not-a-real-api-key'
if qemu-arm -cpu cortex-a7 "$BIN" --config-dir "$CARD/raw-config" \
    config set --no-interactive composio.api_key "$token" > "$TEST_DIR/raw.log" 2>&1; then
    echo "FAIL: raw FAT unexpectedly supported atomic encrypted-key creation" >&2
    exit 1
fi
grep -Ei 'encrypt|publish|not supported|not permitted' "$TEST_DIR/raw.log"
qemu-arm -cpu cortex-a7 "$BIN" --config-dir "$STATE/config" \
    config set --no-interactive composio.api_key "$token"
[ -s "$STATE/config/.secret_key" ]
[ "$(stat -c %a "$STATE/config/.secret_key")" = 600 ]
if grep -F "$token" "$STATE/config/config.toml"; then
    echo "FAIL: test API key was saved as plaintext" >&2
    exit 1
fi
qemu-arm -cpu cortex-a7 "$BIN" --config-dir "$STATE/config" \
    config get --json composio.api_key | grep '"populated": true'

# Use the real property enumeration/workspace defaults without an interactive TTY.
qemu-arm -cpu cortex-a7 "$BIN" --config-dir "$STATE/config" config init agents.prompt_test
ZC_ROOT="$STATE/prompt-runner"
ZC_STATE="$STATE"
mkdir -p "$ZC_ROOT/bin"
PROMPT_TEST_BIN="$BIN"
export PROMPT_TEST_BIN
cat > "$ZC_ROOT/bin/zeroclaw" <<'EOF'
#!/bin/sh
exec qemu-arm -cpu cortex-a7 "$PROMPT_TEST_BIN" "$@"
EOF
chmod 755 "$ZC_ROOT/bin/zeroclaw"
. "$ROOT/openwrt/files/zeroclaw-prompt.sh"
zc_seed_openwrt_prompt prompt_test "$ROOT/openwrt/files/openwrt-prompt.txt"
cmp "$STATE/config/agents/prompt_test/workspace/AGENTS.md" "$ROOT/openwrt/files/openwrt-prompt.txt"
printf '%s\n' user-customized > "$STATE/config/agents/prompt_test/workspace/AGENTS.md"
zc_seed_openwrt_prompt prompt_test "$ROOT/openwrt/files/openwrt-prompt.txt"
grep -Fx user-customized "$STATE/config/agents/prompt_test/workspace/AGENTS.md"
echo "Real ARM configuration and OpenWrt prompt seeding checks passed"
python3 "$ROOT/tests/terminal-runtime.py" "$BIN" "$2" "$STATE"
umount "$STATE"
zc_check_storage
grep -Fx persisted "$STATE/persisted"
qemu-arm -cpu cortex-a7 "$BIN" --config-dir "$STATE/config" \
    config get --json composio.api_key | grep '"populated": true'
echo "Real FAT/ext4 loop mount and encrypted-key persistence checks passed"
