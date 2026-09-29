# Runbook: Drone on the CI host — rebuild, secrets, and deploy-key rotation

Drone runs on the CI host (`aws_instance.drone`, `../../ci.tf`) as `drone-server` + `drone-runner`. It serves `erfeamor/cv-admin-react`, whose `deploy` step reads two Drone repo secrets, `aws_access_key_id` and `aws_secret_access_key`.

## Where things live

| Thing | Source of truth | Notes |
|---|---|---|
| Deploy key for `cv-project-drone-deploy` | `aws_iam_access_key.drone_deploy` (`../../iam.tf`), mirrored to SSM `/cv-project/dev/deploy/drone-deploy/{access-key-id,secret-access-key}` (`../../ssm.tf`) | Deliberately **outside** `ci/*`: no instance role can read it. The CI host's role only reads `ci/*`, and the app host's role has an explicit Deny on `deploy/*`. Only an operator's own credentials read it. |
| Drone's copy of that key | Drone repo secrets on `cv-admin-react` | Set **only** by `../../scripts/drone-reseed-secrets.sh`, never by hand in the UI |
| Drone database encryption key | SSM `/cv-project/dev/ci/drone/database-secret` (`random_password`, 32 chars) | Passed to `drone-server` as `DRONE_DATABASE_SECRET`. Repo secrets are encrypted at rest. |
| Drone's own state (users, activations, build history) | `/var/lib/drone/database.sqlite` on the CI host root disk | **Reconstructable, not backed up.** Build history is expendable. |

## Before any host-up session: pause the reaper without drift

The reaper Lambda stops an idle CI host every 5 minutes, with no grace after a start, and it can't see Drone. Pause it with the instance's `CIKeepAlive` tag. That tag is in `aws_instance.drone`'s `ignore_changes`, so Terraform never plans against it. **Don't disable the EventBridge rule**: it's Terraform-managed, so that shows as drift.

```bash
I=$(terraform state show -no-color aws_instance.drone | awk -F'"' '/^ *id *=/{print $2; exit}')
aws ec2 create-tags --resources "$I" --tags Key=CIKeepAlive,Value=true
aws ec2 start-instances --instance-ids "$I"
# … work …
aws ec2 delete-tags --resources "$I" --tags Key=CIKeepAlive      # always, or the host never stops again (~$17/month)
aws ec2 stop-instances --instance-ids "$I"
```

## The SSM tunnel to Drone's API

Needs `session-manager-plugin` on PATH. It keeps API traffic off the plain-HTTP public address (no TLS on the CI host yet; see the TLS task).

```bash
aws ssm start-session --target "$I" --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["80"],"localPortNumber":["8080"]}'      # leave running; idles out after ~20 min
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080/healthz   # 200
```

Close it by PID afterwards. Don't use `pkill -f <pattern>` from a shell whose own command line contains that pattern, because it kills itself:

```bash
for p in $(ps -eo pid,args | grep '[s]ession-manager-plugin' | awk '{print $1}'); do kill "$p"; done
```

## Handling the Drone token

The Drone UI shows the token under **User settings** (avatar, top right). The login session is tied to the OAuth callback on the public address, so the token page is viewed there. Never paste the token into chat, a file in a repo, or a command line. Save it in your own terminal:

```bash
umask 077; mkdir -p ~/.config
read -rs -p "Drone token: " t && printf '%s' "$t" > ~/.config/cv-drone-token && unset t; echo
wc -c < ~/.config/cv-drone-token      # must print 32; anything else is not the bare token
```

Use it as `DRONE_TOKEN="$(cat ~/.config/cv-drone-token)"`, and `shred -u` the file when done. Wiping Drone's database (below) recreates the admin user, which **invalidates every previous token**.

## Procedure A: rebuild Drone from an empty database

Use this after a host replacement (the database goes with the root disk), or to recover a broken database.

1. The reaper is paused and the host is up (above). If the host was *replaced*, Drone is already empty; skip to step 3.
2. To reset a working host, move the database aside on the host. It stays there as the fallback:
   ```bash
   docker stop drone-server
   mv /var/lib/drone/database.sqlite /var/lib/drone/database.sqlite.bak-$(date +%F)
   docker start drone-server
   ```
3. The **human** opens `http://13.39.59.12`, logs in with GitHub, clicks **Sync**, opens `erfeamor/cv-admin-react` and clicks **Activate** (defaults). Then saves a **fresh** token as above.
4. Open the tunnel, then confirm the token and the activation. If the UI activation didn't stick, activate through the API, which re-registers the GitHub webhook:
   ```bash
   C=$(mktemp); { printf 'header = "Authorization: Bearer '; cat ~/.config/cv-drone-token; printf '"\n'; } > "$C"
   curl -s -K "$C" http://127.0.0.1:8080/api/user                              # login, admin: true
   curl -s -K "$C" http://127.0.0.1:8080/api/repos/erfeamor/cv-admin-react     # "active": true ?
   curl -s -K "$C" -X POST http://127.0.0.1:8080/api/repos/erfeamor/cv-admin-react   # activate if not
   rm -f "$C"
   ```
5. Reseed the secrets (idempotent):
   ```bash
   DRONE_SERVER=http://127.0.0.1:8080 DRONE_TOKEN="$(cat ~/.config/cv-drone-token)" \
     ./scripts/drone-reseed-secrets.sh
   ```
6. **Prove a deploy.** `deploy` runs only on a `push` to `master`, and a rebuilt database has no builds to restart. Merge a small PR to `cv-admin-react` and confirm its push build is green **including `deploy`**.
7. Clean up: close the tunnel, `shred -u ~/.config/cv-drone-token`, remove the tag and stop the host.

## Procedure B: rotate the deploy key

The order matters. **Authenticate the new key, reseed, set the old key Inactive, prove a deploy, and only then delete.** Deletion is the one irreversible step.

1. **Pre-check:** the user must have exactly one key. IAM allows two, so a leftover makes the apply fail with LimitExceeded:
   ```bash
   aws iam list-access-keys --user-name cv-project-drone-deploy --query 'length(AccessKeyMetadata)'
   ```
2. **Back up state** (`../../CLAUDE.md` convention), then create the new key by replacing the Terraform resource. Use a gitignored plan name, and delete it afterwards:
   ```bash
   terraform plan -replace=aws_iam_access_key.drone_deploy -out=rotate.tfplan && terraform apply rotate.tfplan && rm -f rotate.tfplan
   ```
   Note: `-replace` destroys the Terraform-managed key and creates a new one, so there's no overlap window. For zero-downtime rotation, instead add a second key resource temporarily, then run steps 3–6 and remove the old resource.
3. **Authenticate the new key** before touching Drone. Read the values into variables; never print them:
   ```bash
   K=$(aws ssm get-parameter --with-decryption --name /cv-project/dev/deploy/drone-deploy/access-key-id --query Parameter.Value --output text)
   S=$(aws ssm get-parameter --with-decryption --name /cv-project/dev/deploy/drone-deploy/secret-access-key --query Parameter.Value --output text)
   env -u AWS_PROFILE -u AWS_SESSION_TOKEN AWS_ACCESS_KEY_ID="$K" AWS_SECRET_ACCESS_KEY="$S" \
     AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null aws sts get-caller-identity --query Arn --output text
   unset K S     # must print …:user/cv-project-drone-deploy
   ```
4. **Reseed Drone** (Procedure A, step 5).
5. **Deactivate the old key** (reversible). Derive its id by elimination, never by eye:
   ```bash
   NEW=$(terraform state show -no-color aws_iam_access_key.drone_deploy | awk -F'"' '/^ *id *=/{print $2; exit}')
   OLD=$(aws iam list-access-keys --user-name cv-project-drone-deploy --query "AccessKeyMetadata[?AccessKeyId!='$NEW'].AccessKeyId" --output text)
   [ "$(echo $OLD | wc -w)" = 1 ] && aws iam update-access-key --user-name cv-project-drone-deploy --access-key-id "$OLD" --status Inactive
   ```
6. **Prove a real deploy** is green (Procedure A, step 6). It can only succeed on the new key now. `get-access-key-last-used` lags, so the green deploy with the old key Inactive is the proof.
7. Delete the old key, then confirm exactly one remains. Rollback before this step is reactivating the old key.

## Pitfalls seen in practice

- Drone's API omits `false` booleans, so the `pull_request` flags on secrets read back as unset. The reseed script sends them explicitly `false`.
- A token file that isn't exactly 32 bytes almost certainly holds page text. Check its length, never its contents.
- The SSM tunnel idles out after about 20 minutes. Reopen it if a step fails with connection refused on `127.0.0.1:8080`.
