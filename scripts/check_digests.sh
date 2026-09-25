#!/usr/bin/env bash
#
# Fail if any image this repository runs is referenced by tag alone.
#
# Covers every compose file and every `*_IMAGE=` in the scripts. One unpinned image is
# enough for a rebuild to ship something that was never tested, and it is an easy line
# to get wrong in review, so a machine checks it.

set -euo pipefail
cd "$(dirname "$0")/.."

status=0
while IFS= read -r ref; do
  file="${ref%%:*}"; rest="${ref#*:}"; line="${rest%%:*}"; image="${rest#*:}"
  if [[ "${image}" != *@sha256:[0-9a-f]* ]]; then
    echo "::error file=${file},line=${line}::image not pinned by digest: ${image}"
    status=1
  elif [[ ! "${image}" =~ @sha256:[0-9a-f]{64}$ ]]; then
    echo "::error file=${file},line=${line}::malformed digest: ${image}"
    status=1
  fi
done < <(
  grep -nE '^[[:space:]]*image:' compose*.yaml \
    | sed -E 's/^([^:]+:[0-9]+):[[:space:]]*image:[[:space:]]*/\1:/'
  grep -nE '^[A-Z_]*IMAGE="' scripts/*.sh \
    | sed -E 's/^([^:]+:[0-9]+):[A-Z_]*IMAGE="([^"]*)".*/\1:\2/'
)

[[ "${status}" -eq 0 ]] && echo "OK: every image is pinned by digest"
exit "${status}"
