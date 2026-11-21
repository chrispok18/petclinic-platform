# Build log — DMI Final Project (Christian Aryee)

Platform repo: chrispok18/petclinic-platform · App repo: chrispok18/spring-petclinic-microservices
Region: eu-central-1 · Environment: dev only

---

## Day 1 — Tue 17 Nov 2026

### 1. Setup
- Checked tools in WSL Ubuntu: git, aws, terraform 1.14, kubectl 1.37, claude. Helm was missing, so I installed v3.22.1.
- My first tool check ran in Git Bash by mistake (Windows paths /c/...). I re-ran it in WSL to use the Linux tools.
- First clone failed ("Invalid username or token") because the fork did not exist yet. Forked both repos, then the clone worked.
- Installed jq (needed by the safety hooks) and uv/uvx (needed by the AWS MCP servers).
- Created a $30 monthly AWS budget with email alerts before building anything.

### 2. Claude Code configuration
- The starter repo had CLAUDE.md, 6 subagents, 6 hooks, 10 skills, 4 rules, .mcp.json, a technical spec and a Jira backlog, but no Terraform code. I generated the code with Claude Code.
- MCP: aws-knowledge and aws-pricing connected. terraform-mcp-server and context7 failed (CONNECTION_CLOSED) and a retry did not fix them. I skipped atlassian (Jira not needed) and worked without them.
- Turned off auto mode so I approve every command. This keeps infrastructure changes under human control.

### 3. Remote state (PETPLAT-1, 2, 3, 5)
- Claude created the dev-only Terraform skeleton and scripts/bootstrap-state.sh. I ran the bootstrap script myself.
- S3 state bucket: public access blocked, versioning on, AES256 encryption. DynamoDB lock table active.
- Kept my AWS account ID out of Git: the bucket name lives in backend.hcl (gitignored) and is used with `terraform init -backend-config=backend.hcl`.
- terraform validate: Success. Commit c5cca6f.

### 4. VPC, ECR, GitHub OIDC (PETPLAT-6, 8, 9, 18, 19, 20, 52)
- Claude checked read-only that no GitHub OIDC provider existed before creating one.
- Claude worked in a separate git worktree/branch, not on main.
- First plan: 44 to add.
- GAP IN THE SPEC found by Claude: the ALB was allowed to send health checks to nodes on 8080, but the node security group had no rule to accept them. The app would not have loaded through the ALB. I reviewed it and approved the fix. New plan: 45 to add.
- Accepted force_delete=true on dev ECR so destroy does not get stuck on repos holding images.
- Accepted an extra resource that strips all rules from the VPC default security group (security best practice).
- ecr:GetAuthorizationToken must be on "*" (AWS does not allow narrowing it). Push actions are limited to the 8 dev repos.
- terraform apply: 45 added, 0 changed, 0 destroyed. The apply showed no output at first (slow connection to S3 while loading state), then completed.
- Merged the worktree branch into main (fast-forward to 6e00c3f), then ran terraform plan from main: "No changes" (no drift).
- Before the first build, Claude reviewed the IAM policy and found ecr:BatchGetImage was missing. Without it, buildx push would likely fail with 403. Added it plus ecr:GetDownloadUrlForLayer. Commit 3f6836c, applied (1 changed).

### 5. Safety hooks issue (backup A7 / A3 material)
- False positive 1: block-secret-commit.sh blocked `git add .gitignore`, because its pattern for `git add .` matched any dotfile. Claude got past it by changing the file order. Harmless here, but it shows a hook is only as good as its pattern. I checked the commit with `git show --stat 6e00c3f`.
- REAL PROBLEM: hooks in .claude/settings.json were called with a relative path (.claude/hooks/...). When Claude's shell was inside terraform/environments/dev, every PreToolUse hook failed with exit 127 "No such file or directory". Claude Code treats exit 127 as non-blocking, so the safety checks silently did not run (fail open). In that state terraform destroy would not have been blocked.
- Fix: hook commands now use "$CLAUDE_PROJECT_DIR"/.claude/hooks/... so they run from any folder.
- False positive 2: `git add .claude/settings.json` was blocked for the same dotfile reason. This time Claude stopped and asked me instead of working around the hook. I approved tightening the regex to `git\s+add\s+(-A|--all|\.(\s|$))` and adding >&2 so block reasons are visible. I committed the hook change myself (commit df92671).
- Claude caught its own bulk-edit mistake (a stray >&2 on an if line) and fixed it. All hook scripts pass bash -n.
- Verified: from terraform/environments/dev, as two separate calls (cd, then git add .), Claude's command was blocked with the reason shown.

### 6. EKS, RDS, IRSA code (plan only, not applied)
- Kubernetes 1.37: newest version in standard support in eu-central-1 (checked with the AWS CLI). 1.29 from the spec is in extended support (~$0.60/hr instead of $0.10/hr). upgrade_policy = STANDARD so the cluster never slides into paid extended support.
- Node image AL2023_ARM_64_STANDARD (AL2 is not published for new Kubernetes versions). t4g.small, min 2 / max 8 / desired 5.
- My prompt asked which security groups nodes really get. Without a launch template, nodes only get the EKS primary SG, so the RDS 3306 and ALB 8080 rules would match nothing and the app could not reach its database. Claude added a launch template with both SGs, plus encrypted gp3 node disks and IMDSv2 with hop limit 1.
- Capacity estimate: 5 x t4g.small = about 40 pod slots for about 28 pods, about 80% memory. Scale to 6 if pods stay Pending.
- Skipped aws-ebs-csi-driver: Prometheus/Grafana run without persistent volumes, so destroy leaves no EBS volumes behind.
- RDS: MySQL 8.0, db.t4g.micro, single-AZ, encrypted, not public, skip_final_snapshot=true, deletion_protection=false. Password from random_password, stored in Secrets Manager as petclinic/dev/rds-credentials (recovery window 0 so the name can be reused after destroy).
- IRSA roles for External Secrets and the AWS Load Balancer Controller (official v3.6.3 policy).
- Narrowed the ESO IAM policy from petclinic/* to petclinic/dev/* (least privilege: dev cannot read prod secrets).
- Updated docs/technical-spec.md and CLAUDE.md to match what was actually built.
- Plan: 26 to add, 0 change, 0 destroy. Commits 456faff, fcbabf7, 50ef12c. Estimated cost while running: ~$0.25/hr.

### 7. CI pipeline: build ARM64 images and push to ECR (MAIN A7 STORY)
- Workflow .github/workflows/build-push.yml in the app fork (no application code changed). One Maven build on x86, then 8 parallel image builds for linux/arm64, Trivy scan, push to ECR, tagged with the 7-char commit SHA.
- Claude pinned aquasecurity/trivy-action to SHA a9c7b0f but said it could not verify it. I checked the official v0.36.0 release page: it points to commit ed142fd0673e97e23eac54620cfb913e5ce36c25 (verified). Claude explained the root cause: a9c7b0f was the annotated tag object's ID, not the commit. Pin corrected. The release notes confirm a supply-chain attack on this action in 2026, so pinning to a verified commit matters.
- Added -DskipTests to the image build (upstream's own workflow already runs the tests).
- GitHub Actions is disabled on forks by default, so I enabled it.
- Run #1 FAILED: all 8 image jobs got "Could not assume role with OIDC: Not authorized to perform sts:AssumeRoleWithWebIdentity".
  - Investigation: read the trust policy, the OIDC provider and CloudTrail. 96 AccessDenied AssumeRoleWithWebIdentity events showed the real token.
  - Root cause: GitHub's OIDC sub now includes immutable numeric IDs (repo:owner@<id>/repo@<id>:ref:refs/heads/main). The trust policy expected the old plain form, so StringEquals failed.
  - Fix: trust policy accepts both forms, with the IDs passed in as a variable so the module stays reusable. I used `terraform plan -target=module.github_oidc` so EKS/RDS were NOT created. Commit ffc5448, applied (1 changed).
- Run #2 FAILED at the Trivy scan. OIDC and ECR login passed (fix confirmed) and the image built, but the gate blocked all 8 images on fixable CRITICAL CVEs in app libraries:
  - Spring Boot 4.0.1 -> 4.0.6, spring-webflux 7.0.2 -> 7.0.9, netty-handler 4.2.9 -> 4.2.17, bouncycastle 1.81 -> 1.85.
  - The Ubuntu 26.04 base image had 0 OS vulnerabilities. All 6 CRITICAL findings were in app libraries.
- Fix: split Trivy into a gate (blocks only fixable CRITICAL OS vulnerabilities = platform-owned base image) and a report (CRITICAL/HIGH OS + library, uploaded as artifact trivy-<service>, never blocks). Commit 32c63ef.
- Run #3 PASSED in 3m31s: all 8 images built, scanned and pushed to ECR. Image tag for Helm values: 32c63ef.
- Story: #1 failed (OIDC sub format) -> #2 failed (Trivy gate on app library CVEs) -> #3 passed.

---

## Architecture decisions (for A2)
1. Dev environment only (the template does not require prod).
2. No Route 53/ACM: the app is served on the ALB hostname over HTTP.
3. Karpenter skipped.
4. Loki, FluentBit and Alertmanager skipped (no screenshot needs them; saves node capacity).
5. Image tags updated by committing to helm-values/ myself instead of the automatic update-image-tags workflow (ArgoCD still deploys from Git).
6. Kubernetes 1.37 instead of 1.29 (avoid extended-support pricing), upgrade_policy STANDARD.
7. AL2023_ARM_64_STANDARD nodes instead of AL2_ARM_64.
8. Launch template attaching both the EKS primary SG and the custom node SG.
9. 5 x t4g.small nodes instead of 2 (capacity for apps + ArgoCD + observability).
10. No EBS CSI / persistent volumes for Prometheus and Grafana (nothing left behind at destroy).
11. No OpenAI secret: genai-service runs with its default "demo" key.
12. Trivy gate split: block fixable CRITICAL OS CVEs, report library CVEs (app code is out of scope).
13. GitHub OIDC trust policy accepts the immutable-ID sub format.

## Production improvements (for A9 Q6)
- Block on all fixable CRITICAL CVEs and require the app team to upgrade Spring Boot to 4.0.6 and the other libraries.
- HTTPS with Route 53 + ACM instead of plain HTTP.
- Prod environment with manual ArgoCD sync, Multi-AZ RDS, deletion protection, final snapshots, longer backups.
- Private subnets + NAT instead of all-public subnets.
- Persistent volumes for Prometheus/Grafana and longer retention; Loki + Alertmanager for logs and alerts.
- warn-apply-without-plan hook only warns (exit 1 is non-blocking); it should use permissionDecision "ask".
- suggest-validate hook tips never reach Claude on exit 0.
- Re-enable secret scanning in Trivy image scans.
- Larger nodes (e.g. m7g) instead of t4g.small.

## Screenshots so far
| File | Use |
|---|---|
| A4-3a-github-actions-build.png | A4-3a (run #3, all 8 green) |
| A7-1-oidc-sub-mismatch-cloudtrail.png | A7-1 (Claude's root-cause table) |
| A7-2-ci-runs-red-to-green.png | A7-2 (#1 red, #2 red, #3 green) |
| backup-A7-1-ci-oidc-denied.png | Backup A7-1 |
| A7-1-hooks-failing-exit-127.png | Backup A7 (hooks) |
| A7-2-hook-blocks-from-subfolder.png | Backup A7 (hooks) |
| backup-A3-1-claude-vpc-ecr-plan.png | Backup A3 |
| backup-A3-1-claude-iam-gap.png | Backup A3 |
| backup-A3-trivy-release-ed142fd.png | Backup A3 |
| backup-A4-1-vpc-ecr-apply.png | Backup A4-1 (cropped above Outputs) |
| backup-A7-validation-no-drift.png | Backup validation |
| extra-01-claude-checks-before-destroy.png | Extra (blur account ID) |

## Commits
| Repo | Commit | What |
|---|---|---|
| platform | c5cca6f | Terraform skeleton, state backend, bootstrap script |
| platform | 6e00c3f | VPC, ECR, GitHub OIDC (+ 8080 rule, worktrees ignore) |
| platform | 3f6836c | IAM: ecr:BatchGetImage + GetDownloadUrlForLayer |
| platform | df92671 | Hooks: $CLAUDE_PROJECT_DIR, regex fix, stderr |
| platform | 456faff | EKS, RDS, IRSA code (plan only) |
| platform | fcbabf7 | ESO narrowed to dev, spec updated |
| platform | 50ef12c | CLAUDE.md dev row updated |
| platform | ffc5448 | OIDC trust policy accepts immutable-ID sub |
| app | 97b3b9e | build-push workflow added |
| app | 32c63ef | Trivy gate split (run #3 green) |

## Next (Day 2, $0)
- Helm chart + 8 values files (tag 32c63ef), ArgoCD Applications, ESO / LB Controller / observability install files.
- Run the security-auditor agent and fix one finding (A3).

---

## Day 2 — Thu 19 Nov 2026

### 8. Helm chart, External Secrets, ArgoCD (commit 6cadf1e)
- Generic Helm chart (8 services + dev values), ESO ClusterSecretStore + ExternalSecret, ArgoCD root app + 8 Applications with sync waves. helm lint and helm template pass for all 8. My account ID appears only in helm-values/dev.yaml.
- RDS endpoint kept out of Git: the ExternalSecret builds SPRING_DATASOURCE_URL/USERNAME/PASSWORD from the Secrets Manager JSON (sslMode=REQUIRED). DB services load it with envFrom.
- Claude found 4 real problems before the build:
  1. Zipkin hostname mismatch: the app sends traces to tracing-server:9411, but the spec puts Zipkin in namespace tracing. Fix: alias Service tracing-server -> zipkin.tracing.
  2. config-server has no actuator, so the spec's probes would fail and every other service would wait forever. Fix: probes on /application/default.
  3. vets-service needs the production profile, or its Caffeine cache never loads.
  4. External Secrets API is now v1; the spec's v1beta1 would be rejected.
- Startup waves: config-server -> discovery-server -> gateway/customers/vets/genai/admin -> visits (visits table has a foreign key to pets).
- A8 NOTE: the ALB is created by the Load Balancer Controller, not Terraform. Delete the Ingress/apps BEFORE terraform destroy, or the ALB blocks VPC deletion.

### 9. Build-day scripts (commit f366a71)
- scripts/install-addons.sh: installs in order with pinned versions and waits for each: namespaces -> LB Controller 3.6.3 -> External Secrets 2.15.0 (+ ClusterSecretStore, ExternalSecret, tracing alias) -> Zipkin 3.6.1 -> kube-prometheus-stack 93.4.1 (no Alertmanager, no volumes, 1-day retention, Grafana password only in a K8s secret, Petclinic dashboard provisioned) -> ArgoCD v3.6.2 + root app. Waits for all 8 apps Synced + Healthy and prints the ALB URL.
- scripts/teardown-addons.sh: deletes the apps and Ingress, waits until the ALB and target groups are really gone (aws elbv2), uninstalls the add-ons, reports anything left over.
- scripts/port-forwards.sh: ArgoCD 8443, Eureka 8761, Spring Boot Admin 9090, Prometheus 9091, Grafana 3000, Zipkin 9411. Passwords go to the clipboard, never on screen.
- Only 5 of 8 services expose /actuator/prometheus (config-server, discovery-server and admin-server lack the Prometheus metrics library). Explain in A6-3.
- ArgoCD dex, notifications and applicationset scaled to 0 to save pods.
- Raised JVM memory requests from 128Mi to 384Mi (real use ~300Mi) so the scheduler does not overpack nodes. ~62% of node memory requested on 5 nodes (commit 152e6f9).
- Brought CLAUDE.md and .claude/rules (kubernetes.md, helm.md) in line with what was built, and removed a hardcoded example account ID from helm.md, so the security audit reviews against accurate rules (commits f294bc6, 5814724, 9855d06).

### 10. Hook false positive #3
- block-secret-commit.sh blocked a commit because the commit MESSAGE contained the word for the kube config file (it matches the word anywhere in the git command). Nothing secret was staged. Claude stopped and asked; I chose to reword the message.

### 11. Security audit and fix (A3)
- security-auditor subagent, read-only: 0 Critical, 3 High, 7 Medium, 10 Low, Overall Score 6.5/10.
  - H-1: hooks don't really protect dev (guards only petclinic-prod; -chdir and -n bypasses; warn hook never blocks; fail open if jq missing).
  - H-2: ArgoCD default project + auto-sync/prune/self-heal.
  - H-3: every pod can reach RDS, apps use the master DB user, no NetworkPolicies.
- Claude spot-checked the auditor before relaying and corrected 3 claims (M-6 partly wrong, L-6 wrong line numbers, L-1 ID was the template's example, not mine).
- I chose to fix H-1: it enforces the core "human control" rule and can be proven with tests. H-2, H-3 and M-1..M-7 go to A9 Q6.
- H-1 fix: new shared parser .claude/hooks/lib/command-parse.sh; destroy and apply -destroy blocked whatever flags come first; kubectl delete blocked in petclinic-dev and -prod in any flag order (also when no -n is given, and delete -f on petclinic manifests); terraform apply now ASKS me (permissionDecision); all hooks fail closed (exit 2) if jq is missing or the JSON is invalid; 15 permissions.deny rules as a second layer.
- Verified with scripts/test-hooks.sh: 53 cases. Old hooks failed 35, new hooks pass 53/53.
- rm hook false positive (rm -rf "$OLD" plus the text "scripts/"). Claude restructured the command instead of working around the hook.
- Live proof: during the re-audit the new apply hook paused Claude and asked me before a command containing "terraform apply" (only test text inside a Python script, so I approved). Asking is the safe default.
- Re-audit: H-1 partly resolved, score 6.5 -> 7.0/10. Commit f5d4acd. Confirmed: fail-closed, apply asks (incl. sudo / bash -c), dev+prod kubectl delete guards, valid deny rules, 53/53 tests.
- Still bypassable (auditor-tested): shell keywords (if/then, for/do, !), indirection (\terraform, $(which terraform), T=terraform; $T destroy), find -exec / xargs / env -S, kubectl value flags (-v 5), alias k; slow parsing of very long commands (MED-008).
- Claude corrected its own claim (it said the changes were uncommitted; they were committed) and refused to route around the hook when it blocked its own test.
- LESSON: hooks only filter what Claude types. The real protection is IAM + Kubernetes RBAC (e.g. Claude's AWS identity has no rights to delete EKS/RDS).
- A3 COMPLETE.

### Production improvements added (A9 Q6)
- block-secret-commit.sh should match only file paths being added, not the whole command (3 false positives).
- HIGH-001 leftovers: shell keywords, indirection, find/xargs/env, kubectl value flags; add kubectl deny rules; cap input length.
- H-2: ArgoCD AppProject limited to this repo and petclinic-dev, no cluster-scoped resources; branch protection on main.
- H-3: VPC CNI NetworkPolicies (default deny + per-service allows) and a non-master DB user for the apps.
- M-1: RDS require_secure_transport. M-2: KMS encryption for K8s secrets. M-5: read-only root filesystem + emptyDir /tmp, PSA restricted. M-6: pin images by digest, IMMUTABLE tags.

### Screenshots added
| File | Use |
|---|---|
| 02-A3-1a-audit-request-subagent.png | A3-1 (prompt + subagent) |
| 02-A3-1b-audit-score-and-h1.png | A3-1 (6.5/10 + H-1) |
| 02-A3-1c-audit-high-findings.png | A3-1 (H-2, H-3) |
| 03-A3-2a-hook-tests-before-after.png | A3-2 (35 fail -> 53/53 pass) |
| 03-A3-2b-reaudit-score.png | A3-2 (7.0/10) |
| 03-A3-2c-remaining-bypasses.png | A3-2 (honest limits) |
| extra-02-claude-memory-requests-384mi.png | Extra |
| extra-03..05 audit medium/low/order | Extras |
| extra-06-hook-asks-before-apply.png | Extra (live hook proof) |
| extra-07-reaudit-next-steps.png | Extra |

Required screenshots so far: 5 of 22 (02, 03, 06, 19, 20).

### Commits (Day 2, platform repo)
| Commit | What |
|---|---|
| 6cadf1e | Helm chart, values, ESO, ArgoCD apps |
| f366a71 | Build-day scripts + spec drift |
| 152e6f9 | 384Mi memory requests |
| f294bc6, 5814724, 9855d06 | CLAUDE.md + rule files match the build |
| f5d4acd | fix(H-1): hooks + test-hooks.sh |

## Next (Fri 20 Nov, $0)
- Pre-flight: EC2 vCPU quota for 5 x t4g.small, AWS plan check.
- Architecture diagram (A2).
- Draft A3 answers.
- Saturday run-sheet (commands + screenshots in order).

---

## Day 3 — Sat 21 Nov 2026 (build day)

### 12. Pre-flight and apply
- PRE-FLIGHT CATCH: EC2 On-Demand Standard vCPU quota in eu-central-1 = 5. The plan needed 5 x t4g.small = 10 vCPU, so only 2 nodes would start and pods would stay Pending.
- DECISION (A2): 2 x t4g.large (4 vCPU, 16 GiB, 35 pods/node), min = max = 2 (a third node would exceed the quota, so node-group updates must not run while the cluster is up). ~$0.15/hr for nodes; lost the t4g.small free trial (negligible). Requested a quota increase to 16, did not wait for it. Commit c02a723.
- terraform apply: 26 added (EKS 1.37, 2 x t4g.large, RDS, IRSA). kubectl get nodes: 2 Ready, arm64, AL2023, one node per AZ.
- Architecture diagram generated by Claude while apply ran: docs/architecture.drawio (commit 8e1d6d0).

### 13. Add-ons install on a slow link
- install-addons.sh stopped at kube-prometheus-stack: "failed to download openapi ... context deadline exceeded" + many Client.Timeout errors. Cause: slow, unstable link from Ghana to the EKS API in Frankfurt; Helm downloads the whole OpenAPI schema and the Prometheus CRDs are very large. Steps a-d were fine (ESO had already synced the DB secret).
- Hardened install-addons.sh (b5f5bf7): every helm install via one helper (--disable-openapi-validation, --timeout, retries), kubectl --request-timeout=120s, Prometheus CRDs applied server-side one file at a time, charts cached locally; kube-prometheus-stack pulled via OCI (ghcr.io) because its index.yaml is many MB and also timed out.
- Claude changed my instruction for a good reason: it does NOT uninstall a stuck release that was deployed before (uninstalling External Secrets would delete its CRDs and the synced RDS secret); it rolls back instead. Only never-deployed releases are uninstalled.
- Claude tested the retry/skip logic offline against a stubbed helm (6 cases) before I ran it.
- Second run: chart download for the LB Controller timed out 3x (my home internet, not only the EKS API). Re-ran with HELM_TIMEOUT=25m HELM_ATTEMPTS=5 -> SUCCEEDED (~21:05): LBC, ESO (RDS secret synced), Zipkin, kube-prometheus-stack, ArgoCD v3.6.2, root app -> all 8 apps Synced + Healthy in sync-wave order (config 0 -> discovery 1 -> others 2 -> visits 3).
- App URL: http://petclinic-dev-alb-811440813.eu-central-1.elb.amazonaws.com
- Deployment date for A1: 21 November 2026.

### 14. Capture session (~21:10-22:15)
- A4-3b ArgoCD: 9/9 Synced + Healthy (Healthy 9, Degraded 0). A4-4: 8 pods Running 1/1, 0 restarts.
- A5: homepage, owners list, Jean Coleman (2 pets with visit history), new visit "DMI FINAL VISIT" for George Franklin's cat Leo, veterinarians with specialties. All 5 checks passed.
- A6-1 Eureka: 6 instances UP (config-server and discovery-server don't register, by design).
- A6-2 Spring Boot Admin: "all up", 6 applications, version 4.0.1.
- A6-3 Prometheus: sum by (job) (http_server_requests_seconds_count) -> 5 jobs climbing (only 5 of 8 services expose metrics).
- A6-4 Grafana "Spring Petclinic Metrics": HTTP latency + activity, Visit Created = 8; Owners/Pets panels N/A because none were created.
- A6-5 Zipkin: /api/customer/owners trace = 3 services, 26 spans (api-gateway -> customers-service -> 22 JDBC spans to RDS "petclinic"). Shows an N+1 query pattern (one pets query per owner).
- Zipkin findings: health checks and Prometheus scrapes flood traces (needed minDuration 5ms + limit 250); /api/gateway/owners/{id} aggregation endpoint's downstream calls appear as separate traces (context propagation gap on that path).
- A4-2 console: EKS Active 1.37, 2 nodes Ready (t4g.large), RDS Available, 8 ECR repos, ALB Active internet-facing, VPC. Account ID blurred.

### 15. Teardown (A8)
- port-forwards stopped; teardown-addons.sh deleted the 8 apps + root app, the api-gateway Ingress, waited until the ALB and target groups were gone, uninstalled kube-prometheus-stack, Zipkin, External Secrets, ArgoCD, LB Controller. Leftover check: helm releases, ingresses, LoadBalancer services, PVCs, ALB, target groups, controller SGs, detached EBS volumes = none.
- terraform destroy: 71 destroyed (~22:45).
- CLI leftover sweep in eu-central-1: EKS, EC2 instances, ALBs, EBS volumes, Elastic IPs, NAT gateways, RDS instances, ECR repos, Secrets Manager = none.
- LEFTOVER FOUND: automated RDS snapshot rds:petclinic-dev-mysql-2026-11-21-19-42 (from 7-day backup retention). PENDING RE-CHECK on Day 4; delete with delete-db-instance-automated-backup if AWS has not removed it.
- Remaining on purpose: S3 state bucket + DynamoDB lock table (<$0.01/month), delete after submission.
- Only the AWS default VPC remains in the VPC list (not a project resource).

### Production improvements added (A9 Q6)
- Exclude /actuator/** from tracing and lower sampling; fix trace propagation on the gateway aggregation endpoint.
- Fix the N+1 query (fetch pets with owners in one query).
- Request a vCPU quota that allows rolling node updates (surge node).

## Next (Day 4)
- Re-check RDS snapshot, A8-2 console screenshots.
- Tidy + export diagram.
- Write the submission document (A1-A9), then LinkedIn post and blog.
