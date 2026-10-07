# Runbook: deploying to the app host (domain service, BFF, migrations)

The app host (`aws_instance.domain_service`, tag `Name=cv-project-domain-service`) runs MySQL, the domain service and the BFF as containers. Since T-044 a new image or a new migration reaches it **without replacing the host**, through `/usr/local/bin/cv-redeploy` (root only, 0750), which the provisioning script writes at boot.

```
cv-redeploy migrate          # refresh /opt/cv-database (git pull --ff-only), run Flyway exactly as boot does
cv-redeploy domain-service   # ECR login, pull :latest, print old/new image ids, recreate ONLY this container
cv-redeploy bff-node         # same, for the BFF
```

Any other argument prints usage and exits 2. Each container's run arguments exist once, in `/usr/local/lib/cv-app.sh` (`cv_run_flyway`, `cv_run_domain_service`, `cv_run_bff_node`), which boot and `cv-redeploy` both source. Secrets are read from SSM at call time and never printed. Downtime is that one container's restart (seconds to under a minute for the JVM).

## Running a command on the host

No SSH. Use SSM Run Command (needs your own AWS credentials):

```bash
IID=$(aws ec2 describe-instances --region eu-west-3 \
  --filters Name=tag:Name,Values=cv-project-domain-service Name=instance-state-name,Values=running \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)

CMD=$(aws ssm send-command --region eu-west-3 --instance-ids "$IID" \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["/usr/local/bin/cv-redeploy domain-service"]' \
  --query Command.CommandId --output text)

aws ssm get-command-invocation --region eu-west-3 --command-id "$CMD" --instance-id "$IID" \
  --query '[Status,StandardOutputContent,StandardErrorContent]' --output text
```

### CI deploys use documents, and so can you

Since T-047 the GitHub Actions workflows (cv-domain-service, cv-bff-node) deploy with the parameterless SSM documents `cv-redeploy-domain-service` and `cv-redeploy-bff-node`, each running exactly `/usr/local/bin/cv-redeploy <svc>`, targeting the host **by tag** because it is replaced often:

```bash
aws ssm send-command --region eu-west-3 --document-name cv-redeploy-domain-service \
  --targets Key=tag:Name,Values=cv-project-domain-service \
  --query Command.CommandId --output text
```

Since T-049 cv-database's workflow (T-158) applies production migrations the same way with `cv-redeploy-migrate` (no parameters, runs exactly `/usr/local/bin/cv-redeploy migrate`), through the role `cv-project-database-migrate` (OIDC, `cv-database` master only; its ARN is the `database_migrate_role_arn` output, set as cv-database's repo variable `AWS_DEPLOY_ROLE_ARN`). That role has no ECR access and can send only its own document, to the tagged app host only:

```bash
aws ssm send-command --region eu-west-3 --document-name cv-redeploy-migrate \
  --targets Key=tag:Name,Values=cv-project-domain-service \
  --query Command.CommandId --output text
```

Operators can send the same documents by hand (instead of `AWS-RunShellScript` above); poll with `get-command-invocation` or `list-command-invocations --command-id <id> --details`. The workflows' OIDC roles can send only their own document and only to instances tagged `Name=cv-project-domain-service`; no deploy credential exists on the CI host.

Poll `get-command-invocation` until `Status` is `Success` (or `Failed`). The output contains the old and new image ids; keep them (see Rollback).

## Deploying a new image

1. **Save the current digests first.** ECR keeps only `:latest` and the 4 previous `:<sha>` images per repo (`registry.tf` lifecycle, T-050), plus up to 20 untagged children; a digest you replaced by re-pushing `:latest` becomes untagged and is eventually gone:
   ```bash
   aws ecr describe-images --region eu-west-3 --repository-name cv-project-domain-service \
     --query 'sort_by(imageDetails,&imagePushedAt)[].[imageDigest,imageTags]' --output text
   ```
2. Build and push to `:latest` from the service repo, **multi-arch** because the app host is arm64 (t4g.micro, T-035) while the CI host is x86: `docker buildx build --platform linux/amd64,linux/arm64 --push -t <repo>:latest .` (needs QEMU once per boot: `docker run --privileged --rm tonistiigi/binfmt --install arm64`). An amd64-only push breaks the host at the next pull. (`<acct>.dkr.ecr.eu-west-3.amazonaws.com/cv-project-domain-service` or `cv-project-bff-node`; log in with `aws ecr get-login-password | docker login --username AWS --password-stdin <registry>`).
3. `cv-redeploy domain-service` or `cv-redeploy bff-node` via SSM as above.
4. **Verify**: the digest printed as `new=` differs from `old=`; `docker ps` shows the container up (via a second send-command, or Session Manager); then hit it: `curl -s localhost:3000/health` on the host, and `https://<cloudfront domain>/bff/api/v1/people/1` returns 200 from outside.

## A schema change

Hibernate validates the schema at startup, so the order is fixed: **migrate first, then the domain service.**

**Ordering rule (T-049/T-158):** a schema change merges in `cv-database` **first**, and its migrate run (the cv-database workflow, document `cv-redeploy-migrate`) must be **green** before the `cv-domain-service` change that needs it merges. The domain service runs Hibernate `ddl-auto: validate` and its master push deploys itself, so merging it first deploys an image that fails to start and takes the API down. There is no cross-repo guard; the order is a rule.

1. Merge the migration to `cv-database` master (the host pulls master).
2. `cv-redeploy migrate`. It is a no-op when the schema is current (Flyway reports "Schema is up to date").
3. Push the new domain-service image, `cv-redeploy domain-service`.

Migrations are forward-only; there is no `migrate` rollback. A failed Flyway run leaves the running containers untouched (migrate never touches containers).

## Rollback

`cv-redeploy` always pulls `:latest`, so rolling back means making `:latest` the old image again:

1. Find the previous image's digest (saved in step 1 above, or the `old=` image id printed by the redeploy; the image id is the config digest, so prefer the **ECR** digest from `describe-images`).
2. Retag it as `:latest` without a rebuild:
   ```bash
   MANIFEST=$(aws ecr batch-get-image --region eu-west-3 --repository-name cv-project-domain-service \
     --image-ids imageDigest=sha256:<previous> --query 'images[0].imageManifest' --output text)
   aws ecr put-image --region eu-west-3 --repository-name cv-project-domain-service \
     --image-tag latest --image-manifest "$MANIFEST"
   ```
   (or `docker pull` it by digest, `docker tag`, `docker push`).
3. `cv-redeploy <service>` again and verify.

**Lifecycle caveat (T-050):** per repo, ECR keeps only `:latest` and the 4 previous `:<sha>` images (each with its per-arch children, which fit the 20-untagged rule). Rollback to anything older is **not possible from ECR**; the local tarballs in `~/.local/share/cv-image-backups/` are the fallback (`docker load`, retag, push). Roll back soon. A schema migration is not rolled back by any of this.

## What still needs a host replacement

`cv-redeploy` rolls images and migrations. It does **not** change how a container is configured, because the run arguments are baked into the library the host wrote at boot. These still replace the host (`terraform apply`; the stub embeds the script's SHA-256, so the plan shows `aws_instance.domain_service` replaced):

- any change to `templates/domain-service-provision.sh`: a container's run arguments, env vars, ports, the MySQL/Flyway pins, the backup timer, `cv-redeploy` itself;
- a new or renamed SSM parameter the containers read (the library calls `param` at run time, but a **new** variable must be added to a `cv_run_*` function);
- AMI or instance-type changes.

MySQL's data lives on its own EBS volume (T-018) and survives a replacement; expect 3 to 5 minutes of downtime. Save the ECR digests before applying, as above. `db_password` must not be rotated (T-021).
