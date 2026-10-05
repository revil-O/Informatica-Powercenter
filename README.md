# Informatica-Powercenter
Scripts &amp; useful things (administration) for data integration development using Informatica Powercenter

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
Passwort ueber Umgebungsvariable `INFA_PASSWORD` oder interaktive Abfrage (wird per `pmrep connect -X` uebergeben).
Hilfe: `./shortcut_repair.sh -h` bzw. `Get-Help .\shortcut_repair.ps1 -Full`.

Ablauf:
1. `pmrep listobjects` je Typ (source, target, mapplet, transformation) im Ordner
2. `pmrep objectexport` je Objekt, `<SHORTCUT>`-Element auswerten; Referenz im Shared Folder pruefen
   - `OK` - Referenz vorhanden
   - `ORPHAN` - kein Ordner/Objekt referenziert oder Referenz existiert nicht mehr
   - `EXPORT_FAILED` - Export schlug fehl, Status unbekannt
   - `GLOBAL_UNCHECKED` - globaler Shortcut, nicht geprueft
3. `pmrep listobjectdependencies -p parents` fuer verwaiste Shortcuts
4. Aktionen:
   - `LOESCHEN` - verwaist, von nichts verwendet, Typ source/target/mapplet (`pmrep deleteobject`)
   - `MANUELL_PRUEFEN` - noch verwendet (Mappings neu importieren), Transformation (Designer) oder Export fehlgeschlagen (`--include-suspect` / `-IncludeSuspect`)
   - `UMBENENNEN_IM_DESIGNER` - gueltiges Duplikat `X1` zu verwaistem `X`; pmrep kann nicht umbenennen

Ausgabe in `shortcut_repair_<Zeitstempel>/`: `report.csv` (Semikolon, Excel), `plan.txt`, `ctrl_reimport.xml`
(Control-File fuer sauberen Re-Import: FOLDERMAP inkl. Shared Folder, `REUSE` fuer Shortcuts, `REPLACE` fuer den Rest),
`xml/` (Exporte, dienen auch als Sicherung), `log/` (alle pmrep-Ausgaben), `run.log`.

Hinweise:
- Vorher Repository-Backup (`pmrep backup`) ziehen.
- Versioniertes Repository: geloeschte Objekte einchecken, ggf. `pmrep purgeversion`.
- Das Parsing der `listobjects`-Ausgabe kann je nach PowerCenter-Version abweichen - erst Trockenlauf und `report.csv` pruefen.
  Notfalls Objektliste selbst vorgeben: `-L objekte.txt` / `-ObjectFile objekte.txt` (Zeilen `typ|name[|subtyp]`, Sources als `DBD.NAME`).
