# JFrog Artifactory OSS — Kubernetes (Docker Desktop) Deployment

## Purpose

Stand up JFrog Artifactory (open source edition) as a container registry on a
local Docker Desktop Kubernetes cluster, reachable at a friendly local
hostname, using scripts that make setup and teardown repeatable.

## Scope

- Target cluster: Docker Desktop's built-in Kubernetes integration (single
  node, local machine only).
- Deployment mechanism: official JFrog `artifactory-oss` Helm chart.
- Ingress: `ingress-nginx` (official chart), installed as part of this
  project since Docker Desktop does not ship a controller by default.
- Database: embedded Derby (bundled with the OSS chart) — no external
  Postgres dependency.
- Access: HTTP via Ingress at `artifactory.local` (no TLS).
- Repository configuration inside Artifactory (Docker/Maven/npm repos) is
  out of scope — this project only gets Artifactory installed and reachable;
  repo setup is a manual follow-up via the UI.
- Not in scope: HA/multi-replica, cloud-managed clusters, production
  hardening, TLS/cert-manager.

## Architecture

Two Helm releases run in the cluster:

1. `ingress-nginx` — cluster-wide ingress controller (its own namespace,
   e.g. `ingress-nginx`).
2. `artifactory` — JFrog's `artifactory-oss` chart, installed into its own
   `artifactory` namespace.

Traffic flow: browser → `http://artifactory.local` (resolved via a manual
`hosts` file entry pointing at `127.0.0.1`) → ingress-nginx controller →
Artifactory Service → Artifactory pod.

Persistence uses a PersistentVolumeClaim backed by Docker Desktop's default
`hostpath` StorageClass. The deployment runs a single replica with modest
resource requests/limits sized for a laptop, not a production cluster.

## Components & Layout

```
jfrog-artifactory-oss/
├── README.md
├── values/
│   └── artifactory-values.yaml   # single replica, resources, persistence, ingress host
├── scripts/
│   ├── install-ingress.sh        # install/upgrade ingress-nginx, wait for controller ready
│   ├── deploy.sh                 # add jfrog repo, create namespace, helm upgrade --install artifactory
│   ├── status.sh                 # check pod/ingress health, curl the health endpoint
│   └── teardown.sh               # uninstall both releases + delete the artifactory namespace
└── .gitignore                    # helm chart caches, *.tgz
```

Each script is standalone bash:

- `set -euo pipefail` in every script.
- Verifies `docker`, `kubectl`, and `helm` are on `PATH` before doing
  anything, with a clear error naming the missing tool.
- Verifies `kubectl config current-context` matches Docker Desktop's context
  (`docker-desktop`) before applying anything, to avoid accidentally
  targeting the wrong cluster.
- `deploy.sh` uses `helm upgrade --install`, so it is safe to re-run.

## Workflow

1. `./scripts/install-ingress.sh` — adds the ingress-nginx Helm repo,
   installs/upgrades the controller into the `ingress-nginx` namespace, and
   waits for the controller pod to become ready.
2. `./scripts/deploy.sh` — adds the JFrog Helm repo, creates the
   `artifactory` namespace if needed, and runs
   `helm upgrade --install artifactory jfrog/artifactory-oss -n artifactory -f values/artifactory-values.yaml`.
   On success it prints the `hosts` file line to add
   (`127.0.0.1 artifactory.local`) and the URL to browse.
3. `./scripts/status.sh` — runs `kubectl wait` for pod readiness, checks the
   Ingress resource exists, and curls
   `http://artifactory.local/router/api/v1/system/health` through the
   ingress, printing a pass/fail summary.
4. `./scripts/teardown.sh` — uninstalls the `artifactory` Helm release,
   deletes the `artifactory` namespace, and uninstalls the `ingress-nginx`
   release, returning the cluster to its prior state.

## Error Handling

- Every script fails fast (`set -euo pipefail`) rather than continuing past
  a broken step.
- Missing prerequisite tools or wrong kube-context abort the script
  immediately with an actionable message, before any cluster changes are
  made.
- `deploy.sh` is idempotent (`helm upgrade --install`), so a failed or
  partial run can simply be re-run rather than requiring manual cleanup.

## Verification

There is no application code here, so verification is operational rather
than unit-testable:

- `status.sh` is the primary verification surface: it waits for the
  Artifactory pod to reach `Ready`, confirms the Ingress resource is present,
  and calls Artifactory's own health endpoint through the ingress path,
  reporting a clear pass/fail.
- Manual verification: after `deploy.sh` completes and the hosts entry is
  added, browsing to `http://artifactory.local` should show the Artifactory
  login page (default credentials `admin` / `password`, which the UI forces
  a change on first login).