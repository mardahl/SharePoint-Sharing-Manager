# OneDrive Pre-Provisioning v2 — Selectable Rows Design

Date: 2026-09-15
Status: Approved for planning
Supersedes the bulk flow in `2026-09-15-onedrive-pre-provisioning-design.md`
(shipped in v1.10.0-rc.1).

## Goal

Replace the all-or-nothing provisioning modal with rows in the OneDrives
list: unprovisioned users appear as target rows under a dedicated
`Unprovisioned` filter, the operator selects the ones to provision with the
normal selection keys, and `P` provisions only the selection.

## Data model

- Unprovisioned users are added to `$Tab['Items']` as target hashtables
  created by `New-Target` with:
  - `Url` = predicted personal-site URL
    `https://<tenant>-my.sharepoint.com/personal/<slug>` where `<tenant>` is
    the prefix of `$script:Auth.AdminUrl` (`https://<tenant>-admin.sharepoint.com`)
    and `<slug>` = `ConvertTo-SsmPersonalSlug -Upn`. Serves as the dedup key.
  - `Title` = DisplayName, falling back to UPN.
  - New key `Upn` (string).
  - `Status = 'Unprovisioned'`.
- New status `ProvisionRequested`, set on a row after its UPN was submitted
  successfully. Rows in a failed batch keep `Unprovisioned`.
- `Test-SsmPlaceholderTarget -Target` returns `$true` when `Status` is
  `Unprovisioned` or `ProvisionRequested`. Placeholder rows:
  - are skipped by the scan loop (`S`) with a WARN log line;
  - are ignored by `Get-SsmOneDriveAdminSelectedTargets` (`M`);
  - are not written to `session.json` (transient; `P` reloads them);
  - are removed by `C` along with everything else (existing behaviour).

## Filter

- `F` cycle on the OneDrives tab:
  `All -> NotScanned -> Clean -> Findings -> Failed -> Unprovisioned -> All`.
  Sites tab cycle unchanged.
- `Update-TabView`: every filter except `Unprovisioned` excludes placeholder
  rows; `Unprovisioned` shows only placeholder rows. Placeholders therefore
  never appear under `All`.
- Status line appends `   unprovisioned:<N> (F to view)` when N > 0.

## Badge

`Get-StatusBadge`:

| Status | Style | Glyph | Text |
|---|---|---|---|
| `Unprovisioned` | `$t.Attention` (new theme key, bold orange `ESC[1;38;5;208m`) | `!` in both ASCII and Unicode glyph tables (new key `Bang`) | `Unprovisioned` |
| `ProvisionRequested` | `$t.Cloud` | `$g.Half` | `Requested` |

## `P` key behaviour (OneDrives tab only)

Let `placeholders` = items where `Test-SsmPlaceholderTarget`, `chosen` =
placeholders with `Selected` and `Status -eq 'Unprovisioned'`.

1. **No placeholders loaded**: run `Get-SsmLicensedUsers` and
   `Get-SsmProvisionedOwnerSet` (existing, with existing progress modals and
   403 / admin-connect error handling), diff with
   `Get-SsmUnprovisionedUsers`, build rows, `Add-TargetsToTab`, set
   `$Tab['Filter'] = 'Unprovisioned'`, `Cursor = 0`, `Update-TabView`. Write
   `SSM_ONEDRIVE_UNPROVISIONED_<stamp>.csv` when N > 0. Show
   `Show-MsgModal`: `N unprovisioned user(s) loaded. Space/A selects, P
   provisions the selection.` (or `No unprovisioned licensed users found.`).
2. **Placeholders loaded, `chosen.Count > 0`**: `Show-TypedConfirmModal`
   word `PROVISION`, body lists chosen UPNs and the asynchronous-provisioning
   note. On confirm: `Invoke-SsmPersonalSiteRequest -Upns` (chosen UPNs),
   set `Status = 'ProvisionRequested'` and `Selected = $false` on rows whose
   result is `Requested`; write `SSM_ONEDRIVE_REQUESTED_<stamp>.csv`;
   `Update-TabView`; summary `Show-MsgModal` (requested / failed counts, CSV
   path, async note, "P after C reloads to verify").
3. **Placeholders loaded, `chosen.Count = 0`**: `Show-MsgModal` Warn:
   `Nothing selected. F to the Unprovisioned filter, Space/A to select, then
   P. C clears the list so P can reload it.`

`Enter` on an empty view while `Filter -eq 'Unprovisioned'` behaves as
case 1 (mirrors Enter-on-empty-list enumeration).

## Error handling

Unchanged from v1: Graph 403 → permissions modal, abort; admin connection
failure → existing path, abort; failed batch → rows stay `Unprovisioned`,
logged, listed in REQUESTED CSV.

## Testing (assert-based, no live calls)

- `Update-TabView`: placeholder hidden under `All`/`NotScanned`; shown only
  under `Unprovisioned`; non-placeholders hidden under `Unprovisioned`.
- `Get-StatusBadge` returns text `Unprovisioned` / `Requested` for the new
  statuses.
- `Test-SsmPlaceholderTarget` true/false cases.
- `Save-SsmCache` (or equivalent) omits placeholder rows.
- `Invoke-SsmOneDriveProvision` with stubs: case 1 adds rows and sets filter;
  case 2 calls request with only chosen UPNs and flips status; case 3 does
  not call request.
- `F` cycle reaches `Unprovisioned` on OneDrive tab and not on Sites tab.

## Documentation

- `CHANGELOG.md` Unreleased: `Change:` entry describing the new flow.
- `wiki/OneDrive-Pre-Provisioning.md`: rewrite Key/Flow sections.
- `README.md` bullet, help row in `src/20-modals.ps1`, footer hint text
  (`P` → `pre-provision`).

## Known issues / limitations

- Predicted URL is a display/dedup value only; the real site may get a
  different suffix if SharePoint disambiguates. Nothing connects to it.
- Placeholder rows are not cached; a restart requires `P` to reload them.
- Same detection limits as v1 (Owner empty + slug mismatch → false
  positive; harmless request).

## Out of scope

- Provisioning a single row with `Enter` (Space + `P` covers it).
- Persisting placeholders across restarts.
