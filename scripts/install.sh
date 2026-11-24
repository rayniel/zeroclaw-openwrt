#!/bin/sh
set -eu
umask 077

if [ "$(id -u)" -ne 0 ] || [ ! -f /etc/openwrt_release ]; then
    echo "Run this installer as root on OpenWrt" >&2
    exit 1
fi
if [ "$#" -gt 1 ]; then
    echo "Usage: sh install.sh [/mnt/mmcblk0p1]" >&2
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
if [ -f /etc/config/zeroclaw ]; then
    zc_load_paths
fi
ZC_MOUNT="${1:-$ZC_MOUNT}"
ZC_ROOT="$ZC_MOUNT/zeroclaw"
zc_check_storage
if ! (cd "$BUNDLE" && sha256sum -c SHA256SUMS); then
    echo "Bundle checksum verification failed" >&2
    exit 1
fi
binary_kb="$(du -k "$BUNDLE/bin/zeroclaw" | awk '{ print $1 }')"
available_kb="$(df -Pk "$ZC_MOUNT" | awk 'END { print $4 }')"
if [ "$available_kb" -lt "$((binary_kb + 16384))" ]; then
    echo "Not enough card space for an atomic binary update and 16 MiB reserve" >&2
    exit 1
fi
mkdir -p "$ZC_ROOT/bin" "$ZC_ROOT/config" "$ZC_ROOT/home"
cp "$BUNDLE/bin/zeroclaw" "$ZC_ROOT/bin/zeroclaw.new"
chmod 755 "$ZC_ROOT/bin/zeroclaw.new"
if ! "$ZC_ROOT/bin/zeroclaw.new" --version; then
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
uci set zeroclaw.main.enabled='0'
uci commit zeroclaw
echo "Installed. Service remains stopped and disabled in UCI."
echo "Next: zeroclaw onboard"
echo "Then: uci set zeroclaw.main.enabled=1; uci commit zeroclaw"
echo "Then: /etc/init.d/zeroclaw enable; /etc/init.d/zeroclaw start"
