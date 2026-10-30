# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Public, MIT-licensed Helm chart (`limina`) that customers use to deploy the Limina product. The repo root *is* the chart (no `charts/<name>/` layout). Releases are published as an OCI artifact to `oci://crprivateaiprod.azurecr.io/helm/limina`. Customers run with their own values file, so `values.yaml` and `README.md` are user-facing documentation — every value needs a comment explaining it, and commented-out examples are the house style for optional settings.

## Commands

Helm 4 only (>= 4.0.0). Helm 3 is intentionally unsupported.

Common tasks are wrapped in the `Makefile`. Run `make` to list them.

```console
make lint                                              # helm lint with default values
make lint VALUES=ci/async-values.yaml                  # lint with a specific values file
make template                                          # render with defaults
make template TEMPLATE=templates/core/deployment.yaml  # render a single template
make template ARGS="--set shared.async.enabled=true"   # pass extra helm flags
make ci                                                # what CI runs (see below)
make package                                           # produces limina-<version>.tgz (gitignored)
helm show chart .                                      # quick check that the loader sees Chart.yaml
```

Feature flags worth rendering when touching shared logic: `shared.async.enabled`, `externalSecrets.enabled` (plus `externalSecrets.core.enabled` / `tlsCore.enabled` / `tlsApi.enabled`), `core.ingress.enabled` / `api.ingress.enabled` with `selfsigned`, and a non-empty `core.deployment.gpu` map.

`helm test --namespace limina limina` runs `templates/tests/test-connection.yaml` (a busybox `wget` against the core service) against a live install.

There is no unit-test suite. CI (`.github/workflows/ci.yaml`) runs `make ci` on PRs to `main`. That lints the chart once with the default values and once for each `ci/*-values.yaml` scenario file (async, external secrets, GPU, ingress). It reports every failure rather than stopping at the first one. Keep the logic in the Makefile, not the workflow, so CI and local runs stay identical. When you add a new feature flag or conditional template, add or extend a `ci/` scenario so it gets rendered. Chart version bumps are deliberately *not* enforced in CI. CD (`.github/workflows/cd.yaml`) runs on a published GitHub release and pushes the chart to ACR with the **release tag as the chart version**.

## Architecture

Four Limina components, all in one chart:

- **core** (`templates/core/`), image `deid`: always deployed. This is the ML de-identification service. By default it schedules only onto nodes labelled `container=limina-core`, with required hostname anti-affinity (one core pod per node).
- **async file processing** (`templates/async/`): gated entirely by `shared.async.enabled`. It adds:
  - **api** (`afp-api`), with its own Deployment, Service, and optional Ingress.
  - **custodian** (`afp-worker` with `WORKER_ROLE=custodian`), its own Deployment.
  - **processor** (`afp-worker` with `WORKER_ROLE=processor`). This has **no Deployment of its own**. It is injected as a second container into the *core* Deployment (`templates/core/deployment.yaml`) and talks to core over `localhost:8080`. Changes to processor settings therefore mean editing the core deployment template.
  - Shared plumbing: a StorageClass, a RWX PVC (`<fullname>-async`) mounted at `shared.mountPath` by api, custodian and processor, a shared ConfigMap (Redis host/port/TLS, TTLs), and a shared Secret (Redis key).

Values layout mirrors this: top-level `shared`, `core`, `api`, `custodian`, `processor`, `externalSecrets`. Each component's `deployment` block has the same shape (image, limits/requests, nodeSelector, nodeAffinity, podAntiAffinity, `tolerations.values`, `topologySpreadConstraints.values`, `additionalMounts.{volumeMounts,volumes}`, probes). Note the extra `.values` nesting under tolerations and topologySpreadConstraints. Keep the three deployment templates consistent when changing one.

Naming conventions: resources are named `{{ include "limina.fullname" . }}-<component>` (helpers in `templates/_helpers.tpl`). The license Secret and image-pull Secret use names straight from values (`shared.license.name`, `shared.imagePullSecrets.name`). Pod selectors and labels come from `<component>.deployment.selector.matchLabels` (e.g. `app: limina-core`), not from the common-labels helper. Env vars are lists of `{name, value}` rendered into ConfigMaps/Secrets and consumed via `envFrom`.

### Secrets: two mutually exclusive paths

`externalSecrets.enabled` switches the chart between:

- **Plain Secrets** (default): `core/license-secret.yaml`, `core/deploy-secret.yaml`, `async/shared-secret.yaml` render from values. The docker pull secret is expected to be created by the user with `kubectl`.
- **External Secrets Operator**: `external-secrets-operator/*.yaml`, `core/*external-secret.yaml`, `async/*external-secret.yaml` render `ExternalSecret` (`external-secrets.io/v1`) objects against a namespaced `SecretStore` named by `externalSecrets.secretStoreName`. These produce Secrets with the **same names** the plain path would, so the Deployments don't change. TLS external secrets expect a PKCS#12 blob and convert it with `pkcs12cert`/`pkcs12key`. ESO template expressions are escaped as `{{ `{{ ... }}` }}`.

Any new secret has to be wired through both paths behind this flag.

### Ingress and TLS

Ingress defaults to `ingressClassName: haproxy`. When `<component>.ingress.selfsigned` is true, `templates/cert-manager/` creates a `selfsigned` ClusterIssuer and Certificates as `post-install,post-upgrade` Helm hooks. The self-signed path is only meant for customer testing, never for real deployments. Its known limitations (hooks deleting the Certificates so they never renew, a fixed cluster-wide issuer name) are accepted; don't "fix" them unless asked. cert-manager, the ingress controller, and ESO are **not** chart dependencies. Users install them separately, as the README describes.

`cloudProvider` (`AWS` | `Azure` | `Other`) is only used in `templates/NOTES.txt`, to choose `.hostname` vs `.ip` for LoadBalancer lookups.

## Repo gotchas

- `*.values.yaml` files at the root (e.g. `20260924.values.yaml`) are local, per-environment values files. They are gitignored and helmignored and may contain real license data or credentials. Don't commit them, and don't copy their contents into `values.yaml` or the docs.
- **`.helmignore` under Helm 4:** a standalone `!pattern` negation line that has nothing to re-include can make Helm ignore *every* file, which shows up as "Chart.yaml file is missing". If lint fails that way, check `.helmignore` first (`helm show chart .`). Repo-only files (CLAUDE.md, `.claude/`, `Makefile`, `ci/`, `images/`, `.github`) must stay listed there so they aren't shipped in the chart package.
- `values.schema.json` is enforced by `helm install`/`upgrade`/`lint`/`template`. It currently validates only the top-level `cloudProvider` and uses JSON Schema draft 2019-09. If you add `required` keys or `additionalProperties: false`, also check that every `ci/` scenario and the README examples still validate.
- Comments: don't add inline comments to templates, workflows, the Makefile, CI values files or the schema unless the code deviates from standard practice and needs explaining. This doesn't apply to `values.yaml` and `README.md`, which are user-facing documentation where commented values and examples are the house style.
- Version bumps: `Chart.yaml` `version`, plus the hardcoded `--version 0.1.0` / `limina:0.1.0` occurrences in `README.md`. `appVersion` is only a label. The image tags that actually get deployed live in `values.yaml` (`core.deployment.image.tag`, and the `0.x` tags for api/custodian/processor). When changing the core tag, also update the GPU example tag in the README.
- PRs follow `.github/pull_request_template.md` (lint, CI, local-cluster testing; bump chart version for releases; update README).
