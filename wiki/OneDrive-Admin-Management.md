# OneDrive secondary admin management

> **`List` is read-only.** It requires no typed confirmation, makes no
> directory/Graph lookup, and does not write CSV evidence or change any
> permission.

> **Limited live validation.** `Add` and `Remove` were implemented and
> tested against mocked PnP/Graph calls; an operator has since reported a
> successful **Add** against a live tenant using app-only auth, after the CSOM
> `-Includes` fix in v1.9.0. **Remove**, owner-negative cases, bulk targets,
> and delegated auth remain unverified against a live tenant. Treat Add/Remove
> with care, review BEFORE/AFTER CSV evidence, and do not rely on them for
> production access changes until the remaining cases are validated.
> See `docs/superpowers/specs/2026-09-07-onedrive-admin-api-validation.md`
> in the repo for the full validation matrix.

## What it does

On the **OneDrives** tab only, press `M` to list, add, or remove the
tenant's *secondary site collection administrator* role on one or more
selected OneDrives:

```text
Select one or more OneDrives, press M, choose List, Add, or Remove.
List shows every current site collection admin per selected target and
requires nothing further. Add/Remove ask for one UPN, resolve it in the
tenant directory, and preview every selected target before requiring
ADDADMIN or REMOVEADMIN. Removal changes only the named
secondary administrator role; other access grants remain in place.
```

## List (read-only)

1. Select one or more rows on the OneDrives tab (`Space`), press `M`,
   choose **List**.
2. For each selected target, the tool connects to that site and reads its
   current site collection admin membership, then shows a report grouped
   by target: title, UPN, login, and Entra object ID for each admin found -
   whichever of those fields the site actually returns. A principal the
   tool cannot resolve any of those fields for is still shown, marked
   `(unresolved)`, rather than being hidden or guessed at.
3. A target with zero site collection admins is reported explicitly as
   "no administrators found" - never as a failure.
4. A read failure on one target (site connection or membership read) is
   logged and shown under that target; the rest of the selection is still
   listed.
5. Nothing is prompted, confirmed, or permission-changing: no UPN entry,
   no typed confirmation, no CSV/snapshot export of the membership shown,
   and no directory or Graph lookup beyond the site's own membership
   query - normal connection and error-path logging (`O` on the Log tab)
   still happens, same as any other read. `List` does not require the
   `User.Read.All` (or equivalent) consent described below - it is the
   same scope any other target action on this tool already needs.

## Add/Remove

1. Select one or more rows on the OneDrives tab (`Space`), press `M`,
   choose **Add** or **Remove**.
2. Enter one UPN. The tool resolves it against the tenant directory to its
   canonical `userPrincipalName` - an alias-only match is rejected, and
   mixed case/whitespace is normalized, not silently substituted for a
   different account.
3. A read-only preflight runs against every selected target (one connect
   and one admin read per OneDrive, so expect a few seconds each) and shows
   a preview: display name, resolved UPN, object ID, tenant, a full-access
   warning, every target URL, and a Selected/Eligible/No-op/Blocked count.
   A progress modal tracks the directory lookup and each target; **Esc**
   during preflight aborts before anything is written.
4. If at least one target is eligible, a typed confirmation
   (`ADDADMIN`/`REMOVEADMIN`) is required before anything is written.
5. Eligible targets are processed **one at a time**; the operation can be
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
  never defaults to "not protected." The owner is read from the personal
  library's drive (the one list with template 700 / MySiteDocumentLibrary),
  so extra document libraries in a OneDrive (Site Assets, migration
  leftovers) do not affect the check.
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

App-only Add has one operator-reported live success (see the validation
notice at the top of this page); Remove and delegated auth remain
unproven against a real tenant.

## Diagnostics and logging

Every failure path in this feature - tenant identity lookup, account
validation, per-target preflight read, evidence export (zero-eligible,
BEFORE, AFTER, and the trailing evidence flush after the batch completes),
and each internal re-check `M` performs immediately before a write - writes
the original error to the app log (`O` on the Log tab opens the log file),
not just a one-line summary in the on-screen modal. A `[Failed]`/`[Blocked]`
row in the preflight preview and the mixed-batch confirmation/report always
shows its reason directly under the target, instead of just the
classification word. The final report also logs one outcome line per
target (action, target, result) so a completed run's outcome is
recoverable from the log even after the on-screen report is dismissed - no
account UPNs, object IDs, or tokens are included in that summary line.
The directory-lookup and per-target state read also log the full
underlying API error (including any Graph error body) at the point it
occurs, even though the on-screen message stays a short summary.

Both the zero-eligible report and the batch-completion report show the
actual `SSM-Exports/SSM_ADMIN_<BEFORE|AFTER>_<operation-id>.csv` path once
that export call has actually returned it - never a path for an export
that failed. If the trailing evidence flush after a completed or stopped
batch fails, that is shown directly in the completion report (not only
logged), since it means the last AFTER evidence write may be stale.
