# Performance-Tuning: PowerCenter-Sessions und Oracle (`db file sequential read`)

Leitfaden fuer langsame PowerCenter-Sessions. Er beginnt beim Speicher des `pmdtm`-Prozesses (z.B. "nimmt nur
8 GB von 48 GB") und endet bei hohen Oracle-Waits `db file sequential read` von 2000 ms und mehr. Die
Diagnose-Abfragen fuer Oracle stehen in [`sql/oracle/diag_io_waits.sql`](../sql/oracle/diag_io_waits.sql);
Verweise wie **A3** oder **B2** beziehen sich auf die Abschnitte dort.

> **Vorgehen:** messen -> Engpass bestimmen -> **eine** Sache aendern -> erneut messen. Mehrere Aenderungen auf
> einmal machen das Ergebnis unbrauchbar. Aenderungen an Datenbank-Parametern, Storage und VM nur mit DBA bzw.
> Infrastruktur-Team und zuerst in einer Test-Umgebung.

## Inhalt

1. [Engpass finden](#1-engpass-finden)
2. [Speicher und Caches (`pmdtm` nutzt nur 8 GB)](#2-speicher-und-caches-pmdtm-nutzt-nur-8-gb)
3. [Windows-Server und VM](#3-windows-server-und-vm)
4. [Transformationen](#4-transformationen)
5. [Partitionierung und Pushdown](#5-partitionierung-und-pushdown)
6. [Lesen aus Oracle](#6-lesen-aus-oracle)
7. [Schreiben nach Oracle](#7-schreiben-nach-oracle)
8. [Oracle: `db file sequential read` im Detail](#8-oracle-db-file-sequential-read-im-detail)
9. [Checkliste](#9-checkliste)
10. [Quellen](#10-quellen)

---

## 1. Engpass finden

### Thread-Statistik im Session-Log

Am Ende jedes Session-Logs steht je Thread eine Zeile mit *Run time*, *Idle time* und **Busy Percentage**:

```
Thread [READER_1_1_1] created for [the read stage] of partition point [SQ_ORDERS] has completed.
    Total Run Time = [3600.12] secs
    Total Idle Time = [3420.50] secs
    Busy Percentage = [4.99]
Thread [TRANSF_1_1_1] ... Busy Percentage = [8.10]
Thread [WRITER_1_*_1] ... Busy Percentage = [99.20]
```

| Hoechster Busy-Wert bei | Engpass | Weiter bei |
|---|---|---|
| `READER_...` | Quelle: SQL im Source Qualifier, Datenbank, Netz | [6](#6-lesen-aus-oracle), [8](#8-oracle-db-file-sequential-read-im-detail) |
| `TRANSF_...` | Transformationen: Caches, Lookups, Expressions | [2](#2-speicher-und-caches-pmdtm-nutzt-nur-8-gb), [4](#4-transformationen), [5](#5-partitionierung-und-pushdown) |
| `WRITER_...` | Target: Indizes, Constraints, Commit, Update-Strategie | [7](#7-schreiben-nach-oracle), [8](#8-oracle-db-file-sequential-read-im-detail) |
| alle niedrig | Session wartet auf etwas anderes: Pre-/Post-SQL, Lookup-Cache-Aufbau, Sperren, Netz | Session-Log-Zeitstempel |

Ein Thread mit hohem Busy-Wert ist der Engpass - die anderen warten auf ihn. Ein **uncached Lookup** oder ein
Lookup, dessen Cache gerade aufgebaut wird, zaehlt zum Transformations-Thread, obwohl die Zeit in der Datenbank
vergeht.

### Performance-Zaehler

In der Session unter *Properties* **Collect performance data** aktivieren (fuer Dauerbetrieb wieder ausschalten).
Im Workflow Monitor (*Run Properties -> Performance*) bzw. in der Datei `<session>.perf` im Session-Log-Verzeichnis:

| Zaehler | Bedeutung | Soll |
|---|---|---|
| `<Transformation>_readfromdisk`, `_writetodisk` | Cache reicht nicht, Daten werden nach `$PMCacheDir` ausgelagert | 0 |
| `<Lookup>_rowsinlookupcache` | Zeilen im Lookup-Cache | plausibel zur Lookup-Tabelle |
| `<Transformation>_errorrows` | Fehlerzeilen | 0 |

Auslagern sieht man auch daran, dass die Dateien `*.dat`/`*.idx` in `$PMCacheDir` waehrend des Laufs wachsen.

### Isolations-Tests (in einer Kopie der Session)

| Test | Aussage |
|---|---|
| Target durch eine **Flat-File-Target**-Datei ersetzen | wird es schnell, liegt der Engpass beim Schreiben |
| direkt hinter dem Source Qualifier einen **Filter mit Bedingung `FALSE`** einfuegen | Laufzeit = reine Lesezeit aus der Quelle |
| Quelle durch eine Datei mit denselben Daten ersetzen | Laufzeit ohne Datenbank-Lesezugriff |

---

## 2. Speicher und Caches (`pmdtm` nutzt nur 8 GB)

Eine feste 8-GB-Grenze fuer `pmdtm` gibt es im **64-Bit**-PowerCenter nicht. Der Prozess fordert nur so viel
Speicher an, wie die Session-Einstellungen erlauben. Ein 32-Bit-`pmdtm` (Task-Manager zeigt "(32 Bit)") ist auf
etwa 2 GB Cache begrenzt.

### Auto-Memory-Grenzen der Session

Steht die Cache-Groesse einer Transformation auf **Auto**, begrenzen zwei Einstellungen den Speicher aller
Auto-Caches der Session. Es gilt der **kleinere** der beiden Werte:

| Einstellung (*Session -> Config Object -> Advanced*) | Default | Beispiel fuer einen Server mit 48 GB |
|---|---|---|
| Maximum Memory Allowed For Auto Memory Attributes | `512MB` | `24GB` (Einheit angeben, ohne Einheit sind es Bytes) |
| Maximum Percentage of Total Memory Allowed For Auto Memory Attributes | `5` | `60` |

- Die Grenze gilt **je Session**. Parallel laufende Sessions muessen gemeinsam in den Speicher passen.
- Fuer alle Sessions: im Workflow Manager *Tasks -> Session Configuration -> `default_session_config`* anpassen.
- **Nach einem Upgrade** stehen beide Werte oft auf `0` - Auto-Memory ist dann aus, es gelten kleine Standardgroessen.
- **Feste Cache-Groessen** statt Auto: Die "8 GB" sind dann meist die Summe der eingetragenen Werte. Den Bedarf
  zeigt das Session-Log (Meldungen zur Cache-Groesse) bzw. der *Cache Calculator* in der Transformation.

### Caches der Transformationen

| Transformation | Cache | Hinweis |
|---|---|---|
| Aggregator | Index + Data | mit *Sorted Input* fast kein Cache noetig |
| Joiner | Index + Data (Master) | **kleinere** Quelle als Master; mit *Sorted Input* nur ein Block je Schluessel |
| Lookup (cached) | Index + Data | nur benoetigte Spalten, *Lookup Source Filter*, ggf. Persistent Cache |
| Sorter | Sorter Cache | zu klein -> Auslagern nach `$PMTempDir` |
| Rank | Index + Data | wie Aggregator |

Bei Partitionierung braucht **jede Partition** eigene Caches (Ausnahme: ein gemeinsamer Lookup-Cache).

### DTM-Buffer

| Einstellung | Empfehlung |
|---|---|
| DTM Buffer Size | `Auto` oder 512 MB bis 1 GB - mehr bringt laut Informatica selten etwas |
| Default Buffer Block Size | bei breiten Zeilen (viele/lange Ports) erhoehen, z.B. `1MB`; ein Block muss mindestens einige Zeilen fassen |

Das Session-Log meldet zu kleine Buffer (z.B. "insufficient buffer blocks"). Die Block-Groesse bestimmt auch, wie
viele Zeilen je Array-Fetch aus der Quelle gelesen und je Array-Insert geschrieben werden.

### Cache-Verzeichnisse

`$PMCacheDir` und `$PMTempDir` auf schnelle lokale Platten legen, **nicht** auf das Storage der Oracle-Datendateien
und nicht auf Netzlaufwerke. Auslagernde Caches belasten sonst genau das Storage, auf dem die Datenbank liest.

---

## 3. Windows-Server und VM

| Pruefung | Wie | Problem, wenn ... |
|---|---|---|
| Job-Objekt mit Speicherlimit | Process Explorer -> `pmdtm` -> Reiter *Job* | ein Limit eingetragen ist (z.B. durch Ressourcen-Manager, Fremdsoftware) |
| VM-Speicher wirklich verfuegbar | Hyper-V: *Dynamischer Arbeitsspeicher*; VMware: Ballooning (`esxtop`, Spalte MCTL), Reservation | dem Gast weniger als die angezeigten 48 GB zur Verfuegung stehen |
| Auslagerungsdatei | *Systemeigenschaften -> Leistung -> Virtueller Arbeitsspeicher* | sie zu klein fixiert ist (Commit-Grenze = RAM + Auslagerungsdatei) |
| Zugesicherter Speicher | Ressourcenmonitor -> *Arbeitsspeicher* -> Spalte *Zugesichert* bei `pmdtm` | `pmdtm` weit unter dem erwarteten Wert bleibt (dann Session-Einstellungen) |
| Virenscanner | Ausnahmen pruefen | `$PMCacheDir`, `$PMTempDir`, `$PMSourceFileDir`/`$PMTargetFileDir` und (auf DB-Servern) die Oracle-Datendateien gescannt werden |
| Energiesparplan | `powercfg /getactivescheme` | nicht *Hoechstleistung* (CPU taktet herunter) |
| Datenbank auf demselben Host | Task-Manager | `pmdtm` und Oracle sich die 48 GB teilen - siehe [8.5](#85-ursachen-fuer-extreme-latenz-2000-ms) (SGA-Paging) |

"Maximum Memory %" am Knoten (Load Balancer) ist nur eine Schwelle fuer die Verteilung von Sessions, kein
Speicherlimit fuer `pmdtm`.

---

## 4. Transformationen

- **Lookups**
  - Cached statt uncached: ein uncached Lookup schickt **je Zeile ein SQL** an die Datenbank -> je Zeile mehrere
    Index-Reads (`db file sequential read`). Bei Millionen Zeilen ist das der haeufigste Grund fuer stundenlange
    Sessions.
  - Nur die benoetigten Ports, *Lookup Source Filter* bzw. SQL-Override mit `WHERE`, damit der Cache klein bleibt.
  - Bei wiederholter Nutzung derselben Tabelle: *Persistent Cache* (ggf. mit *Cache File Name Prefix*).
  - Bei Partitionierung: *Pre-build lookup cache* = `Always allowed`, damit die Caches parallel aufgebaut werden.
  - Sehr grosse Lookup-Tabellen: statt Lookup einen Joiner mit sortierter Eingabe oder den Join in die Datenbank
    verlegen (SQ-Join, Pushdown).
- **Aggregator / Joiner:** *Sorted Input* mit `ORDER BY` in der Quelle (Number of Sorted Ports im SQ) - die
  Datenbank sortiert in der Regel schneller und der Cache-Bedarf faellt fast weg.
- **Filter** so frueh wie moeglich, am besten als `WHERE` im Source Qualifier.
- **Expressions:** wiederholte Teilausdruecke in Variablenports berechnen; `:LKP`-Aufrufe (unconnected Lookup)
  nur fuer die Zeilen, die sie wirklich brauchen (`IIF(bedingung, :LKP...)`).
- **Update Strategy / Update else Insert:** zeilenweises Update ist langsam - siehe [7](#7-schreiben-nach-oracle).

---

## 5. Partitionierung und Pushdown

- **Partitionierung** (Lizenz-Option *Partitioning*): je Partition und Stufe ein Thread. Auf Servern mit vielen
  Kernen bringen 4 bis 8 Partitionen meist mehr als zusaetzlicher Speicher.
  - Quelle: *Key Range* bzw. *Pass Through* mit eigenem `WHERE` je Partition (z.B. nach Oracle-Partition oder
    `MOD(ORA_HASH(id), 4) = 0..3`).
  - Aggregator/Joiner/Sorter/Rank: *Hash Auto-Keys*, damit gleiche Schluessel in derselben Partition landen.
  - Target: Mehr Partitionen erhoehen die Zahl paralleler Writer - nur sinnvoll, wenn das Target nicht durch
    Sperren oder Index-Pflege begrenzt ist.
- **Pushdown Optimization** (Lizenz-Option): *Source*, *Target* oder *Full* - Joins, Filter und Aggregationen laufen
  als SQL in der Datenbank. Ergebnis im *Pushdown Optimization Viewer* (Workflow Manager) pruefen; nicht jede
  Funktion ist uebersetzbar.

---

## 6. Lesen aus Oracle

1. SQL des Source Qualifiers aus dem Session-Log nehmen (oder aus `v$sql`, Abfrage **A5**) und den Plan pruefen:
   ```sql
   EXPLAIN PLAN FOR <sql>;
   SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY);
   -- tatsaechlicher Plan der laufenden Session (sql_id aus A6):
   SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY_CURSOR('<sql_id>', NULL, 'TYPICAL'));
   ```
2. Fuer **Massenlesen** ist ein Full Table Scan (Multiblock-Reads, `direct path read`) fast immer besser als
   Millionen Index-Zugriffe. Typisches Bild eines schlechten Plans: `NESTED LOOPS` + `TABLE ACCESS BY INDEX ROWID`
   ueber grosse Tabellen -> massenhaft `db file sequential read`.
3. Abhilfe in dieser Reihenfolge: aktuelle Statistiken ([8.6](#86-ursachen-fuer-zu-viele-reads)) -> SQL
   vereinfachen -> Hints im SQL-Override, z.B. `/*+ FULL(o) USE_HASH(o c) */` oder `/*+ PARALLEL(o 4) */`.
4. Netz: Bei entfernten Datenbanken die Zeit zwischen Fetches beachten (`SQL*Net message from client` in **A7**
   ist die Zeit, in der die Datenbank auf Informatica wartet - dann liegt der Engpass **nicht** in Oracle).

---

## 7. Schreiben nach Oracle

| Massnahme | Wirkung | Hinweis |
|---|---|---|
| **Bulk Load** (*Target load type = Bulk*) | Direct-Path-Load, kaum Redo/Undo | nur fuer Inserts; keine Session-Recovery; Indizes/Constraints vorher deaktivieren (Pre-SQL), sonst Fehler oder `UNUSABLE`-Indizes |
| Indizes vor dem Laden deaktivieren, danach neu aufbauen | erspart je Zeile die Index-Pflege (= Single-Block-Reads auf Index-Bloecke) | Pre-SQL `ALTER INDEX ... UNUSABLE` + `ALTER SESSION SET skip_unusable_indexes = TRUE`, Post-SQL `ALTER INDEX ... REBUILD [PARALLEL n NOLOGGING]`; nicht fuer Unique-/PK-Indizes, die Duplikate verhindern sollen |
| Foreign Keys deaktivieren und danach mit `ENABLE NOVALIDATE` bzw. `VALIDATE` wieder einschalten | erspart je Zeile den Index-Zugriff auf die Eltern-Tabelle | nur wenn die Daten anderweitig geprueft sind |
| **Commit Interval** erhoehen (Default 10000) | weniger Commits | 50000 bis 500000 je nach Undo-Groesse |
| **Staging + `MERGE`** statt *Update else Insert* | ein Set-Statement statt je Zeile `UPDATE` (Index-Lookup) + ggf. `INSERT` | Informatica schreibt per Bulk in eine Staging-Tabelle, Post-SQL fuehrt `MERGE` aus |
| Statistiken nach dem Laden | spaetere Abfragen bekommen passende Plaene | Post-SQL `BEGIN DBMS_STATS.GATHER_TABLE_STATS(USER, 'T'); END;` |

**Update-Strategie und Updates ueber den Primaerschluessel:** Jedes `UPDATE ... WHERE pk = :1` liest den
Index-Pfad (Root-, Branch-, Leaf-Block) und den Tabellenblock. Liegen diese Bloecke nicht im Buffer Cache, sind das
pro Zeile bis zu vier `db file sequential read` - bei 10 Mio. Zeilen und 10 ms je Read ueber 100 Stunden
Wartezeit. Dieser Fall ist mit Abstand die haeufigste Ursache fuer "Writer bei 100 % und massenhaft
`db file sequential read`".

---

## 8. Oracle: `db file sequential read` im Detail

### 8.1 Was der Wait bedeutet

Eine Session liest **einen einzelnen Block** synchron von der Platte in den Buffer Cache und wartet, bis er da ist.
Das "sequential" im Namen ist historisch und bedeutet nicht sequentielles Lesen - es ist der typische Wait von
**Einzelzugriffen**:

| Wer liest einzelne Bloecke | Beispiel |
|---|---|
| Index-Zugriff (Root/Branch/Leaf) | `INDEX UNIQUE/RANGE SCAN`, Lookup-SQL, `UPDATE ... WHERE pk = :1` |
| Tabellenzugriff ueber ROWID | `TABLE ACCESS BY INDEX ROWID` |
| Index-Pflege bei DML | Insert in eine Tabelle mit vielen Indizes |
| Pruefung von Foreign Keys | Insert in die Kind-Tabelle liest den PK-Index der Eltern-Tabelle |
| Verkettete/migrierte Zeilen | `table fetch continued row` |
| Lesekonsistenz | Lesen von Undo-Bloecken, wenn parallel geaendert wird |
| Segment-Header, Dateikopf | einmalig, selten relevant |

Parameter des Waits (`v$session`, ASH, Trace):

| Parameter | Bedeutung |
|---|---|
| `P1` | Dateinummer (`file#`) |
| `P2` | Blocknummer (`block#`) |
| `P3` | Anzahl Bloecke (meist 1) |

Mit `P1`/`P2` findet **A8** das Segment (Tabelle, Index, Undo) zu einem konkreten Wait.

### 8.2 Normale Werte

Mittlere Dauer **eines** Single-Block-Reads, wie die Datenbank sie misst:

| Mittlere Dauer | Bewertung |
|---|---|
| < 1 ms | Flash/NVMe bzw. Read-Cache des Storage |
| 1 - 5 ms | gutes SSD-/SAN-Storage |
| 5 - 10 ms | drehende Platten, akzeptabel |
| 10 - 20 ms | grenzwertig, Storage pruefen |
| > 20 ms | Storage-Problem |
| > 100 ms | schwerwiegend |
| **2000+ ms** | **kein SQL-Problem**: ein einzelner Blockread darf nie 2 Sekunden dauern. Ursache ist Infrastruktur (Storage, Pfad, VM, Speicher, CPU) |

### 8.3 Entscheidungsbaum

```
Session langsam, "db file sequential read" ist der Top-Wait
│
├─ mittlere Dauer normal (< 10 ms), aber Millionen Waits
│     -> ZU VIELE Reads: Ausfuehrungsplan, Lookups, Update-Strategie, Indizes     -> 8.6
│
├─ mittlere Dauer hoch (> 20 ms), alle Dateien gleich betroffen
│     -> Storage/Pfad/VM insgesamt ueberlastet oder gestoert                    -> 8.5
│
├─ mittlere Dauer hoch nur bei EINER Datei / EINEM Mountpoint / EINEM LUN (A3, B2)
│     -> LUN, Pfad, Tier oder Platte dieses Speicherorts                         -> 8.5
│
├─ Mittelwert normal, aber einzelne Waits 1 - 30 s (Histogramm A2, MAX_MS A7)
│     -> Aussetzer: Pfad-Failover, SCSI-Timeouts, NFS-Retransmits, Snapshots,
│        Backups, Virenscanner, SGA-Paging                                       -> 8.5
│
└─ hohe Latenz nur zu bestimmten Uhrzeiten (B1, B4)
      -> Konkurrenz: Backups (RMAN, Storage-Snapshots), Statistiklaeufe, andere
         Ladeprozesse, Virenscans                                                -> 8.5
```

### 8.4 Diagnose Schritt fuer Schritt

Alle Abfragen in [`sql/oracle/diag_io_waits.sql`](../sql/oracle/diag_io_waits.sql). Teil A ist lizenzfrei,
**Teil B nur mit der Lizenz "Diagnostics Pack"** (AWR/ASH).

| Schritt | Abfrage | Frage |
|---|---|---|
| 1 | **A1** | Wie gross ist der Anteil von `db file sequential read`, und wie lange dauert ein Read im Mittel (`AVG_MS`)? |
| 2 | **A2** | Wie verteilen sich die Waits? Eintraege in den Buckets `2048`, `4096`, ... ms = Aussetzer von Sekunden |
| 3 | **A3** | Ist eine einzelne Datei / ein Tablespace / ein Mountpoint langsam? (`SINGLEBLKRDTIM` ist in Hundertstelsekunden, die Abfrage rechnet in ms um) |
| 4 | **A6** | Worauf warten die laufenden Informatica-Sessions (`PROGRAM` wie `pmdtm%`) **jetzt**? `P1`/`P2` notieren |
| 5 | **A7** | Summe und laengster Wait (`MAX_MS`) je Informatica-Session seit Anmeldung |
| 6 | **A8** | Welches Segment gehoert zu Datei/Block aus Schritt 4? (Index? Tabelle? Undo?) |
| 7 | **A4**, **A5** | Welche Segmente und welche SQL verursachen die meisten Reads? `READS_PRO_EXEC` zeigt Lookup- und Update-SQL mit wenigen Reads je Ausfuehrung, aber Millionen Ausfuehrungen |
| 8 | **A9** | Ist der Datenbank-Host ausgelastet (`LOAD` > Anzahl CPUs) oder lagert er aus (`VM_IN_BYTES`/`VM_OUT_BYTES` > 0)? |
| 9 | **A10** | Weichen Parameter vom Default ab (`ISDEFAULT = FALSE`)? |
| 10 | **A11** | Wuerde ein groesserer Buffer Cache die physischen Reads deutlich senken? |
| 11 | **A12**, **A13** | Clustering Factor und Statistiken der betroffenen Tabelle, verkettete Zeilen |
| 12 | **B1**, **B2** | Verlauf je AWR-Snapshot: seit wann, zu welchen Uhrzeiten, welche Dateien? |
| 13 | **B3**, **B4** | Welche SQL/Objekte, und was lief zeitgleich? |
| 14 | **C** | 10046-Trace einer Informatica-Session: jeder einzelne Wait mit Dauer, Datei und Block |

**Wichtig fuer den Vergleich mit dem Betriebssystem:** Die Datenbank misst die Zeit vom Absetzen des Reads, bis der
Prozess wieder rechnet. Darin steckt die Latenz von Storage **und** Pfad **und** Betriebssystem **und** die Zeit,
bis der Prozess wieder eine CPU bekommt. Deshalb immer parallel auf OS-Ebene messen:

| Ebene | Werkzeug | Kennzahl |
|---|---|---|
| Windows | Leistungsueberwachung (perfmon), Objekt *PhysicalDisk* bzw. *LogicalDisk* | `Avg. Disk sec/Read` (in Sekunden: 0.005 = 5 ms), `Avg. Disk Read Queue Length`, `Disk Reads/sec` |
| Linux | `iostat -x 5` (Paket sysstat) | `r_await` (ms), `aqu-sz`, `%util` |
| Linux, Pfade | `multipath -ll`, `dmesg -T`, `/var/log/messages` | ausgefallene Pfade, `SCSI timeout`, `abort`, `reset` |
| Linux, NFS | `nfsstat -c`, `mountstats` | `retrans`, Timeouts |
| VMware | `esxtop`, Ansicht Disk (`d`/`u`/`v`) | `DAVG` (Geraet/Storage), `KAVG` (Kernel-Warteschlange des Hosts), `GAVG` (= Sicht des Gastes) |
| Storage | Monitoring des Arrays | Latenz je LUN, Controller-Auslastung, Cache-Status |

Auswertung:

- OS-Latenz **gleich** Oracle-Latenz -> Problem unterhalb des Betriebssystems (Pfad, HBA, Storage, Hypervisor).
- OS-Latenz **niedrig**, Oracle-Latenz hoch -> CPU-Engpass oder Paging auf dem Datenbank-Host (A9), Virenscanner
  bzw. Filter-Treiber, Warteschlangen im Betriebssystem.
- VMware: `DAVG` hoch -> Storage/SAN; `KAVG` hoch -> Warteschlange des ESXi-Hosts (Queue Depth, Ueberbuchung
  des Datastores); nur `GAVG` hoch -> im Gast.

### 8.5 Ursachen fuer extreme Latenz (2000+ ms)

Ein einzelner Blockread von 2 s ist kein "langsames SQL" - der Read hing irgendwo. Typische Ursachen, ungefaehr
nach Haeufigkeit:

| Ursache | Erkennungsmerkmal | Behebung |
|---|---|---|
| **Pfad-Failover / instabiler Pfad** (Multipath, HBA, Switch) | Waits von genau einigen Sekunden bis 30+ s (Timeouts), Meldungen in `dmesg`/Event-Log, `multipath -ll` zeigt `failed`/`faulty` | Pfad/Kabel/SFP/Switch-Port pruefen, Multipath-Konfiguration nach Vorgabe des Storage-Herstellers, Firmware/Treiber |
| **Storage ueberlastet / Warteschlange voll** | hohe `aqu-sz`/Queue Length, `KAVG` > 0, Latenz steigt mit der Last, viele Waits im Bereich 100 ms bis Sekunden | Last verteilen (andere Ladeprozesse, Backups), Queue Depth abstimmen, mehr/schnellere Platten, I/O sparen (8.6) |
| **Storage-Controller ohne Schreibcache** (Batterie/Cache-Fehler, Write-Through) | ploetzlich stark erhoehte Latenz fuer alle LUNs, Warnung im Array-Monitoring | Hardware-Fehler beheben lassen |
| **RAID-Rebuild, Deduplizierung, Kompression, Auto-Tiering** | Latenz hoch nur zeitweise oder nur fuer "kalte" Daten; nach dem ersten Zugriff schnell | Rebuild abwarten; Datendateien auf festes Tier (kein Auto-Tiering auf langsame Platten) |
| **Backup zur gleichen Zeit** (RMAN, Storage-Snapshots, VM-Backup) | Latenz hoch in festen Zeitfenstern (B1/B4), RMAN-Jobs in `v$rman_backup_job_details` | Zeitfenster trennen, RMAN-Kanaele begrenzen, Snapshots nicht waehrend der Ladeprozesse |
| **VM-Snapshots, die lange bestehen** | VM hat Snapshot-Kette, Latenz waechst mit ihrer Groesse | Snapshots konsolidieren/loeschen |
| **Thin Provisioning, ueberbuchter Datastore** | Datastore fast voll, `KAVG` hoch, mehrere VMs auf demselben Datastore | Platz schaffen, Datenbank-VMs auf eigene Datastores / Thick Provisioning |
| **Synchrone Spiegelung/Replikation** (z.B. Metro-Cluster) | Latenz haengt an der Verbindung zum zweiten Standort | Verbindung pruefen; trifft vor allem Writes, ueber die gemeinsame Warteschlange aber auch Reads |
| **Virenscanner / Filter-Treiber** (v.a. Windows) | OS-Latenz niedrig, Oracle-Latenz hoch; Prozess des Virenscanners mit hoher I/O | Ausnahmen fuer Datendateien, Redo, Control Files, Archive, Temp sowie die Oracle-Prozesse (`oracle.exe`) |
| **SGA wird ausgelagert (Paging)** | A9: `VM_IN_BYTES`/`VM_OUT_BYTES` > 0; OS zeigt Paging; Datenbank und `pmdtm` auf demselben Host | SGA im RAM fixieren (Large Pages, siehe unten), Speicher so planen, dass SGA + PGA + `pmdtm`-Caches + OS in den RAM passen |
| **CPU-Saettigung auf dem DB-Host** | A9: `LOAD` dauerhaft > `NUM_CPUS`; Wait-Zeiten wirken laenger, als das Storage meldet | Last senken (Parallelitaet, Partitionen der Informatica-Sessions), Informatica nicht auf dem DB-Host betreiben, CPU-Ressourcen der VM pruefen (CPU Ready) |
| **NFS-Probleme** | `retrans` steigt, Waits mit Timeout-Laenge | Netz/Filer pruefen; Mount-Optionen nach Oracle-Vorgabe; Direct NFS (dNFS) |
| **Informatica-Cache-Dateien auf dem Datenbank-Storage** | `$PMCacheDir`/`$PMTempDir` auf demselben LUN, Latenz nur waehrend Sessions mit auslagernden Caches | Cache-Verzeichnisse auf lokale Platten, Caches gross genug (Abschnitt 2) |

**Large Pages (SGA nicht auslagerbar):**

| Plattform | Einrichtung |
|---|---|
| Windows | Registry-Wert `ORA_LPENABLE = 1` unter `HKLM\SOFTWARE\ORACLE\KEY_<Oracle-Home-Name>`, dem Dienstkonto der Datenbank das Recht *Sperren von Seiten im Speicher* (*Lock pages in memory*) geben, Instanz neu starten. Nicht zusammen mit `memory_target` (AMM) |
| Linux | HugePages im Kernel (`vm.nr_hugepages`) passend zur SGA, `memlock` in `/etc/security/limits.conf`, Parameter `use_large_pages = ONLY`, Transparent HugePages abschalten. Nicht zusammen mit `memory_target` |

### 8.6 Ursachen fuer zu viele Reads

Bei normaler Latenz, aber Millionen Waits, ist der Zugriffsweg das Problem:

| Ursache | Erkennungsmerkmal | Behebung |
|---|---|---|
| **Uncached Lookup** | A5: `SELECT` mit Bind-Variablen, `EXECUTIONS` = Zeilenzahl der Session | Lookup cachen (Abschnitt 4) |
| **Zeilenweises Update / Update else Insert** | A5: `UPDATE ... WHERE ... = :1` mit Millionen Ausfuehrungen | Staging + `MERGE` (Abschnitt 7) |
| **Viele Indizes auf dem Target** | A4: Index-Segmente des Targets oben, Writer-Thread busy | Indizes vor dem Laden deaktivieren, nicht benoetigte Indizes entfernen |
| **Foreign-Key-Pruefung** | A4: PK-Index der Eltern-Tabelle oben | FKs waehrend des Ladens deaktivieren |
| **Plan mit Nested Loops ueber grosse Mengen** | `DBMS_XPLAN`: `NESTED LOOPS` + `INDEX RANGE SCAN` + `TABLE ACCESS BY INDEX ROWID` | Statistiken, Hints (`FULL`, `USE_HASH`), SQL-Override |
| **Veraltete oder leere Statistiken** | A12: `LAST_ANALYZED` alt, `NUM_ROWS` 0 bei gefuellter Tabelle (typisch bei Staging-Tabellen, die bei leerer Tabelle analysiert wurden) | Statistiken nach dem Laden sammeln (Post-SQL) oder repraesentative Statistiken fixieren (`DBMS_STATS.LOCK_TABLE_STATS`) |
| **Schlechter Clustering Factor** | A12: `CLUSTERING_FACTOR` nahe `NUM_ROWS` statt nahe `BLOCKS` - jede Zeile ueber den Index kostet einen eigenen Tabellenblock | Full Scan statt Index fuer grosse Mengen; Tabelle sortiert nach dem Index-Schluessel neu aufbauen (`CTAS ... ORDER BY`, ab 12c Attribute Clustering) |
| **Optimizer-Parameter, die Index-Zugriffe bevorzugen** | A10: `optimizer_index_cost_adj` < 100, `optimizer_index_caching` > 0, `optimizer_mode = FIRST_ROWS*` | auf Default zuruecksetzen (siehe 8.7) - vorher mit dem DBA, betrifft alle Anwendungen |
| **Verkettete/migrierte Zeilen** | A13: `table fetch continued row` hoch | Tabelle reorganisieren (`ALTER TABLE ... MOVE` + Index-Rebuild), `PCTFREE` erhoehen bei wachsenden Updates |
| **Lesekonsistenz (Undo)** | A8: Segment ist ein Undo-Segment; lange Abfrage, waehrend dieselbe Tabelle geaendert wird | Lesen und Schreiben auf dieselbe Tabelle zeitlich trennen; Commit-Intervall der aendernden Session pruefen |
| **Buffer Cache zu klein** | A11: deutlich weniger physische Reads bei groesserem Cache; kleine, oft gelesene Tabellen fallen immer wieder aus dem Cache | Cache vergroessern bzw. KEEP-Pool fuer Lookup-Tabellen (siehe 8.7) |

### 8.7 Datenbank-Parameter

Kein Parameter beschleunigt ein langsames Storage. Parameter senken die **Anzahl** der Reads (Cache, Plaene) oder
verhindern **zusaetzliche Verzoegerungen** (Paging, synchrones I/O). Werte stehen in **A10**.

| Parameter | Empfehlung | Warum |
|---|---|---|
| `sga_target` bzw. `db_cache_size` | anhand von `v$db_cache_advice` (A11) dimensionieren | ein groesserer Buffer Cache spart physische Reads, solange A11 noch nennenswerte Einsparung zeigt |
| `db_keep_cache_size` + `ALTER TABLE/INDEX ... STORAGE (BUFFER_POOL KEEP)` | fuer haeufig gelesene Lookup-/Dimensionstabellen und deren Indizes | haelt sie im Speicher, unabhaengig von grossen Scans |
| `optimizer_index_cost_adj` | `100` (Default) | kleinere Werte (z.B. 10) machen Index-Zugriffe kuenstlich billig -> Nested Loops statt Hash Joins -> massenhaft Single-Block-Reads |
| `optimizer_index_caching` | `0` (Default) | Werte > 0 bevorzugen ebenfalls Nested Loops mit Index |
| `optimizer_mode` | `ALL_ROWS` (Default) | `FIRST_ROWS_n` optimiert auf die ersten Zeilen und bevorzugt Index-Zugriffe - fuer Massenverarbeitung falsch |
| `db_file_multiblock_read_count` | **nicht setzen** (Oracle waehlt den Wert selbst) | betrifft Full Scans; ein zu kleiner fester Wert macht Full Scans fuer den Optimizer teuer und Index-Zugriffe attraktiver |
| `disk_asynch_io` | `TRUE` (Default) | asynchrones I/O, vor allem fuer DBWR |
| `filesystemio_options` | `SETALL` (nur Unix/Linux auf Dateisystemen) | Direct I/O + Async I/O: kein doppeltes Caching im OS-Cache. Nach dem Umstellen den Buffer Cache entsprechend vergroessern, weil der OS-Cache als "zweiter Cache" wegfaellt. Unter Windows nicht relevant |
| `use_large_pages` (Linux) / `ORA_LPENABLE` (Windows), ggf. `lock_sga` | Large Pages, siehe 8.5 | SGA wird nicht ausgelagert |
| `memory_target` / `memory_max_target` (AMM) | auf grossen Systemen besser `sga_target` + `pga_aggregate_target` | AMM ist nicht mit Large Pages kombinierbar |
| `pga_aggregate_target` | ausreichend fuer Sortierungen und Hash Joins | zu klein -> Hash Joins laufen ueber Temp (`direct path read temp`), der Optimizer bevorzugt eher Nested Loops |
| `parallel_max_servers`, `parallel_degree_policy` | mit DBA abstimmen | Parallel Query fuer grosse Reads aus dem Source Qualifier; zu viel Parallelitaet ueberlastet das Storage |
| `statistics_level` | `TYPICAL` (Default) | `BASIC` schaltet Advisories (A11) und Teile der Statistik ab |
| `db_writer_processes` | Default, erhoehen nur bei `free buffer waits` | betrifft das Schreiben; langsames Schreiben kann ueber volle Warteschlangen auch Reads bremsen |
| versteckte Parameter (`_...`) | **nur auf Anweisung von Oracle Support** | |

### 8.8 Sofortmassnahmen bei 2000+ ms

1. **A2** und **A3** ausfuehren: betrifft es alle Dateien oder eine? Wie viele Waits liegen ueber 1 s?
2. **Gleichzeitig** auf OS-Ebene messen (`Avg. Disk sec/Read` bzw. `iostat -x`), auf VMware `esxtop`.
3. Ergebnis an Storage-/Infrastruktur-Team mit **Zeitstempel, Datei/LUN und gemessenen Werten** (A3, B2 oder
   10046-Trace mit `ela=`-Werten). Ohne diese Daten heisst es oft "Storage ist unauffaellig", weil dort Mittelwerte
   ueber Minuten angezeigt werden, in denen Aussetzer von 2 Sekunden verschwinden.
4. Waehrenddessen I/O senken: parallel laufende Ladeprozesse und Backups entzerren, Lookups cachen,
   zeilenweise Updates vermeiden (8.6).
5. A9 pruefen: Paging oder CPU-Saettigung auf dem DB-Host ausschliessen.

---

## 9. Checkliste

**Informatica**

- [ ] Thread-Statistik im Session-Log ausgewertet - Reader, Transformation oder Writer?
- [ ] *Collect performance data*: keine `_readfromdisk`/`_writetodisk` > 0
- [ ] Auto-Memory-Grenzen gesetzt (z.B. `24GB` / `60`), nicht `0`; `default_session_config` angepasst
- [ ] DTM Buffer Size auf Auto oder 512 MB - 1 GB; Block Size passend zur Zeilenbreite
- [ ] `$PMCacheDir`/`$PMTempDir` auf schnellen lokalen Platten, nicht auf dem Datenbank-Storage
- [ ] Windows/VM: kein Job-Limit, kein Ballooning/dynamischer Speicher, Auslagerungsdatei ausreichend, Virenscanner-Ausnahmen
- [ ] Lookups gecacht, gefiltert, ggf. persistent
- [ ] Sorted Input fuer Aggregator/Joiner, kleinere Quelle als Joiner-Master
- [ ] Target: Bulk Load bzw. Staging + `MERGE`, Indizes/FKs waehrend des Ladens deaktiviert, Commit Interval erhoeht
- [ ] Partitionierung / Pushdown geprueft (Lizenz)

**Oracle**

- [ ] A1/A2: mittlere Dauer und Verteilung von `db file sequential read`
- [ ] A3/B2: Latenz je Datei - einzelner LUN oder alles?
- [ ] A4/A5/A8: verursachende Segmente und SQL (Lookup-SQL, Update je Zeile, Index-Pflege)
- [ ] A9: kein Paging, keine CPU-Saettigung auf dem DB-Host
- [ ] A10: Optimizer-Parameter auf Default (`optimizer_index_cost_adj = 100`, `optimizer_index_caching = 0`, `ALL_ROWS`)
- [ ] A11: Buffer Cache ausreichend, KEEP-Pool fuer Lookup-Tabellen
- [ ] A12: Statistiken aktuell (auch Staging-Tabellen nach dem Laden), Clustering Factor
- [ ] OS-Latenz parallel gemessen und mit Storage-/VM-Team abgeglichen
- [ ] Large Pages aktiv, SGA wird nicht ausgelagert
- [ ] keine Backups/Snapshots/Virenscans im Ladefenster

---

## 10. Quellen

- Informatica: [Configuring Automatic Memory Settings for Session Caches](https://docs.informatica.com/data-integration/powercenter/10-4-0/advanced-workflow-guide/understanding-buffer-memory/configuring-session-cache-memory/configuring-automatic-memory-settings-for-session-caches.html),
  [Session Cache Limits](https://docs.informatica.com/data-integration/powercenter/10-5/advanced-workflow-guide/understanding-buffer-memory/configuring-session-cache-memory/session-cache-limits.html),
  [Performance Tuning Guide - Caches](https://docs.informatica.com/data-integration/powercenter/10-5/performance-tuning-guide/optimizing-sessions/caches.html),
  [Increasing DTM Buffer Size](https://docs.informatica.com/data-integration/powercenter/10-5/performance-tuning-guide/optimizing-sessions/buffer-memory/increasing-dtm-buffer-size.html),
  [Using the 64-bit Version of PowerCenter](https://docs.informatica.com/data-integration/powercenter/10-5/performance-tuning-guide/optimizing-sessions/caches/using-the-64-bit-version-of-powercenter.html)
- Oracle Database Reference: `V$FILESTAT`, `V$EVENT_HISTOGRAM`, `V$SYSTEM_EVENT`, `V$DB_CACHE_ADVICE`, `V$OSSTAT`
- Oracle Database Performance Tuning Guide: Kapitel *Instance Tuning Using Performance Views* (Wait Events,
  `db file sequential read`) und *Tuning the Database Buffer Cache*
- Oracle Database Installation Guide for Microsoft Windows: *Large Page Support* (`ORA_LPENABLE`);
  Oracle Database Administrator's Reference for Linux: *HugePages*
