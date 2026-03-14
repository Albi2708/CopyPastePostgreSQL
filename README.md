# PostgreSQL One-Shot Database Copy (Windows)

This folder contains a reusable one-shot workflow to copy a **source PostgreSQL database** into an existing **recipient PostgreSQL database**.

It is designed to be safe for the source database:
- The source database is accessed only by `pg_dump` (read-only extraction).
- Destructive restore actions happen only on the recipient database.

## What this workflow does

`clone-postgres.ps1` performs these steps in order:

1. Load `.env` config and validate required values.
2. Verify PostgreSQL client tools are available (`pg_dump`, `pg_restore`, `psql`).
3. Create a timestamped custom-format dump file (`.dump`) in `backups/`.
4. Verify the recipient database already exists and is reachable.
5. Restore the dump into the recipient database using `pg_restore`.

It keeps the dump file on disk after success.

## What this workflow does NOT do

- It does not schedule recurring backups.
- It does not sync incrementally.
- It does not create the recipient database.
- It does not manage Docker or infrastructure.

## Files

- `clone-postgres.ps1`: Main database copy workflow script.
- `install-pg-tools.ps1`: Helper to install PostgreSQL client tools on Windows.
- `backups/`: Created automatically; stores dump artifacts.

## Prerequisites

- Windows PowerShell.
- Network reachability from your machine to both PostgreSQL servers.
- PostgreSQL client tools installed on Windows.
- The recipient database already exists before running the script.

## Install PostgreSQL client tools on Windows

If tools are missing, use one of these options:

1. Winget:
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\install-pg-tools.ps1 -Method winget
   ```

2. Chocolatey:
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\install-pg-tools.ps1 -Method choco
   ```

3. Manual:
   - Download installer from https://www.postgresql.org/download/windows/
   - Install PostgreSQL 17.x (or compatible).
   - Ensure tools are in `PATH`, or set `PG_BIN_DIR` in `.env` (example: `C:\Program Files\PostgreSQL\17\bin`).

## Configure

Edit `.env` and fill:

- `SOURCE_PGHOST`
- `SOURCE_PGPORT`
- `SOURCE_PGDATABASE`
- `SOURCE_PGUSER`
- `SOURCE_PGPASSWORD`
- `SOURCE_PGSSLMODE` if required by the source server
- `RECIPIENT_PGHOST`
- `RECIPIENT_PGPORT`
- `RECIPIENT_PGDATABASE`
- `RECIPIENT_PGUSER`
- `RECIPIENT_PGPASSWORD`
- `RECIPIENT_PGSSLMODE` if required by the recipient server
- `PG_BIN_DIR` only if tools are not in `PATH`

## Run manually

Run from this folder:

```powershell
powershell -ExecutionPolicy Bypass -File .\clone-postgres.ps1 -EnvFile .\.env
```

## Expected result

On success:
- A new dump file exists in `backups\` named like `yourdb_YYYYMMDD_HHMMSS.dump`.
- The existing recipient database is refreshed using the source dump.
- Output shows completion and dump file path.

## Important caveats

- The recipient database must already exist. The script will fail if it does not.
- The restore uses `pg_restore --clean --if-exists`, which removes objects present in the dump before recreating them.
- Because the database itself is not dropped and recreated, recipient-side objects that are not part of the source dump can remain.
- Extensions: restore may require the same extensions available on the recipient server.
- Ownership/privileges: restore uses `--no-owner --no-privileges` to avoid role mismatch issues; objects are created under the recipient restore user context.
- Large DBs: dump/restore can take significant time and disk space.
- Safety guardrail: the script aborts if source and recipient resolve to the same host, port, and database.

## Source safety guarantee

The workflow never runs restore commands against source settings.
Source connection details are used only for `pg_dump` to read and export data.
