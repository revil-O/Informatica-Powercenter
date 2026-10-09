/* =====================================================================================================
   check_repository_columns.sql  -  Vorpruefung fuer port_lineage.sql (Oracle)

   Prueft, ob die Repository-Tabellen (OPB_*, REP_FLD_DATATYPE) und Spalten, die der ADAPTER-Abschnitt
   von port_lineage.sql verwendet, in diesem Repository existieren. Als Repository-Owner ausfuehren
   (oder p_owner bzw. den Owner in Teil 2 setzen). Nur lesend.

   1. Soll/Ist-Abgleich der Spalten          -> Status FEHLT = im ADAPTER anpassen
   2. tatsaechliche Spalten der betroffenen Tabellen (Vorlage fuer die Anpassung)
   3. Plausibilitaet: Objekttypen, Porttypen, Datentyp-Codes ohne Namen, Lookup-Attribute
   ===================================================================================================== */

-- 1. Soll/Ist-Abgleich --------------------------------------------------------------------------------
WITH params AS (SELECT USER AS p_owner FROM dual),          -- Repository-Schema, z.B. 'INFA_REP'
soll (tabelle, spalte) AS (
            SELECT 'OPB_MAPPING',      'MAPPING_ID'       FROM dual
  UNION ALL SELECT 'OPB_MAPPING',      'MAPPING_NAME'     FROM dual
  UNION ALL SELECT 'OPB_MAPPING',      'SUBJECT_ID'       FROM dual
  UNION ALL SELECT 'OPB_MAPPING',      'VERSION_NUMBER'   FROM dual
  UNION ALL SELECT 'OPB_MAPPING',      'IS_VISIBLE'       FROM dual
  UNION ALL SELECT 'OPB_SUBJECT',      'SUBJ_ID'          FROM dual
  UNION ALL SELECT 'OPB_SUBJECT',      'SUBJ_NAME'        FROM dual
  UNION ALL SELECT 'OPB_WIDGET_INST',  'MAPPING_ID'       FROM dual
  UNION ALL SELECT 'OPB_WIDGET_INST',  'INSTANCE_ID'      FROM dual
  UNION ALL SELECT 'OPB_WIDGET_INST',  'WIDGET_ID'        FROM dual
  UNION ALL SELECT 'OPB_WIDGET_INST',  'WIDGET_TYPE'      FROM dual
  UNION ALL SELECT 'OPB_WIDGET_INST',  'INSTANCE_NAME'    FROM dual
  UNION ALL SELECT 'OPB_WIDGET_INST',  'VERSION_NUMBER'   FROM dual
  UNION ALL SELECT 'OPB_OBJECT_TYPE',  'OBJECT_TYPE_ID'   FROM dual
  UNION ALL SELECT 'OPB_OBJECT_TYPE',  'OBJECT_TYPE_NAME' FROM dual
  UNION ALL SELECT 'OPB_WIDGET_DEP',   'MAPPING_ID'       FROM dual
  UNION ALL SELECT 'OPB_WIDGET_DEP',   'FROM_INSTANCE_ID' FROM dual
  UNION ALL SELECT 'OPB_WIDGET_DEP',   'FROM_FIELD_ID'    FROM dual
  UNION ALL SELECT 'OPB_WIDGET_DEP',   'TO_INSTANCE_ID'   FROM dual
  UNION ALL SELECT 'OPB_WIDGET_DEP',   'TO_FIELD_ID'      FROM dual
  UNION ALL SELECT 'OPB_WIDGET_DEP',   'VERSION_NUMBER'   FROM dual
  UNION ALL SELECT 'OPB_WIDGET_FIELD', 'WIDGET_ID'        FROM dual
  UNION ALL SELECT 'OPB_WIDGET_FIELD', 'FIELD_ID'         FROM dual
  UNION ALL SELECT 'OPB_WIDGET_FIELD', 'FIELD_NAME'       FROM dual
  UNION ALL SELECT 'OPB_WIDGET_FIELD', 'WGT_DATATYPE'     FROM dual
  UNION ALL SELECT 'OPB_WIDGET_FIELD', 'WGT_PREC'         FROM dual
  UNION ALL SELECT 'OPB_WIDGET_FIELD', 'WGT_SCALE'        FROM dual
  UNION ALL SELECT 'OPB_WIDGET_FIELD', 'PORTTYPE'         FROM dual
  UNION ALL SELECT 'OPB_WIDGET_FIELD', 'VERSION_NUMBER'   FROM dual
  UNION ALL SELECT 'REP_FLD_DATATYPE', 'DTYPE_NUM'        FROM dual
  UNION ALL SELECT 'REP_FLD_DATATYPE', 'DTYPE_NAME'       FROM dual
  UNION ALL SELECT 'OPB_WIDGET_EXPR',  'WIDGET_ID'        FROM dual
  UNION ALL SELECT 'OPB_WIDGET_EXPR',  'OUTPUT_FIELD_ID'  FROM dual
  UNION ALL SELECT 'OPB_WIDGET_EXPR',  'EXPR_ID'          FROM dual
  UNION ALL SELECT 'OPB_WIDGET_EXPR',  'VERSION_NUMBER'   FROM dual
  UNION ALL SELECT 'OPB_EXPRESSION',   'WIDGET_ID'        FROM dual
  UNION ALL SELECT 'OPB_EXPRESSION',   'EXPR_ID'          FROM dual
  UNION ALL SELECT 'OPB_EXPRESSION',   'LINE_NO'          FROM dual
  UNION ALL SELECT 'OPB_EXPRESSION',   'EXPRESSION'       FROM dual
  UNION ALL SELECT 'OPB_EXPRESSION',   'VERSION_NUMBER'   FROM dual
  UNION ALL SELECT 'OPB_MMD_DATATYPE', 'NATIVE_DATATYPE'  FROM dual
  UNION ALL SELECT 'OPB_MMD_DATATYPE', 'PM_DATATYPE'      FROM dual
  UNION ALL SELECT 'OPB_MMD_DATATYPE', 'DATATYPE_NAME'    FROM dual
  UNION ALL SELECT 'OPB_SRC_FLD',      'SRC_ID'           FROM dual
  UNION ALL SELECT 'OPB_SRC_FLD',      'FLDID'            FROM dual
  UNION ALL SELECT 'OPB_SRC_FLD',      'SRC_NAME'         FROM dual
  UNION ALL SELECT 'OPB_SRC_FLD',      'NDTYPE'           FROM dual
  UNION ALL SELECT 'OPB_SRC_FLD',      'DTYPE'            FROM dual
  UNION ALL SELECT 'OPB_SRC_FLD',      'DPREC'            FROM dual
  UNION ALL SELECT 'OPB_SRC_FLD',      'DSCALE'           FROM dual
  UNION ALL SELECT 'OPB_SRC_FLD',      'VERSION_NUMBER'   FROM dual
  UNION ALL SELECT 'OPB_TARG_FLD',     'TARGET_ID'        FROM dual
  UNION ALL SELECT 'OPB_TARG_FLD',     'FLDID'            FROM dual
  UNION ALL SELECT 'OPB_TARG_FLD',     'TARGET_NAME'      FROM dual
  UNION ALL SELECT 'OPB_TARG_FLD',     'NDTYPE'           FROM dual
  UNION ALL SELECT 'OPB_TARG_FLD',     'DTYPE'            FROM dual
  UNION ALL SELECT 'OPB_TARG_FLD',     'DPREC'            FROM dual
  UNION ALL SELECT 'OPB_TARG_FLD',     'DSCALE'           FROM dual
  UNION ALL SELECT 'OPB_TARG_FLD',     'VERSION_NUMBER'   FROM dual
  UNION ALL SELECT 'OPB_WIDGET_ATTR',  'WIDGET_ID'        FROM dual
  UNION ALL SELECT 'OPB_WIDGET_ATTR',  'WIDGET_TYPE'      FROM dual
  UNION ALL SELECT 'OPB_WIDGET_ATTR',  'ATTR_ID'          FROM dual
  UNION ALL SELECT 'OPB_WIDGET_ATTR',  'ATTR_VALUE'       FROM dual
  UNION ALL SELECT 'OPB_WIDGET_ATTR',  'VERSION_NUMBER'   FROM dual
  UNION ALL SELECT 'OPB_ATTR',         'OBJECT_TYPE_ID'   FROM dual
  UNION ALL SELECT 'OPB_ATTR',         'ATTR_ID'          FROM dual
  UNION ALL SELECT 'OPB_ATTR',         'ATTR_NAME'        FROM dual
)
SELECT s.tabelle,
       s.spalte,
       CASE WHEN c.column_name IS NOT NULL THEN 'OK'
            WHEN NOT EXISTS (SELECT 1 FROM all_tab_columns x, params p
                             WHERE x.owner = p.p_owner AND x.table_name = s.tabelle)
            THEN 'TABELLE FEHLT'
            ELSE 'FEHLT' END AS status
FROM soll s
CROSS JOIN params p
LEFT JOIN all_tab_columns c ON c.owner = p.p_owner AND c.table_name = s.tabelle AND c.column_name = s.spalte
ORDER BY CASE WHEN c.column_name IS NULL THEN 0 ELSE 1 END, s.tabelle, s.spalte;

-- 2. Tatsaechliche Spalten der verwendeten Tabellen (zum Anpassen des ADAPTER-Abschnitts) --------------
SELECT c.table_name AS tabelle, c.column_id AS nr, c.column_name AS spalte, c.data_type AS typ
FROM all_tab_columns c
WHERE c.owner = USER                                         -- Repository-Schema
  AND c.table_name IN ('OPB_MAPPING', 'OPB_SUBJECT', 'OPB_WIDGET_INST', 'OPB_OBJECT_TYPE', 'OPB_WIDGET_DEP',
                       'OPB_WIDGET_FIELD', 'REP_FLD_DATATYPE', 'OPB_WIDGET_EXPR', 'OPB_EXPRESSION',
                       'OPB_MMD_DATATYPE', 'OPB_SRC_FLD', 'OPB_TARG_FLD', 'OPB_WIDGET_ATTR', 'OPB_ATTR')
ORDER BY c.table_name, c.column_id;

-- 3a. Objekttypen der Instanzen (Namen fuer Router/Union/Normalizer, Codes 1 = Source, 2 = Target) -----
SELECT i.WIDGET_TYPE AS widget_type, t.OBJECT_TYPE_NAME AS objekttyp, COUNT(*) AS instanzen
FROM OPB_WIDGET_INST i
LEFT JOIN OPB_OBJECT_TYPE t ON t.OBJECT_TYPE_ID = i.WIDGET_TYPE
GROUP BY i.WIDGET_TYPE, t.OBJECT_TYPE_NAME
ORDER BY i.WIDGET_TYPE;

-- 3b. Porttypen (Bitmaske: 1 Input, 2 Output, 8 Lookup, 32 Variable) ----------------------------------
SELECT f.PORTTYPE AS porttype, COUNT(*) AS ports, MIN(f.FIELD_NAME) AS beispiel
FROM OPB_WIDGET_FIELD f
GROUP BY f.PORTTYPE
ORDER BY f.PORTTYPE;

-- 3c. Datentyp-Codes der Transformations-Ports und ihr Name aus REP_FLD_DATATYPE ----------------------
--     (ohne Namen erscheint im Lineage-Ergebnis 'Code n')
SELECT f.WGT_DATATYPE AS code, MIN(d.DTYPE_NAME) AS name, COUNT(*) AS ports, MIN(f.FIELD_NAME) AS beispiel
FROM OPB_WIDGET_FIELD f
LEFT JOIN REP_FLD_DATATYPE d ON d.DTYPE_NUM = f.WGT_DATATYPE
GROUP BY f.WGT_DATATYPE
ORDER BY f.WGT_DATATYPE;

-- 3d. Native Datentypen der Source-/Target-Felder und ihr Name aus OPB_MMD_DATATYPE --------------------
SELECT x.art, x.ndtype, x.dtype, MIN(m.DATATYPE_NAME) AS name, COUNT(*) AS felder, MIN(x.feld) AS beispiel
FROM (SELECT 'Source' AS art, NDTYPE AS ndtype, DTYPE AS dtype, SRC_NAME AS feld FROM OPB_SRC_FLD
      UNION ALL
      SELECT 'Target', NDTYPE, DTYPE, TARGET_NAME FROM OPB_TARG_FLD) x
LEFT JOIN OPB_MMD_DATATYPE m ON m.NATIVE_DATATYPE = x.ndtype AND m.PM_DATATYPE = x.dtype
GROUP BY x.art, x.ndtype, x.dtype
ORDER BY x.art, x.ndtype, x.dtype;

-- 3e. Attribute der Lookup-Transformationen (port_lineage.sql erwartet 'Lookup condition%') ------------
SELECT a.WIDGET_TYPE AS widget_type, a.ATTR_ID AS attr_id, d.ATTR_NAME AS attribut, COUNT(*) AS anzahl,
       MIN(a.ATTR_VALUE) AS beispiel
FROM OPB_WIDGET_ATTR a
LEFT JOIN OPB_ATTR d ON d.ATTR_ID = a.ATTR_ID AND d.OBJECT_TYPE_ID = a.WIDGET_TYPE
WHERE a.WIDGET_TYPE = 11                                     -- Lookup Procedure (siehe 3a)
GROUP BY a.WIDGET_TYPE, a.ATTR_ID, d.ATTR_NAME
ORDER BY a.ATTR_ID;
