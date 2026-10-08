/* =====================================================================================================
   check_repository_columns.sql  -  Vorpruefung fuer port_lineage.sql (Oracle)

   Prueft, ob die Tabellen/MX-Views und Spalten, die der ADAPTER-Abschnitt von port_lineage.sql
   verwendet, in diesem Repository existieren. Als Repository-Owner ausfuehren (oder p_owner setzen).
   Nur lesend.

   1. Soll/Ist-Abgleich der Spalten          -> Status FEHLT = im ADAPTER anpassen
   2. tatsaechliche Spalten der betroffenen Objekte (Vorlage fuer die Anpassung)
   3. Plausibilitaet: Objekttypen, Porttypen und Attributname der Lookup-Bedingung
   ===================================================================================================== */

-- 1. Soll/Ist-Abgleich --------------------------------------------------------------------------------
WITH params AS (SELECT USER AS p_owner FROM dual),          -- Repository-Schema, z.B. 'INFA_REP'
soll (tabelle, spalte) AS (
            SELECT 'OPB_MAPPING',         'MAPPING_ID'             FROM dual
  UNION ALL SELECT 'OPB_MAPPING',         'MAPPING_NAME'           FROM dual
  UNION ALL SELECT 'OPB_MAPPING',         'SUBJECT_ID'             FROM dual
  UNION ALL SELECT 'OPB_MAPPING',         'VERSION_NUMBER'         FROM dual
  UNION ALL SELECT 'OPB_MAPPING',         'IS_VISIBLE'             FROM dual
  UNION ALL SELECT 'OPB_SUBJECT',         'SUBJ_ID'                FROM dual
  UNION ALL SELECT 'OPB_SUBJECT',         'SUBJ_NAME'              FROM dual
  UNION ALL SELECT 'OPB_WIDGET_INST',     'MAPPING_ID'             FROM dual
  UNION ALL SELECT 'OPB_WIDGET_INST',     'INSTANCE_ID'            FROM dual
  UNION ALL SELECT 'OPB_WIDGET_INST',     'WIDGET_ID'              FROM dual
  UNION ALL SELECT 'OPB_WIDGET_INST',     'WIDGET_TYPE'            FROM dual
  UNION ALL SELECT 'OPB_WIDGET_INST',     'INSTANCE_NAME'          FROM dual
  UNION ALL SELECT 'OPB_WIDGET_INST',     'VERSION_NUMBER'         FROM dual
  UNION ALL SELECT 'OPB_OBJECT_TYPE',     'OBJECT_TYPE_ID'         FROM dual
  UNION ALL SELECT 'OPB_OBJECT_TYPE',     'OBJECT_TYPE_NAME'       FROM dual
  UNION ALL SELECT 'OPB_WIDGET_DEP',      'MAPPING_ID'             FROM dual
  UNION ALL SELECT 'OPB_WIDGET_DEP',      'FROM_INSTANCE_ID'       FROM dual
  UNION ALL SELECT 'OPB_WIDGET_DEP',      'FROM_FIELD_ID'          FROM dual
  UNION ALL SELECT 'OPB_WIDGET_DEP',      'TO_INSTANCE_ID'         FROM dual
  UNION ALL SELECT 'OPB_WIDGET_DEP',      'TO_FIELD_ID'            FROM dual
  UNION ALL SELECT 'OPB_WIDGET_DEP',      'VERSION_NUMBER'         FROM dual
  UNION ALL SELECT 'REP_WIDGET_FIELD',    'WIDGET_ID'              FROM dual
  UNION ALL SELECT 'REP_WIDGET_FIELD',    'FIELD_ID'               FROM dual
  UNION ALL SELECT 'REP_WIDGET_FIELD',    'FIELD_NAME'             FROM dual
  UNION ALL SELECT 'REP_WIDGET_FIELD',    'DATATYPE'               FROM dual
  UNION ALL SELECT 'REP_WIDGET_FIELD',    'WGT_PREC'               FROM dual
  UNION ALL SELECT 'REP_WIDGET_FIELD',    'WGT_SCALE'              FROM dual
  UNION ALL SELECT 'REP_WIDGET_FIELD',    'PORTTYPE'               FROM dual
  UNION ALL SELECT 'REP_WIDGET_FIELD',    'EXPRESSION'             FROM dual
  UNION ALL SELECT 'REP_WIDGET_FIELD',    'VERSION_NUMBER'         FROM dual
  UNION ALL SELECT 'OPB_SRC_FLD',         'SRC_ID'                 FROM dual
  UNION ALL SELECT 'OPB_SRC_FLD',         'FLDID'                  FROM dual
  UNION ALL SELECT 'OPB_SRC_FLD',         'SRC_NAME'               FROM dual
  UNION ALL SELECT 'OPB_SRC_FLD',         'VERSION_NUMBER'         FROM dual
  UNION ALL SELECT 'REP_ALL_SOURCE_FLDS', 'SOURCE_ID'              FROM dual
  UNION ALL SELECT 'REP_ALL_SOURCE_FLDS', 'SOURCE_FIELD_NAME'      FROM dual
  UNION ALL SELECT 'REP_ALL_SOURCE_FLDS', 'SOURCE_FIELD_DATATYPE'  FROM dual
  UNION ALL SELECT 'REP_ALL_SOURCE_FLDS', 'SOURCE_FIELD_PRECISION' FROM dual
  UNION ALL SELECT 'REP_ALL_SOURCE_FLDS', 'SOURCE_FIELD_SCALE'     FROM dual
  UNION ALL SELECT 'OPB_TARG_FLD',        'TARGET_ID'              FROM dual
  UNION ALL SELECT 'OPB_TARG_FLD',        'FLDID'                  FROM dual
  UNION ALL SELECT 'OPB_TARG_FLD',        'TARGET_NAME'            FROM dual
  UNION ALL SELECT 'OPB_TARG_FLD',        'VERSION_NUMBER'         FROM dual
  UNION ALL SELECT 'REP_ALL_TARGET_FLDS', 'TARGET_ID'              FROM dual
  UNION ALL SELECT 'REP_ALL_TARGET_FLDS', 'TARGET_FIELD_NAME'      FROM dual
  UNION ALL SELECT 'REP_ALL_TARGET_FLDS', 'TARGET_FIELD_DATATYPE'  FROM dual
  UNION ALL SELECT 'REP_ALL_TARGET_FLDS', 'TARGET_FIELD_PRECISION' FROM dual
  UNION ALL SELECT 'REP_ALL_TARGET_FLDS', 'TARGET_FIELD_SCALE'     FROM dual
  UNION ALL SELECT 'REP_WIDGET_ATTR',     'WIDGET_ID'              FROM dual
  UNION ALL SELECT 'REP_WIDGET_ATTR',     'ATTR_DESCRIPTION'       FROM dual
  UNION ALL SELECT 'REP_WIDGET_ATTR',     'ATTR_VALUE'             FROM dual
)
SELECT s.tabelle,
       s.spalte,
       CASE WHEN c.column_name IS NOT NULL THEN 'OK'
            WHEN NOT EXISTS (SELECT 1 FROM all_tab_columns x, params p
                             WHERE x.owner = p.p_owner AND x.table_name = s.tabelle)
            THEN 'TABELLE/VIEW FEHLT'
            ELSE 'FEHLT' END AS status
FROM soll s
CROSS JOIN params p
LEFT JOIN all_tab_columns c ON c.owner = p.p_owner AND c.table_name = s.tabelle AND c.column_name = s.spalte
ORDER BY CASE WHEN c.column_name IS NULL THEN 0 ELSE 1 END, s.tabelle, s.spalte;

-- 2. Tatsaechliche Spalten der verwendeten Objekte (zum Anpassen des ADAPTER-Abschnitts) ---------------
SELECT c.table_name AS tabelle, c.column_id AS nr, c.column_name AS spalte, c.data_type AS typ
FROM all_tab_columns c
WHERE c.owner = USER                                         -- Repository-Schema
  AND c.table_name IN ('OPB_MAPPING', 'OPB_SUBJECT', 'OPB_WIDGET_INST', 'OPB_OBJECT_TYPE', 'OPB_WIDGET_DEP',
                       'REP_WIDGET_FIELD', 'OPB_SRC_FLD', 'REP_ALL_SOURCE_FLDS', 'OPB_TARG_FLD',
                       'REP_ALL_TARGET_FLDS', 'REP_WIDGET_ATTR')
ORDER BY c.table_name, c.column_id;

-- 3a. Objekttypen der Instanzen (Namen fuer Router/Union/Normalizer, Codes 1 = Source, 2 = Target) -----
SELECT i.WIDGET_TYPE AS widget_type, t.OBJECT_TYPE_NAME AS objekttyp, COUNT(*) AS instanzen
FROM OPB_WIDGET_INST i
LEFT JOIN OPB_OBJECT_TYPE t ON t.OBJECT_TYPE_ID = i.WIDGET_TYPE
GROUP BY i.WIDGET_TYPE, t.OBJECT_TYPE_NAME
ORDER BY i.WIDGET_TYPE;

-- 3b. Porttypen (Bitmaske: 1 Input, 2 Output, 8 Lookup, 32 Variable) ----------------------------------
SELECT f.PORTTYPE AS porttype, COUNT(*) AS ports, MIN(f.FIELD_NAME) AS beispiel
FROM REP_WIDGET_FIELD f
GROUP BY f.PORTTYPE
ORDER BY f.PORTTYPE;

-- 3c. Attributname der Lookup-Bedingung (port_lineage.sql erwartet 'Lookup condition%') --------------
SELECT a.ATTR_DESCRIPTION AS attribut, COUNT(*) AS anzahl, MIN(a.ATTR_VALUE) AS beispiel
FROM REP_WIDGET_ATTR a
WHERE UPPER(a.ATTR_DESCRIPTION) LIKE '%CONDITION%' OR UPPER(a.ATTR_DESCRIPTION) LIKE '%BEDINGUNG%'
GROUP BY a.ATTR_DESCRIPTION
ORDER BY a.ATTR_DESCRIPTION;
