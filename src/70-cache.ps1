# ============================================================================
#region Session cache - serialization (pure)
# ============================================================================

function ConvertTo-SsmCacheObject {
    # Snapshot the Targets tabs into a plain object ready for ConvertTo-Json.
    param($Tabs)
    $tabsOut = @()
    foreach ($tab in @($Tabs)) {
        if ($tab['Kind'] -ne 'Targets') { continue }
        $items = @()
        foreach ($it in @($tab['Items'])) {
            $items += [ordered]@{
                Url = $it.Url; Title = $it.Title; Template = $it.Template
                Status = $it.Status; FindingCount = $it.FindingCount
                Findings = @($it.Findings)
            }
        }
        $tabsOut += [ordered]@{
            Name = $tab['Name']; Categories = @($tab['Categories']); Items = $items
        }
    }
    return [ordered]@{
        Version = $script:Version
        SavedAt = (Get-Date).ToString('o')
        Tabs    = $tabsOut
    }
}

function ConvertFrom-SsmCacheObject {
    # Load a parsed cache object into matching (by Name) Targets tabs in place.
    param($Cache, $Tabs)
    foreach ($ct in @($Cache.Tabs)) {
        $tab = @($Tabs) | Where-Object { $_['Kind'] -eq 'Targets' -and $_['Name'] -eq $ct.Name } | Select-Object -First 1
        if (-not $tab) { continue }
        $tab['Categories'] = [System.Collections.ArrayList]@($ct.Categories)
        $items = @()
        foreach ($ci in @($ct.Items)) {
            $findings = @()
            foreach ($f in @($ci.Findings)) {
                if (-not $f) { continue }
                $f | Add-Member -NotePropertyName Selected -NotePropertyValue $false -Force
                $findings += $f
            }
            $items += @{
                Url = $ci.Url; Title = $ci.Title; Template = $ci.Template
                Status = $ci.Status; FindingCount = $ci.FindingCount
                Findings = $findings; Selected = $false
            }
        }
        $tab['Items'] = @($items)
        $tab['Loaded'] = $true
    }
}

#endregion

# ============================================================================
#region Session cache - disk IO
# ============================================================================

function Save-SsmCache {
    # Persist the Targets tabs to session.json (atomic). Best-effort: never throws.
    try {
        if (-not (Test-Path -LiteralPath $script:CacheDir)) {
            New-Item -ItemType Directory -Path $script:CacheDir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $script:CacheDir 'README.txt') -Value $script:CacheWarning -Encoding UTF8
        }
        $json = ConvertTo-SsmCacheObject -Tabs $script:Tabs | ConvertTo-Json -Depth 8
        $tmp  = $script:CacheFile + '.tmp'
        Set-Content -LiteralPath $tmp -Value $json -Encoding UTF8
        Move-Item -LiteralPath $tmp -Destination $script:CacheFile -Force
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
