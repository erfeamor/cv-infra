# CLAUDE.md — cv-infra

Infrastructure as code for cv-project: Terraform (AWS provider ~>5.0), targeting **AWS Free Tier only** — that constraint is binding on every resource choice. Never applied to a real account yet. Cross-repo context: meta repo CLAUDE.md one directory up.

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

- **Free Tier**: EC2 `t2/t3.micro`, default VPC (**no NAT gateway — not free**), CloudFront default cert. `terraform test` asserts the EC2 instance types — keep those assertions passing. **Exception (T-002, ratified):** `aws_instance.drone` is `t3.small`, not `t2/t3.micro` — it now co-hosts Jenkins alongside Drone, which needs the extra RAM headroom for Maven builds; net cost delta is ~+$8/mo, recorded in `variables.tf` and the T-002 PR body. This is a deliberate, one-resource carve-out, not a general licence to resize other instances.
- **No RDS — MySQL is self-hosted** on the domain-service EC2 (MySQL 8.4 container, Flyway-migrated at boot, data on a host volume). This was a deliberate move off `db.t3.micro` RDS: it removed the instance cost **and** the MySQL 8.0 Extended Support per-vCPU charge that began Aug 2026. Trade-off: no managed backups/patching/HA — durability rests on the instance's volume, and a `mysqldump→S3` job is the intended backup. A `t3.small` is recommended over `t3.micro` for the DB+app box for RAM headroom.
- **No SSH anywhere.** Shell access is SSM Session Manager via the instance profile in `iam.tf`. Do not add port-22 ingress or key pairs back.
- Secrets flow: values land in SSM Parameter Store (`/cv-project/<env>/…`); services read them at runtime via the instance role. Never put secrets in tfvars committed files — `terraform.tfvars` is gitignored, `.example` carries placeholders.
- `.terraform.lock.hcl` **is committed** (HashiCorp guidance). Provider/version bumps are their own PR.
- CloudFront serves the SPA fallback (403/404 → `/index.html`) and reaches S3 only through OAC + bucket policy — if you touch `frontend.tf`, keep both, they're what make the distribution work at all.

## Testing convention

`tests/plan.tftest.hcl` uses `mock_provider "aws"` with mocked data sources so plans run without credentials — extend the mocks when you add data sources, and add an assertion when a task pins a resource property (e.g. Free Tier classes).

## Code review guidance

Priorities, ranked:

1. **Security exposure.** Any new ingress rule wider than the resource needs (especially `0.0.0.0/0` on a non-web port), SSH/port-22 ingress or key pairs reintroduced, or a secret placed in a committed file rather than SSM Parameter Store / `terraform.tfvars` (gitignored).
2. **Free Tier drift.** A resized instance class, added NAT gateway, or any resource that isn't Free-Tier-eligible without an explicit, deliberate note — `terraform test` assertions must be updated in the same PR if a class changes.
3. **`user_data` changes without `user_data_replace_on_change`.** A bootstrap-script edit that doesn't force instance replacement will silently update Terraform state without ever re-provisioning the box (this exact bug shipped once — see git history on `compute.tf`).
4. IAM policy changes broader than least-privilege (e.g. `Resource: "*"` where a scoped ARN would do).

Don't flag:
- Self-hosted MySQL 8.4 on the domain-service EC2 instead of RDS, or the lack of managed backups/HA for it — a deliberate, documented cost/lifecycle trade-off (mysqldump→S3 is the planned mitigation, tracked separately).
- `lifecycle { ignore_changes = [ami] }` on the EC2 resources — intentional, rebuilt deliberately via `-replace`.

## Git workflow

`master` is protected — feature branch (`feat/…`) → push → PR via `gh`. Definition of done: fmt + validate + test all pass offline.
