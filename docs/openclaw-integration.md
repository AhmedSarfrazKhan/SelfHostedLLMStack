# Running an assistant on this stack

The next project on this stack is a personal assistant built on OpenClaw. It does not
exist in this repository yet. This page records the decisions made here so that it can
be added without reopening them, and the contract the assistant can rely on.

Anything below that describes OpenClaw's own configuration is intent, to be checked
against OpenClaw's documentation when the assistant is built. The stack side is built
and tested.

## The contract

| What the assistant gets | Where | Tested by |
|---|---|---|
| An OpenAI-compatible API, no SSO | `http://gateway:8081/v1` on the `inference-llm` network | `smoke_test.sh` check 7 |
| Ollama's native API, same place | `http://gateway:8081/api/...` | `smoke_test.sh` check 7 |
| The same API from another machine | `LLM_EXTERNAL_URL`, HTTP Basic as `svc-assistant` | `smoke_test.sh` checks 4 and 5 |
| A model that supports tool calling | `config/models.lock` | CI integration job |
| Its state in every backup and drill | `BACKUP_EXTRA_VOLUMES` | `restore_drill.sh` |
| SSO for its own web UI | a second provider in the blueprint | not yet, see below |

What it does not get, on purpose:

- **Direct access to Ollama.** Ollama is on the `backend` network only. Everything goes
  through the gateway, which refuses model management (`/api/pull`, `/api/delete` and the
  rest). An agent that can run tools can be talked into calling any endpoint it can
  reach, and deleting the model is one HTTP request.
- **The Docker socket.** Holding the socket is holding root on the host. If the assistant
  needs sandboxed tool execution, that goes in its own design, not in a mount.

## Joining the network

In the assistant's own compose file:

```yaml
services:
  assistant:
    networks: [inference-llm]
    environment:
      # OpenAI-compatible base URL. Ollama ignores the key, but most clients insist on one.
      OPENAI_BASE_URL: http://gateway:8081/v1
      OPENAI_API_KEY: unused

networks:
  inference-llm:
    external: true
```

The network has a fixed name (`name: inference-llm` in `compose.yaml`) so another
project can join it without knowing this project's name. That name is a public
interface now. Renaming it breaks the assistant, so treat it like an API.

## Why the internal listener has no SSO

A process on this host, on a network only this stack creates, is already inside the
boundary SSO protects. Putting it through forward auth would add a token to rotate
and a failure mode (Authentik down means the assistant is down) without keeping anyone
out who is not already in. The listener is not published to the host, and the smoke
test checks that Ollama publishes nothing either.

If the assistant ever runs somewhere else, it uses the external URL with the
`svc-assistant` app password, which is in `.env` as `LLM_CLIENT_TOKEN`. Rotating it is
editing that value, then `docker compose up -d && scripts/apply_blueprint.sh`.

## Model choice

`qwen2.5:1.5b` supports tool calling and fits the memory this machine has spare. It is
also small. Expect it to pick the wrong tool, or skip a tool it should use, noticeably
more often than a larger model would. Two things follow for the assistant's design:

- Keep its tool set small and its tool descriptions short. Every tool schema is prompt
  tokens, and prompt processing on this CPU is about 140 tokens a second, so a 3,000
  token system prompt costs about 20 seconds before the first word of any reply.
- Check `OLLAMA_CONTEXT_LENGTH` (8192 here) against what the assistant actually sends.
  Ollama truncates silently when a prompt is longer, and truncation looks like a model
  that ignores its instructions.

A model change is a change to `config/models.lock` in a pull request, which means CI
tests it before it can merge. The same process covers a move to the GPU path.

## Memory budget

Measured on the development host (12 GB total, about 5 GB free before this stack):

| Service | Limit | Measured |
|---|---|---|
| Ollama, model loaded | 3 GiB | 1.3 GiB |
| Authentik server | 1 GiB | 0.7 GiB |
| Authentik worker | 1 GiB | 0.3 GiB |
| Authentik PostgreSQL | 256 MiB | 80 MiB |
| Caddy | 128 MiB | 11 MiB |
| **Stack total** | | **about 2.3 GiB** |

That leaves the assistant roughly 1.5 to 2 GiB on this host before anything swaps. Give
its container a `mem_limit`, so if it grows, the kernel kills the assistant rather than
Ollama or the database.

## SSO for the assistant's web UI

When the assistant has a browser UI, protect it the same way the model is protected:

1. Add a second `proxyprovider` and `application` to
   `config/authentik/blueprints/selfhostedllmstack.yaml`, bound to a group, and add the
   provider to the embedded outpost's `providers` list.
2. Add a site block to `config/caddy/Caddyfile` with the same `forward_auth` stanza,
   proxying to the assistant on the `inference-llm` network.
3. Add the new host to `smoke_test.sh`: redirected when anonymous, reachable for the
   group, refused outside it.

The third step is the one that matters. An access rule that is not tested is a rule
that stops working the first time somebody refactors the Caddyfile.

## Backups

Set `BACKUP_EXTRA_VOLUMES` in `.env` to the assistant's state volume, for example
`assistant_state`. From then on `backup.sh` archives it into every snapshot,
`restore_drill.sh` checks the archive is readable and includes it in the timing, and
`recover.sh` restores it on a clean host. No script changes.

An assistant's state (memory, conversation history, credentials for the channels it
talks on) is more sensitive than anything else in this stack. The restic repository is
encrypted, but whoever holds its password can read all of it. Decide who that is
before the assistant stores anything real.
