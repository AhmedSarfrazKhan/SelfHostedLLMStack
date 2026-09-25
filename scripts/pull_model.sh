#!/usr/bin/env bash
#
# Pull every model in config/models.lock, but only if the registry still serves the
# digest that is pinned there.
#
# The check has to happen BEFORE the pull. `ollama pull` replaces the local copy of a
# tag with whatever the registry serves now, so checking afterwards only tells you that
# the tested weights are already gone. If upstream re-published the tag, this stops,
# and the model that is running keeps running.
#
# Usage:  pull_model.sh

set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
load_env

REGISTRY="${OLLAMA_REGISTRY:-https://registry.ollama.ai}"
MANIFEST="$(mktemp)"
trap 'rm -f "${MANIFEST}"' EXIT

# name:tag -> the registry manifest URL. Bare names live under library/.
manifest_url() {
  local name="${1%%:*}" tag="${1##*:}"
  [[ "${name}" == */* ]] || name="library/${name}"
  printf '%s/v2/%s/manifests/%s\n' "${REGISTRY}" "${name}" "${tag}"
}

grep -vE '^[[:space:]]*(#|$)' config/models.lock | while read -r model pinned; do
  log "checking ${model} upstream"
  # If the registry cannot be reached, nothing is pulled: weights that cannot be
  # checked are never fetched. The local copy is then verified against the pin by
  # assert_model.sh below, which is what decides whether this script passes. So an
  # offline host with the right model deploys, and one without it fails.
  # Hashed from a file, byte for byte: capturing the body in a variable would strip
  # any trailing newline and silently change the digest.
  if ! curl -fsSL --retry 3 --retry-delay 2 --max-time 30 -o "${MANIFEST}" \
        -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
        "$(manifest_url "${model}")"; then
    echo "WARNING: could not reach ${REGISTRY} to check ${model}; not pulling, verifying the local copy" >&2
    continue
  fi
  remote="$(sha256sum "${MANIFEST}" | cut -d' ' -f1)"

  if [[ "${remote}" != "${pinned}" ]]; then
    echo "FAIL: ${model} moved upstream." >&2
    echo "      pinned   ${pinned}" >&2
    echo "      registry ${remote}" >&2
    echo "      Not pulling, because a pull would overwrite the tested copy. To accept the" >&2
    echo "      new weights, update config/models.lock in a pull request so CI tests them." >&2
    exit 1
  fi

  log "pulling ${model} (${pinned:0:12})"
  docker compose exec -T ollama ollama pull "${model}" </dev/null >/dev/null 2>&1 \
    || fail "ollama pull ${model} failed"
done

"$(dirname "$0")/assert_model.sh"
