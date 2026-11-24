#!/bin/sh
set -eu
ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
. "$ROOT/openwrt/files/zeroclaw-common.sh"
FIXTURE="$(mktemp)"
trap 'rm -f "$FIXTURE"' EXIT HUP INT TERM
ZC_MOUNT=/mnt/mmcblk0p1

expect_failure() {
    if zc_check_storage "$FIXTURE"; then
        echo "FAIL: $1" >&2
        exit 1
    fi
}

printf '%s\n' '/dev/mmcblk0p1 /mnt/mmcblk0p1 ext4 rw,relatime 0 0' > "$FIXTURE"
zc_check_storage "$FIXTURE"
printf '%s\n' '/dev/mmcblk0p1 /mnt/mmcblk0p10 ext4 rw 0 0' > "$FIXTURE"
expect_failure "a similarly named mount must not pass"
printf '%s\n' 'overlay / overlay rw 0 0' > "$FIXTURE"
expect_failure "an unmounted card must not fall through to flash"
printf '%s\n' 'tmpfs /mnt/mmcblk0p1 tmpfs rw 0 0' > "$FIXTURE"
expect_failure "RAM storage must not pass"
printf '%s\n' '/dev/mmcblk0p1 /mnt/mmcblk0p1 vfat rw 0 0' > "$FIXTURE"
expect_failure "FAT must not pass"
printf '%s\n' '/dev/mmcblk0p1 /mnt/mmcblk0p1 ext4 rw,noexec 0 0' > "$FIXTURE"
expect_failure "noexec must not pass"
printf '%s\n' '/dev/mmcblk0p1 /mnt/mmcblk0p1 ext4 ro,relatime 0 0' > "$FIXTURE"
expect_failure "read-only storage must not pass"
ZC_MOUNT=mnt/mmcblk0p1
expect_failure "relative paths must not pass"
ZC_MOUNT=/
expect_failure "the root filesystem must not pass"
echo "Storage guard tests passed"
