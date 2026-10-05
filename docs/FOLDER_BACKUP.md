# Folderweises Repository-Backup mit pmrep

Howto fuer `folder_backup.sh` (Linux) und `folder_backup.ps1` (Windows): Sicherung eines PowerCenter-Repositorys
**Folder fuer Folder** als importierbare XML-Exporte - erst die Shared Folder, danach alle anderen,
gruppiert nach Objekttyp in Import-Reihenfolge. Steuerbar als Command Task aus einem Workflow.

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
Deshalb: folderweises Backup **zusaetzlich** zu einem regelmaessigen `pmrep backup`, nicht statt dessen.

## Ablauf

```
connect ─► Folderliste ─► Shared Folder erkennen ─► Shared Folder zuerst, dann alle anderen
             │
             └─ je Folder, je Typ (source ... workflow):
                  listobjects ─► objectexport je Objekt ─► Pruefung ─► Manifest
                  (Fehler: Wiederholung mit Neuverbindung, danach FEHLER im Manifest, .xml.failed)
             └─ je Folder: import_ctrl.xml (Shortcuts REUSE), optional packen
         ─► import_order.txt ─► Status SUCCESS / PARTIAL / FAILED ─► Aufbewahrung ─► Exitcode
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
├── LATEST_SUCCESS                       Name des letzten erfolgreichen Laufs
├── PM_PROD_20261005_220000/
│   ├── SUCCESS | PARTIAL | FAILED       Statusdatei mit Zaehlern (waehrend des Laufs: RUNNING)
│   ├── backup.log                       Protokoll
│   ├── manifest.csv                     folder;typ;name;datei;bytes;sha256;status;meldung
│   ├── import_order.txt                 folder|xml-datei|control-file - in Import-Reihenfolge
│   ├── log/                             alle pmrep-Ausgaben (connect, listobjects, export je Objekt)
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
| Abbruch per Signal / Strg+C | Status `FAILED`, Sperre und Verbindungsdatei werden entfernt |

**Exitcodes:** `0` = SUCCESS (oder PARTIAL mit `PARTIAL_OK=1`), `1` = PARTIAL (einzelne Objekte fehlen),
`2` = FAILED (Abbruch).

**Aufbewahrung** (`KEEP`) laeuft nur nach einem erfolgreichen Lauf: geloescht wird alles, was aelter ist
als das N-te erfolgreiche Backup - fehlgeschlagene Laeufe dazwischen inklusive. Es bleiben also immer
mindestens N gute Backups. Pro Job ein eigenes `BASEDIR` verwenden, sonst raeumen sich Jobs mit
unterschiedlichem Umfang gegenseitig auf.

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

**Zeitplan:** taeglich ausserhalb der Ladefenster (Exporte belasten den Repository Service).
Der Workflow-User braucht Leserechte auf die Folder; das Skript laeuft unter dem Betriebssystem-User
des Integration Service - dieser braucht Schreibrecht auf `BASEDIR`.

## Restore

**Vorbereitung**
1. Laufverzeichnis waehlen - Name steht in `<BASEDIR>/LATEST_SUCCESS`. Bei `PARTIAL` im `manifest.csv`
   pruefen, welche Objekte fehlen.
2. Gepackte Folder auspacken (`tar xzf DWH.tar.gz` bzw. `Expand-Archive DWH.zip .`).
3. `impcntl.dtd` neben jedes `import_ctrl.xml` kopieren (der `DOCTYPE` verweist relativ darauf).
4. Bei Import in ein **anderes** Repository in jedem `import_ctrl.xml` `TARGETREPOSITORYNAME` anpassen.
5. Mit dem Ziel-Repository verbinden (`pmrep connect ... -X INFA_PASSWORD`).

**Alles in Reihenfolge importieren** (Shared Folder zuerst):

```bash
cd /data/infa_backup/folder/$(cat /data/infa_backup/folder/LATEST_SUCCESS)
for d in */; do cp "$INFA_HOME/server/bin/impcntl.dtd" "$d"; done
mkdir -p restore_log
while IFS='|' read -r FOLDER XML CTRL; do
  pmrep objectimport -i "$XML" -c "$CTRL" -l "restore_log/$(echo "$XML" | tr '/' '_').log" \
    || echo "FEHLER: $XML" | tee -a restore_log/fehler.txt
done < import_order.txt
```
```powershell
$base = 'D:\infa_backup\folder'
Set-Location (Join-Path $base (Get-Content (Join-Path $base 'LATEST_SUCCESS')))
Get-ChildItem -Directory | Where-Object Name -ne 'log' | ForEach-Object { Copy-Item "$env:INFA_HOME\server\bin\impcntl.dtd" $_.FullName }
New-Item -ItemType Directory -Force restore_log | Out-Null
foreach ($line in Get-Content .\import_order.txt) {
  $folder, $xml, $ctrl = $line -split '\|'
  $log = Join-Path $PWD ('restore_log\' + ($xml -replace '[\\/]', '_') + '.log')
  pmrep objectimport -i (Join-Path $PWD $xml) -c (Join-Path $PWD $ctrl) -l $log
  if ($LASTEXITCODE -ne 0) { "FEHLER: $xml" | Tee-Object -Append restore_log\fehler.txt }
}
```

**Nur einen Folder:** dieselbe Schleife ueber `grep '^DWH|' import_order.txt` bzw.
`Get-Content .\import_order.txt | Where-Object { $_ -like 'DWH|*' }`. Shared Folder vorher wiederherstellen,
falls deren Objekte im Ziel fehlen.

**Einzelnes Objekt:** die Datei direkt importieren - mit `DEPS=full` bringt sie alle Abhaengigkeiten mit:

```bash
pmrep objectimport -i DWH/06_mapping/m_load_sales.xml -c DWH/import_ctrl.xml -l restore_m_load_sales.log
```

**Danach:** Import-Logs auf `renamed`/`error` pruefen, Workflows validieren, einen Testlauf starten.

> Ein Backup ist erst ein Backup, wenn der Restore geprobt wurde: den Restore regelmaessig in ein
> Sandbox-Repository durchspielen.

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
