# CLAUDE.md — cv-infra

Infrastructure as code for cv-project: Terraform (AWS provider ~>5.0), **cost-constrained but credit-funded — see "Cost model" below; the old "Free Tier only" rule does not apply to this account.** Applied for real to account `760904708057`, eu-west-3. Cross-repo context: meta repo CLAUDE.md one directory up.

## Commands

```bash
terraform init
terraform fmt -recursive   # CI/lint-all check formatting — run before committing
terraform validate
terraform test             # tests/plan.tftest.hcl — runs OFFLINE via mock_provider
terraform plan             # needs real AWS credentials + terraform.tfvars
```

## Layout

One root module, one file per concern: `providers.tf`, `variables.tf`, `network.tf` (default VPC + SGs), `compute.tf` (EC2), `frontend.tf` (S3+CloudFront), `auth.tf` (Cognito), `iam.tf`, `observability.tf` (log groups), `ssm.tf` (parameters), `outputs.tf`. New resources join the matching file or get a new single-concern file. **MySQL is self-hosted** in a container on the domain-service EC2 (`templates/domain-service-user-data.sh`), not RDS — see the decision below.

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
