# OneDrive Pre-Provisioning — Design

Date: 2026-09-15
Status: Approved for planning

## Goal

Add a secondary tool on the OneDrives tab that finds OneDrive-licensed users
whose personal site has not been provisioned yet, shows the list, exports it
to CSV, and (after typed confirmation) requests provisioning for all of them
in bulk.

Primary purpose is the provisioning step; the list is the evidence and
preview for it.

## Definitions

- **Licensed user**: `accountEnabled eq true`, `userType eq 'Member'`, and at
  least one entry in `assignedPlans` with `service -eq 'SharePoint'` and
  `capabilityStatus -eq 'Enabled'`. Matching on the `service` field avoids
  maintaining a list of service-plan GUIDs.
- **Provisioned**: a personal site (`SPSPERS*` template) exists in the tenant
  whose `Owner` equals the user's UPN (case-insensitive), or whose URL ends in
  `/personal/<slug>` where `<slug>` is the UPN with `.` and `@` replaced by
  `_`. The URL fallback covers personal sites with an empty or SID-shaped
  `Owner` value.
- **Unprovisioned**: licensed and not provisioned.

## Architecture

New region file `src/47-onedrive-provision.ps1` (loads after
`46-onedrive-admin.ps1`). Functions:

| Function | Purpose | Depends on |
|---|---|---|
| `Get-SsmLicensedUsers` | Page through Graph `GET /users?$filter=accountEnabled eq true and userType eq 'Member'&$select=id,userPrincipalName,displayName,assignedPlans&$top=999`, follow `@odata.nextLink`, filter client-side per Definitions. Returns `[pscustomobject]{Id; Upn; DisplayName}`. | `Invoke-PnPGraphMethod` on the current connection |
| `Get-SsmProvisionedOwnerSet` | Enumerate personal sites via tenant CSOM (`SPOSitePropertiesEnumerableFilter` with `IncludePersonalSite = Include`, same paging as `Get-TenantTargets` in `src/45-targets.ps1`). Returns a case-insensitive `HashSet[string]` containing each site's lowercased `Owner` and its URL slug. | Admin connection |
| `ConvertTo-SsmPersonalSlug` | `user@example.com` → `user_example_com`. Pure function. | none |
| `Get-SsmUnprovisionedUsers` | Diff licensed users against the owner set (by UPN, then by slug). Pure function; takes both inputs as parameters so it is unit-testable. | none |
| `Invoke-SsmPersonalSiteRequest` | Split UPNs into batches of 200, call `Request-PnPPersonalSite -UserEmails <batch>` on the admin connection, log each batch, continue on failure. Returns per-UPN `{Upn; Batch; Status}`. | Admin connection |

The paging loop in `Get-TenantTargets` is reused if it can be factored into
a small shared helper without changing behaviour; otherwise the ~10 lines are
duplicated with a `ponytail:` comment naming the duplication.

Other touch points:

- `src/75-key-dispatch.ps1`: `P` on the OneDrives tab calls
  `Invoke-OneDriveProvisionView`.
- `src/65-views.ps1`: `Invoke-OneDriveProvisionView` orchestrates the flow;
  hint line for `P` added next to the existing `M` hint.
- `src/50-csv.ps1`: `Export-SsmUnprovisionedCsv` writes
  `ONEDRIVE-UNPROVISIONED-<timestamp>.csv` (Upn, DisplayName) and
  `ONEDRIVE-PROVISION-REQUESTED-<timestamp>.csv` (Upn, Batch, Status) into
  the tenant export directory resolved by the existing helper in
  `src/25-config.ps1`.
- `src/20-modals.ps1`: `P` added to the help/key reference.

## Flow

1. Operator presses `P` on the OneDrives tab.
2. Status line: `Querying Graph for licensed users…`.
3. Status line: `Enumerating personal sites…` (admin connection established
   via the existing admin-connect path if not already open).
4. Diff computed. Unprovisioned CSV written.
5. Report modal: `N licensed · M provisioned · K unprovisioned`, UPN list,
   CSV path.
   - `K = 0`: modal closes, done.
6. Typed confirmation: operator must type `PROVISION`.
7. Batches submitted. Status line shows `Batch b/B`.
8. Requested CSV written. Summary modal: `Requested K users in B batches
   (F failed). SharePoint provisions personal sites asynchronously; re-run P
   later to verify the unprovisioned count shrinks.`

## Error handling

- Graph `403` → modal: `Graph returned 403. Delegated sign-in needs
  User.Read.All; app-only registrations need User.Read.All application
  permission.` Abort, nothing written.
- Admin connection failure → existing admin-connection error path; abort.
- Graph paging error mid-way → abort with the error; no partial diff is
  shown, because a partial licensed list would understate the result.
- A failed `Request-PnPPersonalSite` batch is logged, marked `Failed` for
  every UPN in that batch, and the run continues with the next batch. No
  automatic retry. `ponytail:` comment marks the ceiling; add backoff if
  throttling is observed in practice.

## Permissions

- Delegated: `User.Read.All` (already part of the PnP default delegated
  scopes) plus SharePoint Administrator role for the tenant admin connection.
- App-only: `User.Read.All` (already granted by the setup action) plus
  `Sites.FullControl.All`.

No new permissions introduced.

## Testing

Assert-based test under `tests/` covering only pure logic, no live calls:

- `ConvertTo-SsmPersonalSlug`: `john.doe@contoso.com` → `john_doe_contoso_com`.
- `Get-SsmUnprovisionedUsers`: matches by UPN, matches by slug when `Owner`
  is empty, is case-insensitive, returns users absent from both.

Live behaviour (Graph paging, CSOM enumeration, `Request-PnPPersonalSite`)
is verified manually against a test tenant.

## Documentation

- `CHANGELOG.md`: entry under Unreleased.
- `wiki/OneDrive-Pre-Provisioning.md`: new page (what it does, key, CSVs
  written, permissions, asynchronous-provisioning note); row added to the
  table in `wiki/Home.md`.
- `README.md`: `P` added to the OneDrives key list.

## Known issues / limitations

- Detection relies on the tenant personal-site enumeration. A personal site
  whose `Owner` is empty **and** whose URL slug does not match the current
  UPN (e.g. after a UPN rename) is reported as unprovisioned. Requesting
  provisioning for such a user is harmless: SharePoint ignores requests for
  users who already have a personal site.
- Provisioning is asynchronous on the SharePoint side and can take minutes
  to hours. The tool cannot report completion; re-running `P` is the check.
- Guests and disabled accounts are excluded by design.
- Large tenants: Graph paging is one request per 999 users; CSOM enumeration
  is one request per page of personal sites. No per-user calls are made.

## Out of scope

- Per-user drive probing via Graph (`/users/{id}/drive`).
- Scheduling or background polling for provisioning completion.
- Provisioning for a manually supplied UPN list (import). Can be added later
  by feeding an import into `Invoke-SsmPersonalSiteRequest`.
