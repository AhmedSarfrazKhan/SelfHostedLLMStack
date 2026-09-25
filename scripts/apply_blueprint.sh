#!/usr/bin/env bash
#
# Apply the SSO blueprint now, and fail unless what it declares actually exists.
#
# Authentik re-applies a blueprint when the file changes and on its own schedule. It
# does NOT re-apply on restart, and it does not notice when a value it reads from the
# environment (a hostname, the service token) has changed. So a restart after editing
# .env leaves the old values in place, and a policy someone deleted in the admin UI
# stays deleted until the next scheduled run. This was found by deleting the access
# policy on purpose and watching a worker restart fail to bring it back.
#
# Success is judged by the objects in the database, not by the blueprint's recorded
# status. On a fresh install the worker's own first attempt runs before Authentik has
# created the default flows this blueprint refers to, records `error`, and an explicit
# apply that then succeeds does not clear it. CI caught that; trusting the status
# field would fail a working install on one machine and pass it on another depending on
# timing. So: apply, check the objects, and retry while the worker is still bootstrapping.
#
# Run by the deploy workflow, recover.sh and CI before the smoke test, so every deploy
# converges on what the blueprint says rather than on whatever the database drifted to.

set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

BLUEPRINT=selfhostedllmstack.yaml
ATTEMPTS="${BLUEPRINT_ATTEMPTS:-24}"

sql() { docker compose exec -T authentik-db psql -U authentik -d authentik -tAc "$1"; }

# Every object the gateway depends on, as one row of counts. The expected row is what
# config/authentik/blueprints/selfhostedllmstack.yaml declares.
EXPECTED="1|2|1|1"
state() {
  sql "SELECT
    (SELECT count(*) FROM authentik_core_application WHERE slug = 'llm' AND provider_id IS NOT NULL),
    (SELECT count(*) FROM authentik_policies_policybinding b
       JOIN authentik_core_application a ON a.policybindingmodel_ptr_id = b.target_id
      WHERE a.slug = 'llm' AND b.enabled),
    (SELECT count(*) FROM authentik_core_token
      WHERE identifier = 'svc-assistant-llm' AND intent = 'app_password'),
    (SELECT count(*) FROM authentik_outposts_outpost_providers op
       JOIN authentik_outposts_outpost o ON o.uuid = op.outpost_id
       JOIN authentik_core_application a ON a.provider_id = op.provider_id
      WHERE o.managed = 'goauthentik.io/outposts/embedded' AND a.slug = 'llm')"
}

log "applying config/authentik/blueprints/${BLUEPRINT}"
for attempt in $(seq 1 "${ATTEMPTS}"); do
  docker compose exec -T authentik-worker ak apply_blueprint "custom/${BLUEPRINT}" >/dev/null 2>&1 || true
  current="$(state 2>/dev/null || echo unavailable)"
  if [[ "${current}" == "${EXPECTED}" ]]; then
    log "blueprint applied (application, 2 policy bindings, service token, outpost binding)"
    break
  fi
  echo "    attempt ${attempt}/${ATTEMPTS}: state ${current}, expected ${EXPECTED}; Authentik may still be bootstrapping"
  sleep 5
done

[[ "${current}" == "${EXPECTED}" ]] \
  || fail "blueprint did not converge. Counts are application|bindings|token|outpost. See: docker compose logs authentik-worker"

# The database being right is not the gateway being right. The embedded outpost loads
# its providers asynchronously, and until it has, forward auth answers 404 for the LLM
# host. CI hit exactly that: blueprint applied, every request 404. So wait until an
# anonymous request is redirected to Authentik, which only happens once the outpost
# knows the host.
load_env
PORT="${GATEWAY_PORT:-8480}"
for attempt in $(seq 1 60); do
  got="$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' --max-time 10 \
         --connect-to "::127.0.0.1:${PORT}" "${LLM_EXTERNAL_URL}/api/version" || true)"
  if [[ "${got}" == "302 ${AUTH_EXTERNAL_URL}/"* ]]; then
    log "outpost is serving ${LLM_EXTERNAL_URL}"
    exit 0
  fi
  echo "    outpost not serving the LLM host yet (${got%% *}), attempt ${attempt}/60"
  sleep 5
done
fail "the outpost never started serving ${LLM_EXTERNAL_URL}. See: docker compose logs authentik-server"
