/* =====================================================================================================
   port_lineage.sql  -  Port-Lineage im PowerCenter-Repository (Oracle 11gR2+)

   Verfolgt jeden Port von seinem Ursprung (Source-Feld, Lookup-Rueckgabe, Konstante/SYSDATE, Sequence ...)
   ueber alle Transformationen bis in die Target-Spalte - eine Zeile je Schritt, mit Datentyp,
   Praezision und Scale des Ports in jeder Transformation.

   Kanten im Port-Graphen (Spalte KANTE):
     LINK      Verbindung zwischen zwei Instanzen (Link im Mapping Designer)
     EXPR      logische Verbindung innerhalb einer Transformation: der Ausgabe-/Variablenport
               verwendet den Eingabe-/Variablenport in seiner Expression
     LKP_CALL  Aufruf einer nicht verbundenen Lookup-/Stored-Procedure-Transformation in einer
               Expression (:LKP.<name>(...) / :SP.<name>(...)) - Rueckgabeport -> aufrufender Port
     LKP_ARG   dazu: Ports, die in der aufrufenden Expression verwendet werden -> Eingabeports des
               aufgerufenen Lookups (die Argumente werden nicht einzeln zugeordnet)
     LKP_COND  Lookup: Eingabeports aus der Lookup-Bedingung -> Ausgabeports des Lookups
     GROUP     Router / Union / Normalizer: Port der Eingabegruppe -> gleichnamiger Port der
               Ausgabegruppe (Name ohne Ziffern am Ende, z.B. CUST_ID -> CUST_ID1)
   Durchreichende Input/Output-Ports (SQ, Joiner, Aggregator, Sorter, Filter ...) sind derselbe
   Port und brauchen keine eigene Kante.

   Ausfuehren: Parameter im Block "params" setzen, als Repository-Owner (oder mit Leserecht auf die
   Repository-Tabellen) ausfuehren. Es wird nur gelesen.
   Vorher einmal sql/oracle/check_repository_columns.sql ausfuehren: weichen Spaltennamen in Ihrer
   Version ab, nur den Abschnitt ADAPTER anpassen.

   Ergebnis je Zeile: PFAD_ID, SCHRITT, SCHRITTE, KANTE, INSTANZ, OBJEKTTYP, PORT, PORTTYP, DATENTYP,
   EXPRESSION (nur bei berechneten Ports), PFAD (gesamte Kette als Text).
   ===================================================================================================== */
WITH
params AS (
  SELECT 'DWH'          AS p_folder,      -- Folder (LIKE-Muster, z.B. '%')
         'm_load_sales' AS p_mapping,     -- Mapping oder Mapplet (LIKE-Muster) - moeglichst eng waehlen
         '%'            AS p_start_port,  -- Ursprung 'INSTANZ.PORT' (LIKE), z.B. 'CUSTOMER.%' oder 'SQ_CUSTOMER.CUST_ID'
         '%'            AS p_end_port,    -- Ziel 'INSTANZ.PORT' (LIKE), z.B. 'T_CUSTOMER.FULL_NAME'
         'TARGET'       AS p_end_mode,    -- TARGET = nur Pfade, die in einem Target enden; ALL = auch Sackgassen
         60             AS p_max_depth    -- maximale Pfadlaenge (Schutz vor sehr grossen Graphen)
  FROM dual
),

/* ===================================== ADAPTER =====================================================
   Einzige Stelle mit Tabellen-/Spaltennamen des Repositorys. OPB_* = Repository-Tabellen,
   REP_* = MX-Views. Bei abweichenden Namen (siehe check_repository_columns.sql) hier anpassen.
   Versionierte Repositories: es wird jeweils die sichtbare (aktuelle) Version verwendet.
   ================================================================================================== */
mp AS (                                   -- Mappings/Mapplets mit Folder
  SELECT s.SUBJ_NAME       AS folder_name,
         m.MAPPING_ID      AS mapping_id,
         m.MAPPING_NAME    AS mapping_name,
         m.VERSION_NUMBER  AS map_version
  FROM OPB_MAPPING m
  JOIN OPB_SUBJECT s ON s.SUBJ_ID = m.SUBJECT_ID
  CROSS JOIN params p
  WHERE m.IS_VISIBLE = 1
    AND s.SUBJ_NAME    LIKE p.p_folder
    AND m.MAPPING_NAME LIKE p.p_mapping
),
inst AS (                                 -- Instanzen im Mapping (WIDGET_TYPE 1 = Source, 2 = Target)
  SELECT i.MAPPING_ID    AS mapping_id,
         i.INSTANCE_ID   AS instance_id,
         i.WIDGET_ID     AS widget_id,
         i.WIDGET_TYPE   AS widget_type,
         i.INSTANCE_NAME AS instance_name,
         COALESCE(t.OBJECT_TYPE_NAME, 'Typ ' || i.WIDGET_TYPE) AS object_type
  FROM OPB_WIDGET_INST i
  JOIN mp ON mp.mapping_id = i.MAPPING_ID AND mp.map_version = i.VERSION_NUMBER
  LEFT JOIN OPB_OBJECT_TYPE t ON t.OBJECT_TYPE_ID = i.WIDGET_TYPE
),
link AS (                                 -- Port-Links zwischen Instanzen
  SELECT d.MAPPING_ID       AS mapping_id,
         d.FROM_INSTANCE_ID AS from_inst,
         d.FROM_FIELD_ID    AS from_field,
         d.TO_INSTANCE_ID   AS to_inst,
         d.TO_FIELD_ID      AS to_field
  FROM OPB_WIDGET_DEP d
  JOIN mp ON mp.mapping_id = d.MAPPING_ID AND mp.map_version = d.VERSION_NUMBER
),
fld_trans AS (                            -- Ports der Transformationen (Datentyp als Name, Expression)
  SELECT f.WIDGET_ID  AS widget_id,
         f.FIELD_ID   AS field_id,
         f.FIELD_NAME AS port_name,
         f.DATATYPE   AS datatype,
         f.WGT_PREC   AS prec,
         f.WGT_SCALE  AS scale,
         f.PORTTYPE   AS porttype,        -- Bitmaske: 1 Input, 2 Output, 8 Lookup, 32 Variable
         f.EXPRESSION AS expression
  FROM REP_WIDGET_FIELD f
  WHERE f.VERSION_NUMBER = (SELECT MAX(f2.VERSION_NUMBER) FROM REP_WIDGET_FIELD f2 WHERE f2.WIDGET_ID = f.WIDGET_ID)
),
fld_src AS (                              -- Felder der Source-Definitionen
  SELECT sf.SRC_ID   AS widget_id,
         sf.FLDID    AS field_id,
         sf.SRC_NAME AS port_name,        -- in OPB_SRC_FLD heisst die Feldname-Spalte SRC_NAME
         d.SOURCE_FIELD_DATATYPE  AS datatype,
         d.SOURCE_FIELD_PRECISION AS prec,
         d.SOURCE_FIELD_SCALE     AS scale
  FROM OPB_SRC_FLD sf
  LEFT JOIN REP_ALL_SOURCE_FLDS d ON d.SOURCE_ID = sf.SRC_ID AND d.SOURCE_FIELD_NAME = sf.SRC_NAME
  WHERE sf.VERSION_NUMBER = (SELECT MAX(s2.VERSION_NUMBER) FROM OPB_SRC_FLD s2 WHERE s2.SRC_ID = sf.SRC_ID)
),
fld_tgt AS (                              -- Spalten der Target-Definitionen
  SELECT tf.TARGET_ID   AS widget_id,
         tf.FLDID       AS field_id,
         tf.TARGET_NAME AS port_name,     -- in OPB_TARG_FLD heisst die Spaltenname-Spalte TARGET_NAME
         d.TARGET_FIELD_DATATYPE  AS datatype,
         d.TARGET_FIELD_PRECISION AS prec,
         d.TARGET_FIELD_SCALE     AS scale
  FROM OPB_TARG_FLD tf
  LEFT JOIN REP_ALL_TARGET_FLDS d ON d.TARGET_ID = tf.TARGET_ID AND d.TARGET_FIELD_NAME = tf.TARGET_NAME
  WHERE tf.VERSION_NUMBER = (SELECT MAX(t2.VERSION_NUMBER) FROM OPB_TARG_FLD t2 WHERE t2.TARGET_ID = tf.TARGET_ID)
),
attr AS (                                 -- Transformations-Attribute (fuer die Lookup-Bedingung)
  SELECT a.WIDGET_ID AS widget_id, a.ATTR_DESCRIPTION AS attr_name, a.ATTR_VALUE AS attr_value
  FROM REP_WIDGET_ATTR a
),
/* =================================== Ende ADAPTER ================================================= */

port AS (                                 -- alle Ports aller Instanzen der gewaehlten Mappings
  SELECT i.mapping_id, i.instance_id, f.field_id, i.instance_name, i.object_type, i.widget_type,
         f.port_name, f.datatype, f.prec, f.scale, f.porttype, f.expression
  FROM inst i JOIN fld_trans f ON f.widget_id = i.widget_id
  WHERE i.widget_type NOT IN (1, 2)
  UNION ALL
  SELECT i.mapping_id, i.instance_id, f.field_id, i.instance_name, i.object_type, i.widget_type,
         f.port_name, f.datatype, f.prec, f.scale, 2, NULL
  FROM inst i JOIN fld_src f ON f.widget_id = i.widget_id
  WHERE i.widget_type = 1
  UNION ALL
  SELECT i.mapping_id, i.instance_id, f.field_id, i.instance_name, i.object_type, i.widget_type,
         f.port_name, f.datatype, f.prec, f.scale, 1, NULL
  FROM inst i JOIN fld_tgt f ON f.widget_id = i.widget_id
  WHERE i.widget_type = 2
),

edge_raw AS (
  -- LINK: Verbindungen zwischen Instanzen
  SELECT l.mapping_id, l.from_inst, l.from_field, l.to_inst, l.to_field, 'LINK' AS edge_type
  FROM link l
  UNION ALL
  -- EXPR: Ausgabe-/Variablenport verwendet Eingabe-/Variablenport derselben Instanz in seiner Expression
  SELECT o.mapping_id, i.instance_id, i.field_id, o.instance_id, o.field_id, 'EXPR'
  FROM port o
  JOIN port i ON i.mapping_id = o.mapping_id AND i.instance_id = o.instance_id AND i.field_id <> o.field_id
  WHERE o.expression IS NOT NULL
    AND (BITAND(o.porttype, 2) > 0 OR BITAND(o.porttype, 32) > 0)
    AND (BITAND(i.porttype, 1) > 0 OR BITAND(i.porttype, 32) > 0)
    AND REGEXP_LIKE(UPPER(o.expression), '(^|[^A-Z0-9_$])' || UPPER(i.port_name) || '([^A-Z0-9_$]|$)')
  UNION ALL
  -- LKP_CALL: :LKP.<instanz>(...) / :SP.<instanz>(...) in einer Expression
  SELECT o.mapping_id, l.instance_id, l.field_id, o.instance_id, o.field_id, 'LKP_CALL'
  FROM port o
  JOIN port l ON l.mapping_id = o.mapping_id AND l.instance_id <> o.instance_id
  WHERE o.expression IS NOT NULL
    AND BITAND(l.porttype, 2) > 0
    AND REGEXP_LIKE(UPPER(o.expression), ':(LKP|SP)\.' || UPPER(l.instance_name) || '[[:space:]]*\(')
  UNION ALL
  -- LKP_ARG: Ports der aufrufenden Expression -> Eingabeports des aufgerufenen Lookups / der Stored Procedure
  SELECT o.mapping_id, i.instance_id, i.field_id, l.instance_id, l.field_id, 'LKP_ARG'
  FROM port o
  JOIN port i ON i.mapping_id = o.mapping_id AND i.instance_id = o.instance_id AND i.field_id <> o.field_id
  JOIN port l ON l.mapping_id = o.mapping_id AND l.instance_id <> o.instance_id
  WHERE o.expression IS NOT NULL
    AND (BITAND(i.porttype, 1) > 0 OR BITAND(i.porttype, 32) > 0)
    AND BITAND(l.porttype, 1) > 0 AND BITAND(l.porttype, 2) = 0
    AND REGEXP_LIKE(UPPER(o.expression), ':(LKP|SP)\.' || UPPER(l.instance_name) || '[[:space:]]*\(')
    AND REGEXP_LIKE(UPPER(o.expression), '(^|[^A-Z0-9_$])' || UPPER(i.port_name) || '([^A-Z0-9_$]|$)')
  UNION ALL
  -- LKP_COND: Lookup - Eingabeports der Lookup-Bedingung -> Ausgabeports des Lookups
  SELECT o.mapping_id, i.instance_id, i.field_id, o.instance_id, o.field_id, 'LKP_COND'
  FROM port o
  JOIN inst x ON x.mapping_id = o.mapping_id AND x.instance_id = o.instance_id
  JOIN attr a ON a.widget_id = x.widget_id AND UPPER(a.attr_name) LIKE 'LOOKUP CONDITION%'
  JOIN port i ON i.mapping_id = o.mapping_id AND i.instance_id = o.instance_id AND i.field_id <> o.field_id
  WHERE BITAND(o.porttype, 2) > 0
    AND BITAND(i.porttype, 1) > 0 AND BITAND(i.porttype, 2) = 0
    AND REGEXP_LIKE(UPPER(a.attr_value), '(^|[^A-Z0-9_$])' || UPPER(i.port_name) || '([^A-Z0-9_$]|$)')
  UNION ALL
  -- GROUP: Router / Union / Normalizer - Eingabegruppe -> gleichnamiger Port der Ausgabegruppe
  SELECT o.mapping_id, i.instance_id, i.field_id, o.instance_id, o.field_id, 'GROUP'
  FROM port o
  JOIN port i ON i.mapping_id = o.mapping_id AND i.instance_id = o.instance_id AND i.field_id <> o.field_id
  WHERE (UPPER(o.object_type) LIKE '%ROUTER%' OR UPPER(o.object_type) LIKE '%UNION%' OR UPPER(o.object_type) LIKE '%NORMALIZER%')
    AND BITAND(i.porttype, 1) > 0
    AND BITAND(o.porttype, 2) > 0 AND BITAND(o.porttype, 1) = 0
    AND REGEXP_REPLACE(UPPER(i.port_name), '[0-9]+$', '') = REGEXP_REPLACE(UPPER(o.port_name), '[0-9]+$', '')
),
edge AS (                                 -- je Portpaar nur eine Kante
  SELECT mapping_id, from_inst, from_field, to_inst, to_field, MIN(edge_type) AS edge_type
  FROM edge_raw
  GROUP BY mapping_id, from_inst, from_field, to_inst, to_field
),

root AS (                                 -- Ursprung: Port mit ausgehender, aber ohne eingehende Kante
  SELECT p.*
  FROM port p
  CROSS JOIN params pa
  WHERE EXISTS (SELECT 1 FROM edge e WHERE e.mapping_id = p.mapping_id AND e.from_inst = p.instance_id AND e.from_field = p.field_id)
    AND NOT EXISTS (SELECT 1 FROM edge e WHERE e.mapping_id = p.mapping_id AND e.to_inst = p.instance_id AND e.to_field = p.field_id)
    AND p.instance_name || '.' || p.port_name LIKE pa.p_start_port
),

walk (root_key, mapping_id, instance_id, field_id, step_no, edge_type, keypath, pathtext) AS (
  SELECT CAST(r.mapping_id || ':' || r.instance_id || ':' || r.field_id AS VARCHAR2(100)),
         r.mapping_id, r.instance_id, r.field_id, 1,
         CAST('START' AS VARCHAR2(10)),
         CAST('|' || r.instance_id || ':' || r.field_id || '|' AS VARCHAR2(4000)),
         CAST(r.instance_name || '.' || r.port_name AS VARCHAR2(4000))
  FROM root r
  UNION ALL
  SELECT w.root_key, e.mapping_id, e.to_inst, e.to_field, w.step_no + 1,
         CAST(e.edge_type AS VARCHAR2(10)),
         CAST(w.keypath || e.to_inst || ':' || e.to_field || '|' AS VARCHAR2(4000)),
         CAST(SUBSTR(w.pathtext || ' -> ' || p.instance_name || '.' || p.port_name, 1, 4000) AS VARCHAR2(4000))
  FROM walk w
  JOIN edge e ON e.mapping_id = w.mapping_id AND e.from_inst = w.instance_id AND e.from_field = w.field_id
  JOIN port p ON p.mapping_id = e.mapping_id AND p.instance_id = e.to_inst AND p.field_id = e.to_field
  CROSS JOIN params pa
  WHERE w.step_no < pa.p_max_depth
    AND INSTR(w.keypath, '|' || e.to_inst || ':' || e.to_field || '|') = 0     -- keine Zyklen
),

leaf AS (                                 -- Pfadende: kein weiterer Schritt moeglich
  SELECT w.*
  FROM walk w
  JOIN port p ON p.mapping_id = w.mapping_id AND p.instance_id = w.instance_id AND p.field_id = w.field_id
  CROSS JOIN params pa
  WHERE w.step_no > 1
    AND NOT EXISTS (SELECT 1 FROM edge e
                    WHERE e.mapping_id = w.mapping_id AND e.from_inst = w.instance_id AND e.from_field = w.field_id
                      AND INSTR(w.keypath, '|' || e.to_inst || ':' || e.to_field || '|') = 0
                      AND w.step_no < pa.p_max_depth)
    AND (pa.p_end_mode = 'ALL' OR p.widget_type = 2)
    AND p.instance_name || '.' || p.port_name LIKE pa.p_end_port
),
path AS (
  SELECT l.*, DENSE_RANK() OVER (ORDER BY l.mapping_id, l.root_key, l.keypath) AS path_id
  FROM leaf l
)

SELECT m.folder_name                                   AS folder,
       m.mapping_name                                  AS mapping,
       pa.path_id                                      AS pfad_id,
       w.step_no                                       AS schritt,
       pa.step_no                                      AS schritte,
       w.edge_type                                     AS kante,
       p.instance_name                                 AS instanz,
       p.object_type                                   AS objekttyp,
       p.port_name                                     AS port,
       CASE WHEN p.widget_type = 1 THEN 'Source'
            WHEN p.widget_type = 2 THEN 'Target'
            WHEN BITAND(p.porttype, 32) > 0 THEN 'Variable'
            WHEN BITAND(p.porttype, 8) > 0 AND BITAND(p.porttype, 2) > 0 THEN 'Lookup/Output'
            WHEN BITAND(p.porttype, 8) > 0 THEN 'Lookup'
            WHEN BITAND(p.porttype, 3) = 3 THEN 'Input/Output'
            WHEN BITAND(p.porttype, 1) > 0 THEN 'Input'
            WHEN BITAND(p.porttype, 2) > 0 THEN 'Output'
            ELSE 'Typ ' || p.porttype END              AS porttyp,
       COALESCE(p.datatype, '?')
         || CASE WHEN p.prec IS NOT NULL
                 THEN '(' || p.prec || CASE WHEN COALESCE(p.scale, 0) > 0 THEN ',' || p.scale ELSE '' END || ')'
                 ELSE '' END                           AS datentyp,
       CASE WHEN p.expression IS NOT NULL AND UPPER(p.expression) <> UPPER(p.port_name)
            THEN p.expression END                      AS expression,
       pa.pathtext                                     AS pfad
FROM path pa
JOIN walk w ON w.root_key = pa.root_key AND INSTR(pa.keypath, w.keypath) = 1
JOIN port p ON p.mapping_id = w.mapping_id AND p.instance_id = w.instance_id AND p.field_id = w.field_id
JOIN mp m   ON m.mapping_id = pa.mapping_id
ORDER BY m.folder_name, m.mapping_name, pa.path_id, w.step_no
