/* =====================================================================================================
   diag_io_waits.sql  -  Diagnose von "db file sequential read" (und User-I/O allgemein) - Oracle 11gR2+

   Begleitet docs/TUNING.md, Abschnitt "Oracle: db file sequential read". Nur lesend.
   Ausfuehren als DBA (SELECT_CATALOG_ROLE genuegt fuer Teil A).

   Teil A  V$-Views          lizenzfrei, kumuliert seit Instanzstart bzw. aktueller Zustand
   Teil B  AWR / ASH         NUR mit Lizenz "Oracle Diagnostics Pack" (Enterprise Edition)!
   Teil C  SQL-Trace (10046) einer Informatica-Session, lizenzfrei

   Faustregel fuer die mittlere Dauer EINES Single-Block-Reads:
     < 1 ms   Flash/NVMe          1-5 ms  SSD-SAN, gut          5-10 ms  HDD/SAN, akzeptabel
     > 20 ms  Speicherproblem    > 100 ms schwerwiegend         2000+ ms Infrastruktur, nicht SQL
   ===================================================================================================== */


/* ============================== Teil A: V$-Views (lizenzfrei) ====================================== */

-- A1. User-I/O-Events systemweit: Anzahl, Summe, mittlere Dauer -------------------------------------------
SELECT event,
       total_waits,
       ROUND(time_waited_micro / 1e6)                                AS sekunden_gesamt,
       ROUND(time_waited_micro / NULLIF(total_waits, 0) / 1000, 2)   AS avg_ms
FROM v$system_event
WHERE wait_class = 'User I/O'
ORDER BY time_waited_micro DESC;

-- A2. Verteilung der Wartezeiten: wie viele Reads dauern 2 s, 4 s, ... ? ---------------------------------
--     WAIT_TIME_MILLI = Obergrenze des Bereichs (z.B. 2048 = 1024 bis < 2048 ms).
--     Wenige extreme Ausreisser bei sonst guten Werten -> Spitzen in der Infrastruktur (Backup, AV-Scan, VM).
--     Breiter Buckel bei hohen Werten -> Speicher dauerhaft ueberlastet.
SELECT wait_time_milli                                          AS bis_ms,
       wait_count                                               AS anzahl,
       ROUND(100 * RATIO_TO_REPORT(wait_count) OVER (), 2)      AS prozent
FROM v$event_histogram
WHERE event = 'db file sequential read'
ORDER BY wait_time_milli;

-- A3. Latenz je Datendatei: ist es eine einzelne Datei / ein LUN / ein Mountpoint? ----------------------
--     SINGLEBLKRDTIM ist in Hundertstelsekunden -> * 10 = ms. Erfordert TIMED_STATISTICS = TRUE.
SELECT d.name                                                         AS datei,
       t.name                                                         AS tablespace,
       f.singleblkrds                                                 AS single_block_reads,
       ROUND(f.singleblkrdtim * 10 / NULLIF(f.singleblkrds, 0), 2)    AS avg_ms,
       f.phyrds                                                       AS reads_gesamt,
       f.phywrts                                                      AS writes_gesamt
FROM v$filestat f
JOIN v$datafile d   ON d.file# = f.file#
JOIN v$tablespace t ON t.ts# = d.ts#
WHERE f.singleblkrds > 0
ORDER BY avg_ms DESC;

-- A4. Segmente mit den meisten physischen Reads (Tabellen, Indizes, Partitionen) ------------------------
SELECT *
FROM (SELECT owner, object_name, subobject_name, object_type, value AS physical_reads
      FROM v$segment_statistics
      WHERE statistic_name = 'physical reads'
      ORDER BY value DESC)
WHERE ROWNUM <= 30;

-- A5. SQL mit der hoechsten I/O-Wartezeit - Informatica-SQL erkennt man an MODULE/PROGRAM -----------------
--     reads_pro_exec hoch + executions hoch = typisch fuer ungecachte Lookups / Update je Zeile.
SELECT *
FROM (SELECT sql_id,
             child_number,
             module,
             executions,
             ROUND(user_io_wait_time / 1e6)                                   AS io_wait_s,
             ROUND(elapsed_time / 1e6)                                        AS elapsed_s,
             physical_read_requests,
             ROUND(physical_read_requests / NULLIF(executions, 0), 1)         AS reads_pro_exec,
             ROUND(user_io_wait_time / NULLIF(physical_read_requests, 0) / 1000, 2) AS avg_ms_pro_read,
             SUBSTR(sql_text, 1, 200)                                         AS sql_text
      FROM v$sql
      ORDER BY user_io_wait_time DESC)
WHERE ROWNUM <= 30;

-- A6. Laufende Informatica-Sessions (pmdtm): worauf warten sie gerade? ----------------------------------
--     Bei 'db file sequential read': P1 = Datei-Nr., P2 = Block-Nr. -> Objekt mit A8 ermitteln.
SELECT s.sid,
       s.serial#,
       s.username,
       s.program,
       s.module,
       s.sql_id,
       s.event,
       s.state,
       ROUND(s.wait_time_micro / 1000) AS dauer_ms,
       s.p1                            AS datei_nr,
       s.p2                            AS block_nr
FROM v$session s
WHERE UPPER(s.program) LIKE '%PMDTM%'
ORDER BY s.wait_time_micro DESC;

-- A7. Summen je Informatica-Session seit Anmeldung -------------------------------------------------------
--     MAX_WAIT ist in Hundertstelsekunden -> * 10 = ms.
--     'SQL*Net message from client' = Datenbank wartet auf Informatica (Engpass liegt dann nicht in Oracle).
SELECT s.sid,
       s.program,
       s.module,
       e.event,
       e.total_waits,
       ROUND(e.time_waited_micro / 1e6)                              AS sekunden,
       ROUND(e.time_waited_micro / NULLIF(e.total_waits, 0) / 1000, 2) AS avg_ms,
       e.max_wait * 10                                               AS max_ms
FROM v$session_event e
JOIN v$session s ON s.sid = e.sid
WHERE e.event IN ('db file sequential read', 'db file scattered read', 'direct path read',
                  'SQL*Net message from client')
  AND UPPER(s.program) LIKE '%PMDTM%'
ORDER BY s.sid, e.time_waited_micro DESC;

-- A8. Datei/Block (aus A6, P1/P2) -> Segment. Auf grossen Datenbanken langsam, gezielt einsetzen. ------
SELECT owner, segment_name, partition_name, segment_type, tablespace_name
FROM dba_extents
WHERE file_id = :datei_nr
  AND :block_nr BETWEEN block_id AND block_id + blocks - 1;

-- A9. Betriebssystem aus Sicht der Datenbank: CPU-Last und Paging ---------------------------------------
--     Hohe LOAD (> NUM_CPUS) verlaengert JEDE gemessene Wartezeit (Prozess wartet nach dem I/O auf CPU).
--     VM_IN_BYTES / VM_OUT_BYTES > 0 und wachsend = Server lagert aus (SGA/PGA im Pagefile).
SELECT stat_name, value
FROM v$osstat
WHERE stat_name IN ('NUM_CPUS', 'NUM_CPU_CORES', 'LOAD', 'BUSY_TIME', 'IDLE_TIME', 'IOWAIT_TIME',
                    'PHYSICAL_MEMORY_BYTES', 'FREE_MEMORY_BYTES', 'VM_IN_BYTES', 'VM_OUT_BYTES')
ORDER BY stat_name;

-- A10. Parameter, die Zugriffspfade und I/O beeinflussen (ISDEFAULT = FALSE genau ansehen) -------------
SELECT name, value, isdefault, ismodified
FROM v$parameter
WHERE name IN ('optimizer_index_cost_adj', 'optimizer_index_caching', 'optimizer_mode',
               'db_file_multiblock_read_count', 'db_cache_size', 'db_keep_cache_size',
               'sga_target', 'sga_max_size', 'memory_target', 'pga_aggregate_target',
               'disk_asynch_io', 'filesystemio_options', 'use_large_pages', 'lock_sga',
               'statistics_level', 'timed_statistics', 'db_writer_processes',
               'parallel_max_servers', 'parallel_degree_policy', 'cursor_sharing', 'db_block_size')
ORDER BY name;

-- A11. Buffer-Cache-Advice: wie viele physische Reads spart ein groesserer Cache? -----------------------
--     ESTD_PHYSICAL_READ_FACTOR 0.4 bei SIZE_FACTOR 2 = doppelter Cache -> 60 % weniger physische Reads.
SELECT size_for_estimate          AS cache_mb,
       size_factor,
       estd_physical_read_factor,
       estd_physical_reads
FROM v$db_cache_advice
WHERE name = 'DEFAULT'
  AND advice_status = 'ON'
  AND block_size = (SELECT TO_NUMBER(value) FROM v$parameter WHERE name = 'db_block_size')
ORDER BY size_for_estimate;

-- A12. Indizes einer Tabelle: Clustering Factor und Aktualitaet der Statistiken ---------------------------
--     CLUSTERING_FACTOR nahe NUM_ROWS (statt nahe BLOCKS) = Range-Scans lesen fast je Zeile einen Block.
SELECT i.index_name,
       i.uniqueness,
       i.blevel,
       i.leaf_blocks,
       i.clustering_factor,
       t.blocks                AS tabellen_bloecke,
       t.num_rows,
       i.last_analyzed,
       t.last_analyzed         AS tabelle_analysiert
FROM dba_indexes i
JOIN dba_tables t ON t.owner = i.table_owner AND t.table_name = i.table_name
WHERE i.table_owner = UPPER(:owner)
  AND i.table_name  = UPPER(:tabelle)
ORDER BY i.index_name;

-- A13. Zeilenverkettung: 'table fetch continued row' verursacht zusaetzliche Single-Block-Reads ----------
SELECT name, value
FROM v$sysstat
WHERE name IN ('table fetch continued row', 'table fetch by rowid', 'physical reads', 'physical reads cache',
               'physical read total IO requests', 'physical read total multi block requests');


/* ======================= Teil B: AWR / ASH - NUR mit Diagnostics-Pack-Lizenz ======================= */

-- B1. Verlauf je AWR-Snapshot: Anzahl und mittlere Dauer von db file sequential read ---------------------
--     Zeigt, ob die 2000-ms-Werte nur im ETL-Fenster auftreten (Last) oder dauerhaft (Infrastruktur).
SELECT sn.instance_number,
       sn.begin_interval_time,
       d.waits,
       ROUND(d.us / NULLIF(d.waits, 0) / 1000, 2) AS avg_ms
FROM (SELECT e.dbid, e.instance_number, e.snap_id,
             e.total_waits
               - LAG(e.total_waits) OVER (PARTITION BY e.dbid, e.instance_number ORDER BY e.snap_id) AS waits,
             e.time_waited_micro
               - LAG(e.time_waited_micro) OVER (PARTITION BY e.dbid, e.instance_number ORDER BY e.snap_id) AS us
      FROM dba_hist_system_event e
      WHERE e.event_name = 'db file sequential read'
        AND e.dbid = (SELECT dbid FROM v$database)) d
JOIN dba_hist_snapshot sn
  ON sn.dbid = d.dbid AND sn.instance_number = d.instance_number AND sn.snap_id = d.snap_id
WHERE d.waits > 0                                   -- negative Deltas nach Instanz-Neustart ausblenden
  AND sn.begin_interval_time > SYSDATE - 7
ORDER BY sn.instance_number, sn.snap_id;

-- B2. Latenz je Datei und Snapshot (ein LUN / ein Pfad langsam?) ------------------------------------------
SELECT sn.begin_interval_time,
       d.tsname,
       d.filename,
       d.reads,
       ROUND(d.cs * 10 / NULLIF(d.reads, 0), 2) AS avg_ms
FROM (SELECT f.dbid, f.instance_number, f.snap_id, f.tsname, f.filename,
             f.singleblkrds
               - LAG(f.singleblkrds) OVER (PARTITION BY f.dbid, f.instance_number, f.file# ORDER BY f.snap_id) AS reads,
             f.singleblkrdtim
               - LAG(f.singleblkrdtim) OVER (PARTITION BY f.dbid, f.instance_number, f.file# ORDER BY f.snap_id) AS cs
      FROM dba_hist_filestatxs f
      WHERE f.dbid = (SELECT dbid FROM v$database)) d
JOIN dba_hist_snapshot sn
  ON sn.dbid = d.dbid AND sn.instance_number = d.instance_number AND sn.snap_id = d.snap_id
WHERE d.reads > 0
  AND sn.begin_interval_time > SYSDATE - 2
ORDER BY avg_ms DESC;

-- B3. ASH: welche SQL / welche Objekte verursachen die Waits der Informatica-Sessions? -----------------
--     Zeitfenster anpassen. TIME_WAITED ist in Mikrosekunden und nur im letzten Sample eines Waits gefuellt.
--     Fuer aeltere Zeitraeume v$active_session_history durch dba_hist_active_sess_history ersetzen.
SELECT ash.sql_id,
       ash.current_obj#,
       o.owner,
       o.object_name,
       o.object_type,
       COUNT(*)                                                         AS samples,
       ROUND(AVG(NULLIF(ash.time_waited, 0)) / 1000)                    AS avg_ms,
       ROUND(MAX(ash.time_waited) / 1000)                               AS max_ms
FROM v$active_session_history ash
LEFT JOIN dba_objects o ON o.object_id = ash.current_obj#
WHERE ash.event = 'db file sequential read'
  AND UPPER(ash.program) LIKE '%PMDTM%'
  AND ash.sample_time > SYSDATE - 1/24                                  -- letzte Stunde
GROUP BY ash.sql_id, ash.current_obj#, o.owner, o.object_name, o.object_type
ORDER BY samples DESC;

-- B4. ASH: was lief zeitgleich mit den langen Waits? (Backups, Statistiklaeufe, andere Programme) ---------
SELECT TRUNC(ash.sample_time, 'MI')                    AS minute,
       ash.program,
       ash.event,
       COUNT(*)                                        AS aktive_sessions
FROM v$active_session_history ash
WHERE ash.sample_time > SYSDATE - 1/24
  AND ash.wait_class IN ('User I/O', 'System I/O')
GROUP BY TRUNC(ash.sample_time, 'MI'), ash.program, ash.event
ORDER BY minute, aktive_sessions DESC;


/* =========================== Teil C: SQL-Trace einer Informatica-Session ========================== */
/*
   Variante 1 - laufende Session (SID/SERIAL# aus A6):
     EXEC DBMS_MONITOR.SESSION_TRACE_ENABLE(session_id => :sid, serial_num => :serial, waits => TRUE, binds => FALSE);
     -- Session eine Weile laufen lassen --
     EXEC DBMS_MONITOR.SESSION_TRACE_DISABLE(session_id => :sid, serial_num => :serial);

   Variante 2 - ab Start der Informatica-Session: in der Relational Connection (Workflow Manager) unter
   "Connection Environment SQL" eintragen (danach wieder entfernen!):
     ALTER SESSION SET tracefile_identifier = 'INFA_TRACE';
     ALTER SESSION SET events '10046 trace name context forever, level 8';

   Trace-Datei liegt im Verzeichnis aus:  SELECT value FROM v$diag_info WHERE name = 'Diag Trace';
   Auswerten:  tkprof <datei>.trc ausgabe.txt sys=no sort=exeela,fchela
   In der Trace-Datei steht je Wait eine Zeile:  WAIT #...: nam='db file sequential read' ela= 2134567 file#=7 block=12345 blocks=1
   (ela in Mikrosekunden) - damit lassen sich die langsamen Reads Datei und Objekt genau zuordnen.
*/
