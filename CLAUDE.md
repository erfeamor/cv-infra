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
bash scripts/check-static.sh      # invariants plan-time `terraform test` can't see: output sensitivity,
                                   # the deploy user's least-privilege policy, single-parameter SSM grants,
                                   # the CI host's ignore_changes and Lambda INSTANCE_ID wiring, the Drone DB
                                   # key on every drone-server run, and where the cloud-init wait lives
bash bootstrap/check-static.sh    # the state bucket keeps prevent_destroy
bash scripts/tests/run-drone-reseed-tests.sh   # T-008: offline harness for scripts/drone-reseed-secrets.sh
                                                # (stubs `aws` and the Drone API; no AWS/network needed)
bash scripts/tests/run-cv-redeploy-tests.sh    # T-044: offline harness for cv-redeploy (extracted from the provisioning
                                                # template; stubs docker/aws/git in scripts/tests/stub-bin-app/)
python3 -m unittest discover -s lambda -p 'test_*.py'   # T-034: offline unit tests for lambda/ci_doorbell
                                                          # and lambda/ci_reaper -- boto3/botocore are stubbed
                                                          # in lambda/testsupport.py (neither is installed here
                                                          # on purpose: these Lambdas ship as a bare index.py,
                                                          # no vendored deps), and every urllib call is
                                                          # monkeypatched per test. No AWS/network needed.
bash scripts/tests/run-ci-dns-updater-tests.sh   # T-034 phase 2: offline harness for scripts/ci-dns-updater.sh
                                                  # -- stubs `curl` (IMDSv2) and `aws` (route53) via
                                                  # scripts/tests/stub-bin-dns/, in the same style as the
                                                  # drone-reseed harness above (a separate stub-bin dir, so
                                                  # neither harness's fixtures can affect the other)
```

`scripts/check-static.sh`, `bootstrap/check-static.sh`, `scripts/tests/run-drone-reseed-tests.sh`, `scripts/tests/run-ci-dns-updater-tests.sh`, `scripts/tests/run-cv-redeploy-tests.sh` and the `lambda/` unit tests are cv-infra-local. The meta repo's `scripts/lint-all.sh` and `scripts/test-all.sh` don't run them, so run them from here as shown above.

Operational procedures live in `docs/runbooks/`: `app-host-deploy.md` (T-044: `cv-redeploy migrate | domain-service | bff-node` on the app host, schema-change order, rollback, what still needs a host replacement), `drone.md` (Drone rebuild, repo secrets, deploy-key rotation, pausing the reaper, the T-048 push grace) and `ci-host-replace.md` (replacing the CI host and verifying the new one).

Real usage (needs AWS credentials, `terraform.tfvars`, and the state bucket/table from `bootstrap/` to already exist — see `bootstrap/README.md`):

```bash
terraform init      # plain init — reads the real backend "s3" block, needs credentials
terraform plan
terraform apply
```

## Layout

One root module, one file per concern: `providers.tf`, `variables.tf`, `network.tf` (default VPC + SGs), `compute.tf` (EC2), `frontend.tf` (S3+CloudFront), `auth.tf` (Cognito), `iam.tf`, `observability.tf` (log groups), `ssm.tf` (parameters), `outputs.tf`. New resources join the matching file or get a new single-concern file. **MySQL is self-hosted** in a container on the domain-service EC2 (`templates/domain-service-provision.sh`, an S3 object since T-044; `templates/domain-service-bootstrap.sh` is the small user_data stub that fetches, hash-verifies and runs it; `app-host-provision.tf`), not RDS — see the decision below.

There is also `bootstrap/`, a **separate root module with its own local state** (T-004 part 2). It creates the S3 bucket and DynamoDB table the main module's `backend "s3"` block (`providers.tf`) points at — the main module never manages the bucket it stores its own state in. See `bootstrap/README.md` for the bootstrap/apply/migrate order and the rollback procedure.

## Remote state

State lives in S3 (`cv-project-tfstate-760904708057`, bucket versioning + SSE-S3 + a public-access block + a deny-non-TLS policy + `prevent_destroy`), locked via a DynamoDB table (`cv-project-tfstate-lock`, `PAY_PER_REQUEST`, hash key `LockID`). Both are created by `bootstrap/`, not by this module.

- **Why DynamoDB and not S3-native locking:** Terraform here is pinned to **1.9.8**. S3-native locking (`use_lockfile` on the `backend "s3"` block, no DynamoDB table needed) needs **Terraform >= 1.10**. When the toolchain is upgraded past 1.10, switch `providers.tf`'s backend block to `use_lockfile = true` and drop `dynamodb_table` (and decommission the lock table) **in that same PR** — not as an incidental side effect of an unrelated toolchain bump, and not before the upgrade actually lands.
- **Local-state backup convention.** Before any state-affecting operation (a backend migration, an out-of-band edit, anything riskier than a routine `apply`), copy `terraform.tfstate` and `terraform.tfstate.backup` to `~/.local/share/cv-infra-state-backups/<date>/` — directory `0700`, files `0600`. This lives outside the repo and outside `cv-infra/` itself on purpose: a mistake that damages the working tree (or the bucket) shouldn't also destroy the one copy that could recover it. This covers `bootstrap/terraform.tfstate` / `.tfstate.backup` too, once bootstrap's own apply creates them — that file is the only record of the bucket/table's real attributes until the next apply; losing it without a backup means falling back to a `terraform import` recovery (see `bootstrap/README.md`).
- **Rotation decision (T-004 part 3): accept, no rotation.** `db_password`, `drone_rpc_secret`, `drone_github_client_secret` sat in local state at `0664` until 2026-08-24 (`0600` since). Single-user machine, gitignored files, closed exposure window — judged low enough risk not to rotate. `db_password` specifically has an additional blocker regardless: see T-021 (meta repo task board — cv-infra has no `.claude/` of its own) — rotating it before that lands means Flyway auth fails against the persistent MySQL volume's original credentials and the box comes up with no domain-service container at all. Full reasoning in `bootstrap/README.md`.

## Binding constraints & decisions

- **Cost model — read this before citing "Free Tier". The account moved to the Paid plan on 2026-09-29; figures re-measured that day (T-012/T-020). Re-read them, don't inherit them.** The account was created 2026-07-12 on AWS's post-July-2025 Free Tier (a fixed pot of signup credits, **not** the legacy 12-month/750-hour allowance). There's **no free EC2 allowance**, so every instance-hour bills and is paid from the remaining credits first. **Since the Paid upgrade, anything the credits don't cover bills the card**: the Free plan's hard stop is gone, and the budget alarms (`budgets.tf`, two budgets, SNS to a confirmed email) are the only guard.

  | Measured 2026-09-29 | |
  |---|---|
  | Plan | **PAID**, ACTIVE (upgraded 2026-09-29) |
  | Credits remaining | **$102.13** on 2026-09-29; **$120.75 on 2026-10-01**, after the last $20 activity (Bedrock) — the grant is now **$200** (signup plus all five $20 activities) |
  | Run rate | **~$0.69/day ≈ $21/month** (09-20 to 09-28: $0.67–0.80/day, the higher days being CI host sessions) |
  | Binding constraint | **the credits**: about 5½ months from 2026-10-01 at this rate (longer since T-034 released the CI host's EIP), then the bill is real money. Check the Billing console's Credits page for any expiry date (the API doesn't expose one). |

  **The rate assumes a specific instance state, and that is the whole point of writing it down**: `cv-project-domain-service` (`t4g.micro` since T-035, Graviton/arm64, ~$6.86/month, -$1.75 vs t3.micro; the table figures above were measured on t3.micro) running 24/7, and the `cv-project-drone` CI host (`t3.small`) **stopped except during builds**, which the reaper enforces. Leave that CI host running continuously and the rate goes to **~$1.23/day ≈ $37/month**, burning the credits roughly twice as fast and then billing the card at that rate. So "is the CI host up?" is a money question, not a convenience one.

  Read the numbers yourself rather than trusting this table — the console is **not** required, contrary to what T-010 recorded:

  ```bash
  aws freetier get-account-plan-state     # plan type, remaining credits, expiry
  aws freetier list-account-activities    # the $20 credit-earning activities
  aws ce get-cost-and-usage --granularity DAILY --metrics UnblendedCost \
    --filter '{"Dimensions":{"Key":"RECORD_TYPE","Values":["Usage"]}}'
  ```

  That last filter is not optional: without it Cost Explorer nets credits out and reports ~$0, which is the same "reads green until it doesn't" trap `budgets.tf` exists to avoid.

  **All five $20 credit-earning activities are `COMPLETED`** (Bedrock, the last, on 2026-10-01), so the grant is $200. The `credit-runway` budget stays at $160 on purpose: it alerts ~$40 early, the safe side (T-012's rule: never raise it past the real grant). The endgame decision is T-012 (A, go Paid, trimmed; closed 2026-10-01), the model T-020. Keep resources modest because the money is real now, not because a class is "free".
  - Still true regardless: **no NAT gateway** (~$32/mo — that single resource would cost more than the entire current bill), CloudFront default cert, and note that **every public IPv4 costs ~$3.60/mo**. **T-034 phase 2 released the CI host's EIP** (`aws_eip.drone`, `cv-infra/ci.tf`) — replaced by a DNS name the host keeps current on every boot (`scripts/ci-dns-updater.sh`) — so there is now **one** EIP left (`aws_eip.domain_service`), not two; re-read the actual bill rather than trusting the old "~34%, two EIPs" figure, which predates that change.
  - T-019 and T-009 added two Lambdas, an EventBridge schedule, a Function URL and a private S3 bucket. All are **effectively $0** at this volume — a few invocations a month and a 14 KB object — and none changes the table above.
  - `aws_instance.drone` is `t3.small` (T-002) for Maven headroom. `terraform test` asserts instance classes; those assertions now encode a cost-discipline convention rather than a Free Tier boundary.
- **No RDS — MySQL is self-hosted** on the domain-service EC2 (MySQL 8.4 container, Flyway-migrated at boot, data on a host volume). This was a deliberate move off `db.t3.micro` RDS: it removed the instance cost **and** the MySQL 8.0 Extended Support per-vCPU charge that began Aug 2026. Trade-off: no managed backups/patching/HA — durability rests on the instance's volume, and a `mysqldump→S3` job is the intended backup. The app host is a **`t4g.micro`** (T-035: Graviton, arm64 AL2023 AMI via `data.aws_ami.al2023_arm64`; the CI host keeps the x86 `data.aws_ami.al2023`), same 1 GiB as the t3.micro it replaced; a precondition on `aws_instance.domain_service` fails the plan if the instance family and the AMI architecture disagree. **Every image it runs must be multi-arch (`linux/amd64` + `linux/arm64`)** on ECR: build with `docker buildx build --platform linux/amd64,linux/arm64 --push` (QEMU: `docker run --privileged --rm tonistiigi/binfmt --install arm64`). The ECR lifecycle expires only untagged images beyond 20, so a multi-arch `:latest` keeps its per-arch children. The app host also requires IMDSv2 (`http_tokens = required`, hop limit 1; T-005's app-host half). Moving to or from this type is a `-replace=aws_instance.domain_service` (`ignore_changes = [ami]`).
- **Push grace and the `CILastPush` tag (T-048).** Jenkins discovers pushes only by scanning (5-minute periodic trigger, plus on boot), so a push arriving while the CI host is already up used to race the reaper. The doorbell now tags the instance `CILastPush=<UTC ISO-8601>` for a verified, buildable event on a Jenkins repo (not `REDELIVER_REPOS`) when the host is `running`/`pending`; the reaper leaves the host up while the tag is younger than `PUSH_GRACE_MINUTES` (10, wired in `ci-on-demand.tf`). `CILastPush` is an **operational tag like `CIKeepAlive`**: written by the doorbell, in `aws_instance.drone`'s `ignore_changes` (`tags` and `tags_all`), never declared in Terraform. The doorbell's IAM is `ec2:CreateTags` on the CI instance ARN only, conditioned `ForAllValues:StringEquals aws:TagKeys = [CILastPush]` (`local.ci_doorbell_tag_*`; `scripts/check-static.sh` check 19 guards the scoping); the reaper needs no new IAM (DescribeInstances returns tags). A tagging failure is logged and never changes the webhook's response; a malformed tag is ignored by the reaper.
- **No SSH anywhere.** Shell access is SSM Session Manager via the instance profile in `iam.tf`. Do not add port-22 ingress or key pairs back.
- Secrets flow: values land in SSM Parameter Store (`/cv-project/<env>/…`); services read them at runtime via the instance role. Never put secrets in tfvars committed files — `terraform.tfvars` is gitignored, `.example` carries placeholders.
- **BFF service token (T-043).** The BFF calls the domain service with a Cognito client-credentials token: `aws_cognito_user_pool_client.bff_service` (only that flow, only the `cv-domain/read` scope, 24 h access tokens), whose id, secret (SecureString), token URL and scope sit under `/cv-project/<env>/bff/*` and are read at boot by `templates/domain-service-provision.sh`. The secret is never an output. The domain service validates the issuer only, so the read scope is not yet enforced there (T-116).
- **Exception: `.../deploy/drone-deploy/*` (T-008).** The drone-deploy IAM user's access key (`aws_iam_access_key.drone_deploy`, `iam.tf`) lives in SSM at `.../deploy/drone-deploy/{access-key-id,secret-access-key}`, deliberately **outside** `ci/*` and readable by **no instance role**. The CI host's role only reads `ci/*`, and the app host's role has an explicit Deny on `deploy/*`. Only an operator's own credentials read it, off-host, via `scripts/drone-reseed-secrets.sh` over an SSM port-forwarding tunnel to Drone (see `docs/runbooks/drone.md`).
- **GitHub Actions OIDC (T-045).** `github-oidc.tf` holds the account's one `aws_iam_openid_connect_provider.github_actions` (T-203 reuses it for the BFF deploy role; add roles, not a second provider) and `public_vanilla_deploy`, a keyless role assumable only by `repo:erfeamor/cv-public-vanilla:ref:refs/heads/master` (exact `sub` + `aud`, StringEquals). It writes the frontend bucket root with an explicit Deny on `admin/*` (the live admin shares the bucket) and may only invalidate this distribution; ARN in the `public_vanilla_deploy_role_arn` output. `scripts/check-static.sh` guards the Deny and the exact trust.
- **CI deploy roles and SSM documents (T-047).** `ci-deploy.tf`: `cv-project-domain-service-deploy` and `cv-project-bff-node-deploy`, OIDC roles (same provider, `StringEquals` aud + `sub = repo:erfeamor/<repo>:ref:refs/heads/master`) for the GitHub Actions workflows of cv-domain-service / cv-bff-node. **Deploy credentials live off the CI host on purpose**: Jenkins and Drone mount `docker.sock`, so any build there is root (T-005); GitHub-minted short-lived tokens never touch it. Each role may: `ecr:GetAuthorizationToken` (`*`, ECR requires it); push/read on **its own** ECR repo only; `ssm:SendCommand` on **its own document** plus `instance/*` **conditioned on `ssm:resourceTag/Name = cv-project-domain-service`** (the app host is replaced often, so workflows target it by tag: `--targets Key=tag:Name,Values=cv-project-domain-service`; the CI host has another Name and is unreachable); and `ssm:GetCommandInvocation`/`ListCommandInvocations` on `*` (no resource-level support). The documents `cv-redeploy-domain-service` / `cv-redeploy-bff-node` (schema 2.2, one `aws:runShellScript` step, 600 s) run exactly `/usr/local/bin/cv-redeploy <svc>` and declare **no parameters**, so no caller input reaches a shell; the roles cannot send `AWS-RunShellScript`. Outputs: `domain_service_deploy_role_arn`, `bff_node_deploy_role_arn`, `domain_service_redeploy_document`, `bff_node_redeploy_document` (set as repo variables). `scripts/check-static.sh` guards no-parameters and tag-conditioned, never-`*` SendCommand.
- **CI migrate role and document (T-049).** Same file, a third block for cv-database's GitHub Actions workflow (T-158): document `cv-redeploy-migrate` (schema 2.2, **no parameters**, one step running exactly `/usr/local/bin/cv-redeploy migrate`, 600 s) and OIDC role `cv-project-database-migrate`, trusted only via `StringEquals` aud + `sub = repo:erfeamor/cv-database:ref:refs/heads/master` (so the workflow's push trigger and `workflow_dispatch` must both run on master). **No ECR at all**: its policy is `ssm:SendCommand` on its own document, `ssm:SendCommand` on `instance/*` conditioned on `ssm:resourceTag/Name = cv-project-domain-service`, and `ssm:GetCommandInvocation`/`ListCommandInvocations` on `*`. Outputs `database_migrate_role_arn` (goes in cv-database's repo variable `AWS_DEPLOY_ROLE_ARN`) and `database_migrate_document`. The two plan-known statements are the named local `database_migrate_known_statements` so `terraform test` (plan-only, target-scoped) can assert them; the own-document statement carries a computed ARN, so that one and the no-ECR rule over the whole policy are guarded by `scripts/check-static.sh` 2c. **Ordering rule:** a schema change merges in cv-database first and its migrate run must be green before the cv-domain-service change that needs it merges (the domain service runs Hibernate `ddl-auto: validate`, so deploying first takes the API down); see `docs/runbooks/app-host-deploy.md`.
- **App host SSM read is an exact list (T-005).** `aws_iam_role_policy.read_parameters` Allows only the seven parameters the app host's scripts read (`app/provision-sha256`, `db/password`, `cognito/issuer-uri`, `bff/service-client-id|secret|token-url|token-scope`), by full ARN, no wildcard, no `GetParametersByPath`; the explicit Deny on `deploy/*` stays. A new `param x` in `domain-service-provision.sh` (or a `get-parameter --name`) needs its parameter added to `local.app_host_ssm_parameter_names` in `iam.tf`; `scripts/check-static.sh` fails otherwise.
- **Both instance roles carry an explicit Deny-NotResource on SSM reads (T-005 round 1).** The managed `AmazonSSMManagedInstanceCore` (attached to both roles for Session Manager and Run Command, so it stays) grants `ssm:GetParameter(s)` on `*`, which swallows the inline Allows: on its own the app host could read `ci/*` and the CI host could read `deploy/*`, `db/password` and `bff/*`. So `read_parameters` (app host) and `drone_read_ci_parameters` (CI host) each carry `Deny` on `GetParameter`, `GetParameters`, `GetParametersByPath` and `GetParameterHistory` with `NotResource` = that host's own parameter set (the app host's seven ARNs; `ci/*` for the CI host). **A host that reads a new parameter must add it to its list (app host: `local.app_host_ssm_parameter_names`; CI host: keep it under `ci/` or add its ARN to the NotResource), or the read fails with AccessDenied.** `scripts/check-static.sh` and `terraform test` guard both Denies and the template cross-check.
- **Documented accepted risk (T-005): a Jenkins build is root on the CI host (docker.sock).** The boundary is that fork PRs never build on Jenkins, and Drone steps get no docker.sock (cv-admin-react is untrusted in Drone; its `.drone.yml` mounts no host volumes). Re-open if any of these change: Jenkins starts building fork PRs, Drone's repo becomes trusted or `.drone.yml` mounts host paths, or a non-collaborator gains write access.
- `.terraform.lock.hcl` **is committed** (HashiCorp guidance). Provider/version bumps are their own PR.
- CloudFront reaches S3 only through OAC + bucket policy — if you touch `frontend.tf`, keep both, that's what makes the distribution work at all. SPA routing (extension-less URIs → the owning app's `index.html`) is done by `functions/spa-router.js` (a viewer-request CloudFront Function), **not** a `custom_error_response` fallback — `frontend.tf` has no `custom_error_response` block. (Corrected 2026-10-01, T-014: this sentence previously claimed a 403/404 → `/index.html` `custom_error_response`, which doesn't exist here.)

## Testing convention

`tests/plan.tftest.hcl` uses `mock_provider "aws"` with mocked data sources so plans run without credentials — extend the mocks when you add data sources, and add an assertion when a task pins a resource property (e.g. instance classes).

## Code review guidance

Priorities, ranked:

1. **Security exposure.** Any new ingress rule wider than the resource needs (especially `0.0.0.0/0` on a non-web port), SSH/port-22 ingress or key pairs reintroduced, or a secret placed in a committed file rather than SSM Parameter Store / `terraform.tfvars` (gitignored).
2. **Cost drift.** A resized instance class, an added NAT gateway, an extra public IPv4, or any materially expensive resource without an explicit, deliberate note — `terraform test` assertions must be updated in the same PR if a class changes. Judge this against **real monthly cost** (**~$21/mo measured 2026-09-29** with the CI host stopped between builds; paid from the remaining credits, then the card; see the cost model above and T-020), not against Free Tier eligibility. Note the largest single lever is not a resource at all: leaving the CI host running 24/7 adds **~$17/month**, more than any instance class change in this repo.
3. **`user_data` changes without `user_data_replace_on_change`.** A bootstrap-script edit that doesn't force instance replacement will silently update Terraform state without ever re-provisioning the box (this exact bug shipped once — see git history on `compute.tf`).
4. IAM policy changes broader than least-privilege (e.g. `Resource: "*"` where a scoped ARN would do).

Don't flag:
- Self-hosted MySQL 8.4 on the domain-service EC2 instead of RDS, or the lack of managed backups/HA for it — a deliberate, documented cost/lifecycle trade-off (mysqldump→S3 is the planned mitigation, tracked separately).
- `lifecycle { ignore_changes = [ami] }` on the EC2 resources — intentional, rebuilt deliberately via `-replace`.

## Git workflow

`master` is protected — feature branch (`feat/…`) → push → PR via `gh`. Definition of done: fmt + validate + test all pass offline.
