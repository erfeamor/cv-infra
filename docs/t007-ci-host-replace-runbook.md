# T-007 -- CI host replace runbook (plain AL2023, measured root, IMDSv2, DRONE_DATABASE_SECRET)

This is the runbook for the **driver-run, live** parts of
[T-007](../../.claude/tasks/T-007-ecs-agent-cleanup.md) (H1, 2026-09-29).
Everything here touches the real AWS account and the live CI host --
nothing in this file is executed by the code/offline gate that built the
Terraform (`terraform fmt`/`validate`/`test`, `scripts/check-t007-static.sh`;
see `../CLAUDE.md`).

## Background

**Corrected, review round 1, finding 1 -- this PR's own diff already forces
a replacement, independent of `-replace`.** `aws_instance.drone`
(`../ci.tf`) carries `lifecycle { ignore_changes = [ami, ...] }`, but that
list covers only `ami` and the two `CIKeepAlive` tag entries -- **not**
`root_block_device`. `encrypted` and a `volume_size` decrease are both
ForceNew on that block, and the live instance's actual root (30 GB,
unencrypted -- the ECS AMI's default) genuinely differs from this PR's
explicit `root_block_device { volume_size = 20, encrypted = true }`. That
means once this config exists anywhere `terraform plan` can see it, **a
plain `terraform plan` -- no `-replace` flag at all -- already proposes
replacing `aws_instance.drone`.** This is not a false alarm to dismiss; it
is this task's own change finally becoming visible to Terraform.

Consequence: **this must be applied from the branch and proven live BEFORE
merging to `master`**, the same convention T-004 and T-008 used for their
own state-affecting changes. `master` must never carry this diff unapplied
-- if it did, the next routine `plan` on `master` (by anyone, for any
unrelated change) would surface an unplanned, surprising instance
replacement. Once applied from this branch, state already reflects the new
instance, and merging the PR afterward is just catching the code up to
match what is already true in the account.

`terraform apply -replace=aws_instance.drone` (not a plain apply) is still
the right command, but for a narrower reason than "this is the only thing
that can trigger a replace": it is what's needed to make the **AMI**
attribute actually pick up `data.aws_ami.al2023.id`'s *current* value
despite `ignore_changes = [ami]`. A plain apply would still replace the
instance (forced by `root_block_device`) but, per `ignore_changes`
semantics, would carry the *old* (ECS-optimized) AMI id into the new
instance -- defeating the entire point of this task. `-replace` overrides
that hold for the resource instance being replaced, so it is what actually
gets the plain AL2023 AMI onto the new host.

Drone's own state (repo activations, OAuth token, secrets) is SQLite on the
instance's root volume, so `-replace` destroys it. [T-008](../../.claude/tasks/T-008-drone-host-backup-and-snapshot.md)
already proved that rebuild path live (human GitHub login, activate, reseed
via `scripts/drone-reseed-secrets.sh`) -- this runbook reuses it rather than
inventing a new one. `JENKINS_HOME` is re-seeded by `null_resource.jenkins_provision`
(`../ci.tf`), which reruns automatically against the new instance id on the
same `apply`.

## Pre-replace checklist

1. **State backup** (`../CLAUDE.md`'s local-state backup convention --
   this is a state-affecting apply):
   ```bash
   mkdir -p -m 0700 ~/.local/share/cv-infra-state-backups/$(date +%F)
   terraform state pull > ~/.local/share/cv-infra-state-backups/$(date +%F)/terraform.tfstate
   chmod 0600 ~/.local/share/cv-infra-state-backups/$(date +%F)/terraform.tfstate
   ```
2. **Pausing the reaper cannot be done by disabling
   `aws_cloudwatch_event_rule.ci_reaper` (review round 1, finding 7,
   correcting an earlier draft of this runbook).** That rule IS managed by
   this module (`../ci-on-demand.tf` creates it with no `state` argument,
   so its default is `ENABLED`); `aws events disable-rule` out-of-band would
   make the very next `terraform plan` show drift wanting to re-enable it,
   which is exactly the kind of surprise this runbook exists to avoid. The
   reaper Lambda (`../lambda/ci_reaper/index.py`) instead reads a
   `CIKeepAlive` tag directly off the instance via `ec2:DescribeInstances`
   and returns early if it is `"true"` -- **use that tag, not the rule**:
   ```bash
   # Tag the NEW instance as soon as it exists (immediately after the apply
   # below, before any other verification step) -- the tag lives on the
   # instance itself, not in Terraform config, so a replace never carries
   # it over automatically.
   aws ec2 create-tags --resources <new-drone-instance-id> \
     --tags Key=CIKeepAlive,Value=true
   ```
   Zero drift either way: `aws_instance.drone`'s `ignore_changes` already
   covers `tags["CIKeepAlive"]` and `tags_all["CIKeepAlive"]` (T-019), which
   is precisely what makes this the intended operational lever -- Terraform
   never plans against this tag regardless of its value. Remove the tag (or
   set it to `false`) once post-replace verification is complete (see the
   last step below) -- leaving it set permanently means the reaper never
   stops this host again, silently reintroducing the ~$17/month 24/7 cost
   T-019 exists to avoid.
3. Confirm the CI host is currently **running** (`aws ec2 describe-instances
   --instance-ids <drone-instance-id> --query 'Reservations[0].Instances[0].State.Name'`)
   -- if it is stopped, the doorbell/on-demand automation would otherwise
   race the replace. Start it via the doorbell or the console first if
   needed, and let it settle before continuing.
4. **Confirm `terraform plan` (no `-replace`) shows ONLY what this task's
   own diff forces** -- not "clean" (see the Background section above: this
   plan is expected to already propose replacing `aws_instance.drone`,
   forced by `root_block_device`, before `-replace` is even added). What
   must be clean is everything else: no unrelated resource should show a
   pending change. If anything besides `aws_instance.drone` and its direct
   dependents (see "Expected plan shape" below) shows a diff, stop and
   investigate before proceeding -- that is drift this task did not intend
   to carry.

## The replace

```bash
terraform plan -replace=aws_instance.drone -out=t007.tfplan
```

**Expected plan shape (review round 1, finding 6 -- the full list, not an
abbreviated one)**, all downstream of the one instance replacement:

- `aws_instance.drone` -- replaced (forced by `root_block_device` per the
  Background section above; `-replace` additionally forces the AMI swap).
- `aws_eip_association.drone` -- updated to point at the new instance id.
- `aws_iam_role_policy.ci_doorbell` and `aws_iam_role_policy.ci_reaper`
  (`../ci-on-demand.tf`) -- updated: both embed `local.ci_instance_arn`,
  which is built from `aws_instance.drone.id`, so the policy JSON itself
  changes, not just an env var.
- `aws_lambda_function.ci_doorbell` and `aws_lambda_function.ci_reaper` --
  updated: their `INSTANCE_ID` environment variable, wired from
  `aws_instance.drone.id` (pinned by `scripts/check-t007-static.sh`'s case
  8).
- `null_resource.jenkins_provision` -- replaced: its `triggers.instance_id`
  changes, which is what makes Jenkins re-provision onto the new host in
  this same apply.
- **First apply only** (not on a later `-replace`): `random_password.drone_database_secret`
  and `aws_ssm_parameter.drone_database_secret` are created here too, if
  this is the first time this branch's config has been applied.

Nothing else should move. If the plan shows more than the above, stop and
investigate before applying -- that is drift this task did not intend to
carry.

```bash
terraform apply t007.tfplan
rm -f t007.tfplan
```

The EIP stays attached throughout (H1 point 6): `aws_eip.drone` itself is
untouched, only its association re-points at the new instance id, so the
webhook URL and Drone's OAuth callback need no changes.

## Post-replace verification

Run in this order -- each step's success is what makes the next one
trustworthy, not just a box to tick:

1. **`docker ps -a` shows no `ecs-agent`.** This should now hold trivially:
   the plain AL2023 AMI never installs the `ecs` systemd service (see the
   task's own "widened scope" note), so there is nothing to mask. Confirm
   rather than assume, and confirm again after a reboot (`sudo reboot`, wait
   for SSM to re-register, `docker ps -a` again).
2. **IMDSv2 / hop-limit-1, the lock-yourself-out check, before trusting the
   change** (H1 point 3; scope corrected, review round 1 finding 2 -- the
   hop limit does **not** cover every container, and this step must not
   claim otherwise):
   - From a container on the host's `drone` BRIDGE network (e.g.
     `docker run --rm --max-time 5 --network drone curlimages/curl -s -o /dev/null -w '%{http_code}\n' http://169.254.169.254/latest/api/token -X PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 21600'`),
     confirm the request is denied (times out inside the 5s `--max-time`,
     or connection refused -- not a token). This is the case hop-limit-1
     actually protects: a bridge-network hop is one hop further from the
     host's own loopback route than the limit allows.
   - Repeat with `--network host`. **This is EXPECTED to succeed and return
     a real token -- record that as a known, accepted gap, not a failure.**
     `--network host` puts the container directly in the host's own network
     namespace; it is not "one hop away", it IS the host, so
     `http_put_response_hop_limit = 1` does not apply to it at all.
     `drone-runner` mounts `/var/run/docker.sock`
     (`../templates/drone-user-data.sh`) and Jenkins build steps run against
     that same socket (`../templates/jenkins-provision.sh`), so **any build
     step that runs `docker run --network host ...` can fetch the instance
     role's credentials, exactly as before this change.** Closing this is
     [T-005](../../.claude/tasks/T-005-ci-secret-blast-radius.md)'s work
     (docker-socket / build isolation), not T-007's -- note it there as a
     live follow-up rather than treating this task as having closed it.
   - From the host itself (outside any container), confirm `param()`
     (`../templates/drone-user-data.sh`) already worked at boot -- Drone and
     the Jenkins provisioning step both depend on it, so if either came up
     clean, this already passed implicitly. Confirm explicitly anyway:
     `curl -s -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 21600'`
     from the host must succeed (hop 0 from the host's own perspective).
   - Confirm SSM Session Manager still reaches the host (`aws ssm
     start-session --target <new-instance-id>`) -- IMDSv2 governs the
     *instance's own* credential fetch path, not the SSM agent's control
     channel, but this is the explicit "did we lock ourselves out" check
     H1 calls for, not an assumption.
3. **`DRONE_DATABASE_SECRET` present in the running container's env**, without
   printing the value itself:
   ```bash
   sudo docker exec drone-server env | grep -q '^DRONE_DATABASE_SECRET=' && echo present
   ```
4. **Drone rebuild** (T-008's proven path, run fresh against the new host):
   human GitHub OAuth login, activate `cv-admin-react`, generate a fresh
   personal token, `./scripts/drone-reseed-secrets.sh` over an SSM tunnel.
   Trigger a real deploy and confirm it goes green end-to-end.
5. **Jenkins jobs seeded**: `null_resource.jenkins_provision` reruns
   automatically as part of the same `apply` (its trigger is the instance
   id, which just changed) -- confirm the DSL-seeded multibranch jobs for
   `cv-domain-service` and `cv-database` are present in the Jenkins UI, and
   trigger the doorbell (a push, or the periodicFolderTrigger's own scan) to
   confirm a build goes green.
6. **Disk, with an explicit threshold (review round 1, finding 4)**: record
   `df -h /` and `docker system df` on the fresh host after at least one
   real build of every repo (Jenkins: `cv-domain-service`, `cv-database`;
   Drone: `cv-admin-react`). The old host's ~17 GiB figure was **whole-disk**
   usage, not just Docker's share, and it was measured on a host with no
   pruning at all -- this task's own `docker image prune -af`/`docker
   builder prune -af` timer (see `../templates/drone-user-data.sh`) is what
   is now expected to reclaim old tags going forward, so the fresh
   measurement is the real test of the 20 GB choice, not a re-assertion of
   the old number. **Threshold: if usage exceeds 75% of the 20 GB root
   (~15 GiB) after this one round of builds, file a follow-up task to
   resize** -- don't let it fill silently between now and the next
   replacement.
7. **Prune timer enabled, with the right commands**:
   ```bash
   systemctl is-enabled docker-prune.timer && systemctl list-timers docker-prune.timer
   systemctl cat docker-prune.service   # confirm image+builder prune, NOT `docker system prune`
   ```
8. **Remove the `CIKeepAlive` tag** set in the pre-replace checklist, and
   confirm no drift (the tag itself is in `ignore_changes`, so removing it
   is likewise invisible to `plan` -- what must be clean is everything
   else):
   ```bash
   aws ec2 delete-tags --resources <new-drone-instance-id> --tags Key=CIKeepAlive
   terraform plan   # should show no changes
   ```
   Confirm the reaper resumes normal operation (the host stops on its own
   once genuinely idle) rather than assuming removing the tag is enough --
   the Lambda re-reads the tag fresh on every 5-minute tick, so there is no
   separate "re-arm" step, but a live confirmation costs little.
9. **Webhooks unchanged**: since the EIP's public IP is stable across the
   replace, no GitHub webhook URL needs touching -- confirm by checking one
   recent delivery on each repo's webhook (Settings -> Webhooks -> Recent
   Deliveries) rather than assuming.

## Rollback

**Honest answer: there is no rollback to the old instance.** `-replace`
destroys `aws_instance.drone` as part of the same apply that creates its
replacement -- by the time `terraform apply` returns, the old box (and its
SQLite, its root volume, everything on it) no longer exists. This mirrors
T-008's own rollback note for the access-key cutover: "rollback" here does
not mean "revert to the prior state", it means "fix whatever is wrong on
the new instance and re-apply/re-run the affected step", the same as any
other stateless CI host rebuild:

- **If the replace apply itself fails partway** (e.g. the instance comes up
  but `null_resource.jenkins_provision` times out): the instance and its
  dependents already exist in state. Fix the underlying issue (see
  `../ci.tf`'s header comment on `null_resource.jenkins_provision`'s known
  SSM-agent-registration and poller-timeout gotchas) and re-run `terraform
  apply` -- both the user-data path and the out-of-band provisioner are
  idempotent by design (`../ci.tf`, `../templates/jenkins-provision.sh`).
- **If IMDSv2 verification fails** (a container unexpectedly gets
  credentials, or the host/SSM path is unexpectedly denied): this is a
  config bug in `metadata_options`, not a data-loss risk -- fix
  `aws_instance.drone`'s block and `apply` again; it updates in place
  without another replace (`metadata_options` is not in `ignore_changes`).
- **If Drone's rebuild fails** (OAuth, reseed, or a red deploy): retry
  T-008's rebuild steps against the same instance -- nothing about a failed
  attempt requires another `-replace`.
- **If the whole replace turns out to be wrong** (e.g. discovered mid-way
  that the new root size is still insufficient): fix the config
  (`root_block_device.volume_size`) and run **another** `-replace` -- there
  is no cheaper path once the old instance is gone. This is why the
  pre-replace checklist's disk measurement and the "clean plan first" step
  matter: minimizing the chance of needing a second replace is the only
  real mitigation available.

## Cost

No new recurring resource. The 20 GB gp3 encrypted root replaces the old 30
GB (unencrypted, ECS AMI default) root -- per T-012's measured $0.094/GB-month,
that is roughly **-$0.94/month** (30 -> 20 GB), re-derive against
`../CLAUDE.md`'s current measured rate rather than trusting this figure
going forward. The `random_password`/SSM SecureString pair added by this
task is negligible, same class as the other SSM parameters already in
`../ssm.tf`.
