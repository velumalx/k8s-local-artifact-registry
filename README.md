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
