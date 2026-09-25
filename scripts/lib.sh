#!/usr/bin/env bash
#
# Shared by every script in this directory. Sourced, never run.
#
# Two things live here so they cannot drift between scripts: how .env is read, and how
# restic is invoked.

# Images used by scripts rather than by compose.yaml. Pinned for the same reason, and
# checked by scripts/check_digests.sh like the compose images are.
RESTIC_IMAGE="restic/restic:0.19.1@sha256:136600b6ff6843d61d355f7f71f460a166429f35de6fd11b568fece3c9a4d510"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}" || exit 1

log()  { printf '==> %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# Read .env without `source`. Compose accepts unquoted values with spaces
# (BACKUP_EXTRA_VOLUMES=a b) and bash does not, so sourcing the file either breaks or,
# worse, runs part of a value as a command. Variables already set in the environment
# win, so a CI job or systemd unit can override any single value.
load_env() {
  local file="${REPO_ROOT}/.env" key value
  [[ -f "${file}" ]] || return 0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ "${line}" =~ ^[[:space:]]*(#|$) ]] && continue
    key="${line%%=*}"
    value="${line#*=}"
    [[ "${key}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    value="${value%\"}"; value="${value#\"}"
    value="${value%\'}"; value="${value#\'}"
    if [[ -z "${!key+x}" ]]; then
      export "${key}=${value}"
    fi
  done < "${file}"
}

# Absolute path for a possibly relative one, resolved against the repository root.
abspath() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *)  printf '%s/%s\n' "${REPO_ROOT}" "${1#./}" ;;
  esac
}

# restic, run from a pinned container so the host needs nothing installed and every
# machine runs the same restic. Extra `docker run` arguments (usually -v mounts) go in
# the RESTIC_DOCKER_ARGS array before calling.
#
# A local repository path is bind-mounted at the same absolute path, so the path that
# appears in logs is the real one on the host.
RESTIC_DOCKER_ARGS=()
restic() {
  : "${RESTIC_REPOSITORY:?RESTIC_REPOSITORY is not set}"
  : "${RESTIC_PASSWORD_FILE:?RESTIC_PASSWORD_FILE is not set}"

  local repo="${RESTIC_REPOSITORY}" pwfile args=()
  pwfile="$(abspath "${RESTIC_PASSWORD_FILE}")"
  [[ -s "${pwfile}" ]] || fail "restic password file ${pwfile} is missing or empty"

  repo="${repo#local:}"
  if [[ "${repo}" != *:* ]]; then
    repo="$(abspath "${repo}")"
    mkdir -p "${repo}"
    args+=(-v "${repo}:${repo}")
  fi

  docker run --rm -i \
    --user "$(id -u):$(id -g)" \
    --hostname "${BACKUP_HOSTNAME:-$(hostname)}" \
    -e RESTIC_REPOSITORY="${repo}" \
    -e RESTIC_PASSWORD_FILE=/run/secrets/restic-password \
    -e RESTIC_CACHE_DIR=/tmp/restic-cache \
    -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY \
    -v "${pwfile}:/run/secrets/restic-password:ro" \
    "${args[@]}" "${RESTIC_DOCKER_ARGS[@]}" \
    "${RESTIC_IMAGE}" "$@"
}

# The postgres image compose.yaml pins, so the drill restores into the exact server
# version production runs.
postgres_image() {
  docker compose config --images | grep -m1 '^postgres:' \
    || fail "could not find the postgres image in compose.yaml"
}

# Seconds as 3m07s.
fmt_duration() { printf '%dm%02ds' $(( $1 / 60 )) $(( $1 % 60 )); }
