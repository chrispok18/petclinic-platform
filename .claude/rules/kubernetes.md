---
paths:
  - "k8s/**/*.yaml"
  - "k8s/**/*.yml"
---

# Kubernetes Rules

The 8 services are NOT plain manifests: they are rendered from the generic Helm chart
`helm/petclinic-service/` with `helm-values/{service}.yaml` + `helm-values/{env}.yaml` and deployed by
ArgoCD (see `.claude/rules/helm.md`). `k8s/` only holds what is not Helm-managed per service.
There are no Kustomize overlays.

## Directory Structure

```
k8s/
├── base/
│   ├── namespaces.yaml                 # petclinic-dev + PSA labels (applied before ArgoCD syncs)
│   ├── tracing-server.yaml             # ExternalName alias tracing-server -> zipkin.tracing (see Tracing)
│   ├── external-secrets/
│   │   ├── cluster-secret-store.yaml   # ClusterSecretStore aws-secrets-manager (IRSA)
│   │   └── rds-credentials.yaml        # ExternalSecret -> Secret rds-credentials (SPRING_DATASOURCE_*)
│   ├── addons/                         # static Helm values: aws-load-balancer-controller, external-secrets
│   └── observability/
│       ├── zipkin.yaml                 # Namespace tracing + Deployment/Service zipkin:9411
│       ├── kube-prometheus-stack-values.yaml
│       └── dashboards/                 # Grafana dashboard JSON (sidecar ConfigMap created by script)
└── argocd/
    ├── install/                        # argocd-cm patch (Application health check for sync waves)
    ├── root/petclinic-{env}.yaml       # app-of-apps: syncs applications/{env}/ in sync-wave order
    └── applications/{env}/             # one Application per service (8 per env)
```

Add-ons are installed by `scripts/install-addons.sh` and removed by `scripts/teardown-addons.sh`
(run BEFORE `terraform destroy`: the ALB is created by the LB controller, not terraform).

## Required Labels

Every resource MUST have `app.kubernetes.io/name` and `app.kubernetes.io/part-of: petclinic`, plus:

| Resource type | `app.kubernetes.io/managed-by` | `app.kubernetes.io/component` |
|---------------|--------------------------------|-------------------------------|
| Service workloads (Helm chart) | `Helm` | `server` (config, discovery), `gateway` (api-gateway), `service` (customers, visits, vets, genai), `admin` (admin-server) |
| `k8s/base/**` applied with kubectl | `kubectl` | `infrastructure` |
| ArgoCD `Application` CRs | `argocd` (root app: `kubectl`) | — (use `environment: {env}` label) |

The chart adds these via `_helpers.tpl` — never hand-write label blocks in templates.

## Deployment Requirements

Every Deployment MUST include:

1. **Probes** (technical-spec: Health Probes). A startupProbe gates readiness/liveness, so no
   `initialDelaySeconds`:

   | Probe | Path | Period | Timeout | Failure threshold |
   |-------|------|--------|---------|-------------------|
   | startupProbe | `/actuator/health` | 10s | 5s | 30 (≤5 min) |
   | readinessProbe | `/actuator/health/readiness` | 10s | 5s | 3 |
   | livenessProbe | `/actuator/health/liveness` | 15s | 5s | 3 |

   **Exception — config-server** has no actuator (optional dependency of spring-cloud-config-server):
   startup/readiness `GET /application/default`, liveness TCP. Do not "fix" it back to `/actuator/*`.

2. **Resource requests and limits** (values as built; technical-spec: Resource Requests and Limits):
   ```yaml
   resources:
     requests:
       memory: "384Mi"   # dev (helm-values/dev.yaml); chart default 128Mi
       cpu: "100m"       # api-gateway: 200m
     limits:
       memory: "512Mi"
       cpu: "500m"       # api-gateway: 1000m
   ```
   The dev memory request is 384Mi for all 8 JVM services because they really use ~250-350Mi;
   a 128Mi request lets the scheduler pack too many JVMs onto one 2 GiB t4g.small node.
   Init containers and add-ons also need requests and limits (init: 10m/16Mi → 50m/32Mi).

3. **Image with commit-SHA tag** (never `latest`; the chart fails to render on `latest` or empty):
   ```yaml
   image: {account}.dkr.ecr.eu-central-1.amazonaws.com/petclinic-{env}/{service}:{sha}
   ```
   `image.registry` (`{account}.dkr.ecr.eu-central-1.amazonaws.com/petclinic-{env}`) is set ONLY in
   `helm-values/{env}.yaml` — the account ID must appear in exactly one file. `image.tag` lives in
   `helm-values/{service}.yaml` (CI/manual commit). Images are `linux/arm64` only (`nodeSelector`).

4. **Security context** (PSA: namespace enforces `baseline`, warns on `restricted`):
   pod `runAsNonRoot: true`, `runAsUser/runAsGroup/fsGroup: 1000`, `seccompProfile: RuntimeDefault`;
   container `allowPrivilegeEscalation: false`, `capabilities.drop: ["ALL"]`. Images whose `USER` is a
   name (e.g. zipkin) need an explicit numeric `runAsUser`.

5. **Service name = Spring/Eureka name.** Resource names come from `serviceName`, never the release
   name: other services call `http://config-server:8888`, `http://discovery-server:8761/eureka/`.

## Service Startup Order

Enforced twice:

- **Init containers** (`waitFor: [{name, url}]` in `helm-values/{service}.yaml`, rendered as busybox
  `wget` loops):
  - config-server: none
  - discovery-server: `http://config-server:8888/application/default`
  - all others: config-server (as above) + `http://discovery-server:8761/actuator/health`
  - visits-service: additionally `http://customers-service:8081/actuator/health` (FK on `pets`)
- **ArgoCD sync waves** on the Applications: config-server `0` → discovery-server `1` →
  api-gateway, customers, vets, genai, admin `2` → visits `3`. Waves only work under the root app
  plus the argocd-cm Application health patch.

## Secrets

- NEVER put secrets (or the RDS endpoint) in YAML or values files.
- Use ExternalSecret CRs with **`apiVersion: external-secrets.io/v1`** — ESO v2.x does not serve
  `v1beta1`.
- DB services get `SPRING_DATASOURCE_URL/USERNAME/PASSWORD` from Secret `rds-credentials`
  (templated by ESO from `petclinic/{env}/rds-credentials`) via `envFrom`.
- Expose secrets as environment variables, not files (unless certificates).
- Scripts may create a Secret from a generated value (e.g. `monitoring/grafana-admin`) but must
  never print it or write it to Git.

## Namespaces

| Namespace | Contents |
|-----------|----------|
| `petclinic-dev` / `petclinic-prod` | the 8 services, `rds-credentials`, `tracing-server` alias |
| `tracing` | Zipkin |
| `monitoring` | kube-prometheus-stack (privileged: node-exporter needs host access) |
| `external-secrets` | ESO (SA `external-secrets-sa`, IRSA) |
| `kube-system` | AWS Load Balancer Controller (SA `aws-load-balancer-controller`, IRSA) |
| `argocd` | ArgoCD and the Application CRs |

All namespaced resources MUST set `metadata.namespace` explicitly (chart: `{{ .Release.Namespace }}`).
ArgoCD Applications use `CreateNamespace=false`; the namespace comes from `k8s/base/namespaces.yaml`.

## Tracing

The config repo's `docker` profile sends traces to `http://tracing-server:9411/api/v2/spans` (a short
name, resolved in the caller's namespace). Keep the `tracing-server` ExternalName Service in
`petclinic-{env}` and the Zipkin Service named `zipkin` in `tracing` on 9411, or traces are lost.

## Metrics

Only services with `micrometer-registry-prometheus` expose `/actuator/prometheus`: api-gateway,
customers, visits, vets, genai (`metrics.enabled: true` → Service label `petclinic.io/metrics: "true"`,
selected by the `petclinic-services` ServiceMonitor). config-, discovery- and admin-server stay `false`.

## Environment Differences (Helm values, not overlays)

| | Dev (`helm-values/dev.yaml`) | Prod (`helm-values/prod.yaml`) |
|-|------------------------------|--------------------------------|
| Replicas | 1 | 2+ |
| HPA / PDB | off | on (per spec) |
| JVM memory request | 384Mi | per spec |
| ArgoCD sync | automated, prune + selfHeal | manual |

## Validation

```bash
helm lint helm/petclinic-service -f helm-values/{service}.yaml -f helm-values/{env}.yaml
helm template {service} helm/petclinic-service -n petclinic-{env} \
  -f helm-values/{service}.yaml -f helm-values/{env}.yaml
kubeconform -strict -summary k8s/base   # if installed (CRDs need a schema catalog)
```
