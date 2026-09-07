# OneDrive secondary administrator management

Date: 2026-09-07

Status: Design specification for review. No application behavior is implemented by this document.

## Purpose and scope

Allow an operator to add or remove one secondary administrator account on one or more selected OneDrives. A secondary administrator is a SharePoint site collection administrator with full access to that OneDrive. The operation must not change OneDrive ownership.

- Reuse the OneDrives tab and existing target selection for individual and bulk operations.
- Enter one user principal name (UPN) per operation. Do not save a default account.
- Permit removal of any existing secondary administrator, regardless of which tool created the assignment.
- Validate every manually entered UPN against the connected tenant's live directory before any permission changes.
- Never remove the actual OneDrive user's own administrator role.
- Remove only the named account's site collection administrator role, not its directory account, site-user entry, sharing grants, or other permissions.

Out of scope: SharePoint Sites tab administration, groups as input, multiple admin accounts per operation, per-OneDrive CSV account mappings, scheduled changes, ownership repair, deleted-account cleanup, and persistent assignment history.

## Approach

Add a Manage Secondary Admin action to the existing OneDrive target view. This reuses selection, modal, progress, logging, and connection patterns without creating a separate admin browser.

A dedicated administration screen would support richer browsing but duplicate target navigation. CSV-driven account mappings would support different admins per target but are unnecessary for one account per operation.

## Operator flow

1. Load OneDrive targets and select one or more rows using existing selection keys. Sharing scans are not a prerequisite.
2. Press `M` in the OneDrive target view to open Manage Secondary Admin. The action is unavailable in Sites and findings views. An empty selection produces a message, never an implicit tenant-wide operation.
3. Choose Add or Remove, then enter one UPN.
4. Validate the UPN and resolve its directory identity. Failure stops the whole operation before any target mutation.
5. Perform read-only preflight for all selected targets. Classify each as eligible, already in the requested state, owner-protected, blocked, or failed.
6. Preview the resolved display name, canonical UPN, directory object ID, tenant, action, exact target URLs, and classification counts. Include selected rows hidden by filters and explain that administrator access covers the whole OneDrive.
7. Require exact typed confirmation: `ADDADMIN` or `REMOVEADMIN`. Cancellation makes no changes. If no targets are eligible, show results without requesting destructive confirmation.
8. Write BEFORE evidence, then process eligible targets sequentially. Revalidate identity and target safety immediately before each write.
9. Re-read target state after each attempted write. Show verified results and evidence paths at completion or cancellation.

The selected target set is frozen for the operation. Changing a filter does not alter confirmed scope. A new account or action requires new validation, preflight, and confirmation.

## Mandatory UPN validation

Validation is a read-only operation against Microsoft Graph using the existing PnP connection infrastructure, without adding the Microsoft Graph PowerShell SDK.

- Trim surrounding whitespace. Reject empty input, control characters, internal whitespace, lists, wildcard expressions, claims logins, and malformed UPNs.
- Accept UPN syntax rather than assuming every UPN is an email address. Encode request values safely, including supported special characters such as `#` and a leading `$`; never interpolate unescaped input into OData expressions.
- Perform an exact user lookup in the connected tenant. Require one user with nonempty `id`, `userPrincipalName`, and display information suitable for confirmation.
- Compare the returned canonical UPN with the entered UPN using case-insensitive equality. Do not accept an email alias, display-name search, fuzzy match, or guessed correction.
- Retain tenant identity, immutable directory object ID, and canonical UPN as the operation identity. Never use a SharePoint numeric user ID as a directory object ID.
- Treat not found, missing fields, ambiguous results, permission denial, authentication failure, and exhausted transient lookup failures as validation failures. Before execution, these failures mean zero permission changes across the batch.
- Do not use `EnsureUser`, invitations, or account creation as validation. Any required SharePoint user materialization for Add belongs only to the confirmed mutation stage.

Immediately before each mutation, resolve the validated account again and confirm it still has the same object ID and canonical UPN. A deleted, renamed, or recreated account must not silently redirect the operation. Identity drift or loss of directory validation stops remaining batch writes and requires a new operation; completed changes remain reported.

Directory existence is not proof that an account is safe to remove from a particular OneDrive. Owner protection remains a separate check.

## Owner protection and target safety

The shared mutation path must enforce these checks for individual and bulk use; UI checks alone are insufficient.

- Verify the live target is a personal site in the connected tenant, accessible and eligible for changes. Do not trust an imported URL, cached template, or successful token acquisition as proof.
- Resolve the actual personal-drive owner from authoritative live ownership data, independently of the removable administrator list. Bind that ownership data to the exact target site or drive.
- Resolve the owner's directory object ID and compare it with the requested account's directory object ID. Equal IDs block removal without an override.
- Also block removal of the current primary administrator. A primary-administrator mismatch requires separate ownership repair, outside this feature's scope.
- A tenant site's `Owner` field represents its primary administrator and may have been changed. That field alone cannot establish the actual OneDrive user's identity.
- Never infer ownership from the `/personal/` URL slug, a display name, email equality, the first administrator returned, or the connected operator's identity.
- Block removal for a target if actual ownership or primary-admin identity cannot be resolved reliably, or an existing matching SharePoint principal cannot be bound reliably to the validated account. A successful complete membership read showing the secondary account is absent permits a no-op after owner checks. Missing or conflicting data must not weaken the guard.
- Read live administrator membership and remove only the exact principal bound to the validated account. Do not pass the full administrator list to a removal cmdlet.
- Recheck owner identities and membership immediately before removal. If protected identities changed since preview, skip the target and require a new operation for that target.
- Adding an existing administrator and removing an absent secondary administrator are no-ops. Owner-removal requests remain blocked even if the owner's admin membership is already missing.
- Add only a secondary administrator. Never use a primary-administrator setter or an API path that promotes the requested account when no primary administrator exists; block that target instead.

One target's owner lookup or access failure blocks that target, while other preflight-eligible targets may proceed after confirmation. This differs from failure to validate the manually entered account, which blocks the whole batch.

## API and permission validation gate

The implementation plan must begin with a bounded API validation task before enabling permission writes. Its output must identify supported PnP.PowerShell versions, exact owner-resolution and mutation APIs, and required permissions for each supported authentication mode.

The user explicitly chose to defer that task's live-fixture stage: implementation may proceed against documented-only findings and mocked tests, but the feature remains RELEASE-BLOCKED until the deferred live validation (owner-resolution proof, per-mode read/write proof, on an authorized test tenant) runs and passes. This does not relax any requirement below; it only sequences when live proof is obtained relative to writing guarded implementation code.

Current documented candidates:

- Graph exact user lookup: `GET /users/{id | userPrincipalName}`, selecting `id`, `userPrincipalName`, and `displayName`.
- Graph delegated `User.ReadBasic.All` for other users' basic profiles; `User.Read` alone only covers the signed-in user. Application user lookup requires `User.Read.All` according to the Get user documentation.
- `Get-PnPSiteCollectionAdmin` reads administrator membership on a site connection.
- `Add-PnPSiteCollectionAdmin -Owners` adds secondary administrators without replacing existing administrators. Its documented delegated path requires site collection administrator access.
- `Remove-PnPSiteCollectionAdmin -Owners` removes the specified administrator role on the connected site.

Validate an authoritative personal-drive-owner lookup, such as a Graph drive owner tied to the exact site, against a test OneDrive whose primary administrator differs from its actual user. If the lookup cannot distinguish those identities, it is not an acceptable removal guard. Do not substitute URL heuristics.

Validate delegated and app-only behavior separately. Existing `Sites.FullControl.All` consent does not establish directory-read permission or prove that a particular administrator mutation API accepts app-only access. If a mode cannot satisfy all required reads and writes, block the feature in that mode with an actionable explanation. Do not auto-grant temporary administrator access or silently switch credentials.

Add only the verified directory/ownership read permissions to setup instructions and registration flows. Existing registrations need explicit consent guidance; do not silently modify their permissions. Existing scan/revoke functionality must remain usable without the new feature permissions.

## Execution, errors, and evidence

Use the existing sequential bulk-action pattern, with per-target progress and failure isolation. Preflight is read-only and completes before the first mutation. There is no cross-site transaction and no automatic rollback.

After a write, re-fetch administrator membership and protected owner state. Report success only when the named role has the requested value and protected identities are unchanged. A cmdlet returning without error is not sufficient.

A timeout after submitting a write has an unknown result until re-read. Do not blindly retry the write. If verification cannot complete, record Unverified rather than Failed or Success. A protected-identity change observed during verification stops remaining writes and raises a prominent safety error.

Cancellation stops before the next mutation and preserves results for completed and unattempted targets. Directory identity failures stop the remaining batch. Ordinary target-local failures permit other confirmed targets to continue. Reuse existing PnP throttling/retry behavior rather than introducing a parallel job framework.

Write a dedicated pair of CSV files in the existing tenant-scoped export directory:

- `SSM_ADMIN_BEFORE_<operation-id>.csv`
- `SSM_ADMIN_AFTER_<operation-id>.csv`

Use a unique operation ID and one row per selected target. Include UTC timestamps, tenant and executing identity, action, target URL, entered and canonical UPN, requested directory object ID, actual owner and primary-admin identities, matching SharePoint principal, before/after membership, result, and error. Record blocked and no-op targets as well as attempted writes. Unknown values remain explicitly unknown, not false.

BEFORE evidence must be successfully written before mutations. Update AFTER evidence as each target completes so partial runs retain results. If evidence writing fails during execution, stop further mutations and surface the failure through the existing local log and UI. Do not log tokens or secrets. Escape terminal control sequences in externally sourced display values and use CSV export serialization rather than string concatenation.

Do not mix administrator evidence into sharing-findings CSVs or use scan cache as an authorization record. The UPN is transient configuration but remains in operation evidence and logs where needed for auditing.

## Integration boundaries

| Location | Planned responsibility |
| --- | --- |
| New `src/46-onedrive-admin.ps1` region | Directory validation, live admin/owner reads, guarded mutation, and operation result records |
| `src/30-connections.ps1` | Reuse connection helpers; make only changes needed for explicit connection scope |
| `src/65-views.ps1` | OneDrive action orchestration, preview, typed confirmation, progress, results, and key hint |
| `src/75-key-dispatch.ps1` | Dispatch `M` only in the OneDrive target view |
| `src/50-csv.ps1` | Dedicated administrator evidence export using existing export-directory conventions |
| `src/60-setup-actions.ps1` | Verified permission requirements and explicit setup/consent guidance |
| `tests/onedrive-admin.tests.ps1` and existing view/CSV tests | Assert-based checks with stubbed external calls; no new test framework |

Keep transient operation state separate from sharing findings and scan status. Do not add persistent settings, change the session-cache schema, or require a sharing scan for an admin operation. Preserve StrictMode-safe access and the thin bootstrap/numbered-region architecture.

## Acceptance checks

1. Individual and bulk add/remove use the same guarded path and preserve unselected targets, including when filters hide selected rows.
2. During initial validation, invalid syntax, nonexistent UPN, alias-only match, missing object ID, wrong tenant, ambiguous result, and directory permission failure produce zero mutations across the batch.
3. Mixed-case UPNs and surrounding whitespace resolve correctly. Supported special characters are encoded without broadening the query.
4. Confirmation displays the exact resolved identity. Cancelling input, preview, or typed confirmation produces no permission writes or SharePoint user creation.
5. Actual owner removal is blocked by object ID even if its UPN changed or a different primary administrator is configured. Primary-administrator removal is also blocked.
6. Missing, conflicting, stale, or URL-only owner data cannot authorize removal. Cache restoration cannot bypass a live check.
7. Deleted/recreated or renamed requested accounts stop remaining writes instead of targeting a replacement identity.
8. Add-existing and remove-absent return no-op. Eligible Add does not replace the primary administrator or alter unrelated administrator assignments.
9. Blocked targets are visible in preview and evidence. A mixed batch can change confirmed eligible targets without changing blocked targets.
10. Write errors, ambiguous timeouts, verification mismatches, cancellation, and evidence-write failures retain truthful partial results and apply the specified stop rules.
11. Sites/findings views and empty selection cannot invoke a mutation. Loaded but unscanned OneDrives can use the feature after live preflight.
12. BEFORE/AFTER evidence identifies the actor, requested account, protected owners, exact scope, and results without tokens or secrets.

Run `pwsh tests/run-tests.ps1` and the repository's documented PSScriptAnalyzer checks during implementation. Add mocked checks for the safety paths above using the existing assert runner. Test actual API permissions and ownership semantics in a dedicated test tenant; unit tests cannot prove those properties.

## Documentation changes at implementation

Update `CHANGELOG.md` under Unreleased and the README feature list, key map, permissions, and generated-file documentation. Add `wiki/OneDrive-Admin-Management.md` and link it from `wiki/Home.md`. Update affected authentication, requirements, and troubleshooting wiki pages in the same implementation change.

Document full-access implications, owner-protection blocks, consent requirements, partial bulk results, and the fact that removing the administrator role does not remove access granted through other mechanisms. This design-only change does not announce the feature as available or publish wiki content.

## Limitations

- Authoritative owner resolution and the authentication support matrix require test-tenant validation before mutation support can ship. Unsupported or uncertain ownership cases remain blocked.
- Exact live directory validation intentionally excludes deleted-user administrator cleanup and old aliases that no longer match the canonical UPN.
- There is no atomic transaction spanning directory lookup, ownership checks, and SharePoint writes. Immediate pre-write checks and post-write verification reduce risk but cannot prevent concurrent changes made outside the tool.
- Local evidence contains sensitive account and site identifiers and follows the existing export storage policy. It is not an encrypted or tamper-proof audit service.

## References

- [PnP Add-PnPSiteCollectionAdmin](https://pnp.github.io/powershell/cmdlets/Add-PnPSiteCollectionAdmin.html)
- [PnP Remove-PnPSiteCollectionAdmin](https://pnp.github.io/powershell/cmdlets/Remove-PnPSiteCollectionAdmin.html)
- [Microsoft Graph Get user](https://learn.microsoft.com/en-us/graph/api/user-get?view=graph-rest-1.0)
- Repository architecture and safety conventions: `CONTRIBUTING.md`.
