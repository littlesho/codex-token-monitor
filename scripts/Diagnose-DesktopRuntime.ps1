#Requires -Version 5.1
<#
.SYNOPSIS
  Read-only inventory of running Codex Desktop/CLI processes and installed runtimes.
.DESCRIPTION
  Does not start, stop, attach to or change Codex. Never reads auth files,
  conversation transcripts, network payloads or process environment variables.
  Command lines are inspected only to classify the process; never displayed.
  The output cannot verify the model the server actually served.
.EXAMPLE
  ./scripts/Diagnose-DesktopRuntime.ps1
.EXAMPLE
  ./scripts/Diagnose-DesktopRuntime.ps1 -AsJson
#>
[CmdletBinding()]
param(
    [switch]$AsJson,
    [switch]$ShowFullPaths
)
$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'This inventory supports Windows only.'
}

function Format-SafePath([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return '<unavailable>' }
    if ($ShowFullPaths) { return $Value }
    foreach ($item in @(
        @{ Base = $env:LOCALAPPDATA; Label = '%LOCALAPPDATA%' },
        @{ Base = $env:APPDATA; Label = '%APPDATA%' },
        @{ Base = $env:USERPROFILE; Label = '%USERPROFILE%' }
    )) {
        $prefix = [string]$item.Base
        if ($prefix -and $Value.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
            return $item.Label + $Value.Substring($prefix.Length)
        }
    }
    return $Value
}

function Read-Version([string]$FileName) {
    if ([string]::IsNullOrWhiteSpace($FileName)) { return '<unknown>' }
    try {
        $info = (Get-Item -LiteralPath $FileName -ErrorAction Stop).VersionInfo
        if ($info.ProductVersion) { return [string]$info.ProductVersion }
        if ($info.FileVersion) { return [string]$info.FileVersion }
    } catch {
        # Access to protected packaged binaries may be blocked.
    }
    return '<unavailable>'
}

$all = @()
try { $all = @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop) }
catch {
    throw 'Cannot inventory processes using Win32_Process. Run in a normal Windows PowerShell session.'
}
$byPid = @{}
foreach ($process in $all) { $byPid[[string]$process.ProcessId] = $process }

function Get-ParentNames($Item, $Index) {
    $names = [System.Collections.Generic.List[string]]::new()
    $seen = [System.Collections.Generic.HashSet[int]]::new()
    $cursor = $Item
    for ($i = 0; $i -lt 6; $i++) {
        $parentId = [int]$cursor.ParentProcessId
        if ($parentId -le 0 -or -not $seen.Add($parentId) -or -not $Index.ContainsKey([string]$parentId)) { break }
        $parent = $Index[[string]$parentId]
        # A reused PID is not a real parent.
        if ($parent.CreationDate -and $cursor.CreationDate -and $parent.CreationDate -gt $cursor.CreationDate) { break }
        $names.Add([string]$parent.Name)
        $cursor = $parent
    }
    return $names.ToArray()
}

$matching = @($all | Where-Object {
    $_.Name -match '^(?i:codex|codexapp|openai\.codex|codex-computer-use|codex-computer-use-swift)(?:\.exe)?$'
})
$processRows = @(
    foreach ($process in $matching) {
        $image = [string]$process.ExecutablePath
        $commandLine = [string]$process.CommandLine
        $parents = @(Get-ParentNames $process $byPid)
        $origin = if ($image -match '(?i)[\/]node_modules[\/]@openai[\/]codex') {
            'npm CLI runtime'
        } elseif ($image -match '(?i)[\/]OpenAI[\/]Codex[\/]') {
            'Desktop bundle candidate'
        } elseif ($image -match '(?i)[\/]WindowsApps[\/]') {
            'packaged app candidate'
        } else {
            'not classified'
        }
        $role = if ($commandLine -match '(?i)(?:^|\s)app-server(?:\s|$)') {
            'app-server argument'
        } elseif ($commandLine -match '(?i)--type=(renderer|gpu-process|utility)') {
            'desktop helper'
        } elseif ($process.Name -match '^(?i:codex|openai\.codex)\.exe$') {
            'Codex process (role unverified)'
        } else {
            'helper process'
        }
        [pscustomobject][ordered]@{
            PID       = [int]$process.ProcessId
            ParentPID = [int]$process.ParentProcessId
            Name      = [string]$process.Name
            Role      = $role
            Origin    = $origin
            Version   = Read-Version $image
            Image     = Format-SafePath $image
            ParentNames = @($parents)
        }
    }
)

$bundleFiles = @()
if ($env:LOCALAPPDATA) {
    $bundledRoot = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin'
    if (Test-Path -LiteralPath $bundledRoot -PathType Container) {
        $bundleFiles = @(Get-ChildItem -LiteralPath $bundledRoot -Filter 'codex.exe' -File -Recurse -ErrorAction SilentlyContinue)
    }
}
$bundles = @($bundleFiles | Sort-Object FullName -Unique | ForEach-Object {
    [pscustomobject]@{
        Image = Format-SafePath $_.FullName
        Version = Read-Version $_.FullName
    }
})
$packages = @()
try {
    $packages = @(Get-AppxPackage -Name '*Codex*' -ErrorAction SilentlyContinue |
        Select-Object Name, Version)
} catch {
    # Package metadata is optional; the process census is sufficient.
}
$cliPaths = @(Get-Command codex -All -ErrorAction SilentlyContinue |
    ForEach-Object { Format-SafePath ([string]$_.Source) })

$report = [pscustomobject][ordered]@{
    ObservedAtUtc = [DateTime]::UtcNow.ToString('o')
    Processes = @($processRows | Sort-Object PID)
    DesktopBundledExecutables = @($bundles)
    StorePackages = @($packages)
    CliLaunchers = @($cliPaths)
    ResultNote = 'Metadata inventory only. Process path/parentage cannot prove which backend owns a Desktop thread or which model was served. No Codex process was opened or modified.'
}
if ($AsJson) {
    $report | ConvertTo-Json -Depth 6
} else {
    Write-Output 'Codex Desktop runtime inventory (read-only; no requests sent)'
    Write-Output ('Observed UTC: ' + $report.ObservedAtUtc)
    Write-Output 'Running candidate processes:'
    if ($processRows.Count) {
        $processRows | Select-Object PID,ParentPID,Name,Role,Origin,Version,Image |
            Format-Table -Wrap -AutoSize | Out-String -Width 220 | Write-Output
    } else { Write-Output '  (none visible)' }
    Write-Output 'Desktop-bundled codex.exe candidates:'
    if ($bundles.Count) { $bundles | Format-Table -AutoSize | Out-String -Width 220 | Write-Output }
    else { Write-Output '  (none at the conventional Desktop bundle path)' }
    Write-Output 'Installed Codex Store packages:'
    if ($packages.Count) { $packages | Format-Table -AutoSize | Out-String | Write-Output }
    else { Write-Output '  (not visible / none)' }
    Write-Output 'CLI launchers:'
    if ($cliPaths.Count) { $cliPaths | ForEach-Object { Write-Output ('  ' + $_) } }
    else { Write-Output '  (none found)' }
    Write-Output $report.ResultNote
    Write-Output 'To share a report, omit -ShowFullPaths so local user paths stay redacted.'
}
