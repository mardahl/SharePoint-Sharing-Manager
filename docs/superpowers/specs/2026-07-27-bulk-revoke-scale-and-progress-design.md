# Bulk Revoke — Large Site Sets and Progress Feedback — Design

**Date:** 2026-07-27
**Component:** SharePoint Sharing Manager TUI
**Target version:** 1.3.2

## Problem

Two defects surface when a bulk revoke spans many sites. Both were observed
with 76 links/grants across 18 OneDrive sites at an 80x20 terminal.

**1. The confirmation input field is unreachable.**
`Invoke-BulkRevoke` (`src/65-views.ps1:414-418`) builds one body line per
affected site, unbounded, and passes them to `Show-TypedConfirmModal`. Each
site line carries a full site URL, which `Split-TextLines`
(`src/20-modals.ps1:21-26`) hard-breaks into two lines at the modal's width of
64. Eighteen sites therefore produce roughly 36 body lines.

`Write-ModalFrame` caps body height at `H - 8` (`src/20-modals.ps1:76-79`) and
supports scrolling — it accepts `-BodyScroll` and returns `Scrollable`,
`Total`, and `BodyH`. `Show-TypedConfirmModal` is the only confirm modal that
passes neither and discards the returned geometry (`:193`). The excess lines
are silently dropped from the bottom of the window. Because the "Type REVOKE"
prompt and the input field are appended last (`:189-192`), they are the first
content to disappear, and nothing in the UI indicates that content is hidden.

**2. The revoke run freezes the UI.**
`Invoke-BulkRevoke:420-430` runs the entire job synchronously on the single UI
thread: per site, a `Connect-SsmSite`, an `Invoke-Revoke` (one network
round-trip per finding), an `Export-FindingsCsv`, and a `Save-SsmCache` that
serializes every tab to JSON. The screen holds the last painted frame for the
whole run with no bar, no spinner, and no cancel.

`Invoke-Revoke` already declares a `-Progress` scriptblock parameter
(`src/40-revoke.ps1:31`) and invokes it per finding (`:36`). Neither call site
passes one — not `Invoke-BulkRevoke:425`, nor the single-site path at
`src/65-views.ps1:390`. A working progress pattern already exists in
`Invoke-TabScan` (`src/65-views.ps1:279-292`): a throttled callback that
repaints `Write-ProgressModal` and drains the key buffer for Esc, backed by the
`Start-LoadSpinner` runspace for the dead time inside a blocking cmdlet.

## Scope

- Both revoke paths: bulk (`Invoke-BulkRevoke`) and single-site
  (`Invoke-FindingsRevoke`).
- The three other modals carrying the same unbounded-body defect:
  `Show-ListModal`, `Show-InputModal`, and `Write-ProgressModal`'s hardcoded
  width.
- Not in scope: converting revoke to a background runspace, a console-rendering
  test harness, mouse or scrollbar-gutter interaction.

## Design

### 1. `Write-ModalFrame -PinnedLines <int>`

New parameter on `Write-ModalFrame` (`src/20-modals.ps1:56`), default `0`, so
every existing caller is unaffected.

When greater than zero, the last *n* entries of `-BodyLines` are excluded from
the scroll window and always drawn at the bottom of the box, immediately above
the footer hint row.

```
bodyH     = min(BodyLines.Count, H - 8)   # unchanged; total body rows in box
pinCount  = min(n, BodyLines.Count)       # cannot pin more lines than exist
pinCount  = min(pinCount, bodyH - 1)      # clamp so >=1 scrolling row survives
scrollH   = bodyH - pinCount
scrollSrc = first (BodyLines.Count - pinCount) entries, or empty when that is 0
start     = clamp(BodyScroll, 0, max(0, scrollSrc.Count - scrollH))
```

`pinCount` is clamped twice because the two failure cases differ: a caller may
pin more lines than it supplied, and a short terminal may leave fewer body rows
than the pin requests. PowerShell range operators count backwards when the
upper bound is lower than the lower bound, so the empty case is constructed
explicitly rather than by slicing.

`-PinnedLines` composes with `-FixedBodyHeight` unchanged: `FixedBodyHeight`
still overrides `bodyH` before the pin clamps run, so pinned rows come out of
the fixed allocation rather than adding to it.

The returned geometry hashtable reports the *scrolling region*, not the whole
body: `BodyH = scrollH`, `Total = scrollSrc.Count`, and
`Scrollable = scrollSrc.Count -gt scrollH`. Callers keep using the established
idiom `$scroll -lt ($geo.Total - $geo.BodyH)` (`src/20-modals.ps1:156`, `:174`,
`:284`) with no edits.

The scroll clamp is extracted into a pure helper so it can be unit-tested
without a console:

```powershell
function Get-ModalScrollWindow {
    # Returns @{ Start = <int>; Count = <int> } for a scroll region.
    param([int]$Total, [int]$BodyH, [int]$PinCount, [int]$Scroll)
}
```

When `Scrollable` is true, `Write-ModalFrame` appends a position counter to the
footer hint, right-aligned with the existing hint text, in the form
`3-14 of 36`. Absence of this signal is the direct cause of defect 1: the modal
hid content with no indication it had done so.

### 2. `Show-TypedConfirmModal` scrolling

`Show-TypedConfirmModal` (`src/20-modals.ps1:181`) gains a `$scroll` variable,
captures the geometry it currently discards at `:193`, passes
`-PinnedLines 5 -BodyScroll $scroll`, and handles Up, Down, PageUp, and
PageDown.

The five pinned lines are the safety warning and the input field:

```
(blank)
Files and folders are never deleted. This cannot be undone.
(blank)
Type REVOKE and press Enter to proceed:
  REVOK_
```

The warning is pinned along with the field. A safety statement the operator can
scroll out of view does not serve its purpose.

**Key-handling conflict.** The modal consumes every non-control keypress as
input text (`:205`). Navigation keys report `KeyChar = "\0"`, for which
`[char]::IsControl` returns true, so they are currently discarded harmlessly.
The new scroll branches must `continue` before reaching the text-append branch.
Typed input behaviour is otherwise unchanged, including the 32-character cap.

### 3. Site-list rendering

New pure function in the ordering region of `src/40-revoke.ps1`:

```powershell
function Get-CommonUrlPrefix {
    # Longest common prefix of the given URLs, truncated back to the last '/'.
    # Returns '' when fewer than two URLs share a usable prefix.
    param([string[]]$Urls)
}
```

`Invoke-BulkRevoke` (`src/65-views.ps1:414-417`) applies it when there are two
or more sites and the resulting prefix exceeds 16 characters; otherwise it
falls back to today's full-URL lines. Rendered body:

```
Remove 76 link(s)/grant(s) across 18 site(s):

Under https://<tenant>-my.sharepoint.com/personal/
  alexander.andersen_example_com: 1
  allan.breiling_example_com: 1
  amalie.from_example_com: 4
```

For the 18-site case this reduces roughly 36 wrapped lines to 21, and every
site occupies exactly one line. Combined with pinning, the input field is
reachable at any terminal height and any site count.

The single-site confirmation at `src/65-views.ps1:386` uses the same modal and
inherits the pinning fix without further change.

### 4. `New-SsmProgressCallback` factory

New function in `src/20-modals.ps1` alongside `Write-ProgressModal`. It returns
a closure suitable for any `-Progress` parameter, replacing what would
otherwise become three near-identical inline closures.

```powershell
function New-SsmProgressCallback {
    param(
        [string]$Title,
        [hashtable]$State,
        [ValidateSet('Flag','Throw')][string]$CancelMode = 'Flag'
    )
}
```

The returned scriptblock declares defaults so producers that pass fewer
arguments still bind:

```powershell
param($Count, $Total = 0, $Label = '', $Ok = 0, $Failed = 0)
```

Per invocation it drains `[Console]::KeyAvailable` and acts on Esc per
`CancelMode`; returns early when under the 150 ms repaint throttle; otherwise
calls `Write-ProgressModal` with `Done = $State.Offset + $Count` and
`Total = $State.Total`.

`$State` is a caller-owned hashtable, mutated between units of work:

```powershell
@{ LastTick = 0; Offset = 0; Total = 0; Cancel = $false }
```

`Offset` is what makes a single bar span all sites. `Invoke-Revoke` counts
1..N within its own site, so the caller adds the running total of prior sites
before each site begins.

**Cancel modes.**
`Throw` raises `OperationCanceledException` immediately, preserving the scan
path's existing behaviour exactly. `Flag` first shows a confirmation —
`Stop the revoke? Already-revoked links stay revoked. Y/N` — and sets
`$State.Cancel` only on `Y`.

**Consumers.** `Invoke-TabScan:283-292` is replaced by a factory call with
`CancelMode Throw` and `Total 0`, keeping its indeterminate marquee and
immediate abort. Both revoke paths use `CancelMode Flag`.

### 5. Revoke wiring

`Invoke-Revoke` (`src/40-revoke.ps1:28`) changes in three ways:

1. Tracks a `$failed` counter alongside `$removed` and reports real values:
   `& $Progress -Count $i -Total $ordered.Count -Label $f.Name -Ok $removed -Failed $failed`.
   The `OK:` and `Failed:` rows that `Write-ProgressModal` already renders
   (`src/20-modals.ps1:379-380`) stop being hardcoded zeros.
2. Accepts the shared `-State` hashtable and breaks out of the finding loop
   when `$State.Cancel` is set.
3. Returns as before, so no caller signature changes beyond the two new
   arguments.

`Invoke-BulkRevoke:425` and `Invoke-FindingsRevoke:390` pass `-Progress` and
`-State`. `Invoke-BulkRevoke` advances `State.Offset` by the completed count
after each site, and breaks its site loop when `State.Cancel` is set — after
that site's `Export-FindingsCsv` and `Save-SsmCache` have run.

`Start-LoadSpinner` and `Stop-LoadSpinner` bracket the whole run, in a `try`/
`finally`, so the glyph keeps moving during the dead time inside a single
`Remove-PnPFileSharingLink` call and inside `Save-SsmCache`.
`Write-ProgressModal:401-402` currently hides the spinner whenever `Total > 0`;
that suppression is lifted so the determinate bar still shows motion between
findings on a slow site.

The completion report (`src/65-views.ps1:432`) gains a
`Cancelled after N of M` line when the run was stopped early.

**Cancel granularity.** Cancellation takes effect after the current *finding*,
not the current site. Each finding is a single atomic PnP call, so there is no
partially-applied state to land in. Because the flag causes `Invoke-Revoke` to
return normally rather than throw, the per-site `Export-FindingsCsv` and
`Save-SsmCache` still run and record exactly the statuses achieved — the
evidence trail is complete either way. Finding-level granularity also makes Esc
meaningful on the single-site path, where site-level granularity would be
equivalent to ignoring the keypress.

### 6. Related modal fixes

Three latent instances of the same defect class, inexpensive once
`-PinnedLines` exists:

- **`Show-ListModal`** (`src/20-modals.ps1:238`) adds one body row per option
  (`:250`) with no clamp, so a long option list is truncated by the `H - 8` cap
  and the selection cursor can move to an invisible row. Fix: derive `$scroll`
  from `$sel` using the clamp already used by the target list
  (`src/65-views.ps1:156-158`) and pass `-BodyScroll`. The prompt lines are not
  pinned; keeping the cursor visible is what matters.
- **`Show-InputModal`** (`:211`) also passes no `-BodyScroll`. It receives
  `-PinnedLines 2` for its field, which matters only when a caller supplies a
  long prompt.
- **`Write-ProgressModal`** (`:349-350`) hardcodes `$innerW = 60` and
  `$barW = 53` while sizing its box as `min(66, W - 4)` (`:394`). Below roughly
  64 columns the bar overruns the border. Fix: move the `Get-ConsoleSize` call
  above the bar construction, derive `$innerW` from `$boxW - 4`, and floor
  `$barW` so it cannot go negative.

`Write-ModalFrame` and `Write-ProgressModal` also do not honour the 80x20
minimum-size gate that `Write-Screen` enforces (`src/65-views.ps1:648-653`), so
a modal paints over the "Terminal too small" message. Both gain an early return
when `W -lt 80 -or H -lt 20`.

## Testing

Tests run under the repository's own assert-based runner,
`tests/run-tests.ps1`, which dot-sources the PnP-free source files and executes
every `tests/*.tests.ps1` through `Invoke-SsmTest` / `Assert-Equal`. There is no
Pester dependency and no mocking framework; PnP cmdlets are shadowed by stub
functions defined in the test file.

`src/20-modals.ps1` is not currently in the runner's dot-source list. It
defines functions only, with no load-time side effects, so it is added to that
list to make `Get-ModalScrollWindow` and `Get-CommonUrlPrefix` reachable.

**Unit tests (no console required):**

- `Get-CommonUrlPrefix` in `tests/revoke.tests.ps1`: shared prefix across
  sibling URLs; no common prefix; a single URL; a common prefix that does not
  end on a `/` boundary; empty input.
- `Get-ModalScrollWindow` in `tests/views.tests.ps1`: pin count larger than the
  available height; pin count larger than the total line count; scroll value
  past the end; `PinCount = 0` reproducing current behaviour; total smaller
  than the body height.
- `Invoke-Revoke` cancellation in `tests/revoke.tests.ps1`: with the PnP removal
  cmdlets shadowed by no-op stub functions, setting `State.Cancel` from inside
  the progress callback stops the loop, and the returned count reflects only
  completed items.

**Manual verification:** modal rendering and the modal key loops write directly
to the console through `[Console]::Write` with no existing harness. Verified by
hand against an 18-site bulk revoke at 80x20 and at 120x30, plus a terminal
resize during the confirmation dialog.

## Build and release

- Editing `src/*.ps1` requires regenerating `dist/SharePoint-Sharing-Manager.ps1`
  via `build/New-SingleFile.ps1`, which inlines every source file between the
  `# ==== BEGIN SRC LOAD ====` markers.
- PSScriptAnalyzer runs in CI against `PSScriptAnalyzerSettings.psd1`.
- Bump `$script:Version` in `src/00-globals.ps1` to 1.3.2 and add a CHANGELOG
  entry.

**Files changed:** `src/20-modals.ps1`, `src/40-revoke.ps1`,
`src/65-views.ps1`, `src/00-globals.ps1`, `tests/run-tests.ps1`,
`tests/revoke.tests.ps1`, `tests/views.tests.ps1`, `CHANGELOG.md`,
`dist/SharePoint-Sharing-Manager.ps1`.

## Known issues and limitations

- Revoke remains synchronous on the UI thread. Between progress callbacks — for
  example inside one long `Invoke-PnPQuery` — the foreground is still blocked;
  the background spinner runspace is the only moving indicator during those
  gaps. Moving revoke to a worker runspace is a larger change and is not
  attempted here.
- The progress bar shows no time estimate. Per-item latency varies by roughly
  an order of magnitude between a sharing-link removal and a
  `RoleAssignments` round-trip, so an estimate would be misleading.
- Modal rendering has no automated test coverage. Building a console harness is
  a larger project than this fix; two rendering defects of this class is not yet
  sufficient evidence to justify it.
- Terminal resize during a modal still leaves artifacts. Modal loops call
  `Write-Screen`, which re-reads the size, but never clear the screen, and the
  main loop's resize poll (`SharePoint-Sharing-Manager.ps1:103-110`) does not
  run while a modal is open. Unchanged by this work.
- `Get-CommonUrlPrefix` collapses the prefix only when two or more sites share
  more than 16 characters. Mixed-tenant or mixed-site-collection selections
  fall back to full URLs and therefore to two lines per site; pinning and
  scrolling still keep the input field reachable.
