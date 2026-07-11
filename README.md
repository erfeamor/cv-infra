# cv-infra

Infrastructure as code for the Currículum Interactivo project. Provisions everything the other six repos deploy onto, kept within the AWS Free Tier.

Part of the [cv-project](../README.md) multi-repo. No dedicated pipeline yet (Terraform plan/apply is run manually or from whichever CI ends up owning it).

## Stack

- Terraform (AWS provider `~> 5.0`)
- `terraform test` for plan-level assertions (see `tests/`)

## Resources

- **EC2 t3.micro** — runs `cv-domain-service` (and `cv-bff-node` alongside it for the demo)
- **RDS MySQL (Free Tier, db.t3.micro)** — backs `cv-database`
- **S3 + CloudFront** — hosts the built `cv-admin-react` / `cv-public-vanilla` static assets
- **Cognito user pool + Hosted UI domain** — auth for `cv-admin-react`
- **CloudWatch log groups** — one per backend service
- **SSM Parameter Store** — DB password and Cognito issuer URI

Uses the account's default VPC (no NAT gateway) to stay Free Tier-eligible.

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
