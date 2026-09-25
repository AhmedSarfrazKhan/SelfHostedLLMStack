#!/usr/bin/env bash
#
# House rules for the text in this repository, checked rather than remembered.
#
#   1. No em dashes or en dashes anywhere. Plain hyphens, commas and full stops.
#   2. No term from the denylist appears in any tracked file.
#
# The denylist is for names that must never be published: client names, internal
# hostnames, anything from other work on the same machine. It cannot be committed,
# because a public file listing them would be the leak. So it comes from a gitignored
# .denylist locally and from the TEXT_DENYLIST secret in CI, one term per line,
# matched case-insensitively. When neither is present the check says so rather than
# passing silently.

set -euo pipefail
cd "$(dirname "$0")/.."

status=0
mapfile -t files < <(git ls-files --cached --others --exclude-standard)

if grep -nP '[\x{2013}\x{2014}]' "${files[@]}" 2>/dev/null; then
  echo "::error::em or en dash found (lines above). Use a hyphen, comma or full stop."
  status=1
fi

terms=""
[[ -f .denylist ]] && terms="$(cat .denylist)"
[[ -n "${TEXT_DENYLIST:-}" ]] && terms="${terms}"$'\n'"${TEXT_DENYLIST}"
terms="$(printf '%s\n' "${terms}" | grep -vE '^[[:space:]]*(#|$)' || true)"

if [[ -z "${terms}" ]]; then
  echo "WARNING: no denylist configured (.denylist or TEXT_DENYLIST); skipped name check"
else
  # -F: terms are literal strings, not patterns. Matches are reported by file and line
  # only, so the log of a public CI run does not print the term it was guarding.
  if hits="$(grep -niF -f <(printf '%s\n' "${terms}") "${files[@]}" 2>/dev/null | cut -d: -f1,2)"; then
    printf '%s\n' "${hits}" | sed 's/^/::error::denylisted term at /'
    status=1
  fi
fi

[[ "${status}" -eq 0 ]] && echo "OK: text checks passed"
exit "${status}"
