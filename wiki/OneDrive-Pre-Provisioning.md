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

Loading or reloading the list (`Enter`, `C`) while the `Unprovisioned`
filter is active also loads the rows. Under any other filter they load only
through `P`.

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
the list; under the `Unprovisioned` filter it reloads them, under any other
filter it resets the filter to `All`.

## Flow

1. Press `P`. Progress shows the Graph user paging, then the personal-site
   enumeration. Rows are added and the filter switches to `Unprovisioned`.
   `SSM_ONEDRIVE_UNPROVISIONED_<stamp>.csv` is written to
   `SSM-Exports/<tenant>/` when at least one user is found.
2. Select the users to provision with Space or `A`.
3. Press `P`, type `PROVISION`. The selected UPNs are sent to
   `Request-PnPPersonalSite` in batches of 5 (larger batches fail or time out client-side while the server still provisions part of them).
   Progress updates after each batch. If the provisioning sign-in expires
   mid-run, the browser opens once for a fresh sign-in and the batch is
   retried; if that fails, remaining batches are marked Failed with a
   "Sign-in expired" error and nothing more is sent.
4. Successfully submitted rows change to `Requested`;
   `SSM_ONEDRIVE_REQUESTED_<stamp>.csv` records `Upn, Batch, Status, Error`.
   Rows in a failed batch stay `Unprovisioned` so they can be retried.

## Permissions and the provisioning sign-in

Loading the list (Graph users + tenant personal sites) uses the tool's
normal connection:

| Auth mode | Needs for loading |
|---|---|
| Delegated | SharePoint Administrator role; `User.Read.All` (in the default delegated scopes) |
| App-only | `Sites.FullControl.All` (SharePoint + Graph) and `User.Read.All` (Graph) - the setup wizard's standard set |

**Submitting the provisioning request is different.** The server-side API
(`Tenant.RequestPersonalSites`, what `Request-PnPPersonalSite` and
`Request-SPOPersonalSite` both call) only accepts tokens that carry the
SharePoint scope `AllProfiles.Manage`. That scope cannot be granted to any
tenant-created app registration; Microsoft pre-authorizes it only on its
first-party **SharePoint Online Management Shell** application. As a result:

- app-only certificate tokens are rejected with "Attempted to perform an
  unauthorized operation" whatever permissions the app holds (including
  `User.ReadWrite.All` and the undocumented `OneDrive.Provision.All`);
- delegated tokens from a custom app registration are rejected the same way.

See [pnp/powershell#4329](https://github.com/pnp/powershell/issues/4329)
for the traffic captures that established this.

The tool therefore opens a **separate interactive sign-in** for the
provisioning step, using the SharePoint Online Management Shell client id
(`9bc3ab49-b65d-410a-85ad-de819febfddc`) against the tenant admin site.
After typing `PROVISION`, a browser window opens: sign in with an account
that holds the **SharePoint Administrator** role and a SharePoint license.
The connection is kept for the rest of the session, so later batches do
not prompt again. The tool's own app-only or delegated connection is not
touched. No extra app permission is required for this, and the app-only
registration does not need `User.ReadWrite.All`.

If a batch still fails, the summary modal shows the first error. Typical
causes: the signed-in account lacks the SharePoint Administrator role or a
SharePoint license, or the target user is unlicensed or blocked from
signing in.

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
