/*
================================================================================
  OLA HALLENGREN & DBATOOLS — ENTERPRISE LIVE DEMO SCRIPT
  Presenter: Penny | Date: May 22, 2026 | ~10 min
  Tip: Use @Execute = 'N' on any block to preview without running.
================================================================================
*/

-- ============================================================================
-- SECTION 1: VERIFY INSTALLATION
-- Quick sanity check — confirms all 4 SPs and CommandLog in one shot.
-- ============================================================================

SELECT name AS [Object], 'Stored Procedure' AS [Type]
FROM master.sys.objects
WHERE type = 'P'
  AND name IN ('DatabaseBackup','DatabaseIntegrityCheck','IndexOptimize','CommandExecute')
UNION ALL
SELECT TABLE_NAME, 'Table'
FROM master.INFORMATION_SCHEMA.TABLES
WHERE TABLE_NAME = 'CommandLog';
-- Expected: 5 rows total. Any missing = re-run MaintenanceSolution.sql


-- ============================================================================
-- SECTION 2: FULL BACKUP
-- Compressed, verified FULL backup of all user databases.
-- ============================================================================

EXECUTE master.dbo.DatabaseBackup
    @Databases  = 'USER_DATABASES', 
    @Directory  = 'C:\DropZone', 
    @BackupType = 'FULL',
    @Verify     = 'Y',
    @Compress   = 'Y',
    @CheckSum   = 'Y',
    @LogToTable = 'Y',
    @Execute    = 'Y';              -- Change to 'N' for dry-run preview


-- ============================================================================
-- SECTION 3: INTEGRITY CHECK
-- Wraps DBCC CHECKDB with two modes — physical-only nightly, full weekly.
--
-- PHYSICAL-ONLY ('Y') — checks the storage layer:
--   - Page checksums:   Detects silent disk/hardware corruption (bit rot, bad sectors)
--   - Torn pages:       Catches incomplete I/O operations from sudden power failure
--
-- * CRITICAL NOTE: REGULAR SQL BACKUPS DO NOT DO THIS INTEGRITY CHECK *
-- ============================================================================

EXECUTE master.dbo.DatabaseIntegrityCheck
    @Databases     = 'USER_DATABASES',
    @CheckCommands = 'CHECKDB',
    @PhysicalOnly  = 'Y',            -- Change to 'N' for full logical check
    @LogToTable    = 'Y',
    @Execute       = 'Y';


-- ============================================================================
-- SECTION 4: INDEX OPTIMIZE
-- Smart maintenance — reorganizes or rebuilds based on fragmentation levels.
-- 
-- Talking Points: 
--   - Avoids unnecessary rebuilds, preserving transaction log space.
--   - Update Statistics fixes bad query plans, slow queries, poor join paths,
--     outdated cardinality estimates, and parameter sniffing bugs.
-- ============================================================================

EXECUTE master.dbo.IndexOptimize
    @Databases           = 'USER_DATABASES',
    @FragmentationLevel1 = 5,
    @FragmentationLevel2 = 30,
    @UpdateStatistics    = NULL, -- instead of 'ALL'
    @LogToTable          = 'Y',
    @Execute             = 'Y';

-- Maybe update Stats job here so i don't bog down production server
    EXECUTE master.dbo.IndexOptimize
    @Databases                  = 'USER_DATABASES',
    @FragmentationLow           = NULL,  -- Ignore index fragmentation completely
    @FragmentationMedium        = NULL,
    @FragmentationHigh          = NULL,
    @UpdateStatistics           = 'ALL', -- Tell it to look at stats now
    @OnlyModifiedStatistics     = 'Y',   -- Only touch stats if data has actually changed
    @StatisticsModificationLevel = 1,     -- Target tables with > 1% data changes
    @LogToTable                 = 'Y',
    @Execute                    = 'Y';



-- ============================================================================
-- SECTION 5: COMMANDLOG REVIEW
-- Single source of truth for all maintenance activity.
-- Zero rows in the errors query = clean run — great talking point!
-- ============================================================================

-- Recent activity (last 7 days)
SELECT DatabaseName, CommandType, Command,
       StartTime, EndTime,
       DATEDIFF(SECOND, StartTime, EndTime) AS [DurationSec],
       ErrorNumber, ErrorMessage
FROM master.dbo.CommandLog
WHERE StartTime >= DATEADD(DAY, -1, GETDATE())
ORDER BY StartTime DESC;

-- Errors only — 30-day window (zero rows = clean run)
SELECT DatabaseName, CommandType, StartTime, ErrorNumber, ErrorMessage
FROM master.dbo.CommandLog
WHERE ErrorNumber <> 0
  AND StartTime   >= DATEADD(DAY, -30, GETDATE())
ORDER BY StartTime DESC;


-- ============================================================================
-- SECTION 6: CLEANUP
-- @CleanupTime removes old backup files AFTER the new backup completes.
-- CommandLog DELETE keeps the history table lean.
-- ============================================================================

-- Backup with built-in file cleanup: removes FULL backups older than 48 hours
EXECUTE master.dbo.DatabaseBackup
    @Databases   = 'USER_DATABASES',
    @Directory   = 'C:\DropZone',
    @BackupType  = 'FULL',
    @Compress    = 'Y',
    @CheckSum    = 'Y',
    @CleanupTime = 48,               -- Hours; new backup succeeds BEFORE old deletes
    @LogToTable  = 'Y',
    @Execute     = 'Y';

-- Trim CommandLog rows older than 30 days
DELETE FROM master.dbo.CommandLog
WHERE StartTime < DATEADD(DAY, -30, GETDATE());
SELECT @@ROWCOUNT AS [LogsHistoryRowsDeleted];


-- ============================================================================
-- SECTION 7: RECOVERY & DISASTER RECOVERY (ENTERPRISE PIPELINE)
-- Talking Points:
--   - Native SQL requires managing multi-file recovery chains manually.
--   - dbatools handles timeline reconstruction (FULL -> DIFF -> LOG) automatically.
--   - The following script runs in PowerShell to orchestrate the demo safely.
-- ============================================================================

/* COPY AND RUN THE BELOW CODE IN POWERSHELL TO EXECUTE STAGE 1 & 2:

<#
====================================================================
🚀 WHY USE DBATOOLS? (ENTERPRISE ADVANTAGES)
====================================================================
1. AUTOMATED TIMELINE RECONSTRUCTION: 
   dbatools natively understands Ola Hallengren's directory tree. 
   Instead of writing complex code to loop through files, it reads 
   LSNs (Log Sequence Numbers) inside headers, automatically sorting 
   and applying FULL -> DIFF -> LOGs in perfect chronological order.

2. LOG CHAIN PROTECTION (-CopyOnly):
   Takes full emergency backups without breaking production differential 
   baselines or interrupting transactional log backup chains.

3. CONCURRENCY MANAGEMENT (-DisconnectCode):
   Automatically severs active database connections and handles multi-user 
   locks instantly, preventing "file in use" restore hangs.

4. SAFETY & EFFICIENCY:
   Replaces hundreds of lines of complex T-SQL and native SMO 
   PowerShell with clean, readable, single-line commands.
====================================================================
#>

Set-DbatoolsConfig -Name 'sql.connection.trustcert' -Value $true

# VARIABLES
$TargetServer      = "DESKTOP-LQEABPI\TEST"
$SourceOfTruthDB   = "AWL"                
$TargetDB          = "TestDB_Normal"      

$BackupRoot        = "C:\DropZone"
$SafetyFolder      = "$BackupRoot\SafetyNet"  
$SourceFilesFolder = "$BackupRoot\DESKTOP-LQEABPI`$TEST\$SourceOfTruthDB"

$NewDataDir        = "C:\Program Files\Microsoft SQL Server\MSSQL16.TEST\MSSQL\DATA\Restores\$TargetDB"

# PREPARATION
New-Item -ItemType Directory -Force -Path $SafetyFolder
New-Item -ItemType Directory -Force -Path $NewDataDir

# 1. DEMO STAGE 1: Back up the TRUE Production Database
Write-Host "Taking SAFE copy-only backup of source of truth ($SourceOfTruthDB)..." -ForegroundColor Yellow
Backup-DbaDatabase -SqlInstance $TargetServer `
                   -Database $SourceOfTruthDB `
                   -Type Full `
                   -BackupDirectory $SafetyFolder `
                   -CreateFolder:$false `
                   -CopyOnly              

# 2. DEMO STAGE 2: Sweep all Ola folders dynamically
Write-Host "Sweeping all Ola Hallengren folders to restore ($TargetDB)..." -ForegroundColor Red
Restore-DbaDatabase -SqlInstance $TargetServer `
                    -DatabaseName $TargetDB `
                    -Path $SourceFilesFolder `
                    -MaintenanceSolutionBackup `
                    -DestinationDataDirectory $NewDataDir `
                    -DestinationLogDirectory $NewDataDir `
                    -WithReplace `
                    -Confirm:$false `
                
*/


-- ============================================================================
-- SECTION 8: POST-DEPLOYMENT VERIFICATION & AUDIT LOGS
-- Query msdb to prove the exact backup file, time, type, and user account
-- that performed the restore operation during our demo.
-- ============================================================================

SELECT 
    destination_database_name AS [Target Database], 
    bmf.physical_device_name AS [Source Backup File Used],
    restore_date AS [Event Logged / Restore Time], 
    r.user_name AS [Executed By User Account],                  
    b.backup_start_date AS [Backup Creation Timestamp],
    CASE r.restore_type
        WHEN 'D' THEN 'Full Database Restore'
        WHEN 'I' THEN 'Differential Restore'
        WHEN 'L' THEN 'Transaction Log Restore'
    END AS [Restore Operation Type]
FROM msdb.dbo.restorehistory r
INNER JOIN msdb.dbo.backupset b ON r.backup_set_id = b.backup_set_id
INNER JOIN msdb.dbo.backupmediafamily bmf ON b.media_set_id = bmf.media_set_id
WHERE destination_database_name = 'TestDB_Normal'
ORDER BY restore_date DESC;


-- ============================================================================
-- SECTION 9: DATA VALIDATION & ROW-COUNT COMPARISON
-- A side-by-side snapshot comparison of our Source of Truth vs. our Sandbox.
-- Uses metadata partitions and filters out dynamic background Query Store tables.
-- ============================================================================

WITH ProdRows AS (
    SELECT OBJECT_NAME(object_id, DB_ID('AWL')) AS [TableName], SUM(rows) AS [ProdCount]
    FROM AWL.sys.partitions
    WHERE index_id IN (0,1) -- Heap or Clustered Index base data rows
    GROUP BY object_id
),
TestRows AS (
    SELECT OBJECT_NAME(object_id, DB_ID('TestDB_Normal')) AS [TableName], SUM(rows) AS [TestCount]
    FROM TestDB_Normal.sys.partitions
    WHERE index_id IN (0,1)
    GROUP BY object_id
)
SELECT 
    ISNULL(p.TableName, t.TableName) AS [Table Name],
    ISNULL(p.ProdCount, 0) AS [AWL (Production) Rows],
    ISNULL(t.TestCount, 0) AS [TestDB_Normal (Sandbox) Rows],
    CASE 
        WHEN ISNULL(p.ProdCount, 0) = ISNULL(t.TestCount, 0) THEN 'MATCH'
        ELSE 'MISMATCH'
    END AS [Status]
FROM ProdRows p
FULL OUTER JOIN TestRows t ON p.TableName = t.TableName
WHERE ISNULL(p.TableName, t.TableName) NOT LIKE 'sys%'             -- Exclude basic system views
  AND ISNULL(p.TableName, t.TableName) NOT LIKE 'plan_persist%'     -- Exclude dynamic Query Store tables
  AND ISNULL(p.TableName, t.TableName) NOT LIKE 'queue_messages%'   -- Exclude Service Broker queues
ORDER BY [Table Name];