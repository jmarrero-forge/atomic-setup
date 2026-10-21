#!/bin/bash
# Log opencode in to GitHub Copilot and store the result as a podman secret,
# for agents that pass it as OPENCODE_AUTH_CONTENT (opencode-copilot hands it
# to opencode). Works headless: opencode prints a code to enter at
# https://github.com/login/device on any browser. Log in there as the account
# that holds the Copilot license. The token only grants Copilot; revoke it
# under GitHub Settings -> Applications.
# Usage: bot/copilot-login.sh [secret-name]
set -euo pipefail

secret=${1:-jmarrero-bot-copilot-auth}
image=localhost/bootc-bot-agent:latest

# tmpfs, so the login never reaches disk outside the secret store
tmp=$(mktemp -d "${XDG_RUNTIME_DIR:?}/copilot-login.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

# opencode 2 keeps the login in its database; the secret holds it in
# opencode 1's auth.json format, which opencode-copilot reads.
echo "Pick GitHub.com (or your Enterprise) when asked." >&2
podman run --rm -it --userns=keep-id:uid=2000,gid=2000 --user 2000:2000 \
    -v "$tmp:/home/agent/.local/share/opencode:Z" "$image" sh -c \
    'opencode auth login --standalone github-copilot &&
     opencode auth export --standalone github-copilot | opencode-copilot --login-from-export \
         > /home/agent/.local/share/opencode/auth.json'

test -s "$tmp/auth.json" || { echo "error: no login was saved" >&2; exit 1; }
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert "github-copilot" in d, sorted(d)' \
    "$tmp/auth.json" || { echo "error: the login is not for GitHub Copilot" >&2; exit 1; }
podman secret create --replace "$secret" "$tmp/auth.json" >/dev/null
echo "Stored the Copilot login as podman secret $secret" >&2
