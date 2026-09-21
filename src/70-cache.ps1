# ============================================================================
#region Session cache - serialization (pure)
# ============================================================================

function ConvertTo-SsmCacheObject {
    # Snapshot the Targets tabs into a plain object ready for ConvertTo-Json.
    param($Tabs)
    # List<T> throughout: `$arr +=` copies the array per append, which made a
    # single save take ~20 s at 100k targets (called after every scanned site).
    $tabsOut = [System.Collections.Generic.List[object]]::new()
    foreach ($tab in @($Tabs)) {
        if ($tab['Kind'] -ne 'Targets') { continue }
        $items = [System.Collections.Generic.List[object]]::new()
        foreach ($it in @($tab['Items'])) {
            $s = [string]$it.Status
            if ($s -eq 'Unprovisioned' -or $s -eq 'ProvisionRequested') { continue }   # Test-SsmPlaceholderTarget, inlined
            $items.Add([ordered]@{
                Url = $it.Url; Title = $it.Title; Template = $it.Template
                Status = $it.Status; FindingCount = $it.FindingCount
                Findings = @($it.Findings)
            })
        }
        $tabsOut.Add([ordered]@{
            Name = $tab['Name']; Categories = @($tab['Categories']); Items = $items.ToArray()
        })
    }
    return [ordered]@{
        Version = $script:Version
        SavedAt = (Get-Date).ToString('o')
        Tabs    = $tabsOut.ToArray()
    }
}

function ConvertFrom-SsmCacheObject {
    # Load a parsed cache object into matching (by Name) Targets tabs in place.
    param($Cache, $Tabs)
    foreach ($ct in @($Cache.Tabs)) {
        $tab = @($Tabs) | Where-Object { $_['Kind'] -eq 'Targets' -and $_['Name'] -eq $ct.Name } | Select-Object -First 1
        if (-not $tab) { continue }
        $tab['Categories'] = [System.Collections.ArrayList]@($ct.Categories)
        $items = [System.Collections.Generic.List[object]]::new()
        foreach ($ci in @($ct.Items)) {
            $findings = [System.Collections.Generic.List[object]]::new()
            foreach ($f in @($ci.Findings)) {
                if (-not $f) { continue }
                $f | Add-Member -NotePropertyName Selected -NotePropertyValue $false -Force
                $findings.Add($f)
            }
            $items.Add(@{
                Url = $ci.Url; Title = $ci.Title; Template = $ci.Template
                Status = $ci.Status; FindingCount = $ci.FindingCount
                Findings = $findings.ToArray(); Selected = $false
            })
        }
        $tab['Items'] = $items.ToArray()
        $tab['Loaded'] = $true
        $tab['CachedAt'] = [string]$Cache.SavedAt
    }
}

#endregion

# ============================================================================
#region Session cache - disk IO
# ============================================================================

function Save-SsmCache {
    # Persist the Targets tabs to session.json (atomic). Best-effort: never throws.
    # -Throttle: skip if the last save was under 10 s ago. Used inside the
    # per-target scan/revoke loops, where a save per target would otherwise
    # dominate wall time on large tenants (serialize + write ~100k items);
    # the loops always end with an unthrottled save.
    param([switch]$Throttle)
    if ($Throttle -and $script:CacheLastSave -and ((Get-Date) - $script:CacheLastSave).TotalSeconds -lt 10) { return }
    try {
        if (-not (Test-Path -LiteralPath $script:CacheDir)) {
            New-Item -ItemType Directory -Path $script:CacheDir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $script:CacheDir 'README.txt') -Value $script:CacheWarning -Encoding UTF8
        }
        $json = ConvertTo-SsmCacheObject -Tabs $script:Tabs | ConvertTo-Json -Depth 8 -Compress
        $tmp  = $script:CacheFile + '.tmp'
        Set-Content -LiteralPath $tmp -Value $json -Encoding UTF8
        Move-Item -LiteralPath $tmp -Destination $script:CacheFile -Force
        $script:CacheLastSave = Get-Date
    } catch {
        Write-SsmLog -Message ("Cache save failed: {0}" -f $_.Exception.Message) -Level WARN
    }
}

function Test-SsmCacheAvailable {
    # Return { Count, SavedAt } when a readable cache exists, else $null.
    if (-not (Test-Path -LiteralPath $script:CacheFile)) { return $null }
    try {
        $cache = Get-Content -LiteralPath $script:CacheFile -Raw | ConvertFrom-Json
        $count = 0
        foreach ($ct in @($cache.Tabs)) { $count += @($ct.Items).Count }
        return [pscustomobject]@{ Count = $count; SavedAt = [string]$cache.SavedAt }
    } catch { return $null }
}

function Restore-SsmCache {
    # Load session.json into $script:Tabs. Returns $true on success.
    if (-not (Test-Path -LiteralPath $script:CacheFile)) { return $false }
    try {
        $cache = Get-Content -LiteralPath $script:CacheFile -Raw | ConvertFrom-Json
        ConvertFrom-SsmCacheObject -Cache $cache -Tabs $script:Tabs
        if (Get-Command Update-TabView -ErrorAction SilentlyContinue) {
            foreach ($tab in @($script:Tabs)) { if ($tab['Kind'] -eq 'Targets') { Update-TabView -Tab $tab } }
        }
        Write-SsmLog -Message 'Restored scan cache from disk.' -Level OK
        return $true
    } catch {
        Write-SsmLog -Message ("Cache restore failed: {0}" -f $_.Exception.Message) -Level WARN
        return $false
    }
}

#endregion
