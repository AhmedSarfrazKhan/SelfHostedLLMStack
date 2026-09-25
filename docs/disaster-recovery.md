# Disaster recovery

What can be lost, how fast it comes back, and which of those claims have actually been
tested. A recovery plan that has never been run is a guess. Every number on this page
was measured, and the page says where.

## Targets

| | Target | Basis |
|---|---|---|
| **RPO** (data loss) | 6 hours | `inference-backup.timer` runs every six hours |
| **RTO** (clean host to serving) | 15 minutes | Measured 11m09s, below |
| **Drill limit** | 15 minutes | `DRILL_MAX_SECONDS=900`, enforced by `restore_drill.sh` |

What the RPO covers: users, groups, group membership, tokens and anything else
changed in Authentik since the last backup. The SSO configuration itself is code (the
blueprint) and is never lost. The model is re-downloaded and verified against its pin.
In practice the data that changes on this stack is who has access, so six hours is
generous. When an assistant runs on top and adds its own state through
`BACKUP_EXTRA_VOLUMES`, revisit this: conversation history changes far faster than a
user list.

## What you need from outside the machine

Only two things. Keep both somewhere that is not this host, and not only in one place.

1. **The restic repository location and credentials**, e.g. the S3 URL and keys.
2. **The restic repository password.** Without it every snapshot is unreadable, by
   design.

Everything else comes out of the backup, including `.env` and therefore
`AUTHENTIK_SECRET_KEY` and the service token. That is a deliberate trade: the restic
repository is encrypted, and one secret to protect is easier than six.

Plus this repository, which is public.

## Recovery procedure

On a host with Docker and about 20 GB free:

```bash
git clone <this repository> SelfHostedLLMStack && cd SelfHostedLLMStack
git checkout <commit from the snapshot's MANIFEST, or main>
mkdir -p secrets && (umask 077; cat > secrets/restic-password)   # paste, then Ctrl-D

RESTIC_REPOSITORY=s3:https://... \
RESTIC_PASSWORD_FILE=./secrets/restic-password \
AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... \
  scripts/recover.sh              # or: scripts/recover.sh <snapshot id>
```

`recover.sh` restores the snapshot, restores `.env` from it, pulls the pinned images,
restores the database and volumes, starts the stack, pulls the pinned model (refusing
if upstream moved) and finishes with the full smoke test. It refuses to run if the
stack's database volume already exists, so it cannot overwrite a working install.

If the new host has different hostnames, edit the four hostname values in `.env` after
the restore and run `docker compose up -d && scripts/apply_blueprint.sh`.

## Rehearsal: full recovery from nothing

Performed on the development host on 2026-09-25. Before starting, a marker user was
created in Authentik and a backup taken. Then:

```bash
docker compose down -v --rmi all     # containers, volumes, images: gone
rm .env                              # configuration: gone
```

This leaves the host in the state of a clean one, except that Docker is installed and
the repository is checked out. Recovery, with the restic settings passed on the
command line as above:

| Step | Elapsed |
|---|---|
| Restore snapshot, restore `.env` | 0m01s |
| Pull images (about 3.5 GB compressed) | 7m51s |
| Start PostgreSQL, restore database | 0m24s |
| Restore volumes | 0m01s |
| Start the stack, wait for healthy | 0m43s |
| Pull and verify the pinned model (986 MB) | 1m51s |
| Smoke test, all 15 checks | 0m18s |
| **Total** | **11m09s** |

Afterwards the marker user was present (so the database came from the backup, not from
the blueprint recreating defaults) and the restored `.env` was byte-identical to the
original.

The rehearsal found one real problem, fixed before this page was written. The first
attempt stopped immediately, because with `.env` gone nothing said where the backups
were, and the script failed with a bare shell error. It now says what to pass. That is
exactly the kind of gap that only appears on a clean host, and the reason to rehearse on
one.

### What the numbers depend on

Downloads are 87% of the total, measured on a connection doing about 8 MB/s. A faster
link shortens it; a registry outage stops it entirely. Two mitigations if that matters
for your deployment:

- `BACKUP_MODELS=1` puts the model weights in the backup, removing the model download.
- A local registry mirror, or `docker save` of the pinned images kept next to the backups,
  removes the image download. Not implemented here.

## Rehearsal: data restore, weekly

`restore_drill.sh` runs weekly from `inference-restore-drill.timer`. It restores the
latest snapshot into a throwaway PostgreSQL with no network, checks the SSO
configuration is in it, checks every archive is readable, and fails if the whole thing
exceeds `DRILL_MAX_SECONDS`. First run on the development host: 10 seconds. Every run
is appended to `backups/drill-history.log`.

It also runs in CI on every pull request, against a backup taken moments earlier in the
same job, so a change that breaks backup or restore cannot merge.

What the weekly drill does **not** prove: that the images and model can still be
downloaded, or that Authentik starts on the restored data. The full rehearsal above
does. Repeat it after any Authentik major upgrade, and at least quarterly.

## Rehearsal: a bad deploy

Performed on the development host on 2026-09-26. A deliberately bad release was
committed locally (never pushed): the Caddyfile with the model-management filter removed
from the internal listener, and the blueprint with an extra marker group, so the
release changed both behaviour and data. Then `scripts/deploy.sh`. A watcher polled the
database for the marker group throughout:

| Time | Marker group | What happened |
|---|---|---|
| 03:28:21 | 0 | Pre-deploy snapshot taken |
| 03:28:29 | 1 | Bad release deployed, blueprint applied: data changed |
| | | Smoke test: `internal listener refuses /api/pull (expected 403, got 400)` |
| 03:29:30 | 0 | Database restored from the snapshot, previous commit checked out |
| | | Gateway restarted on the previous config, rollback smoke test passed |

Getting to that result found four bugs, all fixed before this rehearsal passed:

- A deploy of a changed Caddyfile reported "verified" while the gateway kept running the
  old one. Caddy reads its config once at start and `docker compose up -d` does not
  restart a container whose mounted file changed. Deploy and rollback now restart it.
- Single-file and leaf-directory bind mounts go stale after `git pull` or `git checkout`,
  because git replaces files rather than editing them. The blueprint directory was empty
  inside the worker. Mounts are now parent directories, and the smoke test compares the
  config the containers see with the checkout.
- The blueprint check accepted objects left over from earlier applies even when the
  current apply failed. It now requires the apply itself to succeed.
- The deploy steps ran inside a function called from `if`, where bash silently disables
  `set -e`, so only the last step's result counted. A failed model check was ignored
  and the deploy reported "verified". The steps are now chained explicitly.

## Scenarios

| Scenario | Action | Loss |
|---|---|---|
| Ollama container crashes | Restarts itself (`restart: unless-stopped`) | None |
| Bad deploy | `deploy.sh` runs `rollback.sh`: database, code and gateway config back together. Rehearsed, see below | None |
| Model deleted or replaced by hand | `scripts/pull_model.sh` | None |
| Model tag moved upstream | Nothing breaks; `pull_model.sh` refuses to pull | None |
| Authentik database corrupted | `docker compose down -v`, then `recover.sh` | Up to RPO |
| Host lost | New host, `recover.sh` | Up to RPO |
| Restic password lost | None possible. That is what the password is for | Everything |
| `.env` lost, host fine | `restic restore latest --include env`, or `recover.sh` on a wiped stack | None |

## Not tested

Stated plainly, so nobody reads this page as covering more than it does:

- Recovery onto a different machine. The rehearsal wiped and rebuilt the same host.
- Recovery from an off-host repository. The rehearsal used a local repository; an S3
  or SFTP repository adds only the transfer time of a few megabytes, but it has not
  been timed.
- The GPU path. See `docs/gpu.md`.
