#!/bin/sh
set -eu
ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT HUP INT TERM
CARD="$TEST_DIR/card"
BUNDLE="$CARD/unpack"
FIXTURE="$TEST_DIR/mounts"
RECORD="$TEST_DIR/record"
export RECORD
mkdir -p "$BUNDLE/bin" "$BUNDLE/openwrt/files"
cp "$ROOT/openwrt/files/zeroclaw-common.sh" "$BUNDLE/openwrt/files/"
sed -e 's/$(id -u)/0/' -e "s@/proc/mounts@\"$FIXTURE\"@" \
    "$ROOT/scripts/run-test.sh" > "$BUNDLE/run-test.sh"
cat > "$BUNDLE/bin/zeroclaw" <<'EOF'
#!/bin/sh
printf '%s\n' "$HOME|$XDG_CONFIG_HOME|$XDG_DATA_HOME|$XDG_CACHE_HOME|$PWD" > "$RECORD"
printf '%s\n' "$@" >> "$RECORD"
exit "${BINARY_STATUS:-0}"
EOF
chmod 755 "$BUNDLE/bin/zeroclaw"
(cd "$BUNDLE" && sha256sum bin/zeroclaw openwrt/files/* > SHA256SUMS)

reject() {
    rm -f "$RECORD"
    if sh "$BUNDLE/run-test.sh" "$CARD/" agent; then
        echo "FAIL: test runner must reject $1" >&2
        exit 1
    fi
    [ ! -e "$RECORD" ]
    [ ! -e "$CARD/zeroclaw-test" ]
}

printf '%s\n' 'overlay / overlay rw 0 0' > "$FIXTURE"
reject "an unmounted card"
printf '/dev/card %s0 vfat rw 0 0\n' "$CARD" > "$FIXTURE"
reject "a similarly named mount"
for options in ro,relatime rw,noexec; do
    printf '/dev/card %s vfat %s 0 0\n' "$CARD" "$options" > "$FIXTURE"
    reject "$options"
done
printf '/dev/card %s vfat rw,fmask=0000,dmask=0000 0 0\n' "$CARD" > "$FIXTURE"
for path in / relative "$CARD/../card/"; do
    if sh "$BUNDLE/run-test.sh" "$path" agent; then
        echo "FAIL: test runner must reject unsafe mount paths" >&2
        exit 1
    fi
    [ ! -e "$RECORD" ]
    [ ! -e "$CARD/zeroclaw-test" ]
done
printf '/dev/card %s vfat rw 0 0\n' "$TEST_DIR/elsewhere" > "$FIXTURE"
if sh "$BUNDLE/run-test.sh" "$TEST_DIR/elsewhere" agent; then
    echo "FAIL: test runner must require the bundle on the selected card" >&2
    exit 1
fi
[ ! -e "$TEST_DIR/elsewhere" ]
printf '/dev/card %s vfat rw,fmask=0000,dmask=0000 0 0\n' "$CARD" > "$FIXTURE"
printf '%s\n' 'tampered' >> "$BUNDLE/bin/zeroclaw"
reject "a corrupt bundle"
sed '$d' "$BUNDLE/bin/zeroclaw" > "$TEST_DIR/binary"
cp "$TEST_DIR/binary" "$BUNDLE/bin/zeroclaw"
chmod 644 "$BUNDLE/bin/zeroclaw"
case "$(uname -s)" in
    MINGW*|MSYS*) echo "Skipping POSIX execute-bit check on Windows" ;;
    *) reject "a non-executable binary" ;;
esac
chmod 755 "$BUNDLE/bin/zeroclaw"
sh "$BUNDLE/run-test.sh" "$CARD///" agent 'one argument'
grep -Fx "$CARD/zeroclaw-test/home|$CARD/zeroclaw-test/home/.config|$CARD/zeroclaw-test/home/.local/share|$CARD/zeroclaw-test/home/.cache|$CARD/zeroclaw-test" "$RECORD"
printf '%s\n' --config-dir "$CARD/zeroclaw-test/config" agent 'one argument' > "$TEST_DIR/expected"
sed '1d' "$RECORD" > "$TEST_DIR/args"
cmp "$TEST_DIR/expected" "$TEST_DIR/args"
[ ! -e "$CARD/zeroclaw" ]
sh "$BUNDLE/run-test.sh" "$CARD/"
grep -Fx -- --version "$RECORD"
BINARY_STATUS=7
export BINARY_STATUS
status=0
sh "$BUNDLE/run-test.sh" "$CARD/" agent || status=$?
[ "$status" -eq 7 ]
echo "Unchecked FAT test runner tests passed"
