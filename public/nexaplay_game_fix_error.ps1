$ErrorActionPreference = "Stop"

# ============================================================
# NEXAPLAY GAME FIX ERROR
# ============================================================

# =========================
# AUTO REQUEST ADMIN / UAC
# =========================
$IsAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $IsAdmin) {
    Write-Host "Meminta akses Administrator..."

    Start-Process powershell.exe `
        -Verb RunAs `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""

    exit
}

Clear-Host

Write-Host ""
Write-Host "======================================================"
Write-Host " NEXAPLAY GAME FIX ERROR"
Write-Host "======================================================"
Write-Host ""

function Write-ProgressLine {
    param (
        [string]$Label,
        [int]$Percent
    )

    $safePercent = [Math]::Min(100, [Math]::Max(0, $Percent))
    $barWidth = 28
    $filled = [Math]::Floor(($safePercent / 100) * $barWidth)
    $empty = $barWidth - $filled
    $bar = ("#" * $filled) + ("." * $empty)
    $line = "{0,-22} [{1}] {2,3}%%" -f $Label, $bar, $safePercent

    Write-Host ("`r" + $line) -NoNewline
}

function Download-FileWithProgress {
    param (
        [string]$Url,
        [string]$DestinationPath,
        [string]$Label
    )

    $webClient = New-Object System.Net.WebClient
    $downloadComplete = $false
    $downloadError = $null

    $progressEvent = Register-ObjectEvent `
        -InputObject $webClient `
        -EventName DownloadProgressChanged `
        -Action {
            Write-ProgressLine -Label $Event.MessageData.Label -Percent $Event.SourceEventArgs.ProgressPercentage
        } `
        -MessageData @{ Label = $Label }

    $completeEvent = Register-ObjectEvent `
        -InputObject $webClient `
        -EventName DownloadFileCompleted `
        -Action {
            if ($Event.SourceEventArgs.Error) {
                $global:NexaPlayBootstrapDownloadError = $Event.SourceEventArgs.Error
            }

            $global:NexaPlayBootstrapDownloadComplete = $true
        }

    try {
        $global:NexaPlayBootstrapDownloadComplete = $false
        $global:NexaPlayBootstrapDownloadError = $null

        $uri = [System.Uri]::new($Url)
        $destination = [System.IO.Path]::GetFullPath($DestinationPath)

        $webClient.DownloadFileAsync($uri, $destination)

        while (-not $global:NexaPlayBootstrapDownloadComplete) {
            Start-Sleep -Milliseconds 150
        }

        if ($global:NexaPlayBootstrapDownloadError) {
            throw $global:NexaPlayBootstrapDownloadError
        }

        Write-ProgressLine -Label $Label -Percent 100
        Write-Host ""
    }
    finally {
        Unregister-Event -SourceIdentifier $progressEvent.Name -ErrorAction SilentlyContinue
        Unregister-Event -SourceIdentifier $completeEvent.Name -ErrorAction SilentlyContinue
        Remove-Job -Id $progressEvent.Id -Force -ErrorAction SilentlyContinue
        Remove-Job -Id $completeEvent.Id -Force -ErrorAction SilentlyContinue
        $webClient.Dispose()
        Remove-Variable -Name NexaPlayBootstrapDownloadComplete -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name NexaPlayBootstrapDownloadError -Scope Global -ErrorAction SilentlyContinue
    }
}

# =========================
# CONFIG
# =========================
$SetupZipUrl = "https://github.com/adii83/NexaPlay-Game-Fix-Erorr/releases/download/v1.0.1/NexaPlay-Fix-Erorr.zip"

$WorkDir = Join-Path $env:TEMP "NexaPlayFixError"
$ZipPath = Join-Path $WorkDir "NexaPlay-Fix-Erorr.zip"
$ExtractDir = Join-Path $WorkDir "Extracted"

# Salin hash SHA256 dari GitHub Release boleh langsung dipaste,
# prefix "sha256:" akan dibersihkan otomatis jika ada.
$ExpectedHash = "sha256:2fc8590904164ed3ceaf1a1ba664332daeab56e559b41d5326784c6170ca95f6"

# =========================
# PREPARE FOLDER
# =========================
if (Test-Path $WorkDir) {
    Remove-Item $WorkDir -Recurse -Force
}

New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
New-Item -ItemType Directory -Force -Path $ExtractDir | Out-Null

# =========================
# DOWNLOAD ZIP
# =========================
Write-Host "Mengunduh paket NexaPlay..."
Write-Host ""

try {
    Download-FileWithProgress `
        -Url $SetupZipUrl `
        -DestinationPath $ZipPath `
        -Label "Proses download"
}
catch {
    Write-Host ""
    Write-Host "[GAGAL] Download paket tidak berhasil."
    Write-Host $_.Exception.Message
    pause
    exit 1
}

if (-not (Test-Path $ZipPath)) {
    Write-Host "Download gagal."
    pause
    exit 1
}

Write-Host "[OK] Download selesai."

# =========================
# VERIFY HASH OPTIONAL
# =========================
if ($ExpectedHash -ne "") {
    Write-Host ""
    Write-Host "Memeriksa SHA256..."

    $ActualHash = (Get-FileHash $ZipPath -Algorithm SHA256).Hash
    $NormalizedExpectedHash = $ExpectedHash -replace '^\s*sha256\s*:\s*', ''

    if ($ActualHash.ToUpper() -ne $NormalizedExpectedHash.ToUpper()) {
        Write-Host "Hash tidak cocok. Instalasi dibatalkan."
        Write-Host "Expected: $NormalizedExpectedHash"
        Write-Host "Actual  : $ActualHash"
        pause
        exit 1
    }

    Write-Host "Hash valid."
}

# =========================
# EXTRACT ZIP
# =========================
Write-Host ""
Write-Host "Mengekstrak paket..."

Expand-Archive `
    -Path $ZipPath `
    -DestinationPath $ExtractDir `
    -Force

# =========================
# FIND INSTALL SCRIPT
# =========================
$InstallScript = Join-Path $ExtractDir "Setup\install.ps1"

if (-not (Test-Path $InstallScript)) {
    Write-Host ""
    Write-Host "install.ps1 tidak ditemukan."
    Write-Host "Pastikan isi ZIP adalah:"
    Write-Host "NexaPlay-Fix-Erorr.zip\Setup\install.ps1"
    pause
    exit 1
}

# =========================
# RUN MAIN INSTALLER
# =========================
Write-Host ""
Write-Host "Menjalankan GAME FIX ERROR..."

$process = Start-Process `
    -FilePath "powershell.exe" `
    -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$InstallScript`"" `
    -Wait `
    -PassThru

Write-Host ""
Write-Host "GAME FIX ERROR selesai."
Write-Host "Exit Code: $($process.ExitCode)"

pause
