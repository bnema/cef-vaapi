#!/usr/bin/env bash
set -euo pipefail

# CEF Vaapi Runner Setup for Igor
# Run this from the project root after cloning on igor:
#   git clone https://github.com/bnema/cef-vaapi.git
#   bash infra/igor/setup-runner.sh
#
# Prerequisites: GITHUB_PAT env var with repo:admin access

IGOR_HOST="${1:-web-public@igor}"
GITHUB_REPO="bnema/cef-vaapi"

log() { printf '[cef-runner] %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

command -v ssh >/dev/null || die "ssh required"
[ -n "${GITHUB_PAT:-}" ] || die "GITHUB_PAT env var required (repo:admin scope)"

# Copy project files to igor
log "Copying runner files to $IGOR_HOST..."
ssh "$IGOR_HOST" "mkdir -p ~/cef-vaapi-setup"
scp -r .github/actions-runner/ "$IGOR_HOST:~/cef-vaapi-setup/"
scp infra/igor/cef-runner.container "$IGOR_HOST:~/cef-vaapi-setup/"

# Execute setup remotely
ssh -tt "$IGOR_HOST" bash -s << 'ENDSSH'
set -euo pipefail

log() { printf '[cef-runner] %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

cd ~/cef-vaapi-setup

log "Building runner container image..."
podman build -t localhost/cef-runner:latest -f Containerfile .

log "Creating volumes..."
podman volume create cef-build-cache 2>/dev/null || true

log "Setting up Quadlet..."
mkdir -p ~/.config/containers/systemd ~/.local/share/cef-runner/_work
cp cef-runner.container ~/.config/containers/systemd/

log "Creating .env file for runner..."
cat > ~/.config/containers/cef-runner.env << ENVEOF
RUNNER_NAME=igor-cef-builder
RUNNER_LABELS=self-hosted,cef-builder,x64,linux
RUNNER_REPO_URL=https://github.com/bnema/cef-vaapi
GITHUB_PAT=${GITHUB_PAT}
ENVEOF
chmod 600 ~/.config/containers/cef-runner.env

log "Reloading systemd and starting runner service..."
systemctl --user daemon-reload
systemctl --user enable --now cef-runner.service

log "Checking runner status..."
sleep 3
systemctl --user status cef-runner.service --no-pager

log "Done! Runner should appear at https://github.com/bnema/cef-vaapi/settings/actions/runners"
ENDSSH
