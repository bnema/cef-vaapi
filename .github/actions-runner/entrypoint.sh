#!/bin/bash
set -e

# If a one-time RUNNER_TOKEN is provided, use it directly
# Otherwise, if GITHUB_PAT is set, obtain a fresh registration token via API
if [ -n "$RUNNER_TOKEN" ]; then
  REG_TOKEN="$RUNNER_TOKEN"
elif [ -n "$GITHUB_PAT" ]; then
  echo "Fetching runner registration token via PAT..."
  REG_TOKEN=$(curl -s -X POST \
    -H "Authorization: Bearer ${GITHUB_PAT}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/bnema/cef-vaapi/actions/runners/registration-token" \
    | jq -r '.token')
  if [ -z "$REG_TOKEN" ] || [ "$REG_TOKEN" = "null" ]; then
    echo "ERROR: Failed to obtain registration token. Check GITHUB_PAT permissions."
    exit 1
  fi
else
  echo "ERROR: Neither RUNNER_TOKEN nor GITHUB_PAT is set."
  echo "Provide RUNNER_TOKEN (one-time) or GITHUB_PAT (for auto-registration)."
  exit 1
fi

# Configure the runner if not already configured
if [ ! -f /home/runner/.runner ]; then
  ./config.sh \
    --url "$RUNNER_REPO_URL" \
    --token "$REG_TOKEN" \
    --name "$RUNNER_NAME" \
    --labels "$RUNNER_LABELS" \
    --unattended \
    --replace
fi

# Clean up token from environment
unset RUNNER_TOKEN REG_TOKEN GITHUB_PAT

# Start the runner in foreground
exec ./run.sh
