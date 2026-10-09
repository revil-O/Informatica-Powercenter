# Informatica-Powercenter
Scripts &amp; useful things (administration) for data integration development using Informatica Powercenter

## SQL fuer das Repository

Abfragen direkt auf die Repository-Datenbank (nur lesend, Repository-Tabellen `OPB_*`/`REP_*`, keine MX-Views),
siehe [sql/README.md](sql/README.md):

- `sql/oracle/port_lineage.sql` - **Port-Lineage**: verfolgt jeden Port vom Ursprung (Source-Feld, Lookup, Konstante)
  ueber alle Transformationen bis in die Target-Spalte, eine Zeile je Schritt mit Datentyp/Praezision/Scale.
  Neben den Links werden auch logische Verbindungen in Expressions verfolgt (Port-Referenzen, Variablenports,
  `:LKP`/`:SP`-Aufrufe, Lookup-Bedingungen, Router/Union/Normalizer-Gruppen).
- `sql/oracle/check_repository_columns.sql` - Vorpruefung, ob Tabellen und Spalten zum Repository passen.
- `sql/oracle/diag_io_waits.sql` - Diagnose von Oracle-I/O-Waits (`db file sequential read`) der Ziel-/Quelldatenbank,
  passend zu [docs/TUNING.md](docs/TUNING.md).
- `sql/test/` - Test der Abfrage ohne Oracle gegen ein nachgebautes Repository (SQLite).

## Performance-Tuning

[docs/TUNING.md](docs/TUNING.md): Engpass einer Session finden (Thread-Statistik, Performance-Zaehler),
Speicher und Caches (`pmdtm` nutzt nur einen Teil des RAMs, Auto-Memory-Grenzen), Windows/VM, Lookups,
Partitionierung, Lesen und Schreiben nach Oracle sowie ausfuehrlich Oracle-Waits `db file sequential read`
bis 2000+ ms: Diagnose, Infrastruktur-Ursachen, zu viele Reads, Datenbank-Parameter, Checkliste.

## folder_backup / folder_restore (sh + ps1)

Folderweises Backup des Repositorys als importierbare XML-Exporte: erst die Shared Folder, danach alle anderen,
je Folder ein XML pro Objekt - gruppiert nach Typ in Import-Reihenfolge (`01_source` ... `11_workflow`) -
oder ein selbststaendiges XML pro Workflow. Mit Pruefung jeder Datei, Wiederholung bei Fehlern, Manifest mit
SHA256, Statusdatei, Aufbewahrung, Sperre gegen Doppelstart und Exitcodes fuer den Command Task eines Workflows.
Ergaenzt `pmrep backup`, ersetzt es nicht (Connections, Berechtigungen u.a. sind nicht in den XML-Exporten).

```bash
./folder_backup.sh -c folder_backup.conf --list      # Trockenlauf: Folder und Objektanzahl
./folder_backup.sh -c folder_backup.conf             # Backup
```
```powershell
.\folder_backup.ps1 -ConfigFile .\folder_backup.conf -List
.\folder_backup.ps1 -ConfigFile .\folder_backup.conf
```

Optional versioniert in Git (`--git` / `-GitRepo`): Aenderungshistorie je Objekt, Zeitstempel im XML-Kopf neutralisiert,
fehlgeschlagene Exporte behalten ihre letzte Version.
Wahlweise inkrementell (`--incremental QUERY` / `-Incremental`): nur Objekte aus einer gespeicherten Repository-Query,
z.B. taeglich inkrementell und woechentlich voll. Zusaetzlich landen Connections (ohne Passwoerter), Folder-Eigenschaften,
ausgecheckte Objekte, Labels, Deployment Groups und Queries als Nachschlagewerk in `_repository/`.

`folder_restore.sh` / `folder_restore.ps1` spielt einen Lauf wieder ein - alles, einzelne Folder oder Objekte, in
Import-Reihenfolge, mit Pruefsummenkontrolle, Auswertung der Import-Logs (`renamed` = Duplikat) und optionaler Validierung.
Standard ist Trockenlauf; mit `--create-folders` auch als Probe-Restore in ein Sandbox-Repository,
mit `--with-incrementals` / `-WithIncrementals` aus Vollsicherung plus neueren inkrementellen Laeufen.

```bash
./folder_restore.sh -c folder_backup.conf                                   # Trockenlauf, letzter erfolgreicher Lauf
./folder_restore.sh -c folder_backup.conf -r PM_SANDBOX --create-folders --validate --execute --yes
```
```powershell
.\folder_restore.ps1 -ConfigFile .\folder_backup.conf
.\folder_restore.ps1 -ConfigFile .\folder_backup.conf -Repository PM_SANDBOX -CreateFolders -Validate -Execute -Yes
```

Konfiguration: `folder_backup.conf.example`. Passwort als Umgebungsvariable `INFA_PASSWORD` (mit `pmpasswd` verschluesselt).
Exitcodes: `0` = SUCCESS, `1` = PARTIAL, `2` = FAILED.
Howto mit Einrichtung, Git, Workflow-Steuerung, Fehlerbehandlung, Restore und Probe-Restore: [docs/FOLDER_BACKUP.md](docs/FOLDER_BACKUP.md)

## shortcut_repair.sh / shortcut_repair.ps1

Repariert Shortcuts nach einem fehlgeschlagenen Import (REPLACE im Control-File):
verwaiste Shortcuts ohne gueltige Referenz in den Shared Folder bleiben stehen,
daneben entstehen Duplikate mit Zahlen-Suffix (`Shortcut_to_X1`).
Bash fuer Linux-Server, PowerShell (5.1 / 7) fuer Windows - gleiche Logik, gleiche Ausgabe.

**Standard ist Trockenlauf** - es wird nur analysiert, nichts geaendert.

```bash
# Linux - Analyse (Trockenlauf)
./shortcut_repair.sh -r PM_PROD_REPO -d Prod_Domain -n admin -f DWH
# Linux - Plan ausfuehren
./shortcut_repair.sh -r PM_PROD_REPO -d Prod_Domain -n admin -f DWH --execute
```
```powershell
# Windows - Analyse (Trockenlauf)
.\shortcut_repair.ps1 -Repository PM_PROD_REPO -Domain Prod_Domain -User admin -Folder DWH
# Windows - Plan ausfuehren
.\shortcut_repair.ps1 -Repository PM_PROD_REPO -Domain Prod_Domain -User admin -Folder DWH -Execute
```
Passwort: Umgebungsvariable `INFA_PASSWORD` mit dem **mit `pmpasswd` verschluesselten** Passwort (wird per
`pmrep connect -X` uebergeben), sonst interaktive Abfrage (`pmrep connect -x`).
Hilfe: `./shortcut_repair.sh -h` bzw. `Get-Help .\shortcut_repair.ps1 -Full`.

### Windows (PowerShell / Eingabeaufforderung)

Laeuft mit Windows PowerShell 5.1 (in Windows enthalten) und PowerShell 7, auf dem Informatica-Server
oder einem Rechner mit PowerCenter-Client.

**Einmalig: Skript freigeben.** Aus dem Internet geladene Skripte blockiert Windows; je nach
Ausfuehrungsrichtlinie laufen lokale Skripte gar nicht:

```powershell
Unblock-File .\shortcut_repair.ps1
# nur fuer die aktuelle PowerShell-Sitzung erlauben (keine dauerhafte Aenderung):
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

**pmrep finden.** Das Skript sucht `pmrep` im `PATH`, dann unter `%INFA_HOME%`. Sonst den Pfad angeben:

```powershell
.\shortcut_repair.ps1 -Repository PM_PROD_REPO -Domain Prod_Domain -User admin -Folder DWH `
  -Pmrep "C:\Informatica\10.5.0\clients\PowerCenterClient\client\bin\pmrep.exe"
```

Auf einem Client braucht pmrep die Domain-Datei. Meldet die Verbindung einen Fehler zu `domains.infa`:
`$env:INFA_DOMAINS_FILE = "C:\Informatica\10.5.0\domains.infa"` (Pfad je Installation).

**Passwort ohne Abfrage** (z.B. fuer einen geplanten Lauf) - das mit `pmpasswd` verschluesselte Passwort
(Wert zwischen `-->` und `<--` der Ausgabe von `pmpasswd <passwort>`) nur fuer die aktuelle Sitzung setzen:

```powershell
$env:INFA_PASSWORD = "<pmpasswd-verschluesselt>"
.\shortcut_repair.ps1 -Repository PM_PROD_REPO -Domain Prod_Domain -User admin -Folder DWH
Remove-Item Env:INFA_PASSWORD
```

**Aus der Eingabeaufforderung (cmd.exe):**

```bat
:: Trockenlauf
powershell -NoProfile -ExecutionPolicy Bypass -File shortcut_repair.ps1 -Repository PM_PROD_REPO -Domain Prod_Domain -User admin -Folder DWH
:: nur Sources und Targets, zwei Shared Folder fuers Control-File
powershell -NoProfile -ExecutionPolicy Bypass -File shortcut_repair.ps1 -Repository PM_PROD_REPO -Domain Prod_Domain -User admin -Folder DWH -Types source,target -SharedFolder SHARED,SHARED_DWH
:: ausfuehren
powershell -NoProfile -ExecutionPolicy Bypass -File shortcut_repair.ps1 -Repository PM_PROD_REPO -Domain Prod_Domain -User admin -Folder DWH -Execute
```

Mit PowerShell 7 `pwsh` statt `powershell` verwenden. Exitcode in cmd: `echo %ERRORLEVEL%`
(0 = ok, 1 = Fehler beim Verbinden oder Loeschen).

**Ergebnis auswerten** - alle Zeilen mit Handlungsbedarf aus dem neuesten Report:

```powershell
$rep = Get-ChildItem .\shortcut_repair_*\report.csv | Sort-Object LastWriteTime | Select-Object -Last 1
Import-Csv $rep.FullName -Delimiter ';' | Where-Object aktion -ne 'KEINE' | Format-Table typ, name, status, aktion
```

`report.csv` laesst sich auch direkt in Excel oeffnen (Semikolon-getrennt, UTF-8).

### Optionen Linux / Windows

| Bash (`shortcut_repair.sh`) | PowerShell (`shortcut_repair.ps1`) | Bedeutung |
|---|---|---|
| `-r REPO` | `-Repository` | Repository-Name |
| `-d DOMAIN` | `-Domain` | Domain-Name |
| `-n USER` | `-User` | Repository-User |
| `-f FOLDER` | `-Folder` | zu pruefender Ordner (Pflicht) |
| `-s SECDOMAIN` | `-SecurityDomain` | Security Domain (LDAP) |
| `-S A,B` | `-SharedFolder A,B` | Shared Folder fuer das Control-File (Standard: aus den Shortcuts) |
| `-R SRC_REPO` | `-SourceRepository` | Quell-Repository fuer das Control-File (Standard: Repository) |
| `-t source,target` | `-Types source,target` | Objekttypen (Standard: source, target, mapplet, transformation) |
| `-L datei` | `-ObjectFile datei` | Objektliste statt `pmrep listobjects` |
| `-P pfad` | `-Pmrep pfad` | Pfad zu pmrep |
| `-o verz` | `-OutDir verz` | Ausgabeverzeichnis |
| `--no-connect` | `-NoConnect` | bestehende pmrep-Verbindung nutzen |
| `--include-suspect` | `-IncludeSuspect` | auch Objekte loeschen, deren Export fehlschlug |
| `--execute` | `-Execute` | Plan ausfuehren (sonst Trockenlauf) |
| `--yes` | `-Yes` | keine Rueckfrage beim Ausfuehren |

Ablauf:
1. `pmrep listobjects` je Typ (source, target, mapplet, transformation) im Ordner
2. `pmrep objectexport` je Objekt, `<SHORTCUT>`-Element auswerten; Referenz im Shared Folder pruefen
   - `OK` - Referenz vorhanden
   - `ORPHAN` - kein Ordner/Objekt referenziert, oder die Liste des Referenz-Ordners wurde gelesen und das Objekt fehlt
   - `REF_CHECK_FAILED` - Referenz-Ordner nicht lesbar (fehlt, Berechtigung, pmrep-Fehler) - wird nie geloescht
   - `EXPORT_FAILED` - Export schlug fehl, Status unbekannt
   - `GLOBAL_UNCHECKED` - globaler Shortcut, nicht geprueft
3. `pmrep listobjectdependencies -p parents` fuer verwaiste Shortcuts
4. Aktionen:
   - `LOESCHEN` - verwaist, von nichts verwendet, Typ source/target/mapplet (`pmrep deleteobject`)
   - `REIMPORT` - verwaist, aber noch verwendet: gestufter Ablauf in `reimport_plan.txt` (Verwender sichern, Verwender und Shortcut loeschen, Re-Import) - wird nie automatisch ausgefuehrt - Anleitung: [docs/REIMPORT.md](docs/REIMPORT.md)
   - `MANUELL_PRUEFEN` - Referenz-Ordner nicht lesbar, Abhaengigkeiten unbekannt, Transformation (Designer) oder Export fehlgeschlagen (`--include-suspect` / `-IncludeSuspect`)
   - `UMBENENNEN_IM_DESIGNER` - gueltiges Duplikat `X1` zu verwaistem `X`, das geloescht wird; pmrep kann nicht umbenennen
   - `NACH_BASIS_PRUEFEN` - Duplikat `X1`, dessen Original `X` noch nicht geloescht werden kann - erst `X` klaeren

Ausgabe in `shortcut_repair_<Zeitstempel>/`: `report.csv` (Semikolon, Excel), `plan.txt`, `reimport_plan.txt`, `ctrl_reimport.xml`
(Control-File fuer sauberen Re-Import: FOLDERMAP inkl. Shared Folder, `REUSE` nur fuer gueltige Shortcuts, `REPLACE` fuer den Rest;
verwaiste Shortcuts sind als Kommentar aufgefuehrt und muessen vor dem Import geloescht sein - REUSE wuerde sie behalten, REPLACE geht bei Shortcuts nicht),
`xml/` (Exporte, dienen auch als Sicherung), `log/` (alle pmrep-Ausgaben), `run.log`.

Hinweise:
- Vorher Repository-Backup (`pmrep backup`) ziehen.
- `--no-connect` / `-NoConnect` nutzt eine bestehende pmrep-Verbindung; dann ist `-r`/`-R` bzw. `-Repository`/`-SourceRepository` trotzdem Pflicht (fuer das Control-File).
- Ein interaktiv abgefragtes Passwort wird nur fuer `pmrep connect` verwendet (`-x`) und danach sofort verworfen.
- Versioniertes Repository: geloeschte Objekte einchecken, ggf. `pmrep purgeversion`.
- Das Parsing der `listobjects`-Ausgabe kann je nach PowerCenter-Version abweichen - erst Trockenlauf und `report.csv` pruefen.
  Notfalls Objektliste selbst vorgeben: `-L objekte.txt` / `-ObjectFile objekte.txt` (Zeilen `typ|name[|subtyp]`, Sources als `DBD.NAME`).
