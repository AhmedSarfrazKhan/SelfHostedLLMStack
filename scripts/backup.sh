#!/usr/bin/env bash
#
# Back up everything this stack cannot re-download, with restic.
# Run every six hours from deploy/systemd/inference-backup.timer.
#
# What goes in, and why:
#   authentik.dump      Users, groups, policies, tokens, the SSO configuration. The
#                       blueprint recreates the gateway setup, but not the people.
#   authentik-data.tgz  Uploaded media (logos, icons) and anything else under /data.
#   env                 .env, including AUTHENTIK_SECRET_KEY. The restic repository is
#                       encrypted, so this is safe, and it means the restic password is
#                       the only thing you need from outside the backup to recover.
#   MANIFEST            Commit, image digests and model pins at backup time, so a
#                       restore knows which code and images the data belongs to.
#   volume-*.tgz        Anything in BACKUP_EXTRA_VOLUMES. This is how services built on
#                       this stack add their state without editing this script.
#
# What stays out: model weights (re-downloadable, pinned by digest, and 1 GB of churn
# per snapshot) unless BACKUP_MODELS=1.
#
# Every artifact is checked before it is handed to restic. A dump redirected to a file
# creates the file before pg_dump writes a byte, so a dump that died halfway leaves
# something that exists and looks fine, and restic will faithfully keep it forever.

set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
load_env

STAGING="$(mktemp -d)"
trap 'rm -rf "${STAGING}"' EXIT
STARTED=$(date +%s)

# tar a named volume from a throwaway container. Root inside the container so it can
# read files owned by any uid, then hand the archive back to the invoking user.
archive_volume() {
  local volume="$1" out="$2"
  docker volume inspect "${volume}" >/dev/null 2>&1 || fail "volume ${volume} does not exist"
  docker run --rm --network none --entrypoint sh \
    -v "${volume}:/src:ro" -v "${STAGING}:/out" \
    "${RESTIC_IMAGE}" -c "tar -czf /out/${out} -C /src . && chown $(id -u):$(id -g) /out/${out}"
  tar -tzf "${STAGING}/${out}" >/dev/null || fail "${out} is not a readable archive"
}

log "dumping the Authentik database"
docker compose exec -T authentik-db pg_dump -U authentik -Fc authentik > "${STAGING}/authentik.dump"
[[ -s "${STAGING}/authentik.dump" ]] || fail "authentik.dump is empty"
docker compose exec -T authentik-db pg_restore --list < "${STAGING}/authentik.dump" >/dev/null \
  || fail "authentik.dump is not a readable pg_dump archive"

PROJECT="$(docker compose config --format json | python3 -c 'import json,sys; print(json.load(sys.stdin)["name"])')"

log "archiving Authentik data"
archive_volume "${PROJECT}_authentik_data" authentik-data.tgz

for volume in ${BACKUP_EXTRA_VOLUMES:-}; do
  log "archiving extra volume ${volume}"
  archive_volume "${volume}" "volume-${volume}.tgz"
done

if [[ "${BACKUP_MODELS:-0}" == 1 ]]; then
  log "archiving model weights (BACKUP_MODELS=1)"
  archive_volume "${PROJECT}_ollama_models" ollama-models.tgz
fi

[[ -f .env ]] && cp .env "${STAGING}/env"

{
  echo "created:  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "host:     ${BACKUP_HOSTNAME:-$(hostname)}"
  echo "commit:   $(git rev-parse --verify -q HEAD || echo uncommitted)"
  echo "images:"
  docker compose config --images | sed 's/^/  /'
  echo "models:"
  grep -vE '^[[:space:]]*(#|$)' config/models.lock | sed 's/^/  /'
  echo "extra volumes: ${BACKUP_EXTRA_VOLUMES:-none}"
} > "${STAGING}/MANIFEST"

# A fixed path inside the container, so every snapshot has the same paths and restic
# can deduplicate against the previous one instead of treating each run as new data.
log "restic backup"
RESTIC_DOCKER_ARGS=(-v "${STAGING}:/backup/selfhostedllmstack:ro")
restic backup /backup/selfhostedllmstack --tag selfhostedllmstack --quiet

log "applying retention"
restic forget --tag selfhostedllmstack \
  --keep-hourly 24 --keep-daily 14 --keep-weekly 8 --keep-monthly 12 \
  --prune --quiet

log "backup done in $(fmt_duration $(( $(date +%s) - STARTED )))"
