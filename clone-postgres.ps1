param(
    [string]$EnvFile = ".env"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Fail {
    param([string]$Message)
    Write-Error $Message
    exit 1
}

function Load-EnvFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        Fail "Config file not found: $Path"
    }

    $vars = @{}
    $lines = Get-Content -LiteralPath $Path

    foreach ($line in $lines) {
        $trimmed = $line.Trim()

        if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith('#')) {
            continue
        }

        $idx = $trimmed.IndexOf('=')
        if ($idx -lt 1) {
            continue
        }

        $key = $trimmed.Substring(0, $idx).Trim()
        $value = $trimmed.Substring($idx + 1).Trim()

        if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
            $value = $value.Substring(1, $value.Length - 2)
        }

        $vars[$key] = $value
    }

    return $vars
}

function Get-RequiredValue {
    param(
        [hashtable]$Config,
        [string]$Key
    )

    if (-not $Config.ContainsKey($Key) -or [string]::IsNullOrWhiteSpace($Config[$Key])) {
        Fail "Missing required config value: $Key"
    }

    return $Config[$Key]
}

function Get-PgTool {
    param(
        [string]$Name,
        [string]$BinDir
    )

    $exe = "$Name.exe"

    if (-not [string]::IsNullOrWhiteSpace($BinDir)) {
        $candidate = Join-Path $BinDir $exe
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
        Fail "Tool '$exe' not found in PG_BIN_DIR: $BinDir"
    }

    $cmd = Get-Command $exe -ErrorAction SilentlyContinue
    if ($null -ne $cmd) {
        return $cmd.Source
    }

    Fail "Tool '$exe' not found in PATH. Install PostgreSQL client tools or set PG_BIN_DIR."
}

function Run-Checked {
    param(
        [string]$Exe,
        [string[]]$CommandArgs
    )

    & $Exe @CommandArgs
    if ($LASTEXITCODE -ne 0) {
        $joined = $CommandArgs -join ' '
        Fail "Command failed (exit code $LASTEXITCODE): $Exe $joined"
    }
}

function Test-DatabaseExists {
    param(
        [string]$Psql,
        [string]$DbHost,
        [string]$Port,
        [string]$Database,
        [string]$User,
        [string]$Password,
        [string]$SslMode
    )

    $env:PGPASSWORD = $Password
    $hadSsl = $false
    $previousSsl = $null

    try {
        if (-not [string]::IsNullOrWhiteSpace($SslMode)) {
            $hadSsl = Test-Path Env:PGSSLMODE
            if ($hadSsl) {
                $previousSsl = $env:PGSSLMODE
            }
            $env:PGSSLMODE = $SslMode
        }

        $psqlArgs = @(
            '--host', $DbHost,
            '--port', $Port,
            '--username', $User,
            '--dbname', $Database,
            '--no-password',
            '--command', 'SELECT 1;'
        )

        & $Psql @psqlArgs *> $null
        return ($LASTEXITCODE -eq 0)
    }
    finally {
        Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
        if (-not [string]::IsNullOrWhiteSpace($SslMode)) {
            if ($hadSsl) {
                $env:PGSSLMODE = $previousSsl
            }
            else {
                Remove-Item Env:PGSSLMODE -ErrorAction SilentlyContinue
            }
        }
    }
}

try {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $envPath = if ([System.IO.Path]::IsPathRooted($EnvFile)) { $EnvFile } else { Join-Path $scriptDir $EnvFile }

    Write-Step "Loading configuration from $envPath"
    $cfg = Load-EnvFile -Path $envPath

    $sourceHost = Get-RequiredValue -Config $cfg -Key 'SOURCE_PGHOST'
    $sourcePort = Get-RequiredValue -Config $cfg -Key 'SOURCE_PGPORT'
    $sourceDb = Get-RequiredValue -Config $cfg -Key 'SOURCE_PGDATABASE'
    $sourceUser = Get-RequiredValue -Config $cfg -Key 'SOURCE_PGUSER'
    $sourcePassword = Get-RequiredValue -Config $cfg -Key 'SOURCE_PGPASSWORD'
    $sourceSslMode = if ($cfg.ContainsKey('SOURCE_PGSSLMODE')) { $cfg['SOURCE_PGSSLMODE'] } else { '' }

    $recipientHost = Get-RequiredValue -Config $cfg -Key 'RECIPIENT_PGHOST'
    $recipientPort = Get-RequiredValue -Config $cfg -Key 'RECIPIENT_PGPORT'
    $recipientDb = Get-RequiredValue -Config $cfg -Key 'RECIPIENT_PGDATABASE'
    $recipientUser = Get-RequiredValue -Config $cfg -Key 'RECIPIENT_PGUSER'
    $recipientPassword = Get-RequiredValue -Config $cfg -Key 'RECIPIENT_PGPASSWORD'
    $recipientSslMode = if ($cfg.ContainsKey('RECIPIENT_PGSSLMODE')) { $cfg['RECIPIENT_PGSSLMODE'] } else { '' }
    $pgBinDir = if ($cfg.ContainsKey('PG_BIN_DIR')) { $cfg['PG_BIN_DIR'] } else { '' }
    $restoreJobs = if ($cfg.ContainsKey('RESTORE_JOBS') -and -not [string]::IsNullOrWhiteSpace($cfg['RESTORE_JOBS'])) { $cfg['RESTORE_JOBS'] } else { '1' }

    if ($sourceHost.Trim().ToLowerInvariant() -eq $recipientHost.Trim().ToLowerInvariant() -and $sourcePort -eq $recipientPort -and $sourceDb -eq $recipientDb) {
        Fail "Source and recipient endpoints resolve to the same host/port/database. Aborting for safety."
    }

    if (-not ($restoreJobs -as [int]) -or [int]$restoreJobs -lt 1) {
        Fail "RESTORE_JOBS must be an integer >= 1. Current value: $restoreJobs"
    }

    Write-Step "Checking PostgreSQL client tools"
    $pgDump = Get-PgTool -Name 'pg_dump' -BinDir $pgBinDir
    $pgRestore = Get-PgTool -Name 'pg_restore' -BinDir $pgBinDir
    $psql = Get-PgTool -Name 'psql' -BinDir $pgBinDir

    Write-Host "pg_dump:    $pgDump"
    Write-Host "pg_restore: $pgRestore"
    Write-Host "psql:       $psql"

    $backupDir = Join-Path $scriptDir 'backups'
    if (-not (Test-Path -LiteralPath $backupDir)) {
        New-Item -ItemType Directory -Path $backupDir | Out-Null
    }

    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $dumpFile = Join-Path $backupDir ("{0}_{1}.dump" -f $sourceDb, $timestamp)

    Write-Step "Step 1/3: Dumping source database (READ-ONLY) to $dumpFile"
    $env:PGPASSWORD = $sourcePassword
    $hadSourceSsl = $false
    $previousSourceSsl = $null
    try {
        if (-not [string]::IsNullOrWhiteSpace($sourceSslMode)) {
            $hadSourceSsl = Test-Path Env:PGSSLMODE
            if ($hadSourceSsl) {
                $previousSourceSsl = $env:PGSSLMODE
            }
            $env:PGSSLMODE = $sourceSslMode
        }

        $dumpArgs = @(
            '--host', $sourceHost,
            '--port', $sourcePort,
            '--username', $sourceUser,
            '--dbname', $sourceDb,
            '--format=custom',
            '--file', $dumpFile,
            '--verbose',
            '--no-password'
        )

        Run-Checked -Exe $pgDump -CommandArgs $dumpArgs
    }
    finally {
        Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
        if (-not [string]::IsNullOrWhiteSpace($sourceSslMode)) {
            if ($hadSourceSsl) {
                $env:PGSSLMODE = $previousSourceSsl
            }
            else {
                Remove-Item Env:PGSSLMODE -ErrorAction SilentlyContinue
            }
        }
    }

    Write-Step "Step 2/3: Verifying recipient database '$recipientDb' already exists"
    if (-not (Test-DatabaseExists -Psql $psql -DbHost $recipientHost -Port $recipientPort -Database $recipientDb -User $recipientUser -Password $recipientPassword -SslMode $recipientSslMode)) {
        Fail "Recipient database '$recipientDb' is not reachable or does not exist on ${recipientHost}:$recipientPort."
    }

    Write-Step "Step 3/3: Restoring dump into recipient database '$recipientDb'"
    $env:PGPASSWORD = $recipientPassword
    $hadRecipientSsl = $false
    $previousRecipientSsl = $null
    try {
        if (-not [string]::IsNullOrWhiteSpace($recipientSslMode)) {
            $hadRecipientSsl = Test-Path Env:PGSSLMODE
            if ($hadRecipientSsl) {
                $previousRecipientSsl = $env:PGSSLMODE
            }
            $env:PGSSLMODE = $recipientSslMode
        }

        $restoreArgs = @(
            '--host', $recipientHost,
            '--port', $recipientPort,
            '--username', $recipientUser,
            '--dbname', $recipientDb,
            '--clean',
            '--if-exists',
            '--no-owner',
            '--no-privileges',
            '--exit-on-error',
            '--verbose',
            '--jobs', $restoreJobs,
            '--no-password',
            $dumpFile
        )
        Run-Checked -Exe $pgRestore -CommandArgs $restoreArgs
    }
    finally {
        Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
        if (-not [string]::IsNullOrWhiteSpace($recipientSslMode)) {
            if ($hadRecipientSsl) {
                $env:PGSSLMODE = $previousRecipientSsl
            }
            else {
                Remove-Item Env:PGSSLMODE -ErrorAction SilentlyContinue
            }
        }
    }

    Write-Step "Database copy completed successfully"
    Write-Host "Recipient database refreshed: $recipientDb (${recipientHost}:$recipientPort)"
    Write-Host "Dump kept on disk: $dumpFile"
    exit 0
}
catch {
    Write-Error $_
    exit 1
}
