#!/bin/sh
set -eu
umask 077

if [ "$#" -lt 1 ]; then
    echo "Usage: sh run-test.sh /mnt/mmcblk0p1 [zeroclaw arguments...]" >&2
    exit 1
fi
if [ "$(id -u)" -ne 0 ]; then
    echo "zeroclaw-test: run as root on the router" >&2
    exit 1
fi
BUNDLE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
. "$BUNDLE/openwrt/files/zeroclaw-common.sh"
ZC_MOUNT="$1"
shift
zc_normalize_mount
mount_options="$(awk -v path="$ZC_MOUNT" '
    $2 == path { print $4; found = 1; exit }
    END { if (!found) exit 1 }
' /proc/mounts)" || {
    echo "zeroclaw-test: card is not mounted; refusing to write to flash" >&2
    exit 1
}
case ",$mount_options," in
    *,ro,*|*,noexec,*)
        echo "zeroclaw-test: card must be writable and allow execution" >&2
        exit 1
        ;;
esac
case "$BUNDLE/" in
    "$ZC_MOUNT"/*) ;;
    *) echo "zeroclaw-test: unpack the bundle on the mounted card first" >&2; exit 1 ;;
esac
echo "WARNING: TEST ONLY. FAT permissions are NOT checked; other users and PCs may read API keys. No service or UCI changes." >&2
echo "WARNING: encrypted-key creation may fail on bare FAT; use install.sh --fat-image for full setup." >&2
(cd "$BUNDLE" && sha256sum -c SHA256SUMS)
if [ ! -x "$BUNDLE/bin/zeroclaw" ]; then
    echo "zeroclaw-test: bundle binary is not executable" >&2
    exit 1
fi
TEST_ROOT="$ZC_MOUNT/zeroclaw-test"
export HOME="$TEST_ROOT/home"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_DATA_HOME="$HOME/.local/share"
export XDG_CACHE_HOME="$HOME/.cache"
mkdir -p "$HOME" "$TEST_ROOT/config"
cd "$TEST_ROOT"
[ "$#" -gt 0 ] || set -- --version
exec "$BUNDLE/bin/zeroclaw" --config-dir "$TEST_ROOT/config" "$@"
