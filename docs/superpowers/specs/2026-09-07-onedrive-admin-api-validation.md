# OneDrive secondary administrator: API validation gate

Date: 2026-09-07

Status: Local/documentation stage COMPLETE. Live-fixture stage DEFERRED (not
passing) by explicit user decision. Implementation may proceed using mocked
tests against the documented findings below. The feature remains
RELEASE-BLOCKED: it must not ship, be enabled by default, or be exercised
against a live tenant until the deferred live checks in "Unmet tests" below
are run and pass, and this document is updated with the result.

## Scope of this document

This is the bounded API-validation task required by the design spec's
"API and permission validation gate" section before any mutation code is
written. It covers local environment/cmdlet checks and authoritative
documentation review (both completed) and live directory/ownership checks
against a real tenant. The user explicitly chose to defer the live-fixture
stage rather than block implementation on it: test tenant, fixtures, and
authorization to make live calls were not provided in this session, and
credentials were not inspected. This is a deliberate deferral, not a failed
or abandoned attempt, and implementation of Tasks 2-5 with mocked tests may
proceed on that basis while the live stage remains outstanding.

## Test date and environment

- Date: 2026-09-07
- PowerShell: 7.6.3 (`pwsh -Command '$PSVersionTable.PSVersion'`)
- PnP.PowerShell module installed locally: 3.3.0 (`Get-Module -ListAvailable PnP.PowerShell`)
- No PnP connection was opened. No tenant, credential, or test account was
  contacted. No live SharePoint or Graph call was made.

## Step 1: Local baseline

```
git status --short        -> clean (no output)
pwsh tests/run-tests.ps1   -> 132 passed, 0 failed
```

## Step 2: Installed cmdlet signatures (local module inspection only)

```
Get-Command Get-PnPSiteCollectionAdmin -Syntax
  Get-PnPSiteCollectionAdmin [-Connection <PnPConnection>] [-Includes <string[]>]

Get-Command Add-PnPSiteCollectionAdmin -Syntax
  Add-PnPSiteCollectionAdmin [-Owners <List[UserPipeBind]>]
      [-PrimarySiteCollectionAdmin <UserPipeBind>] [-Connection <PnPConnection>]

Get-Command Remove-PnPSiteCollectionAdmin -Syntax
  Remove-PnPSiteCollectionAdmin -Owners <List[UserPipeBind]> [-Connection <PnPConnection>]

Get-Command Invoke-PnPGraphMethod -Syntax
  Invoke-PnPGraphMethod [-Url] <string> [-Method <HttpRequestMethod>] [-Content <Object>]
      [-ContentType <string>] [-AdditionalHeaders ...] [-ConsistencyLevelEventual]
      [-All] [-Connection <PnPConnection>]   (plus -OutFile / -OutStream / -Batch variants)

Get-Command Register-PnPEntraIDAppForInteractiveLogin -Syntax
  ...-ApplicationName <string> -Tenant <string> [-DeviceLogin]
      [-GraphApplicationPermissions <string[]>] [-GraphDelegatePermissions <string[]>] ...

Get-Command Register-PnPAzureADApp -Syntax
  (alias -> Register-PnPEntraIDApp; same permission-list parameters, certificate-based)
```

All six cmdlets exist on the installed module version. Add-/Remove-PnPSiteCollectionAdmin
both accept -Owners (a list of UserPipeBind) and an explicit -Connection, matching the
design's requirement to avoid -PrimarySiteCollectionAdmin and to bind to a specific
connection.

Repository check: `src/60-setup-actions.ps1` currently registers app-only apps with
`SharePointApplicationPermissions = 'Sites.FullControl.All'` and
`GraphApplicationPermissions = 'Sites.FullControl.All'`. `Sites.FullControl.All` is a
tenant-wide SharePoint/Graph permission that is broader than `Sites.Read.All` or
`Files.Read.All`; it is not itself evidence that a narrower drive-read permission is
missing, and whether it also satisfies a Graph drive/list-drives call has not been tested
live. The one gap that is confirmed from documentation is directory user lookup: no
`User.Read.All` (or any Graph application permission scoped to directory user reads) is
granted today, and `Get user` documents `User.Read.All` as the least-privileged
application permission for reading a user other than the caller. That gap is real
regardless of what `Sites.FullControl.All` does or does not cover for drives.

The delegated registration path (`Register-PnPEntraIDAppForInteractiveLogin`) was not
inspected for its default consented scopes in this session, and the shipped registration
code in `src/60-setup-actions.ps1` was only grepped for the strings above, not read in
full for delegated-scope defaults. No claim is made here about which delegated Graph
scopes are or are not already granted; that requires reading the full registration call
and, ideally, confirming against a live app registration.

## Step 3: Authoritative documentation findings

### Graph GET /users/{id | userPrincipalName} (user lookup)

Source: https://learn.microsoft.com/en-us/graph/api/user-get?view=graph-rest-1.0 (fetched 2026-09-07)

- Delegated least-privilege for reading another user: User.ReadBasic.All. User.Read only
  covers the signed-in user (/me), confirming the design's statement.
- Application least-privilege: User.Read.All.
- Default response includes id, userPrincipalName, displayName, sufficient for the
  design's required fields without extra $select.
- Special-character handling confirmed: a UPN starting with $ must be queried as
  /users('$x@y.com') (parentheses and quotes), not /users/$x@y.com, or it returns 400.
  A UPN containing # must have the # percent-encoded (%23). Both match the design's
  requirement to encode # and a leading $ and never string-interpolate raw input into
  the URL/OData path.

### PnP Add-PnPSiteCollectionAdmin / Remove-PnPSiteCollectionAdmin

Source: https://pnp.github.io/powershell/cmdlets/Add-PnPSiteCollectionAdmin.html (fetched 2026-09-07)

- -Owners adds one or more secondary administrators without removing existing ones.
  Confirmed by doc text: "It does not replace or remove existing site collection
  administrators."
- -PrimarySiteCollectionAdmin replaces the current primary administrator. This
  parameter must never be used by this feature, per design; confirmed by docs as the
  primary-promotion path to avoid.
- The doc requires the caller be Site Collection Admin on the target site (delegated
  context) or use Set-PnPTenantSite -Owners from tenant-admin context otherwise. Whether
  and how this applies to an app-only connection is not stated on this page and was not
  tested live.
- Remove-PnPSiteCollectionAdmin -Owners is documented as removing only the specified
  administrator role, matching the design's "remove only the exact principal"
  requirement.

### Graph drive read candidates: Get drive vs. List drives

Sources: https://learn.microsoft.com/en-us/graph/api/drive-get?view=graph-rest-1.0,
https://learn.microsoft.com/en-us/graph/api/resources/drive?view=graph-rest-1.0, and
https://learn.microsoft.com/en-us/graph/api/drive-list?view=graph-rest-1.0 (all fetched
2026-09-07)

- Get drive (/me/drive, /users/{id}/drive, /groups/{id}/drive, /sites/{id}/drive,
  /drives/{id}) documents application permission as "Not supported" for every variant.
  This rules out Get drive specifically for app-only auth; it is not evidence about
  every possible Graph drive-read shape.
- List Drives (GET /sites/{siteId}/drives, GET /groups/{groupId}/drives,
  GET /users/{userId}/drives) documents an application permission path:
  least-privileged Files.Read.All, higher-privileged Files.ReadWrite.All,
  Sites.Read.All, Sites.ReadWrite.All. This is a genuine, documented, untested
  app-only-capable alternative candidate for reading a site's drive (and its owner)
  that Task 1 did not have fixtures to exercise live. It must not be assumed to work
  identically to Get drive; it returns a collection and its owner-field behavior for a
  personal site's single drive has not been observed live.
- Delegated least-privilege for Get drive is Files.Read; Sites.Read.All/
  Sites.ReadWrite.All are documented higher-privileged alternatives.
- owner on the drive resource is documented Optional (an identitySet, itself a bag of
  optional user/application/device sub-objects), confirming the design's statement that
  owner is optional and must be treated as an unreliable/absent value, not assumed
  present. This optionality applies to both Get drive and List Drives, since both return
  the same drive resource shape.
- GET /users/{idOrUserPrincipalName}/drive documentation states: "If a user's OneDrive
  isn't provisioned but the user has a license to use OneDrive, this request will
  automatically provision the user's drive, when using delegated authentication." This
  confirms the design's warning to avoid this endpoint for validation. GET
  /sites/{siteId}/drive and GET /sites/{siteId}/drives are site-bound reads and no
  auto-provisioning behavior is documented for them, but this has not been proven live
  either way.
- sharepointIds on drive is documented as not returned by default; it requires
  $select=sharepointIds, confirming the design's requirement to explicitly select it.

## Findings summary (what is proven vs. not proven)

- Target cmdlets exist in installed PnP.PowerShell 3.3.0: proven locally.
- Add-/Remove-PnPSiteCollectionAdmin -Owners semantics (additive/subtractive, no primary
  change): proven from PnP docs.
- Graph delegated user lookup least privilege (User.ReadBasic.All) and application
  (User.Read.All): proven from Graph docs.
- Special-character ($, #) encoding requirements for user lookup: proven from Graph docs.
- Get drive application permission is documented "Not supported" for all its variants:
  proven from Graph docs, scoped to that specific API only.
- List Drives (GET /sites/{siteId}/drives) documents an application-permission path
  (Files.Read.All least-privileged): proven from Graph docs as a documented candidate;
  not yet tested live against a real personal site/drive.
- drive.owner is optional and not guaranteed present: proven from Graph docs, applies to
  both Get drive and List Drives.
- /users/{upn}/drive can auto-provision on delegated read: proven from Graph docs.
- Site-bound GET /sites/{siteId}/drive or /drives avoids that documented
  auto-provisioning side effect: not proven; no documented statement either way was
  found, requires a live test.
- Actual owner-vs-primary-admin mismatch is distinguishable via a real Graph/PnP read:
  not proven; requires an authorized test OneDrive with owner not equal to primary admin.
- Delegated mode can perform both the directory read and the SharePoint admin mutation on
  one authorized fixture: not proven, no live test run.
- App-only mode is ruled out for Get drive specifically (documented "Not supported"); it
  is not ruled out for owner reads in general, since List Drives documents an
  application-permission path that has not been tested. Mutation-cmdlet app-only
  behavior against a real site has also not been tested.
- Current app registration flow's directory-read coverage: User.Read.All is confirmed
  absent from today's app-only registration. Whether Sites.FullControl.All (already
  granted) is sufficient for a Graph drive/list-drives read, and what the delegated
  registration path grants by default, are both open questions requiring further source
  review and/or a live test, not settled by this document.

## Unmet tests: what still requires an authorized test tenant (deferred, gates release only)

None of the design's step 3 through 5 live checks have run. This is an
explicit, user-chosen deferral, not a hard stop on implementation: Tasks 2-5
may implement the guarded feature with mocked tests now, using the
documented-only findings above. The feature must not be released, shipped
enabled, or run against a live tenant until the items below are provided,
the checks are re-run, and they pass. Each requires an operator to
explicitly authorize and provide:

1. Test fixtures: at least one disposable OneDrive with a known actual owner, a distinct
   known primary administrator (owner not equal to primary admin), and a distinct
   candidate account to add/remove as secondary admin. A second fixture where owner
   equals primary admin, for the normal-match case.
2. Explicit authorization to run read-only Graph/PnP calls against those fixtures
   (Get-PnPSiteCollectionAdmin, a site-bound drive read via both Get drive and List
   Drives, GET /users/{id}), and, separately, explicit authorization to run the mutating
   calls (Add-/Remove-PnPSiteCollectionAdmin) against the mismatch fixture, followed by
   verification and cleanup.
3. A connection with delegated auth (interactive) and, separately, a connection with
   app-only auth, using the currently-registered Sites.FullControl.All app to observe its
   real behavior for both List Drives and directory lookup, and optionally a fresh
   registration with candidate additional Graph permissions (User.Read.All, and whichever
   least-privilege scope the live drive-owner read turns out to need), to test each mode
   independently as the design requires.
4. With those fixtures and connections, the actual assertions from the task brief need to
   be run and observed to pass, not just referenced: resolvedUser.id equals the known
   candidate's object ID; liveOwnerId (from the chosen site-bound drive-owner read) equals
   the known actual owner's object ID and does not equal the known differing primary
   administrator's ID; boundSiteId equals the known target site ID; add/remove of the
   candidate on the mismatch fixture leaves the actual owner and primary administrator
   memberships unchanged, and re-read confirms the add/remove landed.
5. Confirmation of which Graph read (Get drive where supported, or List Drives) and which
   minimal scope (Files.Read, Files.Read.All, Sites.Read.All, or the already-granted
   Sites.FullControl.All) actually succeeds for the site-bound drive-owner read, in both
   delegated and app-only modes, since documentation lists candidates without confirming
   which one this repository's existing consent already satisfies.

## Setup/registration changes needed (once a live path is proven)

- The current app-only registration is missing User.Read.All (or an equivalent
  directory-read application permission); this gap is confirmed from Get user
  documentation and must be closed with new, explicit consent if app-only directory
  lookup is part of the proven path. Do not add it speculatively before a live path is
  proven.
- Whether app-only mode can also satisfy the drive-owner read (via List Drives, using
  Files.Read.All/Sites.Read.All/Sites.ReadWrite.All, or via the already-granted
  Sites.FullControl.All) has not been tested and must not be assumed either way until a
  live fixture test confirms it.
- If delegated mode is used, the registration/consent flow in src/60-setup-actions.ps1
  may need an additional Graph delegated scope for user lookup (at least
  User.ReadBasic.All); this has not been confirmed against the actual default scopes
  requested by Register-PnPEntraIDAppForInteractiveLogin in this codebase, which was not
  read in full this session. Do not modify existing registrations' granted permissions
  without explicit new consent, per design.

## Gate decision

Task 1 local/documentation stage: COMPLETE. Live-fixture stage: DEFERRED
(not passing) by explicit user decision; test tenant, fixtures, and
authorization to make live calls were not provided in this session, and
credentials were not inspected or discovered. Documentation review resolves
what the APIs claim to support for the specific endpoints checked, and rules
out Get drive specifically for app-only auth, but does not rule out an
app-only-capable path in general (List Drives remains an untested
candidate), and does not meet the design's acceptance bar that
"Test actual API permissions and ownership semantics in a dedicated test
tenant; unit tests cannot prove those properties." Per the user's explicit
choice to defer rather than block: Task 2 and subsequent implementation
tasks MAY proceed using mocked tests against these documented findings. The
feature remains RELEASE-BLOCKED until an operator supplies the fixtures and
authorization listed above, the assertions in "Unmet tests" are run and pass
against a real tenant, and this document is updated with the outcome.

## References

- https://pnp.github.io/powershell/cmdlets/Add-PnPSiteCollectionAdmin.html
- https://pnp.github.io/powershell/cmdlets/Remove-PnPSiteCollectionAdmin.html (not
  fetched directly this session; Get-Command -Syntax confirms parameter shape locally)
- https://learn.microsoft.com/en-us/graph/api/user-get?view=graph-rest-1.0
- https://learn.microsoft.com/en-us/graph/api/drive-get?view=graph-rest-1.0
- https://learn.microsoft.com/en-us/graph/api/resources/drive?view=graph-rest-1.0
- https://learn.microsoft.com/en-us/graph/api/drive-list?view=graph-rest-1.0
- Design spec: docs/superpowers/specs/2026-09-07-onedrive-secondary-admin-design.md
