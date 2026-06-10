$ErrorActionPreference = "Stop"

# ============================================================
# NEXAPLAY ONLINE BOOTSTRAPPER
# GAME FIX ERROR
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
Write-Host " NEXAPLAY ONLINE INSTALLER"
Write-Host "======================================================"
Write-Host ""

# =========================
# CONFIG
# =========================
$SetupZipUrl = "https://github.com/adii83/nexaplay-setup/releases/download/v1.0.0/NexaPlaySetup.zip"

$WorkDir = Join-Path $env:TEMP "NexaPlayOnlineSetup"
$ZipPath = Join-Path $WorkDir "NexaPlaySetup.zip"
$ExtractDir = Join-Path $WorkDir "Extracted"

# Nanti bisa diisi SHA256 ZIP kamu
$ExpectedHash = ""

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
Write-Host $SetupZipUrl
Write-Host ""

Invoke-WebRequest `
    -Uri $SetupZipUrl `
    -OutFile $ZipPath `
    -UseBasicParsing

if (-not (Test-Path $ZipPath)) {
    Write-Host "Download gagal."
    pause
    exit 1
}

Write-Host "Download selesai:"
Write-Host $ZipPath

# =========================
# VERIFY HASH OPTIONAL
# =========================
if ($ExpectedHash -ne "") {
    Write-Host ""
    Write-Host "Memeriksa SHA256..."

    $ActualHash = (Get-FileHash $ZipPath -Algorithm SHA256).Hash

    if ($ActualHash.ToUpper() -ne $ExpectedHash.ToUpper()) {
        Write-Host "Hash tidak cocok. Instalasi dibatalkan."
        Write-Host "Expected: $ExpectedHash"
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
    Write-Host "NexaPlaySetup.zip\Setup\install.ps1"
    pause
    exit 1
}

# =========================
# RUN MAIN INSTALLER
# =========================
Write-Host ""
Write-Host "Menjalankan installer utama NexaPlay..."

$process = Start-Process `
    -FilePath "powershell.exe" `
    -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$InstallScript`"" `
    -Wait `
    -PassThru

Write-Host ""
Write-Host "Installer selesai."
Write-Host "Exit Code: $($process.ExitCode)"

pause