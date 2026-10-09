# SQL fuer das PowerCenter-Repository

Abfragen direkt auf die Repository-Datenbank (nur lesend) - auf Basis der **Repository-Tabellen**
(`OPB_*` und `REP_*`-Tabellen wie `REP_FLD_DATATYPE`), nicht der MX-Views. Aufbau:

```
sql/
├── oracle/                         Repository auf Oracle
│   ├── check_repository_columns.sql    Vorpruefung: passen Tabellen/Spalten zum Adapter?
│   ├── diag_io_waits.sql               Diagnose "db file sequential read" (Ziel-/Quelldatenbank, nicht Repository)
│   └── port_lineage.sql                Port-Lineage Source -> Transformationen -> Target
└── test/                           Test ohne Oracle (SQLite, nachgebautes Repository)
```

> Die Repository-Tabellen sind nur zum **Lesen** gedacht. Niemals per SQL aendern - Aenderungen nur ueber die
> PowerCenter-Clients bzw. `pmrep`.

## Port-Lineage (`oracle/port_lineage.sql`)

Verfolgt jeden Port von seinem Ursprung ueber alle Transformationen bis in die Target-Spalte - **eine Zeile je
Schritt**, mit Datentyp, Praezision und Scale des Ports in jeder Transformation und der Expression bei
berechneten Ports. Neben den Links im Mapping werden auch die **logischen Verbindungen** verfolgt, die in
Expressions entstehen.

### Kanten

| `KANTE` | Bedeutung | Beispiel |
|---|---|---|
| `START` | Ursprung des Pfads: Port ohne eingehende Verbindung | Source-Feld, `SYSDATE`, Konstante, Sequence |
| `LINK` | Link zwischen zwei Instanzen | `SQ_CUSTOMER.CUST_ID -> EXP_NAME.CUST_ID` |
| `EXPR` | Ausgabe-/Variablenport verwendet einen Eingabe-/Variablenport derselben Transformation in seiner Expression | `FIRST_NAME -> O_FULL_NAME` (`LTRIM(FIRST_NAME) \|\| ' ' \|\| LAST_NAME`) |
| `LKP_ARG` | Port aus einer Expression mit `:LKP.`/`:SP.`-Aufruf -> Eingabeports des aufgerufenen Lookups | `V_CTRY -> LKP_COUNTRY.IN_CODE` |
| `LKP_COND` | Lookup: Eingabeport aus der Lookup-Bedingung -> Ausgabeports des Lookups | `IN_COUNTRY -> REGION` |
| `LKP_CALL` | Rueckgabeport des aufgerufenen Lookups / der Stored Procedure -> aufrufender Port | `LKP_COUNTRY.COUNTRY_NAME -> EXP_NAME.O_COUNTRY_NAME` |
| `GROUP` | Router, Union, Normalizer: Eingabegruppe -> gleichnamiger Port der Ausgabegruppe | `RTR_CTRY.CUST_ID -> RTR_CTRY.CUST_ID1` |

Input/Output-Ports, die nur durchgereicht werden (Source Qualifier, Joiner, Aggregator, Sorter, Filter, ...),
sind ein und derselbe Port und erscheinen als ein Schritt.

### Beispiel

```
PFAD_ID 5: CUSTOMER.COUNTRY -> SQ_CUSTOMER.COUNTRY -> EXP_NAME.COUNTRY -> EXP_NAME.V_CTRY -> LKP_COUNTRY.IN_CODE
           -> LKP_COUNTRY.COUNTRY_NAME -> EXP_NAME.O_COUNTRY_NAME -> T_CUSTOMER.COUNTRY_NAME

SCHRITT KANTE    INSTANZ      OBJEKTTYP          PORT            PORTTYP       DATENTYP     EXPRESSION
      1 START    CUSTOMER     Source Definition  COUNTRY         Source        char(2)
      2 LINK     SQ_CUSTOMER  Source Qualifier   COUNTRY         Input/Output  string(2)
      3 LINK     EXP_NAME     Expression         COUNTRY         Input         string(2)
      4 EXPR     EXP_NAME     Expression         V_CTRY          Variable      string(2)    UPPER(COUNTRY)
      5 LKP_ARG  LKP_COUNTRY  Lookup Procedure   IN_CODE         Input         string(2)
      6 LKP_COND LKP_COUNTRY  Lookup Procedure   COUNTRY_NAME    Lookup/Output string(50)
      7 LKP_CALL EXP_NAME     Expression         O_COUNTRY_NAME  Output        string(50)   :LKP.LKP_COUNTRY(V_CTRY)
      8 LINK     T_CUSTOMER   Target Definition  COUNTRY_NAME    Target        varchar2(50)
```

Ergebnisspalten: `FOLDER`, `MAPPING`, `PFAD_ID`, `SCHRITT`, `SCHRITTE`, `KANTE`, `INSTANZ`, `OBJEKTTYP`, `PORT`,
`PORTTYP`, `DATENTYP`, `EXPRESSION`, `PFAD` (gesamte Kette als Text). Fuer eine Uebersicht nur die Zeilen mit
`SCHRITT = 1` nehmen; fuer die Weitergabe in SQL Developer als Excel/CSV exportieren.

### Ausfuehren

1. **Vorpruefung** einmal je Repository: `oracle/check_repository_columns.sql` als Repository-Owner ausfuehren.
   - Teil 1 vergleicht die vom Adapter erwarteten Spalten mit dem Data Dictionary. Alles `OK` -> weiter.
   - Bei `FEHLT` / `TABELLE/VIEW FEHLT` die Namen im Abschnitt **ADAPTER** von `port_lineage.sql` anpassen.
     Teil 2 listet dafuer die tatsaechlichen Spalten der Objekte.
   - Teil 3c/3d zeigen Datentyp-Codes ohne Namen (erscheinen sonst als `Code n`), Teil 3e die Lookup-Attribute
     (erwartet: `Lookup condition...`).
2. **Parameter** im Block `params` von `port_lineage.sql` setzen:

   | Parameter | Bedeutung | Beispiel |
   |---|---|---|
   | `p_folder` | Folder (LIKE) | `'DWH'` |
   | `p_mapping` | Mapping oder Mapplet (LIKE) - moeglichst eng | `'m_load_sales'` |
   | `p_start_port` | Ursprung `INSTANZ.PORT` (LIKE) | `'CUSTOMER.%'` |
   | `p_end_port` | Ziel `INSTANZ.PORT` (LIKE) | `'T_CUSTOMER.FULL_NAME'` |
   | `p_end_mode` | `TARGET` = nur Pfade bis in ein Target, `ALL` = auch Sackgassen | `'TARGET'` |
   | `p_max_depth` | maximale Pfadlaenge | `60` |

3. In SQL Developer / SQL*Plus als Repository-Owner (oder mit Leserecht auf die Tabellen) ausfuehren.
   Voraussetzung: Oracle 11gR2 oder neuer (rekursive `WITH`-Klausel, `XMLAGG` fuer die Expressions).

### Aufbau

```
params ─► ADAPTER (mp, inst, link, expr, fld_trans, dtname, fld_src, fld_tgt, attr)  <- einzige Stelle mit Tabellennamen
       ─► port      alle Ports der Instanzen (Transformationen, Sources, Targets)
       ─► edge      Kanten LINK, EXPR, LKP_ARG, LKP_COND, LKP_CALL, GROUP (je Portpaar eine)
       ─► root      Ursprungsports (ausgehende, keine eingehende Kante)
       ─► walk      rekursiv vorwaerts, Zyklenschutz ueber den bisherigen Pfad, Tiefenlimit
       ─► leaf      Pfadenden (Target bzw. alle Sackgassen)
       ─► Ausgabe   je Pfad alle Schritte mit Port-Details
```

Verwendete Tabellen:

| Tabelle | Inhalt |
|---|---|
| `OPB_SUBJECT`, `OPB_MAPPING` | Folder, Mappings/Mapplets (sichtbare Version) |
| `OPB_WIDGET_INST`, `OPB_OBJECT_TYPE` | Instanzen im Mapping, Name des Objekttyps |
| `OPB_WIDGET_DEP` | Port-Links zwischen Instanzen |
| `OPB_WIDGET_FIELD`, `REP_FLD_DATATYPE` | Ports der Transformationen, Name des Datentyps |
| `OPB_WIDGET_EXPR`, `OPB_EXPRESSION` | Expression je Ausgabeport (zeilenweise gespeichert, per `XMLAGG` zusammengesetzt) |
| `OPB_SRC_FLD`, `OPB_TARG_FLD`, `OPB_MMD_DATATYPE` | Felder von Sources/Targets, Name des nativen Datentyps |
| `OPB_WIDGET_ATTR`, `OPB_ATTR` | Transformations-Attribute mit Namen (Lookup-Bedingung) |

Versionierte Repositories: Mapping in der sichtbaren Version (`IS_VISIBLE = 1`), Instanzen und Links in dieser
Version; Ports, Expressions, Attribute und Source-/Target-Felder in der hoechsten Version je Objekt.

### Grenzen

- **Spaltennamen:** Die Repository-Tabellen sind nicht oeffentlich dokumentiert und koennen je Version abweichen.
  Die Namen im Adapter stammen aus verbreiteten Repository-Abfragen - deshalb zuerst die Vorpruefung.
  Am unsichersten: Praezision/Scale in `OPB_SRC_FLD`/`OPB_TARG_FLD` (`DPREC`/`DSCALE`) und die Zuordnung der
  Datentyp-Codes (Teil 3c/3d der Vorpruefung).
- **Expressions werden textuell ausgewertet:** ein Portname in einem String-Literal oder Kommentar erzeugt eine
  ueberzaehlige `EXPR`-Kante. Die Expression wird vollstaendig aus allen Zeilen von `OPB_EXPRESSION` zusammengesetzt
  (CLOB, keine Laengengrenze); in der Ergebnisspalte `EXPRESSION` stehen die ersten 4000 Zeichen.
- **`:LKP`-Argumente** werden nicht positionsgenau zugeordnet: alle Ports der aufrufenden Expression fuehren zu
  allen Eingabeports des Lookups. Ebenso fuehrt `LKP_CALL` von allen Ausgabeports des aufgerufenen Lookups.
- **Router/Union/Normalizer** werden ueber den Portnamen ohne Ziffern am Ende verbunden; Ports wie `ADDR1`/`ADDR2`
  in derselben Gruppe koennen dadurch zusaetzlich verbunden werden.
- **Mapplets:** Eine Mapplet-Instanz wird nicht aufgeloest. Den Weg durch das Mapplet liefert ein eigener Lauf mit
  `p_mapping` = Mapplet-Name.
- **SQL-Override, Source Filter, Join-Bedingungen** im Source Qualifier und **Mapping-Parameter/-Variablen**
  (`$$...`) werden nicht als Kanten ausgewertet; Parameter sind in der Spalte `EXPRESSION` sichtbar.
- **Shortcuts** (z.B. Sources aus dem Shared Folder): Fehlen bei Shortcut-Instanzen die Ports, verweist die
  Instanz auf das Shortcut-Objekt statt auf das Original - dann im Adapter die Aufloesung ueber die
  Shortcut-Tabelle ergaenzen.
- **Laufzeit:** Die Zahl der Pfade waechst mit der Verzweigung des Mappings. `p_mapping` eng waehlen und bei
  Bedarf mit `p_start_port` / `p_end_port` einschraenken.

### Test ohne Oracle

`test/` enthaelt ein in SQLite nachgebautes Repository mit dem Beispiel-Mapping `m_load_sales` (Source,
Source Qualifier, Expression mit Variablenport und `:LKP`-Aufruf, verbundener Lookup, Router, Target).
Die Oracle-Funktionen `REGEXP_LIKE`, `REGEXP_REPLACE`, `BITAND` und `DBMS_LOB.SUBSTR` werden in Python
nachgebildet, die `XMLAGG`-Verkettung durch `group_concat` ersetzt. Getestet werden u.a. eine Expression, die
ueber zwei Zeilen von `OPB_EXPRESSION` verteilt ist, und aeltere Versionen, die nicht erscheinen duerfen.

```bash
python3 sql/test/run_port_lineage.py                                  # alle Pfade + Soll/Ist-Pruefung
python3 sql/test/run_port_lineage.py end_port=T_CUSTOMER.FULL_NAME   # mit Parametern
```

Nach Aenderungen an `port_lineage.sql` muss die Pruefung `OK` melden.

## I/O-Diagnose (`oracle/diag_io_waits.sql`)

Laeuft auf der **Quell- bzw. Zieldatenbank** der Sessions (nicht auf dem Repository), als DBA. Einzelne Abfragen
markieren und ausfuehren; Erklaerung und Auswertung in [docs/TUNING.md](../docs/TUNING.md), Abschnitt 8.

| Teil | Inhalt | Lizenz |
|---|---|---|
| A1 - A13 | V$-Views: Wait-Summen und -Verteilung, Latenz je Datei, Segmente, SQL, laufende `pmdtm`-Sessions, OS-Last, Parameter, Cache-Advice, Clustering Factor | keine |
| B1 - B4 | AWR/ASH: Verlauf je Snapshot, Latenz je Datei, verursachende SQL, zeitgleiche Aktivitaet | **Diagnostics Pack** |
| C | 10046-Trace einer Informatica-Session (Kommentar mit Anleitung) | keine |
