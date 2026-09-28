# CLAUDE.md — cv-infra

Infrastructure as code for cv-project: Terraform (AWS provider ~>5.0), **cost-constrained but credit-funded — see "Cost model" below; the old "Free Tier only" rule does not apply to this account.** Applied for real to account `760904708057`, eu-west-3. Cross-repo context: meta repo CLAUDE.md one directory up.

## Commands

Offline gate (no AWS credentials, no network, never touches the real backend or state — this is what CI/lint-all and `terraform test` run):

```bash
terraform fmt -recursive          # CI/lint-all check formatting — run before committing
terraform init -backend=false     # since the T-004 backend "s3" block landed, plain `terraform init`
                                   # tries to reach the real bucket/table; -backend=false skips that
terraform validate
terraform test                    # tests/plan.tftest.hcl — runs OFFLINE via mock_provider
bash scripts/check-t008-static.sh          # T-008: two properties plan-time `terraform test` can't see
                                            # (a sensitive output, a policy pinned by hash) — see the
                                            # script's own header for why
bash scripts/tests/run-drone-reseed-tests.sh   # T-008: offline harness for scripts/drone-reseed-secrets.sh
                                                # (stubs `aws` and the Drone API; no AWS/network needed)
```

Both `scripts/check-t008-static.sh` and `scripts/tests/run-drone-reseed-tests.sh` are cv-infra-local additions (T-008) — they are not part of the meta repo's `scripts/lint-all.sh` / `scripts/test-all.sh` orchestration, so run them directly from here as shown above.

Real usage (needs AWS credentials, `terraform.tfvars`, and the state bucket/table from `bootstrap/` to already exist — see `bootstrap/README.md`):

```bash
terraform init      # plain init — reads the real backend "s3" block, needs credentials
terraform plan
terraform apply
```

## Layout

One root module, one file per concern: `providers.tf`, `variables.tf`, `network.tf` (default VPC + SGs), `compute.tf` (EC2), `frontend.tf` (S3+CloudFront), `auth.tf` (Cognito), `iam.tf`, `observability.tf` (log groups), `ssm.tf` (parameters), `outputs.tf`. New resources join the matching file or get a new single-concern file. **MySQL is self-hosted** in a container on the domain-service EC2 (`templates/domain-service-user-data.sh`), not RDS — see the decision below.

There is also `bootstrap/`, a **separate root module with its own local state** (T-004 part 2). It creates the S3 bucket and DynamoDB table the main module's `backend "s3"` block (`providers.tf`) points at — the main module never manages the bucket it stores its own state in. See `bootstrap/README.md` for the bootstrap/apply/migrate order and the rollback procedure.

## Remote state

State lives in S3 (`cv-project-tfstate-760904708057`, bucket versioning + SSE-S3 + a public-access block + a deny-non-TLS policy + `prevent_destroy`), locked via a DynamoDB table (`cv-project-tfstate-lock`, `PAY_PER_REQUEST`, hash key `LockID`). Both are created by `bootstrap/`, not by this module.

- **Why DynamoDB and not S3-native locking:** Terraform here is pinned to **1.9.8**. S3-native locking (`use_lockfile` on the `backend "s3"` block, no DynamoDB table needed) needs **Terraform >= 1.10**. When the toolchain is upgraded past 1.10, switch `providers.tf`'s backend block to `use_lockfile = true` and drop `dynamodb_table` (and decommission the lock table) **in that same PR** — not as an incidental side effect of an unrelated toolchain bump, and not before the upgrade actually lands.
- **Local-state backup convention.** Before any state-affecting operation (a backend migration, an out-of-band edit, anything riskier than a routine `apply`), copy `terraform.tfstate` and `terraform.tfstate.backup` to `~/.local/share/cv-infra-state-backups/<date>/` — directory `0700`, files `0600`. This lives outside the repo and outside `cv-infra/` itself on purpose: a mistake that damages the working tree (or the bucket) shouldn't also destroy the one copy that could recover it. This covers `bootstrap/terraform.tfstate` / `.tfstate.backup` too, once bootstrap's own apply creates them — that file is the only record of the bucket/table's real attributes until the next apply; losing it without a backup means falling back to a `terraform import` recovery (see `bootstrap/README.md`).
- **Rotation decision (T-004 part 3): accept, no rotation.** `db_password`, `drone_rpc_secret`, `drone_github_client_secret` sat in local state at `0664` until 2026-08-24 (`0600` since). Single-user machine, gitignored files, closed exposure window — judged low enough risk not to rotate. `db_password` specifically has an additional blocker regardless: see T-021 (meta repo task board — cv-infra has no `.claude/` of its own) — rotating it before that lands means Flyway auth fails against the persistent MySQL volume's original credentials and the box comes up with no domain-service container at all. Full reasoning in `bootstrap/README.md`.

## Binding constraints & decisions

- **Cost model — read this before citing "Free Tier". Figures measured 2026-08-19 (T-020); re-read them, do not inherit them.** This account was created 2026-07-12, so it is on AWS's **post-July-2025 Free Tier**: a fixed pot of signup credits and a 6-month window, **not** the legacy 12-month allowance. There is **no 750 h/month EC2 allowance here**, so every instance-hour bills and is paid from credits (net invoice $0 so far).

  | Measured 2026-08-19 | |
  |---|---|
  | Plan | **FREE**, ACTIVE, expires **2027-01-12** |
  | Credits remaining | **$111.08** of a **$160** grant |
  | Run rate | **~$0.68/day ≈ $21/month** |
  | Binding constraint | **the window**, not the credits (credits last to ~2027-01-28) |

  **The rate assumes a specific instance state, and that is the whole point of writing it down**: `cv-project-domain-service` (`t3.micro`) running 24/7, and the `cv-project-drone` CI host (`t3.small`) **stopped except during builds** — which is what T-019's on-demand automation now enforces. Leave that CI host running continuously and the rate goes to **~$1.23/day ≈ $37/month**, which pushes credit exhaustion forward to **~2026-11-17** and makes the credits bind ~8 weeks before the window. The crossover is **$0.76/day**: below it the window binds, above it the credits do. So "is the CI host up?" is a runway question, not a convenience one.

  Read the numbers yourself rather than trusting this table — the console is **not** required, contrary to what T-010 recorded:

  ```bash
  aws freetier get-account-plan-state     # plan type, remaining credits, expiry
  aws freetier list-account-activities    # the $20 credit-earning activities
  aws ce get-cost-and-usage --granularity DAILY --metrics UnblendedCost \
    --filter '{"Dimensions":{"Key":"RECORD_TYPE","Values":["Usage"]}}'
  ```

  That last filter is not optional: without it Cost Explorer nets credits out and reports ~$0, which is the same "reads green until it doesn't" trap `budgets.tf` exists to avoid.

  Two $20 credit-earning activities remain `NOT_STARTED` (Bedrock, Lambda). They are **optional** — while the window binds first, extra credits buy nothing. The binding constraint is **credit runway and the 6-month cliff, not instance class** — decision tracked as T-012 (due **2026-11-01**), model as T-020. Keep resources modest because credits are finite, not because a class is "free".
  - Still true regardless: **no NAT gateway** (~$32/mo — that single resource would cost more than the entire current bill), CloudFront default cert, and note that **every public IPv4 costs ~$3.60/mo** — the two EIPs are now **~34%** of the bill (they were ~26% when the rate was $28/mo; a fixed cost becomes a bigger share as the variable part shrinks, so this percentage moves without anyone touching an EIP).
  - T-019 and T-009 added two Lambdas, an EventBridge schedule, a Function URL and a private S3 bucket. All are **effectively $0** at this volume — a few invocations a month and a 14 KB object — and none changes the table above.
  - `aws_instance.drone` is `t3.small` (T-002) for Maven headroom. `terraform test` asserts instance classes; those assertions now encode a cost-discipline convention rather than a Free Tier boundary.
- **No RDS — MySQL is self-hosted** on the domain-service EC2 (MySQL 8.4 container, Flyway-migrated at boot, data on a host volume). This was a deliberate move off `db.t3.micro` RDS: it removed the instance cost **and** the MySQL 8.0 Extended Support per-vCPU charge that began Aug 2026. Trade-off: no managed backups/patching/HA — durability rests on the instance's volume, and a `mysqldump→S3` job is the intended backup. A `t3.small` is recommended over `t3.micro` for the DB+app box for RAM headroom.
- **No SSH anywhere.** Shell access is SSM Session Manager via the instance profile in `iam.tf`. Do not add port-22 ingress or key pairs back.
- Secrets flow: values land in SSM Parameter Store (`/cv-project/<env>/…`); services read them at runtime via the instance role. Never put secrets in tfvars committed files — `terraform.tfvars` is gitignored, `.example` carries placeholders.
- **Exception: `.../deploy/drone-deploy/*` (T-008).** The drone-deploy IAM user's own access key (`aws_iam_access_key.drone_deploy`, `iam.tf`) lives in SSM at `.../deploy/drone-deploy/{access-key-id,secret-access-key}`, deliberately **outside** `ci/*` and read by **no instance role** — the Drone CI host's own role only reads `ci/*`, and build containers on that host can reach it until T-007/T-005. This credential is read only by an operator's own AWS credentials, off-host, via `scripts/drone-reseed-secrets.sh` over an SSM port-forwarding tunnel to Drone (see `docs/drone-host-backup-and-cutover.md`). Before this task the credential's only copy was in Drone's SQLite on the CI host's unencrypted root volume.
- `.terraform.lock.hcl` **is committed** (HashiCorp guidance). Provider/version bumps are their own PR.
- CloudFront serves the SPA fallback (403/404 → `/index.html`) and reaches S3 only through OAC + bucket policy — if you touch `frontend.tf`, keep both, they're what make the distribution work at all.

## Testing convention

`tests/plan.tftest.hcl` uses `mock_provider "aws"` with mocked data sources so plans run without credentials — extend the mocks when you add data sources, and add an assertion when a task pins a resource property (e.g. instance classes).

## Code review guidance

Priorities, ranked:

1. **Security exposure.** Any new ingress rule wider than the resource needs (especially `0.0.0.0/0` on a non-web port), SSH/port-22 ingress or key pairs reintroduced, or a secret placed in a committed file rather than SSM Parameter Store / `terraform.tfvars` (gitignored).
2. **Cost drift.** A resized instance class, an added NAT gateway, an extra public IPv4, or any materially expensive resource without an explicit, deliberate note — `terraform test` assertions must be updated in the same PR if a class changes. Judge this against **credit burn** (**~$21/mo measured 2026-08-19** with the CI host stopped between builds; finite pot, 6-month cliff — see the cost model above, and T-020 for how it was measured), not against Free Tier eligibility. Note the largest single lever is not a resource at all: leaving the CI host running 24/7 adds **~$17/month**, more than any instance class change in this repo.
3. **`user_data` changes without `user_data_replace_on_change`.** A bootstrap-script edit that doesn't force instance replacement will silently update Terraform state without ever re-provisioning the box (this exact bug shipped once — see git history on `compute.tf`).
4. IAM policy changes broader than least-privilege (e.g. `Resource: "*"` where a scoped ARN would do).

Don't flag:
- Self-hosted MySQL 8.4 on the domain-service EC2 instead of RDS, or the lack of managed backups/HA for it — a deliberate, documented cost/lifecycle trade-off (mysqldump→S3 is the planned mitigation, tracked separately).
- `lifecycle { ignore_changes = [ami] }` on the EC2 resources — intentional, rebuilt deliberately via `-replace`.

## Git workflow

`master` is protected — feature branch (`feat/…`) → push → PR via `gh`. Definition of done: fmt + validate + test all pass offline.
