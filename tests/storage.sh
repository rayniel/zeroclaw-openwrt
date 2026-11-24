#!/bin/sh
set -eu
ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
. "$ROOT/openwrt/files/zeroclaw-common.sh"
TEST_DIR="$(mktemp -d)"
FIXTURE="$TEST_DIR/mounts"
trap 'rm -rf "$TEST_DIR"' EXIT HUP INT TERM
ZC_MOUNT=/mnt/mmcblk0p1

expect_failure() {
    if zc_check_storage "$FIXTURE"; then
        echo "FAIL: $1" >&2
        exit 1
    fi
}

printf '%s\n' '/dev/mmcblk0p1 /mnt/mmcblk0p1 ext4 rw,relatime 0 0' > "$FIXTURE"
zc_check_storage "$FIXTURE"
ZC_MOUNT=/mnt/mmcblk0p1///
zc_check_storage "$FIXTURE"
[ "$ZC_MOUNT" = /mnt/mmcblk0p1 ]
[ "$ZC_ROOT" = /mnt/mmcblk0p1/zeroclaw ]
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
for ZC_MOUNT in //// /mnt/../mmcblk0p1/ /mnt/./mmcblk0p1/ /mnt//mmcblk0p1 '/mnt/card space/' '/mnt/card\name' /mnt/mmcblk0p1/..; do
    expect_failure "unsafe paths must not pass: $ZC_MOUNT"
done

# Mount metadata is simulated so these tests do not require root or real FAT mounts.
TEST_ACCESS='0:0:700'
TEST_FILE_ACCESS='0:0:700'
stat() {
    if [ -f "$3" ]; then
        printf '%s\n' "$TEST_FILE_ACCESS"
    else
        printf '%s\n' "$TEST_ACCESS"
    fi
}
ZC_MOUNT="$TEST_DIR/card"
mkdir -p "$ZC_MOUNT/zeroclaw/bin"
for fs in vfat exfat; do
    ZC_ALLOW_FAT=0
    printf '/dev/mmcblk0p1 %s %s rw,uid=0,gid=0,umask=0077 0 0\n' "$ZC_MOUNT" "$fs" > "$FIXTURE"
    expect_failure "$fs requires opt-in even with safe permissions"
    ZC_ALLOW_FAT=1
    for opts in \
        rw,uid=0,gid=0,umask=0077 \
        rw,fmask=0077,dmask=0077 \
        rw,umask=077,dmask=0077 \
        rw,umask=0022,fmask=0077,dmask=0077 \
        rw,fmask=0077,dmask=0077,umask=0022; do
        printf '/dev/mmcblk0p1 %s %s %s 0 0\n' "$ZC_MOUNT" "$fs" "$opts" > "$FIXTURE"
        zc_check_storage "$FIXTURE"
        [ "$ZC_FAT" -eq 1 ]
    done
    for opts in \
        rw \
        rw,uid=1000,gid=0,umask=0077 \
        rw,uid=0,gid=1000,umask=0077 \
        rw,umask=0022 \
        rw,umask=0077,fmask=0022 \
        rw,umask=0077,dmask=0022 \
        rw,fmask=0022,umask=0077 \
        rw,dmask=0022,umask=0077 \
        rw,fmask=0077 \
        rw,dmask=0077 \
        rw,fmask=0177,dmask=0077 \
        rw,fmask=0077,dmask=0177 \
        rw,umask=0077,fmask=invalid \
        rw,umask=0077,dmask=0088 \
        rw,umask=0077,fmask= \
        rw,umask=0077,dmask= \
        rw,umask=0077,noexec \
        ro,umask=0077; do
        printf '/dev/mmcblk0p1 %s %s %s 0 0\n' "$ZC_MOUNT" "$fs" "$opts" > "$FIXTURE"
        expect_failure "$fs unsafe options must not pass: $opts"
    done
done
printf '/dev/mmcblk0p1 %s exfat rw,umask=0077 0 0\n' "$ZC_MOUNT" > "$FIXTURE"
for TEST_ACCESS in 1000:0:700 0:1000:700 0:0:755 0:0:600; do
    expect_failure "actual directory permissions override claimed mount options"
done
TEST_ACCESS='0:0:700'
zc_check_storage "$FIXTURE"
cat > "$ZC_ROOT/bin/zeroclaw" <<'EOF'
#!/bin/sh
if [ "${1:-}" = --version ]; then
    [ "${TEST_EXEC_FAIL:-0}" -eq 0 ] || exit 7
    echo "test binary version"
    exit 0
fi
printf '%s\n' "$HOME|$*" > "$TEST_RUN"
EOF
chmod 700 "$ZC_ROOT/bin/zeroclaw"
cp "$ZC_ROOT/bin/zeroclaw" "$ZC_ROOT/bin/zerocode"
zc_check_binary "$ZC_ROOT/bin/zeroclaw"
for TEST_FILE_ACCESS in 1000:0:700 0:0:755 0:0:600; do
    if zc_check_binary "$ZC_ROOT/bin/zeroclaw"; then
        echo "FAIL: actual binary permissions must be checked" >&2
        exit 1
    fi
done
TEST_FILE_ACCESS='0:0:700'
TEST_EXEC_FAIL=1
export TEST_EXEC_FAIL
if zc_check_binary "$ZC_ROOT/bin/zeroclaw"; then
    echo "FAIL: executable mode bits are not proof of actual execution" >&2
    exit 1
fi
if zc_check_binary "$ZC_ROOT/bin/missing"; then
    echo "FAIL: missing binary must not pass" >&2
    exit 1
fi
TEST_EXEC_FAIL=0
printf '/dev/mmcblk0p1 %s ext4 rw 0 0\n' "$ZC_MOUNT" > "$FIXTURE"
zc_check_storage "$FIXTURE"
[ "$ZC_FAT" -eq 0 ]

TEST_MOUNT="$ZC_MOUNT/"
TEST_ALLOW_FAT=1
TEST_ENABLED=1
TEST_RUN="$TEST_DIR/run"
TEST_STUB="$TEST_DIR/functions.sh"
export ROOT TEST_DIR FIXTURE TEST_MOUNT TEST_ALLOW_FAT TEST_ENABLED TEST_RUN TEST_STUB TEST_ACCESS TEST_FILE_ACCESS
cat > "$TEST_STUB" <<'EOF'
config_load() { :; }
config_get() {
    case "$1" in
        ZC_MOUNT) ZC_MOUNT="$TEST_MOUNT" ;;
        port) port=42617 ;;
    esac
}
config_get_bool() {
    case "$1" in
        ZC_ALLOW_FAT) ZC_ALLOW_FAT="$TEST_ALLOW_FAT" ;;
        enabled) enabled="$TEST_ENABLED" ;;
    esac
}
stat() {
    if [ -f "$3" ]; then
        printf '%s\n' "$TEST_FILE_ACCESS"
    else
        printf '%s\n' "$TEST_ACCESS"
    fi
}
logger() { printf '%s\n' "$*" >&2; }
procd_open_instance() { echo open >> "$TEST_RUN"; }
procd_set_param() { printf '%s\n' "$*" >> "$TEST_RUN"; }
procd_close_instance() { :; }
procd_add_reload_trigger() { :; }
procd_add_restart_mount_trigger() { printf '%s\n' "$1" > "$TEST_RUN"; }
EOF
sed -e 's|^\. /lib/functions.sh$|. "$TEST_STUB"|' \
    -e 's|^\. /usr/libexec/zeroclaw-common.sh$|. "$ROOT/openwrt/files/zeroclaw-common.sh"|' \
    -e 's|^zc_check_storage$|zc_check_storage "$FIXTURE"|' \
    "$ROOT/openwrt/files/zeroclaw" > "$TEST_DIR/launcher"
sed 's|exec /usr/bin/zeroclaw |exec sh "$TEST_DIR/launcher" |' \
    "$ROOT/openwrt/files/zerocode" > "$TEST_DIR/terminal"
sed -e 's|^\. /usr/libexec/zeroclaw-common.sh$|. "$TEST_STUB"; . "$ROOT/openwrt/files/zeroclaw-common.sh"|' \
    -e 's@    zc_check_storage || {@    zc_check_storage "$FIXTURE" || {@' \
    "$ROOT/openwrt/files/zeroclaw.init" > "$TEST_DIR/init"

expect_runtime_failure() {
    rm -f "$TEST_RUN"
    if sh "$TEST_DIR/launcher" agent; then
        echo "FAIL: launcher must reject $1" >&2
        exit 1
    fi
    if sh "$TEST_DIR/terminal" -a diagnostics; then
        echo "FAIL: terminal client must reject $1" >&2
        exit 1
    fi
    if sh -c '. "$1"; start_service' sh "$TEST_DIR/init"; then
        echo "FAIL: service must reject $1" >&2
        exit 1
    fi
    [ ! -e "$TEST_RUN" ]
    [ ! -d "$ZC_ROOT/home" ]
}

printf '/dev/mmcblk0p1 %s exfat rw,umask=0077 0 0\n' "$ZC_MOUNT" > "$FIXTURE"
TEST_ALLOW_FAT=0
expect_runtime_failure "FAT without UCI opt-in"
TEST_ALLOW_FAT=1
for opts in rw,umask=0077,noexec ro,umask=0077 rw,umask=0077,fmask=0022; do
    printf '/dev/mmcblk0p1 %s exfat %s 0 0\n' "$ZC_MOUNT" "$opts" > "$FIXTURE"
    expect_runtime_failure "$opts"
done
printf '%s\n' 'overlay / overlay rw 0 0' > "$FIXTURE"
expect_runtime_failure "an unmounted card"
printf '/dev/mmcblk0p1 %s exfat rw,umask=0077 0 0\n' "$ZC_MOUNT" > "$FIXTURE"
TEST_EXEC_FAIL=1
expect_runtime_failure "a binary that cannot execute"
TEST_EXEC_FAIL=0
TEST_ACCESS='0:0:755'
expect_runtime_failure "insecure actual access"
TEST_ACCESS='0:0:700'
TEST_ENABLED=0
sh -c '. "$1"; start_service' sh "$TEST_DIR/init"
[ ! -e "$TEST_RUN" ]
TEST_ENABLED=1
sh -c '. "$1"; start_service' sh "$TEST_DIR/init"
grep -Fx 'command /usr/bin/zeroclaw --verbose daemon --host 127.0.0.1 --port 42617' "$TEST_RUN"
sh "$TEST_DIR/launcher" agent
grep -Fx "$ZC_ROOT/home|--config-dir $ZC_ROOT/config agent" "$TEST_RUN"
for alias in diagnostics network-lab; do
    sh "$TEST_DIR/terminal" -a "$alias"
    grep -Fx "$ZC_ROOT/home|--config-dir $ZC_ROOT/config -a $alias" "$TEST_RUN"
done
mv "$ZC_ROOT/bin/zerocode" "$ZC_ROOT/bin/zerocode.saved"
rm "$TEST_RUN"
if sh "$TEST_DIR/terminal" -a diagnostics; then
    echo "FAIL: missing terminal binary must not start another agent" >&2
    exit 1
fi
[ ! -e "$TEST_RUN" ]
mv "$ZC_ROOT/bin/zerocode.saved" "$ZC_ROOT/bin/zerocode"
sh -c '. "$1"; service_triggers' sh "$TEST_DIR/init"
grep -Fx "$ZC_MOUNT" "$TEST_RUN"

TEST_SYSTEM="$TEST_DIR/system"
TEST_BUNDLE="$TEST_DIR/bundle"
TEST_CHMOD_FAIL=0
export TEST_SYSTEM TEST_CHMOD_FAIL
mkdir -p "$TEST_SYSTEM/etc" "$TEST_BUNDLE/openwrt/files" "$TEST_BUNDLE/bin"
touch "$TEST_SYSTEM/etc/openwrt_release"
cp "$ROOT/openwrt/files/"* "$TEST_BUNDLE/openwrt/files/"
cp "$ZC_ROOT/bin/zeroclaw" "$TEST_BUNDLE/bin/zeroclaw"
cp "$ZC_ROOT/bin/zerocode" "$TEST_BUNDLE/bin/zerocode"
cat >> "$TEST_STUB" <<'EOF'
id() { echo 0; }
uname() { echo armv7l; }
uci() { printf '%s\n' "$*" >> "$TEST_RUN"; }
chmod() {
    case "$*" in
        *zeroclaw.new)
            if [ "$TEST_CHMOD_FAIL" -eq 1 ]; then
                echo "test: binary chmod failed" >&2
                return 1
            fi
            echo binary-chmod >> "$TEST_RUN"
            ;;
    esac
    command chmod "$@"
}
EOF
sed -e 's|/etc/|$TEST_SYSTEM/etc/|g' \
    -e 's|/usr/|$TEST_SYSTEM/usr/|g' \
    -e 's|^\. /lib/functions.sh$|. "$TEST_STUB"|' \
    -e 's|^zc_check_parent_storage$|zc_check_parent_storage "$FIXTURE"|' \
    -e 's|^zc_check_storage$|zc_check_storage "$FIXTURE"|' \
    -e '2i\. "$TEST_STUB"' \
    "$ROOT/scripts/install.sh" > "$TEST_BUNDLE/install.sh"
(cd "$TEST_BUNDLE" && sha256sum bin/* openwrt/files/* > SHA256SUMS)
TEST_MOUNT="$TEST_DIR/install-card/"
ZC_MOUNT="${TEST_MOUNT%/}"
mkdir -p "$ZC_MOUNT"
printf '/dev/mmcblk0p1 %s vfat rw,umask=0077 0 0\n' "$ZC_MOUNT" > "$FIXTURE"
TEST_ALLOW_FAT=0
rm -f "$TEST_RUN"
if sh "$TEST_BUNDLE/install.sh" "$TEST_MOUNT"; then
    echo "FAIL: installer must require FAT opt-in" >&2
    exit 1
fi
[ ! -d "$ZC_MOUNT/zeroclaw" ]
[ ! -e "$TEST_RUN" ]
TEST_CHMOD_FAIL=1
sh "$TEST_BUNDLE/install.sh" --allow-fat "$TEST_MOUNT"
grep -Fx "set zeroclaw.main.mountpoint=$ZC_MOUNT" "$TEST_RUN"
grep -Fx 'set zeroclaw.main.allow_fat=1' "$TEST_RUN"
grep -Fx 'set zeroclaw.main.enabled=0' "$TEST_RUN"
[ -x "$TEST_SYSTEM/usr/bin/zerocode" ]
[ -x "$ZC_MOUNT/zeroclaw/bin/zerocode" ]
if grep -Fx binary-chmod "$TEST_RUN"; then
    echo "FAIL: FAT must not depend on per-file chmod" >&2
    exit 1
fi
printf '%s\n' 'existing binary' > "$ZC_MOUNT/zeroclaw/bin/zeroclaw"
printf '/dev/mmcblk0p1 %s ext4 rw 0 0\n' "$ZC_MOUNT" > "$FIXTURE"
rm -f "$TEST_RUN"
if sh "$TEST_BUNDLE/install.sh" "$TEST_MOUNT"; then
    echo "FAIL: Linux chmod errors must not be ignored" >&2
    exit 1
fi
grep -Fx 'existing binary' "$ZC_MOUNT/zeroclaw/bin/zeroclaw"
[ ! -e "$TEST_RUN" ]
printf '/dev/mmcblk0p1 %s exfat rw,umask=0077 0 0\n' "$ZC_MOUNT" > "$FIXTURE"
TEST_ALLOW_FAT=1
for failure in execution permissions; do
    TEST_EXEC_FAIL=0
    TEST_FILE_ACCESS='0:0:700'
    case "$failure" in
        execution) TEST_EXEC_FAIL=1 ;;
        permissions) TEST_FILE_ACCESS='0:0:755' ;;
    esac
    if sh "$TEST_BUNDLE/install.sh" "$TEST_MOUNT"; then
        echo "FAIL: FAT installer must reject unsafe binary $failure" >&2
        exit 1
    fi
    grep -Fx 'existing binary' "$ZC_MOUNT/zeroclaw/bin/zeroclaw"
    [ ! -e "$ZC_MOUNT/zeroclaw/bin/zeroclaw.new" ]
    [ ! -e "$TEST_RUN" ]
done
TEST_EXEC_FAIL=0
TEST_FILE_ACCESS='0:0:700'
printf '#!/bin/sh\nexit 9\n' > "$TEST_BUNDLE/bin/zerocode"
(cd "$TEST_BUNDLE" && sha256sum bin/* openwrt/files/* > SHA256SUMS)
if sh "$TEST_BUNDLE/install.sh" "$TEST_MOUNT"; then
    echo "FAIL: a broken terminal client must not replace either installed binary" >&2
    exit 1
fi
grep -Fx 'existing binary' "$ZC_MOUNT/zeroclaw/bin/zeroclaw"
[ ! -e "$ZC_MOUNT/zeroclaw/bin/zeroclaw.new" ]
[ ! -e "$ZC_MOUNT/zeroclaw/bin/zerocode.new" ]
echo "Storage guard tests passed"
