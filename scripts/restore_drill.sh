#!/usr/bin/env bash
#
# Restore the latest snapshot somewhere harmless, prove it holds what it should, and
# time it. Run weekly from deploy/systemd/inference-restore-drill.timer.
#
# This is the script that separates having backups from having recovery. It restores
# into a throwaway PostgreSQL container running the exact image production pins, with
# no network, and never touches the live stack.
#
# It FAILS when:
#   - there is no snapshot, or it cannot be restored
#   - the database restores empty, or without the SSO configuration in it
#   - any archive in the snapshot is unreadable
#   - the whole thing takes longer than DRILL_MAX_SECONDS
#
# The last one matters. A drill that passes however long it takes cannot tell you
# whether you meet the RTO in docs/disaster-recovery.md, and that is what it is for.
#
# Every run appends one line to backups/drill-history.log, so the RTO in the DR page
# is a measured number with a history rather than an estimate.

set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
load_env

MAX_SECONDS="${DRILL_MAX_SECONDS:-900}"
HISTORY="${REPO_ROOT}/backups/drill-history.log"
WORKDIR="$(mktemp -d)"
DRILL_PG="inference-drill-pg-$$"
cleanup() {
  docker rm -f "${DRILL_PG}" >/dev/null 2>&1 || true
  rm -rf "${WORKDIR}"
}
trap cleanup EXIT
STARTED=$(date +%s)
FAILED=0
bad() { printf '    FAIL: %s\n' "$*" >&2; FAILED=1; }

SNAPSHOT="$(restic snapshots --tag selfhostedllmstack --latest 1 --json \
  | python3 -c 'import json,sys; s=json.load(sys.stdin); print(s[-1]["short_id"] if s else "")')"
[[ -n "${SNAPSHOT}" ]] || fail "no selfhostedllmstack snapshot in ${RESTIC_REPOSITORY}"

log "restoring snapshot ${SNAPSHOT}"
RESTIC_DOCKER_ARGS=(-v "${WORKDIR}:/restore")
restic restore "${SNAPSHOT}" --target /restore --quiet
RESTORED="${WORKDIR}/backup/selfhostedllmstack"
[[ -f "${RESTORED}/MANIFEST" ]] || fail "snapshot ${SNAPSHOT} has no MANIFEST"
sed -n 's/^\(created\|commit\): */    \1 /p' "${RESTORED}/MANIFEST"

log "starting a throwaway PostgreSQL (no network)"
docker run -d --name "${DRILL_PG}" --network none \
  -e POSTGRES_USER=authentik -e POSTGRES_PASSWORD=drill -e POSTGRES_DB=authentik \
  "$(postgres_image)" >/dev/null
for _ in $(seq 1 60); do
  # pg_isready passes during the image's init phase, when a temporary server is up and
  # about to be shut down again. Querying the target database is the reliable signal.
  docker exec "${DRILL_PG}" psql -U authentik -d authentik -tAc 'select 1' >/dev/null 2>&1 && break
  sleep 1
done

log "restoring the Authentik database"
docker exec -i "${DRILL_PG}" pg_restore -U authentik -d authentik --no-owner --exit-on-error \
  < "${RESTORED}/authentik.dump" || bad "pg_restore reported errors"

# Counts of things that must never be missing. A restore that produces an empty
# database succeeds at the command line and fails at the only thing that matters.
q() { docker exec "${DRILL_PG}" psql -U authentik -d authentik -tAc "$1" 2>/dev/null || echo 0; }
expect() { # expect <label> <minimum> <sql>
  local n; n="$(q "$3")"
  printf '    %-42s %s\n' "$1" "${n}"
  [[ "${n}" =~ ^[0-9]+$ && "${n}" -ge "$2" ]] || bad "$1: expected at least $2, got ${n}"
}
expect "users"                                  1 "select count(*) from authentik_core_user where username = 'akadmin'"
expect "LLM gateway application"                1 "select count(*) from authentik_core_application where slug = 'llm'"
expect "llm-users group bindings"               1 "select count(*) from authentik_policies_policybinding b join authentik_core_group g on g.group_uuid = b.group_id where g.name = 'llm-users'"
expect "service account app passwords"          1 "select count(*) from authentik_core_token where intent = 'app_password'"
# Not the blueprint's recorded status: that can say `error` on a working install (see
# apply_blueprint.sh). The objects are what the gateway actually depends on.
expect "LLM provider bound to the embedded outpost" 1 "select count(*) from authentik_outposts_outpost_providers op join authentik_outposts_outpost o on o.uuid = op.outpost_id join authentik_core_application a on a.provider_id = op.provider_id where o.managed = 'goauthentik.io/outposts/embedded' and a.slug = 'llm'"

log "checking archives"
for archive in "${RESTORED}"/*.tgz; do
  [[ -e "${archive}" ]] || continue
  if files="$(tar -tzf "${archive}" | wc -l)"; then
    printf '    %-42s %s entries\n' "$(basename "${archive}")" "${files}"
  else
    bad "$(basename "${archive}") is unreadable"
  fi
done
[[ -s "${RESTORED}/env" ]] || bad "env is missing from the snapshot; recovery will need .env from elsewhere"

ELAPSED=$(( $(date +%s) - STARTED ))
log "restore completed in $(fmt_duration "${ELAPSED}") (limit $(fmt_duration "${MAX_SECONDS}"))"
if (( ELAPSED > MAX_SECONDS )); then
  bad "restore took longer than DRILL_MAX_SECONDS; the documented RTO is not being met"
fi

RESULT=PASSED; [[ "${FAILED}" -eq 0 ]] || RESULT=FAILED
mkdir -p "$(dirname "${HISTORY}")"
printf '%s snapshot=%s seconds=%d result=%s\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${SNAPSHOT}" "${ELAPSED}" "${RESULT}" >> "${HISTORY}"

if [[ "${FAILED}" -ne 0 ]]; then
  echo "==> drill FAILED" >&2
  exit 1
fi
echo "==> drill PASSED, throwaway database removed"
