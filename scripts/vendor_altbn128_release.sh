#!/usr/bin/env bash
# Stage altbn128's libbn128.so for linux/{amd64,arm64} from the PUBLISHED
# co.rsk:native release, verifying every artifact against a known checksum.
#
# Why take the published binaries rather than rebuilding:
#   * The binaries committed to repos/native git are stale placeholders --
#     linux/arm64/libbn128.so is byte-identical to the amd64 one and is actually
#     an ELF x86-64 object, so altbn128 cannot load on arm64.
#   * A local rebuild works (scripts/build_altbn128.sh) but is NOT bit-reproducible:
#     the original toolchain has inputs Dockerfile never pinned (C toolchain
#     version, golang.org/x/sys revision), so the checksums documented in
#     repos/native/README.md cannot be reproduced. Verified: Go 1.13.5 on buster
#     gives bfb55c1c..., Go 1.13.15 gives a63478d1..., target is 1346e44d...
#   * The altbn128 Go source is IDENTICAL between tag 1.3.0 and current master
#     (`git diff 1.3.0 HEAD -- altbn128/`), so 1.3.0's binaries correspond to
#     today's source and come with a checksum that actually validates.
#
# Use scripts/build_altbn128.sh instead only when the Go source under
# repos/native/altbn128 has actually changed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VER="${ALTBN128_RELEASE_VER:-1.3.0}"
JAR_URL="https://deps.rsklabs.io/co/rsk/native/$VER/native-$VER.jar"

# Pinned by rskj itself in gradle/verification-metadata.xml, and the two library
# checksums are the ones documented in repos/native/README.md.
JAR_SHA256="cf03d2230ae7cf5349b44ffb3f089193aff17d8b8f6071ff562605d1be99228c"
AMD64_SHA256="1346e44d3e99147c760d306b1e859c6a42c631bd942b14c05af2dc6c84cadd78"
ARM64_SHA256="2746bad5e5f13482c076eb9a18875500526cce8d0b2264c59418a82493b0b2ad"

[ "$VER" = "1.3.0" ] || { echo "ERROR: checksums are pinned for 1.3.0; update them before changing ALTBN128_RELEASE_VER." >&2; exit 1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
JAR="$WORK/native-$VER.jar"

echo "==> fetching $JAR_URL"
curl -sSL -o "$JAR" "$JAR_URL"
echo "$JAR_SHA256  $JAR" | shasum -a 256 -c - >/dev/null \
  || { echo "ERROR: jar checksum mismatch -- refusing to use it." >&2; exit 1; }
echo "    jar sha256 OK ($JAR_SHA256)"

DEST="$ROOT/repos/native/src/main/resources/co/rsk/altbn128/cloudflare/native/linux"
for pair in "amd64 $AMD64_SHA256 3e" "arm64 $ARM64_SHA256 b7"; do
  set -- $pair; arch=$1; want=$2; machine=$3
  p="co/rsk/altbn128/cloudflare/native/linux/$arch/libbn128.so"
  unzip -p "$JAR" "$p" > "$WORK/$arch.so"
  echo "$want  $WORK/$arch.so" | shasum -a 256 -c - >/dev/null \
    || { echo "ERROR: $arch libbn128.so checksum mismatch." >&2; exit 1; }
  # Independent check that it is genuinely the right architecture: ELF e_machine
  # at offset 18 (0x3e = x86-64, 0xb7 = aarch64). This is the check whose absence
  # let a broken arm64 binary ship in the first place.
  got=$(od -An -tx1 -j18 -N1 "$WORK/$arch.so" | tr -d ' ')
  [ "$got" = "$machine" ] || { echo "ERROR: $arch e_machine=0x$got, expected 0x$machine." >&2; exit 1; }
  mkdir -p "$DEST/$arch"
  cp "$WORK/$arch.so" "$DEST/$arch/libbn128.so"
  echo "    $arch OK  sha256=${want:0:8}...  e_machine=0x$machine"
done

echo "Staged altbn128 $VER binaries into repos/native resources."
