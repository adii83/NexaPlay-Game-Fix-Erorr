[Console]::InputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function Show-SpinnerAndResult {
    param (
        [string]$SpinnerText,
        [ScriptBlock]$Action,
        [string]$ExtraInfo = $null,
        [string]$Tip = $null,
        [switch]$IsSubStep
    )
    $prefix = if ($IsSubStep) { '  ' } else { '' }
    $spinnerPos = [Console]::CursorTop
    $spinner = @('|', '/', '-', '\')
    Write-Host "$prefix$($spinner[0])" -NoNewline -ForegroundColor White
    Write-Host " $SpinnerText" -ForegroundColor White
    if ($Tip) {
        $tipPos = [Console]::CursorTop
        Write-Host "$prefix  $([char]0x2514)$([char]0x2500) $Tip" -ForegroundColor Yellow
    }
    $done = $false
    $i = 0
    $result = $null
    $job = Start-Job -ScriptBlock $Action

    while (-not $done) {
        Start-Sleep -Milliseconds 100
        $char = $spinner[$i % $spinner.Count]
        [Console]::SetCursorPosition(0, $spinnerPos)
        Write-Host "$prefix$char" -NoNewline -ForegroundColor White
        Write-Host " $SpinnerText" -NoNewline -ForegroundColor White
        $i++
        if ($job.State -eq 'Completed' -or $job.State -eq 'Failed' -or $job.State -eq 'Stopped') {
            $done = $true
        }
    }
    $result = Receive-Job $job -ErrorAction SilentlyContinue
    Remove-Job $job | Out-Null

    [Console]::SetCursorPosition(0, $spinnerPos)
    [Console]::Write((' ' * ([Console]::WindowWidth-1)))
    if ($Tip) {
        [Console]::SetCursorPosition(0, $tipPos)
        [Console]::Write((' ' * ([Console]::WindowWidth-1)))
    }
    [Console]::SetCursorPosition(0, $spinnerPos)
    if ($result -and $result.Success) {
        Write-Host "$prefix$([char]0x2713)" -NoNewline -ForegroundColor Green
        Write-Host " $SpinnerText" -NoNewline -ForegroundColor Green
        [Console]::WriteLine('')
        if ($ExtraInfo -and $result.Path) {
            Write-Host "${prefix}Location: $($result.Path)" -ForegroundColor White
        }
    } else {
        Write-Host "${prefix}X" -NoNewline -ForegroundColor Red
        Write-Host " $SpinnerText" -NoNewline -ForegroundColor Red
        [Console]::WriteLine('')
        if ($result -and $result.Extra) {
            Write-Host "$prefix$($result.Extra)" -ForegroundColor Red
        }
        if (-not $IsSubStep) {
            Write-Host ''
            Write-Host 'Press any key to exit...' -ForegroundColor White
            $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
            exit
        }
    }
    return $result
}

Clear-Host
Write-Host ''
Write-Host 'Nexaplay' -BackgroundColor Magenta
Write-Host 'Tunggu proses sampai selesai' -BackgroundColor DarkGray -ForegroundColor White
Write-Host ''

$API = "https://api.steamproof.net"

function DlError($raw) {
    if ($raw -match "\((\d{3})\)") { return "HTTP $($Matches[1])" }
    if ($raw -match 'timed?\s*out') { return 'timed out' }
    if ($raw -match 'name.*(not|could).*resolve') { return 'DNS error' }
    return 'download failed'
}

function RestartSteam {
    Show-SpinnerAndResult `
        -SpinnerText 'Restart Steam' `
        -Action {
            $sp = $using:steamPath
            $steamExe = Join-Path $sp 'steam.exe'
            if (Get-Process -Name 'steam' -EA SilentlyContinue) {
                Get-Process 'steam' -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
                Start-Sleep -Seconds 2
                if (Get-Process -Name 'steam' -EA SilentlyContinue) {
                    Start-Process cmd -ArgumentList '/c taskkill /f /im steam.exe' -WindowStyle Hidden -EA SilentlyContinue
                    Start-Sleep -Seconds 2
                }
            }
            Start-Process $steamExe
            Start-Process 'steam://'
            return @{ Success = $true; Path = '' }
        } | Out-Null
}

# Step 0: Find Steam installation
$steamResult = Show-SpinnerAndResult `
    -SpinnerText 'Find Steam installation' `
    -Action {
        $registryPaths = @(
            'HKCU:\Software\Valve\Steam',
            'HKLM:\Software\Valve\Steam',
            'HKLM:\Software\WOW6432Node\Valve\Steam'
        )

        foreach ($regPath in $registryPaths) {
            if (Test-Path $regPath) {
                $props = Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue
                if ($props -and ("SteamPath" -in $props.PSObject.Properties.Name)) {
                    $installPath = $props.SteamPath -replace "/", "\"
                    if ($installPath -and (Test-Path $installPath)) {
                        return @{ Success = $true; Path = $installPath }
                    }
                }
                $installPath = $props.InstallPath
                if ($installPath -and (Test-Path $installPath)) {
                    return @{ Success = $true; Path = $installPath }
                }
            }
        }

        return @{ Success = $false; Extra = 'Steam installation not found. Try reinstalling Steam' }
    }
$steamPath = $steamResult.Path

# Step 1: Locate stplug-in folder and lua files
$luaResult = Show-SpinnerAndResult `
    -SpinnerText 'Locate stplug-in folder and lua files' `
    -Action {
        $sp = $using:steamPath
        $pluginDir = Join-Path $sp "config\stplug-in"
        $depotCache = Join-Path $sp "depotcache"

        if (-not (Test-Path $pluginDir)) {
            return @{ Success = $false; Extra = "No stplug-in folder found at: $pluginDir" }
        }

        $luaFiles = Get-ChildItem -Path $pluginDir -Filter "*.lua" -EA SilentlyContinue
        if ($luaFiles.Count -eq 0) {
            return @{ Success = $false; Extra = 'No .lua files found in stplug-in folder' }
        }

        if (-not (Test-Path $depotCache)) { New-Item -ItemType Directory -Path $depotCache -Force > $null }

        return @{ Success = $true; Path = "$($luaFiles.Count)" }
    }

$pluginDir = Join-Path $steamPath "config\stplug-in"
$depotCache = Join-Path $steamPath "depotcache"
$luaFiles = Get-ChildItem -Path $pluginDir -Filter "*.lua" -EA SilentlyContinue

# Step 2: Scan lua files for missing manifests
$scanResult = Show-SpinnerAndResult `
    -SpinnerText "Scan $($luaFiles.Count) lua file(s) for missing manifests" `
    -Action {
        $sp = $using:steamPath
        $pDir = Join-Path $sp "config\stplug-in"
        $dCache = Join-Path $sp "depotcache"
        $lFiles = Get-ChildItem -Path $pDir -Filter "*.lua" -EA SilentlyContinue

        $appLuas = @{}
        $needsLookup = @()

        foreach ($luaFile in $lFiles) {
            $appId = [System.IO.Path]::GetFileNameWithoutExtension($luaFile.Name)
            if ($appId -notmatch "^\d+$") { continue }

            $luaRaw = Get-Content -Path $luaFile.FullName -Raw -Encoding UTF8
            $depotIds = [regex]::Matches($luaRaw, "addappid\((\d+)") | ForEach-Object { $_.Groups[1].Value }
            $appLuas[$appId] = @{ file = $luaFile.FullName; content = $luaRaw; depotIds = $depotIds }

            $allPresent = $depotIds.Count -gt 0
            foreach ($did in $depotIds) {
                if (-not (Get-ChildItem -Path $dCache -Filter "${did}_*.manifest" -EA SilentlyContinue)) {
                    $allPresent = $false; break
                }
            }
            if (-not $allPresent) { $needsLookup += $appId }
        }

        return @{ Success = $true; Path = ($needsLookup -join ","); Extra = ($appLuas.Count - $needsLookup.Count) }
    }

$needsLookup = @()
if ($scanResult.Path -and $scanResult.Path -ne '') {
    $needsLookup = $scanResult.Path -split ','
}
$upToDate = $scanResult.Extra

if ($upToDate -gt 0) {
    Write-Host "  $upToDate app(s) already up-to-date" -ForegroundColor DarkGray
}

if ($needsLookup.Count -eq 0) {
    Write-Host ''
    Write-Host ([char]0x2713) 'Everything is up-to-date!' -BackgroundColor Green -ForegroundColor Black
    Write-Host ''
    Write-Host 'Press any key to exit...' -ForegroundColor DarkGray
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    exit
}

# Step 3: Fetch app info from API
$wc = New-Object System.Net.WebClient
$wc.Encoding = [System.Text.Encoding]::UTF8
$wc.Headers["Content-Type"] = "application/json"

$appInfoMap = @{}
$fetchResult = Show-SpinnerAndResult `
    -SpinnerText "Fetch info for $($needsLookup.Count) app(s)" `
    -Action {
        $wcInner = New-Object System.Net.WebClient
        $wcInner.Encoding = [System.Text.Encoding]::UTF8
        $wcInner.Headers["Content-Type"] = "application/json"
        $apiBase = $using:API

        try {
            $ids = ($using:needsLookup | ForEach-Object { [int]$_ }) -join ","
            $resp = $wcInner.DownloadString("$apiBase/apps/depots?ids=$ids") | ConvertFrom-Json
            $data = @{}
            foreach ($app in $resp.apps) { $data[[string]$app.appId] = $app }
            $wcInner.Dispose()
            return @{ Success = $true; Path = ($data | ConvertTo-Json -Depth 10 -Compress) }
        } catch {
            $wcInner.Dispose()
            $msg = $_.Exception.Message
            if ($msg -match 'remote server returned an error|WebException') {
                return @{ Success = $false; Extra = "Could not fetch app info: server may be overloaded or down, try again later" }
            }
            return @{ Success = $false; Extra = "Could not fetch app info: $msg" }
        }
    }

$appInfoRaw = $fetchResult.Path | ConvertFrom-Json
foreach ($prop in $appInfoRaw.PSObject.Properties) {
    $appInfoMap[$prop.Name] = $prop.Value
}

# Re-read lua files for main thread processing
$appLuas = @{}
foreach ($luaFile in $luaFiles) {
    $appId = [System.IO.Path]::GetFileNameWithoutExtension($luaFile.Name)
    if ($appId -notmatch "^\d+$") { continue }
    $luaRaw = Get-Content -Path $luaFile.FullName -Raw -Encoding UTF8
    $depotIds = [regex]::Matches($luaRaw, "addappid\((\d+)") | ForEach-Object { $_.Groups[1].Value }
    $appLuas[$appId] = @{ file = $luaFile; content = $luaRaw; depotIds = $depotIds }
}

# Step 4: Download and update manifests
$totalUpdated = 0
$totalFailed = 0
$totalSkipped = 0
$luaFilesUpdated = 0
$spinner = @('|', '/', '-', '\')
$treeJoin = "$([char]0x251C)$([char]0x2500)"
$treeEnd  = "$([char]0x2514)$([char]0x2500)"

$parentPos = [Console]::CursorTop
$parentText = "Download and update manifests for $($needsLookup.Count) app(s)"
Write-Host "$($spinner[0]) $parentText" -ForegroundColor White
$spinnerIdx = 0

for ($appIdx = 0; $appIdx -lt $needsLookup.Count; $appIdx++) {
    $appId = $needsLookup[$appIdx]
    $isLast = ($appIdx -eq $needsLookup.Count - 1)
    $branch_char = if ($isLast) { $treeEnd } else { $treeJoin }
    $info = $appInfoMap[$appId]
    $lua = $appLuas[$appId]
    $name = if ($info -and $info.name) { $info.name } else { "App $appId" }

    if (-not $info -or -not $info.depots -or $info.depots.Count -eq 0) {
        Write-Host "$branch_char " -NoNewline -ForegroundColor DarkGray
        Write-Host "X" -NoNewline -ForegroundColor Red
        Write-Host " [$appId] $name - no depots found" -ForegroundColor Red
        $totalFailed++
        continue
    }

    $depotManifests = @{}
    $needsDownload = $false
    foreach ($depot in $info.depots) {
        $depotBranch = $depot.manifests.public
        if (-not $depotBranch -or -not $depotBranch.manifestId) { continue }
        $depotManifests[$depot.depotId] = @{ id = $depotBranch.manifestId; size = $depot.maxSize }
        if (-not (Test-Path (Join-Path $depotCache "$($depot.depotId)_$($depotBranch.manifestId).manifest"))) {
            $needsDownload = $true
        }
    }

    if ($depotManifests.Count -gt 100) {
        Write-Host "$branch_char " -NoNewline -ForegroundColor DarkGray
        Write-Host "!" -NoNewline -ForegroundColor Yellow
        Write-Host " [$appId] $name - $($depotManifests.Count) depots, retry on https://steamproof.net/bundle" -ForegroundColor Yellow
        $totalSkipped++
        continue
    }

    $downloaded = 0
    if ($needsDownload) {
        $dlSuccess = $false
        $lastErr = ""

        $subPos = [Console]::CursorTop

        # Fetch manifest list
        $manifestList = $null
        for ($attempt = 1; $attempt -le 2; $attempt++) {
            $job = Start-Job -ScriptBlock {
                param($url)
                try {
                    $wc2 = New-Object System.Net.WebClient
                    $wc2.Encoding = [System.Text.Encoding]::UTF8
                    $json = $wc2.DownloadString($url)
                    $wc2.Dispose()
                    return @{ Success = $true; Data = $json }
                } catch {
                    return @{ Success = $false; Error = $_.Exception.Message }
                }
            } -ArgumentList "$API/app/$appId/manifests/download"

            while ($job.State -eq 'Running') {
                Start-Sleep -Milliseconds 100
                $spinnerIdx++
                $char = $spinner[$spinnerIdx % $spinner.Count]
                $bufH = [Console]::BufferHeight

                if ($parentPos -lt $bufH) {
                    [Console]::SetCursorPosition(0, $parentPos)
                    [Console]::Write("$char $parentText")
                }

                if ($subPos -lt $bufH) {
                    [Console]::SetCursorPosition(0, $subPos)
                    [Console]::Write("$branch_char $char [$appId] $name")
                    if ($subPos + 1 -lt $bufH) { [Console]::SetCursorPosition(0, $subPos + 1) }
                }
            }

            $jobResult = Receive-Job $job -EA SilentlyContinue
            Remove-Job $job -EA SilentlyContinue

            if ($jobResult -and $jobResult.Success) {
                $manifestList = ($jobResult.Data | ConvertFrom-Json).manifests
                $dlSuccess = $true
                break
            } else {
                $lastErr = DlError ($(if ($jobResult) { $jobResult.Error } else { 'Download failed' }))
                if ($attempt -eq 1) { Start-Sleep -Seconds 2 }
            }
        }

        if (-not $dlSuccess -or -not $manifestList) {
            if ($subPos -lt [Console]::BufferHeight) {
                [Console]::SetCursorPosition(0, $subPos)
                [Console]::Write((' ' * ([Console]::WindowWidth - 1)))
                [Console]::SetCursorPosition(0, $subPos)
            }
            $totalFailed++
            Write-Host "$branch_char " -NoNewline -ForegroundColor DarkGray
            Write-Host "X" -NoNewline -ForegroundColor Red
            Write-Host " [$appId] $name - failed ($lastErr)" -ForegroundColor Red
            continue
        }

        # Download each manifest individually
        $toDownload = @()
        foreach ($m in $manifestList) {
            $dest = Join-Path $depotCache "$($m.depotId)_$($m.manifestId).manifest"
            if (-not (Test-Path $dest)) { $toDownload += $m }
        }

        $dlFailed = $false
        for ($mi = 0; $mi -lt $toDownload.Count; $mi++) {
            $m = $toDownload[$mi]
            $dest = Join-Path $depotCache "$($m.depotId)_$($m.manifestId).manifest"
            $mSuccess = $false

            for ($attempt = 1; $attempt -le 2; $attempt++) {
                $job = Start-Job -ScriptBlock {
                    param($url, $out)
                    try {
                        $wc2 = New-Object System.Net.WebClient
                        $wc2.DownloadFile($url, $out)
                        $wc2.Dispose()
                        return @{ Success = $true }
                    } catch {
                        return @{ Success = $false; Error = $_.Exception.Message }
                    }
                } -ArgumentList $m.url, $dest

                while ($job.State -eq 'Running') {
                    Start-Sleep -Milliseconds 100
                    $spinnerIdx++
                    $char = $spinner[$spinnerIdx % $spinner.Count]
                    $bufH = [Console]::BufferHeight
                    $progress = "($($mi + 1)/$($toDownload.Count))"

                    if ($parentPos -lt $bufH) {
                        [Console]::SetCursorPosition(0, $parentPos)
                        [Console]::Write("$char $parentText")
                    }

                    if ($subPos -lt $bufH) {
                        [Console]::SetCursorPosition(0, $subPos)
                        [Console]::Write("$branch_char $char [$appId] $name $progress")
                        if ($subPos + 1 -lt $bufH) { [Console]::SetCursorPosition(0, $subPos + 1) }
                    }
                }

                $jobResult = Receive-Job $job -EA SilentlyContinue
                Remove-Job $job -EA SilentlyContinue

                if ($jobResult -and $jobResult.Success) { $mSuccess = $true; break }
                $lastErr = DlError ($(if ($jobResult) { $jobResult.Error } else { 'Download failed' }))
                if ($attempt -eq 1) { Start-Sleep -Seconds 2 }
            }

            if ($mSuccess) {
                $downloaded++
                $totalUpdated++
            } else {
                $dlFailed = $true
                Remove-Item $dest -Force -EA SilentlyContinue
                break
            }
        }

        # Clear substep line
        if ($subPos -lt [Console]::BufferHeight) {
            [Console]::SetCursorPosition(0, $subPos)
            [Console]::Write((' ' * ([Console]::WindowWidth - 1)))
            [Console]::SetCursorPosition(0, $subPos)
        }

        if ($dlFailed) {
            $totalFailed++
            Write-Host "$branch_char " -NoNewline -ForegroundColor DarkGray
            Write-Host "X" -NoNewline -ForegroundColor Red
            Write-Host " [$appId] $name - failed ($lastErr)" -ForegroundColor Red
            continue
        }
    }

    # Update lua file
    $luaContent = $lua.content
    if ($depotManifests.Count -gt 0) {
        $luaContent = [regex]::Replace($luaContent, "\n*setManifestid\([^\n]*\n*", "")
        $luaContent = [regex]::Replace($luaContent, "(\n-- SteamProof Manifests.*)", "", [System.Text.RegularExpressions.RegexOptions]::Singleline)
        $luaContent = $luaContent.TrimEnd()

        $ts = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd HH:mm UTC")
        $section = "`n`n-- SteamProof Manifests (updated $ts)"
        foreach ($did in ($depotManifests.Keys | Sort-Object)) {
            $mid = $depotManifests[$did].id
            $sz = $depotManifests[$did].size
            if ($sz) { $section += "`nsetManifestid($did, `"$mid`", $sz)" }
            else     { $section += "`nsetManifestid($did, `"$mid`")" }
        }
        $section += "`n"

        [System.IO.File]::WriteAllText($lua.file.FullName, ($luaContent + $section), (New-Object System.Text.UTF8Encoding $false))
        $luaFilesUpdated++
    }

    # Print substep result
    $statusParts = @()
    if ($downloaded -gt 0) { $statusParts += "$downloaded new" }
    if ($depotManifests.Count -gt 0) { $statusParts += "lua updated" }
    $statusText = if ($statusParts.Count -gt 0) { $statusParts -join ', ' } else { 'ok' }

    Write-Host "$branch_char " -NoNewline -ForegroundColor DarkGray
    Write-Host "$([char]0x2713)" -NoNewline -ForegroundColor Green
    Write-Host " [$appId] $name - $statusText" -ForegroundColor Green
}

# Update parent step header with checkmark
$endPos = [Console]::CursorTop
if ($parentPos -lt [Console]::BufferHeight) {
    [Console]::SetCursorPosition(0, $parentPos)
    [Console]::Write((' ' * ([Console]::WindowWidth - 1)))
    [Console]::SetCursorPosition(0, $parentPos)
    Write-Host "$([char]0x2713)" -NoNewline -ForegroundColor Green
    Write-Host " $parentText" -ForegroundColor Green
    [Console]::SetCursorPosition(0, $endPos)
}

$wc.Dispose()

if ($totalUpdated -gt 0 -or $luaFilesUpdated -gt 0) {
    RestartSteam
}

Write-Host ''
Write-Host ([char]0x2713) "Process completed - $totalUpdated downloaded, $luaFilesUpdated lua updated$(if ($totalSkipped -gt 0) { ", $totalSkipped skipped" })$(if ($totalFailed -gt 0) { ", $totalFailed failed" })" -BackgroundColor Green -ForegroundColor Black
Write-Host ''
Write-Host 'Press any key to exit...' -ForegroundColor DarkGray
$null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
exit