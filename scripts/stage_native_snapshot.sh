#!/usr/bin/env bash
# Stage the locally built co.rsk:native SNAPSHOT from the host ~/.m2 into the
# Docker build context, so the in-container Gradle build (which has its own
# empty ~/.m2) can resolve it via mavenLocal().
#
# Run this before `docker compose -f docker-compose.rskj.yml build <node>`
# whenever the native jar has been rebuilt.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$ROOT/m2/co/rsk/native"

# Version rskj actually asks for, so the two can never drift.
VER="${1:-$(sed -n "s/.*rskjNativeVer *: *'\([^']*\)'.*/\1/p" \
  "$ROOT/repos/rskj/rskj-core/build.gradle")}"
if [ -z "$VER" ]; then
  echo "ERROR: could not read rskjNativeVer from repos/rskj/rskj-core/build.gradle" >&2
  exit 1
fi

SRC="$HOME/.m2/repository/co/rsk/native/$VER"
if [ ! -f "$SRC/native-$VER.jar" ]; then
  echo "ERROR: $SRC/native-$VER.jar not found." >&2
  echo "Build and install it first:  cd repos/native && ./gradlew install" >&2
  exit 1
fi

rm -rf "$DEST"
mkdir -p "$DEST/$VER"
# Only the jar + pom are needed to resolve; sources/javadoc would just bloat
# the build context (and the image layer) by ~7 MB.
cp "$SRC/native-$VER.jar" "$SRC/native-$VER.pom" "$DEST/$VER/"
[ -f "$SRC/maven-metadata-local.xml" ] && \
  cp "$SRC/maven-metadata-local.xml" "$DEST/$VER/"

echo "Staged co.rsk:native:$VER -> m2/co/rsk/native/$VER"
ls -l "$DEST/$VER"
