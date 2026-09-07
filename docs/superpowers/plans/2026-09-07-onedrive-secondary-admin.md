# OneDrive Secondary Admin Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add and remove one validated secondary administrator account on selected OneDrives, individually or in bulk, without removing the actual owner's administrator role.

**Architecture:** Reuse the OneDrives target selection and existing modal/progress infrastructure. Put live directory and ownership checks plus the guarded mutation path in one new numbered source region; keep rendering and evidence serialization in their existing regions. Resolve identity before preflight, confirm the frozen batch, then revalidate and verify each sequential mutation.

**Tech Stack:** PowerShell 7.4+, PnP.PowerShell v3, Microsoft Graph/SharePoint APIs, VT/ANSI TUI, existing assert-based tests and PSScriptAnalyzer. No new runtime dependency or test framework.

## Global Constraints

- Approved spec: `docs/superpowers/specs/2026-09-07-onedrive-secondary-admin-design.md`.
- Enter one user principal name (UPN) per operation. Do not save a default account.
- Validate every manually entered UPN against the connected tenant's live directory before any permission changes.
- Never remove the actual OneDrive user's own administrator role.
- Require exact typed confirmation: `ADDADMIN` or `REMOVEADMIN`.
- Reuse the OneDrives tab and existing target selection for individual and bulk operations.
- Permit removal of any existing secondary administrator, regardless of which tool created the assignment.
- Sharing scans are not a prerequisite.
- Preserve PowerShell 7.4+, `Set-StrictMode -Version 2.0`, numbered source regions, and the thin bootstrap.
- No cached authorization, temporary privilege grants, primary-admin changes, account deletion, URL-derived owner guesses, persistent admin setting, or session-cache schema change.
- No network activity except operator-triggered SharePoint/Graph calls. No tokens or secrets in evidence or logs.
- Update user-facing docs and affected `wiki/*.md` pages in the feature change, not after release.
- Use `apply_patch` for manual edits. Preserve unrelated changes, including untracked `wiki-remote/`.
- Commit, push, publish wiki content, or change live permissions only with explicit authorization. Review checkpoints below are not permission to commit.

## Execution order and release gate

Task 1 is a blocking API validation task, not permission to test against production. Its local/documentation stage (installed cmdlet inspection, authoritative documentation review) completed 2026-09-07 without live tenant access. Its live-fixture stage (Steps 3 through 5: authorized test tenant, disposable test targets, live owner-resolution and mutation proof) was explicitly deferred by the user, not skipped or failed. Implementation (Tasks 2 through 5) may proceed now against Task 1's documented-only findings, using mocked tests only. The feature remains RELEASE-BLOCKED: it must not ship, be enabled by default, or be exercised against a live tenant until the deferred live-fixture stage runs and passes, updating `docs/superpowers/specs/2026-09-07-onedrive-admin-api-validation.md` with the result. Do not substitute guessed API behavior for that live stage.

Tasks 2 through 5 follow Task 1 sequentially. Task 6 verifies the integrated feature. Mocked tests can prove guard behavior but cannot establish live ownership semantics or authorization support; that proof remains outstanding and gates release, not implementation.

## File map

| File | Responsibility |
| --- | --- |
| `src/46-onedrive-admin.ps1` (new) | Identity validation, live state reads, pure safety classification, guarded per-target mutation |
| `tests/onedrive-admin.tests.ps1` (new) | Safety, identity, and mutation checks with local stubs |
| `tests/run-tests.ps1` | Add `46-onedrive-admin` to its explicit source list |
| `src/50-csv.ps1` | Dedicated administrator evidence serializer |
| `tests/csv.tests.ps1` | Evidence schema and write-failure checks |
| `src/65-views.ps1` | Operation orchestration, frozen selection, preview, progress, results, footer hint |
| `tests/views.tests.ps1` | Read/write ordering, cancellation, hidden selections, failures |
| `src/75-key-dispatch.ps1` | OneDrive target-only `M` dispatch |
| `src/20-modals.ps1` | Static help entry only; reuse existing modal functions |
| `src/60-setup-actions.ps1` | Verified registration scopes and consent explanations |
| `tests/setup-actions.tests.ps1` (new) | Registration argument and consent-copy regression checks |
| `src/30-connections.ps1` | Change only if Task 1 proves current helpers cannot preserve explicit connection scope |
| `CONTRIBUTING.md` | New region in code map and feature verification notes |
| `README.md`, `CHANGELOG.md`, `wiki/*.md` | Operator documentation and release notes |
| `docs/superpowers/specs/2026-09-07-onedrive-admin-api-validation.md` (new during execution) | API evidence and supported-mode decision from Task 1 |

The bootstrap and release inliner discover `src/*.ps1` automatically. The test runner does not: its source list must change. Do not add a separate build system or test-filter framework.

## Shared data contracts

Use hashtables and arrays, not new classes. All listed state keys must exist even when their values are unknown. Use `$null` for unknown membership; do not coerce it to `$false`.

```powershell
# Resolver output: one validated account in a verified tenant context.
@{ TenantId = [guid]::Empty; EnteredUpn = ''; Upn = ''; Id = [guid]::Empty; DisplayName = '' }

# Live target state. An unresolved owner or principal leaves its ID null.
@{
    TenantId = [guid]::Empty; Url = ''; SiteId = ''; IsPersonalSite = $false
    Unlocked = $false; OwnerId = $null; OwnerUpn = ''
    PrimaryAdminId = $null; PrimaryAdminUpn = ''
    AdminPresent = $null; AdminUserId = $null; AdminLogin = ''
}

# Per-target execution result. StopBatch is reserved for shared identity/evidence
# failures and detected post-write protected-identity changes.
@{ Result = ''; Error = ''; Before = $null; After = $null; StopBatch = $false }
```

The zero GUIDs above describe types only: successful runtime identities must contain nonzero, validated GUIDs. `SiteId` binds the live site to the confirmed target. `AdminUserId` is an Entra directory ID, not the site-local numeric user ID. `AdminLogin` is the exact SharePoint principal used for removal.

Preflight classifications: `Eligible`, `NoOp`, `OwnerProtected`, `PrimaryProtected`, `Blocked`, `Failed`. Execution outcomes additionally include `Success`, `Unverified`, `Cancelled`, and `NotAttempted`. Errors carry explanatory text; callers must not treat unknown state as success.

### Task 1: Prove owner resolution and permission support

**Files:** Create `docs/superpowers/specs/2026-09-07-onedrive-admin-api-validation.md`; read `src/30-connections.ps1`, `src/60-setup-actions.ps1`, and the approved design.

**Interfaces:** Produces an exact read/write call sequence for Task 2/3, supported PnP version and authentication-mode matrix, and confirmed Graph registration scopes for Task 5. No application interface changes in this task.

- [ ] **Step 1: Capture local baseline and available commands.** Run `git status --short` and `pwsh tests/run-tests.ps1`. Then inspect installed cmdlets without installing or changing credentials:

```powershell
Get-Module -ListAvailable PnP.PowerShell | Select-Object Name, Version
Get-Command Get-PnPSiteCollectionAdmin, Add-PnPSiteCollectionAdmin,
    Remove-PnPSiteCollectionAdmin, Invoke-PnPGraphMethod,
    Register-PnPEntraIDAppForInteractiveLogin, Register-PnPAzureADApp -Syntax
```

- [ ] **Step 2: Check authoritative documentation and version-specific source.** Read PnP's Add/Remove/Get site collection admin documentation and Microsoft Graph Get user, drive resource, Get drive, and site lookup documentation. Record exact endpoints, selected properties, and permission types. Documentation checked while planning states drive `owner` is optional and Get drive lists application permissions as unsupported; do not assume app-only parity. Avoid `/users/{upn}/drive` for validation because delegated lookup can provision an unprovisioned drive.

- [ ] **Step 3: Establish authorized test fixtures.** Use already provisioned disposable OneDrives with independently known owners, one distinct primary admin, and a distinct candidate admin. Obtain explicit authorization before changing any test permission or primary-admin fixture. Record fixtures using generic labels in the checked-in report, with actual IDs retained only in local test evidence. Test both a normal owner-primary match and an owner-primary mismatch.

- [ ] **Step 4: Prove read-only identity and target binding.** Resolve typed UPN using Graph user lookup and check returned canonical UPN plus object ID. Resolve target through tenant/site APIs, then a site-bound ownership endpoint; if evaluating Graph, use the already identified site's drive or existing drive ID and check `sharepointIds`/site identity. The following assertions describe required observed values after the documented calls, not an alternate owner heuristic:

```powershell
if ($resolvedUser.id -ne $knownCandidateId) { throw 'Candidate identity mismatch' }
if ($liveOwnerId -ne $knownActualOwnerId) { throw 'Actual owner mismatch' }
if ($boundSiteId -ne $knownSiteId) { throw 'Drive is not bound to target site' }
if ($knownActualOwnerId -eq $knownDifferentPrimaryId) { throw 'Invalid mismatch fixture' }
```

Run the owner check for both fixture states. A missing owner, group-valued owner, unrelated site, or unresolvable directory ID must fail closed. A primary-admin field, profile display name, or URL slug is not sufficient proof.

- [ ] **Step 5: Verify least-privilege operation support per mode.** On authorized fixtures only, read admin state, add the distinct candidate, re-read, remove that candidate, and re-read again. Prefer site-scoped `Add-PnPSiteCollectionAdmin -Owners` and `Remove-PnPSiteCollectionAdmin -Owners` with explicit `-Connection`; do not use `-PrimarySiteCollectionAdmin`. Confirm primary and actual owner stay unchanged. Record denied operations as unsupported, not as reasons for auto-elevation. Validate directory reads with delegated `User.ReadBasic.All` and application `User.Read.All` separately from SharePoint permissions.

- [ ] **Step 6: Write the gate decision.** Include test date, PowerShell/PnP versions, exact read/mutation commands, typed account-to-principal binding method, observed owner-primary mismatch behavior, read/write permissions, and each supported/unsupported authentication mode. Record how tenant identity is verified from the connection/token; never log the token. If no mode passes, stop execution and report that no safe implementation path is proven. If a supported path differs from the candidates, update this plan's API instructions before proceeding. Review checkpoint: security semantics and scope, no commit unless requested.

### Task 2: Implement exact directory validation and read-only preflight

**Files:** Create `src/46-onedrive-admin.ps1`, `tests/onedrive-admin.tests.ps1`; modify `tests/run-tests.ps1` source list.

**Interfaces:**
- `Resolve-SsmDirectoryUser -Upn <string> -TenantId <guid> -Connection <object>` returns the identity contract or throws a terminating validation error. Uses only read operations.
- `Get-SsmOneDriveAdminState -Url <string> -Identity <hashtable> -Connection <object>` returns the state contract using Task 1's proven APIs. Exceptions mean no trustworthy state.
- `Get-SsmOneDriveAdminDecision -Action <Add|Remove> -Identity <hashtable> -Snapshot <hashtable>` returns one preflight classification string. This pure function never performs network calls.

- [ ] **Step 1: Add focused failing tests and source loading.** Add `46-onedrive-admin` immediately after `45-targets` in the runner's source array. External-command stubs must be local to each `Invoke-SsmTest` block; restore any script-scope state in `finally`. Start with this directory validation test:

```powershell
Invoke-SsmTest 'Admin input rejects aliases returned as another canonical UPN' {
    function Invoke-PnPGraphMethod {
        param($Method, $Url, $Connection, $ErrorAction)
        @{ id = '22222222-2222-2222-2222-222222222222'
           userPrincipalName = 'canonical@contoso.com'; displayName = 'Admin' }
    }
    $caught = $false
    try {
        Resolve-SsmDirectoryUser -Upn 'alias@contoso.com' `
            -TenantId '11111111-1111-1111-1111-111111111111' -Connection @{} | Out-Null
    } catch { $caught = $true }
    Assert-Equal $true $caught
}
```

Also add a positive test returning `admin@contoso.com`: input ` ADMIN@contoso.com ` must return canonical UPN and the known object ID. This prevents an always-throwing resolver from satisfying only negative tests. Stub the Task 1 tenant-context read as well if it is a separate call.

- [ ] **Step 2: Run `pwsh tests/run-tests.ps1` and confirm new positive test fails because the resolver is absent.** Preserve baseline failures separately; do not claim an unrelated failure proves this regression check.

- [ ] **Step 3: Implement resolver and live-read adapter with Task 1's verified call sequence.** Reject empty/control/whitespace/list/wildcard/claims input before Graph; do not use an email alias resolver. For an exact Graph UPN key, encode the OData string key and escape its apostrophes rather than appending raw input to a URL:

```powershell
$canonicalInput = $Upn.Trim()
$key = [Uri]::EscapeDataString($canonicalInput.Replace("'", "''"))
$url = "users('$key')?`$select=id,userPrincipalName,displayName"
$user = Invoke-PnPGraphMethod -Method Get -Url $url `
    -Connection $Connection -ErrorAction Stop
```

Validate the chosen PnP version's return shape, exact ordinal-ignore-case UPN equality, nonzero GUID, and tenant context. Never infer tenant from UPN suffix: tenant users may use multiple domains. Check optional fields before access under StrictMode. A malformed response, 404, 403, ambiguous collection, or unresolved required identity throws. Do not call `EnsureUser` during this task.

- [ ] **Step 4: Add pure decision tests, then implement ordered guards.** Start with actual-owner protection even when membership is absent:

```powershell
Invoke-SsmTest 'Actual owner removal is blocked before absent-admin no-op' {
    $id = [guid]'22222222-2222-2222-2222-222222222222'
    $tenant = [guid]'11111111-1111-1111-1111-111111111111'
    $identity = @{ Id = $id; TenantId = $tenant }
    $snapshot = @{
        TenantId = $tenant; Url = 'https://contoso-my.sharepoint.com/personal/user'
        SiteId = 'known-site'; IsPersonalSite = $true; Unlocked = $true
        OwnerId = $id; OwnerUpn = 'user@contoso.com'
        PrimaryAdminId = [guid]'33333333-3333-3333-3333-333333333333'
        PrimaryAdminUpn = 'primary@contoso.com'
        AdminPresent = $false; AdminUserId = $null; AdminLogin = ''
    }
    Assert-Equal 'OwnerProtected' (Get-SsmOneDriveAdminDecision `
        -Action Remove -Identity $identity -Snapshot $snapshot)
}
```

Guard order: tenant/personal-site/unlocked checks; actual and primary owner completeness; protected identity comparison for Remove; known membership; existing matching principal binding; no-op; eligible. Require both protected identities before either kind of write so post-write verification can prove they stayed unchanged. Add never promotes a new primary. Successful complete membership read with no matching secondary admin permits Remove no-op after owner checks.

- [ ] **Step 5: Complete table-driven edge checks and rerun the suite.** Cover casing/trim, `#EXT#`, leading `$`, apostrophe encoding, invalid/empty input, mismatched UPN, malformed/missing GUID, directory denial, wrong-tenant connection, changed primary, missing actual owner, primary protected, personal-site mismatch, locked target, unresolved existing principal, add-existing, remove-absent, and both eligible actions. Assert live reads do not call any mutation cmdlet. Run `pwsh tests/run-tests.ps1`; expected new tests pass with no increase in baseline failures. Review checkpoint: all input validation and guard order.

### Task 3: Implement guarded per-target mutation and verification

**Files:** Modify `src/46-onedrive-admin.ps1`, `tests/onedrive-admin.tests.ps1`.

**Interfaces:** `Invoke-SsmOneDriveAdminChange -Action <Add|Remove> -Identity <hashtable> -Snapshot <hashtable> -Connection <object>` returns the execution result contract. Consumes Task 2 functions. The caller must already have obtained typed batch confirmation and written evidence; this function still enforces all identity and owner guards before writing.

- [ ] **Step 1: Add a failing write-order test.** Use local stubs for resolver/live reads and actual mutation cmdlets, recording events in a list. The required happy-path order is:

```powershell
Invoke-SsmTest 'Secondary removal revalidates and verifies the exact principal' {
    $events = [System.Collections.Generic.List[string]]::new()
    $written = @{ Value = $false }
    $candidate = @{
        TenantId = [guid]'11111111-1111-1111-1111-111111111111'
        Id = [guid]'22222222-2222-2222-2222-222222222222'
        Upn = 'admin@contoso.com'; EnteredUpn = 'admin@contoso.com'; DisplayName = 'Admin'
    }
    $preview = @{
        TenantId = $candidate.TenantId; Url = 'https://contoso-my.sharepoint.com/personal/user'
        SiteId = 'known-site'; IsPersonalSite = $true; Unlocked = $true
        OwnerId = [guid]'33333333-3333-3333-3333-333333333333'; OwnerUpn = 'user@contoso.com'
        PrimaryAdminId = [guid]'33333333-3333-3333-3333-333333333333'
        PrimaryAdminUpn = 'user@contoso.com'; AdminPresent = $true
        AdminUserId = $candidate.Id; AdminLogin = 'i:0#.f|membership|admin@contoso.com'
    }
    function Resolve-SsmDirectoryUser {
        param($Upn, $TenantId, $Connection)
        $events.Add('ResolveIdentity'); return $candidate.Clone()
    }
    function Get-SsmOneDriveAdminState {
        param($Url, $Identity, $Connection)
        $state = $preview.Clone()
        if ($written.Value) {
            $events.Add('ReadAfter'); $state.AdminPresent = $false
            $state.AdminUserId = $null; $state.AdminLogin = ''
        } else { $events.Add('ReadBefore') }
        return $state
    }
    function Remove-PnPSiteCollectionAdmin {
        param($Owners, $Connection, $ErrorAction)
        Assert-Equal $preview.AdminLogin $Owners
        Assert-Equal 'site-connection' $Connection
        $events.Add('Write'); $written.Value = $true
    }
    $result = Invoke-SsmOneDriveAdminChange -Action Remove -Identity $candidate `
        -Snapshot $preview -Connection 'site-connection'
    Assert-Equal 'ResolveIdentity,ReadBefore,Write,ReadAfter' ($events -join ',')
    Assert-Equal 'Success' $result.Result
    Assert-Equal $false $result.StopBatch
}
```

Run `pwsh tests/run-tests.ps1`; expect the new function/positive path to fail.

- [ ] **Step 2: Implement revalidation and immediate pre-write safety.** Re-resolve the original canonical UPN; require identical tenant, nonzero object ID, and canonical UPN. Compare freshly read `SiteId`, URL, actual owner ID, and primary admin ID with preview. Stop batch on requested identity drift; block only the target on pre-write target/owner drift. Re-run Task 2 decision on live state. For Remove, pass only `AdminLogin` bound to `Identity.Id`; Add passes the validated canonical UPN through Task 1's proven principal-binding path.

```powershell
if ($Action -eq 'Add') {
    Add-PnPSiteCollectionAdmin -Owners $Identity['Upn'] `
        -Connection $Connection -ErrorAction Stop
} else {
    Remove-PnPSiteCollectionAdmin -Owners $fresh['AdminLogin'] `
        -Connection $Connection -ErrorAction Stop
}
```

These calls are permitted only after all guards pass. Never pass `-PrimarySiteCollectionAdmin`, a wildcard, or the entire administrator list. Use the alternative mutation call only if explicitly established in Task 1 and recorded in this plan.

- [ ] **Step 3: Implement post-write reads, including exception paths.** After a submitted mutation, re-read membership and protected identity state even if the request threw. Success requires known requested membership and unchanged protected identities. Known unchanged membership after a denied write is Failed; missing verification is Unverified. Membership mismatch without a transport exception is also a verification failure, never Success. Protected-identity change returns a safety error with `StopBatch = $true`. Do not blindly resubmit a timed-out write; use the existing PnP retry behavior without another write-retry layer.

- [ ] **Step 4: Add failure and no-op checks.** Test missing owner, actual/primary owner candidate, renamed/recreated candidate, stale target, unknown membership, Add already present, Remove absent, wrong connection, denied write, timeout with verified success, timeout without readable state, and protected-owner change after write. Assert zero writes on every blocked pre-write path and verify no-op still checks owner protection. Run `pwsh tests/run-tests.ps1`. Review checkpoint: security-sensitive single mutation path and truthful outcomes.

### Task 4: Add evidence and confirmed bulk workflow

**Files:** Modify `src/50-csv.ps1`, `src/65-views.ps1`, `tests/csv.tests.ps1`, `tests/views.tests.ps1`.

**Interfaces:**
- `Export-SsmAdminCsv -Rows <object[]> -OperationId <guid> -Phase <BEFORE|AFTER>` writes UTF8BOM CSV to `$script:ExportDir`, returns its path, and throws on any failure.
- `Invoke-SsmOneDriveAdmin -Tab <hashtable>` is the sole UI entry. Consumes Tasks 2/3, existing modals, connection helpers, and progress callback. Returns no pipeline data.

- [ ] **Step 1: Write an evidence round-trip test.** Use a unique temporary directory and restore `$script:ExportDir` in `finally`; remove only files created by this test. Assert exact basename, columns, empty unknown state, escaped commas/quotes/newlines, and both phases:

```powershell
$row = [pscustomobject]@{
    OperationId = '44444444-4444-4444-4444-444444444444'
    TimestampUtc = '2026-09-07T00:00:00Z'; TenantId = '11111111-1111-1111-1111-111111111111'
    Actor = 'operator@contoso.com'; Action = 'Remove'
    TargetUrl = 'https://contoso-my.sharepoint.com/personal/user'
    EnteredUpn = 'admin@contoso.com'; ResolvedUpn = 'admin@contoso.com'
    ResolvedUserId = '22222222-2222-2222-2222-222222222222'
    OwnerUpn = 'user@contoso.com'; OwnerId = '33333333-3333-3333-3333-333333333333'
    PrimaryAdminUpn = 'user@contoso.com'; PrimaryAdminId = '33333333-3333-3333-3333-333333333333'
    AdminLogin = 'i:0#.f|membership|admin@contoso.com'; AdminBefore = $true
    AdminAfter = $null; Result = 'Unverified'; Error = "Read failed, reported `"timeout`"`nRetry read"
}
$operationId = [guid]'44444444-4444-4444-4444-444444444444'
$path = Export-SsmAdminCsv -Rows @($row) -OperationId $operationId -Phase BEFORE
Assert-Equal "SSM_ADMIN_BEFORE_$operationId.csv" ([IO.Path]::GetFileName($path))
$readBack = @(Import-Csv -LiteralPath $path)
Assert-Equal 1 $readBack.Count
Assert-Equal $row.TargetUrl $readBack[0].TargetUrl
Assert-Equal '' $readBack[0].AdminAfter
```

Also assert the Error field round-trips unchanged. Run the suite and confirm exporter test fails before implementation.

- [ ] **Step 2: Implement dedicated export without altering findings schema.** Use these fixed columns in order:

```powershell
$columns = @(
    'OperationId','TimestampUtc','TenantId','Actor','Action','TargetUrl',
    'EnteredUpn','ResolvedUpn','ResolvedUserId','OwnerUpn','OwnerId',
    'PrimaryAdminUpn','PrimaryAdminId','AdminLogin','AdminBefore','AdminAfter',
    'Result','Error'
)
$Rows | Select-Object $columns |
    Export-Csv -LiteralPath $path -NoTypeInformation -Encoding UTF8BOM -ErrorAction Stop
```

Use existing tenant-scoped export-directory creation. The filename is exactly `SSM_ADMIN_<phase>_<operation-id>.csv`. For AFTER updates, write a same-directory temporary snapshot and replace the final file only after successful serialization; preserve the prior snapshot if writing fails. Do not change BEFORE after execution starts. Unknown membership stays empty with explicit Result/Error explanation, rather than appearing as False. Apply the same temporary snapshot rule to the first write to avoid treating incomplete evidence as saved.

- [ ] **Step 3: Add orchestration tests before UI implementation.** Stub modals, connections, resolver, preflight, evidence, and Task 3 function locally. Use two selected items with only one visible to assert both are in preview and evidence; use an unselected third item to assert it is untouched. For rejection paths, this stub must never run:

```powershell
function Invoke-SsmOneDriveAdminChange {
    param($Action, $Identity, $Snapshot, $Connection)
    throw 'Unexpected permission change'
}
```

Record call order and require account validation before the preflight phase, all preflight before confirmation, confirmation before BEFORE evidence, and successful BEFORE plus initial AFTER evidence before first mutation. Failed global UPN validation must prevent preflight and all writes. A declined confirmation prevents evidence writes and mutation. A completed all-blocked/no-op preflight writes the two evidence reports without requesting destructive confirmation; export errors are reported without mutations. Run suite to see the positive orchestration test fail.

- [ ] **Step 4: Implement workflow using existing modal signatures.** Guard OneDrive target mode again inside the entry function. Freeze selected URLs from all Items, deduplicate case-insensitively, and reject empty selection. Do not filter by scan status. Obtain an explicit tenant connection via `Connect-SsmAdmin` and `Get-PnPConnection`; preserve each needed connection object before connecting elsewhere.

```powershell
$action = Show-ListModal -Title 'Manage Secondary Admin' `
    -Prompt 'Choose an operation' -Options @('Add','Remove')
if (-not $action) { return }
$upn = Show-InputModal -Title 'Secondary Admin Account' `
    -Prompt 'Enter the account UPN'
if ($null -eq $upn) { return }
# Validation and read-only preflight populate the complete preview lines.
$word = if ($action -eq 'Add') { 'ADDADMIN' } else { 'REMOVEADMIN' }
if (-not (Show-TypedConfirmModal -Title 'Confirm Admin Change' `
    -Lines $lines -Word $word)) { return }
```

Construct `$lines` using existing theme/text tuples, including account display name, UPN, object ID, tenant, full-access warning, every target URL and classification, and counts for all selected/eligible/blocked/no-op/failed targets. Use `Show-ReportModal` for result detail. External text must not inject VT commands; escape control characters at rendering/log boundaries, for example replacing C0/C1 characters with visible `\uXXXX` text. Keep full canonical values for APIs and evidence.

- [ ] **Step 5: Implement sequential progress, durable partial results, and stop rules.** Build one row per selected target; preserve blocked/no-op/error rows. Write BEFORE and initialize AFTER with `NotAttempted` rows before writes. Use `New-SsmProgressCallback -Title 'Updating OneDrive Admins' -State $state -CancelMode Flag`, bracket spinner lifetime with `try/finally`, and check cancellation before each next mutation. Do not overwrite sharing scan status or findings. After each eligible attempt, update that row from Task 3 result and persist AFTER immediately. A target-local failure continues; `StopBatch`, directory failure, or evidence failure stops further writes. Record remaining rows as Cancelled or NotAttempted with reason. Do not automatically undo completed changes.

- [ ] **Step 6: Finish error/cancellation tests and rerun suite.** Cover input/list cancellation, typed-confirm rejection, initial evidence failure, mid-batch evidence failure, zero eligible rows, one protected plus one eligible target, target-local failure continuation, identity failure stopping later targets, cancellation after first target, and Unverified outcomes. Assert actor/site/account details appear in CSV, no tokens appear, and control characters are escaped in UI/log values. Run `pwsh tests/run-tests.ps1`. Review checkpoint: end-to-end ordering and partial-run evidence.

### Task 5: Wire keys, consent guidance, and operator documentation

**Files:** Modify `src/75-key-dispatch.ps1`, `src/65-views.ps1`, `src/20-modals.ps1`, `src/60-setup-actions.ps1`, `tests/views.tests.ps1`, `README.md`, `CHANGELOG.md`, `CONTRIBUTING.md`, `wiki/Home.md`, `wiki/Authentication.md`, `wiki/Requirements.md`, `wiki/FAQ-and-Troubleshooting.md`; create `tests/setup-actions.tests.ps1` and `wiki/OneDrive-Admin-Management.md`.

**Interfaces:** `Invoke-TargetsKey` dispatches `M` to Task 4 entry only for OneDrives. `Get-TabHints` advertises the same scope. Existing `Show-HelpModal` documents the key. Registration consumes Task 1's confirmed permission matrix; runtime feature checks remain independent of registration.

- [ ] **Step 1: Add dispatch and hint tests.** Locally stub `Invoke-SsmOneDriveAdmin` to count calls, construct `ConsoleKeyInfo` for `M`, and dispatch once to a Sites target tab and once to a OneDrive target tab. Require counts zero then one. Include required tab/view keys used by current dispatcher. Assert findings routing never reaches this entry and only OneDrive target hints contain `M`.

```powershell
Invoke-SsmTest 'M dispatch is restricted to OneDrive targets' {
    $savedUi = $script:UI
    $calls = [System.Collections.Generic.List[object]]::new()
    function Invoke-SsmOneDriveAdmin { param($Tab) $calls.Add($Tab) }
    try {
        $script:UI = @{ SearchMode = $false; H = 32 }
        $tab = @{ Kind = 'Targets'; Mode = 'Targets'; OneDrive = $false
                  View = @(); Items = @(); Cursor = 0; Search = '' }
        $key = [ConsoleKeyInfo]::new([char]'m', [ConsoleKey]::M, $false, $false, $false)
        Invoke-TargetsKey -Tab $tab -K $key
        Assert-Equal 0 $calls.Count
        $tab.OneDrive = $true
        Invoke-TargetsKey -Tab $tab -K $key
        Assert-Equal 1 $calls.Count
    } finally { $script:UI = $savedUi }
}
```

Run `pwsh tests/run-tests.ps1` and confirm the positive dispatch test fails.

- [ ] **Step 2: Add the minimal key, hint, and help entries.** In `Invoke-TargetsKey` use:

```powershell
'M' {
    if ($Tab['OneDrive']) { Invoke-SsmOneDriveAdmin -Tab $Tab }
    return
}
```

Append `@('M','manage admins')` only in the OneDrive target branch of `Get-TabHints`. Add `M  manage secondary admin (OneDrives only)` to `Show-HelpModal`. Preserve existing keys, findings mode, and tuple-array conventions.

- [ ] **Step 3: Test and implement explicit permission setup.** Stub registration cmdlets to capture parameters, then update them only with Task 1's proven scopes. App-only currently passes Graph `Sites.FullControl.All`; user lookup requires adding `User.Read.All` if that mode is supported. Delegated registration currently relies on defaults: inspect those defaults for the verified PnP version and preserve existing required scopes when explicitly adding `User.ReadBasic.All` and any proven ownership-read scope. Do not reduce existing scan/revoke permissions accidentally.

```powershell
# Update the existing registration splat when Task 1 supports app-only.
$splat.GraphApplicationPermissions = @('Sites.FullControl.All', 'User.Read.All')
```

Show added scopes and why they are needed before registration. Existing registrations receive consent guidance, not automatic PATCH changes. Unsupported modes show a precise reason and do not write permissions. Test missing new consent blocks only admin management, not existing scans/revokes. Run full suite after changes.

- [ ] **Step 4: Write synchronized operator docs.** Include this core workflow in README and the new wiki page:

```text
Select one or more OneDrives, press M, choose Add or Remove, and enter one UPN.
The tool resolves the account in the tenant directory and previews every selected
target before requiring ADDADMIN or REMOVEADMIN. Removal changes only the named
secondary administrator role; other access grants remain in place.
```

Document full access, actual/primary owner blocks, unsupported or unresolved-owner cases, canonical-UPN requirement, deleted-user cleanup exclusion, hidden selected targets, no sharing-scan prerequisite, partial outcomes, BEFORE/AFTER filenames and storage sensitivity, missing-consent recovery, verified auth-mode matrix, and no automatic rollback. Add `| [[OneDrive-Admin-Management]] | Add or remove secondary administrators on selected OneDrives |` to wiki Home. Update Requirements/Authentication with the exact Task 1 permission result, not an assumed app-only promise. Add Unreleased changelog entry and `src/46-onedrive-admin.ps1` to CONTRIBUTING code map. Do not publish or touch `wiki-remote/`.

- [ ] **Step 5: Review cross-surface consistency.** Compare key dispatch, footer, static help, README, and wiki. Ensure descriptions never say all access is removed or directory validation alone makes removal safe. Review checkpoint: UI and docs match verified functionality, no unrequested version bump or release commit.

### Task 6: Verify integrated behavior and report release readiness

**Files:** No new runtime files. Modify implementation/tests/docs above only to resolve findings; append verified outcomes to Task 1's API report.

**Interfaces:** Consumes complete feature. Produces evidence that mocked behavior, parsing, lint, TUI, and authorized live API paths meet acceptance criteria; separates untested capabilities from passing checks.

- [ ] **Step 1: Run complete assert suite.** Execute `pwsh tests/run-tests.ps1`. Expected: zero failed tests. If baseline failures remain, report them explicitly and do not claim a fully passing suite.

- [ ] **Step 2: Run parsing and analyzer with failing exit status on findings.** Use each analyzer path separately because `-Path` parameter handling varies by analyzer version:

```powershell
$paths = @('./SharePoint-Sharing-Manager.ps1', './src')
$issues = @($paths | ForEach-Object {
    Invoke-ScriptAnalyzer -Path $_ -Recurse -Settings ./PSScriptAnalyzerSettings.psd1 `
        -Severity Error, Warning
})
$issues | Format-Table -AutoSize
if ($issues.Count) { exit 1 }
```

```powershell
$files = @(Get-Item ./SharePoint-Sharing-Manager.ps1) + @(Get-ChildItem ./src/*.ps1)
$parseErrors = @($files | ForEach-Object {
    $tokens = $null; $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile(
        $_.FullName, [ref]$tokens, [ref]$errors)
    $errors
})
$parseErrors | Format-List
if ($parseErrors.Count) { exit 1 }
```

Run in `pwsh -NoProfile` from repository root. Do not install new tooling without following the repository's documented dev setup.

- [ ] **Step 3: Exercise TUI at normal and narrow sizes in an authorized test configuration.** Run `pwsh -NoProfile -File ./SharePoint-Sharing-Manager.ps1`. Capture normal 120x32 and narrow 80x24 terminal views using the CONTRIBUTING tmux approach. Verify OneDrive-only hint, empty-selection message, Add/Remove picker, editable UPN, escaped hostile display text, long batch preview scrolling, pinned typed confirmation, progress cancellation, and final evidence paths. Do not script a live typed permission confirmation without explicit test authorization. Capture output for review; do not claim headless unit tests prove TUI layout.

- [ ] **Step 4: Run authorized end-to-end test matrix in each supported auth mode.** Use Task 1 disposable fixtures. Verify individual Add/Remove, bulk mixed eligible/protected targets, exact owner-protected removal, different primary admin, invalid and renamed UPN, missing directory consent, read failures, and repeated no-op operations. Verify role membership directly after changes, actual/primary owners unchanged, and CSV rows match outcomes. Simulate ambiguous timeout/evidence failure in mocks, not by damaging live data. Never attempt a raw owner-removal API call to test the guard; invoke only the guarded feature and assert no write occurs.

- [ ] **Step 5: Review diff and coverage.** Run `git diff --check`, `git diff --stat`, and `git status --short`; inspect untracked implementation files too, since ordinary diff does not show them. Compare spec acceptance checks to tests using the table below. Confirm no cache/default account changes, no new runtime dependencies, and no unrelated worktree changes. Report exact commands/results, live modes exercised, and any blocked release gate. Do not commit, tag, publish wiki, or generate a release unless requested.

## Spec coverage

| Spec requirement | Implementation and verification |
| --- | --- |
| One account, individual/bulk, selected and hidden targets | Tasks 4 and 5 |
| Exact live UPN validation, safe encoding, immutable identity | Tasks 1 and 2 |
| Actual owner distinct from primary admin; fail closed | Tasks 1 through 3 |
| Revalidate before writes; do not retarget recreated accounts | Task 3, Task 4 stop rules |
| Typed confirmation and no pre-confirm mutation/materialization | Task 4 ordering tests |
| Add/remove only secondary role; no unrelated changes | Tasks 1 and 3, Task 6 live verification |
| No-ops and owner checks before no-op | Tasks 2 and 3 |
| Verification, timeouts, partial failure, cancellation | Tasks 3 and 4 |
| Durable BEFORE/AFTER evidence, actor and sensitive values | Task 4 |
| No required scan, cache authorization, or persistent account | Tasks 4 and 6 |
| Explicit permission/consent support without scan regression | Tasks 1 and 5 |
| UI keys, hints, static help, README/changelog/wiki | Task 5 |
| StrictMode, parser, lint, unit/TUI/live checks | Task 6 |

## References

- [Approved design](../specs/2026-09-07-onedrive-secondary-admin-design.md)
- [PnP Add-PnPSiteCollectionAdmin](https://pnp.github.io/powershell/cmdlets/Add-PnPSiteCollectionAdmin.html)
- [PnP Remove-PnPSiteCollectionAdmin](https://pnp.github.io/powershell/cmdlets/Remove-PnPSiteCollectionAdmin.html)
- [Microsoft Graph Get user](https://learn.microsoft.com/en-us/graph/api/user-get?view=graph-rest-1.0)
- [Microsoft Graph drive resource](https://learn.microsoft.com/en-us/graph/api/resources/drive?view=graph-rest-1.0)
- [Microsoft Graph Get drive](https://learn.microsoft.com/en-us/graph/api/drive-get?view=graph-rest-1.0)
