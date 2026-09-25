# Runbook

What to do when something is wrong, and how to make routine changes without making
something wrong. Commands run from the repository checkout on the host.

## First, look

```bash
docker compose ps                      # every service should say (healthy)
scripts/smoke_test.sh                  # the stack, checked the way clients use it
docker compose logs --tail 100 <service>
free -m                                # this host has little spare memory
```

`smoke_test.sh` is the fastest way to find out which layer is broken. Each check
exercises one layer, so the first failing line usually names the problem.

## Symptoms

### Requests to the LLM host redirect to login in a loop

The session cookie is being set for one hostname and requested on another. Check that
`LLM_EXTERNAL_URL` in `.env` matches exactly what the browser uses, scheme and port
included, then recreate the containers so they see the new value and apply the
blueprint:

```bash
docker compose up -d
scripts/apply_blueprint.sh
```

A restart alone is not enough. Authentik does not re-apply blueprints on restart.

### 502 from the LLM host

Caddy cannot reach Ollama or Authentik. `docker compose ps` shows which. If Ollama is
restarting, check `docker compose logs ollama` for an out-of-memory kill, and see the
next section.

### Slow responses, or Ollama restarting

This host runs other services, and memory is the constraint. In order:

1. `docker stats --no-stream`. Is Ollama at its `mem_limit`? Is the host swapping (`free -m`)?
2. Only one model should ever be loaded: `docker compose exec ollama ollama ps`. A second
   one means someone pulled a model by hand; `scripts/assert_model.sh` will flag it.
3. Long prompts are slow on CPU before generation even starts: about 140 tokens a
   second to read the prompt, about 11 a second to generate, on the development host.
   A client sending an 8,000 token prompt waits about a minute for the first token. That
   is the hardware, not a fault.

### Authentik server killed for memory

It runs at about 700 MiB of its 1 GiB limit, higher during migrations after an upgrade.
If `docker compose ps` shows it restarting after an upgrade, raise `mem_limit` for
`authentik-server` in `compose.yaml` in a pull request. Do not remove the limit: an
unlimited service on a shared host is how one service's bad day becomes every service's.

### "model management is not available through the gateway"

Working as intended. Models change through `config/models.lock`, see below.

### `pull_model.sh` says the model moved upstream

The registry is serving different weights under the same tag. The running model is
untouched, because the check happens before the pull. Nothing is broken. To take the
new weights, treat it as a model change (below). To keep the old ones, do nothing; the
local copy stays as long as the `ollama_models` volume does.

## Routine changes

Every change goes through a pull request so CI brings the full stack up with it. Then
the deploy workflow applies it and rolls back if the smoke test fails.

### Update an image

```bash
docker pull ghcr.io/goauthentik/server:<new version>
docker buildx imagetools inspect ghcr.io/goauthentik/server:<new version> \
  --format '{{json .Manifest.Digest}}'
```

Put `tag@digest` in `compose.yaml`, open a pull request. Read the upstream release
notes first for Authentik: its database migrations run on startup and cannot be
reversed except by restoring the pre-deploy dump, which `rollback.sh` does.

### Change the model

Get the manifest digest from the registry:

```bash
curl -s -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
  https://registry.ollama.ai/v2/library/<name>/manifests/<tag> | sha256sum
```

Update `config/models.lock`, check the new model's resident memory fits in
`OLLAMA_MEM_LIMIT`, open a pull request. After deploy, remove the old model so it is
not taking disk: `docker compose exec ollama ollama rm <old>`.

### Give someone access to the model

Add them to the `llm-users` group in the Authentik admin UI
(`AUTH_EXTERNAL_URL/if/admin/`). Group membership is data, backed up with the
database. The rule that only that group gets in is code, in the blueprint.

### Rotate the service token

Put a new value in `LLM_CLIENT_TOKEN` in `.env`, then
`docker compose up -d && scripts/apply_blueprint.sh`. Both steps are needed: the first
gives the containers the new value, the second writes it, because Authentik does not
re-apply blueprints on restart. Update every remote client at the same time; the old token stops working
immediately.

### Rotate the akadmin password

In the Authentik UI. `AUTHENTIK_BOOTSTRAP_PASSWORD` is only read on the very first
start, so changing it in `.env` does nothing. The smoke test does not use akadmin, so it
keeps working after rotation.

## Exposing it beyond this host

The gateway listens on `127.0.0.1:8480` and does not do TLS. To reach it from
elsewhere, put something in front that terminates TLS: an existing reverse proxy on the
host, or a tunnel. Then:

1. Set the four hostname values in `.env` to the real names, with `https://`.
2. `docker compose up -d && scripts/apply_blueprint.sh` so Caddy and Authentik pick them up.
3. Run `smoke_test.sh`. It connects to the local gateway directly, whatever DNS says, so
   it tests this host rather than whatever the name points at.

Do not publish the gateway on `0.0.0.0` without TLS. The login form and the service
token would cross the network in clear text.

## Backups

- Timer: `deploy/systemd/inference-backup.timer`, every six hours.
- Drill: `deploy/systemd/inference-restore-drill.timer`, weekly. History in
  `backups/drill-history.log`.
- Check both are actually firing: `systemctl list-timers 'inference-*'`.
- A failed drill is an incident, not a warning. See `docs/disaster-recovery.md`.
