# Design: scan cache, bulk revocation, and scan-all resume

## Problem

The SharePoint Sharing Manager TUI holds all target and finding state in
memory only. Three consequences make large-tenant OneDrive cleanup slow and
error-prone:

1. **No cached scan results.** Closing the tool discards every enumerated
   target and every finding. A long tenant-wide scan must be repeated from
   scratch on the next launch, and there is no way to run a scan once and then
   revoke against those results later.
2. **No bulk revocation.** Revoke only exists inside a single drive's
   drill-down view (`Invoke-FindingsRevoke`). There is no action to revoke
   across many OneDrives at once, nor to revoke every finding in the list.
3. **Interrupted scans lose progress.** A sequential scan of hundreds of
   drives that is interrupted (crash, terminal close, `Esc`) loses all
   in-progress results, and the operator loses track of which drives were
   already done.

All three trace to two missing capabilities: **persistence** and
**cross-target (bulk) operations**.

## Goals

- Persist scan results to disk so a session can be restored after the tool is
  closed and reopened.
- Revoke sharing in bulk: across all findings in an aggregate list, and across
  all findings on a set of selected drives.
- Run a full scan with one action, saving progress incrementally so an
  interrupted run resumes instead of restarting.

## Non-goals

- Parallel scanning. PnP.PowerShell holds a single connection at a time;
  incremental resume addresses the slow/interrupted-run pain without the
  complexity and safety risk of multiple runspaces each holding their own
  connection.
- Automatic cache load on startup. Restore is an explicit operator action, to
  avoid silently acting on stale findings.
- Cache encryption. The cache file carries the same directory data as the CSV
  exports and config file and is protected the same way (filesystem
  permissions plus an in-file warning), not encrypted.

## Existing architecture (reference)

- State lives in `$script:Tabs` (`src/00-globals.ps1`). The two Targets tabs
  (Sites, OneDrives) each hold `Items` (target objects), enabled `Categories`,
  and view state.
- A target object (`New-Target`, `src/45-targets.ps1`) holds
  `Url/Title/Template/Status/FindingCount/Findings/Selected`. A finding is a
  `pscustomobject` produced by the scan engine (`src/35-scan-engine.ps1`).
- Scan: `Invoke-TabScan` (`src/65-views.ps1`) loops the selected targets
  sequentially, connecting per-site, storing findings on each target.
- Revoke: `Invoke-FindingsRevoke` (`src/65-views.ps1`) acts on selected
  findings within one drilled target, using `Invoke-Revoke` (`src/40-revoke.ps1`),
  which orders removals and treats an already-removed principal as success.
- Evidence CSVs (BEFORE / REVOKED) are written per scan and revoke but never
  read back.

## Design

### 1. Persistence — new file `src/70-cache.ps1`

**Location.** `SSM-Cache/session.json` under the script root (`$script:Root`),
a new directory alongside `SSM-Exports/`. Kept out of the user profile root so
sensitive finding data does not accumulate in `$HOME`.

**Contents.** A single JSON object:

```
{
  "Version": "<tool version>",
  "SavedAt": "<ISO 8601 timestamp>",
  "Tabs": [
    {
      "Name": "Sites",
      "Categories": ["OrgLink"],
      "Items": [ { Url, Title, Template, Status, FindingCount, Findings: [...] } ]
    },
    { "Name": "OneDrives", "Categories": [...], "Items": [...] }
  ]
}
```

Findings are the plain `pscustomobject` records the scan engine already emits,
which serialize to JSON and back without custom converters.

**Functions.**

- `Save-SsmCache` — serialize the two Targets tabs to `session.json`. Called
  after each target completes in a scan run and after each bulk/single revoke.
  Writes atomically (temp file then move) so an interrupted write cannot
  corrupt the cache.
- `Test-SsmCacheAvailable` — true when `session.json` exists and parses; reads
  `SavedAt` and target count for the restore banner.
- `Restore-SsmCache` — load `session.json` into the two Targets tabs by name,
  rehydrating each finding with `Selected = $false` and each target with its
  saved `Status`/`FindingCount`. Marks tabs `Loaded`. Rebuilds views.

**Restore trigger.** On startup, `Test-SsmCacheAvailable` result is stored on
`$script:UI`. When true, the title bar / an empty-target-list hint shows a
restore prompt (target count and `SavedAt`). Pressing `L` on a Targets tab
calls `Restore-SsmCache`. Nothing loads automatically.

**Cache file warning.** The first run that creates `SSM-Cache/` also writes a
`README.txt` there stating the directory contains SharePoint/OneDrive
directory data (paths, principals, guest email addresses) and should be
treated as sensitive.

### 2. Aggregate findings view and bulk revoke

**Aggregate view.** No new tab is added, so the digit-key tab mapping (1-5)
is unchanged. From a Targets tab, a new key **`G`** ("all findings") enters an
aggregate findings mode. It reuses the existing findings sub-state (`FTab`)
but populates `Items` with every finding from every scanned target in that
tab, and renders an added **Site** column so each row shows which drive it
came from. Existing findings-mode keys apply unchanged: `Space`/`A`/`N`
select, `/` search, `F` category filter, `Esc` back to the target list.

**Bulk revoke in the aggregate view.** `R` on the aggregate view:

1. Collect selected findings and group them by site URL.
2. Show one typed `REVOKE` confirmation listing the per-site counts and total.
3. For each site in turn: connect (`Connect-SsmSite`), run `Invoke-Revoke` on
   that site's subset, write a REVOKED CSV for that site, and call
   `Save-SsmCache`.
4. Update each affected target's `FindingCount`/`Status` and show a summary
   report (per-site removed counts, any failures).

`Invoke-Revoke` is reused unchanged — it already orders removals correctly and
counts an already-removed principal as success.

**Target-list bulk revoke.** `R` on the target list (new binding) revokes
**all** findings on the currently selected targets. It reuses the same
group-by-site confirm-and-loop path as the aggregate view, seeded with every
finding on each selected target. This covers per-drive bulk cleanup without
drilling into each drive.

### 3. Scan-all with incremental save and resume

A new key **`X`** on a Targets tab runs scan-all:

1. If the target list is empty, enumerate from the tenant first (same path as
   `Enter` on an empty list).
2. Scan every target whose `Status` is `NotScanned`, sequentially, using the
   existing per-target scan and progress modal.
3. After each target completes, call `Save-SsmCache`.

`Esc` cancels mid-run as it does today; targets already scanned keep their
results and remain saved. Because status is persisted and restored, a restored
session followed by `X` naturally resumes: already-scanned drives (Clean /
Findings / Failed / Skipped) are passed over and only the `NotScanned`
remainder is scanned. Re-scanning a completed drive is still done by selecting
it and pressing `S`.

### Files changed

- **New:** `src/70-cache.ps1` — `Save-SsmCache`, `Test-SsmCacheAvailable`,
  `Restore-SsmCache`, cache-dir/README bootstrap.
- **Edit:** `src/00-globals.ps1` — cache path constant; `$script:UI` restore-
  available flag.
- **Edit:** `src/65-views.ps1` — aggregate findings render (Site column);
  `Invoke-TabScanAll`; group-by-site bulk revoke helper shared by the
  aggregate view and target-list revoke; restore banner in the title/empty
  hint.
- **Edit:** `src/75-key-dispatch.ps1` — `G` (aggregate view), `R` on the
  target list (bulk revoke), `X` (scan-all), `L` (restore).
- **Edit:** `README.md` — keys table, "Files the tool writes" (add
  `SSM-Cache/session.json`), feature list.

## Known issues and limitations

- **Stale cache.** Restored findings reflect the tenant at scan time; sharing
  may have changed since. The restore banner shows the cache timestamp, and
  revoke reconnects live and treats an already-removed grant as success, but a
  re-scan is the authoritative refresh before acting on old results.
- **Sensitive cache file.** `SSM-Cache/session.json` contains paths,
  principals, and guest email addresses. It is protected by filesystem
  permissions and an in-directory warning, not encryption.
- **Sequential scans.** A full tenant scan is bound by single-connection PnP
  throughput. Incremental save makes long scans resumable but not faster.
- **Single cache slot.** One `session.json` per script root; a new scan-all
  overwrites the prior cached session for that tab. Multiple retained sessions
  are out of scope.
