#!/usr/bin/env bash
#
# Apply the SSO blueprint now, and fail if it does not apply cleanly.
#
# Authentik re-applies a blueprint when the file changes and on its own schedule. It
# does NOT re-apply on restart, and it does not notice when a value it reads from the
# environment (a hostname, the service token) has changed. So a restart after editing
# .env leaves the old values in place, and a policy someone deleted in the admin UI
# stays deleted until the next scheduled run. This was found by deleting the access
# policy on purpose and watching a worker restart fail to bring it back.
#
# Run by the deploy workflow and recover.sh before the smoke test, so every deploy
# converges on what the blueprint says rather than on whatever the database drifted to.

set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

log "applying config/authentik/blueprints/selfhostedllmstack.yaml"
docker compose exec -T authentik-worker ak apply_blueprint custom/selfhostedllmstack.yaml >/dev/null 2>&1 \
  || fail "ak apply_blueprint failed; see: docker compose logs authentik-worker"

status="$(docker compose exec -T authentik-db psql -U authentik -d authentik -tAc \
  "SELECT status FROM authentik_blueprints_blueprintinstance WHERE name = 'selfhostedllmstack'")"
[[ "${status}" == successful ]] || fail "blueprint status is '${status}', expected 'successful'"
log "blueprint applied"
