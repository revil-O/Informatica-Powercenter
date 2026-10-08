"""Nachgebautes PowerCenter-Repository (Tabellen/Spalten wie im ADAPTER von port_lineage.sql) in SQLite.

Beispiel-Mapping m_load_sales: Source CUSTOMER -> SQ_CUSTOMER -> EXP_NAME (Variablenport, :LKP-Aufruf)
-> RTR_CTRY (Router) -> T_CUSTOMER, dazu ein verbundener Lookup LKP_REGION. Oracle-Funktionen
(REGEXP_LIKE, REGEXP_REPLACE, BITAND) werden in Python nachgebildet.
"""
import re, sqlite3

def connect():
    db = sqlite3.connect(":memory:")
    def rx(p):  # Oracle-POSIX-Klassen -> Python
        return p.replace("[[:space:]]", r"\s")
    db.create_function("REGEXP_LIKE", 2, lambda s, p: None if s is None else int(re.search(rx(p), s) is not None))
    db.create_function("REGEXP_REPLACE", 3, lambda s, p, r: None if s is None else re.sub(rx(p), r, s))
    db.create_function("BITAND", 2, lambda a, b: None if a is None or b is None else int(a) & int(b))
    db.executescript("""
    CREATE TABLE DUAL (DUMMY TEXT); INSERT INTO DUAL VALUES ('X');
    CREATE TABLE OPB_SUBJECT (SUBJ_ID INT, SUBJ_NAME TEXT);
    CREATE TABLE OPB_MAPPING (MAPPING_ID INT, MAPPING_NAME TEXT, SUBJECT_ID INT, VERSION_NUMBER INT, IS_VISIBLE INT);
    CREATE TABLE OPB_OBJECT_TYPE (OBJECT_TYPE_ID INT, OBJECT_TYPE_NAME TEXT);
    CREATE TABLE OPB_WIDGET_INST (MAPPING_ID INT, INSTANCE_ID INT, WIDGET_ID INT, WIDGET_TYPE INT, INSTANCE_NAME TEXT, VERSION_NUMBER INT);
    CREATE TABLE OPB_WIDGET_DEP (MAPPING_ID INT, FROM_INSTANCE_ID INT, FROM_FIELD_ID INT, TO_INSTANCE_ID INT, TO_FIELD_ID INT, VERSION_NUMBER INT);
    CREATE TABLE REP_WIDGET_FIELD (WIDGET_ID INT, FIELD_ID INT, FIELD_NAME TEXT, DATATYPE TEXT, WGT_PREC INT, WGT_SCALE INT, PORTTYPE INT, EXPRESSION TEXT, VERSION_NUMBER INT);
    CREATE TABLE OPB_SRC_FLD (SRC_ID INT, FLDID INT, SRC_NAME TEXT, VERSION_NUMBER INT);
    CREATE TABLE REP_ALL_SOURCE_FLDS (SOURCE_ID INT, SOURCE_FIELD_NAME TEXT, SOURCE_FIELD_DATATYPE TEXT, SOURCE_FIELD_PRECISION INT, SOURCE_FIELD_SCALE INT);
    CREATE TABLE OPB_TARG_FLD (TARGET_ID INT, FLDID INT, TARGET_NAME TEXT, VERSION_NUMBER INT);
    CREATE TABLE REP_ALL_TARGET_FLDS (TARGET_ID INT, TARGET_FIELD_NAME TEXT, TARGET_FIELD_DATATYPE TEXT, TARGET_FIELD_PRECISION INT, TARGET_FIELD_SCALE INT);
    CREATE TABLE REP_WIDGET_ATTR (WIDGET_ID INT, ATTR_DESCRIPTION TEXT, ATTR_VALUE TEXT);
    """)
    q = db.executemany
    q("INSERT INTO OPB_SUBJECT VALUES (?,?)", [(10, "DWH"), (11, "SHARED")])
    # Mapping in Version 1 (alt, unsichtbar) und 2 (aktuell)
    q("INSERT INTO OPB_MAPPING VALUES (?,?,?,?,?)", [(100, "m_load_sales", 10, 1, 0), (100, "m_load_sales", 10, 2, 1), (101, "m_other", 10, 1, 1)])
    q("INSERT INTO OPB_OBJECT_TYPE VALUES (?,?)", [(1, "Source Definition"), (2, "Target Definition"), (3, "Source Qualifier"),
      (5, "Expression"), (11, "Lookup Procedure"), (15, "Router")])
    # Instanzen (Version 2); Version 1 enthaelt eine alte Instanz, die nicht erscheinen darf
    inst = [(1, 500, 1, "CUSTOMER"), (2, 501, 3, "SQ_CUSTOMER"), (3, 502, 5, "EXP_NAME"), (4, 503, 11, "LKP_COUNTRY"),
            (5, 504, 11, "LKP_REGION"), (6, 505, 15, "RTR_CTRY"), (7, 600, 2, "T_CUSTOMER")]
    q("INSERT INTO OPB_WIDGET_INST VALUES (100,?,?,?,?,2)", inst)
    q("INSERT INTO OPB_WIDGET_INST VALUES (100,99,999,5,'EXP_ALT',1)", [()])
    # Source CUSTOMER (500) und Target T_CUSTOMER (600)
    q("INSERT INTO OPB_SRC_FLD VALUES (500,?,?,1)", [(1, "CUST_ID"), (2, "FIRST_NAME"), (3, "LAST_NAME"), (4, "COUNTRY")])
    q("INSERT INTO REP_ALL_SOURCE_FLDS VALUES (500,?,?,?,?)", [("CUST_ID", "number", 10, 0), ("FIRST_NAME", "varchar2", 30, 0),
      ("LAST_NAME", "varchar2", 30, 0), ("COUNTRY", "char", 2, 0)])
    q("INSERT INTO OPB_TARG_FLD VALUES (600,?,?,1)", [(1, "CUST_ID"), (2, "FULL_NAME"), (3, "COUNTRY_NAME"), (4, "LOAD_TS"), (5, "REGION")])
    q("INSERT INTO REP_ALL_TARGET_FLDS VALUES (600,?,?,?,?)", [("CUST_ID", "number", 10, 0), ("FULL_NAME", "varchar2", 61, 0),
      ("COUNTRY_NAME", "varchar2", 50, 0), ("LOAD_TS", "date", 19, 0), ("REGION", "varchar2", 20, 0)])
    # Transformations-Ports: (widget, field, name, typ, prec, scale, porttype, expression)
    F = [
      (501, 1, "CUST_ID", "decimal", 10, 0, 3, "CUST_ID"), (501, 2, "FIRST_NAME", "string", 30, 0, 3, "FIRST_NAME"),
      (501, 3, "LAST_NAME", "string", 30, 0, 3, "LAST_NAME"), (501, 4, "COUNTRY", "string", 2, 0, 3, "COUNTRY"),
      (502, 1, "CUST_ID", "decimal", 10, 0, 3, "CUST_ID"), (502, 2, "FIRST_NAME", "string", 30, 0, 1, None),
      (502, 3, "LAST_NAME", "string", 30, 0, 1, None), (502, 4, "COUNTRY", "string", 2, 0, 1, None),
      (502, 5, "V_CTRY", "string", 2, 0, 32, "UPPER(COUNTRY)"),
      (502, 6, "O_FULL_NAME", "string", 61, 0, 2, "LTRIM(FIRST_NAME) || ' ' || LAST_NAME"),
      (502, 7, "O_COUNTRY_NAME", "string", 50, 0, 2, ":LKP.LKP_COUNTRY(V_CTRY)"),
      (502, 8, "O_LOAD_TS", "date/time", 29, 9, 2, "SYSDATE"),
      (502, 9, "O_FLAG", "string", 1, 0, 2, "'Y'"),
      (503, 1, "IN_CODE", "string", 2, 0, 1, None), (503, 2, "COUNTRY_CODE", "string", 2, 0, 8, None),
      (503, 3, "COUNTRY_NAME", "string", 50, 0, 10, None),
      (504, 1, "IN_COUNTRY", "string", 2, 0, 1, None), (504, 2, "COUNTRY_CODE", "string", 2, 0, 8, None),
      (504, 3, "REGION", "string", 20, 0, 10, None),
      (505, 1, "CUST_ID", "decimal", 10, 0, 1, None), (505, 2, "FULL_NAME", "string", 61, 0, 1, None),
      (505, 3, "CUST_ID1", "decimal", 10, 0, 2, None), (505, 4, "FULL_NAME1", "string", 61, 0, 2, None),
      (505, 5, "CUST_ID3", "decimal", 10, 0, 2, None), (505, 6, "FULL_NAME3", "string", 61, 0, 2, None),
    ]
    q("INSERT INTO REP_WIDGET_FIELD VALUES (?,?,?,?,?,?,?,?,1)", F)
    q("INSERT INTO REP_WIDGET_FIELD VALUES (999,1,'ALT','string',1,0,2,'ALT',1)", [()])
    q("INSERT INTO REP_WIDGET_ATTR VALUES (?,?,?)", [(504, "Lookup condition", "COUNTRY_CODE = IN_COUNTRY"),
      (504, "Lookup table name", "D_REGION"), (503, "Lookup condition", "COUNTRY_CODE = IN_CODE")])
    # Links (Version 2): (from_inst, from_field, to_inst, to_field)
    L = [(1, 1, 2, 1), (1, 2, 2, 2), (1, 3, 2, 3), (1, 4, 2, 4),
         (2, 1, 3, 1), (2, 2, 3, 2), (2, 3, 3, 3), (2, 4, 3, 4), (2, 4, 5, 1),
         (3, 1, 6, 1), (3, 6, 6, 2), (6, 3, 7, 1), (6, 4, 7, 2),
         (3, 7, 7, 3), (3, 8, 7, 4), (5, 3, 7, 5)]
    q("INSERT INTO OPB_WIDGET_DEP VALUES (100,?,?,?,?,2)", L)
    q("INSERT INTO OPB_WIDGET_DEP VALUES (100,99,1,7,1,1)", [()])   # alter Link aus Version 1
    db.commit()
    return db

def load_sql(path, **params):
    sql = open(path).read()
    sql = sql.replace("WITH\nparams AS", "WITH RECURSIVE\nparams AS", 1)
    for k, v in params.items():
        sql = re.sub(r"'[^']*'(\s+AS p_%s\b)" % k, "'%s'\\1" % v, sql)
    return sql
