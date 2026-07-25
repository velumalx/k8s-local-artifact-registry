#!/usr/bin/env bash
# Checks that the Artifactory deployment is healthy and reachable
# through the ingress, without requiring a hosts file entry (uses
# curl --resolve to fake DNS for a single request).
set -euo pipefail

for cmd in kubectl curl; do
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

NAMESPACE="artifactory"
HOST="artifactory.local"

echo "== Pods in namespace '$NAMESPACE' =="
kubectl -n "$NAMESPACE" get pods

echo ""
echo "== Waiting for Artifactory pod to be Ready =="
if kubectl -n "$NAMESPACE" wait --for=condition=Ready pod \
  -l app=artifactory,release=artifactory --timeout=180s; then
  echo "Pod is Ready."
else
  echo "FAIL: Artifactory pod did not become Ready in time." >&2
  exit 1
fi

echo ""
echo "== Ingress =="
if ! kubectl -n "$NAMESPACE" get ingress artifactory >/dev/null 2>&1; then
  echo "FAIL: no Ingress named 'artifactory' found in namespace '$NAMESPACE'." >&2
  exit 1
fi
kubectl -n "$NAMESPACE" get ingress artifactory

echo ""
echo "== Health check: http://$HOST/router/api/v1/system/readiness =="
HTTP_CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
  --resolve "$HOST:80:127.0.0.1" \
  "http://$HOST/router/api/v1/system/readiness" || echo "000")"

if [ "$HTTP_CODE" = "200" ]; then
  echo "PASS: Artifactory readiness endpoint responded 200 OK."
else
  echo "FAIL: readiness endpoint returned HTTP $HTTP_CODE (expected 200)." >&2
  echo "Make sure ./scripts/install-ingress.sh has been run and the" >&2
  echo "ingress-nginx controller is Ready (kubectl get pods -n ingress-nginx)." >&2
  exit 1
fi
