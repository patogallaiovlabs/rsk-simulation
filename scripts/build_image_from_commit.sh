#!/usr/bin/env bash
# Build a named Docker image from a specific repos/rskj commit without disturbing the
# current branch or uncommitted changes.
#
# Usage:
#   scripts/build_image_from_commit.sh <commit> <image:tag> [<service>]
#
# Arguments:
#   commit      Git commit hash (or tag/branch) in repos/rskj to build from.
#   image:tag   Docker image name and tag to produce (e.g. rskj-baseline:commit1).
#   service     Compose service whose Dockerfile/build-context to use (default: rskj-miner1).
#               The service's build context and Dockerfile are read from docker-compose.rskj.yml,
#               but the repos/rskj source inside that context is swapped to <commit>.
#
# Example:
#   scripts/build_image_from_commit.sh 2f2ff25d6 rskj-baseline:commit1
#   scripts/build_image_from_commit.sh 2f2ff25d6 rskj-baseline:commit1 rskj-miner3
#
# After this script completes:
#   - repos/rskj is back on its original branch with all local changes intact.
#   - The image is available locally as <image:tag>.
#   - To pin a compose service to it, replace its build: block with image: <image:tag>.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

# ── args ──────────────────────────────────────────────────────────────────────
if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <commit> <image:tag> [<service>]" >&2
  exit 1
fi

COMMIT="$1"
IMAGE_TAG="$2"
SERVICE="${3:-rskj-miner1}"

# ── resolve build context and dockerfile from compose ─────────────────────────
CONTEXT=$(docker compose -f docker-compose.rskj.yml config --format json \
  | python3 -c "
import sys, json
svc = json.load(sys.stdin)['services']['$SERVICE']
print(svc['build']['context'])
")
DOCKERFILE=$(docker compose -f docker-compose.rskj.yml config --format json \
  | python3 -c "
import sys, json
svc = json.load(sys.stdin)['services']['$SERVICE']
print(svc['build'].get('dockerfile', 'Dockerfile'))
")

echo "==> commit   : $COMMIT"
echo "==> image    : $IMAGE_TAG"
echo "==> service  : $SERVICE (context=$CONTEXT, dockerfile=$DOCKERFILE)"

# ── save repos/rskj state ─────────────────────────────────────────────────────
RSKJ_DIR="repos/rskj"
ORIGINAL_BRANCH=$(git -C "$RSKJ_DIR" symbolic-ref --short HEAD 2>/dev/null || echo "")
STASH_NAME="build-image-from-commit-temp-$$"
STASHED=0

if ! git -C "$RSKJ_DIR" diff --quiet || ! git -C "$RSKJ_DIR" diff --cached --quiet; then
  echo "==> stashing uncommitted changes in $RSKJ_DIR"
  git -C "$RSKJ_DIR" stash push -m "$STASH_NAME"
  STASHED=1
fi

restore_rskj() {
  echo "==> restoring $RSKJ_DIR"
  if [[ -n "$ORIGINAL_BRANCH" ]]; then
    git -C "$RSKJ_DIR" checkout "$ORIGINAL_BRANCH"
  else
    echo "    (was in detached HEAD before — leaving as-is after checkout)"
  fi
  if [[ "$STASHED" -eq 1 ]]; then
    git -C "$RSKJ_DIR" stash pop
  fi
}
trap restore_rskj EXIT

# ── checkout target commit ─────────────────────────────────────────────────────
echo "==> checking out $COMMIT in $RSKJ_DIR"
git -C "$RSKJ_DIR" checkout "$COMMIT"
echo "    $(git -C "$RSKJ_DIR" log --oneline -1)"

# ── build ─────────────────────────────────────────────────────────────────────
echo "==> building $IMAGE_TAG"
docker build -t "$IMAGE_TAG" -f "$DOCKERFILE" "$CONTEXT"

echo "==> built successfully: $IMAGE_TAG"
# restore_rskj runs via EXIT trap
