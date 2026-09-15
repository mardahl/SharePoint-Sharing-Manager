# OneDrive Pre-Provisioning

Find users who are licensed for OneDrive but have never had a personal
site created, and request provisioning for all of them in one pass. Useful
before migrations or before assigning secondary admins, both of which need
the OneDrive to exist first.

## Key

`P` on the **OneDrives** tab. No selection needed; the tool works on the
whole tenant.

## What counts as licensed

An enabled member user (`accountEnabled = true`, `userType = Member`) with
at least one `assignedPlans` entry where `service = SharePoint` and
`capabilityStatus = Enabled`. Guests and disabled accounts are excluded.

## How "not provisioned" is decided

The tool enumerates every personal site (`SPSPERS*` template) through the
tenant admin connection and builds a set of each site's owner UPN and its
`/personal/<slug>` URL segment. A licensed user missing from both is
reported as unprovisioned. No per-user Graph or drive calls are made.

## Flow

1. Press `P`. Progress shows the Graph user paging, then the personal-site
   enumeration.
2. A report lists `N licensed | M personal sites | K unprovisioned` and
   every unprovisioned UPN. When at least one unprovisioned user is found,
   `SSM_ONEDRIVE_UNPROVISIONED_<stamp>.csv` is written to
   `SSM-Exports/<tenant>/` (no file on a zero result).
3. If `K > 0`, type `PROVISION` to submit. UPNs are sent to
   `Request-PnPPersonalSite` in batches of 200.
4. `SSM_ONEDRIVE_REQUESTED_<stamp>.csv` records `Upn, Batch, Status, Error`
   for every user. A failed batch marks all of its users `Failed`; the run
   continues with the next batch.

## Permissions

| Auth mode | Needs |
|---|---|
| Delegated | SharePoint Administrator role; `User.Read.All` (included in the default delegated scopes) |
| App-only | `Sites.FullControl.All` and `User.Read.All` application permissions (both granted by the setup wizard) |

## Limitations

- Provisioning is asynchronous on the SharePoint side and can take minutes
  to hours. Press `P` again later to confirm the unprovisioned count drops.
- A personal site whose owner field is empty **and** whose URL slug no
  longer matches the user's current UPN (for example after a UPN rename) is
  reported as unprovisioned. Requesting it again is harmless; SharePoint
  ignores requests for users who already have a site.
- No automatic retry on throttling. Failed batches are listed in the
  REQUESTED CSV; re-run `P` to retry them.
