#!/bin/sh
set -e
umask 077

if [ "$(id -u)" -ne 0 ] || [ ! -f /etc/openwrt_release ]; then
    echo "Run this installer as root on OpenWrt" >&2
    exit 1
fi
allow_fat=0
storage_mode=''
case "${1:-}" in
    --allow-fat) allow_fat=1; storage_mode=direct; shift ;;
    --fat-image) storage_mode=image; shift ;;
esac
if [ "$#" -gt 1 ]; then
    echo "Usage: sh install.sh [--fat-image | --allow-fat] [/mnt/mmcblk0p1]" >&2
    exit 1
fi
case "$(uname -m)" in
    armv7*) ;;
    *) echo "This bundle requires ARMv7" >&2; exit 1 ;;
esac
BUNDLE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
. "$BUNDLE/openwrt/files/zeroclaw-common.sh"
. /lib/functions.sh
ZC_MOUNT=/mnt/mmcblk0p1
ZC_ALLOW_FAT=0
ZC_STORAGE_MODE=direct
if [ -f /etc/config/zeroclaw ]; then
    zc_load_paths
fi
ZC_MOUNT="${1:-$ZC_MOUNT}"
[ "$allow_fat" -eq 0 ] || ZC_ALLOW_FAT=1
if [ -n "$storage_mode" ]; then
    ZC_STORAGE_MODE="$storage_mode"
    [ "$storage_mode" != image ] || ZC_ALLOW_FAT=0
fi
zc_check_parent_storage
if ! (cd "$BUNDLE" && sha256sum -c SHA256SUMS); then
    echo "Bundle checksum verification failed" >&2
    exit 1
fi
binary_kb="$(du -k "$BUNDLE/bin/zeroclaw" | awk '{ print $1 }')"
available_kb="$(df -Pk "$ZC_MOUNT" | awk 'END { print $4 }')"
image_kb=0
if [ "$ZC_STORAGE_MODE" = image ] && [ ! -e "$ZC_IMAGE" ]; then
    image_kb=262144
fi
if [ "$available_kb" -lt "$((binary_kb + image_kb + 16384))" ]; then
    echo "Not enough card space for the state image, atomic binary update and 16 MiB reserve" >&2
    exit 1
fi
if [ "$ZC_STORAGE_MODE" = image ]; then
    sh "$BUNDLE/prepare-state-image.sh" "$ZC_MOUNT"
fi
zc_check_storage
for directory in "$ZC_ROOT" "$ZC_ROOT/bin" "$ZC_STATE/config" "$ZC_STATE/home"; do
    if [ -L "$directory" ]; then
        echo "zeroclaw: refusing to install through a symlink: $directory" >&2
        exit 1
    fi
done
mkdir -p "$ZC_ROOT/bin" "$ZC_STATE/config" "$ZC_STATE/home"
if [ "$ZC_STORAGE_MODE" = image ]; then
    chmod 700 "$ZC_STATE/config" "$ZC_STATE/home"
fi
cp "$BUNDLE/bin/zeroclaw" "$ZC_ROOT/bin/zeroclaw.new"
if [ "$ZC_FAT" -eq 0 ]; then
    chmod 755 "$ZC_ROOT/bin/zeroclaw.new"
fi
if ! zc_check_binary "$ZC_ROOT/bin/zeroclaw.new" || ! "$ZC_ROOT/bin/zeroclaw.new" --version; then
    rm -f "$ZC_ROOT/bin/zeroclaw.new"
    echo "Binary could not run on this router; existing binary was not replaced" >&2
    exit 1
fi
if [ -x /etc/init.d/zeroclaw ]; then
    /etc/init.d/zeroclaw stop
fi
mv -f "$ZC_ROOT/bin/zeroclaw.new" "$ZC_ROOT/bin/zeroclaw"
mkdir -p /usr/libexec /usr/bin /etc/init.d /etc/config
cp "$BUNDLE/openwrt/files/zeroclaw-common.sh" /usr/libexec/zeroclaw-common.sh
cp "$BUNDLE/openwrt/files/zeroclaw" /usr/bin/zeroclaw
cp "$BUNDLE/openwrt/files/zeroclaw.init" /etc/init.d/zeroclaw
chmod 755 /usr/bin/zeroclaw /etc/init.d/zeroclaw
if [ ! -f /etc/config/zeroclaw ]; then
    cp "$BUNDLE/openwrt/files/zeroclaw.config" /etc/config/zeroclaw
fi
uci set zeroclaw.main.mountpoint="$ZC_MOUNT"
uci set zeroclaw.main.allow_fat="$ZC_ALLOW_FAT"
uci set zeroclaw.main.storage_mode="$ZC_STORAGE_MODE"
uci set zeroclaw.main.enabled='0'
uci commit zeroclaw
echo "Installed. Service remains stopped and disabled in UCI."
echo "Config and runtime data: $ZC_STATE"
echo "Next: zeroclaw quickstart"
echo "Then: uci set zeroclaw.main.enabled=1; uci commit zeroclaw"
echo "Then: /etc/init.d/zeroclaw enable; /etc/init.d/zeroclaw start"
