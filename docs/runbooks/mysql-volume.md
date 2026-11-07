# Runbook: swapping the MySQL data volume (T-066: 8 GiB → 2 GiB)

EBS volumes cannot shrink, and the provider plans a size change as an in-place modify that AWS rejects at apply time, half-way through a host swap. So the 2 GiB volume is a **new resource** (`aws_ebs_volume.mysql_data_v2`, `storage.tf`), and the original 8 GiB `aws_ebs_volume.mysql_data` is **forgotten, not destroyed**, by a `removed { lifecycle { destroy = false } }` block. It stays in AWS, detached, as the rollback until you delete it (step 7).

The volume id is baked into the provision script, so the apply replaces the **host** too: expect **~8–10 minutes** of `/api` and `/bff` down, and an **empty database** (Flyway's schema, no rows) until step 5 restores the nightly dump. Don't edit the CV through the admin during the window.

Dump size is a few KB (4.4 KB on 2026-11-07), so every step is quick; the wait is the host replacement.

## 1. Fresh backup (before anything changes)

```bash
IID=$(aws ec2 describe-instances --region eu-west-3 \
  --filters Name=tag:Name,Values=cv-project-domain-service Name=instance-state-name,Values=running \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)
aws ssm send-command --region eu-west-3 --instance-ids "$IID" --document-name AWS-RunShellScript \
  --parameters 'commands=["systemctl start mysql-backup.service"]' --query Command.CommandId --output text
# the newest object must be seconds old:
aws s3 ls s3://cv-project-mysql-backup-dev/mysql-dumps/ | tail -2
KEY=$(aws s3api list-objects-v2 --bucket cv-project-mysql-backup-dev --prefix mysql-dumps/ \
  --query 'sort_by(Contents,&LastModified)[-1].Key' --output text); echo "$KEY"
```

## 2. Baseline: exact row counts and a hash of the public CV

`information_schema.table_rows` is an estimate for InnoDB, so count for real:

```bash
cat > /tmp/rowcounts.sh <<'SH'
PW=$(aws ssm get-parameter --with-decryption --region eu-west-3 --name /cv-project/dev/db/password --query Parameter.Value --output text)
docker exec -e MYSQL_PWD="$PW" mysql sh -c 'for t in $(mysql -uroot -N -e "SHOW TABLES" cv); do echo "$t $(mysql -uroot -N -e "SELECT COUNT(*) FROM \`$t\`" cv)"; done'
SH
python3 -c 'import json;print(json.dumps({"commands":open("/tmp/rowcounts.sh").read().splitlines()}))' > /tmp/rowcounts.json
CMD=$(aws ssm send-command --region eu-west-3 --instance-ids "$IID" --document-name AWS-RunShellScript \
  --parameters file:///tmp/rowcounts.json --query Command.CommandId --output text); sleep 8
aws ssm get-command-invocation --region eu-west-3 --command-id "$CMD" --instance-id "$IID" --query StandardOutputContent --output text
curl -s https://erfeamor.com/bff/api/v1/people/1/cv | sha256sum
```

On 2026-11-07: `education 3, experience 8, flyway_schema_history 2, person 1, person_skill 30, project 2, skill 30`; keep your own output, it is what step 6 compares against. The password is read on the host and never printed.

Note the old volume's id now (you need it in step 7), from the terraform directory:

```bash
terraform state show aws_ebs_volume.mysql_data | grep -E '^\s+id\s'
```

## 3. Review the plan

After the PR is merged and `master` pulled, `terraform plan` must show:

- `aws_ebs_volume.mysql_data will no longer be managed by Terraform, but will not be destroyed` (and **no** `destroy` line for it);
- `aws_ebs_volume.mysql_data_v2 will be created` (size 2);
- the instance, its EIP association and the volume attachment replaced; the S3 provision object and its SHA-256 parameter updated.

If the plan says the old volume will be **destroyed**, stop: the `removed` block is missing.

## 4. Apply

`terraform apply`. The old instance is stopped cleanly first (the attachment has `stop_instance_before_detaching`), then replaced; the new host boots, formats the empty 2 GiB volume, starts MySQL, runs Flyway and the domain service.

## 5. Restore the dump

The instance role can upload backups but not read them (deliberately; no IAM change), so the host fetches the dump through a **10-minute presigned URL** made with your own credentials. It shows in the SSM command text for that window; the dump is CV data, no secrets.

```bash
URL=$(aws s3 presign "s3://cv-project-mysql-backup-dev/$KEY" --region eu-west-3 --expires-in 600)
IID=$(aws ec2 describe-instances --region eu-west-3 \
  --filters Name=tag:Name,Values=cv-project-domain-service Name=instance-state-name,Values=running \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)
cat > /tmp/restore.sh <<SH
set -euo pipefail
PW=\$(aws ssm get-parameter --with-decryption --region eu-west-3 --name /cv-project/dev/db/password --query Parameter.Value --output text)
curl -sSf "$URL" | gunzip | docker exec -i -e MYSQL_PWD="\$PW" mysql mysql -uroot cv
echo restored
SH
python3 -c 'import json;print(json.dumps({"commands":open("/tmp/restore.sh").read().splitlines()}))' > /tmp/restore.json
CMD=$(aws ssm send-command --region eu-west-3 --instance-ids "$IID" --document-name AWS-RunShellScript \
  --parameters file:///tmp/restore.json --query Command.CommandId --output text); sleep 10
aws ssm get-command-invocation --region eu-west-3 --command-id "$CMD" --instance-id "$IID" --query '[Status,StandardOutputContent,StandardErrorContent]' --output text
rm -f /tmp/restore.sh /tmp/restore.json
```

`mysqldump` writes `DROP TABLE IF EXISTS` + `CREATE TABLE` + `INSERT` for every table, including `flyway_schema_history`, so the restore overwrites the empty schema Flyway just made, consistently. The BFF may have cached an empty CV: `cv-redeploy-bff-node` (see `app-host-deploy.md`) if the next step shows stale data.

## 6. Verify

Re-run step 2's row counts: they must equal the baseline exactly, and the CV hash must equal too. Then: `https://erfeamor.com/` and `/admin/` render, the admin lists the same records, `/api/v1/people/1` is 401 without a token, and the nightly backup timer is active (`systemctl is-active mysql-backup.timer` on the host). `df -h /var/lib/cv-mysql` shows 2.0G.

## 7. Retire the old volume (after a few days of the new one being fine)

It costs about $0.74/month while it exists. It is detached (`available`); snapshot it, then delete it:

```bash
OLD=vol-xxxxxxxxxxxxxxxxx   # from step 2
aws ec2 describe-volumes --region eu-west-3 --volume-ids "$OLD" --query 'Volumes[0].[State,Size]' --output text   # available 8
SNAP=$(aws ec2 create-snapshot --region eu-west-3 --volume-id "$OLD" --description "T-066 final snapshot of the 8 GiB MySQL volume" --query SnapshotId --output text)
aws ec2 wait snapshot-completed --region eu-west-3 --snapshot-ids "$SNAP"
aws ec2 delete-volume --region eu-west-3 --volume-id "$OLD"
```

Then delete the `removed` block in `storage.tf` (nothing refers to it any more) in a small PR. The snapshot is billed by stored data (cents); delete it later.

## Rollback

- **Restore failed or data looks wrong, volume still fine:** the S3 dump is the source of truth; re-run step 5 (it is repeatable).
- **The new volume is unusable:** the old volume still holds the original data, detached. Reattach it by hand to the new host (`aws ec2 attach-volume`, device `/dev/sdf` after detaching the new one) and `mount` by UUID; or, cleaner, restore the dump onto a fresh volume. Do not delete the old volume before step 6 passes.

## Growing later

`var.mysql_volume_size_gb` can be **raised** in place (an EBS modify), then run `xfs_growfs /var/lib/cv-mysql` on the host. Going smaller again means another `_vN` volume and this runbook.
