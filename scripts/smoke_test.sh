#!/usr/bin/env bash
#
# Prove the stack works end to end, from the outside, the way its clients use it.
#
# Every container can be healthy while the thing people use is broken: a blueprint that
# did not apply, a forward-auth rule that lets everyone in, a model that was never
# pulled. This checks behaviour, not process state. CI runs it on every pull request,
# and the deploy workflow runs it after every deploy and rolls back if it fails.
#
# What it checks:
#   1. Ollama publishes no port on the host.
#   2. The pinned model is present at its pinned digest.
#   3. Unauthenticated requests to the LLM host are sent to Authentik.
#   4. A wrong service token is refused.
#   5. The service token gets through, and the model answers a real chat completion.
#   6. Model management endpoints are refused, even with valid credentials.
#   7. The internal listener serves the model and refuses management too.
#   8. A browser login as a member of llm-users reaches the model.
#   9. A browser login as a valid user outside llm-users does not.
#
# The two browser users are created for the test and deleted afterwards, so the test
# never needs a real person's password and keeps working after akadmin's is rotated.

set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
load_env

: "${LLM_EXTERNAL_URL:?}" "${AUTH_EXTERNAL_URL:?}" "${LLM_CLIENT_TOKEN:?}"
MODEL="$(grep -vE '^[[:space:]]*(#|$)' config/models.lock | head -n1 | awk '{print $1}')"
PORT="${GATEWAY_PORT:-8480}"

# Always talk to this host's gateway, whatever DNS says about the hostnames. The smoke
# test is about this deployment, not whatever the name currently resolves to.
CURL=(curl -sS --max-time 180 --connect-to "::127.0.0.1:${PORT}")

JARS="$(mktemp -d)"
trap 'rm -rf "${JARS}"; cleanup_users' EXIT

FAILED=0
pass() { printf '  ok    %s\n' "$1"; }
bad()  { printf '  FAIL  %s\n' "$1" >&2; FAILED=1; }
check() { # check <description> <expected> <actual>
  if [[ "$3" == "$2" ]]; then pass "$1"; else bad "$1 (expected $2, got $3)"; fi
}
status() { "${CURL[@]}" -o /dev/null -w '%{http_code}' "$@" || true; }

# Log in through the real browser flow and print the status of a request to the LLM
# host made with the resulting session. Drives Authentik's flow executor API, which is
# exactly what the login page's JavaScript does.
sso_status() {
  local user="$1" pass="$2" jar="${JARS}/$1" landed query exec to
  landed="$("${CURL[@]}" -c "${jar}" -b "${jar}" -L -o /dev/null -w '%{url_effective}' \
            "${LLM_EXTERNAL_URL}/api/version")"
  # The flow needs to know where to send the user afterwards. `next` is itself a URL
  # with a query string, so it is encoded twice: once as a value, once as `query`.
  query="$(python3 -c 'import sys, urllib.parse as u
q = u.parse_qs(u.urlparse(sys.argv[1]).query)
print(u.quote(u.urlencode({"next": q["next"][0]}), safe=""))' "${landed}")" || { echo 000; return; }
  exec="${AUTH_EXTERNAL_URL}/api/v3/flows/executor/default-authentication-flow/?query=${query}"

  "${CURL[@]}" -c "${jar}" -b "${jar}" -o /dev/null "${exec}"
  "${CURL[@]}" -c "${jar}" -b "${jar}" -L -o /dev/null -H 'Content-Type: application/json' \
    -d "{\"component\":\"ak-stage-identification\",\"uid_field\":\"${user}\"}" "${exec}"
  to="$("${CURL[@]}" -c "${jar}" -b "${jar}" -L -H 'Content-Type: application/json' \
        -d "$(python3 -c 'import json,sys; print(json.dumps({"component":"ak-stage-password","password":sys.argv[1]}))' "${pass}")" \
        "${exec}" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("to",""))')" || true
  [[ -n "${to}" ]] || { echo 000; return; }
  [[ "${to}" == http* ]] || to="${AUTH_EXTERNAL_URL}${to}"

  "${CURL[@]}" -c "${jar}" -b "${jar}" -L -o /dev/null "${to}" || true
  status -b "${jar}" "${LLM_EXTERNAL_URL}/api/version"
}

# Throwaway users with valid passwords, one in llm-users and one in no group at all.
# Created in the worker, not the server: `ak shell` is a full Django process, and the
# server runs close to its memory limit.
MEMBER="smoke-member"
OUTSIDER="smoke-outsider"
SMOKE_PASS="$(head -c 32 /dev/urandom | base64 | tr -d '/+=\n' | head -c 24)"
ak_shell() { docker compose exec -T authentik-worker ak shell -c "$1" >/dev/null 2>&1; }
cleanup_users() {
  ak_shell "from authentik.core.models import User
User.objects.filter(username__in=['${MEMBER}', '${OUTSIDER}']).delete()" || true
}
create_users() {
  ak_shell "from authentik.core.models import Group, User
for name in ['${MEMBER}', '${OUTSIDER}']:
    u, _ = User.objects.get_or_create(username=name, defaults={'name': 'smoke test'})
    u.set_password('${SMOKE_PASS}')
    u.save()
User.objects.get(username='${MEMBER}').groups.add(Group.objects.get(name='llm-users'))"
}

log "smoke test against ${LLM_EXTERNAL_URL} (model ${MODEL})"

# 1
# `docker compose port` prints "invalid IP:0" and exits 0 when nothing is published,
# so ask Docker for the port bindings directly.
bindings="$(docker inspect -f '{{json .HostConfig.PortBindings}}' "$(docker compose ps -q ollama)")"
if [[ "${bindings}" != "{}" && "${bindings}" != "null" ]]; then
  bad "ollama publishes ports on the host: ${bindings}"
else
  pass "ollama publishes no host port"
fi

# 2
if "$(dirname "$0")/assert_model.sh" >/dev/null; then pass "model digest matches models.lock"
else bad "model digest does not match models.lock"; fi

# 3
redirect="$("${CURL[@]}" -o /dev/null -w '%{http_code} %{redirect_url}' "${LLM_EXTERNAL_URL}/api/tags")"
if [[ "${redirect}" == "302 ${AUTH_EXTERNAL_URL}/"* ]]; then pass "unauthenticated request redirected to Authentik"
else bad "unauthenticated request was not redirected to Authentik (${redirect:0:80})"; fi

# 4
# Refused means Authentik answered and said no: a redirect to login or a 401. Anything
# else (a 404 from an outpost that does not know the host, a 502) is a broken gateway
# that happens to also refuse, and must not count as a pass.
code="$(status -u "svc-assistant:wrong-${RANDOM}" "${LLM_EXTERNAL_URL}/api/tags")"
if [[ "${code}" == 302 || "${code}" == 401 ]]; then pass "wrong service token refused (${code})"
else bad "wrong service token not refused by Authentik (got ${code})"; fi

# 5
check "service token accepted" 200 "$(status -u "svc-assistant:${LLM_CLIENT_TOKEN}" "${LLM_EXTERNAL_URL}/api/tags")"

started=$(date +%s%N)
reply="$("${CURL[@]}" -u "svc-assistant:${LLM_CLIENT_TOKEN}" -H 'Content-Type: application/json' \
  "${LLM_EXTERNAL_URL}/v1/chat/completions" \
  -d "{\"model\":\"${MODEL}\",\"temperature\":0,\"max_tokens\":16,\"messages\":[{\"role\":\"user\",\"content\":\"Reply with one word: ready\"}]}" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["choices"][0]["message"]["content"].strip())' 2>/dev/null)" || reply=""
elapsed_ms=$(( ($(date +%s%N) - started) / 1000000 ))
# The content is not asserted. A 1.5B model does not reliably follow "one word", and a
# test that fails on wording gets ignored. A non-empty completion through the whole
# chain is the thing being proven.
if [[ -n "${reply}" ]]; then pass "chat completion through SSO in ${elapsed_ms} ms: \"${reply:0:40}\""
else bad "chat completion through SSO returned nothing"; fi

# 6
for path in /api/pull /api/delete /api/create /api/copy /api/push; do
  check "management ${path} refused with valid credentials" 403 \
    "$(status -u "svc-assistant:${LLM_CLIENT_TOKEN}" -X POST -d '{}' "${LLM_EXTERNAL_URL}${path}")"
done

# 7
internal() { docker compose exec -T gateway wget -S -qO /dev/null "$@" 2>&1 | awk '/^  HTTP\//{print $2}' | tail -n1; }
check "internal listener serves the model API" 200 "$(internal http://127.0.0.1:8081/api/tags)"
check "internal listener refuses /api/pull" 403 "$(internal --post-data '{}' http://127.0.0.1:8081/api/pull)"

# 8, 9
if create_users; then
  check "browser login as a member of llm-users reaches the model" 200 "$(sso_status "${MEMBER}" "${SMOKE_PASS}")"
  # 000 means the login flow itself broke, which proves nothing about the policy.
  code="$(sso_status "${OUTSIDER}" "${SMOKE_PASS}")"
  case "${code}" in
    302|403) pass "browser login outside llm-users is refused (${code})" ;;
    200)     bad "a user outside llm-users reached the model" ;;
    *)       bad "browser login outside llm-users could not be tested (got ${code})" ;;
  esac
else
  bad "could not create the smoke test users"
fi

if [[ "${FAILED}" -ne 0 ]]; then
  echo "==> smoke test FAILED" >&2
  exit 1
fi
echo "==> smoke test PASSED"
