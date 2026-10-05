# Folderweises Repository-Backup mit pmrep

Howto fuer `folder_backup.sh` / `folder_backup.ps1` und `folder_restore.sh` / `folder_restore.ps1`
(Linux / Windows): Sicherung eines PowerCenter-Repositorys **Folder fuer Folder** als importierbare
XML-Exporte - erst die Shared Folder, danach alle anderen, gruppiert nach Objekttyp in Import-Reihenfolge -,
optional versioniert in Git, wahlweise inkrementell, mit ergaenzenden Sicherungen (Connections, Folder,
Checkouts), Restore-Skript und Probe-Restore. Steuerbar als Command Task aus einem Workflow.

## Wozu - und wozu nicht

| | `pmrep backup` (komplett) | `folder_backup` (XML je Objekt) |
|---|---|---|
| Restore | nur ganzes Repository, ueberschreibt alles | einzelnes Objekt, ein Folder oder alles |
| Ziel | gleiche Version, eigenes Repository | jedes Repository derselben PowerCenter-Version |
| Vergleichbar | nein (Binaerformat) | ja (XML, diff-bar, versionierbar) |
| Laufzeit | kurz | laenger (ein pmrep-Aufruf je Objekt) |
| Enthaelt | alles | nur Design-Objekte |

**Nicht** in den XML-Exporten enthalten: Connections (Relational/Application), Benutzer, Gruppen und
Berechtigungen, Folder-Eigenschaften und -Rechte, Deployment Groups, Labels, Queries, OS-Profile,
Integration-Service-Einstellungen sowie Dateien auf dem Server (Parameterdateien, Skripte, Lookup-Caches).
Einen Teil davon sichert `folder_backup` als **Nachschlagewerk** in `_repository/` (siehe
[Ergaenzende Sicherungen](#ergaenzende-sicherungen)) - wiederherstellbar ist er damit nicht.
Deshalb: folderweises Backup **zusaetzlich** zu einem regelmaessigen `pmrep backup`, nicht statt dessen.

## Ablauf

```
connect ─► Folderliste ─► Shared Folder erkennen ─► Shared Folder zuerst, dann alle anderen
             │
             └─ je Folder, je Typ (source ... workflow):
                  listobjects ─► objectexport je Objekt ─► Pruefung ─► Manifest
                  (Fehler: Wiederholung mit Neuverbindung, danach FEHLER im Manifest, .xml.failed)
             └─ je Folder: import_ctrl.xml (Shortcuts REUSE), optional packen
         ─► _repository/ (Connections, Folder, Checkouts, Labels, ...) ─► Git (optional)
         ─► import_order.txt ─► Status SUCCESS / PARTIAL / FAILED ─► Aufbewahrung ─► Exitcode

Inkrementell (--incremental QUERY): vorher executequery ─► nur Folder/Objekte aus dem Query-Ergebnis
```

## Voraussetzungen

- pmrep auf dem ausfuehrenden Rechner (Integration-Service-Host oder PowerCenter-Client)
- Repository-User mit **Leserecht auf alle zu sichernden Folder** (eigener Service-User empfohlen)
- Passwort **mit `pmpasswd` verschluesselt** in einer Umgebungsvariable (siehe unten)
- Schreibrecht und genug Platz im Backup-Verzeichnis (grob: Groesse eines kompletten Exports x 2-3 bei `DEPS=full`)
- Linux: bash 4+; Windows: PowerShell 5.1 oder 7

## Einrichtung

**1. Skripte ablegen**, z.B. im Skriptverzeichnis des Integration Service:

```bash
cp folder_backup.sh folder_backup.conf.example $PMRootDir/scripts/
cd $PMRootDir/scripts && cp folder_backup.conf.example folder_backup.conf && chmod 750 folder_backup.sh
```
```powershell
Copy-Item folder_backup.ps1, folder_backup.conf.example "$env:PMRootDir\scripts\"
Copy-Item "$env:PMRootDir\scripts\folder_backup.conf.example" "$env:PMRootDir\scripts\folder_backup.conf"
Unblock-File "$env:PMRootDir\scripts\folder_backup.ps1"
```

**2. Passwort verschluesseln** - `pmpasswd` gibt eine Zeile `Encrypted string -->...<--` aus, verwendet wird der Wert dazwischen:

```bash
pmpasswd 'MeinPasswort'      # danach Shell-History bereinigen
```

Den verschluesselten Wert als Umgebungsvariable `INFA_PASSWORD` bereitstellen:

- **Aufruf aus einem Workflow:** im Administrator Tool beim Integration Service unter
  *Processes → Environment Variables* eintragen (danach Service neu starten). So steht der Wert
  jedem Command Task zur Verfuegung, ohne in Skript, Konfiguration oder Workflow aufzutauchen.
- **Manueller Aufruf:** `export INFA_PASSWORD='<wert>'` bzw. `$env:INFA_PASSWORD = '<wert>'`.

Ohne Variable fragt das Skript interaktiv nach dem Passwort - aus einem Workflow heraus (kein Terminal)
bricht es dann mit Exitcode 2 ab.

**3. Konfiguration anpassen** (`folder_backup.conf`, Format `KEY=VALUE`):

| Schluessel | Bash-Option | PowerShell-Parameter | Bedeutung |
|---|---|---|---|
| `REPO` | `-r` | `-Repository` | Repository-Name |
| `DOMAIN` | `-d` | `-Domain` | Domain-Name |
| `USER` | `-n` | `-User` | Repository-User |
| `SECDOMAIN` | `-s` | `-SecurityDomain` | Security Domain (LDAP) |
| `PASSVAR` | `-X` | `-PasswordVar` | Name der Variable mit dem verschluesselten Passwort (Standard `INFA_PASSWORD`) |
| `PMREP` | `-P` | `-Pmrep` | Pfad zu pmrep |
| `FOLDERS` | `-F` | `-Folders` | nur diese Folder (Standard: alle) |
| `SHARED` | `-S` | `-SharedFolders` | Shared Folder, werden zuerst gesichert (Standard: automatisch) |
| `EXCLUDE` | `-E` | `-Exclude` | Folder ausschliessen (Regex) |
| `TYPES` | `-t` | `-Types` | Objekttypen (Standard siehe unten) |
| `MODE` | `-m` | `-Mode` | `objects` oder `workflows` |
| `DEPS` | `--deps` | `-Deps` | `full` oder `none` |
| `BASEDIR` | `-b` | `-BackupDir` | Backup-Basisverzeichnis |
| `RETRIES` | `--retries` | `-Retries` | Wiederholungen je pmrep-Aufruf (Standard 2) |
| `KEEP` | `--keep` | `-Keep` | Anzahl aufzubewahrender erfolgreicher Backups (0 = alle) |
| `MIN_FREE_MB` | `--min-free-mb` | `-MinFreeMB` | Mindest-Speicherplatz (Standard 500) |
| `MAX_ERRORS` | `--max-errors` | `-MaxErrors` | Abbruch ab N Fehlern (0 = nie) |
| `FAIL_FAST` | `--fail-fast` | `-FailFast` | beim ersten Fehler abbrechen (`1`/`0`) |
| `PARTIAL_OK` | `--partial-ok` | `-PartialOk` | Exitcode 0 auch bei einzelnen Fehlern (`1`/`0`) |
| `ZIP` | `--zip` | `-Zip` | fehlerfreie Folder packen (`1`/`0`) |
| `GIT_REPO` | `--git` | `-GitRepo` | Exporte zusaetzlich in dieses Git-Repository uebernehmen (siehe unten) |
| `GIT_AUTHOR` | `--git-author` | `-GitAuthor` | Autor der Commits, `Name <mail>` |
| `GIT_PUSH` | `--git-push` | `-GitPush` | nach dem Commit pushen (`1`/`0`) |
| `INCR_QUERY` | `--incremental` | `-Incremental` | inkrementell: gespeicherte Repository-Query (siehe unten) |
| `QUERY_TYPE` | `--query-type` | `-QueryType` | `shared` (Standard) oder `personal` |
| `EXTRAS` | `--no-extras` | `-NoExtras` | ergaenzende Sicherungen (`1` = an, Standard; `0` bzw. Option = aus) |
| - | `--list` | `-List` | Trockenlauf: nur Folder und Objektanzahl |

Kommandozeilen-Optionen ueberschreiben Werte aus der Konfigurationsdatei.

**4. Trockenlauf** - zeigt Folder (Shared zuerst) und Objektanzahl je Typ, exportiert nichts:

```bash
./folder_backup.sh -c folder_backup.conf --list
```
```powershell
.\folder_backup.ps1 -ConfigFile .\folder_backup.conf -List
```

Steht bei einem Typ ueberall `0`, obwohl es Objekte gibt, oder erscheint eine Warnung
*„unbekanntes Format“*, die Rohausgabe unter `log/list_*.txt` pruefen (Typname je PowerCenter-Version,
z.B. `User Defined Function`).

## Modi

**`MODE=objects`** (Standard) - ein XML pro Objekt, nach Typ gruppiert. Die Verzeichnis-Praefixe
geben die Import-Reihenfolge vor:

| Verzeichnis | Typ (`-t`) |
|---|---|
| `01_source` | `source` |
| `02_target` | `target` |
| `03_user_defined_function` | `User Defined Function` |
| `04_transformation` | `transformation` (wiederverwendbare) |
| `05_mapplet` | `mapplet` |
| `06_mapping` | `mapping` |
| `07_sessionconfig` | `sessionconfig` |
| `08_task` | `task` (wiederverwendbare Command-/Email-/Timer-Tasks; nicht im Standard, bei Bedarf in `TYPES` aufnehmen) |
| `09_session` | `session` (wiederverwendbare) |
| `10_worklet` | `worklet` |
| `11_workflow` | `workflow` |

Nicht wiederverwendbare Objekte (z.B. Sessions innerhalb eines Workflows) stecken im Export ihres
Eltern-Objekts und werden nicht einzeln exportiert.

**`MODE=workflows`** - ein selbststaendiges XML pro Workflow mit allen Abhaengigkeiten. Ideal, um
einen kompletten Ablauf wiederherzustellen. Objekte, die zu keinem Workflow gehoeren, fehlen -
deshalb fuer die Vollsicherung `objects` verwenden.

**`DEPS=full`** (Standard) exportiert mit `-m -s -b -r`: jede Datei ist **einzeln** importierbar,
dafuer groesser (Sources/Targets stecken auch in jedem Mapping-Export). **`DEPS=none`** spart Platz,
der Restore funktioniert dann aber nur vollstaendig in der Reihenfolge von `import_order.txt`.

## Ergebnis

```
<BASEDIR>/
├── LATEST_SUCCESS                       letzte erfolgreiche Vollsicherung
├── LATEST_INCREMENTAL                   letzter erfolgreicher inkrementeller Lauf
├── PM_PROD_20261006_220000_inc/         inkrementeller Lauf (Marker-Datei INCREMENTAL, nur geaenderte Objekte)
├── PM_PROD_20261005_220000/
│   ├── SUCCESS | PARTIAL | FAILED       Statusdatei mit Zaehlern (waehrend des Laufs: RUNNING)
│   ├── backup.log                       Protokoll
│   ├── manifest.csv                     folder;typ;name;datei;bytes;sha256;status;meldung
│   ├── import_order.txt                 folder|xml-datei|control-file - in Import-Reihenfolge
│   ├── log/                             alle pmrep-Ausgaben (connect, listobjects, export je Objekt)
│   ├── _repository/                     ergaenzende Sicherungen (Connections, Folder, Checkouts, ...)
│   ├── SHARED/                          Shared Folder zuerst
│   │   ├── 01_source/ORA.CUST.xml
│   │   ├── 04_transformation/LKP_CUST.xml
│   │   └── import_ctrl.xml
│   └── DWH/
│       ├── 01_source/ ... 11_workflow/
│       ├── 06_mapping/m_trunc.xml.failed   fehlerhafter Export, nie importieren
│       └── import_ctrl.xml
└── .folder_backup.lock                  nur waehrend eines Laufs
```

Mit `ZIP=1` wird jeder fehlerfreie Folder zu `DWH.tar.gz` (Linux) bzw. `DWH.zip` (Windows) gepackt.

`import_ctrl.xml` je Folder enthaelt `FOLDERMAP`s fuer den Folder und die Shared Folder, auf die
seine Shortcuts zeigen, `REUSE` fuer alle Shortcuts (ein `REPLACE` wuerde bei Shortcuts Duplikate
`..._1` erzeugen) und `REPLACE` fuer alles andere.

## Fehlererkennung und -behandlung

| Pruefung | Reaktion |
|---|---|
| Parameter, Konfiguration, pmrep vorhanden | Abbruch, Exitcode 2 |
| zweiter Lauf parallel (Sperre `.folder_backup.lock`) | Abbruch, Exitcode 2; verwaiste Sperre (Prozess existiert nicht mehr) wird entfernt |
| Passwort-Variable fehlt (ohne Terminal) | Abbruch, Exitcode 2 |
| `connect` fehlgeschlagen | Abbruch, Exitcode 2, Hinweis auf `pmpasswd` |
| Speicherplatz unter `MIN_FREE_MB` (vor jedem Folder) | Abbruch, Exitcode 2 |
| pmrep-Aufruf fehlgeschlagen | bis zu `RETRIES` Wiederholungen mit steigender Wartezeit (5 s, 10 s, ...) und Neuverbindung |
| Export nach allen Wiederholungen fehlgeschlagen | `FEHLER` im Manifest, Lauf geht weiter |
| Export-Datei leer, ohne `</POWERMART>` oder ohne das Objekt | `FEHLER`, Datei wird zu `.xml.failed` |
| XML nicht wohlgeformt (Windows: .NET-Parser; Linux: `xmllint`, falls installiert) | `FEHLER`, `.xml.failed` |
| Folder aus `FOLDERS` existiert nicht | `FEHLER`, uebrige Folder werden gesichert |
| `listobjects` liefert unbekanntes Format | Warnung (sonst wuerde still nichts gesichert) |
| Shared Folder erst nachtraeglich erkannt | Warnung; `import_order.txt` beruecksichtigt ihn trotzdem zuerst |
| Archiv fehlerhaft (`ZIP`) | `FEHLER`, XML-Dateien bleiben erhalten |
| Fehlerzahl erreicht `MAX_ERRORS` bzw. `FAIL_FAST` | Abbruch, Status `FAILED`, Exitcode 2 |
| Inkrementell: Query nicht vorhanden / nicht ausfuehrbar | Abbruch, Status `FAILED`, Exitcode 2 |
| Inkrementell: Query-Treffer ohne wiederverwendbares Objekt | Info im Log (nicht wiederverwendbar, geloescht, ausserhalb des Umfangs) |
| Ergaenzende Sicherung fehlgeschlagen (z.B. `listconnections`) | Warnung - das Backup bleibt gueltig |
| ausgecheckte Objekte (versioniertes Repository) | Warnung - gesichert ist die zuletzt eingecheckte Version |
| Abbruch per Signal / Strg+C | Status `FAILED`, Sperre und Verbindungsdatei werden entfernt |

**Exitcodes:** `0` = SUCCESS (oder PARTIAL mit `PARTIAL_OK=1`), `1` = PARTIAL (einzelne Objekte fehlen),
`2` = FAILED (Abbruch).

**Aufbewahrung** (`KEEP`) laeuft nur nach einem erfolgreichen Lauf: geloescht wird alles, was aelter ist
als das N-te erfolgreiche Backup - fehlgeschlagene Laeufe dazwischen inklusive. Es bleiben also immer
mindestens N gute Backups. Pro Job ein eigenes `BASEDIR` verwenden, sonst raeumen sich Jobs mit
unterschiedlichem Umfang gegenseitig auf.

## Inkrementelles Backup

Bei grossen Repositories dauert die Vollsicherung lange (ein pmrep-Aufruf je Objekt). Ein inkrementeller Lauf
sichert nur die Objekte, die eine **gespeicherte Repository-Query** liefert - typischerweise alles, was in den
letzten Tagen gespeichert wurde.

**1. Query einmalig anlegen** (Repository Manager, als Shared Query, damit der Service-User sie ausfuehren darf):

1. *Tools → Queries → New*
2. Name: `Q_CHANGED_2D`, Typ: **Shared**
3. Bedingung: `Last saved time` - `Within last (days)` - `2`
4. Speichern. Test: `pmrep executequery -q Q_CHANGED_2D -t shared`

Zwei Tage statt einem Tag ueberlappen absichtlich: faellt ein Lauf aus, wird nichts verpasst. Mehrfach
gesicherte Objekte schaden nicht.

**2. Aufruf**

```bash
./folder_backup.sh -c folder_backup.conf --incremental Q_CHANGED_2D
```
```powershell
.\folder_backup.ps1 -ConfigFile .\folder_backup.conf -Incremental Q_CHANGED_2D
```

**Verhalten**

| | Vollsicherung | inkrementeller Lauf |
|---|---|---|
| Laufverzeichnis | `<REPO>_<Zeitstempel>` | `<REPO>_<Zeitstempel>_inc` + Marker `INCREMENTAL` |
| Umfang | alle Objekte der Folder | nur Query-Treffer (im Rahmen von `FOLDERS`, `EXCLUDE`, `TYPES`) |
| Zeiger | `LATEST_SUCCESS` | `LATEST_INCREMENTAL` |
| Aufbewahrung (`KEEP`) | zaehlt, raeumt auf | zaehlt nicht; aeltere inkrementelle Laeufe verschwinden mit der Vollsicherung |
| Git | spiegelt alles, entfernt geloeschte Objekte | aktualisiert nur, **loescht nie**; Control-Files werden zusammengefuehrt |
| geloeschte Objekte | erkannt | nicht erkennbar - erst die naechste Vollsicherung |

Die Query liefert Objekt-IDs, Folder, Typ und Name. Das Skript ordnet jeden Treffer ueber `listobjects` einem
wiederverwendbaren Objekt zu. Nicht wiederverwendbare Objekte (z.B. eine Session innerhalb eines Workflows)
werden nicht einzeln gesichert - der Workflow selbst wird beim Speichern mitgeaendert und ist dann Treffer.
Treffer ohne Zuordnung stehen in `log/query_candidates.txt`.

**Empfohlener Rhythmus:** taeglich inkrementell, woechentlich voll (siehe Workflow-Steuerung).

**Restore:** `folder_restore --with-incrementals` / `-WithIncrementals` legt alle neueren inkrementellen
Laeufe ueber die Vollsicherung - je Datei wird die neueste Version importiert (siehe Restore).

## Ergaenzende Sicherungen

Jeder Lauf (voll und inkrementell) schreibt zusaetzlich ein Verzeichnis `_repository/` - als Nachschlagewerk
fuer Dinge, die nicht in den Objekt-Exporten stehen. Abschalten mit `EXTRAS=0` / `--no-extras` / `-NoExtras`.

| Datei | Inhalt | pmrep |
|---|---|---|
| `connections.txt` | alle Connections mit Typ/Subtyp | `listconnections -t` |
| `connections/<name>.txt` | Details je Connection: User, Connect String, Code Page, Attribute - **ohne Passwort** (Zeilen mit „password“ werden entfernt) | `getconnectiondetails` |
| `folders.csv` | Folder, Shared, Owner, Gruppe, Permissions, Beschreibung (aus dem `FOLDER`-Element der Exporte) | - |
| `checkouts.txt` | ausgecheckte Objekte aller User (nur versionierte Repositories) | `findcheckout -u` |
| `labels.txt`, `deploymentgroups.txt`, `queries.txt` | Namen der globalen Objekte | `listobjects -o ...` |

- Fehler hier sind **Warnungen** - das Backup bleibt gueltig.
- Ausgecheckte Objekte erzeugen eine Warnung: im Backup steht die zuletzt **eingecheckte** Version.
- Wiederhergestellt wird `_repository/` nicht automatisch. Connections nach einem Restore in eine neue Umgebung
  anhand von `connections/` im Workflow Manager anlegen, Passwoerter separat.
- `permissions` stammt aus dem Export-Attribut und bildet die feingranularen Rechte neuerer Versionen
  (Objekt-Berechtigungen, Gruppen) nicht vollstaendig ab.
- Benutzer und Gruppen gehoeren zur Domain, nicht zum Repository - sie sind mit `infacmd isp` zu sichern
  (nicht Teil dieser Skripte).
- Mit Git-Versionierung wird `_repository/` mitversioniert: Aenderungen an Connections werden so sichtbar.

## Versionierung mit Git

Mit `GIT_REPO` (bzw. `--git` / `-GitRepo`) uebernimmt jeder Lauf die Exporte zusaetzlich in ein
Git-Repository und committet die Aenderungen. So entsteht eine **Aenderungshistorie je Objekt**:
wer wann was an einem Mapping geaendert hat, laesst sich mit `git log` / `git diff` nachvollziehen,
und jede fruehere Version ist abrufbar - auch wenn die Backup-Laeufe laengst aufgeraeumt sind.

```
<GIT_REPO>/
├── .gitattributes                 *.xml -text diff (keine Zeilenende-Konvertierung)
└── PM_PROD/
    ├── SHARED/01_source/ORA.CUST.xml
    ├── DWH/06_mapping/m_load_sales.xml
    └── DWH/import_ctrl.xml
```

| Regel | Grund |
|---|---|
| `CREATION_DATE` im XML-Kopf wird auf `01/01/1970 00:00:00` gesetzt | sonst aendert sich jede Datei bei jedem Lauf |
| identischer Stand → kein Commit | `[GIT] - keine Aenderungen gegenueber dem letzten Backup` |
| Objekt nicht mehr im Repository → Datei wird geloescht | Historie bleibt in Git erhalten |
| Export eines Objekts fehlgeschlagen → **letzte Version bleibt** | ein Fehler soll kein Loeschen vortaeuschen |
| Objektliste eines Folders nicht lesbar → in diesem Folder wird nichts geloescht | dito |
| Lauf mit `FOLDERS` (Teilmenge) → nur diese Folder werden angefasst | |
| Folder existiert nicht mehr (nur bei Sicherung aller Folder, nicht bei `EXCLUDE`) → wird entfernt | |
| Commit-Nachricht | `Backup PM_PROD 20261005_220000 (SUCCESS): 2 neu, 5 geaendert, 1 geloescht` |
| Git-Fehler (init, commit, push) | `FEHLER` im Lauf → Status `PARTIAL`; das Backup selbst bleibt gueltig |

Die Git-Kopien sind fuer **Historie und Vergleich** gedacht. Fuer den Restore die Backup-Laeufe verwenden
(unveraendert, mit Pruefsummen). Eine aeltere Version aus Git zurueckholen:

```bash
cd <GIT_REPO>
git log --oneline -- PM_PROD/DWH/06_mapping/m_load_sales.xml          # Historie eines Mappings
git diff HEAD~1 -- PM_PROD/DWH/06_mapping/m_load_sales.xml            # letzte Aenderung
git show <commit>:PM_PROD/DWH/06_mapping/m_load_sales.xml > m_load_sales_alt.xml
pmrep objectimport -i m_load_sales_alt.xml -c PM_PROD/DWH/import_ctrl.xml   # impcntl.dtd daneben legen
```
```powershell
Set-Location <GIT_REPO>
git log --oneline -- PM_PROD/DWH/06_mapping/m_load_sales.xml
git show "<commit>:PM_PROD/DWH/06_mapping/m_load_sales.xml" | Set-Content -Encoding Default m_load_sales_alt.xml
```

**Einrichtung:** `git` muss auf dem ausfuehrenden Rechner installiert sein. Das Repository wird beim ersten
Lauf angelegt. Fuer einen zentralen Server einmalig ein Remote einrichten und `GIT_PUSH=1` setzen:

```bash
git -C <GIT_REPO> remote add origin <url> && git -C <GIT_REPO> push -u origin HEAD
```

Der Autor kommt aus `GIT_AUTHOR` oder der git-Konfiguration des Service-Users. Zugangsdaten fuer den Push
(SSH-Schluessel oder Credential Helper) gehoeren zum Service-User, nicht in die Konfigurationsdatei.

## Steuerung aus einem Workflow

Empfohlen ist ein eigener Admin-Workflow mit einem **Command Task** (statt eines Pre-/Post-Session-Commands
einer Session - der braeuchte ein Dummy-Mapping und koppelt das Backup an eine Session).

```
wf_ADMIN_FOLDER_BACKUP
  Start ──► cmd_FOLDER_BACKUP ──[Status = SUCCEEDED]──► (optional) eml_BACKUP_OK
                       └────────[Status = FAILED]────► eml_BACKUP_FAILED
```

**Command Task `cmd_FOLDER_BACKUP`**
- Properties: *Fail task if any command fails* = aktiviert
- Command (Linux):
  ```
  $PMRootDir/scripts/folder_backup.sh -c $PMRootDir/scripts/folder_backup.conf
  ```
- Command (Windows):
  ```
  powershell -NoProfile -ExecutionPolicy Bypass -File $PMRootDir\scripts\folder_backup.ps1 -ConfigFile $PMRootDir\scripts\folder_backup.conf
  ```

Exitcode `1` oder `2` laesst den Task fehlschlagen. Soll der Workflow bei einzelnen fehlenden Objekten
weiterlaufen, `PARTIAL_OK=1` setzen und den Status ueber die Datei `PARTIAL` im Laufverzeichnis
auswerten (z.B. in einem zweiten Command Task).

**Links**
- `$cmd_FOLDER_BACKUP.Status = SUCCEEDED` → Erfolgs-Mail (optional)
- `$cmd_FOLDER_BACKUP.Status = FAILED` → Fehler-Mail mit Hinweis auf `<BASEDIR>/LATEST_SUCCESS` und das Log

**Parameter aus der Parameterdatei** - Command Tasks koennen Workflow-Variablen und -Parameter verwenden.
So laesst sich z.B. derselbe Workflow fuer unterschiedliche Folder-Gruppen nutzen:

```
[ADMIN.WF:wf_ADMIN_FOLDER_BACKUP]
$$BACKUP_FOLDERS=SHARED,DWH,STAGE
$$BACKUP_MODE=objects
```
```
$PMRootDir/scripts/folder_backup.sh -c $PMRootDir/scripts/folder_backup.conf -F $$BACKUP_FOLDERS -m $$BACKUP_MODE
```

**Zeitplan:** ausserhalb der Ladefenster (Exporte belasten den Repository Service), z.B.

| Workflow | Zeitplan | Command (Linux; Windows analog mit `folder_backup.ps1`) |
|---|---|---|
| `wf_ADMIN_FOLDER_BACKUP_FULL` | sonntags 22:00 | `$PMRootDir/scripts/folder_backup.sh -c $PMRootDir/scripts/folder_backup.conf` |
| `wf_ADMIN_FOLDER_BACKUP_INC` | Mo-Sa 22:00 | `$PMRootDir/scripts/folder_backup.sh -c $PMRootDir/scripts/folder_backup.conf --incremental Q_CHANGED_2D` |

Beide nutzen dasselbe `BASEDIR` - die Sperre verhindert, dass sie gleichzeitig laufen.
Der Workflow-User braucht Leserechte auf die Folder; das Skript laeuft unter dem Betriebssystem-User
des Integration Service - dieser braucht Schreibrecht auf `BASEDIR`.

## Restore mit folder_restore

`folder_restore.sh` / `folder_restore.ps1` importiert aus einem Backup-Lauf - alles, einzelne Folder oder
einzelne Objekte - in der Reihenfolge von `import_order.txt` (Shared Folder zuerst).

**Standard ist Trockenlauf:** Dateien bereitstellen, Pruefsummen gegen `manifest.csv` pruefen, Ziel-Folder
abgleichen, Plan schreiben. Importiert wird nur mit `--execute` / `-Execute` (mit Rueckfrage, ausser `--yes`).
Der Backup-Lauf wird nie veraendert: alles passiert in einem Arbeitsverzeichnis `restore_<REPO>_<Zeitstempel>/`.

```bash
# Trockenlauf: letzter erfolgreicher Lauf, ganzes Repository
./folder_restore.sh -c folder_backup.conf
# nur Folder DWH, ausfuehren
./folder_restore.sh -c folder_backup.conf -F DWH --execute
# ein einzelnes Mapping aus einem bestimmten Lauf
./folder_restore.sh -c folder_backup.conf -L PM_PROD_20261005_220000 -O 'DWH/06_mapping/m_load_sales' --execute
```
```powershell
.\folder_restore.ps1 -ConfigFile .\folder_backup.conf
.\folder_restore.ps1 -ConfigFile .\folder_backup.conf -Folders DWH -Execute
.\folder_restore.ps1 -ConfigFile .\folder_backup.conf -Run PM_PROD_20261005_220000 -ObjectFilter 'DWH/06_mapping/m_load_sales' -Execute
```

| Bash | PowerShell | Bedeutung |
|---|---|---|
| `-r REPO` | `-Repository` | **Ziel**-Repository; wird in allen Control-Files als `TARGETREPOSITORYNAME` gesetzt |
| `-d`, `-n`, `-s`, `-X`, `-P` | `-Domain`, `-User`, `-SecurityDomain`, `-PasswordVar`, `-Pmrep` | Verbindung wie beim Backup |
| `-b VERZ` | `-BackupDir` | Backup-Basisverzeichnis |
| `-L LAUF` | `-Run` | Backup-Lauf (Name oder Pfad); Standard: `LATEST_SUCCESS` |
| `--with-incrementals` | `-WithIncrementals` | neuere inkrementelle Laeufe ueberlagern: je Datei die neueste Version, Control-Files zusammengefuehrt; fehlgeschlagene inkrementelle Laeufe werden mit Warnung uebersprungen |
| `-F A,B` | `-Folders` | nur diese Folder |
| `-O REGEX` | `-ObjectFilter` | nur Dateien, deren Pfad passt |
| `--dtd DATEI` | `-Dtd` | `impcntl.dtd` (Standard: neben pmrep bzw. `$INFA_HOME/server/bin`) |
| `-w VERZ` | `-WorkDir` | Arbeitsverzeichnis |
| `--create-folders` | `-CreateFolders` | fehlende Ziel-Folder anlegen (`pmrep createfolder`, Shared-Eigenschaft aus dem Backup) |
| `--checkin TEXT` | `-Checkin` | versioniertes Repository: nach dem Import einchecken (`CHECKIN_AFTER_IMPORT`) |
| `--validate` | `-Validate` | importierte Mappings, Mapplets, Sessions, Worklets, Workflows mit `pmrep validate` pruefen |
| `--no-verify` | `-NoVerify` | Pruefsummen nicht kontrollieren |
| `--fail-fast`, `--max-errors N` | `-FailFast`, `-MaxErrors` | Abbruchgrenzen |
| `--execute`, `--yes` | `-Execute`, `-Yes` | importieren, ohne Rueckfrage |

Aus der Konfigurationsdatei werden nur die Verbindungs-Schluessel (`REPO`, `DOMAIN`, `USER`, `SECDOMAIN`,
`PASSVAR`, `PMREP`) und `BASEDIR` gelesen. **Achtung:** `REPO` ist beim Restore das Ziel - fuer einen Restore in
ein anderes Repository `-r` / `-Repository` angeben oder eine eigene Konfiguration verwenden.

**Was geprueft wird**

| Pruefung | Reaktion |
|---|---|
| Backup-Lauf `RUNNING` (abgebrochen) | Abbruch, Exitcode 2 |
| Backup-Lauf `PARTIAL` / `FAILED` | Warnung (fehlende Objekte stehen in `manifest.csv`) |
| Folder-Verzeichnis fehlt | Archiv `.tar.gz` / `.zip` wird ausgepackt, sonst `FEHLER` |
| Pruefsumme weicht von `manifest.csv` ab | `FEHLER`, Datei wird nicht importiert |
| Ziel-Folder fehlt | `FEHLER` - oder mit `--create-folders` anlegen |
| Import liefert Exitcode <> 0 oder Fehlerzeile | `FEHLER` im Report, Lauf geht weiter |
| Verbindungsverlust | einmal neu verbinden und wiederholen |
| Import meldet `renamed` | `WARNUNG` - ein Duplikat (z.B. `Shortcut_to_X1`) ist entstanden, siehe [REIMPORT.md](REIMPORT.md) |
| `--validate`: Objekt ungueltig | `FEHLER`, Spalte `validierung` = `UNGUELTIG` |

**Ergebnis** im Arbeitsverzeichnis: `restore_plan.txt` (alle pmrep-Befehle), `restore_report.csv`
(`folder;datei;import;validierung;meldung`), `restore.log`, `log/` (Ausgabe je Import), `src/` (Kopie der
importierten Dateien mit angepassten Control-Files). Exitcodes: `0` = OK, `1` = einzelne Fehler, `2` = Abbruch.

## Probe-Restore in ein Sandbox-Repository

> Ein Backup ist erst ein Backup, wenn der Restore geprobt wurde.

Ein zweiter Admin-Workflow spielt den letzten erfolgreichen Lauf regelmaessig (z.B. woechentlich) in ein
Sandbox-Repository ein und validiert die Workflows. Faellt der Probe-Restore aus, ist das Backup nicht
verlaesslich - lange bevor es gebraucht wird.

```
wf_ADMIN_RESTORE_TEST
  Start ──► cmd_RESTORE_TEST ──[Status = FAILED]──► eml_RESTORE_TEST_FAILED
```

Command (Linux bzw. Windows):

```
$PMRootDir/scripts/folder_restore.sh -c $PMRootDir/scripts/folder_backup.conf -r PM_SANDBOX --create-folders --validate --execute --yes
```
```
powershell -NoProfile -ExecutionPolicy Bypass -File $PMRootDir\scripts\folder_restore.ps1 -ConfigFile $PMRootDir\scripts\folder_backup.conf -Repository PM_SANDBOX -CreateFolders -Validate -Execute -Yes
```

Voraussetzungen: ein eigenes Sandbox-Repository (gleiche PowerCenter-Version) in derselben Domain, ein User mit
Schreibrecht dort (und dem Recht, Folder anzulegen), dasselbe oder ein eigenes verschluesseltes Passwort
(`PASSVAR`). Liegt die Sandbox in einer anderen Domain, eine eigene Konfigurationsdatei verwenden.
Ungueltige Objekte nach dem Import deuten oft auf fehlende Connections oder Abhaengigkeiten in der Sandbox
hin - sie sind nicht Teil der XML-Exporte.

## Restore ohne Skript

Falls `folder_restore` nicht verfuegbar ist - dieselbe Reihenfolge von Hand:

1. Laufverzeichnis waehlen (`<BASEDIR>/LATEST_SUCCESS`), gepackte Folder auspacken.
2. `impcntl.dtd` neben jedes `import_ctrl.xml` kopieren, bei anderem Ziel `TARGETREPOSITORYNAME` anpassen.
3. Mit dem Ziel-Repository verbinden und `import_order.txt` abarbeiten:

```bash
while IFS='|' read -r FOLDER XML CTRL; do
  pmrep objectimport -i "$XML" -c "$CTRL" -l "restore_$(echo "$XML" | tr '/' '_').log" || echo "FEHLER: $XML"
done < import_order.txt
```
```powershell
foreach ($line in Get-Content .\import_order.txt) {
  $folder, $xml, $ctrl = $line -split '\|'
  pmrep objectimport -i (Join-Path $PWD $xml) -c (Join-Path $PWD $ctrl) -l (Join-Path $PWD ('restore_' + ($xml -replace '[\\/]', '_') + '.log'))
  if ($LASTEXITCODE -ne 0) { "FEHLER: $xml" }
}
```

## Pruefen eines Backups

```bash
# Status und Zaehler
cat <LAUF>/SUCCESS <LAUF>/PARTIAL <LAUF>/FAILED 2>/dev/null
# fehlerhafte Objekte
grep ';FEHLER;' <LAUF>/manifest.csv
# Pruefsummen nachrechnen (z.B. nach Kopie auf ein anderes System)
awk -F';' 'NR>1 && $7=="OK" {print $6 "  " $4}' <LAUF>/manifest.csv | (cd <LAUF> && sha256sum -c --quiet -)
```
```powershell
Get-ChildItem <LAUF> -File | Where-Object Name -in 'SUCCESS', 'PARTIAL', 'FAILED' | Get-Content
Import-Csv <LAUF>\manifest.csv -Delimiter ';' | Where-Object status -eq 'FEHLER' | Format-Table folder, typ, name, meldung
Import-Csv <LAUF>\manifest.csv -Delimiter ';' | Where-Object status -eq 'OK' | ForEach-Object {
  if ((Get-FileHash -Algorithm SHA256 (Join-Path '<LAUF>' $_.datei)).Hash.ToLower() -ne $_.sha256) { "ABWEICHUNG: $($_.datei)" }
}
```
