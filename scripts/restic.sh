#!/usr/bin/env bash
#
# Run any restic command against this stack's repository, using the same pinned
# container and settings as the backup and drill scripts.
#
#   scripts/restic.sh init          # once, before the first backup
#   scripts/restic.sh snapshots
#   scripts/restic.sh check --read-data-subset=5%
#
# There is deliberately no automatic `init` in backup.sh. A typo in RESTIC_REPOSITORY
# would otherwise create a fresh empty repository and back up into it happily, and the
# first sign would be a restore that cannot find last month.

set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
load_env
restic "$@"
