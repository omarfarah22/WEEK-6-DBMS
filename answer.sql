@echo off
setlocal enabledelayedexpansion
title PostgreSQL Docker Lab: Steps 1-3 (Backup, Archiving, PITR)

:: =====================================================================
:: SETUP: Define backup directory
:: =====================================================================
set "BACKUP_DIR=%USERPROFILE%\backups"
if not exist "%BACKUP_DIR%" mkdir "%BACKUP_DIR%"

:: =====================================================================
:: STEP 1: Take and Verify a Logical Backup
:: =====================================================================
echo ==========================================
echo STEP 1: Logical Backup and Verification
echo ==========================================
echo.

echo [1/4] Taking logical backup of 'bootcamp' database...
docker exec -it pg pg_dump -Fc -U postgres -f /tmp/bootcamp.dump bootcamp

echo [2/4] Copying backup to Windows...
docker cp pg:/tmp/bootcamp.dump "%BACKUP_DIR%\bootcamp.dump"

echo [3/4] Creating scratch database 'bootcamp_check' and restoring...
docker exec -it pg createdb -U postgres bootcamp_check
docker exec -it pg pg_restore -U postgres -d bootcamp_check /tmp/bootcamp.dump

echo [4/4] Verifying restore (checking for tables)...
docker exec -it pg psql -U postgres -d bootcamp_check -c "\dt"

echo.
echo Cleaning up scratch database...
docker exec -it pg dropdb -U postgres bootcamp_check
echo ✅ Step 1 Complete!
echo.

:: =====================================================================
:: STEP 2: Enable WAL Archiving and Take a Base Backup
:: =====================================================================
echo ==========================================
echo STEP 2: WAL Archiving and Base Backup
echo ==========================================
echo.

echo [1/4] Configuring postgresql.conf for WAL archiving...
:: Using sed to edit the file inside the container to avoid nano/vi rendering issues
docker exec -u root pg bash -c "sed -i 's/#archive_mode = off/archive_mode = on/' /var/lib/postgresql/data/postgresql.conf"
docker exec -u root pg bash -c "sed -i \"s|#archive_command = ''|archive_command = 'cp %%p /tmp/wal_archive/%%f'|\" /var/lib/postgresql/data/postgresql.conf"
docker exec -u root pg bash -c "sed -i 's/#wal_level = replica/wal_level = replica/' /var/lib/postgresql/data/postgresql.conf"

echo [2/4] Creating WAL archive directory...
docker exec -u root pg bash -c "mkdir -p /tmp/wal_archive && chown postgres:postgres /tmp/wal_archive"

echo [3/4] Restarting PostgreSQL to apply changes...
docker restart pg
echo Waiting 10 seconds for database to boot...
timeout /t 10 /nobreak >nul
docker exec -it pg psql -U postgres -c "SHOW archive_mode;"

echo [4/4] Taking base backup...
docker exec -u postgres -it pg pg_basebackup -D /tmp/basebackup -Ft -z -Xs -P
echo Copying base backup to Windows...
docker cp pg:/tmp/basebackup "%BACKUP_DIR%\base"
echo ✅ Step 2 Complete!
echo.

:: =====================================================================
:: STEP 3: Simulate Disaster and PITR
:: =====================================================================
echo ==========================================
echo STEP 3: Simulate Disaster and PITR
echo ==========================================
echo.

echo [1/6] Recording current timestamp and simulating disaster...
docker exec -it pg psql -U postgres -d bootcamp -c "SELECT count(*) FROM students;"

:: Capture the exact timestamp from PostgreSQL into a Windows variable
for /f "delims=" %%a in ('docker exec -i pg psql -U postgres -d bootcamp -t -A -c "SELECT now();"') do set "TIMESTAMP=%%a"
echo.
echo 🚨 RECOVERY TARGET TIME CAPTURED: !TIMESTAMP!
echo.

echo Deleting all data from students table (simulating disaster)...
docker exec -it pg psql -U postgres -d bootcamp -c "DELETE FROM students;"
echo Verifying data is gone (should be 0):
docker exec -it pg psql -U postgres -d bootcamp -c "SELECT count(*) FROM students;"

echo.
echo [2/6] Stopping container and extracting base backup to Windows...
docker stop pg >nul
if exist "%BACKUP_DIR%\base_pitr" rd /s /q "%BACKUP_DIR%\base_pitr"
docker cp pg:/tmp/basebackup "%BACKUP_DIR%\base_pitr"
cd /d "%BACKUP_DIR%\base_pitr"
mkdir data
tar -xzf base.tar.gz -C data
tar -xzf pg_wal.tar.gz -C data\pg_wal

echo.
echo [3/6] Configuring recovery target files...
:: Append recovery settings to postgresql.auto.conf
echo restore_command = 'cp /tmp/wal_archive/%%f %%p' >> data\postgresql.auto.conf
echo recovery_target_time = '!TIMESTAMP!' >> data\postgresql.auto.conf
echo recovery_target_action = 'promote' >> data\postgresql.auto.conf

:: Create the recovery.signal file
type nul > data\recovery.signal

echo.
echo [4/6] Copying modified files back into Docker container...
docker cp data\. pg:/var/lib/postgresql/data/

echo [5/6] Starting PostgreSQL container (this triggers recovery)...
docker start pg >nul
echo Waiting 15 seconds for WAL replay...
timeout /t 15 /nobreak >nul

echo [6/6] Checking recovery logs...
docker logs pg | findstr /C:"recovery" /C:"restored log file" /C:"ready to accept connections"

echo.
echo ==========================================
echo Verifying recovered data...
echo ==========================================
docker exec -it pg psql -U postgres -d bootcamp -c "SELECT count(*) FROM students;"

echo.
echo 🎉 If the count matches the original number, PITR was successful!
echo ==========================================
pause


@echo off
setlocal enabledelayedexpansion
title Step 4: Streaming Standby Replica

:: =====================================================================
:: CONFIGURATION
:: =====================================================================
set "PRIMARY=pg"
set "STANDBY=pg_standby"
set "REPPASS=reppass"

echo ==========================================
echo STEP 4: Set Up a Streaming Standby
echo ==========================================
echo.

:: =====================================================================
:: PART 1: Create the replication role on the PRIMARY
:: =====================================================================
echo [1/6] Creating replication role on the primary...

:: Drop if it exists (idempotent), then create
docker exec -it %PRIMARY% psql -U postgres -c "DROP ROLE IF EXISTS replicator;"
docker exec -it %PRIMARY% psql -U postgres -c "CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD '%REPPASS%';"
echo Replication role created.
echo.

:: =====================================================================
:: PART 2: Configure pg_hba.conf on the PRIMARY to allow replication
:: =====================================================================
echo [2/6] Configuring pg_hba.conf on the primary for replication...

:: Append the replication rule if it isn't already there
docker exec -u root %PRIMARY% bash -c "grep -q 'host replication replicator' /var/lib/postgresql/data/pg_hba.conf || echo 'host replication replicator all md5' >> /var/lib/postgresql/data/pg_hba.conf"

:: Reload the config (no restart needed for pg_hba changes)
docker exec -it %PRIMARY% psql -U postgres -c "SELECT pg_reload_conf();"
echo pg_hba.conf updated and reloaded.
echo.

:: =====================================================================
:: PART 3: Prepare the standby data directory
:: =====================================================================
echo [3/6] Cleaning up any previous standby container...

:: Remove old standby container if it exists
docker rm -f %STANDBY% >nul 2>&1

:: Create a named volume for the standby's data directory
docker volume rm standby_data >nul 2>&1
docker volume create standby_data >nul
echo Volume 'standby_data' created.
echo.

:: =====================================================================
:: PART 4: Build the standby using pg_basebackup
:: =====================================================================
echo [4/6] Running pg_basebackup to seed the standby...

:: Start a temporary container that runs pg_basebackup to fill the volume
:: Uses PGPASSWORD so no interactive prompt is needed
docker run --rm ^
  --network container:%PRIMARY% ^
  -e PGPASSWORD=%REPPASS% ^
  -v standby_data:/var/lib/postgresql/data ^
  postgres:16 ^
  bash -c "pg_basebackup -h 127.0.0.1 -U replicator -D /var/lib/postgresql/data -R -P -X stream"

if %errorlevel% neq 0 (
  echo.
  echo ❌ pg_basebackup failed. Check the error above.
  pause
  exit /b 1
)
echo Base backup into standby volume completed.
echo.

:: =====================================================================
:: PART 5: Start the standby container
:: =====================================================================
echo [5/6] Starting the standby container...

docker run -d ^
  --name %STANDBY% ^
  --network container:%PRIMARY% ^
  -v standby_data:/var/lib/postgresql/data ^
  postgres:16 >nul

echo Waiting 15 seconds for standby to boot and start streaming...
timeout /t 15 /nobreak >nul
echo.

:: =====================================================================
:: PART 6: Verify streaming replication
:: =====================================================================
echo [6/6] Verifying replication status...
echo.

echo --- Replication status on PRIMARY (pg_stat_replication) ---
docker exec -it %PRIMARY% psql -U postgres -c "SELECT application_name, client_addr, state, sync_state, sent_lsn, replay_lsn FROM pg_stat_replication;"

echo.
echo --- Is the standby in recovery mode? (should be 't') ---
docker exec -it %STANDBY% psql -U postgres -c "SELECT pg_is_in_recovery();"

echo.
echo --- Creating test data on PRIMARY to prove replication works ---
docker exec -it %PRIMARY% psql -U postgres -d bootcamp -c "CREATE TABLE IF NOT EXISTS repl_test (id int, note text);"
docker exec -it %PRIMARY% psql -U postgres -d bootcamp -c "INSERT INTO repl_test VALUES (1, 'replicated!');"

echo.
echo --- Reading that data on the STANDBY ---
timeout /t 3 /nobreak >nul
docker exec -it %STANDBY% psql -U postgres -d bootcamp -c "SELECT * FROM repl_test;"

echo.
echo ==========================================
echo 🎉 If you see 'streaming' state and the test row on the standby,
echo    Step 4 is complete!
echo ==========================================
pause


@echo off
title Step 5: Watch Replication Health

echo ==========================================
echo STEP 5: Watch Replication Health
echo ==========================================
echo.

echo [1/4] Basic replication status...
docker exec -it pg psql -U postgres -c "SELECT application_name, state, pg_wal_lsn_diff(sent_lsn, replay_lsn) AS lag_bytes FROM pg_stat_replication;"
echo.

echo [2/4] Full health report...
docker exec -it pg psql -U postgres -c "SELECT application_name, client_addr, state, sync_state, sent_lsn, write_lsn, flush_lsn, replay_lsn, pg_wal_lsn_diff(sent_lsn, replay_lsn) AS lag_bytes, pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS total_lag_bytes FROM pg_stat_replication;"
echo.

echo [3/4] Generating WAL traffic on the primary...
docker exec -it pg psql -U postgres -d bootcamp -c "INSERT INTO repl_test SELECT generate_series(2,1000), 'generated data';"
echo Waiting 3 seconds for standby to catch up...
timeout /t 3 /nobreak >nul
echo.

echo [4/4] Lag after traffic generation...
docker exec -it pg psql -U postgres -c "SELECT now(), state, pg_wal_lsn_diff(sent_lsn, replay_lsn) AS lag_bytes FROM pg_stat_replication;"
echo.

echo --- Confirming standby received the new data ---
docker exec -it pg_standby psql -U postgres -d bootcamp -c "SELECT count(*) FROM repl_test;"
echo.

echo ==========================================
echo 🎉 If lag_bytes is 0 and the count matches on both sides,
echo    Step 5 is complete!
echo ==========================================
pause
