#!/usr/bin/env bash
#
# Assert that the models Ollama has are the ones config/models.lock pins.
#
# The model equivalent of asserting a deploy's version moved. A deploy can succeed, the
# healthcheck can pass, and the stack can be serving a model nobody tested: pulled by
# hand, re-published upstream, or left behind by a restore. Exit 0 only when every
# pinned model is present at its pinned digest.

set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

tags="$(docker compose exec -T gateway wget -qO- http://ollama:11434/api/tags)" \
  || fail "could not reach Ollama through the gateway"

TAGS="${tags}" python3 - config/models.lock <<'PY'
import json, os, sys

have = {m["name"]: m["digest"] for m in json.loads(os.environ["TAGS"])["models"]}
status = 0
for line in open(sys.argv[1]):
    line = line.strip()
    if not line or line.startswith("#"):
        continue
    name, pinned = line.split()
    actual = have.pop(name, None)
    if actual is None:
        print(f"FAIL: {name} is pinned but not present", file=sys.stderr)
        status = 1
    elif actual != pinned:
        print(f"FAIL: {name} is at {actual[:12]}, pinned {pinned[:12]}", file=sys.stderr)
        status = 1
    else:
        print(f"OK: {name} at {actual[:12]}")
for name in have:
    # Not a failure: an operator may be trying a model out. It is flagged because
    # anything unpinned is also untested and absent from backups and DR.
    print(f"WARNING: {name} is present but not in config/models.lock", file=sys.stderr)
sys.exit(status)
PY
