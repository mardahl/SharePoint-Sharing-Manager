# Bulk Revoke — Large Site Sets and Progress Feedback — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the bulk-revoke confirmation dialog usable with any number of sites, and give the revoke run a live progress bar with cancellation, instead of freezing the terminal.

**Architecture:** Two independent fixes plus their shared plumbing. First, `Write-ModalFrame` gains an optional pinned-footer region so a scrolling body can never push the typed-confirmation input off-screen, and the site list is condensed by factoring out the common URL prefix. Second, a shared progress-callback factory feeds the existing but unused `-Progress` hook on `Invoke-Revoke`, driving the existing `Write-ProgressModal` with a determinate bar spanning every site, plus Esc-to-cancel that takes effect between findings.

**Tech Stack:** PowerShell 7.4, `Set-StrictMode -Version 2.0`, hand-rolled ANSI/VT rendering via `[Console]::Write` (no TUI library), PnP.PowerShell v3 for the SharePoint calls, and a custom assert-based test runner at `tests/run-tests.ps1`.

**Design spec:** `docs/superpowers/specs/2026-07-27-bulk-revoke-scale-and-progress-design.md`

## Global Constraints

- PowerShell 7.4 minimum (`#Requires -Version 7.4`); `Set-StrictMode -Version 2.0` is active everywhere, so referencing an undefined property or variable is a hard error — always initialise hashtable keys before reading them.
- Source files in `src/` are dot-sourced in filename order by `SharePoint-Sharing-Manager.ps1`. A function may only call functions defined in a file that sorts earlier, or in the same file. `20-modals.ps1` loads before `40-revoke.ps1`, which loads before `65-views.ps1`.
- Any change under `src/` requires regenerating `dist/SharePoint-Sharing-Manager.ps1` with `pwsh build/New-SingleFile.ps1`. This is a single step at the end of the plan, not per task.
- Tests run with `pwsh tests/run-tests.ps1`. It is not Pester — it dot-sources PnP-free source files and provides exactly two helpers, `Invoke-SsmTest -Name <string> -Block <scriptblock>` and `Assert-Equal -Expected <obj> -Actual <obj>`. There is no mocking framework and no `Should`.
- `Assert-Equal` compares via string interpolation (`"$Expected" -ne "$Actual"`), so compare scalars, not objects or arrays.
- PSScriptAnalyzer runs in CI with `PSScriptAnalyzerSettings.psd1`. Do not introduce unused parameters or unapproved verbs; PowerShell approved verbs only (`Get-`, `New-`, `Write-`, `Show-`, `Invoke-`, `Start-`, `Stop-`).
- Target release version is `1.3.2`.
- Never delete files or folders in SharePoint. This work only removes sharing links and role assignments; that invariant is already enforced by `Invoke-Revoke` and must not change.

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `src/20-modals.ps1` | All modal primitives, the frame renderer, the spinner runspace, the progress modal | Add `Get-ModalScrollWindow`, `-PinnedLines` on `Write-ModalFrame`, scroll support in `Show-TypedConfirmModal`/`Show-ListModal`/`Show-InputModal`, `New-SsmProgressCallback`, width fixes in `Write-ProgressModal` |
| `src/40-revoke.ps1` | Revoke ordering (pure) and execution (PnP-bound) | Add `Get-CommonUrlPrefix`; add progress reporting and cancellation to `Invoke-Revoke` |
| `src/65-views.ps1` | Screen composition and the tab action handlers | Condense the bulk-revoke site list; wire progress and cancel into both revoke paths; replace the inline scan callback with the factory |
| `src/00-globals.ps1` | Version string, theme, glyphs | Version bump only |
| `tests/run-tests.ps1` | Test runner | Add `20-modals` to the dot-source list |
| `tests/views.tests.ps1` | View and layout logic tests | Add `Get-ModalScrollWindow` cases |
| `tests/revoke.tests.ps1` | Revoke logic tests | Add `Get-CommonUrlPrefix` and `Invoke-Revoke` cancellation cases |
| `CHANGELOG.md` | Release notes | 1.3.2 entry |
| `dist/SharePoint-Sharing-Manager.ps1` | Generated single-file build | Regenerated |

Task order is bottom-up: pure helpers with tests first (Tasks 1–3), then the renderer changes that consume them (Tasks 4–5), then the progress plumbing (Tasks 6–8), then the peripheral modal fixes (Task 9), then release mechanics (Task 10).

---

### Task 1: Make modal source loadable by the test runner

The runner does not currently dot-source `src/20-modals.ps1`, so any function added there is invisible to tests. Fix that first — every later task's tests depend on it.

**Files:**
- Modify: `tests/run-tests.ps1:16`

**Interfaces:**
- Consumes: nothing.
- Produces: functions defined in `src/20-modals.ps1` become callable from any `tests/*.tests.ps1` file.

- [ ] **Step 1: Confirm the current test suite is green before touching anything**

Run: `pwsh tests/run-tests.ps1`
Expected: a list of `PASS` lines and a final line of the form `N passed, 0 failed`. Note the value of N — later tasks compare against it. If it is not 0 failed, stop and report; the baseline is broken and this plan assumes a green start.

- [ ] **Step 2: Add the modals file to the dot-source list**

`src/20-modals.ps1` defines functions only and has no load-time side effects, so it is safe to load in a headless test process. It must be listed before `65-views.ps1`, matching runtime load order.

In `tests/run-tests.ps1`, find this line:

```powershell
foreach ($f in @('25-config','30-connections','35-scan-engine','40-revoke','45-targets','50-csv','55-tenant-actions','65-views','70-cache','75-key-dispatch')) {
```

Replace it with:

```powershell
foreach ($f in @('20-modals','25-config','30-connections','35-scan-engine','40-revoke','45-targets','50-csv','55-tenant-actions','65-views','70-cache','75-key-dispatch')) {
```

- [ ] **Step 3: Verify the suite still passes with the new file loaded**

Run: `pwsh tests/run-tests.ps1`
Expected: the same `N passed, 0 failed` as Step 1. A failure here means `20-modals.ps1` has a load-time dependency that the runner's stubs do not satisfy — report the error rather than working around it.

- [ ] **Step 4: Commit**

```bash
git add tests/run-tests.ps1
git commit -m "test: load src/20-modals.ps1 in the test runner"
```

---

### Task 2: `Get-ModalScrollWindow` — pure scroll arithmetic

The clamp logic for a scrolling body with a pinned footer, extracted as a pure function so it can be tested without a console. `Write-ModalFrame` consumes it in Task 4.

**Files:**
- Modify: `src/20-modals.ps1` (insert immediately before `function Write-ModalFrame`, around line 56)
- Test: `tests/views.tests.ps1` (append)

**Interfaces:**
- Consumes: nothing.
- Produces: `Get-ModalScrollWindow -Total <int> -BodyH <int> -PinCount <int> -Scroll <int>` returns a hashtable with exactly three integer keys: `Start` (index of the first scrolling line to draw), `Count` (how many scrolling lines to draw), `Pin` (the clamped pin count actually applied). `Total` is the count of *all* body lines including pinned ones.

- [ ] **Step 1: Write the failing tests**

Append to `tests/views.tests.ps1`:

```powershell
Invoke-SsmTest 'Get-ModalScrollWindow: no pin, content fits, shows everything' {
    $w = Get-ModalScrollWindow -Total 5 -BodyH 10 -PinCount 0 -Scroll 0
    Assert-Equal 0 $w.Start
    Assert-Equal 5 $w.Count
    Assert-Equal 0 $w.Pin
}
Invoke-SsmTest 'Get-ModalScrollWindow: pinned lines are reserved out of the body height' {
    # 36 lines total, 5 pinned, 12 rows of box body -> 7 rows left to scroll 31 lines
    $w = Get-ModalScrollWindow -Total 36 -BodyH 12 -PinCount 5 -Scroll 0
    Assert-Equal 0 $w.Start
    Assert-Equal 7 $w.Count
    Assert-Equal 5 $w.Pin
}
Invoke-SsmTest 'Get-ModalScrollWindow: scroll advances the window start' {
    $w = Get-ModalScrollWindow -Total 36 -BodyH 12 -PinCount 5 -Scroll 3
    Assert-Equal 3 $w.Start
    Assert-Equal 7 $w.Count
}
Invoke-SsmTest 'Get-ModalScrollWindow: scroll past the end clamps to the last full window' {
    # 31 scrolling lines, 7 visible -> max start is 24
    $w = Get-ModalScrollWindow -Total 36 -BodyH 12 -PinCount 5 -Scroll 999
    Assert-Equal 24 $w.Start
    Assert-Equal 7 $w.Count
}
Invoke-SsmTest 'Get-ModalScrollWindow: negative scroll clamps to zero' {
    $w = Get-ModalScrollWindow -Total 36 -BodyH 12 -PinCount 5 -Scroll -4
    Assert-Equal 0 $w.Start
}
Invoke-SsmTest 'Get-ModalScrollWindow: pin larger than the body height keeps one scrolling row' {
    $w = Get-ModalScrollWindow -Total 20 -BodyH 4 -PinCount 9 -Scroll 0
    Assert-Equal 3 $w.Pin
    Assert-Equal 1 $w.Count
}
Invoke-SsmTest 'Get-ModalScrollWindow: pin larger than the total line count is clamped' {
    $w = Get-ModalScrollWindow -Total 3 -BodyH 10 -PinCount 8 -Scroll 0
    Assert-Equal 3 $w.Pin
    Assert-Equal 0 $w.Count
    Assert-Equal 0 $w.Start
}
Invoke-SsmTest 'Get-ModalScrollWindow: zero total is safe' {
    $w = Get-ModalScrollWindow -Total 0 -BodyH 10 -PinCount 0 -Scroll 0
    Assert-Equal 0 $w.Start
    Assert-Equal 0 $w.Count
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pwsh tests/run-tests.ps1`
Expected: eight `FAIL Get-ModalScrollWindow: ...` lines, each reporting that the term `Get-ModalScrollWindow` is not recognised, and a non-zero failed count.

- [ ] **Step 3: Write the implementation**

Insert into `src/20-modals.ps1`, immediately before `function Write-ModalFrame`:

```powershell
function Get-ModalScrollWindow {
    # Scroll arithmetic for a modal body whose last $PinCount lines are pinned
    # to the bottom and never scroll. Pure: no console access, so it is unit
    # testable. $Total counts every body line, pinned ones included.
    # Returns @{ Start; Count; Pin } - the slice of scrolling lines to draw and
    # the pin count actually applied after clamping.
    param([int]$Total, [int]$BodyH, [int]$PinCount, [int]$Scroll)

    if ($Total -lt 0)   { $Total = 0 }
    if ($BodyH -lt 1)   { $BodyH = 1 }
    if ($PinCount -lt 0) { $PinCount = 0 }

    # Two independent clamps: a caller may pin more lines than it supplied, and
    # a short terminal may leave fewer body rows than the pin asks for. At least
    # one scrolling row always survives so the body is never entirely pinned.
    $pin = [Math]::Min($PinCount, $Total)
    $pin = [Math]::Min($pin, [Math]::Max(0, $BodyH - 1))

    $scrollTotal = $Total - $pin
    $visible = [Math]::Min($BodyH - $pin, $scrollTotal)
    if ($visible -lt 0) { $visible = 0 }

    $maxStart = [Math]::Max(0, $scrollTotal - $visible)
    $start = [Math]::Max(0, [Math]::Min($Scroll, $maxStart))

    return @{ Start = $start; Count = $visible; Pin = $pin }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `pwsh tests/run-tests.ps1`
Expected: eight new `PASS Get-ModalScrollWindow: ...` lines and `N passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add src/20-modals.ps1 tests/views.tests.ps1
git commit -m "feat: add Get-ModalScrollWindow for pinned-footer modal scrolling"
```

---

### Task 3: `Get-CommonUrlPrefix` — condense the site list

Eighteen full OneDrive URLs wrap to two lines each. Factoring out the shared prefix puts each site on one line. Consumed by Task 5.

**Files:**
- Modify: `src/40-revoke.ps1` (append to the pure region, after `Group-FindingsBySite`, before the `#endregion` at line 22)
- Test: `tests/revoke.tests.ps1` (append)

**Interfaces:**
- Consumes: nothing.
- Produces: `Get-CommonUrlPrefix -Urls <string[]>` returns a `[string]`: the longest common prefix of all inputs, truncated back to and including the last `/`. Returns `''` when there are fewer than two URLs, when they share no prefix, or when the trimmed prefix is 16 characters or shorter.

- [ ] **Step 1: Write the failing tests**

Append to `tests/revoke.tests.ps1`:

```powershell
Invoke-SsmTest 'Get-CommonUrlPrefix: shared OneDrive prefix is factored out' {
    $u = @(
        'https://contoso-my.sharepoint.com/personal/ann_contoso_com',
        'https://contoso-my.sharepoint.com/personal/bob_contoso_com',
        'https://contoso-my.sharepoint.com/personal/cat_contoso_com'
    )
    Assert-Equal 'https://contoso-my.sharepoint.com/personal/' (Get-CommonUrlPrefix -Urls $u)
}
Invoke-SsmTest 'Get-CommonUrlPrefix: prefix is truncated back to a slash boundary' {
    # 'ann' and 'anna' share 'anna'/'ann' mid-segment; only the /personal/ part is usable
    $u = @(
        'https://contoso-my.sharepoint.com/personal/ann_contoso_com',
        'https://contoso-my.sharepoint.com/personal/anna_contoso_com'
    )
    Assert-Equal 'https://contoso-my.sharepoint.com/personal/' (Get-CommonUrlPrefix -Urls $u)
}
Invoke-SsmTest 'Get-CommonUrlPrefix: different hosts share nothing usable' {
    $u = @('https://alpha.example.com/sites/a', 'https://beta.example.org/sites/b')
    Assert-Equal '' (Get-CommonUrlPrefix -Urls $u)
}
Invoke-SsmTest 'Get-CommonUrlPrefix: a single URL yields no prefix' {
    Assert-Equal '' (Get-CommonUrlPrefix -Urls @('https://contoso.sharepoint.com/sites/hr'))
}
Invoke-SsmTest 'Get-CommonUrlPrefix: empty input yields no prefix' {
    Assert-Equal '' (Get-CommonUrlPrefix -Urls @())
}
Invoke-SsmTest 'Get-CommonUrlPrefix: a short shared prefix is rejected' {
    # 'https://a/' is 10 chars, at or below the 16-char floor
    $u = @('https://a/one', 'https://a/two')
    Assert-Equal '' (Get-CommonUrlPrefix -Urls $u)
}
Invoke-SsmTest 'Get-CommonUrlPrefix: identical URLs yield the parent path' {
    $u = @(
        'https://contoso.sharepoint.com/sites/finance',
        'https://contoso.sharepoint.com/sites/finance'
    )
    Assert-Equal 'https://contoso.sharepoint.com/sites/' (Get-CommonUrlPrefix -Urls $u)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pwsh tests/run-tests.ps1`
Expected: seven `FAIL Get-CommonUrlPrefix: ...` lines reporting an unrecognised term.

- [ ] **Step 3: Write the implementation**

Insert into `src/40-revoke.ps1` after `Group-FindingsBySite` and before the `#endregion` that closes the pure region:

```powershell
function Get-CommonUrlPrefix {
    # Longest common prefix of the given URLs, truncated back to and including
    # the last '/', so the remainder is always a whole path segment. Used to
    # print a shared site-collection prefix once instead of on every line.
    # Returns '' when there is nothing worth factoring out.
    param([string[]]$Urls)

    $list = @($Urls | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($list.Count -lt 2) { return '' }

    $prefix = $list[0]
    foreach ($u in $list) {
        $max = [Math]::Min($prefix.Length, $u.Length)
        $i = 0
        while ($i -lt $max -and $prefix[$i] -eq $u[$i]) { $i++ }
        $prefix = $prefix.Substring(0, $i)
        if ($prefix.Length -eq 0) { return '' }
    }

    # Trim back to a segment boundary so a partial name is never shown as shared.
    $cut = $prefix.LastIndexOf('/')
    if ($cut -lt 0) { return '' }
    $prefix = $prefix.Substring(0, $cut + 1)

    # Below this length the header costs more lines than it saves.
    if ($prefix.Length -le 16) { return '' }
    return $prefix
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `pwsh tests/run-tests.ps1`
Expected: seven new `PASS Get-CommonUrlPrefix: ...` lines and `N passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add src/40-revoke.ps1 tests/revoke.tests.ps1
git commit -m "feat: add Get-CommonUrlPrefix to condense multi-site revoke lists"
```

---

### Task 4: `Write-ModalFrame -PinnedLines`

Teach the shared frame renderer to hold a footer region out of the scroll window, and to signal when content is hidden. Purely additive — the default of `0` reproduces current behaviour for all seven existing callers.

**Files:**
- Modify: `src/20-modals.ps1:56-132` (`Write-ModalFrame`)

**Interfaces:**
- Consumes: `Get-ModalScrollWindow -Total <int> -BodyH <int> -PinCount <int> -Scroll <int>` returning `@{ Start; Count; Pin }` (Task 2).
- Produces: `Write-ModalFrame` gains `-PinnedLines <int>` (default `0`). Its returned geometry hashtable keeps the same keys — `X`, `Y`, `W`, `H`, `InnerW`, `BodyH`, `Total`, `Scrollable` — but `BodyH` and `Total` now describe the *scrolling region only*: `BodyH` is the number of visible scrolling rows and `Total` is the number of scrolling lines. With `-PinnedLines 0` both are identical to today's values.

- [ ] **Step 1: Add the parameter**

In `src/20-modals.ps1`, the `param` block of `Write-ModalFrame` currently ends:

```powershell
        [int]$FixedBodyHeight = 0, # 0 = size to content
        [int]$BodyScroll = 0
    )
```

Replace with:

```powershell
        [int]$FixedBodyHeight = 0, # 0 = size to content
        [int]$BodyScroll = 0,
        [int]$PinnedLines = 0      # last N body lines never scroll; drawn at the bottom
    )
```

- [ ] **Step 2: Add the minimum-size guard**

`Write-Screen` refuses to draw below 80x20 (`src/65-views.ps1:648`), but modals do not, so a modal paints over the "Terminal too small" message. Directly after the existing size lookup:

```powershell
    $size = Get-ConsoleSize; $W = $size[0]; $H = $size[1]
```

add:

```powershell
    # Match the floor Write-Screen enforces, so a modal cannot paint over the
    # "Terminal too small" message.
    if ($W -lt 80 -or $H -lt 20) {
        return @{ X=1; Y=1; W=0; H=0; InnerW=0; BodyH=0; Total=0; Scrollable=$false }
    }
```

- [ ] **Step 3: Replace the body-height and slicing block**

Replace the existing block that runs from `$bodyH = $BodyLines.Count` through the `$visible = ...` slicing (currently lines 74-104, ending just before `$row = $y + 1`) with the following. Note that the top-border drawing code sits between those two regions in the current file — leave it exactly where it is; only the height calculation above it and the slicing below it change.

Height calculation (replaces lines 74-79):

```powershell
    $bodyH = $BodyLines.Count
    if ($FixedBodyHeight -gt 0) { $bodyH = $FixedBodyHeight }
    $maxBodyH = $H - 8
    if ($maxBodyH -lt 3) { $maxBodyH = 3 }
    if ($bodyH -gt $maxBodyH) { $bodyH = $maxBodyH }

    # Split the body into a scrolling region and a pinned footer region. The
    # geometry returned describes the scrolling region only, so callers keep
    # using ($geo.Total - $geo.BodyH) as their maximum scroll offset.
    $win = Get-ModalScrollWindow -Total $BodyLines.Count -BodyH $bodyH -PinCount $PinnedLines -Scroll $BodyScroll
    $pinCount   = $win.Pin
    $scrollLen  = $BodyLines.Count - $pinCount
    $scrollable = $scrollLen -gt $win.Count
```

Slicing (replaces lines 100-104):

```powershell
    $visible = @()
    if ($win.Count -gt 0 -and $scrollLen -gt 0) {
        $visible = @($BodyLines[$win.Start..($win.Start + $win.Count - 1)])
    }
    $pinned = @()
    if ($pinCount -gt 0) {
        $pinned = @($BodyLines[$scrollLen..($BodyLines.Count - 1)])
    }
    $rows = @($visible) + @($pinned)
```

- [ ] **Step 4: Draw from the combined row set**

The body loop currently iterates `$bodyH` times reading from `$visible`. Replace the loop header and its bounds check so it draws `$rows` instead. Change:

```powershell
    for ($i = 0; $i -lt $bodyH; $i++) {
        $style = $t.Row; $text = ''
        if ($i -lt $visible.Count) {
            $pair = $visible[$i]
```

to:

```powershell
    for ($i = 0; $i -lt $bodyH; $i++) {
        $style = $t.Row; $text = ''
        if ($i -lt $rows.Count) {
            $pair = $rows[$i]
```

The rest of the loop body, and the footer-hint and bottom-border blocks, are unchanged.

- [ ] **Step 5: Add the scroll position indicator**

Without a visible signal that content is hidden, a truncated body looks like a complete one — the root cause of the reported defect. Replace the footer-hint content line:

```powershell
    [void]$sb.Append($t.Muted).Append((Get-PadCell $FooterHint $innerW -AlignRight)).Append($t.Reset)
```

with:

```powershell
    $hintText = $FooterHint
    if ($scrollable) {
        $first = $win.Start + 1
        $last  = $win.Start + $win.Count
        $hintText = ("{0}-{1} of {2}   {3}" -f $first, $last, $scrollLen, $FooterHint)
    }
    [void]$sb.Append($t.Muted).Append((Get-PadCell $hintText $innerW -AlignRight)).Append($t.Reset)
```

- [ ] **Step 6: Update the returned geometry**

Replace the final `return` line:

```powershell
    return @{ X=$x; Y=$y; W=$boxW; H=$boxH; InnerW=$innerW; BodyH=$bodyH; Total=$BodyLines.Count; Scrollable=$scrollable }
```

with:

```powershell
    # BodyH/Total describe the scrolling region, not the whole body, so callers
    # can keep using ($geo.Total - $geo.BodyH) as the maximum scroll offset.
    return @{ X=$x; Y=$y; W=$boxW; H=$boxH; InnerW=$innerW; BodyH=$win.Count; Total=$scrollLen; Scrollable=$scrollable }
```

- [ ] **Step 7: Verify nothing regressed**

Run: `pwsh tests/run-tests.ps1`
Expected: `N passed, 0 failed`, unchanged from Task 3. These tests do not cover rendering; this step only proves the file still parses and loads under `Set-StrictMode -Version 2.0`.

Run: `pwsh -NoProfile -Command "Invoke-ScriptAnalyzer -Path src/20-modals.ps1 -Settings PSScriptAnalyzerSettings.psd1"`
Expected: no output. Any diagnostic must be fixed before committing.

- [ ] **Step 8: Commit**

```bash
git add src/20-modals.ps1
git commit -m "feat: add -PinnedLines and a scroll position indicator to Write-ModalFrame"
```

---

### Task 5: Scrollable typed confirmation with a pinned input

The user-visible fix for the reported defect: the REVOKE field and the safety warning stay on screen regardless of how many sites are listed.

**Files:**
- Modify: `src/20-modals.ps1:181-209` (`Show-TypedConfirmModal`)
- Modify: `src/65-views.ps1:408-418` (`Invoke-BulkRevoke`, confirmation lines only)

**Interfaces:**
- Consumes: `Write-ModalFrame -PinnedLines <int> -BodyScroll <int>` returning `@{ BodyH; Total; Scrollable; ... }` (Task 4); `Get-CommonUrlPrefix -Urls <string[]>` returning `[string]` (Task 3).
- Produces: `Show-TypedConfirmModal -Title <string> -Lines <object[]> -Word <string>` keeps its signature and its `[bool]` return. Callers must now supply *only* the descriptive body; the modal continues to append the blank line, warning, prompt, and field itself.

- [ ] **Step 1: Rewrite `Show-TypedConfirmModal`**

Two things change: the trailing lines move into a pinned region, and navigation keys are handled before the branch that treats any keypress as input text. Arrow and page keys report `KeyChar` as `"\0"`, which `[char]::IsControl` treats as a control character, so they are discarded today rather than typed — but the new branches must still `continue` to keep it that way.

Replace the whole function (`src/20-modals.ps1:181-209`) with:

```powershell
function Show-TypedConfirmModal {
    # Requires the operator to type an exact word. Returns $true/$false.
    # The warning, prompt and input field are pinned to the bottom of the box,
    # so a long body (e.g. one line per site in a bulk revoke) can scroll
    # without ever pushing the field off screen.
    param([string]$Title, [object[]]$Lines, [string]$Word)
    $typed = ''
    $scroll = 0
    while ($true) {
        Write-Screen
        $body = New-Object System.Collections.ArrayList
        foreach ($ln in (ConvertTo-ModalLines -Lines $Lines -Width 64)) { [void]$body.Add($ln) }
        # These five lines are pinned; keep the count in sync with -PinnedLines.
        [void]$body.Add(@($script:T.Row, ''))
        [void]$body.Add(@($script:T.Warn, 'Files and folders are never deleted. This cannot be undone.'))
        [void]$body.Add(@($script:T.Row, ''))
        [void]$body.Add(@($script:T.CtxHi, "Type $Word and press Enter to proceed:"))
        $field = $typed + '_'
        [void]$body.Add(@($script:T.Input, ('  ' + $field)))
        $geo = Write-ModalFrame -Title $Title -BodyLines $body.ToArray() -FooterHint 'Up/Down scroll   Enter confirm   Esc cancel' -BorderStyle $script:T.BorderErr -BodyScroll $scroll -PinnedLines 5
        $k = Read-ModalKey
        if ($k.Key -eq 'Escape') { $script:UI.Dirty = $true; return $false }
        if (($k.Modifiers -band [ConsoleModifiers]::Control) -and $k.Key -eq 'C') { $script:UI.Dirty = $true; return $false }
        if ($k.Key -eq 'Enter') {
            $script:UI.Dirty = $true
            return ($typed -ceq $Word)
        }
        # Scroll keys must be consumed before the text-append branch below.
        if ($k.Key -eq 'UpArrow')   { if ($scroll -gt 0) { $scroll-- }; continue }
        if ($k.Key -eq 'DownArrow') { if ($geo.Scrollable -and $scroll -lt ($geo.Total - $geo.BodyH)) { $scroll++ }; continue }
        if ($k.Key -eq 'PageUp')    { $scroll = [Math]::Max(0, $scroll - $geo.BodyH); continue }
        if ($k.Key -eq 'PageDown')  { if ($geo.Scrollable) { $scroll = [Math]::Min([Math]::Max(0, $geo.Total - $geo.BodyH), $scroll + $geo.BodyH) }; continue }
        if ($k.Key -eq 'Home')      { $scroll = 0; continue }
        if ($k.Key -eq 'End')       { if ($geo.Scrollable) { $scroll = [Math]::Max(0, $geo.Total - $geo.BodyH) }; continue }
        if ($k.Key -eq 'Backspace') {
            if ($typed.Length -gt 0) { $typed = $typed.Substring(0, $typed.Length - 1) }
            continue
        }
        if ($k.KeyChar -and -not [char]::IsControl($k.KeyChar) -and $typed.Length -lt 32) {
            $typed += $k.KeyChar
        }
    }
}
```

- [ ] **Step 2: Remove the now-duplicated warning from both call sites**

The modal now emits the "Files and folders are never deleted" line itself, so the two callers that append it would otherwise print it twice.

In `src/65-views.ps1`, the single-site confirmation currently reads:

```powershell
    $ok = Show-TypedConfirmModal -Title 'Revoke sharing' -Word 'REVOKE' -Lines (@(
        ("Remove {0} link(s)/grant(s) on" -f $sel.Count), $target.Url, '') + $byCat + @('', 'Files and folders are never deleted. This cannot be undone.'))
```

Replace with:

```powershell
    $ok = Show-TypedConfirmModal -Title 'Revoke sharing' -Word 'REVOKE' -Lines (@(
        ("Remove {0} link(s)/grant(s) on" -f $sel.Count), $target.Url, '') + $byCat)
```

- [ ] **Step 3: Condense the bulk-revoke site list**

In `src/65-views.ps1`, replace the confirmation-building block in `Invoke-BulkRevoke` — the four lines from `$lines  = @((...))` through the `Show-TypedConfirmModal` call — with:

```powershell
    $lines = @(("Remove {0} link(s)/grant(s) across {1} site(s):" -f $sel.Count, $groups.Count), '')
    $prefix = Get-CommonUrlPrefix -Urls @($groups | ForEach-Object { $_.Name })
    if ($prefix) {
        # Print the shared site-collection prefix once so each site fits on one
        # line; full URLs wrap to two lines each at the modal's 64-char width.
        $lines += ("Under " + $prefix)
        foreach ($g in $groups) {
            $lines += ("  {0}: {1}" -f $g.Name.Substring($prefix.Length), @($g.Group).Count)
        }
    } else {
        foreach ($g in $groups) { $lines += ("  {0}: {1}" -f $g.Name, @($g.Group).Count) }
    }
    if (-not (Show-TypedConfirmModal -Title 'Bulk revoke sharing' -Word 'REVOKE' -Lines $lines)) { return }
```

- [ ] **Step 4: Verify**

Run: `pwsh tests/run-tests.ps1`
Expected: `N passed, 0 failed`, unchanged.

Run: `pwsh -NoProfile -Command "Invoke-ScriptAnalyzer -Path src/20-modals.ps1,src/65-views.ps1 -Settings PSScriptAnalyzerSettings.psd1"`
Expected: no output.

- [ ] **Step 5: Manual check**

Launch `pwsh ./SharePoint-Sharing-Manager.ps1` in an 80x20 terminal, scan enough targets to produce findings across several sites, press `G` for the aggregate view, `A` to select all, then `R`.

Expected: the confirmation box shows the shared prefix header, one line per site, a right-aligned `1-7 of 21` style counter in the footer, and the warning plus the `Type REVOKE` prompt and input field visible at the bottom. Up/Down and PageUp/PageDown scroll the site list while the field stays put. Typing `REVOKE` fills the field. Esc cancels.

- [ ] **Step 6: Commit**

```bash
git add src/20-modals.ps1 src/65-views.ps1
git commit -m "fix: keep the REVOKE input on screen when confirming across many sites"
```

---

### Task 6: `New-SsmProgressCallback` factory

One throttled, cancel-aware progress closure shared by the scan path and both revoke paths, instead of three near-identical inline copies.

**Files:**
- Modify: `src/20-modals.ps1` (append after `Write-ProgressModal`, before `Show-HelpModal`)

**Interfaces:**
- Consumes: `Write-ProgressModal -Title <string> -Done <int> -Total <int> -Label <string> -Ok <int> -Failed <int>` (existing); `Show-ConfirmModal -Title <string> -Lines <object[]> -Danger` returning `[bool]` (existing).
- Produces: `New-SsmProgressCallback -Title <string> -State <hashtable> -CancelMode <'Flag'|'Throw'>` returns a `[scriptblock]` whose signature is `param($Count, $Total = 0, $Label = '', $Ok = 0, $Failed = 0)`. The caller owns `$State` and must initialise all of `LastTick`, `Offset`, `Total`, `Cancel` before first use — `Set-StrictMode -Version 2.0` makes reading an absent key a terminating error.

- [ ] **Step 1: Write the implementation**

Insert into `src/20-modals.ps1` between the end of `Write-ProgressModal` and `function Show-HelpModal`:

```powershell
function New-SsmProgressCallback {
    # Builds the -Progress scriptblock used by the scan and revoke engines.
    # Repaints Write-ProgressModal at most every 150 ms and drains the key
    # buffer so Esc is noticed between units of work.
    #
    # $State is caller-owned and must be initialised with all four keys:
    #   @{ LastTick = 0; Offset = 0; Total = 0; Cancel = $false }
    # Offset is added to the reported count, which lets several sequential
    # runs share one continuous progress bar. Total 0 selects the
    # indeterminate marquee.
    #
    # CancelMode 'Throw'  - Esc raises OperationCanceledException immediately.
    #                       For non-destructive work that can be safely unwound
    #                       from deep inside a scan loop.
    # CancelMode 'Flag'   - Esc asks for confirmation, then sets $State.Cancel.
    #                       For destructive work: the engine finishes the item
    #                       in flight and returns normally, so its caller still
    #                       writes evidence and saves state.
    param(
        [string]$Title,
        [hashtable]$State,
        [ValidateSet('Flag','Throw')][string]$CancelMode = 'Flag'
    )
    $fnProgress = ${function:Write-ProgressModal}
    $fnConfirm  = ${function:Show-ConfirmModal}
    $st = $State
    $mode = $CancelMode
    $ttl = $Title
    return {
        param($Count, $Total = 0, $Label = '', $Ok = 0, $Failed = 0)
        while ([Console]::KeyAvailable) {
            if ([Console]::ReadKey($true).Key -eq [ConsoleKey]::Escape) {
                if ($mode -eq 'Throw') {
                    throw (New-Object System.OperationCanceledException 'Cancelled by operator.')
                }
                if (-not $st.Cancel) {
                    $stop = & $fnConfirm -Title 'Stop the revoke?' -Danger -Lines @(
                        'Stop after the current item?',
                        '',
                        'Links and grants already removed stay removed; the',
                        'evidence CSV records exactly what was processed.')
                    if ($stop) { $st.Cancel = $true }
                    $st.LastTick = 0   # force an immediate repaint over the confirm box
                }
            }
        }
        $now = [Environment]::TickCount
        if (($now - $st.LastTick) -lt 150) { return }
        $st.LastTick = $now
        & $fnProgress -Title $ttl -Done ($st.Offset + $Count) -Total $st.Total -Label $Label -Ok $Ok -Failed $Failed
    }.GetNewClosure()
}
```

- [ ] **Step 2: Show the determinate spinner**

`Write-ProgressModal` hides the background spinner whenever `Total > 0`, which leaves a determinate bar completely static between findings on a slow site. Since a revoke can spend many seconds inside one PnP call, the spinner must run in both modes.

That means both modes need the same suffix geometry, because the spinner runspace writes to one absolute cell. Standardise on a 7-character suffix whose *last* character is the spinner cell.

Widen the determinate suffix from 5 to 7 characters, with the spinner cell at the end. Replace:

```powershell
        $bar = $t.BarOn + ([string]$g.BarOn * $fill) + $t.BarOff + ([string]$g.BarOff * ($barW - $fill)) + $t.Reset + $t.Row + (' {0,3}%' -f $pct)
```

with:

```powershell
        # 7-char suffix: ' 100%' plus a space and the spinner cell, matching
        # the indeterminate layout so the spinner lands in the same column.
        $bar = $t.BarOn + ([string]$g.BarOn * $fill) + $t.BarOff + ([string]$g.BarOff * ($barW - $fill)) + $t.Reset + $t.Row + (' {0,3}%  ' -f $pct)
```

Move the indeterminate spinner glyph to the same final column. Replace:

```powershell
        $bar = $t.BarOff + ([string]$g.BarOff * $pos) + $t.BarOn + ([string]$g.BarOn * $segW) + $t.BarOff + ([string]$g.BarOff * ($span - $pos)) + $t.Reset + $t.Row + ('   {0} ' -f $spin)
```

with:

```powershell
        $bar = $t.BarOff + ([string]$g.BarOff * $pos) + $t.BarOn + ([string]$g.BarOn * $segW) + $t.BarOff + ([string]$g.BarOff * ($span - $pos)) + $t.Reset + $t.Row + ('      {0}' -f $spin)
```

Update the padding width used when drawing a `RAWBAR` row, from:

```powershell
            $visLen = $barW + 5
```

to:

```powershell
            $visLen = $barW + 7
```

Reduce `$barW` by 2 so the wider suffix still fits, changing:

```powershell
    $barW = $innerW - 7
```

to:

```powershell
    $barW = $innerW - 9
```

Finally, publish the spinner cell in both modes at the suffix's last column. Replace:

```powershell
    if ($script:Spinner) {
        if ($Total -gt 0) {
            $script:Spinner.State.X = 0
        } else {
            $script:Spinner.State.Y = $y + 3
            $script:Spinner.State.X = $x + 2 + $barW + 3
        }
    }
```

with:

```powershell
    # Show the spinner in both modes: a determinate bar can sit unchanged for
    # many seconds inside a single blocking cmdlet, and a frozen bar is
    # indistinguishable from a hung application. Both suffixes are 7 chars wide
    # with the spinner in the last one, so the cell is the same either way.
    if ($script:Spinner) {
        $script:Spinner.State.Y = $y + 3
        $script:Spinner.State.X = $x + 2 + $barW + 6
    }
```

- [ ] **Step 3: Verify**

Run: `pwsh tests/run-tests.ps1`
Expected: `N passed, 0 failed`, unchanged.

Run: `pwsh -NoProfile -Command "Invoke-ScriptAnalyzer -Path src/20-modals.ps1 -Settings PSScriptAnalyzerSettings.psd1"`
Expected: no output.

- [ ] **Step 4: Commit**

```bash
git add src/20-modals.ps1
git commit -m "feat: add New-SsmProgressCallback and show the spinner on determinate bars"
```

---

### Task 7: Progress reporting and cancellation in `Invoke-Revoke`

The engine change: report real success/failure counts, and stop between findings when asked.

**Files:**
- Modify: `src/40-revoke.ps1:28-65` (`Invoke-Revoke`)
- Test: `tests/revoke.tests.ps1` (append)

**Interfaces:**
- Consumes: a `-Progress` scriptblock matching the factory's signature (Task 6).
- Produces: `Invoke-Revoke -Findings <object[]> -Progress <scriptblock> -State <hashtable>` returns `[int]`, the number removed, exactly as before. `-State` is optional; when supplied it must have a `Cancel` key. The progress block is now invoked as `-Count <int> -Total <int> -Label <string> -Ok <int> -Failed <int>`.

- [ ] **Step 1: Write the failing tests**

The runner has no mocking framework, so the PnP cmdlets are shadowed by stub functions defined in the test file. These stubs live at script scope and take precedence over any real module command of the same name. Append to `tests/revoke.tests.ps1`:

```powershell
# Stub the PnP removal cmdlets so Invoke-Revoke can run headless. Defined at
# script scope, these shadow the real PnP.PowerShell commands.
function Remove-PnPFileSharingLink   { param($FileUrl, $Identity, [switch]$Force) }
function Remove-PnPFolderSharingLink { param($Folder, $Identity, [switch]$Force) }

Invoke-SsmTest 'Invoke-Revoke reports progress for every finding' {
    $f = @(
        [pscustomobject]@{ RemovalKind='Link'; Location='File'; Name='a'; Path='/a'; LinkId='1'; RevokeStatus='' },
        [pscustomobject]@{ RemovalKind='Link'; Location='File'; Name='b'; Path='/b'; LinkId='2'; RevokeStatus='' },
        [pscustomobject]@{ RemovalKind='Link'; Location='File'; Name='c'; Path='/c'; LinkId='3'; RevokeStatus='' }
    )
    $seen = New-Object System.Collections.ArrayList
    $cb = { param($Count, $Total = 0, $Label = '', $Ok = 0, $Failed = 0) [void]$seen.Add($Count) }.GetNewClosure()
    $removed = Invoke-Revoke -Findings $f -Progress $cb
    Assert-Equal 3 $removed
    Assert-Equal 3 $seen.Count
    Assert-Equal '1 2 3' ($seen -join ' ')
}
Invoke-SsmTest 'Invoke-Revoke passes a Total matching the finding count' {
    $f = @(
        [pscustomobject]@{ RemovalKind='Link'; Location='File'; Name='a'; Path='/a'; LinkId='1'; RevokeStatus='' },
        [pscustomobject]@{ RemovalKind='Link'; Location='File'; Name='b'; Path='/b'; LinkId='2'; RevokeStatus='' }
    )
    $totals = New-Object System.Collections.ArrayList
    $cb = { param($Count, $Total = 0, $Label = '', $Ok = 0, $Failed = 0) [void]$totals.Add($Total) }.GetNewClosure()
    [void](Invoke-Revoke -Findings $f -Progress $cb)
    Assert-Equal '2 2' ($totals -join ' ')
}
Invoke-SsmTest 'Invoke-Revoke reports a running Ok count' {
    $f = @(
        [pscustomobject]@{ RemovalKind='Link'; Location='File'; Name='a'; Path='/a'; LinkId='1'; RevokeStatus='' },
        [pscustomobject]@{ RemovalKind='Link'; Location='File'; Name='b'; Path='/b'; LinkId='2'; RevokeStatus='' },
        [pscustomobject]@{ RemovalKind='Link'; Location='File'; Name='c'; Path='/c'; LinkId='3'; RevokeStatus='' }
    )
    $oks = New-Object System.Collections.ArrayList
    $cb = { param($Count, $Total = 0, $Label = '', $Ok = 0, $Failed = 0) [void]$oks.Add($Ok) }.GetNewClosure()
    [void](Invoke-Revoke -Findings $f -Progress $cb)
    # Reported before the current item is attempted: 0 removed, then 1, then 2.
    Assert-Equal '0 1 2' ($oks -join ' ')
}
Invoke-SsmTest 'Invoke-Revoke skips a finding with an empty LinkId and continues' {
    $f = @(
        [pscustomobject]@{ RemovalKind='Link'; Location='File'; Name='a'; Path='/a'; LinkId=''; RevokeStatus='' },
        [pscustomobject]@{ RemovalKind='Link'; Location='File'; Name='b'; Path='/b'; LinkId='2'; RevokeStatus='' }
    )
    $removed = Invoke-Revoke -Findings $f
    Assert-Equal 1 $removed
    # Get-RevokeOrder sorts, and Sort-Object gives no stability guarantee, so
    # assert on the end state rather than on per-item ordering.
    Assert-Equal 'Skipped: empty LinkId' ($f | Where-Object { $_.Name -eq 'a' }).RevokeStatus
    Assert-Equal 'Removed' ($f | Where-Object { $_.Name -eq 'b' }).RevokeStatus
}
Invoke-SsmTest 'Invoke-Revoke stops after the current finding when State.Cancel is set' {
    $f = @(
        [pscustomobject]@{ RemovalKind='Link'; Location='File'; Name='a'; Path='/a'; LinkId='1'; RevokeStatus='' },
        [pscustomobject]@{ RemovalKind='Link'; Location='File'; Name='b'; Path='/b'; LinkId='2'; RevokeStatus='' },
        [pscustomobject]@{ RemovalKind='Link'; Location='File'; Name='c'; Path='/c'; LinkId='3'; RevokeStatus='' },
        [pscustomobject]@{ RemovalKind='Link'; Location='File'; Name='d'; Path='/d'; LinkId='4'; RevokeStatus='' }
    )
    $state = @{ LastTick = 0; Offset = 0; Total = 4; Cancel = $false }
    $cb = { param($Count, $Total = 0, $Label = '', $Ok = 0, $Failed = 0) if ($Count -ge 2) { $state.Cancel = $true } }.GetNewClosure()
    $removed = Invoke-Revoke -Findings $f -Progress $cb -State $state
    # The second item completes, then the loop breaks before the third.
    Assert-Equal 2 $removed
    Assert-Equal 2 @($f | Where-Object { $_.RevokeStatus -eq 'Removed' }).Count
    Assert-Equal 2 @($f | Where-Object { $_.RevokeStatus -eq '' }).Count
}
Invoke-SsmTest 'Invoke-Revoke without -State or -Progress still revokes everything' {
    $f = @(
        [pscustomobject]@{ RemovalKind='Link'; Location='File'; Name='a'; Path='/a'; LinkId='1'; RevokeStatus='' },
        [pscustomobject]@{ RemovalKind='Link'; Location='File'; Name='b'; Path='/b'; LinkId='2'; RevokeStatus='' }
    )
    Assert-Equal 2 (Invoke-Revoke -Findings $f)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pwsh tests/run-tests.ps1`
Expected: failures on the new cases. The `Total`, `Ok`, `Failed`, and cancellation tests fail because `Invoke-Revoke` currently passes only `-Count` and `-Label` and has no `-State` parameter; the last case may already pass, which is fine — it is a regression guard.

- [ ] **Step 3: Write the implementation**

Replace the header of `Invoke-Revoke` in `src/40-revoke.ps1` — the `param` line through the progress invocation — so it reads:

```powershell
function Invoke-Revoke {
    # Remove all given findings against the currently-connected site; sets
    # RevokeStatus per finding and returns the count removed.
    #
    # -State is the shared progress/cancel hashtable (see
    # New-SsmProgressCallback). When its Cancel key is set, the loop stops
    # after the finding in flight and returns normally, so the caller still
    # exports evidence and saves the cache for the work actually done.
    param($Findings, [scriptblock]$Progress, [hashtable]$State)
    $removed = 0; $failed = 0; $i = 0
    $ordered = Get-RevokeOrder -Findings $Findings
    $total = @($ordered).Count
    foreach ($f in $ordered) {
        $i++
        if ($Progress) {
            & $Progress -Count $i -Total $total -Label ("Revoking {0} / {1}: {2}" -f $i, $total, $f.Name) -Ok $removed -Failed $failed
        }
```

Then, inside the loop, change each of the two early `continue` statements so a skip is counted as a failure. Replace:

```powershell
                if ([string]::IsNullOrWhiteSpace($f.LinkId)) { $f.RevokeStatus = 'Skipped: empty LinkId'; continue }
```

with:

```powershell
                if ([string]::IsNullOrWhiteSpace($f.LinkId)) { $f.RevokeStatus = 'Skipped: empty LinkId'; $failed++; continue }
```

and replace:

```powershell
                if (-not $f.PrincipalId) { $f.RevokeStatus = 'Skipped: no PrincipalId'; continue }
```

with:

```powershell
                if (-not $f.PrincipalId) { $f.RevokeStatus = 'Skipped: no PrincipalId'; $failed++; continue }
```

In the `catch` block, increment the failure counter alongside the status. Replace:

```powershell
            } else {
                $f.RevokeStatus = "Failed: $msg"
            }
```

with:

```powershell
            } else {
                $f.RevokeStatus = "Failed: $msg"
                $failed++
            }
```

Finally, add the cancellation check as the last statement inside the `foreach` body, immediately before its closing brace and before `return $removed`:

```powershell
        if ($State -and $State.Cancel) { break }
    }
    return $removed
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `pwsh tests/run-tests.ps1`
Expected: six new `PASS Invoke-Revoke ...` lines and `N passed, 0 failed`.

- [ ] **Step 5: Check the analyzer**

Run: `pwsh -NoProfile -Command "Invoke-ScriptAnalyzer -Path src/40-revoke.ps1 -Settings PSScriptAnalyzerSettings.psd1"`
Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add src/40-revoke.ps1 tests/revoke.tests.ps1
git commit -m "feat: report progress and honour cancellation in Invoke-Revoke"
```

---

### Task 8: Wire progress into both revoke paths and the scan path

Connect the engine to the UI. This is the step that removes the freeze.

**Files:**
- Modify: `src/65-views.ps1:267-319` (`Invoke-TabScan` — replace the inline closure)
- Modify: `src/65-views.ps1:373-396` (`Invoke-FindingsRevoke` — single-site path)
- Modify: `src/65-views.ps1:408-434` (`Invoke-BulkRevoke` — bulk path)

**Interfaces:**
- Consumes: `New-SsmProgressCallback -Title <string> -State <hashtable> -CancelMode <'Flag'|'Throw'>` returning `[scriptblock]` (Task 6); `Invoke-Revoke -Findings <object[]> -Progress <scriptblock> -State <hashtable>` returning `[int]` (Task 7); `Start-LoadSpinner` / `Stop-LoadSpinner` (existing).
- Produces: no new callable surface.

- [ ] **Step 1: Replace the inline scan callback with the factory**

In `Invoke-TabScan`, replace the block from `$fnProgress = ${function:Write-ProgressModal}` through the closing `}.GetNewClosure()` (currently lines 281-292) with:

```powershell
        $state = @{ LastTick = 0; Offset = 0; Total = 0; Cancel = $false }
        $cb = New-SsmProgressCallback -Title 'Scanning' -State $state -CancelMode 'Throw'
```

Behaviour is unchanged: `Total = 0` keeps the indeterminate marquee, and `Throw` mode preserves the existing `catch [System.OperationCanceledException]` handler at what is currently line 300.

- [ ] **Step 2: Verify the scan path still behaves identically**

Run: `pwsh tests/run-tests.ps1`
Expected: `N passed, 0 failed`.

Launch `pwsh ./SharePoint-Sharing-Manager.ps1`, select one target, press `S`.
Expected: the same indeterminate marquee with a moving spinner as before, `Retrieved N so far` counting up, and Esc aborting the scan and marking the target `NotScanned`.

- [ ] **Step 3: Add progress to the single-site revoke**

In `Invoke-FindingsRevoke`, replace:

```powershell
    if (-not (Connect-SsmSite -Url $target.Url)) { return }
    $removed = Invoke-Revoke -Findings $sel
    [void](Export-FindingsCsv -Findings @($ft['Items']) -SiteUrl $target.Url -Phase 'REVOKED')
```

with:

```powershell
    if (-not (Connect-SsmSite -Url $target.Url)) { return }
    $state = @{ LastTick = 0; Offset = 0; Total = $sel.Count; Cancel = $false }
    $cb = New-SsmProgressCallback -Title 'Revoking' -State $state -CancelMode 'Flag'
    Start-LoadSpinner
    try {
        Write-ProgressModal -Title 'Revoking' -Done 0 -Total $sel.Count -Label $target.Url -Ok 0 -Failed 0
        $removed = Invoke-Revoke -Findings $sel -Progress $cb -State $state
    } finally {
        Stop-LoadSpinner
    }
    [void](Export-FindingsCsv -Findings @($ft['Items']) -SiteUrl $target.Url -Phase 'REVOKED')
```

Then replace the completion report so a cancelled run says so:

```powershell
    Show-ReportModal -Title 'Revoke complete' -Lines @(("Removed {0} of {1}. Evidence CSV written." -f $removed, $sel.Count))
```

becomes:

```powershell
    $report = @(("Removed {0} of {1}. Evidence CSV written." -f $removed, $sel.Count))
    if ($state.Cancel) { $report += 'Cancelled by operator; the remaining findings were not processed.' }
    Show-ReportModal -Title 'Revoke complete' -Lines $report
```

- [ ] **Step 4: Add progress to the bulk revoke**

In `Invoke-BulkRevoke`, replace the whole site loop and report — from `$totalRemoved = 0; $siteReport = @()` through the `Show-ReportModal` call — with:

```powershell
    $totalRemoved = 0; $siteReport = @(); $siteNo = 0
    # One continuous bar across every site: Offset carries the running total of
    # findings completed in earlier sites, so the bar never resets to zero.
    $state = @{ LastTick = 0; Offset = 0; Total = $sel.Count; Cancel = $false }
    $cb = New-SsmProgressCallback -Title 'Revoking' -State $state -CancelMode 'Flag'
    Start-LoadSpinner
    try {
        foreach ($g in $groups) {
            $siteNo++
            $siteCount = @($g.Group).Count
            Write-ProgressModal -Title ("Revoking site {0}/{1}" -f $siteNo, $groups.Count) -Done $state.Offset -Total $sel.Count -Label $g.Name -Ok $totalRemoved -Failed 0
            if (-not (Connect-SsmSite -Url $g.Name)) {
                $siteReport += ("{0}: connect failed" -f $g.Name)
                $state.Offset += $siteCount
                continue
            }
            $removed = Invoke-Revoke -Findings @($g.Group) -Progress $cb -State $state
            [void](Export-FindingsCsv -Findings @($g.Group) -SiteUrl $g.Name -Phase 'REVOKED')
            $totalRemoved += $removed
            $state.Offset += $siteCount
            $siteReport += ("{0}: removed {1} of {2}" -f $g.Name, $removed, $siteCount)
            if (Get-Command Save-SsmCache -ErrorAction SilentlyContinue) { Save-SsmCache }
            # Checked after the evidence CSV and cache save, so a cancelled run
            # still records everything it actually did.
            if ($state.Cancel) { break }
        }
    } finally {
        Stop-LoadSpinner
    }
    Update-TabTargetStatuses -Tab $Tab
    $summary = @(("Removed {0} of {1} across {2} site(s)." -f $totalRemoved, $sel.Count, $groups.Count))
    if ($state.Cancel) {
        $summary += ("Cancelled after {0} of {1} site(s); the rest were not processed." -f $siteNo, $groups.Count)
    }
    Show-ReportModal -Title 'Bulk revoke complete' -Lines ($summary + @('') + $siteReport)
```

- [ ] **Step 5: Verify**

Run: `pwsh tests/run-tests.ps1`
Expected: `N passed, 0 failed`.

Run: `pwsh -NoProfile -Command "Invoke-ScriptAnalyzer -Path src/65-views.ps1 -Settings PSScriptAnalyzerSettings.psd1"`
Expected: no output.

- [ ] **Step 6: Manual check**

Launch the app, scan several targets, press `G`, `A`, then `R`, type `REVOKE`, and press Enter.

Expected: a determinate bar appears immediately and advances continuously across all sites without resetting; the title shows `Revoking site 3/18`; the label names the item in flight; `OK:` and `Failed:` count up; the spinner keeps moving during slow calls. Pressing Esc raises a `Stop the revoke?` confirmation — `N` resumes, `Y` stops after the current item and the final report includes the `Cancelled after N of M site(s)` line.

- [ ] **Step 7: Commit**

```bash
git add src/65-views.ps1
git commit -m "fix: show live progress and allow cancelling a revoke instead of freezing"
```

---

### Task 9: Fix the remaining unbounded modals

Three more instances of the same defect class, each cheap now that the machinery exists.

**Files:**
- Modify: `src/20-modals.ps1` (`Show-ListModal`, `Show-InputModal`, `Write-ProgressModal`)

**Interfaces:**
- Consumes: `Write-ModalFrame -PinnedLines <int> -BodyScroll <int>` returning `@{ BodyH; Total; Scrollable; ... }` (Task 4).
- Produces: no signature changes. `Show-ListModal` and `Show-InputModal` keep their existing parameters and return types.

- [ ] **Step 1: Make `Show-ListModal` scroll with its cursor**

The option loop adds one body row per option with no clamp, so a long list is truncated by the `H - 8` cap and the selection cursor can move to an invisible row. Scroll must follow the cursor.

In `Show-ListModal`, replace the line:

```powershell
    $sel = [Array]::IndexOf($Options, $Default)
    if ($sel -lt 0) { $sel = 0 }
```

with:

```powershell
    $sel = [Array]::IndexOf($Options, $Default)
    if ($sel -lt 0) { $sel = 0 }
    $scroll = 0
```

Then replace the `Write-ModalFrame` call:

```powershell
        [void](Write-ModalFrame -Title $Title -BodyLines $body.ToArray() -FooterHint 'Up/Down move   Enter select   Esc cancel' -BorderStyle $script:T.Border -MinWidth 66)
```

with:

```powershell
        # Keep the cursor inside the visible window. The prompt occupies the
        # first rows of the body, so the option at index $sel sits at body row
        # ($promptRows + $sel).
        $geo = Write-ModalFrame -Title $Title -BodyLines $body.ToArray() -FooterHint 'Up/Down move   Enter select   Esc cancel' -BorderStyle $script:T.Border -MinWidth 66 -BodyScroll $scroll
        $cursorRow = $promptRows + $sel
        if ($cursorRow -lt $scroll) {
            $scroll = $cursorRow
            continue
        }
        if ($geo.BodyH -gt 0 -and $cursorRow -ge ($scroll + $geo.BodyH)) {
            $scroll = $cursorRow - $geo.BodyH + 1
            continue
        }
```

`$promptRows` must be captured where the prompt lines are added. Replace:

```powershell
        foreach ($ln in (ConvertTo-ModalLines -Lines @($Prompt) -Width 60)) { [void]$body.Add($ln) }
        [void]$body.Add(@($script:T.Row, ''))
```

with:

```powershell
        foreach ($ln in (ConvertTo-ModalLines -Lines @($Prompt) -Width 60)) { [void]$body.Add($ln) }
        [void]$body.Add(@($script:T.Row, ''))
        $promptRows = $body.Count
```

The `continue` statements re-enter the loop to redraw at the corrected offset before waiting for a key, so the cursor is never drawn out of view.

- [ ] **Step 2: Pin the input field in `Show-InputModal`**

In `Show-InputModal`, replace:

```powershell
        [void](Write-ModalFrame -Title $Title -BodyLines $body.ToArray() -FooterHint 'Enter accept   Esc cancel' -BorderStyle $script:T.Border -MinWidth 66)
```

with:

```powershell
        # Pin the blank spacer and the field so a long prompt cannot push the
        # input off the bottom of the box.
        [void](Write-ModalFrame -Title $Title -BodyLines $body.ToArray() -FooterHint 'Enter accept   Esc cancel' -BorderStyle $script:T.Border -MinWidth 66 -PinnedLines 2)
```

- [ ] **Step 3: Derive `Write-ProgressModal`'s width from the terminal**

`$innerW` is hardcoded to 60 while the box is sized as `min(66, W - 4)`, so below roughly 64 columns the bar overruns the border. Move the size lookup above the bar construction and derive the widths.

At the top of `Write-ProgressModal`, replace:

```powershell
    $t = $script:T; $g = $script:G
    $innerW = 60
    $barW = $innerW - 9
```

with:

```powershell
    $t = $script:T; $g = $script:G
    $size = Get-ConsoleSize; $W = $size[0]; $H = $size[1]
    # Match the floor Write-Screen enforces so this cannot paint over the
    # "Terminal too small" message.
    if ($W -lt 80 -or $H -lt 20) { return }
    $boxW = [Math]::Min(66, $W - 4)
    $innerW = [Math]::Max(20, $boxW - 4)
    $barW = [Math]::Max(8, $innerW - 9)
```

Then remove the now-duplicated lookup further down. Replace:

```powershell
    $size = Get-ConsoleSize; $W = $size[0]; $H = $size[1]
    $boxW = [Math]::Min(66, $W - 4); $innerBox = $boxW - 4
```

with:

```powershell
    $innerBox = $innerW
```

- [ ] **Step 4: Verify**

Run: `pwsh tests/run-tests.ps1`
Expected: `N passed, 0 failed`.

Run: `pwsh -NoProfile -Command "Invoke-ScriptAnalyzer -Path src/20-modals.ps1 -Settings PSScriptAnalyzerSettings.psd1"`
Expected: no output.

- [ ] **Step 5: Manual check**

Launch the app, go to the Setup tab, and open a setting that uses a picker. Confirm the list scrolls and the highlighted row is always visible. Resize the terminal to 80 columns and start a scan; confirm the progress bar stays inside its border.

- [ ] **Step 6: Commit**

```bash
git add src/20-modals.ps1
git commit -m "fix: scroll long list modals and size the progress bar to the terminal"
```

---

### Task 10: Release — version, changelog, single-file build

**Files:**
- Modify: `src/00-globals.ps1:5`
- Modify: `CHANGELOG.md`
- Modify: `dist/SharePoint-Sharing-Manager.ps1` (generated)

**Interfaces:**
- Consumes: everything above.
- Produces: a runnable single-file distribution at version 1.3.2.

- [ ] **Step 1: Bump the version**

In `src/00-globals.ps1`, change:

```powershell
$script:Version = '1.3.1'
```

to:

```powershell
$script:Version = '1.3.2'
```

- [ ] **Step 2: Add the changelog entry**

Insert directly below the `# Changelog` heading in `CHANGELOG.md`, above the `## [1.3.1]` section:

```markdown
## [1.3.2] - 2026-07-27

- Fix: the bulk revoke confirmation hid its `REVOKE` input field when many
  sites were selected. The dialog listed one full site URL per line, each
  wrapping to two lines, and the body was silently truncated to the terminal
  height - taking the typed-confirmation prompt and field with it, with no
  indication that anything was hidden. The site list now scrolls (Up/Down,
  PgUp/PgDn, Home/End) while the warning, prompt and input field stay pinned
  to the bottom of the box, and a `3-14 of 36` position counter appears in the
  footer whenever content is off screen. Sites that share a URL prefix now
  print that prefix once as a header, so each site fits on one line.
- Fix: revoking sharing froze the interface until the whole job finished, with
  no bar, no spinner and no way to stop. Both revoke paths now show a
  determinate progress bar that runs continuously across every affected site,
  with the item in flight, live OK/failed counts and a moving spinner during
  slow calls. Esc asks for confirmation and then stops after the current item;
  everything processed up to that point is still written to the evidence CSV
  and the session cache, and the completion report states where the run
  stopped.
- Fix: long option lists in picker modals were truncated with no way to scroll,
  which could leave the selection cursor on an invisible row.
- Fix: the progress bar overran its border on terminals narrower than about 64
  columns; its width is now derived from the terminal size. Modals also honour
  the same 80x20 minimum as the main screen instead of painting over the
  "Terminal too small" message.
```

- [ ] **Step 3: Rebuild the single-file distribution**

Run: `pwsh build/New-SingleFile.ps1`
Expected: it completes without error and `dist/SharePoint-Sharing-Manager.ps1` is modified.

Confirm the build picked up the changes:

Run: `pwsh -NoProfile -Command "Select-String -Path dist/SharePoint-Sharing-Manager.ps1 -Pattern 'New-SsmProgressCallback|Get-ModalScrollWindow|Get-CommonUrlPrefix' | Select-Object -ExpandProperty Pattern -Unique"`
Expected: the pattern matches, confirming all three new functions are inlined.

- [ ] **Step 4: Verify the built file runs**

Run: `pwsh -NoProfile -Command "\$null = [scriptblock]::Create((Get-Content dist/SharePoint-Sharing-Manager.ps1 -Raw)); 'parsed ok'"`
Expected: `parsed ok`. A parse error means the build inlined something malformed.

- [ ] **Step 5: Full verification pass**

Run: `pwsh tests/run-tests.ps1`
Expected: `N passed, 0 failed`.

Run: `pwsh -NoProfile -Command "Invoke-ScriptAnalyzer -Path src -Recurse -Settings PSScriptAnalyzerSettings.psd1"`
Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add src/00-globals.ps1 CHANGELOG.md dist/SharePoint-Sharing-Manager.ps1
git commit -m "release: 1.3.2"
```

---

## Verification Summary

After Task 10, all of the following must hold:

- `pwsh tests/run-tests.ps1` reports `0 failed`, with 21 tests added across Tasks 2, 3, and 7 (eight, seven, and six respectively).
- `Invoke-ScriptAnalyzer -Path src -Recurse -Settings PSScriptAnalyzerSettings.psd1` produces no output.
- At 80x20 with findings across 18 sites, `G` then `A` then `R` shows a confirmation whose input field is visible without scrolling, and whose site list scrolls independently.
- Confirming that revoke shows a bar that advances from 0 to the total finding count without resetting between sites.
- Esc during a revoke prompts for confirmation; answering `Y` stops after the current item and the report names the site where it stopped.
- `dist/SharePoint-Sharing-Manager.ps1` parses and contains the three new functions.
