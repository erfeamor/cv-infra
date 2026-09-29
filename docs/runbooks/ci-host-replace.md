# Runbook: replacing the CI host

Use this for any change that replaces `aws_instance.drone` (`../../ci.tf`), which runs Drone and Jenkins behind the `ci-proxy` container. Examples: an AMI bump, an instance-type or root-volume change that forces replacement, or recovering a broken host.

A replacement **destroys the root disk**, and with it Drone's database and `JENKINS_HOME`. Both come back by rebuild: Drone by [drone.md](drone.md) Procedure A, and Jenkins by its provisioning code. The Elastic IP stays, so the GitHub webhooks and Drone's OAuth callback don't change.

## Things to know before you plan

- **`ignore_changes = [ami, tags["CIKeepAlive"], tags_all["CIKeepAlive"]]`** only stops *in-place updates* of those attributes. Any forced replacement, whether from `-replace` or from a ForceNew attribute such as `root_block_device.encrypted`, builds the new instance from the **current** configuration, including the latest AMI that `data.aws_ami.al2023` resolves to.
- **If your change itself forces replacement, apply it from its branch before merging.** Otherwise master carries a pending host replacement, and the next unrelated plan will propose it.
- **Pause the reaper with the `CIKeepAlive` tag**, never by disabling its EventBridge rule (that rule is Terraform-managed, so disabling it drifts). See [drone.md](drone.md). The tag is per-instance, so set it on the **new** instance right after the apply.

## Procedure

1. **Back up state** (`../../CLAUDE.md` convention: `~/.local/share/cv-infra-state-backups/<date>/`, directory 0700, files 0600):
   ```bash
   terraform state pull > ~/.local/share/cv-infra-state-backups/$(date +%F)/pre-ci-replace.tfstate
   ```
2. **Plan and read the whole shape** before applying:
   ```bash
   terraform plan -replace=aws_instance.drone -out=ci-replace.tfplan
   ```
   A replacement always moves these, all downstream of the new instance id:
   - `aws_instance.drone`: replaced
   - `aws_eip_association.drone`: replaced (re-points the same EIP)
   - `aws_iam_role_policy.ci_doorbell` and `aws_iam_role_policy.ci_reaper`: updated (they embed the instance ARN)
   - `aws_lambda_function.ci_doorbell` and `aws_lambda_function.ci_reaper`: updated (their `INSTANCE_ID` env)
   - `null_resource.jenkins_provision`: replaced (it re-provisions Jenkins onto the new host)

   If `templates/jenkins-provision.sh` changed, `local_file.jenkins_provision_script`, `aws_s3_object.jenkins_provision` and `aws_ssm_parameter.jenkins_provision_sha256` also move. **Anything else is drift your change didn't intend. Stop and investigate.**
3. **Apply**, then immediately tag the new host:
   ```bash
   terraform apply ci-replace.tfplan && rm -f ci-replace.tfplan
   I=$(terraform state show -no-color aws_instance.drone | awk -F'"' '/^ *id *=/{print $2; exit}')
   aws ec2 create-tags --resources "$I" --tags Key=CIKeepAlive,Value=true
   ```
   The apply waits for `null_resource.jenkins_provision`, which takes about 4–5 minutes on a fresh host. Its SSM command runs `cloud-init status --wait` first, so it doesn't race user_data's Docker install.

## Post-replace verification

Run these on the host with `aws ssm send-command` (AWS-RunShellScript) or an SSM session.

| Check | Command (on the host unless noted) | Expect |
|---|---|---|
| Instance shape | *(operator)* `aws ec2 describe-instances --instance-ids $I --query '…[ImageId,MetadataOptions.HttpTokens,MetadataOptions.HttpPutResponseHopLimit,PublicIpAddress]'` | the expected AMI, `required`, `1`, the same EIP |
| Root volume | *(operator)* `aws ec2 describe-volumes --volume-ids <root>` | the expected size, `gp3`, `Encrypted: true` |
| No ECS leftovers | `docker ps -a \| grep -c ecs-agent`; `systemctl list-unit-files \| grep -ci ecs` | 0, 0 |
| No host-network containers | `for c in $(docker ps -q); do docker inspect -f '{{.Name}} {{.HostConfig.NetworkMode}}' $c; done` | all on the `drone` network |
| IMDS denied to bridge containers | `docker run --rm curlimages/curl -s -o /dev/null -w '%{http_code}' --max-time 5 -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60'` | `000` (timeout) |
| IMDS from a host-network container | the same with `--network host` | **`200`: a known gap.** Hop limit 1 doesn't apply to host-networked containers, and builds can start them through `docker.sock` (owned by the CI-secrets hardening task) |
| IMDSv1 off | `curl -s -o /dev/null -w '%{http_code}' http://169.254.169.254/latest/meta-data/` | `401` |
| Host can read its parameters | `aws ssm get-parameter --name /cv-project/dev/ci/drone-rpc-secret --with-decryption --query Parameter.Name` | the name (never print the value) |
| Drone DB key set | `docker exec drone-server env \| grep -q '^DRONE_DATABASE_SECRET=.\{32\}$' && echo present` | `present` |
| Jenkins jobs seeded | `ls /var/lib/jenkins/jobs/` | `cv-database`, `cv-domain-service` |
| Prune timer | `systemctl is-enabled docker-prune.timer`; `systemctl cat docker-prune.service \| grep ExecStart` | `enabled`; `image prune` and `builder prune` only, never `system prune` |
| Disk | `df -h /`; `docker system df` | under **75%** after one build of each repo; above that, raise `root_block_device.volume_size` |

Then **rebuild Drone** ([drone.md](drone.md) Procedure A; the human logs in and supplies a fresh token) and **prove Jenkins** with a real build:

```bash
# on the host: Jenkins is behind ci-proxy on port 80 under /jenkins, and
# the user is var.jenkins_admin_username (terraform.tfvars), not "admin".
# Password auth needs a CSRF crumb.
P=$(aws ssm get-parameter --name /cv-project/dev/ci/jenkins-admin-password --with-decryption --query Parameter.Value --output text)
J=http://127.0.0.1/jenkins; C=$(mktemp); K=$(mktemp); chmod 600 "$C" "$K"
printf 'user = "%s:%s"\n' "<jenkins_admin_username>" "$P" > "$C"; unset P
curl -s -K "$C" -c "$K" "$J/crumbIssuer/api/json" \
  | python3 -c 'import json,sys;d=json.load(sys.stdin);print("header = \""+d["crumbRequestField"]+": "+d["crumb"]+"\"")' >> "$C"
curl -s -K "$C" -b "$K" -X POST "$J/job/cv-domain-service/build?delay=0"       # rescan
# then poll $J/job/cv-domain-service/job/master/lastBuild/api/json until "building": false, "result": "SUCCESS"
rm -f "$C" "$K"
```

## Finish

```bash
aws ec2 delete-tags --resources "$I" --tags Key=CIKeepAlive
aws ec2 stop-instances --instance-ids "$I"
terraform plan        # must show "No changes."
```

Then merge the change's PR, if it was applied from a branch.

## Rollback

The old instance is **gone** once the replacement is applied. There's no host to fall back to, and by design there's no snapshot: Drone and Jenkins are rebuilt from code and SSM, not restored. If the new host fails to provision (for example `null_resource.jenkins_provision` times out, or a template error aborts user_data):

1. Read the failure from `aws ssm list-command-invocations --details` or the host's `/var/log/cloud-init-output.log`.
2. Fix the template or config on the branch.
3. Re-apply. `terraform apply -replace=aws_instance.drone` builds another fresh host from the fixed config. State is in S3 with versioning, and the pre-replace backup from step 1 restores the old state only if the *state* itself is damaged. It can't bring back the destroyed instance.
