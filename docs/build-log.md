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
