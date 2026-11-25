@echo off
setlocal EnableExtensions DisableDelayedExpansion
title GitHub Script Launcher

set "LAUNCHER_WORK=%TEMP%\GitHub-Script-Launcher"
rem ____________________________settings_________________________________________________
rem Set to 0 to skip the clear-cache prompt, keep the cache, and show its location.
set "SHOW_CACHE_CLEAR_PROMPT=1"
rem GitHub repository link and branch to cache:
set "GITHUB_REPO_URL=https://github.com/xxPRABHATxx/test_pbt_script_ol_pul"
set "GITHUB_BRANCH=uncompressed"
rem _____________________________________________________________________________________
if not exist "%LAUNCHER_WORK%\" mkdir "%LAUNCHER_WORK%" >nul 2>&1
if not exist "%LAUNCHER_WORK%\" (
    echo Could not create the working folder:
    echo "%LAUNCHER_WORK%"
    pause
    exit /b 1
)

set "LAUNCHER_PS=%TEMP%\GitHubScriptLauncher_%RANDOM%_%RANDOM%.ps1"
set "LAUNCHER_MARKER="
for /f "tokens=1 delims=:" %%N in ('findstr /n /l /c:"POWERSHELL_SECTION_BEGIN_91A7" "%~f0"') do set "LAUNCHER_MARKER=%%N"
if not defined LAUNCHER_MARKER (
    echo Launcher error: embedded PowerShell section not found.
    pause
    exit /b 1
)
more +%LAUNCHER_MARKER% "%~f0" > "%LAUNCHER_PS%"
if errorlevel 1 (
    echo Launcher error: could not prepare its menu.
    del /q "%LAUNCHER_PS%" >nul 2>&1
    pause
    exit /b 1
)

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%LAUNCHER_PS%" -WorkingFolder "%LAUNCHER_WORK%"
set "LAUNCHER_RESULT=%ERRORLEVEL%"
del /f /q "%LAUNCHER_PS%" >nul 2>&1
exit /b %LAUNCHER_RESULT%
#POWERSHELL_SECTION_BEGIN_91A7
param([Parameter(Mandatory=$true)][string]$WorkingFolder)
$ErrorActionPreference = 'Stop'
$repoUrlText = $env:GITHUB_REPO_URL
$branch = $env:GITHUB_BRANCH
if ([string]::IsNullOrWhiteSpace($repoUrlText)) { throw 'Set GITHUB_REPO_URL near the top of this CMD file.' }
if ([string]::IsNullOrWhiteSpace($branch)) { throw 'Set GITHUB_BRANCH near the top of this CMD file.' }
$repoUri = [Uri]$repoUrlText
if ($repoUri.Host -ine 'github.com') { throw 'GITHUB_REPO_URL must be a github.com repository link.' }
$repoParts = @($repoUri.AbsolutePath.Trim('/').Split('/'))
if ($repoParts.Count -lt 2) { throw 'GITHUB_REPO_URL must include an owner and repository name.' }
$owner = $repoParts[0]
$repo = $repoParts[1] -replace '\.git$', ''
$launcherNames = @('_online_script1.cmd', 'GitHub-Script-Launcher.cmd')
$hashProvider = [Security.Cryptography.SHA256]::Create()
try { $cacheKey = [BitConverter]::ToString($hashProvider.ComputeHash([Text.Encoding]::UTF8.GetBytes("$repoUrlText|$branch"))).Replace('-', '').Substring(0, 16) }
finally { $hashProvider.Dispose() }
$cacheRoot = Join-Path $WorkingFolder "repository-cache-$cacheKey"
$cacheMarker = Join-Path $cacheRoot '.launcher-cache-ready'
$archivePath = Join-Path $WorkingFolder "repository-cache-$cacheKey.download.zip"

function Initialize-RepositoryCache {
    if (Test-Path -LiteralPath $cacheMarker -PathType Leaf) {
        $existingRootItem = Get-ChildItem -LiteralPath $cacheRoot -Directory | Select-Object -First 1
        if ($existingRootItem) {
            Write-Host "Using saved repository cache: $cacheRoot"
            return $existingRootItem.FullName
        }
    }

    Write-Host 'No complete repository cache was found. Downloading the repository once...'
    Remove-Item -LiteralPath $cacheRoot -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $cacheRoot -Force | Out-Null
    try {
        $encodedBranch = ($branch -split '/' | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/'
        $archiveUrl = "https://codeload.github.com/$owner/$repo/zip/refs/heads/$encodedBranch"
        Invoke-WebRequest -Uri $archiveUrl -OutFile $archivePath -Headers @{ 'User-Agent' = 'GitHub-Script-Launcher' } -TimeoutSec 180 -UseBasicParsing
        if ((Get-Item -LiteralPath $archivePath).Length -lt 1000) { throw 'The GitHub repository archive is unexpectedly small.' }
        Expand-Archive -LiteralPath $archivePath -DestinationPath $cacheRoot -Force
        $repoRootItem = Get-ChildItem -LiteralPath $cacheRoot -Directory | Select-Object -First 1
        if (-not $repoRootItem) { throw 'Could not find the extracted repository folder.' }
        $repoRoot = $repoRootItem.FullName

        # Normalize batch line endings once while preserving the original encoding bytes.
        Get-ChildItem -LiteralPath $repoRoot -Recurse -File | Where-Object { $_.Extension -match '(?i)^\.(cmd|bat)$' } | ForEach-Object {
            $sourceBytes = [IO.File]::ReadAllBytes($_.FullName)
            $normalizedStream = New-Object IO.MemoryStream
            for ($byteIndex = 0; $byteIndex -lt $sourceBytes.Length; $byteIndex++) {
                if ($sourceBytes[$byteIndex] -eq 10 -and ($byteIndex -eq 0 -or $sourceBytes[$byteIndex - 1] -ne 13)) {
                    $normalizedStream.WriteByte([byte]13)
                }
                $normalizedStream.WriteByte($sourceBytes[$byteIndex])
            }
            [IO.File]::WriteAllBytes($_.FullName, $normalizedStream.ToArray())
            $normalizedStream.Dispose()
        }
        Set-Content -LiteralPath $cacheMarker -Value 'ready' -Encoding ASCII
        return $repoRoot
    }
    catch {
        Remove-Item -LiteralPath $cacheRoot -Recurse -Force -ErrorAction SilentlyContinue
        throw
    }
    finally {
        Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue
    }
}

function Get-CachedScripts([string]$Root) {
    $paths = @(Get-ChildItem -LiteralPath $Root -Recurse -File | Where-Object {
        $_.Extension -match '(?i)^\.(cmd|bat)$' -and
        [IO.Path]::GetFileName($_.FullName) -notin $launcherNames
    } | ForEach-Object {
        $_.FullName.Substring($Root.Length).TrimStart('\').Replace('\', '/')
    } | Where-Object {
        $_ -match '(?i)(^[^/]+\.(cmd|bat)$|.+/(run|main)[^/]*\.(cmd|bat)$)'
    } | Sort-Object -Unique)
    return $paths
}

function Get-Children([string[]]$Paths, [string]$Prefix) {
    $folders = @{}
    $files = @()
    foreach ($path in $Paths) {
        if (-not $path.StartsWith($Prefix, [StringComparison]::OrdinalIgnoreCase)) { continue }
        $relative = $path.Substring($Prefix.Length)
        if ([string]::IsNullOrWhiteSpace($relative)) { continue }
        $slash = $relative.IndexOf('/')
        if ($slash -ge 0) {
            $folders[$relative.Substring(0, $slash)] = $true
        }
        else {
            $files += [pscustomobject]@{ Type = 'File'; Name = $relative; Path = $path }
        }
    }
    $items = @()
    foreach ($name in @($folders.Keys | Sort-Object)) {
        $items += [pscustomobject]@{ Type = 'Folder'; Name = $name; Path = $null }
    }
    $items += @($files | Sort-Object Name)
    return $items
}

try {
    $repoRoot = Initialize-RepositoryCache
    while ($true) {
        $scriptPaths = @(Get-CachedScripts -Root $repoRoot)
        if ($scriptPaths.Count -eq 0) { throw 'The cached repository has no eligible .cmd or .bat scripts.' }
        $currentParts = [Collections.Generic.List[string]]::new()
        $runAnother = $false
        while (-not $runAnother) {
            Clear-Host
            $prefix = if ($currentParts.Count) { ($currentParts -join '/') + '/' } else { '' }
            $category = if ($currentParts.Count) { '/' + ($currentParts -join '/') } else { '/ (repository root)' }
            Write-Host '============================================================'
            Write-Host '                 GITHUB SCRIPT LAUNCHER'
            Write-Host '============================================================'
            Write-Host "Repository: $owner/$repo ($branch)"
            Write-Host "Cache location: $cacheRoot"
            Write-Host "Category: $category"
            Write-Host ''
            $items = @(Get-Children -Paths $scriptPaths -Prefix $prefix)
            $index = 1
            foreach ($item in $items) {
                if ($item.Type -eq 'Folder') {
                    Write-Host (' {0}. {1} {2}' -f $index, $item.Name, [char]::ConvertFromUtf32(0x1F4C2))
                }
                else {
                    Write-Host (' {0}. {1}' -f $index, $item.Name)
                }
                $index++
            }
            if ($currentParts.Count) {
                Write-Host ' 0. Back to parent folder'
            }
            else {
                Write-Host ' 0. Quit'
            }
            Write-Host ''
            $answer = (Read-Host 'Choose a folder or script').Trim()
            if ($answer -eq '0') {
                if ($currentParts.Count) {
                    $currentParts.RemoveAt($currentParts.Count - 1)
                    continue
                }
                if ($env:SHOW_CACHE_CLEAR_PROMPT -eq '1') {
                    Write-Host ''
                    Write-Host "Cache: $cacheRoot"
                    Write-Host ' 1. Clear cache and exit'
                    Write-Host ' enter to Exit without clearing cache'
                    $exitChoice = (Read-Host 'Choose').Trim()
                    if ($exitChoice -eq '1') {
                        Get-ChildItem -LiteralPath $WorkingFolder -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'repository-cache-*' -or $_.Name -like 'script-cache-*' } | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
                        Write-Host 'Cache cleared.'
                    }
                    else {
                        Write-Host "Cache retained at: $cacheRoot"
                    }
                }
                else {
                    Write-Host "Cache retained at: $cacheRoot"
                }
                return
            }
            $selection = 0
            if (-not [int]::TryParse($answer, [ref]$selection) -or $selection -lt 1 -or $selection -gt $items.Count) {
                Write-Host 'Invalid selection.' -ForegroundColor Yellow
                Start-Sleep -Seconds 1
                continue
            }
            $selected = $items[$selection - 1]
            if ($selected.Type -eq 'Folder') {
                $currentParts.Add($selected.Name)
                continue
            }

            $selectedLocal = Join-Path $repoRoot ($selected.Path -replace '/', '\')
            if (-not (Test-Path -LiteralPath $selectedLocal -PathType Leaf)) {
                Write-Host 'The selected script is missing from the saved cache.' -ForegroundColor Red
                Start-Sleep -Seconds 2
                $runAnother = $true
                continue
            }
            $hash = (Get-FileHash -LiteralPath $selectedLocal -Algorithm SHA256).Hash
            Write-Host "`nUsing cached script. SHA-256: $hash"
            Write-Host 'Launching in a separate window; this menu stays available.'
            $scriptFolder = Split-Path -Parent $selectedLocal
            $quoted = '""{0}""' -f $selectedLocal
            $process = Start-Process -FilePath $env:ComSpec -ArgumentList "/d /c $quoted" -WorkingDirectory $scriptFolder -WindowStyle Normal -PassThru
            Write-Host "Started $($selected.Path) in a new window (process $($process.Id))."
            $runAnother = $true
        }
    }
}
catch {
    Write-Host "Launcher error: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Cache location: $cacheRoot"
    [void](Read-Host 'Press Enter to close')
    exit 1
}
