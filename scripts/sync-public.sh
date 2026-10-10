#!/bin/bash
# Mirror the committed source (minus the private server/) to the public repo, one commit per release.
#   scripts/sync-public.sh "<message>"
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
PUB="${FREEFLOW_PUBLIC_DIR:-$REPO/../freeflow-public}"
MSG="${1:?commit message}"
[ -d "$PUB/.git" ] || { echo "No public clone at $PUB"; exit 1; }
T=$(mktemp -d); git -C "$REPO" archive HEAD | tar -x -C "$T"; rm -rf "$T/server"
rsync -a --delete --exclude .git "$T/" "$PUB/"; rm -rf "$T"
cd "$PUB" && git add -A
if git diff --cached --quiet; then echo "public: nothing to sync"; exit 0; fi
git -c user.name="Jayden Ghiyam" -c user.email="jaydenghiyam@gmail.com" commit -qm "$MSG

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git push -q && echo "public: pushed $(git rev-parse --short HEAD)"
