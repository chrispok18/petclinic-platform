---
paths:
  - "helm/**"
  - "helm-values/**/*.yaml"
  - "helm-values/**/*.yml"
---

# Helm Rules

## Chart Structure

Single generic chart shared by all 8 services:

```
helm/petclinic-service/
├── Chart.yaml              # name petclinic-service, version 0.1.0
├── values.yaml             # Defaults (documented; overridden by per-service/env files)
└── templates/
    ├── _helpers.tpl         # name, labels, selectors, image (refuses latest/empty tag), probe renderer
    ├── deployment.yaml      # probes, resources, waitFor init containers, envFrom, security context
    ├── service.yaml         # ClusterIP; label petclinic.io/metrics=true when metrics.enabled
    ├── configmap.yaml       # commonConfig (env file) merged with config (service file)
    ├── serviceaccount.yaml  # one per service, automountServiceAccountToken: false, IRSA annotations
    ├── hpa.yaml             # if autoscaling.enabled
    ├── pdb.yaml             # if podDisruptionBudget.enabled
    ├── ingress.yaml         # if ingress.enabled (api-gateway only; ALB)
    └── NOTES.txt            # Post-install notes
```

Every resource name is `serviceName` (never the release name) because other services reach it by
that DNS name. Every namespaced resource sets `namespace: {{ .Release.Namespace }}`.

## Values Hierarchy

ArgoCD merges values files in this order (last wins; maps are deep-merged):

1. `helm/petclinic-service/values.yaml` — chart defaults
2. `helm-values/{service}.yaml` — per-service config
3. `helm-values/{env}.yaml` — per-environment overrides

Deep merge means an env file can override one key (e.g. `resources.requests.memory`) without wiping
per-service siblings (api-gateway's CPU). Use `null` to delete an inherited key.

## Per-Service Values (`helm-values/{service}.yaml`)

| Key | Required | Notes |
|-----|----------|-------|
| `serviceName` | yes | DNS / resource / Spring name, e.g. `customers-service` |
| `component` | yes | `server`, `gateway`, `service` or `admin` |
| `image.name` | yes | ECR image name only (e.g. `config-server`); registry comes from the env file |
| `image.tag` | yes | 7-char commit SHA from the app repo CI; never `latest` |
| `service.port` | yes | 8888, 8761, 8080, 8081, 8082, 8083, 8084, 9090 |
| `springProfiles` | yes | `docker`; `docker,mysql` (customers, visits); `docker,mysql,production` (vets: the env var replaces the app's default `production` profile, which gates the cache) |
| `waitFor` | yes (except config-server) | list of `{name, url}`; rendered as busybox `wget` init containers |
| `metrics.enabled` | yes | `true` only for services with `micrometer-registry-prometheus` (api-gateway, customers, visits, vets, genai) |
| `envFromSecrets` | DB services | `[rds-credentials]` (Secret created by ESO with `SPRING_DATASOURCE_*`) |
| `probes` | config-server only | override: startup/readiness `GET /application/default`, liveness `type: tcp` (no actuator) |
| `resources` | api-gateway only | CPU 200m/1000m |
| `ingress` | api-gateway only | `enabled: true`, ALB annotations that do not depend on the environment |
| `env`, `secrets`, `config` | optional | extra env vars, single secret-backed vars `{name, secretName, key}`, ConfigMap entries |

## Per-Environment Values (`helm-values/{env}.yaml`)

| Key | Dev (`dev.yaml`) | Prod (`prod.yaml`, not built yet) |
|-----|------------------|-----------------------------------|
| `image.registry` | `{account}.dkr.ecr.eu-central-1.amazonaws.com/petclinic-dev` | `.../petclinic-prod` |
| `replicaCount` | 1 | 2 |
| `autoscaling.enabled` / `podDisruptionBudget.enabled` | false / false | per spec |
| `resources` | memory request 384Mi, limit 512Mi (all 8 JVMs) | per spec |
| `commonConfig` | `CONFIG_SERVER_URL: http://config-server:8888` | same |
| `ingress.annotations` | ALB name `petclinic-dev-alb`, SG `petclinic-dev-alb-sg`, tags | prod equivalents |

**The ECR registry (and so the AWS account ID) appears in exactly ONE file: `helm-values/{env}.yaml`.**
Never write the account ID in rules, docs, templates or service files — use `{account}`.

## Template Conventions

- Use Go template syntax: `{{ .Values.x }}`, `{{ include "helper" . }}`, `{{ tpl .Values.x . }}`
- Use `_helpers.tpl` for labels, names, selectors and the image string — do not duplicate label blocks
- Use `{{- if .Values.x.enabled }}` for conditional resources (HPA, PDB, Ingress)
- Use `{{- with }}` to scope into nested values
- Use `{{- toYaml . | nindent N }}` for YAML blocks; `include ... | trim | nindent N` for helpers
- Use `required` / `fail` for values that must be set (serviceName, image.registry, image.tag)
- NEVER hardcode environment-specific values in templates — use values files
- NEVER put secrets (or the RDS endpoint) in values files — use ExternalSecret CRs in
  `k8s/base/external-secrets/`

## Image Tags

- Commit SHA tags only; the chart fails to render on `latest` or an empty tag
- `image.tag` lives in `helm-values/{service}.yaml`; a commit there makes ArgoCD sync
- Rendered as `{{ .Values.image.registry }}/{{ .Values.image.name }}:{{ .Values.image.tag }}`
  (`image.name` defaults to `serviceName`)

## Startup Order

`waitFor` init containers enforce the dependency chain:
- **config-server**: none
- **discovery-server**: `http://config-server:8888/application/default` (config-server has no actuator)
- **all other services**: config-server (as above) + `http://discovery-server:8761/actuator/health`
- **visits-service**: additionally `http://customers-service:8081/actuator/health` (FK on `pets`)

ArgoCD sync waves (`k8s/argocd/applications/{env}/`) apply the same order at deploy time.

## Validation

Before committing any Helm change, lint and render all 8 services for the environment:

```bash
for s in config-server discovery-server api-gateway customers-service visits-service \
         vets-service genai-service admin-server; do
  helm lint helm/petclinic-service -n petclinic-dev \
    -f helm-values/$s.yaml -f helm-values/dev.yaml || exit 1
  helm template $s helm/petclinic-service -n petclinic-dev \
    -f helm-values/$s.yaml -f helm-values/dev.yaml > /dev/null || exit 1
done && echo "all 8 OK"
```

No cluster dry-run in CI or by Claude: ArgoCD applies the rendered output.
