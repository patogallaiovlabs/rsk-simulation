#!/usr/bin/env bash
# Replay the deterministic-replay benchmark (1158-block sample) once per commit,
# walking repos/rskj from a starting commit to a tip commit, one commit at a time.
# Produces one set of bench/deterministic-replay/results/<label>_* files per commit,
# so results across the whole range can be diffed with nmt/analyze_block_breakdown.py.
#
# Usage:
#   scripts/replay_commit_sweep.sh <from-commit> <to-commit> [label-prefix]
#
# Arguments:
#   from-commit    First commit to replay (inclusive), e.g. commit 1's hash.
#   to-commit      Last commit to replay (inclusive), e.g. the branch tip.
#   label-prefix   Prefix for result labels (default: sweep). Each commit's results
#                  are saved as <prefix>_<NN>_<shorthash>.
#
# What it does, per commit (oldest to newest, from-commit..to-commit inclusive):
#   1. git checkout <commit> in repos/rskj (detached HEAD)
#   2. docker compose -f docker-compose.rskj.yml build rskj-miner1  (produces the
#      rsk-nodes-rskj-miner1 image the replay harness expects)
#   3. bench/deterministic-replay/run_replay_1159.sh <label>
#
# Any uncommitted changes in repos/rskj are stashed before the sweep starts and
# popped back after it ends (or if the script is interrupted — trap on EXIT).
# repos/rskj is restored to its original branch when the sweep finishes.
#
# This is a long-running, sequential operation (one Gradle build + one full
# 1158-block replay per commit) — expect many hours for a large commit range.
# Progress and per-commit status are logged to
# bench/deterministic-replay/results/sweep_progress.log so the sweep can be
# monitored or resumed by inspecting which labels already have a _summary.json.

set -uo pipefail   # NOT -e: one commit's failure shouldn't kill the whole sweep

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

RSKJ_DIR="repos/rskj"
RESULTS_DIR="bench/deterministic-replay/results"
PROGRESS_LOG="$RESULTS_DIR/sweep_progress.log"

# ── args ──────────────────────────────────────────────────────────────────────
if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <from-commit> <to-commit> [label-prefix]" >&2
  exit 1
fi

FROM_COMMIT="$1"
TO_COMMIT="$2"
LABEL_PREFIX="${3:-sweep}"

mkdir -p "$RESULTS_DIR"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$PROGRESS_LOG"
}

# ── resolve commit list (oldest first, inclusive of both ends) ────────────────
if ! git -C "$RSKJ_DIR" cat-file -t "$FROM_COMMIT" &>/dev/null; then
  echo "Error: from-commit '$FROM_COMMIT' not found in $RSKJ_DIR" >&2
  exit 1
fi
if ! git -C "$RSKJ_DIR" cat-file -t "$TO_COMMIT" &>/dev/null; then
  echo "Error: to-commit '$TO_COMMIT' not found in $RSKJ_DIR" >&2
  exit 1
fi

COMMITS=()
while IFS= read -r line; do
  COMMITS+=("$line")
done < <(git -C "$RSKJ_DIR" log --reverse --format="%H" "${FROM_COMMIT}^..${TO_COMMIT}")

if [[ ${#COMMITS[@]} -eq 0 ]]; then
  echo "Error: no commits found between $FROM_COMMIT and $TO_COMMIT (is from-commit an ancestor of to-commit?)" >&2
  exit 1
fi

log "==> sweep starting: ${#COMMITS[@]} commits, from $FROM_COMMIT to $TO_COMMIT, label prefix '$LABEL_PREFIX'"

# ── save repos/rskj state ─────────────────────────────────────────────────────
ORIGINAL_BRANCH=$(git -C "$RSKJ_DIR" symbolic-ref --short HEAD 2>/dev/null || git -C "$RSKJ_DIR" rev-parse HEAD)
STASHED=0
if ! git -C "$RSKJ_DIR" diff --quiet || ! git -C "$RSKJ_DIR" diff --cached --quiet; then
  log "==> stashing uncommitted changes in $RSKJ_DIR"
  git -C "$RSKJ_DIR" stash push -m "replay-commit-sweep-temp-$$"
  STASHED=1
fi

restore_rskj() {
  log "==> restoring $RSKJ_DIR to $ORIGINAL_BRANCH"
  git -C "$RSKJ_DIR" checkout "$ORIGINAL_BRANCH"
  if [[ "$STASHED" -eq 1 ]]; then
    git -C "$RSKJ_DIR" stash pop
  fi
}
trap restore_rskj EXIT

# ── sweep ─────────────────────────────────────────────────────────────────────
TOTAL=${#COMMITS[@]}
FAILED=()

for i in "${!COMMITS[@]}"; do
  COMMIT="${COMMITS[$i]}"
  SHORT=$(git -C "$RSKJ_DIR" rev-parse --short "$COMMIT")
  NN=$(printf "%02d" "$((i + 1))")
  LABEL="${LABEL_PREFIX}_${NN}_${SHORT}"
  SUBJECT=$(git -C "$RSKJ_DIR" log -1 --format="%s" "$COMMIT")

  if [[ -f "$RESULTS_DIR/${LABEL}_summary.json" ]]; then
    log "==> [$((i + 1))/$TOTAL] $LABEL already has a summary — skipping (delete it to force a re-run)"
    continue
  fi

  log "==> [$((i + 1))/$TOTAL] $LABEL : $SUBJECT"

  if ! git -C "$RSKJ_DIR" checkout "$COMMIT" >>"$PROGRESS_LOG" 2>&1; then
    log "    FAILED to checkout $COMMIT — skipping"
    FAILED+=("$LABEL (checkout)")
    continue
  fi

  log "    building rskj-miner1 image..."
  if ! docker compose -f docker-compose.rskj.yml build rskj-miner1 >>"$PROGRESS_LOG" 2>&1; then
    log "    FAILED to build image for $LABEL — skipping"
    FAILED+=("$LABEL (build)")
    continue
  fi

  log "    running replay..."
  if ! ./bench/deterministic-replay/run_replay_1159.sh "$LABEL" >>"$PROGRESS_LOG" 2>&1; then
    log "    FAILED replay for $LABEL — check $PROGRESS_LOG and ${LABEL}_raw.log"
    FAILED+=("$LABEL (replay)")
    continue
  fi

  log "    done: $RESULTS_DIR/${LABEL}_summary.json"
done

log "==> sweep complete: $((TOTAL - ${#FAILED[@]}))/$TOTAL succeeded"
if [[ ${#FAILED[@]} -gt 0 ]]; then
  log "==> failed: ${FAILED[*]}"
fi
# restore_rskj runs via EXIT trap
