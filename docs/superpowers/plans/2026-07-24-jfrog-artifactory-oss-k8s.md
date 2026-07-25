# JFrog Artifactory OSS — Kubernetes (Docker Desktop) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up JFrog Artifactory OSS as a container registry on the local Docker Desktop Kubernetes cluster, reachable at `http://artifactory.local`, using repeatable shell scripts.

**Architecture:** Two Helm releases — `ingress-nginx` (official chart) and `artifactory` (JFrog's `artifactory-oss` chart) — installed into their own namespaces on the `docker-desktop` kube-context. A values file disables the chart's bundled nginx in favor of our own ingress-nginx, keeps the chart's bundled Postgres subchart enabled (this chart/app version hard-rejects embedded Derby — see spec), and configures an Ingress at `artifactory.local`. Four standalone bash scripts (`install-ingress.sh`, `deploy.sh`, `status.sh`, `teardown.sh`) wrap the Helm/kubectl calls.

**Tech Stack:** Helm 3 (chart repos `jfrog` and `ingress-nginx` already added on this machine), kubectl, Docker Desktop Kubernetes, bash.

## Global Constraints

- Target context is exactly `docker-desktop` — every script must verify `kubectl config current-context` equals `docker-desktop` before making changes, and abort with a clear message otherwise.
- No TLS, no HA, single replica, PostgreSQL DB via the chart's bundled Postgres subchart (embedded Derby is not viable for this chart version — see spec) — per the approved spec at `docs/superpowers/specs/2026-07-24-jfrog-artifactory-oss-k8s-design.md`.
- Every script starts with `set -euo pipefail` and checks required CLI tools are on `PATH` before doing anything else.
- `deploy.sh` and `install-ingress.sh` must be idempotent (`helm upgrade --install`) — safe to re-run.
- Verification must not require editing the Windows hosts file — use `curl --resolve` to fake DNS resolution for a single request instead, since editing system files is a change outside the project directory.

---

### Task 1: Helm values file for Artifactory

**Files:**
- Create: `values/artifactory-values.yaml`

**Interfaces:**
- Produces: a values file consumed by `scripts/deploy.sh` via `-f "$SCRIPT_DIR/../values/artifactory-values.yaml"`.

**Confirmed chart facts** (from `helm show values jfrog/artifactory-oss` and `helm pull --untar` inspection of chart `artifactory-oss` v107.146.29, done during planning; revised during Task 3 after a live deploy proved embedded Derby non-viable — see spec):
- Everything nests under a top-level `artifactory:` key (the umbrella chart's dependency name).
- `artifactory.postgresql.enabled` (default `true`) — leave at `true`. This chart/app version hard-rejects the embedded Derby database at startup (`DbTypeNotAllowedException`), so the bundled Postgres subchart is required.
- `artifactory.nginx.enabled` (default `true`) — set `false`; we front the release with our own ingress-nginx instead of the chart's bundled nginx/LoadBalancer.
- `artifactory.ingress.enabled` (default `false`) — set `true`; `artifactory.ingress.hosts` is a plain string list; `artifactory.ingress.className` sets `ingressClassName` (maps to `nginx`, the IngressClass the `ingress-nginx` chart creates).
- `artifactory.artifactory.replicaCount` (default `1`) — leave at `1`.
- `artifactory.artifactory.persistence.size` (default `20Gi`) — reduce to `5Gi` for a laptop.
- `artifactory.artifactory.resources` (default `{}`, no limits) — set modest requests/limits.
- Rendering confirms the chart creates a `Service` named `artifactory` with ports `8082` (`http-router`) and `8081` (`http-artifactory`), a `StatefulSet` named `artifactory` with pod labels `app=artifactory,release=artifactory`, and an `Ingress` named `artifactory`.

- [ ] **Step 1: Write the values file**

```yaml
# values/artifactory-values.yaml
#
# Overrides for the jfrog/artifactory-oss chart, tuned for a single-node
# Docker Desktop Kubernetes cluster. See:
# docs/superpowers/specs/2026-07-24-jfrog-artifactory-oss-k8s-design.md
artifactory:
  # This chart/app version hard-rejects the embedded Derby database at
  # startup; use the chart's bundled Postgres subchart instead.
  postgresql:
    enabled: true

  # We front Artifactory with our own ingress-nginx release (see
  # scripts/install-ingress.sh) instead of the chart's bundled nginx +
  # LoadBalancer service.
  nginx:
    enabled: false

  ingress:
    enabled: true
    hosts:
      - artifactory.local
    className: nginx

  artifactory:
    replicaCount: 1
    persistence:
      size: 5Gi
    resources:
      requests:
        memory: "1Gi"
        cpu: "500m"
      limits:
        memory: "2Gi"
        cpu: "1"
```

- [ ] **Step 2: Dry-run render the chart with this values file**

Run (from the repo root):

```bash
helm template artifactory jfrog/artifactory-oss -n artifactory -f values/artifactory-values.yaml > /tmp/rendered.yaml
```

Expected: exits `0` with no error output. If `helm` reports the `jfrog` repo is missing, run `helm repo add jfrog https://charts.jfrog.io && helm repo update jfrog` first — this one-time setup is not part of the scripts because it's a one-off machine-level Helm config, done here only to unblock the dry run.

- [ ] **Step 3: Confirm the rendered output matches expectations**

Run:

```bash
grep -E "^kind:|^  name:" /tmp/rendered.yaml
```

Expected: includes `kind: Service` / `name: artifactory`, `kind: StatefulSet` / `name: artifactory`, `kind: Ingress` / `name: artifactory`, `kind: StatefulSet` / `name: artifactory-postgresql` (confirming the bundled Postgres subchart is enabled), and no `kind: Deployment` with `nginx` in the name (confirming `nginx.enabled: false` took effect). Then delete the scratch file: `rm /tmp/rendered.yaml`.

- [ ] **Step 4: Commit**

```bash
git add values/artifactory-values.yaml
git commit -m "feat: add Helm values for Artifactory OSS on Docker Desktop"
```

---

### Task 2: `install-ingress.sh`

**Files:**
- Create: `scripts/install-ingress.sh`

**Interfaces:**
- Produces: an `ingress-nginx` Helm release in the `ingress-nginx` namespace, with IngressClass `nginx`, that Task 3's Ingress resource depends on.

- [ ] **Step 1: Write the script**

```bash
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

helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null 2>&1 || true
helm repo update ingress-nginx

helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  --wait --timeout 5m

kubectl -n ingress-nginx wait --for=condition=Ready pod \
  -l app.kubernetes.io/component=controller \
  --timeout=180s

echo "ingress-nginx controller is ready in namespace 'ingress-nginx'."
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x scripts/install-ingress.sh
```

- [ ] **Step 3: Run it for real against the Docker Desktop cluster**

Run: `./scripts/install-ingress.sh`
Expected: ends with `ingress-nginx controller is ready in namespace 'ingress-nginx'.` and exit code `0`.

- [ ] **Step 4: Verify the controller and IngressClass exist**

Run: `kubectl get pods -n ingress-nginx && kubectl get ingressclass`
Expected: one controller pod `Running`/`1/1 Ready`, and an `ingressclass` named `nginx` listed.

- [ ] **Step 5: Re-run to confirm idempotency**

Run: `./scripts/install-ingress.sh`
Expected: completes successfully again (Helm reports the release already up to date; no errors).

- [ ] **Step 6: Commit**

```bash
git add scripts/install-ingress.sh
git commit -m "feat: add ingress-nginx install script"
```

---

### Task 3: `deploy.sh`

**Files:**
- Create: `scripts/deploy.sh`

**Interfaces:**
- Consumes: `values/artifactory-values.yaml` (Task 1), the `nginx` IngressClass created by Task 2.
- Produces: an `artifactory` Helm release in the `artifactory` namespace that Task 4's `status.sh` checks.

- [ ] **Step 1: Write the script**

```bash
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
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x scripts/deploy.sh
```

- [ ] **Step 3: Run it for real against the Docker Desktop cluster**

Run: `./scripts/deploy.sh`
Expected: Helm reports `STATUS: deployed`, and the script prints the "Artifactory deployed." block. This can take several minutes on first run (image pull).

- [ ] **Step 4: Verify the pod is running**

Run: `kubectl -n artifactory get statefulset,pods,svc,ingress`
Expected: `statefulset.apps/artifactory` with `1/1` ready, its pod `Running` with `READY 1/1` (or however many containers the chart configured — all must show ready), a `service/artifactory` with ports `8082` and `8081`, and an `ingress.networking.k8s.io/artifactory` with host `artifactory.local`.

- [ ] **Step 5: Re-run to confirm idempotency**

Run: `./scripts/deploy.sh`
Expected: completes successfully again with `STATUS: deployed`.

- [ ] **Step 6: Commit**

```bash
git add scripts/deploy.sh
git commit -m "feat: add Artifactory deploy script"
```

---

### Task 4: `status.sh`

**Files:**
- Create: `scripts/status.sh`

**Interfaces:**
- Consumes: the `artifactory` StatefulSet/Service/Ingress produced by Task 3 (pod labels `app=artifactory,release=artifactory`; Ingress named `artifactory`; router health path `/router/api/v1/system/readiness` on port `8082`, confirmed from the chart's own router readiness-probe configuration during planning).

- [ ] **Step 1: Write the script**

```bash
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
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x scripts/status.sh
```

- [ ] **Step 3: Run it for real against the live deployment**

Run: `./scripts/status.sh`
Expected: every section prints, ending with `PASS: Artifactory readiness endpoint responded 200 OK.` and exit code `0`.

- [ ] **Step 4: Verify failure path (negative test)**

Run: `kubectl -n ingress-nginx scale deployment ingress-nginx-controller --replicas=0 && ./scripts/status.sh; echo "exit code: $?"`
Expected: the health check section fails with `FAIL: readiness endpoint returned HTTP 000 (expected 200)` (connection refused, since the controller is scaled down) and a non-zero exit code. Then restore it:

```bash
kubectl -n ingress-nginx scale deployment ingress-nginx-controller --replicas=1
kubectl -n ingress-nginx wait --for=condition=Ready pod -l app.kubernetes.io/component=controller --timeout=120s
```

- [ ] **Step 5: Re-run to confirm it passes again**

Run: `./scripts/status.sh`
Expected: `PASS: Artifactory readiness endpoint responded 200 OK.` again.

- [ ] **Step 6: Commit**

```bash
git add scripts/status.sh
git commit -m "feat: add deployment status/health-check script"
```

---

### Task 5: `teardown.sh`

**Files:**
- Create: `scripts/teardown.sh`

**Interfaces:**
- Consumes: the `artifactory` and `ingress-nginx` Helm releases from Tasks 2/3.

- [ ] **Step 1: Write the script**

```bash
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
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x scripts/teardown.sh
```

- [ ] **Step 3: Run it for real against the live deployment**

Run: `./scripts/teardown.sh`
Expected: ends with `Teardown complete.` and exit code `0`.

- [ ] **Step 4: Verify everything is gone**

Run: `kubectl get namespaces`
Expected: no `artifactory` or `ingress-nginx` namespace listed. Also run `helm list -A` and confirm neither release appears.

- [ ] **Step 5: Re-run to confirm idempotency (nothing to remove)**

Run: `./scripts/teardown.sh`
Expected: prints `Release 'artifactory' not found in namespace 'artifactory', skipping.` and the same for `ingress-nginx`, then `Teardown complete.`, exit code `0`.

- [ ] **Step 6: Commit**

```bash
git add scripts/teardown.sh
git commit -m "feat: add teardown script"
```

---

### Task 6: README and .gitignore

**Files:**
- Create: `README.md`
- Create: `.gitignore`

**Interfaces:**
- None — this is documentation tying together Tasks 1–5. No code depends on it.

- [ ] **Step 1: Write `.gitignore`**

```gitignore
*.tgz
.DS_Store
```

- [ ] **Step 2: Write `README.md`**

```markdown
# JFrog Artifactory OSS on Docker Desktop Kubernetes

Deploys JFrog Artifactory (open source edition) as a container registry
on a local Docker Desktop Kubernetes cluster, reachable at
`http://artifactory.local`.

See `docs/superpowers/specs/2026-07-24-jfrog-artifactory-oss-k8s-design.md`
for the full design.

## Prerequisites

- Docker Desktop with the Kubernetes integration enabled, set as the
  current kubectl context (`docker-desktop`).
- `helm` (v3) and `kubectl` on your `PATH`.

## Quick start

```bash
./scripts/install-ingress.sh   # one-time: installs the ingress-nginx controller
./scripts/deploy.sh            # installs/upgrades Artifactory
./scripts/status.sh            # verifies the deployment is healthy
```

After `deploy.sh` succeeds, add this line to your hosts file (as
Administrator) to browse the UI:

```
127.0.0.1 artifactory.local
```

Windows hosts file path: `C:\Windows\System32\drivers\etc\hosts`.

Then browse to `http://artifactory.local`. Default login is
`admin` / `password` — you'll be forced to change it on first login.

`status.sh` itself does not require the hosts file entry; it uses
`curl --resolve` to verify the deployment directly.

## Tearing down

```bash
./scripts/teardown.sh
```

Removes both the `artifactory` and `ingress-nginx` Helm releases and
their namespaces, returning the cluster to its prior state.

## What's deployed

- Single-replica Artifactory OSS (`jfrog/artifactory-oss` Helm chart),
  PostgreSQL DB via the chart's bundled Postgres subchart (embedded Derby
  is not viable for this chart version — see spec), no TLS, no HA —
  intended for local development, not production use.
- `ingress-nginx` as the ingress controller, since Docker Desktop
  Kubernetes does not ship one by default.
- Persistence via a 5Gi PVC on Docker Desktop's default `hostpath`
  StorageClass.

## Configuring repositories

This project only installs and exposes Artifactory — it does not
pre-create any Docker/Maven/npm repositories. Do that afterward via the
UI at `http://artifactory.local`.
```

- [ ] **Step 3: Commit**

```bash
git add README.md .gitignore
git commit -m "docs: add project README"
```

---

## Final check

- [ ] Confirm the full up/down cycle works end to end in one pass:

```bash
./scripts/install-ingress.sh && \
./scripts/deploy.sh && \
./scripts/status.sh && \
./scripts/teardown.sh
```

Expected: all four scripts complete with exit code `0` in sequence, with `status.sh` printing `PASS: Artifactory readiness endpoint responded 200 OK.` before teardown runs. This leaves the Docker Desktop cluster clean; re-run `install-ingress.sh` + `deploy.sh` whenever you want the registry running again.
