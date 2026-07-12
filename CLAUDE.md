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

One root module, one file per concern: `providers.tf`, `variables.tf`, `network.tf` (default VPC + SGs), `compute.tf` (EC2), `database.tf` (RDS), `frontend.tf` (S3+CloudFront), `auth.tf` (Cognito), `iam.tf`, `observability.tf` (log groups), `ssm.tf` (parameters), `outputs.tf`. New resources join the matching file or get a new single-concern file.

## Binding constraints & decisions

- **Free Tier**: EC2 `t2/t3.micro`, RDS `db.t3.micro` single-AZ ≤20GB gp2, default VPC (**no NAT gateway — not free**), CloudFront default cert. `terraform test` asserts the instance classes — keep those assertions passing.
- **No SSH anywhere.** Shell access is SSM Session Manager via the instance profile in `iam.tf`. Do not add port-22 ingress or key pairs back.
- Secrets flow: values land in SSM Parameter Store (`/cv-project/<env>/…`); services read them at runtime via the instance role. Never put secrets in tfvars committed files — `terraform.tfvars` is gitignored, `.example` carries placeholders.
- `.terraform.lock.hcl` **is committed** (HashiCorp guidance). Provider/version bumps are their own PR.
- CloudFront serves the SPA fallback (403/404 → `/index.html`) and reaches S3 only through OAC + bucket policy — if you touch `frontend.tf`, keep both, they're what make the distribution work at all.

## Testing convention

`tests/plan.tftest.hcl` uses `mock_provider "aws"` with mocked data sources so plans run without credentials — extend the mocks when you add data sources, and add an assertion when a task pins a resource property (e.g. Free Tier classes).

## Git workflow

`master` is protected — feature branch (`feat/…`) → push → PR via `gh`. Definition of done: fmt + validate + test all pass offline.
