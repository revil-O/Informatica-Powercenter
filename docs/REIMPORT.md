# Re-Import-Ablauf fuer verwaiste Shortcuts

Anleitung fuer Shortcuts, die `shortcut_repair.sh` (Linux) / `shortcut_repair.ps1` (Windows) mit der Aktion **`REIMPORT`** markiert:
verwaist (keine gueltige Referenz in den Shared Folder), aber **noch von Mappings verwendet**.
Solche Shortcuts kann das Skript nicht einfach loeschen - die Verwender wuerden ungueltig.

> **Wichtig:** Der Ablauf veraendert Mappings, Sessions und Workflows. Nur im Wartungsfenster,
> mit Repository-Backup und erst in einer Test-Umgebung durchspielen.

Alle Befehle stehen fuer **Linux (bash)** und **Windows (PowerShell)** da. Die pmrep-Optionen sind auf beiden
Plattformen gleich, es unterscheiden sich nur Shell-Syntax, Pfade und die Hilfsbefehle zum Auswerten.

## Warum ein Re-Import noetig ist

Ein verwaister Shortcut laesst sich nicht reparieren, nur ersetzen:

| Konflikt-Aufloesung im Control-File | Ergebnis bei einem vorhandenen verwaisten Shortcut |
|---|---|
| `REUSE` | der kaputte Shortcut bleibt, die Mappings zeigen weiter darauf |
| `REPLACE` | bei Shortcuts nicht moeglich - der Import weicht auf `RENAME` aus und erzeugt `Shortcut_to_X1` |
| keiner vorhanden | der Import legt den Shortcut neu an, mit gueltiger Referenz auf den Shared Folder |

Deshalb muessen der verwaiste Shortcut **und** alle Objekte, die ihn verwenden, vor dem Import weg sein.

## Voraussetzungen

- [ ] Repository-Backup (`pmrep backup -o <datei>.rep`, Admin-Rechte) oder mindestens Export des ganzen Ordners
- [ ] Trockenlauf von `shortcut_repair` ist gelaufen, `report.csv` ist geprueft
- [ ] **Original-Export** der betroffenen Workflows aus dem Quell-Repository (siehe Schritt 2)
- [ ] Shared Folder existiert im Ziel-Repository und enthaelt die referenzierten Originalobjekte
- [ ] Schreibrechte auf den Ziel-Ordner, Leserechte auf den Shared Folder
- [ ] Keine der betroffenen Objekte ist ausgecheckt (versioniertes Repository)
- [ ] Betroffene Workflows sind nicht geplant/laufend (Scheduler pausieren)

## Ueberblick

| Schritt | Was | Werkzeug |
|---|---|---|
| 1 | Unbenutzte verwaiste Shortcuts loeschen, Duplikate umbenennen | `shortcut_repair --execute`, Designer |
| 2 | Original-Export bereitstellen | `pmrep objectexport` im Quell-Repository |
| 3 | Control-File pruefen | Editor |
| 4 | Verwender sichern | `reimport_plan.txt`, Teil 1 |
| 5 | Verwender und verwaisten Shortcut loeschen | `reimport_plan.txt`, Teil 2 |
| 6 | Re-Import | `pmrep objectimport` |
| 7 | Kontrolle und Aufraeumen | Trockenlauf, `pmrep validate` |

Die Dateien stammen aus dem Ausgabeverzeichnis des Trockenlaufs (`shortcut_repair_<Zeitstempel>/`):
`report.csv`, `plan.txt`, `reimport_plan.txt`, `ctrl_reimport.xml`, `xml/`, `log/`.
Die PowerShell-Version schreibt die Befehle in `plan.txt` / `reimport_plan.txt` direkt in PowerShell-Syntax (`& "pfad\pmrep.exe" ...`).

## Vorbereitung der Shell

**pmrep finden.** Liegt pmrep nicht im `PATH`, das Verzeichnis voranstellen:

```bash
export PATH="$INFA_HOME/server/bin:$PATH"          # Informatica-Server unter Linux
pmrep help connect >/dev/null && echo "pmrep ok"
```
```powershell
# Server-Installation
$env:Path = "$env:INFA_HOME\server\bin;$env:Path"
# oder PowerCenter-Client, z.B.:
# $env:Path = "C:\Informatica\10.5.0\clients\PowerCenterClient\client\bin;$env:Path"
Get-Command pmrep
```

Auf einem Windows-Client braucht pmrep die Domain-Datei. Meldet `connect` einen Fehler zu `domains.infa`,
die Variable setzen: `$env:INFA_DOMAINS_FILE = "C:\Informatica\10.5.0\domains.infa"` (Pfad je Installation).

**Verbinden ohne Passwort auf der Kommandozeile.** pmrep liest das Passwort mit `-X` aus einer Umgebungsvariable:

```bash
read -rs -p "Passwort: " INFA_PASSWORD; echo; export INFA_PASSWORD
pmrep connect -r PM_PROD_REPO -d Prod_Domain -n admin -X INFA_PASSWORD
unset INFA_PASSWORD
```
```powershell
$sec  = Read-Host -AsSecureString "Passwort"
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
$env:INFA_PASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
pmrep connect -r PM_PROD_REPO -d Prod_Domain -n admin -X INFA_PASSWORD
Remove-Item Env:INFA_PASSWORD
```

Die Verbindung gilt fuer alle folgenden pmrep-Aufrufe in derselben Shell. Fuer Schritt 2 (Quell-Repository)
und die Schritte 4-7 (Ziel-Repository) jeweils neu verbinden.

**Erfolg pruefen.** pmrep liefert 0 bei Erfolg - nach jedem loeschenden oder importierenden Befehl kontrollieren:

```bash
echo $?
```
```powershell
$LASTEXITCODE
```

## Schritt 1 - Einfache Faelle zuerst

Erst alles erledigen, was ohne Re-Import geht. Sonst stoeren diese Objekte den Import.

```bash
./shortcut_repair.sh -r PM_PROD_REPO -d Prod_Domain -n admin -f DWH --execute
```
```powershell
.\shortcut_repair.ps1 -Repository PM_PROD_REPO -Domain Prod_Domain -User admin -Folder DWH -Execute
```

Danach im Designer die Duplikate aus `plan.txt` umbenennen (Aktion `UMBENENNEN_IM_DESIGNER`,
z.B. `Shortcut_to_CUST1` -> `Shortcut_to_CUST`) und speichern bzw. einchecken.

Anschliessend **neuen Trockenlauf** starten. Ab hier mit dessen Ausgabe weiterarbeiten -
`reimport_plan.txt` und `ctrl_reimport.xml` passen dann zum aktuellen Stand.

## Schritt 2 - Original-Export bereitstellen

Der Re-Import braucht die Objekte in ihrem **korrekten** Zustand - aus dem Quell-Repository
(z.B. Entwicklung), aus dem urspruenglich importiert wurde. Exportiert wird auf **Workflow-Ebene**,
damit Mappings, Sessions und Workflows gemeinsam und konsistent zurueckkommen:

```bash
pmrep connect -r PM_DEV_REPO -d Dev_Domain -n admin -X INFA_PASSWORD
pmrep objectexport -o workflow -f DWH -n wf_load_sales -m -s -b -r -u wf_load_sales.xml
```
```powershell
pmrep connect -r PM_DEV_REPO -d Dev_Domain -n admin -X INFA_PASSWORD
pmrep objectexport -o workflow -f DWH -n wf_load_sales -m -s -b -r -u "$PWD\wf_load_sales.xml"
```

Unter Windows fuer `-u` einen absoluten Pfad angeben (`$PWD\...`) - sonst landet die Datei je nach Installation
im pmrep-Verzeichnis.

| Option | Bedeutung |
|---|---|
| `-m` | Primaer-/Fremdschluessel-Abhaengigkeiten mitexportieren |
| `-s` | Objekte mitexportieren, auf die Shortcuts zeigen |
| `-b` | nicht wiederverwendbare Abhaengigkeiten |
| `-r` | wiederverwendbare Abhaengigkeiten |

Welche Workflows betroffen sind, steht in `reimport_plan.txt` (Verwender) und in `log/deps_*.txt`.
Fuer Sessions den Workflow ermitteln:

```bash
pmrep listobjectdependencies -n s_m_load_sales -o session -f DWH -p parents
```
```powershell
pmrep listobjectdependencies -n s_m_load_sales -o session -f DWH -p parents
```

Im Export pruefen, dass die Shortcuts auf den richtigen Shared Folder zeigen:

```bash
# je Shortcut: Name, referenziertes Objekt, Shared Folder, Repository
grep -o '<SHORTCUT [^>]*>' wf_load_sales.xml | grep -o ' \(NAME\|REFOBJECTNAME\|FOLDERNAME\|REPOSITORYNAME\) *="[^"]*"' | paste - - - -
# Repository, aus dem der Export stammt
grep -o '<REPOSITORY NAME *="[^"]*"' wf_load_sales.xml
```
```powershell
# je Shortcut: Name, referenziertes Objekt, Shared Folder, Repository
Select-String -Path .\wf_load_sales.xml -Pattern '<SHORTCUT [^>]*>' -AllMatches |
  ForEach-Object { $_.Matches } | ForEach-Object {
    $a = @{}; foreach ($m in [regex]::Matches($_.Value, '(\w+) *="([^"]*)"')) { $a[$m.Groups[1].Value] = $m.Groups[2].Value }
    [pscustomobject]@{ NAME = $a.NAME; REFOBJECTNAME = $a.REFOBJECTNAME; FOLDERNAME = $a.FOLDERNAME; REPOSITORYNAME = $a.REPOSITORYNAME }
  } | Format-Table -AutoSize
# Repository, aus dem der Export stammt
Select-String -Path .\wf_load_sales.xml -Pattern '<REPOSITORY NAME *="([^"]*)"' | ForEach-Object { $_.Matches[0].Groups[1].Value }
```

## Schritt 3 - Control-File pruefen

`ctrl_reimport.xml` ist ein Vorschlag. Vor dem Import abgleichen:

1. **`SOURCEREPOSITORYNAME`** muss exakt dem `<REPOSITORY NAME="...">` im Export entsprechen.
   Kommt der Export aus einem anderen Repository als dem, auf dem das Skript lief, mit `-R` / `-SourceRepository`
   neu erzeugen oder von Hand anpassen.
2. **Je ein `FOLDERMAP`** fuer den Ziel-Ordner **und** jeden Shared Folder, auf den die Shortcuts im Export zeigen
   (`FOLDERNAME` aus Schritt 2). Fehlt der Shared Folder, verlieren die Shortcuts beim Import wieder ihre Referenz.
3. **Kommentare `vor dem Import loeschen/klaeren`**: Jedes dort genannte Objekt muss vor Schritt 6 geloescht sein.
4. **`REUSE`** steht nur bei gueltigen Shortcuts. `TYPEOBJECT All REPLACE` ersetzt alles andere (Mappings, Sessions, ...).

Beispiel:

```xml
<!DOCTYPE IMPORTPARAMS SYSTEM "impcntl.dtd">
<IMPORTPARAMS CHECKIN_AFTER_IMPORT="NO" RETAIN_GENERATED_VALUE="YES">
  <FOLDERMAP SOURCEFOLDERNAME="DWH" SOURCEREPOSITORYNAME="PM_DEV_REPO" TARGETFOLDERNAME="DWH" TARGETREPOSITORYNAME="PM_PROD_REPO"/>
  <FOLDERMAP SOURCEFOLDERNAME="SHARED" SOURCEREPOSITORYNAME="PM_DEV_REPO" TARGETFOLDERNAME="SHARED" TARGETREPOSITORYNAME="PM_PROD_REPO"/>
  <!-- vor dem Import loeschen/klaeren: target Shortcut_to_T_OLD (ORPHAN) -->
  <RESOLVECONFLICT>
    <SPECIFICOBJECT NAME="Shortcut_to_CUST" DBDNAME="ORA" OBJECTTYPENAME="Source Definition" FOLDERNAME="DWH" REPOSITORYNAME="PM_DEV_REPO" RESOLUTION="REUSE"/>
    <TYPEOBJECT OBJECTTYPENAME="All" RESOLUTION="REPLACE"/>
  </RESOLVECONFLICT>
</IMPORTPARAMS>
```

`impcntl.dtd` liegt im pmrep-Verzeichnis (`server/bin` bzw. `client/bin`). Liegt das Control-File woanders,
die DTD daneben kopieren oder den Pfad im `DOCTYPE` anpassen:

```bash
cp "$INFA_HOME/server/bin/impcntl.dtd" .
```
```powershell
Copy-Item "$env:INFA_HOME\server\bin\impcntl.dtd" .
# Client: Copy-Item "C:\Informatica\10.5.0\clients\PowerCenterClient\client\bin\impcntl.dtd" .
```

Das Control-File in einem Editor bearbeiten, der UTF-8 **ohne BOM** speichert (Notepad++ / VS Code; das alte
Windows-Notepad fuegt ein BOM ein). Unter PowerShell nicht mit `Set-Content`/`Out-File` von Windows PowerShell 5.1
schreiben - die setzen je nach Version ein BOM bzw. UTF-16.

## Schritt 4 - Verwender sichern

Die Befehle stehen in `reimport_plan.txt` unter `# 1. Verwender sichern`, je verwaistem Shortcut:

```bash
pmrep objectexport -o mapping -f DWH -n m_load_sales -m -s -b -r -u backup_mapping_m_load_sales.xml
```
```powershell
pmrep objectexport -o mapping -f DWH -n m_load_sales -m -s -b -r -u "$PWD\backup_mapping_m_load_sales.xml"
```

Zusaetzlich die betroffenen Workflows im **Ziel**-Repository exportieren - das ist der Rueckweg, falls der Import scheitert:

```bash
pmrep objectexport -o workflow -f DWH -n wf_load_sales -m -s -b -r -u backup_wf_load_sales.xml
```
```powershell
pmrep objectexport -o workflow -f DWH -n wf_load_sales -m -s -b -r -u "$PWD\backup_wf_load_sales.xml"
```

Pruefen, dass alle Dateien existieren und nicht leer sind, bevor es weitergeht:

```bash
ls -l backup_*.xml; for f in backup_*.xml; do [ -s "$f" ] || echo "LEER: $f"; done
```
```powershell
Get-ChildItem .\backup_*.xml | Select-Object Name, Length
Get-ChildItem .\backup_*.xml | Where-Object Length -eq 0 | ForEach-Object { "LEER: $($_.Name)" }
```

## Schritt 5 - Verwender und verwaisten Shortcut loeschen

Befehle aus `reimport_plan.txt` unter `# 2.` - **in genau dieser Reihenfolge**: erst die Mappings, dann der Shortcut.

```bash
pmrep deleteobject -o mapping -f DWH -n m_load_sales && \
pmrep deleteobject -o target  -f DWH -n Shortcut_to_T_OLD
```
```powershell
pmrep deleteobject -o mapping -f DWH -n m_load_sales
if ($LASTEXITCODE -eq 0) { pmrep deleteobject -o target -f DWH -n Shortcut_to_T_OLD }
```

Der zweite Befehl laeuft nur, wenn der erste erfolgreich war.

- Sessions, Worklets und Workflows, die die Mappings nutzen, werden **nicht** geloescht - sie werden beim Import
  ersetzt (`REPLACE`). Deshalb muss der Export aus Schritt 2 sie enthalten.
- Transformations-Shortcuts kann `pmrep deleteobject` nicht loeschen: im Designer (Transformation Developer) loeschen.
- Sources werden mit DBD-Praefix angegeben: `-n ORA.Shortcut_to_CUST`.
- **Versioniertes Repository:** geloeschte Objekte einchecken, sonst blockieren sie den Namen:
  ```bash
  pmrep checkin -o target -f DWH -n Shortcut_to_T_OLD -c "verwaisten Shortcut entfernt"
  ```
  ```powershell
  pmrep checkin -o target -f DWH -n Shortcut_to_T_OLD -c "verwaisten Shortcut entfernt"
  ```

Kontrolle - der Shortcut darf nicht mehr gelistet werden:

```bash
pmrep listobjects -o target -f DWH | grep -iw Shortcut_to_T_OLD || echo "geloescht"
```
```powershell
if (-not (pmrep listobjects -o target -f DWH | Select-String -Pattern '\bShortcut_to_T_OLD\b')) { 'geloescht' }
```

## Schritt 6 - Re-Import

```bash
pmrep objectimport -i wf_load_sales.xml -c ctrl_reimport.xml -l import_wf_load_sales.log
```
```powershell
pmrep objectimport -i "$PWD\wf_load_sales.xml" -c "$PWD\ctrl_reimport.xml" -l "$PWD\import_wf_load_sales.log"
"Exitcode: $LASTEXITCODE"
```

Log nach Problemen durchsuchen:

```bash
grep -inE 'renamed|error|failed|not found|invalid' import_wf_load_sales.log
```
```powershell
Select-String -Path .\import_wf_load_sales.log -Pattern 'renamed|error|failed|not found|invalid'
```

Im Import-Log achten auf:

| Meldung | Bedeutung |
|---|---|
| `renamed` / neue Namen mit Zahl am Ende | ein Objekt existierte noch - Schritt 5 unvollstaendig, Duplikat entstanden |
| `shortcut ... not found` / `invalid` | `FOLDERMAP` fuer den Shared Folder fehlt oder Name falsch (Schritt 3) |
| `Failed` / `Error` | Import abgebrochen - Rueckweg siehe unten |
| `successfully imported` | Objekt angelegt bzw. ersetzt |

## Schritt 7 - Kontrolle und Aufraeumen

1. **Neuer Trockenlauf** von `shortcut_repair` auf den Ordner. Erwartet:
   kein `ORPHAN`, kein `REIMPORT`, keine neuen Zahlen-Duplikate.
   ```bash
   ./shortcut_repair.sh -r PM_PROD_REPO -d Prod_Domain -n admin -f DWH
   ```
   ```powershell
   .\shortcut_repair.ps1 -Repository PM_PROD_REPO -Domain Prod_Domain -User admin -Folder DWH
   Import-Csv (Get-ChildItem .\shortcut_repair_*\report.csv | Sort-Object LastWriteTime | Select-Object -Last 1) -Delimiter ';' |
     Where-Object aktion -ne 'KEINE' | Format-Table typ, name, status, aktion
   ```
2. **Validieren** der wieder importierten Mappings, Sessions und Workflows:
   ```bash
   pmrep validate -n m_load_sales -o mapping -f DWH -s
   pmrep validate -n wf_load_sales -o workflow -f DWH -s
   ```
   ```powershell
   pmrep validate -n m_load_sales -o mapping -f DWH -s
   pmrep validate -n wf_load_sales -o workflow -f DWH -s
   ```
3. **Alte Duplikate** (Aktion `NACH_BASIS_PRUEFEN`, z.B. `Shortcut_to_T_OLD1`) entfernen, sobald sie unbenutzt sind:
   ```bash
   pmrep listobjectdependencies -n Shortcut_to_T_OLD1 -o target -f DWH -p parents
   pmrep deleteobject -o target -f DWH -n Shortcut_to_T_OLD1
   ```
   ```powershell
   pmrep listobjectdependencies -n Shortcut_to_T_OLD1 -o target -f DWH -p parents
   pmrep deleteobject -o target -f DWH -n Shortcut_to_T_OLD1
   ```
4. **Versioniertes Repository:** alles einchecken.
5. Workflow-Scheduler wieder aktivieren, einen Testlauf starten.

## Rueckweg bei Fehlern

| Situation | Vorgehen |
|---|---|
| Import scheitert, Objekte fehlen | Sicherung aus Schritt 4 importieren: `pmrep objectimport -i backup_wf_load_sales.xml -c ctrl_reimport.xml` (Windows: absolute Pfade, z.B. `"$PWD\backup_wf_load_sales.xml"`) |
| wieder Zahlen-Duplikate entstanden | Duplikate loeschen, Schritt 5 vollstaendig wiederholen (verwaister Shortcut noch da? eingecheckt?), dann Schritt 6 |
| Shortcuts nach Import wieder verwaist | `FOLDERMAP` / `SOURCEREPOSITORYNAME` gegen den Export pruefen (Schritt 3), Originalobjekt im Shared Folder vorhanden? |
| alles verloren | Repository-Backup zuruecksichern (`pmrep restore`, Admin) |

## Checkliste

- [ ] pmrep im PATH, Verbindung mit `-X` (Passwort nicht auf der Kommandozeile)
- [ ] Backup vorhanden
- [ ] Schritt 1 ausgefuehrt, neuer Trockenlauf
- [ ] Original-Export auf Workflow-Ebene (`-m -s -b -r`)
- [ ] Control-File: Repository-Namen, `FOLDERMAP` inkl. Shared Folder
- [ ] Verwender gesichert (Mapping- **und** Workflow-Ebene)
- [ ] Mappings geloescht, dann verwaister Shortcut (Transformationen im Designer), eingecheckt
- [ ] Import ohne `renamed` im Log
- [ ] Trockenlauf sauber, Validierung ok, alte Duplikate entfernt
- [ ] Scheduler wieder aktiv, Testlauf ok
