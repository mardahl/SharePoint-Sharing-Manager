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
