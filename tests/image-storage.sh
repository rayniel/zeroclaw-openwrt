#!/bin/sh
set -eu
ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT HUP INT TERM
FIXTURE="$TEST_DIR/mounts"
SYSFS="$TEST_DIR/sys"
STUB="$TEST_DIR/functions.sh"
RECORD="$TEST_DIR/record"
SYSTEM="$TEST_DIR/system"
TEST_MOUNT="$TEST_DIR/card"
STATE_ACCESS='0:0:700'
AVAILABLE=1048576
MOUNT_FAIL=0
FORMAT_FAIL=0
export ROOT FIXTURE SYSFS STUB RECORD SYSTEM TEST_MOUNT STATE_ACCESS AVAILABLE MOUNT_FAIL FORMAT_FAIL
mkdir -p "$TEST_MOUNT" "$SYSFS/loop0/loop" "$SYSTEM/etc" "$TEST_DIR/bin"
PATH="$TEST_DIR/bin:$PATH"
export PATH
cat > "$TEST_DIR/bin/mkfs.ext4" <<'EOF'
#!/bin/sh
set -eu
for target in "$@"; do :; done
[ "$target" = "$TEST_MOUNT/zeroclaw/.state.ext4.new" ]
[ -f "$target" ] && [ ! -L "$target" ]
printf 'format %s\n' "$target" >> "$RECORD"
[ "$FORMAT_FAIL" -eq 0 ] || exit 1
echo ext4 >> "$target"
EOF
chmod 755 "$TEST_DIR/bin/mkfs.ext4"
cat > "$STUB" <<'EOF'
config_load() { :; }
config_get() {
    case "$1" in
        ZC_MOUNT) ZC_MOUNT="$TEST_MOUNT/" ;;
        ZC_STORAGE_MODE) ZC_STORAGE_MODE=image ;;
        port) port=42617 ;;
    esac
}
config_get_bool() {
    case "$1" in
        ZC_ALLOW_FAT) ZC_ALLOW_FAT=0 ;;
        enabled) enabled=1 ;;
    esac
}
id() { echo 0; }
uname() { echo armv7l; }
stat() {
    if [ "$2" = '%u:%g:%a' ]; then
        printf '%s\n' "$STATE_ACCESS"
    else
        command stat "$@"
    fi
}
df() { printf 'Filesystem 1024-blocks Used Available Capacity Mounted\n/dev/card 2097152 0 %s 0%% %s\n' "$AVAILABLE" "$TEST_MOUNT"; }
mount() {
    echo mount >> "$RECORD"
    [ "$MOUNT_FAIL" -eq 0 ] || return 1
    printf '/dev/loop0 %s ext4 rw,nosuid,nodev 0 0\n' "$ZC_STATE" >> "$FIXTURE"
}
dd() {
    printf '%s\n' "dd $*" >> "$RECORD"
    printf '%s\n' new-image > "$ZC_ROOT/.state.ext4.new"
}
uci() { printf '%s\n' "$*" >> "$RECORD"; }
logger() { printf '%s\n' "$*" >&2; }
procd_open_instance() { echo procd >> "$RECORD"; }
procd_set_param() { printf '%s\n' "$*" >> "$RECORD"; }
procd_close_instance() { :; }
EOF
# shellcheck source=/dev/null
. "$STUB"
. "$ROOT/openwrt/files/zeroclaw-common.sh"
ZC_MOUNT="$TEST_MOUNT/"
ZC_STORAGE_MODE=image
zc_set_paths
printf '%s\n' "$ZC_IMAGE" > "$SYSFS/loop0/loop/backing_file"
parent() {
    printf '/dev/card %s vfat %s 0 0\n' "$TEST_MOUNT" "${1:-rw,fmask=0000,dmask=0000}" > "$FIXTURE"
}
reject() {
    if zc_check_storage "$FIXTURE" "$SYSFS"; then
        echo "FAIL: image storage must reject $1" >&2
        exit 1
    fi
}
parent
reject "a missing image"
[ ! -d "$ZC_ROOT" ]
mkdir -p "$ZC_ROOT"
: > "$ZC_IMAGE"
printf '%s\n' 'overlay / overlay rw 0 0' > "$FIXTURE"
reject "a missing card even when the image file exists"
for options in ro rw,noexec; do
    parent "$options"
    reject "$options parent"
done
[ ! -d "$ZC_STATE" ]
parent
MOUNT_FAIL=1
reject "a failed mount"
[ ! -e "$ZC_STATE/config" ]
[ ! -d "$ZC_ROOT/.state-mount-lock" ]
MOUNT_FAIL=0
echo stray > "$ZC_STATE/stray"
reject "a nonempty unmounted state directory"
rm "$ZC_STATE/stray"
zc_check_storage "$FIXTURE" "$SYSFS"
[ "$ZC_STATE" = "$TEST_MOUNT/zeroclaw/state" ]
mount_count="$(grep -c '^mount$' "$RECORD")"
zc_check_storage "$FIXTURE" "$SYSFS"
[ "$(grep -c '^mount$' "$RECORD")" -eq "$mount_count" ]
for row in \
    "/dev/card $ZC_STATE ext4 rw,nosuid,nodev 0 0" \
    "/dev/loop0 $ZC_STATE vfat rw,nosuid,nodev 0 0" \
    "/dev/loop0 $ZC_STATE ext4 ro,nosuid,nodev 0 0" \
    "/dev/loop0 $ZC_STATE ext4 rw,noexec,nosuid,nodev 0 0" \
    "/dev/loop0 $ZC_STATE ext4 rw,nodev 0 0" \
    "/dev/loop0 $ZC_STATE ext4 rw,nosuid 0 0"; do
    parent
    printf '%s\n' "$row" >> "$FIXTURE"
    reject "an incorrect state mount: $row"
done
parent
printf '/dev/loop0 %s ext4 rw,nosuid,nodev 0 0\n' "$ZC_STATE" >> "$FIXTURE"
printf '%s\n' "$TEST_DIR/other-image" > "$SYSFS/loop0/loop/backing_file"
reject "another loop backing file"
printf '%s\n' "$ZC_IMAGE" > "$SYSFS/loop0/loop/backing_file"
STATE_ACCESS='0:0:755'
reject "insecure ext4 root permissions"
STATE_ACCESS='0:0:700'
printf '/dev/card %s ext4 rw,nosuid,nodev 0 0\n' "$ZC_STATE" >> "$FIXTURE"
reject "a different filesystem stacked over a valid image mount"
ZC_STORAGE_MODE=unknown
reject "an invalid storage mode"
ZC_STORAGE_MODE=image

BUNDLE="$TEST_MOUNT/unpack"
mkdir -p "$BUNDLE/openwrt/files" "$BUNDLE/bin"
sed -e "s@/proc/mounts@$FIXTURE@g" -e "s@/sys/block@$SYSFS@g" \
    "$ROOT/openwrt/files/zeroclaw-common.sh" > "$BUNDLE/openwrt/files/zeroclaw-common.sh"
cp "$ROOT/openwrt/files/zeroclaw.config" "$BUNDLE/openwrt/files/"
cp "$ROOT/openwrt/files/zeroclaw" "$BUNDLE/openwrt/files/"
cp "$ROOT/openwrt/files/zeroclaw.init" "$BUNDLE/openwrt/files/"
sed -e '2i\. "$STUB"' "$ROOT/scripts/prepare-state-image.sh" > "$BUNDLE/prepare-state-image.sh"
sed -e 's|/etc/|$SYSTEM/etc/|g' -e 's|/usr/|$SYSTEM/usr/|g' \
    -e 's|^\. /lib/functions.sh$|. "$STUB"|' -e '2i\. "$STUB"' \
    "$ROOT/scripts/install.sh" > "$BUNDLE/install.sh"
cat > "$BUNDLE/bin/zeroclaw" <<'EOF'
#!/bin/sh
[ "${1:-}" != --version ] || exit 0
printf '%s\n' "$HOME|$PWD|$*" >> "$RECORD"
EOF
chmod 755 "$BUNDLE/bin/zeroclaw"
(cd "$BUNDLE" && sha256sum bin/zeroclaw openwrt/files/* > SHA256SUMS)
touch "$SYSTEM/etc/openwrt_release"
rm -f "$ZC_IMAGE" "$RECORD"
parent
AVAILABLE=1024
if sh "$BUNDLE/install.sh" --fat-image "$TEST_MOUNT/"; then
    echo "FAIL: image installation must check outer free space" >&2
    exit 1
fi
[ ! -e "$ZC_IMAGE" ] && [ ! -e "$RECORD" ]
AVAILABLE=invalid
if sh "$BUNDLE/install.sh" --fat-image "$TEST_MOUNT/"; then
    echo "FAIL: invalid free-space output must abort before image creation" >&2
    exit 1
fi
[ ! -e "$ZC_IMAGE" ] && [ ! -e "$RECORD" ]
AVAILABLE=1048576
FORMAT_FAIL=1
if sh "$BUNDLE/install.sh" --fat-image "$TEST_MOUNT/"; then
    echo "FAIL: failed formatting must abort installation" >&2
    exit 1
fi
[ ! -e "$ZC_IMAGE" ] && [ ! -e "$ZC_ROOT/.state.ext4.new" ]
[ ! -d "$ZC_ROOT/.state-create-lock" ]
FORMAT_FAIL=0
rm -f "$RECORD"
echo keep-temporary > "$ZC_ROOT/.state.ext4.new"
if sh "$BUNDLE/prepare-state-image.sh" "$TEST_MOUNT/"; then
    echo "FAIL: an existing temporary image must never be overwritten" >&2
    exit 1
fi
grep -Fx keep-temporary "$ZC_ROOT/.state.ext4.new"
[ ! -e "$RECORD" ] && [ ! -e "$ZC_IMAGE" ]
rm "$ZC_ROOT/.state.ext4.new"
echo keep-existing > "$ZC_IMAGE"
MOUNT_FAIL=1
if sh "$BUNDLE/prepare-state-image.sh" "$TEST_MOUNT/"; then
    echo "FAIL: an unmountable existing image must not be reformatted" >&2
    exit 1
fi
grep -Fx keep-existing "$ZC_IMAGE"
if grep '^format ' "$RECORD"; then
    echo "FAIL: existing image was passed to the formatter" >&2
    exit 1
fi
rm -f "$ZC_IMAGE" "$RECORD"
MOUNT_FAIL=0
sh "$BUNDLE/install.sh" --fat-image "$TEST_MOUNT/"
grep -Fx 'set zeroclaw.main.storage_mode=image' "$RECORD"
grep -Fx 'set zeroclaw.main.allow_fat=0' "$RECORD"
grep -Fx 'set zeroclaw.main.enabled=0' "$RECORD"
grep -Fx "dd if=/dev/zero of=$ZC_ROOT/.state.ext4.new bs=1048576 count=256" "$RECORD"
[ -d "$ZC_STATE/config" ] && [ -d "$ZC_STATE/home" ]
[ ! -d "$ZC_ROOT/config" ] && [ ! -d "$ZC_ROOT/home" ]
echo user-state > "$ZC_STATE/config/persisted"
image_hash="$(sha256sum "$ZC_IMAGE")"
format_count="$(grep -c '^format ' "$RECORD")"
printf '#!/bin/sh\nexit 0\n' > "$SYSTEM/etc/init.d/zeroclaw"
sh "$BUNDLE/install.sh" "$TEST_MOUNT/"
[ "$(sha256sum "$ZC_IMAGE")" = "$image_hash" ]
[ "$(grep -c '^format ' "$RECORD")" -eq "$format_count" ]
grep -Fx user-state "$ZC_STATE/config/persisted"

sed -e 's|^\. /lib/functions.sh$|. "$STUB"|' \
    -e 's|^\. /usr/libexec/zeroclaw-common.sh$|. "$BUNDLE/openwrt/files/zeroclaw-common.sh"|' \
    "$ROOT/openwrt/files/zeroclaw" > "$TEST_DIR/launcher"
sed -e 's|^\. /usr/libexec/zeroclaw-common.sh$|. "$STUB"; . "$BUNDLE/openwrt/files/zeroclaw-common.sh"|' \
    "$ROOT/openwrt/files/zeroclaw.init" > "$TEST_DIR/init"
export BUNDLE
sh "$TEST_DIR/launcher" agent
grep -Fx "$ZC_STATE/home|$ZC_STATE|--config-dir $ZC_STATE/config agent" "$RECORD"
sh -c '. "$1"; start_service' sh "$TEST_DIR/init"
grep -Fx 'command /usr/bin/zeroclaw --verbose daemon --host 127.0.0.1 --port 42617' "$RECORD"
parent ro
rm -f "$RECORD"
if sh "$TEST_DIR/launcher" agent || sh -c '. "$1"; start_service' sh "$TEST_DIR/init"; then
    echo "FAIL: runtime must reject a read-only card" >&2
    exit 1
fi
[ ! -e "$RECORD" ]
echo "Image-backed storage tests passed"
