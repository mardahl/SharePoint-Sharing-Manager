# Excel report export with Copilot exposure indicator

Date: 2026-09-21
Status: approved design, awaiting implementation plan

## Goal

Let an operator hand a reviewer a single `.xlsx` file that summarises the
sharing findings from a SharePoint or OneDrive scan and lists every finding
with full path detail. Includes a heuristic "Copilot exposure" indicator
that relates overshared items to the total number of items scanned.

CSV export stays exactly as today.

## Decisions

| Topic | Decision |
|---|---|
| xlsx library | `ImportExcel` module, installed on demand (`Install-Module ImportExcel -Scope CurrentUser`). First and only optional dependency beyond `PnP.PowerShell`. CONTRIBUTING updated accordingly. |
| Trigger | `E` (target list and findings view) opens a modal: `[C] CSV  [X] Excel  [Esc] cancel`. `C` runs existing `Export-ViewCsv` unchanged. |
| Scope | Follows the current view. Target list: all findings across scanned targets in the current tab. Findings view: `FTab.View` (respects filter and search). Zero findings: status message, no file. |
| Sheets | `Summary`, `Findings`, `Sites` (Sites only when exporting a whole tab). |
| Detail columns | Richer than CSV: includes site title, sharing type, full path, IDs. |
| Exposure indicator | Weighted heuristic, labelled as such. Denominator = items enumerated by the scan. |

## Architecture

New region file `src/52-xlsx.ps1` (loaded by the bootstrap glob like every
other `src/*.ps1`). Everything Excel-related lives there. Pure functions
(aggregation, scoring) are separated from the ImportExcel-bound writer so
tests need no module.

```
src/35-scan-engine.ps1   Invoke-SiteScan: record ItemsScanned on target, Reach on findings
src/52-xlsx.ps1          Ensure-ImportExcel, Get-FindingsSummary, Get-ExposureScore,
                         Export-FindingsXlsx
src/65-views.ps1         Export modal renderer
src/75-key-dispatch.ps1  E -> modal; modal keys C / X / Esc
tests/xlsx.tests.ps1     assert-based tests for the pure functions
```

### 1. Scan engine changes (`src/35-scan-engine.ps1`)

- `Invoke-SiteScan` sums `$scanned` across libraries and writes
  `$Target.ItemsScanned` (int) and `$Target.LibrariesScanned` (int) before
  returning. Targets are hashtables created in `src/45-targets.ps1`; both keys
  are added there with default `0` so StrictMode never trips. Cache
  (`src/70-cache.ps1`) persists and restores both keys.
- Every finding gets a new property `Reach` (int): number of items the grant
  or link exposes.
  - `Location = 'File'` or `'Folder'`: `1`. Folder children are not counted
    (`# ponytail: folder reach = 1; walk children if reviewers ask`).
  - `Location = 'Library'`: the library `ItemCount` (`$total`).
  - `Location = 'Web'`: sum of `ItemCount` over all scanned libraries. Because
    web-root grants are collected before libraries are enumerated, the
    web-level findings are patched at the end of `Invoke-SiteScan` with the
    final sum.
- CSV export is not changed; `Reach` is simply not selected there.

### 2. Pure helpers (`src/52-xlsx.ps1`)

`Get-FindingsSummary -Findings <object[]> -Targets <object[]>` returns a
hashtable:

```
Total, SitesAffected, Links, DirectGrants,
ByCategory  = ordered list of @{ Category; Count }
ByAccess    = ordered list of @{ Access; Count }
ByStatus    = ordered list of @{ Status; Count }
TopSites    = top 10 @{ Site; Title; Count } by finding count
ItemsScanned = sum of Target.ItemsScanned over supplied targets
```

`Get-ExposureScore -Findings <object[]> -ItemsScanned <int>` returns
`@{ Score; Band; WeightedReach; ExposedPercent }`.

Weights by `CategoryKey`:

| CategoryKey | Weight | Rationale |
|---|---|---|
| `AnonymousLink` | 5 | Anyone, including former staff |
| `EEEU`, `Everyone` | 5 | Every licensed user's Copilot can surface it |
| `OrgLink` | 3 | Every internal user |
| `GuestLink`, `GuestGrant` | 2 | External identities |
| anything else | 1 | Named internal principals |

```
WeightedReach  = sum(weight(f) * f.Reach)
ExposedPercent = 100 * sum(f.Reach) / ItemsScanned      (0 when ItemsScanned = 0)
Score          = min(100, round(WeightedReach / ItemsScanned * 1000))   (0 when ItemsScanned = 0)
Band           = 0-10 Low | 11-40 Medium | 41-70 High | 71-100 Critical
                 'n/a' when ItemsScanned = 0 (Score also 0)
```

The `*1000` scale means 1 % of items overshared at weight 1 scores 10 (Low);
2 % anonymous-shared scores 100 (Critical). Both raw percentage and score are
shown so the reviewer can see the method.

If `ItemsScanned` is 0 (cached results from a version without the counter, or
scan aborted) the Summary shows "n/a - rescan to compute".

### 3. Writer (`src/52-xlsx.ps1`)

`Ensure-ImportExcel` returns `$true` when the module is importable. If it is
not installed it shows a typed prompt (existing modal helpers):
"Excel export needs the ImportExcel module. Install for current user? Y/N".
`Y` runs `Install-Module ImportExcel -Scope CurrentUser -Force -ErrorAction Stop`
then `Import-Module`. `N` or failure: status line
"Excel export unavailable - use CSV", logged, no file.

`Export-FindingsXlsx -Findings -Targets -ScopeLabel -Tab` writes to a temp
file in `$script:ExportDir` and `Move-Item` to the final name on success
(same atomic pattern as `Export-AdminCsv`). Filename:

```
SSM_REPORT_<SharePoint|OneDrive>_<site-tag|ALL>_<yyyyMMdd-HHmmss>.xlsx
```

`Export-Excel` is called with `-PassThru`; the package is closed with
`Close-ExcelPackage`. Any exception: status line + `Write-SsmErrorLog`, temp
file removed.

#### Summary sheet

Plain cells, bold labels, autosized columns, no charts.

1. Title: `SharePoint Sharing Manager - Sharing Findings Report`
2. Meta block: tool version, tenant admin URL, scope label (tab + site or
   "All SharePoint sites" / "All OneDrives"), generated (UTC), operator
   account (`$script:Conn.Account`).
3. KPI block: Total findings, Sites/OneDrives affected, Items scanned,
   Sharing links, Direct grants, Anonymous links, Removed, Failed,
   Not attempted.
4. Exposure block: `Copilot Exposure Indicator (heuristic)`: Score (cell
   filled green/yellow/orange/red by band), Band, Items overshared %,
   followed by the weight table above and one-line method text.
5. Tables: By category, By access, By revoke status, Top 10 sites.

#### Findings sheet

Excel table (`-TableName Findings -TableStyle Medium2`), autofilter, frozen
header row, autosized columns. Columns in order:

```
Site Title | Site URL | Location | Category | Sharing Type | Item Name |
Full Path | Access | Shared With | Link Created | Reach (items) |
Revoke Status | Link Id | List Id | Item Id
```

`Sharing Type` = `Link` or `Direct grant` from `RemovalKind`. `Link Created`
rendered `yyyy-MM-dd` when parseable, otherwise blank. `Site Title` is looked
up from the target list by URL; falls back to URL last segment.

#### Sites sheet (whole-tab export only)

Excel table: `Title | URL | Status | Findings | Items Scanned | Exposure Score | Band`.
Per-site score uses that site's findings and `ItemsScanned`.

### 4. UI (`src/65-views.ps1`, `src/75-key-dispatch.ps1`)

- `E` in target list handler (`75-key-dispatch.ps1:121`) and findings view
  handler (`75-key-dispatch.ps1:228`) sets `$script:Modal = 'Export'`
  instead of exporting directly.
- Export modal renders three options; keys `C`, `X`, `Esc`. `C` calls the
  existing `Export-ViewCsv` path with the same arguments as today. `X` calls
  `Ensure-ImportExcel` then `Export-FindingsXlsx`. Status line shows the
  written path, same as CSV.
- Key hint footer for both views changes `E export` to `E export...`.

### 5. Tests (`tests/xlsx.tests.ps1`)

Assert-based, no ImportExcel required:

- `Get-ExposureScore`: fixture with 1000 items, 5 anonymous links (weight 5,
  reach 1) -> WeightedReach 25, Score 25, Band Medium, ExposedPercent 0.5.
- Library-level EEEU grant with Reach 1000 of 1000 items -> Score 100,
  Critical.
- `ItemsScanned = 0` -> Score 0, Band `n/a`.
- `Get-FindingsSummary`: counts by category/access/status, TopSites ordering,
  SitesAffected distinct count.
- Scan engine (existing `tests/scan-engine.tests.ps1`): `Reach` present on
  item findings and equals 1.

Export itself is verified manually via the tmux recipe in CONTRIBUTING.

### 6. Docs (same change)

- `CHANGELOG.md` Unreleased: Excel report export, exposure indicator, export
  modal, optional ImportExcel dependency.
- `README.md`: feature bullet; requirements note that ImportExcel is
  optional and installed on demand for Excel export.
- `CONTRIBUTING.md`: dependency rule amended to allow `ImportExcel` as an
  optional, on-demand module used only by `src/52-xlsx.ps1`.
- `wiki/Scanning-and-Revoking.md`: `E` key now opens export menu; new
  section "Excel report" describing sheets, filename, exposure indicator
  method and its limits.
- `wiki/FAQ-and-Troubleshooting.md`: ImportExcel install prompt, offline
  fallback to CSV.
- `wiki/Home.md`: no new page needed; existing page updated.

## Limits stated to the reviewer (printed on Summary sheet)

- Indicator is an SSM heuristic, not a Microsoft metric.
- Only libraries visible to the scan count; hidden/excluded libraries are not
  in the denominator.
- Folder-level sharing counts as one item.
- Items with inherited permissions from an overshared library or web are
  counted via `Reach`, not individually verified.

## Out of scope

- Charts, conditional formatting beyond the score cell.
- Per-item byte sizes or sensitivity labels.
- Automatic xlsx after every scan.
- Hand-rolled OOXML fallback when ImportExcel cannot be installed.
