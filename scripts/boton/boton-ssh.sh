#!/usr/bin/env bash
# Thin, unattended-safe SSH/SCP wrapper for a Boton instance.
#
#   scripts/boton/boton-ssh.sh 'uptime; nproc'      # run a command
#   scripts/boton/boton-ssh.sh --push FILE REMOTE   # scp a file up
#   scripts/boton/boton-ssh.sh --pull REMOTE FILE   # scp a file down
#   scripts/boton/boton-ssh.sh --host 1.2.3.4 'id'  # override the configured host
#
# Host/key come from docs/boton/hosts.env (gitignored); see hosts.env.example.
# BatchMode=yes keeps it from ever blocking on a passphrase or host-key prompt —
# a hang here would stall an unattended run, so it fails fast instead.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENV_FILE="$ROOT/docs/boton/hosts.env"

if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  set -a; . "$ENV_FILE"; set +a
fi

HOST="${BOTON_HOST:-}"
if [[ "${1:-}" == "--host" ]]; then HOST="$2"; shift 2; fi

USER_="${BOTON_USER:-ubuntu}"
KEY="${BOTON_KEY:-$HOME/.ssh/rskj-automation}"
KEY="${KEY/#\~/$HOME}"

if [[ -z "$HOST" ]]; then
  echo "No host. Create $ENV_FILE (cp docs/boton/hosts.env.example docs/boton/hosts.env) or pass --host IP." >&2
  exit 2
fi

SSH_OPTS=(-i "$KEY" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=25
          -o ServerAliveInterval=15 -o StrictHostKeyChecking=accept-new)

case "${1:-}" in
  --push) shift; exec scp -q "${SSH_OPTS[@]}" "$1" "$USER_@$HOST:$2" ;;
  --pull) shift; exec scp -q "${SSH_OPTS[@]}" "$USER_@$HOST:$1" "$2" ;;
  "")     exec ssh "${SSH_OPTS[@]}" "$USER_@$HOST" ;;
  *)      exec ssh "${SSH_OPTS[@]}" "$USER_@$HOST" "$@" ;;
esac
