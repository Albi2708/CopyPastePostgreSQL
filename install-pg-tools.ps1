param(
    [ValidateSet('winget', 'choco', 'manual')]
    [string]$Method = 'winget'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Has-Command {
    param([string]$Name)
    return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

function Print-DetectedTools {
    $tools = @('pg_dump.exe', 'pg_restore.exe', 'psql.exe')
    foreach ($tool in $tools) {
        $cmd = Get-Command $tool -ErrorAction SilentlyContinue
        if ($null -ne $cmd) {
            Write-Host "$tool -> $($cmd.Source)"
        }
    }
}

function Test-PgToolsAvailable {
    return (
        (Has-Command 'pg_dump.exe') -and
        (Has-Command 'pg_restore.exe') -and
        (Has-Command 'psql.exe')
    )
}

function Invoke-WingetInstall {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PackageId
    )

    Write-Host "Attempting winget install for package id: $PackageId"
    & winget install --id $PackageId -e --source winget --accept-package-agreements --accept-source-agreements
    return $LASTEXITCODE
}

if (Test-PgToolsAvailable) {
    Write-Host "PostgreSQL client tools are already available."
    Print-DetectedTools
    exit 0
}

switch ($Method) {
    'winget' {
        if (-not (Has-Command 'winget.exe')) {
            Write-Error "winget is not available. Re-run with -Method choco or -Method manual."
            exit 1
        }

        $packageIds = @(
            'PostgreSQL.PostgreSQL.17'
        )

        $installed = $false

        Write-Host "Checking winget sources..."
        & winget source list

        foreach ($packageId in $packageIds) {
            Write-Host "Installing PostgreSQL (includes client tools) via winget..."
            $exitCode = Invoke-WingetInstall -PackageId $packageId

            if ($exitCode -eq 0) {
                $installed = $true
                break
            }

            Write-Warning "winget install failed for $packageId with exit code $exitCode."
            Write-Host "Trying to refresh/reset winget sources, then retry once..."

            & winget source update
            & winget source reset --force

            $exitCode = Invoke-WingetInstall -PackageId $packageId
            if ($exitCode -eq 0) {
                $installed = $true
                break
            }

            Write-Warning "Retry also failed for $packageId with exit code $exitCode."
        }

        if (-not $installed) {
            Write-Host ""
            Write-Host "Diagnostics you can run manually:"
            Write-Host "  winget source list"
            Write-Host "  winget source update"
            Write-Host "  winget source reset --force"
            Write-Host "  winget search PostgreSQL"
            Write-Host "  winget search --id PostgreSQL.PostgreSQL.17"
            Write-Error "winget installation failed."
            exit 1
        }
    }

    'choco' {
        if (-not (Has-Command 'choco.exe')) {
            Write-Error "Chocolatey is not available. Re-run with -Method winget or -Method manual."
            exit 1
        }

        Write-Host "Installing PostgreSQL (includes client tools) via Chocolatey..."
        & choco install postgresql --yes
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Chocolatey installation failed with exit code $LASTEXITCODE."
            exit 1
        }
    }

    'manual' {
        Write-Host "Manual install:"
        Write-Host "1) Download PostgreSQL installer for Windows from: https://www.postgresql.org/download/windows/"
        Write-Host "2) Install PostgreSQL 17.x (or newer compatible version)."
        Write-Host "3) Ensure client tools are available in PATH or set PG_BIN_DIR in .env."
        Write-Host "   Typical path: C:\Program Files\PostgreSQL\17\bin"
        exit 0
    }
}

Write-Host ""
Write-Host "Installation command finished. Verifying tools..."

if (Test-PgToolsAvailable) {
    Write-Host "PostgreSQL client tools detected."
    Print-DetectedTools
    exit 0
}

Write-Warning "Tools are not yet visible in PATH in this shell."
Write-Host "If installed successfully, either:"
Write-Host "- Open a new PowerShell session and run the database copy script again, or"
Write-Host "- Set PG_BIN_DIR in .env to your PostgreSQL bin folder."
exit 1
