# cv-infra/bootstrap

Creates the S3 bucket and DynamoDB table the **main module** (`cv-infra/`,
one directory up) moves its state onto. T-004 part 2.

This module has **its own local state** (no `backend` block). It cannot
store its state in the bucket it creates -- that would be the bucket
managing its own existence, and a `terraform destroy` here would try to
delete a bucket while depending on that same bucket to record the delete.
Bootstrap state stays local, gitignored, exactly like any other
`*.tfstate` in this repo before T-004.

## What it creates

- `aws_s3_bucket.tfstate` -- `cv-project-tfstate-760904708057`. The
  account id is folded into the name because S3 bucket names are unique
  *globally*, across every AWS account, not just this one -- `decide and
  justify` from the task file. `cv-project-tfstate` alone is a plausible
  name for someone else to already hold, this module and its tests run
  fully offline, and there is no way to probe global availability from a
  red-first test. The account-id suffix makes uniqueness a certainty
  instead of a guess.
- Versioning: `Enabled`. SSE: `AES256` (SSE-S3, not SSE-KMS -- H1 judged a
  KMS key's per-request cost and key-policy surface unjustified for a
  demo-scale state file; revisit if this bucket ever holds more than
  Terraform state).
- A public-access block with all four flags explicitly `true`.
- A bucket policy denying any request where `aws:SecureTransport` is
  `false`.
- `lifecycle { prevent_destroy = true }` on the bucket -- this is the
  mapping between every resource in the repo and the live AWS objects it
  created; losing it is exactly what T-004 exists to prevent.
- `aws_s3_bucket_ownership_controls.tfstate` -- `BucketOwnerEnforced`
  (review round 1, finding 9): disables ACLs on this bucket entirely, so
  access is bucket-policy-only, matching what the deny-non-TLS policy
  already assumes.
- `aws_s3_bucket_lifecycle_configuration.tfstate` (review round 1,
  finding 9): expires noncurrent versions after 90 days (versioning
  without an expiration policy keeps every historical state revision,
  and its cost, forever) and aborts incomplete multipart uploads after 7
  days.
- `aws_dynamodb_table.tf_locks` -- `cv-project-tfstate-lock`,
  `PAY_PER_REQUEST`, hash key `LockID` (the S3 backend's locking protocol
  requires that exact attribute name).

## Static checks `terraform test` can't express

`prevent_destroy` is a lifecycle meta-argument, not a resource attribute
-- it never appears in plan output, so no `assert` block can see it.
Checked instead by `bootstrap/check-static.sh`, part of this module's gate
(run it alongside fmt/validate/test -- the meta repo's `lint-all.sh` /
`test-all.sh` don't invoke it, since this is a demo-scale addition scoped
to this one module rather than a cross-repo convention; wiring it in there
is a separate, deliberate change if it's ever wanted):

```bash
bash bootstrap/check-static.sh
```

Anchored (`^\s*prevent_destroy\s*=\s*true`) and requires the assignment
uncommented, so it can't be fooled by a comment mentioning
`prevent_destroy` (this file has several) the way a bare
`grep -n prevent_destroy` would be. Verified red: removing the
`lifecycle { prevent_destroy = true }` block from a scratch copy of
`state-backend.tf` makes the script exit 1 with "no uncommented
'prevent_destroy = true' found"; restoring the block (or checking the
real file) exits 0.

## Bootstrap / apply / migrate order

Everything below except step 1 is **driver-run**, not part of this PR (see
the task's H1 test plan -- this PR is code + offline gates only).

1. `terraform fmt -check -recursive`, `terraform validate`, `terraform
   test`, and `bash bootstrap/check-static.sh`, here and in the main
   module. (This PR.)
2. Back up the main module's `terraform.tfstate` and `.backup`, **and**
   this module's own `bootstrap/terraform.tfstate` /
   `.tfstate.backup` once they exist, to
   `~/.local/share/cv-infra-state-backups/<date>/` (dir `0700`, files
   `0600`) -- **before** anything below touches the real backend. The
   bootstrap state is the only record of what the bucket/table actually
   are (their real ARNs, tags, applied config) until the next apply; losing
   that disk without a backup means falling back to the `terraform import`
   recovery below.
3. `cd bootstrap && terraform init && terraform apply` -- creates the
   bucket and table for real. Nothing about the main module's state
   changes yet. Immediately after, back up the now-populated
   `bootstrap/terraform.tfstate` per step 2 (it didn't exist before this
   step).
4. Note `terraform state list | wc -l` in the main module (pre-migration
   resource count, to diff against post-migration).
5. In the main module: `terraform init -migrate-state` against the new
   `backend "s3"` block (providers.tf). Terraform prompts to copy the
   existing local state into the bucket -- confirm.
6. `terraform plan` **immediately** afterward. It must say exactly `No
   changes.` -- anything showing a resource "to be created" means the
   migration lost track of it; stop and restore from the step-2 backup
   rather than applying. Compare `terraform state list | wc -l` against
   step 4.
7. Only after step 6 confirms a clean migration: remove the local
   `terraform.tfstate` / `.tfstate.backup` from the main module's working
   tree. Re-check they're `0600` (or gone) after every step above that
   touches them, not just at the end.
8. Delete the two stale saved plans this task also found,
   `cv-infra/tfplan` and `cv-infra/t001.tfplan` (`0664` -- saved plans
   embed the same plaintext secrets as state).

## Rollback

Bootstrap and main-module migration are **separate applies against
separate state**, so rollback is per-stage. In every case, back up
whatever local state file is about to be touched, per the step-2 backup
convention, *before* running anything below.

- **Before step 5 (migration not yet run):** nothing to roll back. The
  main module is still on local state; `terraform destroy` here removes
  the (still-empty, unused) bucket and table. `prevent_destroy` on the
  bucket will refuse this -- remove that block first if the bootstrap
  itself needs undoing, which is the point: it forces that removal to be
  a deliberate, separate action, not a side effect.
- **After step 5, before step 6 confirms clean** -- order matters here,
  reversed from what's intuitive:
  1. Revert the `backend "s3"` block in the main module's `providers.tf`
     to local (comment it out, matching what it looked like before this
     task).
  2. `terraform init -reconfigure` in the main module. This is the step
     that actually matters and is easy to skip: the working directory's
     own backend pointer (`.terraform/terraform.tfstate`, not the state
     file itself) still says "S3" until `-reconfigure` runs, so without
     it Terraform keeps reading/writing the bucket regardless of what
     `providers.tf` now says, and the restored file in step 3 is never
     looked at.
  3. Restore the main module's `terraform.tfstate` from the step-2
     backup.
  4. `terraform plan` -- confirms no drift happened between the backup
     and now (it should already match; this is a check, not a fix).

  The remote copy in the bucket is now stale, not authoritative. Leave it
  (harmless, and versioning bills for it either way at this scale) or see
  "Deleting a stale remote object" below.
- **After step 6 confirms clean:** the bucket is now authoritative.
  Rolling back -- **`init -migrate-state` needs something to migrate
  FROM, which means the block edit has to come first here, the opposite
  order from the mid-migration case above** (there, the block was still
  pointed at S3 and the goal was to abandon that; here the goal is to
  tell Terraform "go get it from S3 one more time, then stop"):
  1. Revert the `backend "s3"` block in `providers.tf` to local. With the
     block still saying `s3`, `init -migrate-state` has no backend change
     to detect and nothing to migrate; reverting first is what gives it
     something to do.
  2. `terraform init -migrate-state` -- Terraform detects the backend
     config changed (s3 → none/local) and prompts to copy the current
     remote state down to a local file. Answer yes.
  3. `terraform plan` -- must show `No changes.`
  4. Re-check `terraform.tfstate`'s permissions -- `init -migrate-state`
     writes the file with the umask in effect at the time, which is not
     guaranteed to be `0600`. `ls -l terraform.tfstate`, and
     `chmod 600 terraform.tfstate` if it isn't already.

  Manual alternative, if the file is wanted under your own control rather
  than trusting `-migrate-state`'s prompt -- **order matters here, and
  it's the reverse of the primary procedure above:**
  1. `umask 077 && mkdir -p ~/.local/share/cv-infra-state-backups/<date>`
     -- `0700`, matching the backup convention this reuses rather than a
     scratch location like `/tmp`, which is world-traversable by default
     and would land the state (secrets included) somewhere with a laxer
     default mode than the file deserves.
  2. `umask 077 && terraform state pull > ~/.local/share/cv-infra-state-backups/<date>/rollback-state.json`
     -- **while the `backend "s3"` block is still in `providers.tf` and
     still what `.terraform/` is configured for.** `state pull` reads
     whatever backend the working directory is currently pointed at; if
     the block has already been reverted (or `init -reconfigure` already
     run), it errors, and by then the `>` redirect has already truncated
     the target file on its way to failing -- pulling to this separate
     file first is what avoids that. The `umask 077` on this line, not
     just the `mkdir` above, is what actually protects the file's own
     mode: a redirect creates the file with the umask in effect for the
     shell running the command, not the directory's mode.
  3. Revert the `backend "s3"` block in `providers.tf` to local.
  4. `terraform init -reconfigure`.
  5. `install -m 600 ~/.local/share/cv-infra-state-backups/<date>/rollback-state.json terraform.tfstate`
     (copies and sets the mode in one step; `mv` instead is fine too, but
     then follow with step 6 explicitly rather than assuming `mv`
     preserved `0600`).
  6. `chmod 600 terraform.tfstate` -- belt-and-suspenders after either
     `install` or `mv`: re-check rather than assume, same as the primary
     procedure's step 4.
  7. `terraform plan` to confirm no changes.
- Versioning on the bucket means an in-place corruption (not a backend
  swap, but a bad state write) is a version rollback
  (`aws s3api list-object-versions` /
  `aws s3api get-object --version-id`), not a restore-from-elsewhere.

### Deleting a stale remote object

Versioning means a plain `aws s3api delete-object` only writes a delete
marker -- every prior version (and the secrets in it) is still stored
and billed, just hidden from a normal `get-object`. To actually remove a
stale state object, delete every version and every delete marker for
that key explicitly:

```bash
aws s3api list-object-versions --bucket cv-project-tfstate-760904708057 \
  --prefix cv-infra/terraform.tfstate \
  --query '{Versions: Versions[].[Key,VersionId], Markers: DeleteMarkers[].[Key,VersionId]}'
# For every [Key, VersionId] pair in BOTH lists returned above:
aws s3api delete-object --bucket cv-project-tfstate-760904708057 \
  --key cv-infra/terraform.tfstate --version-id <VersionId>
```

The S3 backend (DynamoDB-locking mode, which is what this task uses --
see the `use_lockfile` note above) also writes a digest item to the lock
table alongside every state write, keyed as `<bucket>/<key>-md5`, to
detect a state object that's out of sync with what Terraform last wrote.
Deleting the S3 object without also deleting this item leaves a stale
digest behind: the next `init`/`plan` against that key compares the
(now-missing or different) object against the old digest and fails on a
checksum mismatch instead of just seeing a clean, empty key.

```bash
aws dynamodb delete-item --table-name cv-project-tfstate-lock \
  --key '{"LockID":{"S":"cv-project-tfstate-760904708057/cv-infra/terraform.tfstate-md5"}}'
```

### Recovering from a lost bootstrap state

Bootstrap's own state is local (see above); losing that disk loses the
mapping to the real bucket/table even though the bucket/table themselves
are untouched. Recover with an empty bootstrap state and import the
eight resources back into it (the step-2 backup is the alternative to
all of this -- restore it instead if one exists):

```bash
cd bootstrap
terraform init
terraform import aws_s3_bucket.tfstate                                   cv-project-tfstate-760904708057
terraform import aws_s3_bucket_versioning.tfstate                        cv-project-tfstate-760904708057
terraform import aws_s3_bucket_server_side_encryption_configuration.tfstate cv-project-tfstate-760904708057
terraform import aws_s3_bucket_public_access_block.tfstate               cv-project-tfstate-760904708057
terraform import aws_s3_bucket_ownership_controls.tfstate                 cv-project-tfstate-760904708057
terraform import aws_s3_bucket_lifecycle_configuration.tfstate           cv-project-tfstate-760904708057
terraform import aws_s3_bucket_policy.tfstate                            cv-project-tfstate-760904708057
terraform import aws_dynamodb_table.tf_locks                             cv-project-tfstate-lock
terraform plan   # must show no changes -- confirms every attribute the import
                 # brought in still matches this module's config
```

## Rotation decision (T-004 part 3)

**Accept, no rotation.** `db_password`, `drone_rpc_secret`, and
`drone_github_client_secret` have been sitting in local state at `0664`
until 2026-08-24, then `0600` since. Single-user machine, gitignored
files, and the exposure window is closed -- H1 (2026-09-28) judged the
practical risk low enough not to rotate now. This keeps T-021
deferred with its existing trigger ("before anyone rotates `db_password`")
unchanged: `db_password` specifically cannot be rotated today without
landing T-021 first (task board, meta repo -- cv-infra has no `.claude/`
of its own), since the MySQL container on the persistent EBS
volume (T-018) keeps its original credentials on reattach while the
bootstrap script reads the new one from SSM, so a rotation applied today
would fail Flyway auth and come up with no domain-service container at
all.
