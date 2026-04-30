#!/bin/bash
set -euo pipefail

RUNNER_HOME="${RUNNER_HOME:-/runner}"
mkdir -p "$RUNNER_HOME"

# Populate the persistent runner volume on first start. Keeping the runner
# registration in a mounted volume means a one-time RUNNER_TOKEN is enough for
# normal service restarts; a long-lived PAT is optional, not required.
if [[ ! -x "$RUNNER_HOME/config.sh" ]]; then
  echo "Initializing runner home at $RUNNER_HOME..."
  cp -a /opt/actions-runner/. "$RUNNER_HOME/"
fi

cd "$RUNNER_HOME"

# Configure only once. If .runner exists, do not require any token at startup.
if [[ ! -f .runner ]]; then
  if [[ -n "${RUNNER_TOKEN:-}" ]]; then
    REG_TOKEN="$RUNNER_TOKEN"
  elif [[ -n "${GITHUB_PAT:-}" ]]; then
    echo "Fetching runner registration token via PAT..."
    REG_TOKEN=$(curl -fsSL -X POST \
      -H "Authorization: Bearer ${GITHUB_PAT}" \
      -H "Accept: application/vnd.github+json" \
      "https://api.github.com/repos/bnema/cef-vaapi/actions/runners/registration-token" \
      | jq -r '.token')
  else
    echo "ERROR: runner is not configured and neither RUNNER_TOKEN nor GITHUB_PAT is set." >&2
    echo "Provide a one-time RUNNER_TOKEN for first registration, or GITHUB_PAT for auto-registration." >&2
    exit 1
  fi

  if [[ -z "${REG_TOKEN:-}" || "$REG_TOKEN" == "null" ]]; then
    echo "ERROR: failed to obtain a GitHub runner registration token." >&2
    exit 1
  fi

  ./config.sh \
    --url "$RUNNER_REPO_URL" \
    --token "$REG_TOKEN" \
    --name "$RUNNER_NAME" \
    --labels "$RUNNER_LABELS" \
    --work _work \
    --unattended \
    --replace
fi

unset RUNNER_TOKEN REG_TOKEN GITHUB_PAT
exec ./run.sh
