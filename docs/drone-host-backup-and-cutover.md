# T-008 -- drone-deploy credential cutover, SQLite rebuild rehearsal, and the one-off copy

This is the runbook for the parts of [T-008](../../.claude/tasks/T-008-drone-host-backup-and-snapshot.md)
that touch the live CI host. Everything here is **driver-run**, against the
real AWS account -- nothing in this file is executed by the code/offline
gate that built the Terraform and the reseed script it references
(`../scripts/drone-reseed-secrets.sh`).

## Background (H1, 2026-09-28)

- The credential moves out of Drone's SQLite: Terraform now creates
  `aws_iam_access_key.drone_deploy` (`../iam.tf`) and writes it to two SSM
  SecureStrings under `deploy/drone-deploy/*` (`../ssm.tf`) -- deliberately
  **not** under `ci/*`, so the Drone host's own instance role (which build
  containers can reach until T-007/T-005) can never read it.
- Drone's SQLite (`/var/lib/drone/database.sqlite` on the CI host) is
  **reconstructable, not backed up**. No new IAM grant on the CI role. A
  live rehearsal proves the rebuild. Build history is expendable.
- Encryption of the CI host's root volume happens at T-007's replacement
  (encrypted root, AWS-managed EBS key). `snap-0d7f5ae272ce0cef5`
  (unencrypted) is deleted only after the rehearsal below is proven.

## Part 1 -- apply and cutover

Run from `cv-infra/` with real credentials and `terraform.tfvars` present.

```bash
# 1. Back up state first -- this is a state-affecting apply (CLAUDE.md's
#    local-state backup convention). State itself lives in S3; this backs
#    up the last-known-good copy pulled locally, not the source of truth.
mkdir -p -m 0700 ~/.local/share/cv-infra-state-backups/$(date +%F)
terraform state pull > ~/.local/share/cv-infra-state-backups/$(date +%F)/terraform.tfstate
chmod 0600 ~/.local/share/cv-infra-state-backups/$(date +%F)/terraform.tfstate

# 2. Apply -- creates aws_iam_access_key.drone_deploy and the two SSM
#    SecureStrings. The OLD out-of-band key on drone-deploy still exists
#    and still works; nothing about the deploy step changes yet.
terraform plan -out=t008.plan
terraform apply t008.plan

# 3. Open an SSM port-forwarding tunnel to Drone on the CI host (the CI
#    host must be running -- see ci-on-demand.tf / the doorbell if it's
#    stopped). Replace the instance id and remote port with the real ones.
aws ssm start-session \
  --target <drone-instance-id> \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["80"],"localPortNumber":["8080"]}'
# leave this running in its own terminal

# 4. Reseed cv-admin-react's Drone secrets from SSM, over that tunnel, with
#    your own operator credentials -- never the CI host's.
export DRONE_SERVER=http://127.0.0.1:8080
export DRONE_TOKEN=***              # your Drone personal token; never echo this
./scripts/drone-reseed-secrets.sh

# 5. VERIFY THE NEW KEY WORKS BEFORE TOUCHING THE OLD ONE (case 9 -- this
#    order is load-bearing, not a suggestion). Read the new key's own
#    values back out of SSM and prove they authenticate, entirely with
#    your own operator credentials -- this does not touch the CI host.
NEW_AKID=$(aws ssm get-parameter --with-decryption \
  --name /cv-project/dev/deploy/drone-deploy/access-key-id \
  --query Parameter.Value --output text)
NEW_SECRET=$(aws ssm get-parameter --with-decryption \
  --name /cv-project/dev/deploy/drone-deploy/secret-access-key \
  --query Parameter.Value --output text)
AWS_ACCESS_KEY_ID="$NEW_AKID" AWS_SECRET_ACCESS_KEY="$NEW_SECRET" \
  aws sts get-caller-identity
# must succeed and show the drone-deploy user's ARN before step 6.

# 6. Trigger a real deploy (push to cv-admin-react's master, or re-run the
#    last build in the Drone UI) and confirm the `deploy` step goes green
#    using the NEW key while the OLD one still exists.

# 7. Only now, delete the OLD out-of-band key -- list it first so you
#    delete the right one (there will be exactly two on the user right up
#    until this step).
aws iam list-access-keys --user-name cv-project-drone-deploy
aws iam delete-access-key --user-name cv-project-drone-deploy \
  --access-key-id <THE OLD ONE, NOT aws_iam_access_key.drone_deploy's id>

# 8. Confirm exactly one key remains.
aws iam list-access-keys --user-name cv-project-drone-deploy
```

## Part 2 -- SQLite rebuild rehearsal

Proves Drone's state is actually reconstructable, on the real
`cv-admin-react` repo, per H1 decision 2. Run over the same SSM tunnel /
Session Manager shell as above; no new IAM grant needed.

```bash
# On the CI host (via `aws ssm start-session --target <drone-instance-id>`):
sudo systemctl stop docker-drone-server 2>/dev/null || sudo docker stop drone-server
sudo mv /var/lib/drone/database.sqlite /var/lib/drone/database.sqlite.rehearsal-$(date +%F)
sudo docker start drone-server   # or the systemd unit, matching however it's run

# From a browser: hit the Drone server URL (terraform output drone_server_url),
# log in via GitHub OAuth (fresh install prompts this), activate
# cv-admin-react in the Drone UI.

# Off-host again: reseed the freshly-activated repo's secrets.
export DRONE_SERVER=http://127.0.0.1:8080   # same tunnel as Part 1
export DRONE_TOKEN=***
./scripts/drone-reseed-secrets.sh

# Push a trivial commit to cv-admin-react (or re-trigger the last one) and
# confirm a green build, deploy step included.
```

Record, in the task file (T-008) or its PR: the timestamps, the build URL,
and the **keep-or-restore decision** for `database.sqlite.rehearsal-<date>`
(build history is expendable per H1 -- the default is to leave the moved-aside
file in place briefly for a rollback window, then delete it; state the actual
choice made, not just the default).

## Part 3 -- one-off SQLite copy (pre-T-007, no new host grant)

A single backup of the pre-rehearsal `database.sqlite`, taken before Part 2,
kept locally at `~/.local/share/cv-infra-state-backups/<date>/` (`0700`/`0600`
per the existing convention). The CI host's instance role gets **no new IAM
grant** for this -- the upload is authorized entirely by a presigned URL the
operator generates with their own credentials.

```bash
# 1. Locally, with your own credentials: presign a short-lived PUT for a
#    throwaway key in the existing CI artifacts bucket (already private,
#    already has a public-access block -- see ci-on-demand.tf). 300s is
#    enough for a 1.35 MB file.
PRESIGNED_PUT=$(aws s3 presign \
  s3://cv-project-ci-artifacts-dev/tmp/drone-database-$(date +%F).sqlite \
  --expires-in 300 --http-method PUT)

# 2. On the CI host (SSM session, no new grant used -- the presigned URL
#    carries its own SigV4 auth in the query string):
sudo curl -sS -T /var/lib/drone/database.sqlite.rehearsal-<date> "$PRESIGNED_PUT"

# 3. Locally again, with your own credentials: download it to the
#    convention's path and lock down permissions.
mkdir -p -m 0700 ~/.local/share/cv-infra-state-backups/$(date +%F)
aws s3 cp s3://cv-project-ci-artifacts-dev/tmp/drone-database-$(date +%F).sqlite \
  ~/.local/share/cv-infra-state-backups/$(date +%F)/drone-database.sqlite
chmod 0600 ~/.local/share/cv-infra-state-backups/$(date +%F)/drone-database.sqlite

# 4. Clean up the transient S3 copy -- it was only ever a relay, not the
#    backup itself.
aws s3 rm s3://cv-project-ci-artifacts-dev/tmp/drone-database-$(date +%F).sqlite
```

This is a **one-off**, not a recurring job -- H1 decision 2 explicitly
rejects an ongoing backup for the SQLite (reconstructable + rehearsed is the
chosen answer). If that decision is ever revisited, do it as its own task
rather than quietly turning this into a cron job here.

## Part 4 -- cleanup (strictly after the rehearsal is proven)

```bash
# Only after Part 2's rehearsal has a recorded pass:
aws ec2 delete-snapshot --snapshot-id snap-0d7f5ae272ce0cef5

# The CI host should already be back to its normal on-demand lifecycle
# (T-019's reaper); this task does not change that. If it was started
# outside a reaper tick for this rehearsal, start it right after a reaper
# tick fires so the on-demand window stays bounded, and confirm the reaper
# stops it again afterward rather than leaving it running.
```

## Cost

No new recurring resource. The two SSM SecureStrings and the deleted
snapshot are both negligible against the run rate in `../CLAUDE.md`'s cost
model; the snapshot's ~$0.69/month (T-020 measurement) goes away entirely
once Part 4 runs.
