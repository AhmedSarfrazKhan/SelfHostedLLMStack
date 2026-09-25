#!/usr/bin/env bash
#
# Deploy the checked-out commit: snapshot, deploy, prove it works, roll back if not.
#
# This is the whole deploy procedure, in one place, so running it by hand on the host
# and running it from .github/workflows/deploy.yml are the same thing. The reference
# host deliberately has no GitHub runner: the repository is public, a self-hosted
# runner on a public repository can be made to execute a stranger's code, and this
# host runs other services. So deploys there are this script, run by a person.
#
# Usage:
#   scripts/deploy.sh --pull   fetch main, deploy it; roll back to what was running
#   scripts/deploy.sh          deploy HEAD as checked out; roll back to HEAD~1
#
# On failure it runs rollback.sh, which restores the Authentik database from the
# snapshot taken here AND checks out the previous commit, and leaves the checkout on a
# detached HEAD at that commit. Fix forward in a pull request, then `git checkout main`.

set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
load_env

[[ -s .env ]] || fail ".env is missing"
if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
  fail "tracked files have local changes. Deploy commits, not working trees."
fi

if [[ "${1:-}" == --pull ]]; then
  PREV_SHA="$(git rev-parse HEAD)"
  log "fetching main"
  git pull --ff-only --quiet origin main
else
  PREV_SHA="$(git rev-parse HEAD~1)"
fi
log "deploying $(git rev-parse --short HEAD), rollback target $(git rev-parse --short "${PREV_SHA}")"

# A snapshot of the database as it is right now, taken before anything changes. It is
# local to the host on purpose: a rollback must not depend on the backup repository
# being reachable at the moment something has already gone wrong.
SNAP_DIR="${REPO_ROOT}/backups/pre-deploy"
mkdir -p "${SNAP_DIR}"
SNAPSHOT="${SNAP_DIR}/pre-deploy-$(date +%Y%m%d-%H%M%S).dump"
log "snapshotting the Authentik database"
docker compose exec -T authentik-db pg_dump -U authentik -Fc authentik > "${SNAPSHOT}"
[[ -s "${SNAPSHOT}" ]] || fail "${SNAPSHOT} is empty. Refusing to deploy without a usable snapshot."
docker compose exec -T authentik-db pg_restore --list < "${SNAPSHOT}" >/dev/null \
  || fail "${SNAPSHOT} is not a readable archive. Refusing to deploy."
# Keep the last five, so the disk cannot fill one deploy at a time.
find "${SNAP_DIR}" -name 'pre-deploy-*.dump' -printf '%T@ %p\n' | sort -rn | tail -n +6 \
  | cut -d' ' -f2- | xargs -r rm --

# Every step is chained with && on purpose. This used to be a function called as
# `if deploy; then`, and bash switches `set -e` off inside anything evaluated as an
# `if` condition, silently, all the way down. So a failed step was ignored, only the
# last command counted, and a deploy whose model check had failed reported "verified".
# Found by the first real run of this script.
deploy() {
  log "pulling digest-pinned images" &&
  docker compose pull --quiet &&
  log "starting the stack" &&
  docker compose up -d --wait --wait-timeout 600 &&
  # Caddy reads its config once, at start, and its admin API (which could reload it)
  # is off on purpose. `up -d` only recreates a container whose compose definition
  # changed, not one whose mounted config changed, so without this a Caddyfile change
  # deploys "successfully" and never takes effect. A restart is a second or two.
  log "restarting the gateway so it loads the deployed config" &&
  docker compose restart gateway >/dev/null &&
  docker compose up -d --wait --wait-timeout 120 gateway &&
  "$(dirname "$0")/apply_blueprint.sh" &&
  "$(dirname "$0")/pull_model.sh" &&
  "$(dirname "$0")/smoke_test.sh"
}

if deploy; then
  log "deploy of $(git rev-parse --short HEAD) verified"
  exit 0
fi

echo "==> deploy FAILED, rolling back database and code together" >&2
"$(dirname "$0")/rollback.sh" "${SNAPSHOT}" "${PREV_SHA}"
exit 1
