# T-008 -- drone-deploy credential cutover and SQLite rebuild rehearsal

This is the runbook for the parts of [T-008](../../.claude/tasks/T-008-drone-host-backup-and-snapshot.md)
that touch the live CI host. Everything here is **driver-run**, against the
real AWS account -- nothing in this file is executed by the code/offline
gate that built the Terraform and the reseed script it references
(`../scripts/drone-reseed-secrets.sh`).

## Background (H1, 2026-09-28; cutover order and the SQLite-copy decision revised in review round 1; deploy/ isolation extended in review round 2)

- The credential moves out of Drone's SQLite: Terraform now creates
  `aws_iam_access_key.drone_deploy` (`../iam.tf`) and writes it to two SSM
  SecureStrings under `deploy/drone-deploy/*` (`../ssm.tf`) -- deliberately
  **not** under `ci/*`, so the Drone host's own instance role (which build
  containers can reach until T-007/T-005) can never read it. That scope
  isolation only protects against the CI host's role, though: the app
  host's role (`aws_iam_role_policy.read_parameters`, `../iam.tf`) grants
  `ssm:GetParameter*` on the whole parameter tree and has no
  `metadata_options` (IMDSv1 on), so an SSRF/RCE in the domain service
  could otherwise read this credential too. Security review round 2
  (Medium, accepted) added an explicit **Deny** on that role for the
  `deploy/*` prefix, so this path is now protected two different ways:
  scope keeps it from the CI host's role, an explicit Deny keeps it from
  the app host's role.
- Drone's SQLite (`/var/lib/drone/database.sqlite` on the CI host) is
  **reconstructable, not backed up**. No new IAM grant on the CI role. A
  live rehearsal proves the rebuild. Build history is expendable.
- Encryption of the CI host's root volume happens at T-007's replacement
  (encrypted root, AWS-managed EBS key). `snap-0d7f5ae272ce0cef5`
  (unencrypted) is deleted only after the rehearsal below is proven.
- **No one-off off-host copy of the SQLite either (human decision, review
  round 1).** An earlier draft of this runbook had a "Part 3" that shipped
  `database.sqlite` off the host via a presigned S3 URL before the
  rehearsal. Dropped entirely: that file holds the GitHub OAuth token and
  every activated repo's secrets **unencrypted at the time this decision was
  made** -- Drone had no `DRONE_DATABASE_SECRET` configured back then, so
  there was no at-rest encryption to rely on, and copying it off-host would
  have created a second, less-controlled home for exactly the credentials
  this task exists to stop scattering. The fallback until T-007 replaces
  this host with an encrypted root is the moved-aside
  `database.sqlite.rehearsal-<date>` file Part 2 already leaves on the host
  itself -- not a separate off-host copy.
  **Update (T-007): `DRONE_DATABASE_SECRET` is now set.** T-007 adds
  `random_password.drone_database_secret` and an SSM SecureString at
  `ci/drone/database-secret` (`../ssm.tf`), and
  `../templates/drone-user-data.sh` reads it via `param()` and passes it to
  `drone-server` as `DRONE_DATABASE_SECRET`. This is set on the *replacement*
  host built by T-007's own runbook
  (`docs/t007-ci-host-replace-runbook.md`) -- the rebuild that runbook
  documents already includes it, so no separate cutover step is needed here.
  The background above is left as-is because it correctly describes why the
  gap existed and why it wasn't papered over with an off-host copy; it is
  not a live gap after T-007 lands.

## Part 1 -- apply and cutover

Run from `cv-infra/` with real credentials and `terraform.tfvars` present.

Cutover order (review round 1): **authenticate the new key, reseed, deactivate
the old key (reversible), prove a real deploy, THEN delete the old key.**
Deactivating before deleting means the old key can be reactivated as a rollback
right up until the last step -- deleting it is the one action in this
procedure that cannot be undone.

```bash
# 0. Pre-apply sanity check: the user must carry exactly ONE access key
#    before this apply. IAM allows at most 2 keys per user -- if a prior,
#    incomplete cutover already left 2, this apply's key creation hits
#    LimitExceeded, so catch that here with a clear message instead of a
#    confusing apply-time API error.
existing_key_count=$(aws iam list-access-keys --user-name cv-project-drone-deploy \
  --query 'length(AccessKeyMetadata)' --output text)
if [ "$existing_key_count" != "1" ]; then
  echo "expected exactly 1 existing access key on cv-project-drone-deploy, found $existing_key_count -- resolve before applying" >&2
  exit 1
fi

# 1. Back up state first -- this is a state-affecting apply (CLAUDE.md's
#    local-state backup convention). State itself lives in S3; this backs
#    up the last-known-good copy pulled locally, not the source of truth.
mkdir -p -m 0700 ~/.local/share/cv-infra-state-backups/$(date +%F)
terraform state pull > ~/.local/share/cv-infra-state-backups/$(date +%F)/terraform.tfstate
chmod 0600 ~/.local/share/cv-infra-state-backups/$(date +%F)/terraform.tfstate

# 2. Apply -- creates aws_iam_access_key.drone_deploy and the two SSM
#    SecureStrings. The OLD out-of-band key on drone-deploy still exists
#    and still works; nothing about the deploy step changes yet. `.tfplan`
#    matches the repo's own .gitignore (`*.tfplan`/`tfplan*`) -- delete it
#    anyway once applied, since a plan file embeds variable values.
terraform plan -out=t008.tfplan
terraform apply t008.tfplan
rm -f t008.tfplan

# 3. Open an SSM port-forwarding tunnel to Drone on the CI host (the CI
#    host must be running -- see ci-on-demand.tf / the doorbell if it's
#    stopped). Replace the instance id and remote port with the real ones.
aws ssm start-session \
  --target <drone-instance-id> \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["80"],"localPortNumber":["8080"]}'
# leave this running in its own terminal -- if it idles out before you
# reach step 8, reopen it before continuing (Part 2 hits the same thing).

# 4. Get the NEW key's id and secret from the source of truth (Terraform
#    state / SSM), never by eye off a list-access-keys table -- that's what
#    step 6 below needs to reliably name the OLD key by elimination.
NEW_AKID=$(terraform state show aws_iam_access_key.drone_deploy \
  | awk -F'"' '/^ *id *=/{print $2}')
NEW_SECRET=$(aws ssm get-parameter --with-decryption \
  --name /cv-project/dev/deploy/drone-deploy/secret-access-key \
  --query Parameter.Value --output text)

# 5. VERIFY THE NEW KEY AUTHENTICATES BEFORE TOUCHING DRONE AT ALL (case 9,
#    and this step is what makes the rollback note below meaningful -- see
#    it before relying on it). Entirely with your own operator credentials;
#    does not touch the CI host or Drone.
AWS_ACCESS_KEY_ID="$NEW_AKID" AWS_SECRET_ACCESS_KEY="$NEW_SECRET" \
  aws sts get-caller-identity
# must succeed and show the drone-deploy user's ARN before step 6.

# 6. Reseed cv-admin-react's Drone secrets from SSM, over the tunnel, with
#    your own operator credentials -- never the CI host's.
export DRONE_SERVER=http://127.0.0.1:8080
export DRONE_TOKEN=***              # your Drone personal token; never echo this
./scripts/drone-reseed-secrets.sh

# 7. Deactivate (not delete) the OLD key -- reversible right up until step
#    9. Derive its id by elimination against NEW_AKID (from step 4), not by
#    reading the list and picking one "by eye".
OLD_AKID=$(aws iam list-access-keys --user-name cv-project-drone-deploy \
  --query "AccessKeyMetadata[?AccessKeyId!='${NEW_AKID}'].AccessKeyId" --output text)
if [ "$(echo "$OLD_AKID" | wc -w)" != "1" ]; then
  echo "expected exactly one non-matching access key, got: $OLD_AKID" >&2
  exit 1
fi
aws iam update-access-key --user-name cv-project-drone-deploy \
  --access-key-id "$OLD_AKID" --status Inactive

# 8. Trigger a real deploy (push to cv-admin-react's master, or re-run the
#    last build in the Drone UI). It can only go green on the NEW key now
#    (the old one is Inactive) -- confirm the `deploy` step is green, and
#    separately confirm the new key was actually the one used:
aws iam get-access-key-last-used --access-key-id "$NEW_AKID"
# ServiceName/Region/LastUsedDate should reflect this run.

# ROLLBACK if step 8 does not go green: reactivate the old key
#   aws iam update-access-key --user-name cv-project-drone-deploy \
#     --access-key-id "$OLD_AKID" --status Active
# Note this is NOT a full rollback to the pre-cutover state: step 6 already
# overwrote Drone's stored secret with the NEW key's values, and Drone never
# had the OLD key's secret to begin with (H1 decision 1 -- it was never put
# in SSM or state). So reactivating the old key restores nothing Drone-side
# by itself; the actual rollback is "reactivate the old key [so deploys keep
# working via whatever process used it out-of-band before this task] and
# fix whatever is wrong with the new key", not "revert to the old key in
# Drone". This is exactly why step 5's authentication check matters: it is
# the guard that should catch a bad new key BEFORE step 6 overwrites
# anything, so this rollback path is rarely needed at all.

# 9. Only once step 8 is confirmed green, delete the OLD key.
aws iam delete-access-key --user-name cv-project-drone-deploy \
  --access-key-id "$OLD_AKID"

# 10. Confirm exactly one key remains.
aws iam list-access-keys --user-name cv-project-drone-deploy
```

## Part 2 -- SQLite rebuild rehearsal

Proves Drone's state is actually reconstructable, on the real
`cv-admin-react` repo, per H1 decision 2. Run over the same SSM tunnel /
Session Manager shell as above; no new IAM grant needed.

```bash
# On the CI host (via `aws ssm start-session --target <drone-instance-id>` --
# reopen this tunnel first if the one from Part 1 idled out):
sudo systemctl stop docker-drone-server 2>/dev/null || sudo docker stop drone-server
sudo mv /var/lib/drone/database.sqlite /var/lib/drone/database.sqlite.rehearsal-$(date +%F)
sudo docker start drone-server   # or the systemd unit, matching however it's run

# From a browser: hit the Drone server URL (terraform output drone_server_url),
# log in via GitHub OAuth (fresh install prompts this), activate
# cv-admin-react in the Drone UI.

# The wipe above means Drone's admin user (and every existing personal
# token, including whatever DRONE_TOKEN you used in Part 1) no longer
# exists -- this is a brand new install as far as Drone's own database is
# concerned. Generate a FRESH token from the newly-logged-in user's
# settings page; do not reuse the value from Part 1, it is gone.

# Off-host again: reseed the freshly-activated repo's secrets. If the
# tunnel from Part 1 idled out during the OAuth login above, reopen it
# (same `aws ssm start-session ... AWS-StartPortForwardingSession` command)
# before running this.
export DRONE_SERVER=http://127.0.0.1:8080   # same tunnel as Part 1
export DRONE_TOKEN=***                       # the FRESH token from above
./scripts/drone-reseed-secrets.sh

# Push a trivial commit to cv-admin-react (or re-trigger the last one) and
# confirm a green build, deploy step included.
```

Record, in the task file (T-008) or its PR: the timestamps, the build URL,
and the **keep-or-restore decision** for `database.sqlite.rehearsal-<date>`
(build history is expendable per H1 -- the default is to leave the moved-aside
file in place briefly for a rollback window, then delete it; state the actual
choice made, not just the default). This file is now also the only backup of
this data that exists anywhere (see the Background section above on why
there is deliberately no separate off-host copy) -- until T-007 replaces
this host with an encrypted root, that is the accepted, recorded risk.

## Part 3 -- cleanup (strictly after the rehearsal is proven)

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
once Part 3 runs.
