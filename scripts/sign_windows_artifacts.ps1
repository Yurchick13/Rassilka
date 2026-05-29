param(
    [string]$SignToolPath = "",
    [string]$DistDir = ".\dist\windows",
    [string]$BundleDir = ".\redos_notifier\windows\vacation-notifier",
    [string]$CertThumbprint = "",
    [string]$PfxPath = "",
    [string]$PfxPassword = "",
    [string]$TimestampUrl = "http://timestamp.digicert.com"
)

$ErrorActionPreference = "Stop"

function Resolve-SignTool {
    param([string]$Preferred)

    if (-not [string]::IsNullOrWhiteSpace($Preferred)) {
        if (-not (Test-Path $Preferred)) {
            throw "signtool not found at: $Preferred"
        }
        return (Resolve-Path $Preferred).Path
    }

    $cmd = Get-Command signtool.exe -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Path) {
        return $cmd.Path
    }

    $kitsRoot = "${env:ProgramFiles(x86)}\Windows Kits\10\bin"
    if (Test-Path $kitsRoot) {
        $candidate = Get-ChildItem -Path $kitsRoot -Recurse -Filter signtool.exe -ErrorAction SilentlyContinue |
            Sort-Object FullName -Descending |
            Select-Object -First 1
        if ($candidate) {
            return $candidate.FullName
        }
    }

    throw "signtool.exe not found. Install Windows SDK (Signing Tools)."
}

function Invoke-Sign {
    param(
        [string]$Tool,
        [string]$FilePath,
        [string]$Thumb,
        [string]$Pfx,
        [string]$PfxPass,
        [string]$TsUrl
    )

    $args = @("sign", "/fd", "SHA256", "/tr", $TsUrl, "/td", "SHA256")

    if (-not [string]::IsNullOrWhiteSpace($Thumb)) {
        $args += @("/sha1", $Thumb)
    }
    elseif (-not [string]::IsNullOrWhiteSpace($Pfx)) {
        if (-not (Test-Path $Pfx)) {
            throw "PFX not found: $Pfx"
        }
        $args += @("/f", $Pfx)
        if (-not [string]::IsNullOrWhiteSpace($PfxPass)) {
            $args += @("/p", $PfxPass)
        }
    }
    else {
        $args += "/a"
    }

    $args += $FilePath

    & $Tool @args
    if ($LASTEXITCODE -ne 0) {
        throw "Signing failed: $FilePath"
    }
}

function Invoke-Verify {
    param(
        [string]$Tool,
        [string]$FilePath
    )

    & $Tool verify /pa /v $FilePath
    if ($LASTEXITCODE -ne 0) {
        throw "Signature verification failed: $FilePath"
    }
}

$tool = Resolve-SignTool -Preferred $SignToolPath

$targets = @()
if (Test-Path $BundleDir) {
    $targets += Get-ChildItem -Path $BundleDir -Recurse -File | Where-Object { $_.Extension -in @('.exe', '.dll') }
}
if (Test-Path $DistDir) {
    $targets += Get-ChildItem -Path $DistDir -Recurse -File | Where-Object { $_.Extension -eq '.exe' }
}

$targets = $targets | Sort-Object FullName -Unique
if (-not $targets -or $targets.Count -eq 0) {
    throw "No Windows artifacts found to sign. Build installers first."
}

Write-Host "Using signtool: $tool"
Write-Host "Files to sign: $($targets.Count)"

foreach ($item in $targets) {
    Write-Host "Signing: $($item.FullName)"
    Invoke-Sign -Tool $tool -FilePath $item.FullName -Thumb $CertThumbprint -Pfx $PfxPath -PfxPass $PfxPassword -TsUrl $TimestampUrl
}

foreach ($item in $targets) {
    Write-Host "Verifying: $($item.FullName)"
    Invoke-Verify -Tool $tool -FilePath $item.FullName
}

Write-Host "All files signed and verified successfully."
