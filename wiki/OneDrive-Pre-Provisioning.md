# OneDrive Pre-Provisioning

Find users who are licensed for OneDrive but have never had a personal
site created, and request provisioning for the ones you select. Useful
before migrations or before assigning secondary admins, both of which need
the OneDrive to exist first.

## Key

`P` on the **OneDrives** tab. `P` is context-aware:

| State | What `P` does |
|---|---|
| No unprovisioned rows loaded | Queries the tenant and loads them under the `Unprovisioned` filter |
| Unprovisioned rows selected | Asks for `PROVISION` and submits only the selected users |
| Rows loaded, nothing selected | Shows a hint |

`Enter` on an empty list while the `Unprovisioned` filter is active also
loads the rows.

## What counts as licensed

An enabled member user (`accountEnabled = true`, `userType = Member`) with
at least one `assignedPlans` entry where `service = SharePoint` and
`capabilityStatus = Enabled`. Guests and disabled accounts are excluded.

## How "not provisioned" is decided

The tool enumerates every personal site (`SPSPERS*` template) through the
tenant admin connection and builds a set of each site's owner UPN and its
`/personal/<slug>` URL segment. A licensed user missing from both is
reported as unprovisioned. No per-user Graph or drive calls are made.

## The Unprovisioned filter

`F` cycles `All → Not scanned → Clean → Findings → Failed → Unprovisioned`
on the OneDrives tab. Unprovisioned rows show only under that filter, never
under `All`, so the normal OneDrive list is unaffected. Each row shows the
user's display name, the personal-site URL SharePoint will normally assign,
and an orange `! Unprovisioned` badge. The status line shows
`unprovisioned:N (F to view)` while any are loaded.

These rows are placeholders: scans (`S`), admin actions (`M`) skip them, and
they are not saved to the session cache. `C` clears them with the rest of
the list; `P` reloads them.

## Flow

1. Press `P`. Progress shows the Graph user paging, then the personal-site
   enumeration. Rows are added and the filter switches to `Unprovisioned`.
   `SSM_ONEDRIVE_UNPROVISIONED_<stamp>.csv` is written to
   `SSM-Exports/<tenant>/` when at least one user is found.
2. Select the users to provision with Space or `A`.
3. Press `P`, type `PROVISION`. The selected UPNs are sent to
   `Request-PnPPersonalSite` in batches of 200.
4. Successfully submitted rows change to `Requested`;
   `SSM_ONEDRIVE_REQUESTED_<stamp>.csv` records `Upn, Batch, Status, Method, Error`.
   Rows in a failed batch stay `Unprovisioned` so they can be retried.

## Permissions

| Auth mode | Needs |
|---|---|
| Delegated | SharePoint Administrator role; `User.Read.All` (included in the default delegated scopes) |
| App-only | `Sites.FullControl.All` (SharePoint + Graph), **`User.ReadWrite.All` (SharePoint)** and `User.Read.All` (Graph) application permissions. Registrations created by the setup wizard from v1.10.0 include all of them. |

`Request-PnPPersonalSite` goes through the User Profile Service, which
rejects app-only tokens that lack SharePoint `User.ReadWrite.All` with an
"access denied ... profile" message (localized to the tenant language).
Rows in that batch stay `Unprovisioned` and the summary modal shows the
first error plus the fix.

**Existing app-only registrations are not changed automatically.** To add
the permission once: Entra portal > App registrations >
`SharePoint-Sharing-Manager` > API permissions > Add a permission >
SharePoint > Application permissions > `User.ReadWrite.All` > Grant admin
consent (Global Administrator or Privileged Role Administrator). Then run
`P` again.

## App-only mode and PnP issue #4329

`Request-PnPPersonalSite` (CSOM `Tenant.RequestPersonalSites`) fails under
app-only certificate authentication with "Attempted to perform an
unauthorized operation" no matter which permissions are granted
([pnp/powershell#4329](https://github.com/pnp/powershell/issues/4329),
open since 2024). The tool therefore retries every failed batch with
`New-PnPPersonalSite` (User Profile Service
`CreatePersonalSiteEnqueueBulk`), which requires the SharePoint application
permission `User.ReadWrite.All` and works app-only. The
`SSM_ONEDRIVE_REQUESTED_<stamp>.csv` file records which API succeeded in
its `Method` column. If both fail, use delegated sign-in (Setup tab) for
this operation; delegated mode is not affected by the bug.

## Limitations

- Provisioning is asynchronous on the SharePoint side and can take minutes
  to hours. Press `P` again later to confirm the unprovisioned count drops.
- A personal site whose owner field is empty **and** whose URL slug no
  longer matches the user's current UPN (for example after a UPN rename) is
  reported as unprovisioned. Requesting it again is harmless; SharePoint
  ignores requests for users who already have a site.
- No automatic retry on throttling. Failed batches are listed in the
  REQUESTED CSV; re-run `P` to retry them.
- The URL shown on an unprovisioned row is predicted from the UPN; the
  actual site can get a different suffix if SharePoint has to disambiguate.
- Unprovisioned rows are not cached; after a restart press `P` to reload.
