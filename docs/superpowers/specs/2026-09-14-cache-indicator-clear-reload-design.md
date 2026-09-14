# Cache indicator, clear+reload key, pinned help hint

Date: 2026-09-14

## Goal

Three small UX changes to the Sites / OneDrives target tabs:

1. Show when the displayed target list came from the on-disk session cache.
2. Give the operator one key that discards the list and re-enumerates the tenant.
3. Keep the `?` help hint visible in the footer regardless of terminal width.

## Design

### 1. Cache indicator

- `ConvertFrom-SsmCacheObject` sets `Tab['CachedAt']` to the cache `SavedAt`
  value (ISO string) for every Targets tab it populates.
- `Add-TargetsToTab` clears `Tab['CachedAt']` (the list now contains data
  fetched or entered in this session).
- `Add-TargetsView` appends `   from cache (saved yyyy-MM-dd HH:mm)` to the
  row-3 context line when `Tab['CachedAt']` is set.
- `New-TargetsTab` initialises `CachedAt = $null`.

### 2. Clear + reload (`C`)

- New key `C` in `Invoke-TargetsKey` for Targets tabs with items.
- Y/N confirm modal: `Discard N <noun> and their scan results, then reload
  from the tenant?`. Cancel does nothing.
- On confirm: `Tab['Items'] = @()`, `Tab['Loaded'] = $false`, `CachedAt = $null`,
  `Update-TabView`, `Save-SsmCache` (so the cache no longer holds the stale
  list), then `Invoke-TabEnumerate -Tab $Tab`.
- Hint `C reload` added to `Get-TabHints`; help modal row added.

### 3. Pinned footer hints

- `Get-FooterBar` treats the last two hints (`? help`, `Q quit`) as pinned:
  their width is reserved first, the remaining hints fill leftover width in
  order, then the pinned ones are appended. Pinned entries are always drawn;
  if even they do not fit they are truncated like today.

## Testing

- `targets.tests.ps1`: `Add-TargetsToTab` clears `CachedAt`.
- `cache.tests.ps1`: restore sets `CachedAt` from `SavedAt`.
- `views.tests.ps1`: `Get-FooterBar` with narrow width still contains `?` and `Q`.

## Docs

- `CHANGELOG.md` Unreleased; `wiki/Scanning-and-Revoking.md` keys table and
  scan-cache section; help modal text.
