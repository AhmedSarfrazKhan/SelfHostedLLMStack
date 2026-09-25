#!/usr/bin/env bash
#
# Create .env from .env.example with random secrets, and a restic password file.
#
# Refuses to overwrite either. Regenerating AUTHENTIK_SECRET_KEY on a running install
# signs everyone out and invalidates every issued token; regenerating the restic
# password makes every existing snapshot unreadable. Both are the kind of mistake that
# is one keystroke to make and very hard to undo.

set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

[[ -e .env ]] && fail ".env already exists. Delete it yourself if you really mean to."

rand() { head -c "$1" /dev/urandom | base64 | tr -d '/+=\n' | head -c "$2"; }

sed \
  -e "s|^AUTHENTIK_SECRET_KEY=.*|AUTHENTIK_SECRET_KEY=$(rand 64 60)|" \
  -e "s|^AUTHENTIK_DB_PASSWORD=.*|AUTHENTIK_DB_PASSWORD=$(rand 48 40)|" \
  -e "s|^AUTHENTIK_BOOTSTRAP_PASSWORD=.*|AUTHENTIK_BOOTSTRAP_PASSWORD=$(rand 32 24)|" \
  -e "s|^LLM_CLIENT_TOKEN=.*|LLM_CLIENT_TOKEN=$(rand 64 48)|" \
  .env.example > .env
chmod 600 .env
log "wrote .env"

load_env
pwfile="$(abspath "${RESTIC_PASSWORD_FILE}")"
if [[ -e "${pwfile}" ]]; then
  log "${pwfile} already exists, leaving it alone"
else
  mkdir -p "$(dirname "${pwfile}")"
  ( umask 077; rand 64 48 > "${pwfile}" )
  log "wrote ${pwfile}"
  echo "    Copy it somewhere that is not this machine now. Without it, every backup is unreadable."
fi
