#!/usr/bin/env bash
# Build the co.rsk:native SNAPSHOT that repos/rskj depends on, and stage it for
# the Docker image build. Run this ONCE after cloning, before building any node.
#
#   ./scripts/build_native_libs.sh
#
# Why this exists: repos/rskj pins co.rsk:native:1.4.0-SNAPSHOT, which is NOT
# published anywhere -- it only exists in your local ~/.m2. Without it, every
# `docker compose ... build` fails to resolve the dependency.
#
# Why not `./gradlew buildProject` (what repos/native/README.md says): none of
# those tasks run on a modern host. buildAltbn128 needs Go <= 1.15 (the source
# uses a pre-modules relative import) plus an aarch64 cross-compiler;
# buildSecp256k1Cross uses images that no longer exist. This script builds each
# library the way that actually works today, then installs and stages the jar.
#
# Requirements: Docker, JDK 11 (for the Gradle 6.5 build) and, for the macOS
# binaries, Xcode command line tools + autoconf/automake/libtool.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAT="$ROOT/repos/native"
WORK="${TMPDIR:-/tmp}/rsk-native-build"
RES="$NAT/src/main/resources"

# Gradle 6.5 cannot compile under JDK 17+ ("IllegalAccessError: ... jdk.compiler
# does not export com.sun.tools.javac.code"), so pin a JDK 11 for the install step.
JDK11="${JDK11:-$(/usr/libexec/java_home -v 11 2>/dev/null || true)}"
if [ -z "$JDK11" ]; then
  echo "ERROR: no JDK 11 found. Install one, or set JDK11=/path/to/jdk11." >&2
  exit 1
fi
# Any modern JDK works for generating headers.
JDKANY="${JAVA_HOME:-$(/usr/libexec/java_home 2>/dev/null || true)}"

[ -f "$NAT/build.gradle" ] || { echo "ERROR: repos/native not initialised. Run: git submodule update --init --recursive" >&2; exit 1; }

rm -rf "$WORK"; mkdir -p "$WORK"

# ── 1. JNI headers ────────────────────────────────────────────────────────────
# secp256k1/jni/*.h are gitignored generated files, so a fresh clone has none and
# the C sources fail to compile. This is what gradle's generateJniHeaders does.
echo "==> generating JNI headers"
mkdir -p "$WORK/h" "$WORK/classes"
"$JDKANY/bin/javac" --release 8 -nowarn -h "$WORK/h" -d "$WORK/classes" \
  "$NAT"/src/main/java/org/bitcoin/*.java \
  "$NAT"/src/main/java/co/rsk/altbn128/cloudflare/*.java 2>&1 | grep -v '^Note:' || true
cp "$WORK/h/org_bitcoin_NativeSecp256k1.h" "$WORK/h/org_bitcoin_Secp256k1Context.h" "$NAT/secp256k1/jni/"

# ── 2. secp256k1 ──────────────────────────────────────────────────────────────
echo "==> preparing secp256k1 source"
rsync -a --exclude '.libs' --exclude 'build' "$NAT/secp256k1/" "$WORK/secp256k1-src/"
( cd "$WORK/secp256k1-src" && ./autogen.sh >"$WORK/autogen.log" 2>&1 )

CONFIGURE_FLAGS="--enable-experimental --enable-module-ecdh --enable-module-recovery --enable-jni
                 --disable-benchmark --disable-tests --disable-openssl-tests --disable-static"

if [ "$(uname -s)" = "Darwin" ]; then
  for pair in "aarch64-apple-darwin arm64" "x86_64-apple-darwin x86_64"; do
    set -- $pair; host=$1; arch=$2
    echo "==> secp256k1: macOS $arch"
    mkdir -p "$WORK/mac-$arch" && cd "$WORK/mac-$arch"
    JAVA_HOME="$JDKANY" "$WORK/secp256k1-src/configure" --host="$host" $CONFIGURE_FLAGS \
      CC=clang CFLAGS="-arch $arch -O2 -mmacosx-version-min=11.0" \
      LDFLAGS="-arch $arch -mmacosx-version-min=11.0" >configure.log 2>&1
    make -j"$(sysctl -n hw.ncpu)" >make.log 2>&1
  done
else
  echo "==> skipping macOS secp256k1 (not on Darwin)"
fi

echo "==> secp256k1: Linux amd64 + arm64"
cat > "$WORK/Dockerfile.secp" <<'EOF'
FROM eclipse-temurin:17-jdk AS build
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential autoconf automake libtool pkg-config file && \
    rm -rf /var/lib/apt/lists/*
COPY secp256k1-src /src
WORKDIR /build
RUN JAVA_HOME=/opt/java/openjdk /src/configure \
      --enable-experimental --enable-module-ecdh --enable-module-recovery --enable-jni \
      --disable-benchmark --disable-tests --disable-openssl-tests --disable-static \
      CFLAGS="-O2" \
 && make -j"$(nproc)"
RUN mkdir -p /out && cp .libs/libsecp256k1.so.0.0.0 /out/libsecp256k1.so
FROM scratch
COPY --from=build /out/libsecp256k1.so /libsecp256k1.so
EOF
cd "$WORK"
for plat in amd64 arm64; do
  docker buildx build --platform "linux/$plat" -f Dockerfile.secp \
    --output "type=local,dest=out-linux-$plat" . >"$WORK/secp-$plat.log" 2>&1
done

# ── 3. altbn128 ───────────────────────────────────────────────────────────────
# Take the PUBLISHED binaries: same Go source as current master, but with
# checksums that actually validate (a local rebuild is not bit-reproducible --
# see scripts/vendor_altbn128_release.sh for the evidence). Use
# scripts/build_altbn128.sh instead if the Go source itself changed.
echo "==> altbn128: vendoring verified release binaries"
"$ROOT/scripts/vendor_altbn128_release.sh"

# ── 4. stage every binary where the loaders look for it ───────────────────────
echo "==> staging binaries into resources"
R="$RES/org/bitcoin/native"
rm -rf "$R"; mkdir -p "$R/Linux/x86_64" "$R/Linux/aarch64" "$R/Mac/x86_64" "$R/Mac/aarch64"
cp "$WORK/out-linux-amd64/libsecp256k1.so" "$R/Linux/x86_64/libsecp256k1.so"
cp "$WORK/out-linux-arm64/libsecp256k1.so" "$R/Linux/aarch64/libsecp256k1.so"
if [ "$(uname -s)" = "Darwin" ]; then
  cp "$WORK/mac-x86_64/.libs/libsecp256k1.0.dylib" "$R/Mac/x86_64/libsecp256k1.jnilib"
  cp "$WORK/mac-arm64/.libs/libsecp256k1.0.dylib"  "$R/Mac/aarch64/libsecp256k1.jnilib"
fi
# altbn128 binaries were already written in place by step 3.

# ── 5. install to ~/.m2 and stage into the Docker build context ───────────────
echo "==> installing co.rsk:native to ~/.m2 (JDK 11)"
( cd "$NAT" && JAVA_HOME="$JDK11" ./gradlew --no-daemon install >"$WORK/install.log" 2>&1 ) \
  || { tail -30 "$WORK/install.log"; exit 1; }
"$ROOT/scripts/stage_native_snapshot.sh"

# ── 6. report ─────────────────────────────────────────────────────────────────
echo
echo "==> binaries in the published jar:"
find "$RES/org/bitcoin/native" "$RES/co/rsk/altbn128/cloudflare/native/linux" -type f | while read -r f; do
  printf "    %-52s %s\n" "${f#"$RES"/}" "$(file -b "$f" | cut -d, -f1-2)"
done
echo
echo "Done. Now build a node:  docker compose -f docker-compose.rskj.yml build rskj-miner1"
