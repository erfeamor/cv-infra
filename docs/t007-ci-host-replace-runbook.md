# T-007 -- CI host replace runbook (plain AL2023, measured root, IMDSv2, DRONE_DATABASE_SECRET)

This is the runbook for the **driver-run, live** parts of
[T-007](../../.claude/tasks/T-007-ecs-agent-cleanup.md) (H1, 2026-09-29).
Everything here touches the real AWS account and the live CI host --
nothing in this file is executed by the code/offline gate that built the
Terraform (`terraform fmt`/`validate`/`test`, `scripts/check-t007-static.sh`;
see `../CLAUDE.md`).

## Background

`aws_instance.drone` (`../ci.tf`) carries `lifecycle { ignore_changes = [ami,
...] }`, so a plain `terraform apply` will **never** propose replacing the
host -- not even once this PR's `root_block_device` and `metadata_options`
land in config. The only way onto the new AMI/root/IMDS posture is an
explicit `terraform apply -replace=aws_instance.drone`. This is deliberate
(see the premise correction in the task file): `ignore_changes` is what has
kept the live host on the ECS-optimized AMI, and it must stay in the
resource so unrelated applies can never replace this box by accident.

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
2. **Pause the reaper** (T-034's finding, ratified in H1 point 6): the
   replace/restore window needs the host to stay up through Drone rebuild,
   `DRONE_DATABASE_SECRET` verification, and Jenkins job seeding, all of
   which take far longer than the reaper's 20-minute idle window.
   ```bash
   aws events disable-rule --name cv-project-ci-reaper
   ```
   Re-enable at the end of this runbook, and confirm the next `terraform
   plan` after re-enabling shows no drift (the rule's `enabled` state is not
   managed by this module, so toggling it out-of-band is exactly the
   intended operational lever -- same pattern as the `CIKeepAlive` tag).
3. Confirm the CI host is currently **running** (`aws ec2 describe-instances
   --instance-ids <drone-instance-id> --query 'Reservations[0].Instances[0].State.Name'`)
   -- if it is stopped, the doorbell/on-demand automation would otherwise
   race the replace. Start it via the doorbell or the console first if
   needed, and let it settle before continuing.
4. Confirm `terraform plan` is clean (no unrelated drift) before adding
   `-replace` -- a `-replace` run on top of an already-dirty plan makes the
   post-replace diff (case below) harder to read.

## The replace

```bash
terraform plan -replace=aws_instance.drone -out=t007.tfplan
```

Expected plan shape (per the QA plan, driver-run reference): **one instance
replacement** (`aws_instance.drone`, forced by `-replace`) **plus** the
doorbell/reaper Lambda `INSTANCE_ID` environment variable updates and the
`aws_eip_association.drone` update -- both downstream of the new instance
id, both already wired (`../ci-on-demand.tf`, pinned by
`scripts/check-t007-static.sh`'s case 8). Nothing else should move. If the
plan shows more than these three resources changing, stop and investigate
before applying -- that is drift this task did not intend to carry.

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
   change** (H1 point 3):
   - From a container on the host's `drone` bridge network (e.g.
     `docker run --rm --network drone curlimages/curl -s -o /dev/null -w '%{http_code}\n' http://169.254.169.254/latest/api/token -X PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 21600'`),
     confirm the request is denied (connection refused/timeout, not a
     token).
   - Repeat with `--network host` (the PO's settlement: post-replace IMDS
     checks include a host-network container, not just the bridge network)
     -- this must be denied too, or the hop limit isn't doing its job.
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
6. **Disk**: record `df -h` and `docker system df` on the fresh host after
   at least one real build of each repo, and compare against the ~17 GiB
   measured on the old host (T-007's disk-measurement section) -- this is
   the actual proof the 20 GB root (not the AMI's 8 GB default) was the
   right call, not a guess re-asserted from the old box's number.
7. **Prune timer enabled**:
   ```bash
   systemctl is-enabled docker-prune.timer && systemctl list-timers docker-prune.timer
   ```
8. **Re-enable the reaper** and confirm no drift:
   ```bash
   aws events enable-rule --name cv-project-ci-reaper
   terraform plan   # should be clean
   ```
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
