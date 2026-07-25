#!/usr/bin/env bash
# Removes both Helm releases and their namespaces, returning the
# Docker Desktop cluster to its prior state.
set -euo pipefail

for cmd in kubectl helm; do
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

uninstall_release() {
  local release="$1" ns="$2"
  if helm status "$release" -n "$ns" >/dev/null 2>&1; then
    helm uninstall "$release" -n "$ns"
  else
    echo "Release '$release' not found in namespace '$ns', skipping."
  fi
}

uninstall_release artifactory artifactory
kubectl delete namespace artifactory --ignore-not-found --timeout=120s

uninstall_release ingress-nginx ingress-nginx
kubectl delete namespace ingress-nginx --ignore-not-found --timeout=120s

echo "Teardown complete."
