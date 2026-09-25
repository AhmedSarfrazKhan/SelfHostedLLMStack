#!/usr/bin/env bash
#
# Roll the Authentik database and the code back together, after a failed deploy.
#
# Authentik migrates its database on startup and has no downgrade path. So once a new
# Authentik image has started, the old image cannot run against that database, and
# "revert the commit" is not a rollback, it is a second outage. The database has to go
# back with the code. The deploy workflow takes the snapshot this script restores.
#
# Usage:  rollback.sh <pre-deploy dump> <previous commit sha>

set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
load_env

SNAPSHOT="${1:?pre-deploy dump required}"
PREV_SHA="${2:?previous commit sha required}"

# Validate before destroying anything. pg_restore --list reads the archive's table of
# contents without touching a database, so it costs nothing and catches truncated,
# corrupt and zero-byte dumps, at the one moment when there is nothing to fall back to.
log "validating ${SNAPSHOT} before touching the database"
[[ -s "${SNAPSHOT}" ]] || fail "${SNAPSHOT} is missing or empty. Refusing to drop the database."
docker compose exec -T authentik-db pg_restore --list < "${SNAPSHOT}" >/dev/null 2>&1 \
  || fail "${SNAPSHOT} is not a readable pg_dump archive. Refusing to drop the database."
git cat-file -e "${PREV_SHA}^{commit}" 2>/dev/null \
  || fail "${PREV_SHA} is not a commit in this checkout. Refusing to drop the database."

log "stopping Authentik so nothing writes during the restore"
docker compose stop authentik-server authentik-worker gateway

log "checking out ${PREV_SHA}"
git checkout --quiet "${PREV_SHA}"

# The database container may itself have changed in the failed deploy. Bring it up on
# the previous code's image before restoring into it.
docker compose up -d --wait authentik-db

log "recreating the database from ${SNAPSHOT}"
docker compose exec -T authentik-db psql -U authentik -d postgres -qc "DROP DATABASE IF EXISTS authentik WITH (FORCE)"
docker compose exec -T authentik-db psql -U authentik -d postgres -qc "CREATE DATABASE authentik OWNER authentik"
docker compose exec -T authentik-db pg_restore -U authentik -d authentik --no-owner --exit-on-error < "${SNAPSHOT}"

log "bringing the stack back up on the previous code"
docker compose up -d --wait
# Same reason as in deploy.sh: Caddy only reads its config at start, so without this
# the gateway would keep serving the config that just failed.
docker compose restart gateway >/dev/null
docker compose up -d --wait --wait-timeout 120 gateway
"$(dirname "$0")/apply_blueprint.sh"

if "$(dirname "$0")/smoke_test.sh"; then
  log "rollback complete, database and code both at ${PREV_SHA}"
else
  fail "rolled back, but the smoke test fails. Manual intervention needed; see docs/runbook.md."
fi
