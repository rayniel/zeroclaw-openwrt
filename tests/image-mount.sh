#!/bin/sh
set -eu

if [ "$(id -u)" -ne 0 ] || [ "$#" -ne 1 ]; then
    echo "Usage (Linux root): sh tests/image-mount.sh /path/to/ARMv7/zeroclaw" >&2
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
qemu-arm -cpu cortex-a7 "$BIN" --config-dir "$STATE/config" config set composio.api_key "$token"
[ -s "$STATE/config/.secret_key" ]
[ "$(stat -c %a "$STATE/config/.secret_key")" = 600 ]
if grep -F "$token" "$STATE/config/config.toml"; then
    echo "FAIL: test API key was saved as plaintext" >&2
    exit 1
fi
umount "$STATE"
zc_check_storage
grep -Fx persisted "$STATE/persisted"
echo "Real FAT/ext4 loop mount and encrypted-key persistence checks passed"
