# Tenant hardening

The **Sharing** tab shows the current tenant sharing posture (`Get-PnPTenant`) and applies hardening settings (`Set-PnPTenant`) behind typed confirmation. Cleaning up existing sharing does not prevent new sharing; this tab is what keeps the tenant clean.

Keys: `Enter` loads the posture, `R` refreshes, and digits or `Enter` change the highlighted setting (this tab owns the digit keys, so use `Tab`/`Shift+Tab` to leave it).

## Settings covered

| Setting | Effect | Notes |
|---|---|---|
| `SharingCapability` | External sharing level for SharePoint | SPO admin UI: Sharing > External sharing > SharePoint |
| `OneDriveSharingCapability` | External sharing level for OneDrive | Must be <= SharePoint |
| `DefaultSharingLinkType` | Link type pre-selected in the sharing dialog | `AnonymousAccess` = "Anyone" |
| `DefaultLinkPermission` | Permission pre-selected in the sharing dialog | View/Edit |
| `RequireAnonymousLinksExpireInDays` | Expiration for anonymous ("Anyone") links | Org-link and guest expiry are separate settings; `0`/blank = never |
| `SharingDomainRestrictionMode` | Limit sharing by domain (AllowList/BlockList) | Domain lists editable in the SPO admin UI |
| `FileAnonymousLinkType` | Default permission for anonymous file links | View/Edit |
| `FolderAnonymousLinkType` | Default permission for anonymous folder links | View/Edit |
| `PreventExternalUsersFromResharing` | Block guests from resharing | `True` recommended |
| `ExternalUserExpirationRequired` | Guest site access expires after N days | Access, not a link setting |
| `ExternalUserExpireInDays` | Days until guest site access expires | Only if expiration is required |
| `LegacyAuthProtocolsEnabled` | Legacy auth on/off | CIS 7.2.1: `False` = modern authentication required |
| `EnableAzureADB2BIntegration` | Entra B2B integration for guest management | CIS 7.2.2 |
| `EmailAttestationRequired` | Guests reauthenticate with a verification code | CIS 7.2.10 |
| `EmailAttestationReAuthDays` | Days between guest reauthentication | CIS 7.2.10 |
| `ShowEveryoneClaim` | Show "Everyone" in the People Picker | `False` (hidden) recommended |
| `ShowAllUsersClaim` | Show "All Users (x)" org-wide claims in the People Picker | |
| `ShowEveryoneExceptExternalUsersClaim` | Show EEEU in the People Picker | |
| `AllowEveryoneExceptExternalUsersClaimInPrivateSite` | Allow the EEEU claim in private sites | |
| `CoreOrganizationSharingLinkMaxExpirationInDays`, `OneDriveOrganizationSharingLinkMaxExpirationInDays` | Longest a new "People in your organization" link may live, for SharePoint sites and for OneDrive | 7-720 days, `0` = never. No CIS recommendation |
| `CoreOrganizationSharingLinkRecommendedExpirationInDays`, `OneDriveOrganizationSharingLinkRecommendedExpirationInDays` | Days suggested in the sharing dialog for those links | Not above the maximum. No CIS recommendation |
| `CoreAnyoneSharingLinkMaxExpirationInDays`, `OneDriveAnyoneSharingLinkMaxExpirationInDays` | Longest a new Anyone link may live, for SharePoint sites and for OneDrive | 1-730 days, `0` = never. No CIS recommendation |
| `CoreAnyoneSharingLinkRecommendedExpirationInDays`, `OneDriveAnyoneSharingLinkRecommendedExpirationInDays` | Days suggested in the sharing dialog for Anyone links | Not above the maximum. No CIS recommendation |

The eight link-expiration rows are new and show a blank value on a tenant that does not expose them. Only links created after a limit is set get an expiry date; Microsoft's documentation says an older "People in your organization" link is checked against its creation date the next time someone uses it. These rows are not part of the CIS baseline: the benchmark text this tool follows (v5.0.0) has no recommended value for them, and Microsoft publishes only the allowed ranges.

Sharing-capability values are shown with the SharePoint admin UI wording alongside the internal enum (for example `ExternalUserAndGuestSharing (Anyone)`), both in the posture view and the value picker.

## CIS alignment badges

Each value carries a badge when a CIS Microsoft 365 Foundations 7.2.x rule covers it:

- Green **CIS ✓**: the value meets the recommended state (or is stricter)
- Dim **CIS ✗**: it does not

Settings without a CIS rule show no badge.

## CIS baseline one-shot apply

- `C` applies the **CIS Microsoft 365 Foundations 7.2.x sharing baseline** (L1, or L1+L2 via picker; typed `CIS` confirmation).
- Current values are snapshotted to the per-tenant cache directory first.
- `Z` **reverts** to the latest snapshot (typed `REVERT` confirmation).
- CIS 7.2.6 (domain allowlist) is shown as a notice but is not applied, because the allowed-domains list is org-specific.
