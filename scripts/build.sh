#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source build.env

if [[ ! "${EXTRA_FEATURES:-}" =~ ^[a-zA-Z0-9_,-]*$ ]]; then
    echo "EXTRA_FEATURES must be a comma-separated Cargo feature list" >&2
    exit 1
fi
FEATURES="agent-runtime,gateway${EXTRA_FEATURES:+,$EXTRA_FEATURES}"
mkdir -p .sdk dist

SDK_URL="https://downloads.openwrt.org/releases/$OPENWRT_VERSION/targets/ipq40xx/generic/$SDK_FILE"
curl --fail --location --retry 3 "$SDK_URL" -o ".sdk/$SDK_FILE"
printf '%s  %s\n' "$SDK_SHA256" ".sdk/$SDK_FILE" | sha256sum --check
mkdir -p .sdk/sdk
tar --zstd -xf ".sdk/$SDK_FILE" --strip-components=1 -C .sdk/sdk
SDK="$ROOT/.sdk/sdk"
export STAGING_DIR="$SDK/staging_dir"
compilers=("$STAGING_DIR"/toolchain-*/bin/arm-openwrt-linux-muslgnueabi-gcc)
if [[ ${#compilers[@]} -ne 1 || ! -x "${compilers[0]}" ]]; then
    echo "Expected exactly one OpenWrt ARM musl EABI compiler" >&2
    exit 1
fi
CC_TARGET="${compilers[0]}"
PREFIX="${CC_TARGET%gcc}"
export PATH="$(dirname "$CC_TARGET"):$SDK/staging_dir/host/bin:$PATH"
export CARGO_TARGET_ARMV7_UNKNOWN_LINUX_MUSLEABI_LINKER="$CC_TARGET"
export CC_armv7_unknown_linux_musleabi="$CC_TARGET"
export AR_armv7_unknown_linux_musleabi="${PREFIX}ar"
export CFLAGS_armv7_unknown_linux_musleabi="-Os -mcpu=cortex-a7"
export CARGO_TARGET_ARMV7_UNKNOWN_LINUX_MUSLEABI_RUSTFLAGS="-C target-cpu=cortex-a7 -C target-feature=+crt-static -C link-arg=-static"

rustup toolchain install "$RUST_VERSION" --profile minimal --target "$RUST_TARGET"
git init upstream
git -C upstream remote add origin https://github.com/zeroclaw-labs/zeroclaw.git
git -C upstream fetch --depth 1 origin "$UPSTREAM_COMMIT"
git -C upstream checkout --detach FETCH_HEAD
test "$(git -C upstream rev-parse HEAD)" = "$UPSTREAM_COMMIT"

{
    printf 'upstream_version=%s\nupstream_commit=%s\n' "$UPSTREAM_VERSION" "$UPSTREAM_COMMIT"
    printf 'openwrt_version=%s\ntarget=%s\nfeatures=%s\n' "$OPENWRT_VERSION" "$RUST_TARGET" "$FEATURES"
    printf 'sdk_sha256=%s\n' "$SDK_SHA256"
    rustup run "$RUST_VERSION" rustc --version
    "$CC_TARGET" --version | head -n 1
} | tee dist/build-info.txt

cargo "+$RUST_VERSION" build --manifest-path upstream/Cargo.toml \
    --locked --release --target "$RUST_TARGET" --bin zeroclaw \
    --no-default-features --features "$FEATURES"
BIN="$ROOT/upstream/target/$RUST_TARGET/release/zeroclaw"
file "$BIN" | tee dist/binary-info.txt
"${PREFIX}readelf" -h -A "$BIN" >> dist/binary-info.txt
if "${PREFIX}readelf" -l "$BIN" | grep -q INTERP; then
    echo "Unexpected ELF dynamic interpreter; refusing to publish" >&2
    exit 1
fi
if "${PREFIX}readelf" -d "$BIN" | grep -q NEEDED; then
    echo "Unexpected shared-library dependency; refusing to publish" >&2
    exit 1
fi
qemu-arm -cpu cortex-a7 "$BIN" --version | tee -a dist/binary-info.txt
qemu-arm -cpu cortex-a7 "$BIN" --help > dist/cli-info.txt
qemu-arm -cpu cortex-a7 "$BIN" daemon --help >> dist/cli-info.txt

BUNDLE="$ROOT/dist/bundle"
mkdir -p "$BUNDLE/bin" "$BUNDLE/openwrt" "$BUNDLE/licenses"
install -m 755 "$BIN" "$BUNDLE/bin/zeroclaw"
cp -R openwrt/files "$BUNDLE/openwrt/"
install -m 755 scripts/install.sh "$BUNDLE/install.sh"
cp README.md LICENSE dist/build-info.txt dist/binary-info.txt "$BUNDLE/"
cp upstream/LICENSE* "$BUNDLE/licenses/"
(
    cd "$BUNDLE"
    find bin openwrt licenses -type f -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS
)
ARCHIVE="zeroclaw-${UPSTREAM_VERSION}-openwrt-ipq4019.tar.gz"
tar -czf "dist/$ARCHIVE" -C "$BUNDLE" .

cp -R openwrt "$SDK/package/zeroclaw-openwrt"
(
    cd "$SDK"
    ./scripts/feeds update -a
    ./scripts/feeds install ca-bundle
    printf '%s\n' \
        'CONFIG_ALL=n' 'CONFIG_ALL_NONSHARED=n' 'CONFIG_ALL_KMODS=n' \
        'CONFIG_PACKAGE_zeroclaw-openwrt=m' > .config
    make defconfig
    make package/zeroclaw-openwrt/compile -j2 V=s
)
mapfile -t PACKAGES < <(find "$SDK/bin" -type f -name 'zeroclaw-openwrt*.apk')
if [[ ${#PACKAGES[@]} -ne 1 ]]; then
    echo "Expected exactly one OpenWrt APK integration package" >&2
    exit 1
fi
cp "${PACKAGES[0]}" dist/
(
    cd dist
    sha256sum "$ARCHIVE" ./*.apk > SHA256SUMS
)
{
    echo "### Build artifacts"
    echo "- ZeroClaw $UPSTREAM_VERSION, static ARMv7 musl EABI, Cortex-A7"
    echo "- Features: $FEATURES"
    echo "- MMC deployment archive and small OpenWrt APK integration package"
    echo "- QEMU CLI smoke test passed; real-router operation is NOT yet verified."
    echo '```'
    du -h "$BIN" "dist/$ARCHIVE"
    echo '```'
} | tee -a "${GITHUB_STEP_SUMMARY:-/dev/stdout}"
