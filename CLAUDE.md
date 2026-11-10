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
make template ARGS="--set async.shared.enabled=true"   # pass extra helm flags
make ci                                                # what CI runs (see below)
make package                                           # produces limina-<version>.tgz (gitignored)
helm show chart .                                      # quick check that the loader sees Chart.yaml
```

Feature flags worth rendering when touching shared logic: `async.shared.enabled`, `platform.shared.enabled` (plus `platform.ui.ingress.enabled`), the per-product External Secrets switches (`externalSecrets.dockerCredential.enabled`, `externalSecrets.core.enabled`, `externalSecrets.async.enabled`, `externalSecrets.platform.enabled`, plus the optional `env`/`tls` sub-switches), `core.ingress.enabled` / `async.api.ingress.enabled` with `selfsigned`, and a non-empty `core.deployment.gpu` map.

`helm test --namespace limina limina` runs `templates/tests/test-connection.yaml` (a busybox `wget` against the core service) against a live install.

There is no unit-test suite. CI (`.github/workflows/ci.yaml`) runs `make ci` on PRs to `main`. That lints the chart once with the default values and once for each `ci/*-values.yaml` scenario file (async, external secrets, GPU, ingress, platform). It reports every failure rather than stopping at the first one. Keep the logic in the Makefile, not the workflow, so CI and local runs stay identical. When you add a new feature flag or conditional template, add or extend a `ci/` scenario so it gets rendered. Chart version bumps are deliberately *not* enforced in CI. CD (`.github/workflows/cd.yaml`) runs on a published GitHub release and pushes the chart to ACR with the **release tag as the chart version**.

## Architecture

Four Limina components, all in one chart:

- **core** (`templates/core/`), image `deid`: always deployed. This is the ML de-identification service. By default it schedules only onto nodes labelled `container=limina-core`, with required hostname anti-affinity (one core pod per node).
- **async file processing** (`templates/async/`): gated entirely by `async.shared.enabled`. It adds:
  - **api** (`afp-api`, resources named `<fullname>-api`), with its own Deployment, Service, and optional Ingress.
  - **custodian** (`afp-worker` with `WORKER_ROLE=custodian`), its own Deployment.
  - **processor** (`afp-worker` with `WORKER_ROLE=processor`). This has **no Deployment of its own**. It is injected as a second container into the *core* Deployment (`templates/core/deployment.yaml`) and talks to core over `localhost:8080`. Changes to processor settings therefore mean editing the core deployment template.
  - Shared plumbing: a StorageClass, a RWX PVC (`<fullname>-async`) mounted at `async.shared.mountPath` by api, custodian and processor, a shared ConfigMap (Redis host/port/TLS, TTLs), and a shared Secret (Redis key).
- **Limina Platform** (`templates/platform/`): gated by `platform.shared.enabled`, independent of async (both can be on). It adds:
  - **middleware** (`limina-middleware`), with Deployment, Service, and an `alembic upgrade head` init container (`platform.middleware.migrations`).
  - **worker** (`limina-worker`), Deployment only. It calls core through the core Service, not a sidecar.
  - **ui** (`limina-ui`), with Deployment, Service, optional Ingress, and its own Secret (`<fullname>-ui`).
  - Shared plumbing, all named `<fullname>-platform`: a StorageClass + RWX PVC, a ConfigMap and a Secret consumed by middleware and worker, and an optional ServiceAccount (helpers in `_helpers.tpl`). The platform and ui ConfigMaps inject `LIMINA_CORE_URL`, `STORAGE_PATH` and `MIDDLEWARE_URL` from chart values, overridable by user data.

Values layout mirrors this, one top-level section per product:

- Top level holds only chart-wide settings: `cloudProvider`, `nameOverride`, `fullnameOverride`, `repository`, `imagePullSecrets`, and `externalSecrets`.
- `core` (including `core.license`, since only core mounts the license).
- `async.{shared,api,custodian,processor}` and `platform.{shared,middleware,ui,worker}`. Each product's `shared` block holds its `enabled` switch and the shared ConfigMap/Secret/PVC/StorageClass settings.
- All External Secrets settings live under the top-level `externalSecrets`, nested to mirror the products: `externalSecrets.{secretStoreName,secretStore,dockerCredential}`, `externalSecrets.core.{enabled,license,env,tls}`, `externalSecrets.async.{enabled,shared.env,api.tls}`, `externalSecrets.platform.{enabled,shared.env,ui.env,ui.tls}`. The rule is `externalSecrets.<product>[.<app>].<license|env|tls>`, with the product switch at `externalSecrets.<product>.enabled`.

`values.schema.json` sets `additionalProperties: false` on the root, `async`, `platform`, `externalSecrets` and `externalSecrets.{core,async,platform}`, so misspelled or misplaced keys fail validation instead of being silently ignored. All installs are fresh installs of the 0.2.0 layout, so there is no upgrade path or key migration to maintain. Any new top-level key, new app under `async`/`platform`, or new `externalSecrets` sub-block has to be added to the schema. All images go through the `limina.image` helper: `<component>.deployment.image.repository`, falling back to the top-level `repository`.

Each component's `deployment` block has the same shape (image, limits/requests, nodeSelector, nodeAffinity, podAntiAffinity, `tolerations.values`, `topologySpreadConstraints.values`, `additionalMounts.{volumeMounts,volumes}`, probes). Note the extra `.values` nesting under tolerations and topologySpreadConstraints. Keep the three deployment templates consistent when changing one.

Naming conventions: resources are named `{{ include "limina.fullname" . }}-<component>` (helpers in `templates/_helpers.tpl`). The license Secret and image-pull Secret use names straight from values (`core.license.name`, `imagePullSecrets.name`). Pod selectors and labels come from `<component>.deployment.selector.matchLabels` (e.g. `app: limina-core`), not from the common-labels helper. Env vars are lists of `{name, value}` rendered into ConfigMaps/Secrets and consumed via `envFrom`.

### Secrets: two mutually exclusive paths per product

Each product has its own switch, so plain Secrets and ESO can be mixed across products: `externalSecrets.core.enabled` (license + core env + core TLS), `externalSecrets.async.enabled` (shared Redis secret + api TLS), `externalSecrets.platform.enabled` (platform shared + ui env + ui TLS), and `externalSecrets.dockerCredential.enabled` for the image-pull secret. Each switch moves its product between:

- **Plain Secrets** (default): `core/license-secret.yaml`, `core/deploy-secret.yaml`, `async/shared-secret.yaml` render from values. The docker pull secret is expected to be created by the user with `kubectl`.
- **External Secrets Operator**: `external-secrets-operator/docker-creds-external-secret.yaml` and the `*external-secret.yaml` files under `core/`, `async/` and `platform/` render `ExternalSecret` (`external-secrets.io/v1`) objects against a namespaced `SecretStore` named by `externalSecrets.secretStoreName`. The user creates that SecretStore by default. With `externalSecrets.secretStore.create`, `external-secrets-operator/secret-store.yaml` creates it instead, rendering `externalSecrets.secretStore.provider` as `spec.provider`. It only renders when at least one ESO switch is on (helper `limina.externalSecretsEnabled`), and it fails if `provider` is empty. `externalSecrets.secretStore.serviceAccount` (create defaults to true, name defaults to `<fullname>-secret-store`, helper `limina.secretStore.serviceAccountName`) is the identity the store authenticates with, via IRSA/Workload Identity annotations. Because a namespaced SecretStore can only reference a service account in its own namespace, the chart creates it rather than reusing the ESO controller's. The `limina.secretStore.provider` helper injects that name into `provider.aws.auth.jwt.serviceAccountRef` (when `auth` is unset) and `provider.azurekv.serviceAccountRef` (when `authType: WorkloadIdentity` and unset). `create: false` with an empty name skips injection, so the controller's own identity is used. These produce Secrets with the **same names** the plain path would, so the Deployments don't change. The platform and ui ExternalSecrets render explicit `data` entries from `externalSecrets.platform.shared.env.properties` / `externalSecrets.platform.ui.env.properties`, which default to the required keys (REDIS_PASSWORD, POSTGRES_USER, POSTGRES_PASSWORD / BETTER_AUTH_SECRET, GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET). Each property can set its own `remoteRefKey` (falling back to the block-level one), so keys can come from different remote secrets, e.g. Postgres credentials from the RDS-managed master secret. Setting `properties: []` switches them to `dataFrom.extract`, which pulls every property. TLS external secrets expect a PKCS#12 blob and convert it with `pkcs12cert`/`pkcs12key`. ESO template expressions are escaped as `{{ `{{ ... }}` }}`.

Any new secret has to be wired through both paths behind its product's switch.

### Ingress and TLS

Ingress defaults to `ingressClassName: haproxy`. When `<component>.ingress.selfsigned` is true, `templates/cert-manager/` creates a `selfsigned` ClusterIssuer and Certificates as `post-install,post-upgrade` Helm hooks. The self-signed path is only meant for customer testing, never for real deployments. Its known limitations (hooks deleting the Certificates so they never renew, a fixed cluster-wide issuer name) are accepted; don't "fix" them unless asked. cert-manager, the ingress controller, and ESO are **not** chart dependencies. Users install them separately, as the README describes.

`cloudProvider` (`AWS` | `Azure` | `Other`) is only used in `templates/NOTES.txt`, to choose `.hostname` vs `.ip` for LoadBalancer lookups.

## Repo gotchas

- `*.values.yaml` files at the root (e.g. `20260924.values.yaml`) are local, per-environment values files. They are gitignored and helmignored and may contain real license data or credentials. Don't commit them, and don't copy their contents into `values.yaml` or the docs.
- **`.helmignore` under Helm 4:** a standalone `!pattern` negation line that has nothing to re-include can make Helm ignore *every* file, which shows up as "Chart.yaml file is missing". If lint fails that way, check `.helmignore` first (`helm show chart .`). Repo-only files (CLAUDE.md, `.claude/`, `Makefile`, `ci/`, `images/`, `.github`) must stay listed there so they aren't shipped in the chart package.
- `values.schema.json` is enforced by `helm install`/`upgrade`/`lint`/`template`. It uses JSON Schema draft 2019-09, validates `cloudProvider`, and restricts the allowed keys at the top level and under `async`/`platform` (see Architecture). If you tighten it further, also check that every `ci/` scenario and the README examples still validate.
- Comments: don't add inline comments to templates, workflows, the Makefile, CI values files or the schema unless the code deviates from standard practice and needs explaining. This doesn't apply to `values.yaml` and `README.md`, which are user-facing documentation where commented values and examples are the house style.
- Version bumps: `Chart.yaml` `version`, plus the hardcoded `--version 0.2.0` / `limina:0.2.0` occurrences in `README.md`. `appVersion` is only a label. The image tags that actually get deployed live in `values.yaml` (`core.deployment.image.tag`, and the `0.x` tags for api/custodian/processor). When changing the core tag, also update the GPU example tag in the README.
- PRs follow `.github/pull_request_template.md` (lint, CI, local-cluster testing; bump chart version for releases; update README).
