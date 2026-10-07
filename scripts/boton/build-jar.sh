#!/usr/bin/env bash
# Build an RSKj fat jar locally (no Docker) from a git ref in repos/rskj.
#
#   scripts/boton/build-jar.sh <git-ref> <output.jar>
#   scripts/boton/build-jar.sh block-processing-perf   /tmp/rsk-tip.jar
#   scripts/boton/build-jar.sh 47a2eb63a    /tmp/rsk-baseline.jar
#
# Builds the current checkout in place when <git-ref> is already HEAD; otherwise
# uses a throwaway git worktree so the working copy and its local changes are
# never disturbed. Takes ~20s, versus minutes for the Docker image path.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RSKJ="$ROOT/repos/rskj"
REF="${1:?usage: build-jar.sh <git-ref> <output.jar>}"
OUT="${2:?usage: build-jar.sh <git-ref> <output.jar>}"

# rskj targets Java 17; the default JDK on this machine may be newer.
JAVA_HOME="${JAVA_HOME:-$(/usr/libexec/java_home -v 17 2>/dev/null || true)}"
[ -n "$JAVA_HOME" ] || { echo "No JDK 17 found (/usr/libexec/java_home -v 17)." >&2; exit 1; }
export JAVA_HOME
echo "JDK: $("$JAVA_HOME/bin/java" -version 2>&1 | head -1)"

HEAD_SHA=$(git -C "$RSKJ" rev-parse HEAD)
REF_SHA=$(git -C "$RSKJ" rev-parse "$REF")

if [ "$HEAD_SHA" = "$REF_SHA" ]; then
  BUILD_DIR="$RSKJ"
  echo "Building current checkout ($REF -> ${REF_SHA:0:9}), local changes included."
else
  BUILD_DIR="$(mktemp -d)/rskj"
  echo "Building ${REF_SHA:0:9} in a throwaway worktree: $BUILD_DIR"
  git -C "$RSKJ" worktree add --detach "$BUILD_DIR" "$REF_SHA" >/dev/null
  # gradle-wrapper.jar is untracked in this repo, so a fresh worktree has no wrapper.
  cp "$RSKJ/gradle/wrapper/gradle-wrapper.jar" "$BUILD_DIR/gradle/wrapper/"
  # The mavenLocal->co.rsk:native restriction is an uncommitted local fix; without it
  # dependency verification fails on unrelated ~/.m2 artifacts served as bare .pom.
  if ! grep -q 'includeModule("co.rsk", "native")' "$BUILD_DIR/rskj-core/build.gradle"; then
    echo "Applying the mavenLocal content-filter fix to the worktree."
    /usr/bin/python3 - "$BUILD_DIR/rskj-core/build.gradle" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
s=s.replace("    mavenLocal()\n",
            '    mavenLocal {\n        content {\n            includeModule("co.rsk", "native")\n        }\n    }\n',1)
open(p,"w").write(s)
PY
  fi
fi

( cd "$BUILD_DIR" && ./gradlew :rskj-core:fatJar -x test --console=plain )
JAR=$(ls -t "$BUILD_DIR"/rskj-core/build/libs/*-all.jar | head -1)
cp "$JAR" "$OUT"

if [ "$BUILD_DIR" != "$RSKJ" ]; then
  git -C "$RSKJ" worktree remove --force "$BUILD_DIR" >/dev/null 2>&1 || true
fi

echo "-> $OUT ($(du -h "$OUT" | cut -f1)), built from ${REF_SHA:0:9}"
# The linux/amd64 natives must be present or the Boton box silently falls back to
# Bouncy Castle / JavaAltBN128, which changes throughput.
#
# Listed once into a variable rather than piped per-check: with `set -o pipefail`,
# `unzip -l ... | grep -q X` reports failure even on a match, because grep -q exits at
# the first hit, unzip dies of SIGPIPE, and pipefail propagates that non-zero status.
# That made this guard report MISSING for jars that were in fact complete.
JAR_LIST=$(unzip -l "$OUT")
for want in "co/rsk/altbn128/cloudflare/native/linux/amd64/libbn128.so" "librocksdbjni-linux64.so"; do
  case "$JAR_LIST" in
    *"$want"*) echo "   ok: $want" ;;
    *)         echo "   MISSING: $want" >&2 ;;
  esac
done
