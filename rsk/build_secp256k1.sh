#!/bin/bash
set -e

# Configuration
SECP_VERSION="v0.2.0"
SRC_DIR="/tmp/secp256k1-src"
JNI_SRC_DIR="$(pwd)/rsk/secp256k1-native"
OUTPUT_DIR="$(pwd)/rsk/output"
JAVA_HOME="${JAVA_HOME:-/usr/lib/jvm/java-17-openjdk-amd64}"

echo "Building Secp256k1 with JNI support..."

# 1. Download source
if [ ! -d "$SRC_DIR" ]; then
    git clone https://github.com/bitcoin-core/secp256k1.git "$SRC_DIR"
fi
cd "$SRC_DIR"
git checkout "$SECP_VERSION"

# 2. Configure and Build libsecp256k1
./autogen.sh
./configure --enable-module-recovery --enable-experimental --enable-module-ecdh --with-pic
make -j$(nproc)

# 3. Compile JNI Wrapper
# Note: We need to include JNI headers and the secp256k1 headers
echo "Compiling JNI wrapper..."
mkdir -p "$OUTPUT_DIR"

gcc -shared -fPIC \
    -I"$SRC_DIR" \
    -I"$SRC_DIR/src" \
    -I"$JNI_SRC_DIR" \
    -I"$JAVA_HOME/include" \
    -I"$JAVA_HOME/include/linux" \
    "$JNI_SRC_DIR/org_bitcoin_NativeSecp256k1.c" \
    "$JNI_SRC_DIR/org_bitcoin_Secp256k1Context.c" \
    .libs/libsecp256k1.a \
    -o "$OUTPUT_DIR/libsecp256k1.so" \
    -lm

echo "Success! Library created at $OUTPUT_DIR/libsecp256k1.so"
