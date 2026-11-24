#!/bin/sh

zc_load_paths() {
    config_load zeroclaw
    config_get ZC_MOUNT main mountpoint '/mnt/mmcblk0p1'
    config_get_bool ZC_ALLOW_FAT main allow_fat 0
    config_get ZC_STORAGE_MODE main storage_mode 'direct'
    zc_set_paths
}

zc_set_paths() {
    zc_normalize_mount || return 1
    ZC_ROOT="$ZC_MOUNT/zeroclaw"
    case "${ZC_STORAGE_MODE:-direct}" in
        direct) ZC_STATE="$ZC_ROOT" ;;
        image) ZC_STATE="$ZC_ROOT/state" ;;
        *) echo "zeroclaw: invalid storage_mode (use direct or image)" >&2; return 1 ;;
    esac
    ZC_IMAGE="$ZC_ROOT/state.ext4"
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

zc_check_parent_storage() {
    zc_set_paths || return 1
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
            if [ "${ZC_STORAGE_MODE:-direct}" != image ] && [ "${ZC_ALLOW_FAT:-0}" != 1 ]; then
                echo "zeroclaw: FAT/exFAT requires --fat-image (recommended), or explicit --allow-fat; ext4 is recommended" >&2
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
    if [ "$ZC_FAT" -eq 1 ] && [ "${ZC_STORAGE_MODE:-direct}" != image ]; then
        zc_check_fat_options "${zc_mount_info#* }" || return 1
        zc_check_fat_access "$ZC_MOUNT" || return 1
        echo "zeroclaw: WARNING: FAT has no per-file Unix permissions/symlinks; keys are readable on a PC and some tools may fail. ext4 is recommended." >&2
    fi
}

zc_image_mount_info() {
    awk -v path="$ZC_STATE" '
        $2 == path { row = $1 " " $3 " " $4; found = 1 }
        END { if (found) print row; else exit 1 }
    ' "${1:-/proc/mounts}"
}

zc_verify_image_mount() {
    zc_image_info="$(zc_image_mount_info "${1:-/proc/mounts}")" || {
        echo "zeroclaw: state image is not mounted; refusing to write to flash/FAT" >&2
        return 1
    }
    zc_loop="${zc_image_info%% *}"
    zc_state_info="${zc_image_info#* }"
    case "$zc_loop" in
        /dev/loop[0-9]*) ;;
        *) echo "zeroclaw: state must be mounted from its loop image" >&2; return 1 ;;
    esac
    case "${zc_loop#/dev/loop}" in
        ''|*[!0-9]*) echo "zeroclaw: invalid loop device" >&2; return 1 ;;
    esac
    if [ "${zc_state_info%% *}" != ext4 ]; then
        echo "zeroclaw: state image must contain ext4" >&2
        return 1
    fi
    case ",${zc_state_info#* }," in
        *,ro,*|*,noexec,*)
            echo "zeroclaw: state image must be writable and allow execution" >&2
            return 1
            ;;
    esac
    case ",${zc_state_info#* }," in
        *,nosuid,*) ;;
        *) echo "zeroclaw: state image must be mounted nosuid" >&2; return 1 ;;
    esac
    case ",${zc_state_info#* }," in
        *,nodev,*) ;;
        *) echo "zeroclaw: state image must be mounted nodev" >&2; return 1 ;;
    esac
    zc_backing="$(cat "${2:-/sys/block}/${zc_loop##*/}/loop/backing_file")" || {
        echo "zeroclaw: cannot verify loop backing file" >&2
        return 1
    }
    if [ "$zc_backing" != "$ZC_IMAGE" ]; then
        echo "zeroclaw: loop backing file does not match $ZC_IMAGE" >&2
        return 1
    fi
}

zc_mount_image() (
    zc_check_parent_storage "${1:-/proc/mounts}" || exit 1
    if [ -L "$ZC_ROOT" ]; then
        echo "zeroclaw: image directory must not be a symlink" >&2
        exit 1
    fi
    if [ ! -f "$ZC_IMAGE" ] || [ -L "$ZC_IMAGE" ]; then
        echo "zeroclaw: missing regular state image; run install.sh --fat-image first" >&2
        exit 1
    fi
    if zc_image_mount_info "${1:-/proc/mounts}" >/dev/null; then
        zc_verify_image_mount "${1:-/proc/mounts}" "${2:-/sys/block}"
        exit $?
    fi
    zc_lock="$ZC_ROOT/.state-mount-lock"
    mkdir "$zc_lock" || {
        echo "zeroclaw: cannot lock image mount; another mount may be running (or remove a stale lock after checking)" >&2
        exit 1
    }
    trap 'rmdir "$zc_lock"' 0
    trap 'exit 1' HUP INT TERM
    if ! zc_image_mount_info "${1:-/proc/mounts}" >/dev/null; then
        if [ -L "$ZC_STATE" ]; then
            echo "zeroclaw: state mountpoint must not be a symlink" >&2
            exit 1
        fi
        mkdir -p "$ZC_STATE" || exit 1
        zc_contents="$(ls -A "$ZC_STATE")" || exit 1
        if [ -n "$zc_contents" ]; then
            echo "zeroclaw: refusing to hide files in the unmounted state directory" >&2
            exit 1
        fi
        mount -t ext4 -o loop,rw,nosuid,nodev "$ZC_IMAGE" "$ZC_STATE" || {
            echo "zeroclaw: cannot mount state image; check loop/ext4 support and filesystem health" >&2
            exit 1
        }
    fi
    zc_verify_image_mount "${1:-/proc/mounts}" "${2:-/sys/block}"
)

zc_check_storage() {
    zc_check_parent_storage "${1:-/proc/mounts}" || return 1
    if [ "${ZC_STORAGE_MODE:-direct}" = image ]; then
        zc_mount_image "${1:-/proc/mounts}" "${2:-/sys/block}" || return 1
        zc_state_access="$(stat -c '%u:%g:%a' "$ZC_STATE")" || {
            echo "zeroclaw: cannot inspect state image permissions" >&2
            return 1
        }
        if [ "$zc_state_access" != '0:0:700' ]; then
            echo "zeroclaw: state image root must be root-owned and mode 0700; run the installer" >&2
            return 1
        fi
        if [ "$ZC_FAT" -eq 1 ]; then
            echo "zeroclaw: WARNING: FAT-backed image and binary can be read/modified by anyone with access to the card; this is not encrypted storage." >&2
        fi
    fi
}

zc_check_binary() {
    if [ ! -x "$1" ]; then
        echo "zeroclaw: missing or non-executable binary: $1" >&2
        return 1
    fi
    if [ "${ZC_FAT:-0}" -eq 1 ]; then
        if [ "${ZC_STORAGE_MODE:-direct}" != image ]; then
            zc_check_fat_access "$1" || return 1
        fi
        if ! "$1" --version >/dev/null; then
            echo "zeroclaw: FAT binary execution check failed: $1" >&2
            return 1
        fi
    fi
}

zc_available_kb() {
    zc_df="$(df -Pk "$1")" || {
        echo "zeroclaw: cannot read card free space" >&2
        return 1
    }
    printf '%s\n' "$zc_df" | awk '
        END { if (NR < 2 || $4 !~ /^[0-9]+$/) exit 1; print $4 }
    ' || {
        echo "zeroclaw: invalid card free-space report" >&2
        return 1
    }
}
