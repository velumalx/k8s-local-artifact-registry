#!/usr/bin/env bash
# Installs (or upgrades) the ingress-nginx controller on the local
# Docker Desktop Kubernetes cluster. Safe to re-run.
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

helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx --force-update >/dev/null 2>&1 || true
helm repo update ingress-nginx

helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --version 4.15.1 \
  --namespace ingress-nginx \
  --create-namespace \
  --wait --timeout 5m

kubectl -n ingress-nginx wait --for=condition=Ready pod \
  -l app.kubernetes.io/component=controller \
  --timeout=180s

echo "ingress-nginx controller is ready in namespace 'ingress-nginx'."
