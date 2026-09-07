# OneDrive secondary admin management

> **Prerelease (v1.9.0-rc.1), pending live-tenant validation.** This
> feature is implemented and tested entirely against mocked PnP/Graph
> calls, by explicit, deliberate deferral - not a failed live test. It
> ships as a prerelease so an authorized test tenant can run that
> deferred live validation; the stable release line (currently v1.8.0)
> does not include this feature and does not move until validation
> passes. Do not rely on it for production access changes until then.
> See `docs/superpowers/specs/2026-09-07-onedrive-admin-api-validation.md`
> in the repo for the full gate and what is still unproven.

## What it does

On the **OneDrives** tab only, press `M` to add or remove the tenant's
*secondary site collection administrator* role on one or more selected
OneDrives:

```text
Select one or more OneDrives, press M, choose Add or Remove, and enter one UPN.
The tool resolves the account in the tenant directory and previews every selected
target before requiring ADDADMIN or REMOVEADMIN. Removal changes only the named
secondary administrator role; other access grants remain in place.
```

1. Select one or more rows on the OneDrives tab (`Space`), then press `M`.
2. Choose **Add** or **Remove**.
3. Enter one UPN. The tool resolves it against the tenant directory to its
   canonical `userPrincipalName` - an alias-only match is rejected, and
   mixed case/whitespace is normalized, not silently substituted for a
   different account.
4. A read-only preflight runs against every selected target and shows a
   preview: display name, resolved UPN, object ID, tenant, a full-access
   warning, every target URL, and a Selected/Eligible/No-op/Blocked count.
5. If at least one target is eligible, a typed confirmation
   (`ADDADMIN`/`REMOVEADMIN`) is required before anything is written.
6. Eligible targets are processed **one at a time**; the operation can be
   cancelled mid-batch, and each target gets its own final result.

## What the role actually grants

The *secondary site collection administrator* role gives **full access**
to that OneDrive - the same level of access as the actual owner. It is not
a scoped, read-only, or helpdesk-tier role; there is no narrower built-in
role this tool can grant instead. Treat granting it with the same caution
as granting site-collection-admin anywhere else.

## Safety blocks

- **Owner protection**: blocked if the entered account is the OneDrive's
  actual owner.
- **Primary-admin protection**: blocked if the entered account is the
  tenant's primary site-collection administrator on that drive.
- **Unresolved/unknown owner or primary admin blocks the request**: if
  either identity cannot be determined (blank or group-valued owner field,
  or a read failure), the target is blocked, not treated as safe. Unknown
  never defaults to "not protected."
- **Identity drift stops the whole batch**: if the confirmed account is
  found to have changed (deleted, renamed away, or recreated under the same
  UPN) at write time, no further targets in that batch are touched.
- **A protected identity changing during/after a write** (the drive's owner
  or primary admin moved mid-operation) is reported `Failed` and also stops
  the rest of the batch, as a safety escalation.
- **Ordinary target-local failures do not stop the batch** - the next
  target still runs.

## Partial outcomes and no rollback

Every selected target gets its own result: `Blocked`, `NoOp` (already in
the requested state), `Success`, `Failed`, `Unverified` (the tool could not
confirm the outcome either way), `Cancelled`, or `NotAttempted` (batch
stopped before this target's turn). A batch of several OneDrives commonly
ends with a mix of these - one target failing does not undo or block the
others (except the drift/protected-identity cases above).

**There is no automatic rollback.** A partially-failed Remove, or an Add
later found to be unwanted, must be corrected manually with another
Add/Remove pass - the tool does not remember or restore a "before" state
for you beyond the evidence CSVs described below.

## Evidence and other scope notes

- Hidden-but-selected OneDrives (filtered or searched out of the current
  view) are still included; only actual selection state matters.
- No prior sharing scan is required - this feature works from the target
  list alone.
- This is not a scan for stale or already-deleted secondary admins already
  on a drive; it only adds/removes the one account you enter.
- Writes `SSM_ADMIN_BEFORE_<operation-id>.csv` and
  `SSM_ADMIN_AFTER_<operation-id>.csv` to `SSM-Exports/`, with the same
  directory-data sensitivity as every other export in this tool. The AFTER
  file is re-written after each target, so partial progress survives a
  cancelled or interrupted run.

## Auth mode and consent

Exact UPN-to-account resolution needs a directory-read permission beyond
what scan/revoke already use:

- **App-only**: new registrations now request Graph `User.Read.All`
  (application). Existing registrations are **not** automatically changed -
  add the permission manually in the Entra portal and grant consent; see
  [[Authentication]].
- **Delegated**: PnP.PowerShell 3.3.0's documented default delegated scope
  set already includes `User.ReadWrite.All`, which covers this - no change
  needed.

If the required scope was never consented, pressing `M` fails with a
specific permission error; it never falls back to a partial-match lookup,
and existing scans/revokes are unaffected. See
[[FAQ-and-Troubleshooting]] and [[Authentication]] for recovery steps.

Neither auth mode's directory-lookup or mutation behavior has been proven
against a real tenant - see the prerelease notice at the top of this
page.
