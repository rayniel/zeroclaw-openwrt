#!/bin/sh
set -eu
umask 077

if [ "$(id -u)" -ne 0 ] || [ "$#" -ne 1 ]; then
    echo "Usage (root): sh prepare-state-image.sh /mnt/mmcblk0p1" >&2
    exit 1
fi
BUNDLE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
. "$BUNDLE/openwrt/files/zeroclaw-common.sh"
ZC_MOUNT="$1"
ZC_STORAGE_MODE=image
zc_check_parent_storage
if [ -L "$ZC_ROOT" ]; then
    echo "zeroclaw: image directory must not be a symlink" >&2
    exit 1
fi
mkdir -p "$ZC_ROOT"
lock="$ZC_ROOT/.state-create-lock"
mkdir "$lock" || {
    echo "zeroclaw: cannot lock image creation; check for another installer or a stale lock" >&2
    exit 1
}
temporary="$ZC_ROOT/.state.ext4.new"
created=0
trap 'if [ "$created" -eq 1 ]; then rm -f "$temporary"; fi; rmdir "$lock"' 0
trap 'exit 1' HUP INT TERM
if [ ! -e "$ZC_IMAGE" ] && [ ! -L "$ZC_IMAGE" ]; then
    if ! command -v mkfs.ext4 >/dev/null 2>&1; then
        echo "zeroclaw: install e2fsprogs (mkfs.ext4) and loop/ext4 kernel support first" >&2
        exit 1
    fi
    available_kb="$(df -Pk "$ZC_MOUNT" | awk 'END { print $4 }')"
    if [ "$available_kb" -lt 278528 ]; then
        echo "zeroclaw: image creation needs 256 MiB plus a 16 MiB card reserve" >&2
        exit 1
    fi
    # Exclusive creation prevents formatting an existing image or block device.
    if [ -e "$temporary" ] || [ -L "$temporary" ]; then
        echo "zeroclaw: refusing to overwrite an existing temporary image" >&2
        exit 1
    fi
    (set -C; : > "$temporary") || {
        echo "zeroclaw: refusing to overwrite an existing temporary image" >&2
        exit 1
    }
    created=1
    if [ ! -f "$temporary" ] || [ -L "$temporary" ]; then
        echo "zeroclaw: refusing to format anything but the new regular image file" >&2
        exit 1
    fi
    dd if=/dev/zero of="$temporary" bs=1048576 count=256
    mkfs.ext4 -q -F -m 0 -L zeroclaw-state "$temporary"
    mv -n "$temporary" "$ZC_IMAGE"
    if [ -e "$temporary" ]; then
        echo "zeroclaw: state image appeared concurrently; it was not overwritten" >&2
        exit 1
    fi
    created=0
    echo "Created 256 MiB ext4 state image: $ZC_IMAGE"
fi
zc_mount_image
chmod 700 "$ZC_STATE"
zc_check_storage
