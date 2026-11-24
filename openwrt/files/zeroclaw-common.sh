#!/bin/sh

zc_load_paths() {
    config_load zeroclaw
    config_get ZC_MOUNT main mountpoint '/mnt/mmcblk0p1'
    ZC_ROOT="$ZC_MOUNT/zeroclaw"
}

zc_check_storage() {
    case "$ZC_MOUNT" in
        /*) ;;
        *) echo "zeroclaw: mountpoint must be absolute" >&2; return 1 ;;
    esac
    case "$ZC_MOUNT" in
        /|*/../*|*/./*|*/..|*/.|*[[:space:]]*)
            echo "zeroclaw: invalid mountpoint" >&2
            return 1
            ;;
    esac
    zc_mount_info="$(awk -v path="$ZC_MOUNT" '
        $2 == path { print $3 " " $4; found = 1; exit }
        END { if (!found) exit 1 }
    ' "${1:-/proc/mounts}")" || {
        echo "zeroclaw: $ZC_MOUNT is not mounted; refusing to write to flash" >&2
        return 1
    }
    case "${zc_mount_info%% *}" in
        ext2|ext3|ext4|f2fs|btrfs|xfs) ;;
        *)
            echo "zeroclaw: use a Linux filesystem supporting permissions, such as ext4" >&2
            return 1
            ;;
    esac
    case ",${zc_mount_info#* }," in
        *,ro,*|*,noexec,*)
            echo "zeroclaw: storage must be writable and allow execution" >&2
            return 1
            ;;
    esac
}
