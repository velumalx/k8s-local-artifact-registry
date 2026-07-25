#!/usr/bin/env bash
# Deploys (or upgrades) Artifactory OSS on the local Docker Desktop
# Kubernetes cluster. Safe to re-run.
set -euo pipefail

for cmd in docker kubectl helm; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: required tool '$cmd' not found on PATH." >&2
    exit 1
  fi
done

CONTEXT="$(kubectl config current-context)"
if [ "$CONTEXT" != "docker-desktop" ]; then
  echo "ERROR: current kubectl context is '$CONTEXT', expected 'docker-desktop'." >&2
  echo "Switch with: kubectl config use-context docker-desktop" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALUES_FILE="$SCRIPT_DIR/../values/artifactory-values.yaml"

helm repo add jfrog https://charts.jfrog.io >/dev/null 2>&1 || true
helm repo update jfrog

helm upgrade --install artifactory jfrog/artifactory-oss \
  --namespace artifactory \
  --create-namespace \
  -f "$VALUES_FILE" \
  --wait --timeout 10m

cat <<'EOF'

Artifactory deployed.

To browse the UI:
  1. Add this line to your hosts file (as Administrator):
       127.0.0.1 artifactory.local
     Windows path: C:\Windows\System32\drivers\etc\hosts
  2. Browse to: http://artifactory.local
  3. Default login: admin / password (you will be forced to change it
     on first login).

Run ./scripts/status.sh to verify the deployment without editing your
hosts file first.
EOF
