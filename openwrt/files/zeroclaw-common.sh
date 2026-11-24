#!/bin/sh

zc_load_paths() {
    config_load zeroclaw
    config_get ZC_MOUNT main mountpoint '/mnt/mmcblk0p1'
    config_get_bool ZC_ALLOW_FAT main allow_fat 0
    zc_normalize_mount || return 1
    ZC_ROOT="$ZC_MOUNT/zeroclaw"
}

zc_normalize_mount() {
    while [ "${ZC_MOUNT%/}" != "$ZC_MOUNT" ]; do
        ZC_MOUNT="${ZC_MOUNT%/}"
    done
    case "$ZC_MOUNT" in
        /*) ;;
        *) echo "zeroclaw: mountpoint must be absolute and not root" >&2; return 1 ;;
    esac
    case "$ZC_MOUNT" in
        *//*|*/../*|*/./*|*/..|*/.|*\\*|*[[:space:]]*)
            echo "zeroclaw: invalid mountpoint" >&2
            return 1
            ;;
    esac
}

zc_check_fat_options() {
    # fmask/dmask override umask independently, regardless of option order.
    printf '%s\n' "$1" | awk -F, '
        function mask(s,    i, n) {
            if (s !~ /^[0-7]+$/ || length(s) > 4) return -1
            n = 0
            for (i = 1; i <= length(s); i++) n = n * 8 + substr(s, i, 1)
            return n
        }
        {
            u = -1
            f = d = -2
            uid = gid = "0"
            for (i = 1; i <= NF; i++) {
                split($i, a, "=")
                if (a[1] == "uid") uid = a[2]
                if (a[1] == "gid") gid = a[2]
                if (a[1] == "umask") u = mask(a[2])
                if (a[1] == "fmask") f = mask(a[2])
                if (a[1] == "dmask") d = mask(a[2])
            }
            if (f == -2) f = u
            if (d == -2) d = u
            exit !(uid == "0" && gid == "0" && f == 63 && d == 63)
        }
    ' || {
        echo "zeroclaw: FAT requires uid=0,gid=0 and effective fmask=0077,dmask=0077 (or umask=0077)" >&2
        return 1
    }
}

zc_check_fat_access() {
    zc_access="$(stat -c '%u:%g:%a' "$1")" || {
        echo "zeroclaw: cannot inspect FAT permissions: $1" >&2
        return 1
    }
    if [ "$zc_access" != '0:0:700' ]; then
        echo "zeroclaw: FAT must actually provide root-owned, root-only rwx access: $1 ($zc_access)" >&2
        return 1
    fi
}

zc_check_storage() {
    zc_normalize_mount || return 1
    ZC_ROOT="$ZC_MOUNT/zeroclaw"
    ZC_FAT=0
    zc_mount_info="$(awk -v path="$ZC_MOUNT" '
        $2 == path { print $3 " " $4; found = 1; exit }
        END { if (!found) exit 1 }
    ' "${1:-/proc/mounts}")" || {
        echo "zeroclaw: $ZC_MOUNT is not mounted; refusing to write to flash" >&2
        return 1
    }
    case "${zc_mount_info%% *}" in
        ext2|ext3|ext4|f2fs|btrfs|xfs) ;;
        vfat|exfat)
            if [ "${ZC_ALLOW_FAT:-0}" != 1 ]; then
                echo "zeroclaw: FAT/exFAT requires explicit --allow-fat or UCI allow_fat=1; ext4 is recommended" >&2
                return 1
            fi
            ZC_FAT=1
            ;;
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
    if [ "$ZC_FAT" -eq 1 ]; then
        zc_check_fat_options "${zc_mount_info#* }" || return 1
        zc_check_fat_access "$ZC_MOUNT" || return 1
        echo "zeroclaw: WARNING: FAT has no per-file Unix permissions/symlinks; keys are readable on a PC and some tools may fail. ext4 is recommended." >&2
    fi
}

zc_check_binary() {
    if [ ! -x "$1" ]; then
        echo "zeroclaw: missing or non-executable binary: $1" >&2
        return 1
    fi
    if [ "${ZC_FAT:-0}" -eq 1 ]; then
        zc_check_fat_access "$1" || return 1
        if ! "$1" --version >/dev/null; then
            echo "zeroclaw: FAT binary execution check failed: $1" >&2
            return 1
        fi
    fi
}
