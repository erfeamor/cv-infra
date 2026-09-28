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
- `aws_dynamodb_table.tf_locks` -- `cv-project-tfstate-lock`,
  `PAY_PER_REQUEST`, hash key `LockID` (the S3 backend's locking protocol
  requires that exact attribute name).

## Static checks `terraform test` can't express

`prevent_destroy` is a lifecycle meta-argument, not a resource attribute
-- it never appears in plan output, so no `assert` block can see it.
Checked instead by a static grep as part of this module's gate:

```bash
grep -n "prevent_destroy" bootstrap/state-backend.tf
```

## Bootstrap / apply / migrate order

Everything below except step 1 is **driver-run**, not part of this PR (see
the task's H1 test plan -- this PR is code + offline gates only).

1. `terraform fmt -check -recursive`, `terraform validate`, `terraform
   test` here and in the main module. (This PR.)
2. Back up the main module's `terraform.tfstate` and `.backup` to
   `~/.local/share/cv-infra-state-backups/<date>/` (dir `0700`, files
   `0600`) -- **before** anything below touches the real backend.
3. `cd bootstrap && terraform init && terraform apply` -- creates the
   bucket and table for real. Nothing about the main module's state
   changes yet.
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
separate state**, so rollback is per-stage:

- **Before step 5 (migration not yet run):** nothing to roll back. The
  main module is still on local state; `terraform destroy` here removes
  the (still-empty, unused) bucket and table. `prevent_destroy` on the
  bucket will refuse this -- remove that block first if the bootstrap
  itself needs undoing, which is the point: it forces that removal to be
  a deliberate, separate action, not a side effect.
- **After step 5, before step 6 confirms clean:** do not apply anything.
  Restore the main module's `terraform.tfstate` from the step-2 backup,
  then re-run `terraform init` there (without `-migrate-state`) to drop
  back to local state. The bucket now holds a copy of state that no
  longer matches the working config's backend block; it can be emptied
  and left in place, or the object deleted, once local state is confirmed
  working again.
- **After step 6 confirms clean:** the bucket is now authoritative.
  Rolling back means reversing the `backend "s3"` block in the main
  module's `providers.tf` back to local, `terraform init` (Terraform
  copies remote state back to a local file on the next init without
  `-migrate-state` if prompted, or use `terraform state pull >
  terraform.tfstate` to recover it manually), and treating the bucket
  copy as the backup going forward.
- Versioning on the bucket means an in-place corruption (not a backend
  swap, but a bad state write) is a version rollback
  (`aws s3api list-object-versions` /
  `aws s3api get-object --version-id`), not a restore-from-elsewhere.

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
