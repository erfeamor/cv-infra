# cv-infra

Infrastructure as code for the Currículum Interactivo project. Provisions everything the other seven repos deploy onto. The account is on AWS's Paid plan (since 2026-09-29), paid from credits first and then the card, so resources are kept modest on purpose. Current figures are in [CLAUDE.md](CLAUDE.md)'s cost model.

Part of the [cv-project](../README.md) multi-repo. No pipeline by design: `terraform plan`/`apply` run by hand, and every apply is human-approved. The offline gate (`terraform test`, `scripts/check-static.sh`, the script harnesses, the Lambda unit tests) is listed in `CLAUDE.md`.

## Stack

- Terraform (AWS provider `~> 5.0`)
- `terraform test` for plan-level assertions (see `tests/`)

## Resources

- **EC2 t4g.micro** (Graviton, arm64; T-035) — runs `cv-domain-service`, `cv-bff-node` (T-014) and a self-hosted MySQL 8.4 container (Flyway-migrated at boot), all as containers on the same box for the demo. Images on ECR must be multi-arch (`linux/amd64` + `linux/arm64`); the host requires IMDSv2 (hop limit 1). Deploys go through GitHub OIDC roles and per-service SSM documents (`ci-deploy.tf`; see `docs/runbooks/app-host-deploy.md`)
- **S3 + CloudFront** — hosts the built `cv-public-vanilla` (root) and `cv-admin-react` (`admin/`) static assets, and fronts the BFF (`/bff/*`) and the domain service (`/api/*`)
- **Cognito user pool + Hosted UI domain** — auth for `cv-admin-react`
- **CloudWatch log groups** — one per backend service, which the app containers write to through the awslogs driver (T-054), plus the CI doorbell and reaper Lambdas' groups
- **SSM Parameter Store** — DB password, Cognito issuer URI, the BFF's Cognito service-client credentials (`bff/*`, T-043), CI secrets (`ci/*`, readable by the Drone/Jenkins host role), and the drone-deploy IAM credentials (`deploy/drone-deploy/*`, T-008 — readable by no instance role, only by an operator running `scripts/drone-reseed-secrets.sh`; see `docs/runbooks/drone.md`)

Uses the account's default VPC with no NAT gateway, for cost: a NAT gateway alone would cost more than the whole current bill.

## State

Remote, in S3 + DynamoDB (`providers.tf`'s `backend "s3"` block) — created by `bootstrap/`, a separate root module with its own local state (see `bootstrap/README.md` for the bootstrap/apply/migrate order, the rollback procedure, and the T-004 part 3 rotation decision). Back up `terraform.tfstate`/`.backup` to `~/.local/share/cv-infra-state-backups/<date>/` (`0700`/`0600`) before any state-affecting operation.

## Usage

```bash
cp terraform.tfvars.example terraform.tfvars   # fill in db_password and an existing EC2 key pair name
terraform init
terraform plan
terraform apply
```

## Testing

```bash
terraform test    # runs tests/plan.tftest.hcl against a plan, no resources created
```
