#!/usr/bin/env bash
#
# Rebuild the whole stack from a restic snapshot, on this host or a clean one.
# This is the procedure in docs/disaster-recovery.md, as a script, so the procedure
# that gets rehearsed is the procedure that gets run.
#
# Needs: this repository checked out, Docker, the restic repository location and its
# password file. Everything else, .env included, comes out of the snapshot.
#
# REFUSES to run if the stack's Authentik database volume already holds data. Recovery
# replaces state; it should never be the thing that destroys a working install. To
# rehearse on a host that is already running the stack, take it down with
# `docker compose down -v` first, deliberately.
#
# Usage:  recover.sh [snapshot id, default latest]

set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

SNAPSHOT_ARG="${1:-latest}"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT
STARTED=$(date +%s)
step() { log "[$(fmt_duration $(( $(date +%s) - STARTED )))] $*"; }

# restic settings can come from the environment on a clean host where .env does not
# exist yet; load_env only fills in what is unset.
load_env
if [[ -z "${RESTIC_REPOSITORY:-}" || -z "${RESTIC_PASSWORD_FILE:-}" ]]; then
  echo "FAIL: nothing says where the backups are. On a clean host there is no .env yet," >&2
  echo "      so pass the repository and password file explicitly:" >&2
  echo "        RESTIC_REPOSITORY=... RESTIC_PASSWORD_FILE=... scripts/recover.sh" >&2
  exit 1
fi

PROJECT="$(docker compose config --format json 2>/dev/null \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["name"])' 2>/dev/null || echo selfhostedllmstack)"
if docker volume inspect "${PROJECT}_authentik_db" >/dev/null 2>&1; then
  fail "volume ${PROJECT}_authentik_db exists. Refusing to recover over existing state."
fi

step "restoring snapshot ${SNAPSHOT_ARG}"
RESTIC_DOCKER_ARGS=(-v "${WORKDIR}:/restore")
restic restore "${SNAPSHOT_ARG}" --tag selfhostedllmstack --target /restore --quiet
RESTORED="${WORKDIR}/backup/selfhostedllmstack"
[[ -s "${RESTORED}/authentik.dump" ]] || fail "snapshot has no authentik.dump"
sed -n 's/^/    /p' "${RESTORED}/MANIFEST" | head -n 3

if [[ -f .env ]]; then
  step "keeping the existing .env"
else
  [[ -s "${RESTORED}/env" ]] || fail "no .env here and none in the snapshot"
  step "restoring .env from the snapshot"
  ( umask 077; cp "${RESTORED}/env" .env )
  load_env
fi

step "pulling images"
docker compose pull --quiet

step "starting the database and restoring into it"
docker compose up -d --wait authentik-db
docker compose exec -T authentik-db pg_restore -U authentik -d authentik --no-owner --exit-on-error \
  < "${RESTORED}/authentik.dump"

step "restoring volumes"
restore_volume() {
  local volume="$1" archive="$2"
  docker volume create "${volume}" >/dev/null
  docker run --rm --network none --entrypoint sh \
    -v "${volume}:/dst" -v "${archive}:/in.tgz:ro" \
    "${RESTIC_IMAGE}" -c 'tar -xzf /in.tgz -C /dst'
}
# Compose labels its volumes and warns about unlabelled ones it did not create, so
# create the stack's own volumes through compose first, then fill them.
docker compose create --quiet-pull >/dev/null 2>&1 || true
restore_volume "${PROJECT}_authentik_data" "${RESTORED}/authentik-data.tgz"
[[ -f "${RESTORED}/ollama-models.tgz" ]] && restore_volume "${PROJECT}_ollama_models" "${RESTORED}/ollama-models.tgz"
for archive in "${RESTORED}"/volume-*.tgz; do
  [[ -e "${archive}" ]] || continue
  volume="$(basename "${archive}" .tgz)"; volume="${volume#volume-}"
  restore_volume "${volume}" "${archive}"
  echo "    restored ${volume}"
done

step "starting the stack"
docker compose up -d --wait

step "applying the SSO blueprint"
"$(dirname "$0")/apply_blueprint.sh"

step "pulling pinned models"
"$(dirname "$0")/pull_model.sh"

step "smoke test"
"$(dirname "$0")/smoke_test.sh"

step "recovery complete"
