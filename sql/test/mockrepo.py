"""Nachgebautes PowerCenter-Repository (Tabellen/Spalten wie im ADAPTER von port_lineage.sql) in SQLite.

Nur Repository-Tabellen (OPB_*, REP_FLD_DATATYPE). Beispiel-Mapping m_load_sales:
Source CUSTOMER -> SQ_CUSTOMER -> EXP_NAME (Variablenport, :LKP-Aufruf, Expression ueber zwei Zeilen)
-> RTR_CTRY (Router) -> T_CUSTOMER, dazu ein verbundener Lookup LKP_REGION.
Oracle-Funktionen (REGEXP_LIKE, REGEXP_REPLACE, BITAND, DBMS_LOB.SUBSTR) werden in Python nachgebildet,
die XMLAGG-Verkettung der Expression-Zeilen durch group_concat ersetzt.
"""
import re
import sqlite3

# Datentyp-Codes (frei gewaehlt; im echten Repository liefern REP_FLD_DATATYPE / OPB_MMD_DATATYPE die Namen)
PM = {"string": 12, "decimal": 3, "date/time": 11, "integer": 4}
NATIVE = {("number", 3): 101, ("varchar2", 12): 102, ("char", 12): 103, ("date", 11): 104}


def connect():
    db = sqlite3.connect(":memory:")

    def rx(p):  # Oracle-POSIX-Klassen -> Python
        return p.replace("[[:space:]]", r"\s")

    db.create_function("REGEXP_LIKE", 2, lambda s, p: None if s is None else int(re.search(rx(p), s) is not None))
    db.create_function("REGEXP_REPLACE", 3, lambda s, p, r: None if s is None else re.sub(rx(p), r, s))
    db.create_function("BITAND", 2, lambda a, b: None if a is None or b is None else int(a) & int(b))
    db.create_function("LOB_SUBSTR", 3, lambda s, n, o: None if s is None else s[o - 1:o - 1 + n])
    db.executescript("""
    CREATE TABLE DUAL (DUMMY TEXT); INSERT INTO DUAL VALUES ('X');
    CREATE TABLE OPB_SUBJECT (SUBJ_ID INT, SUBJ_NAME TEXT);
    CREATE TABLE OPB_MAPPING (MAPPING_ID INT, MAPPING_NAME TEXT, SUBJECT_ID INT, VERSION_NUMBER INT, IS_VISIBLE INT);
    CREATE TABLE OPB_OBJECT_TYPE (OBJECT_TYPE_ID INT, OBJECT_TYPE_NAME TEXT);
    CREATE TABLE OPB_WIDGET_INST (MAPPING_ID INT, INSTANCE_ID INT, WIDGET_ID INT, WIDGET_TYPE INT, INSTANCE_NAME TEXT, VERSION_NUMBER INT);
    CREATE TABLE OPB_WIDGET_DEP (MAPPING_ID INT, FROM_INSTANCE_ID INT, FROM_FIELD_ID INT, TO_INSTANCE_ID INT, TO_FIELD_ID INT, VERSION_NUMBER INT);
    CREATE TABLE OPB_WIDGET_FIELD (WIDGET_ID INT, FIELD_ID INT, FIELD_NAME TEXT, WGT_DATATYPE INT, WGT_PREC INT, WGT_SCALE INT, PORTTYPE INT, VERSION_NUMBER INT);
    CREATE TABLE REP_FLD_DATATYPE (DTYPE_NUM INT, DTYPE_NAME TEXT);
    CREATE TABLE OPB_WIDGET_EXPR (WIDGET_ID INT, OUTPUT_FIELD_ID INT, EXPR_ID INT, VERSION_NUMBER INT);
    CREATE TABLE OPB_EXPRESSION (WIDGET_ID INT, EXPR_ID INT, LINE_NO INT, EXPRESSION TEXT, VERSION_NUMBER INT);
    CREATE TABLE OPB_MMD_DATATYPE (NATIVE_DATATYPE INT, PM_DATATYPE INT, DATATYPE_NAME TEXT);
    CREATE TABLE OPB_SRC_FLD (SRC_ID INT, FLDID INT, SRC_NAME TEXT, NDTYPE INT, DTYPE INT, DPREC INT, DSCALE INT, VERSION_NUMBER INT);
    CREATE TABLE OPB_TARG_FLD (TARGET_ID INT, FLDID INT, TARGET_NAME TEXT, NDTYPE INT, DTYPE INT, DPREC INT, DSCALE INT, VERSION_NUMBER INT);
    CREATE TABLE OPB_WIDGET_ATTR (WIDGET_ID INT, WIDGET_TYPE INT, ATTR_ID INT, ATTR_VALUE TEXT, VERSION_NUMBER INT);
    CREATE TABLE OPB_ATTR (OBJECT_TYPE_ID INT, ATTR_ID INT, ATTR_NAME TEXT);
    """)
    q = db.executemany
    q("INSERT INTO OPB_SUBJECT VALUES (?,?)", [(10, "DWH"), (11, "SHARED")])
    # Mapping in Version 1 (alt, unsichtbar) und 2 (aktuell)
    q("INSERT INTO OPB_MAPPING VALUES (?,?,?,?,?)", [(100, "m_load_sales", 10, 1, 0), (100, "m_load_sales", 10, 2, 1),
                                                     (101, "m_other", 10, 1, 1)])
    q("INSERT INTO OPB_OBJECT_TYPE VALUES (?,?)", [(1, "Source Definition"), (2, "Target Definition"), (3, "Source Qualifier"),
                                                   (5, "Expression"), (11, "Lookup Procedure"), (15, "Router")])
    q("INSERT INTO REP_FLD_DATATYPE VALUES (?,?)", [(v, k) for k, v in PM.items()])
    q("INSERT INTO OPB_MMD_DATATYPE VALUES (?,?,?)", [(n, d, name) for (name, d), n in NATIVE.items()])
    # Instanzen (Version 2); Version 1 enthaelt eine alte Instanz, die nicht erscheinen darf
    inst = [(1, 500, 1, "CUSTOMER"), (2, 501, 3, "SQ_CUSTOMER"), (3, 502, 5, "EXP_NAME"), (4, 503, 11, "LKP_COUNTRY"),
            (5, 504, 11, "LKP_REGION"), (6, 505, 15, "RTR_CTRY"), (7, 600, 2, "T_CUSTOMER")]
    q("INSERT INTO OPB_WIDGET_INST VALUES (100,?,?,?,?,2)", inst)
    q("INSERT INTO OPB_WIDGET_INST VALUES (100,99,999,5,'EXP_ALT',1)", [()])

    def nat(name, pm):
        return NATIVE[(name, PM[pm])], PM[pm]

    # Source CUSTOMER (500) und Target T_CUSTOMER (600): (fldid, name, nativ, pm, prec, scale)
    src = [(1, "CUST_ID", "number", "decimal", 10, 0), (2, "FIRST_NAME", "varchar2", "string", 30, 0),
           (3, "LAST_NAME", "varchar2", "string", 30, 0), (4, "COUNTRY", "char", "string", 2, 0)]
    q("INSERT INTO OPB_SRC_FLD VALUES (500,?,?,?,?,?,?,1)", [(f, n, *nat(a, b), p, s) for f, n, a, b, p, s in src])
    tgt = [(1, "CUST_ID", "number", "decimal", 10, 0), (2, "FULL_NAME", "varchar2", "string", 61, 0),
           (3, "COUNTRY_NAME", "varchar2", "string", 50, 0), (4, "LOAD_TS", "date", "date/time", 19, 0),
           (5, "REGION", "varchar2", "string", 20, 0)]
    q("INSERT INTO OPB_TARG_FLD VALUES (600,?,?,?,?,?,?,1)", [(f, n, *nat(a, b), p, s) for f, n, a, b, p, s in tgt])
    # Transformations-Ports: (widget, field, name, typ, prec, scale, porttype, expression-zeilen)
    F = [
        (501, 1, "CUST_ID", "decimal", 10, 0, 3, ["CUST_ID"]), (501, 2, "FIRST_NAME", "string", 30, 0, 3, ["FIRST_NAME"]),
        (501, 3, "LAST_NAME", "string", 30, 0, 3, ["LAST_NAME"]), (501, 4, "COUNTRY", "string", 2, 0, 3, ["COUNTRY"]),
        (502, 1, "CUST_ID", "decimal", 10, 0, 3, ["CUST_ID"]), (502, 2, "FIRST_NAME", "string", 30, 0, 1, None),
        (502, 3, "LAST_NAME", "string", 30, 0, 1, None), (502, 4, "COUNTRY", "string", 2, 0, 1, None),
        (502, 5, "V_CTRY", "string", 2, 0, 32, ["UPPER(COUNTRY)"]),
        # Expression ueber zwei Zeilen, Umbruch mitten im Portnamen LAST_NAME
        (502, 6, "O_FULL_NAME", "string", 61, 0, 2, ["LTRIM(FIRST_NAME) || ' ' || LAST_", "NAME"]),
        (502, 7, "O_COUNTRY_NAME", "string", 50, 0, 2, [":LKP.LKP_COUNTRY(V_CTRY)"]),
        (502, 8, "O_LOAD_TS", "date/time", 29, 9, 2, ["SYSDATE"]),
        (502, 9, "O_FLAG", "string", 1, 0, 2, ["'Y'"]),
        (503, 1, "IN_CODE", "string", 2, 0, 1, None), (503, 2, "COUNTRY_CODE", "string", 2, 0, 8, None),
        (503, 3, "COUNTRY_NAME", "string", 50, 0, 10, None),
        (504, 1, "IN_COUNTRY", "string", 2, 0, 1, None), (504, 2, "COUNTRY_CODE", "string", 2, 0, 8, None),
        (504, 3, "REGION", "string", 20, 0, 10, None),
        (505, 1, "CUST_ID", "decimal", 10, 0, 1, None), (505, 2, "FULL_NAME", "string", 61, 0, 1, None),
        (505, 3, "CUST_ID1", "decimal", 10, 0, 2, None), (505, 4, "FULL_NAME1", "string", 61, 0, 2, None),
        (505, 5, "CUST_ID3", "decimal", 10, 0, 2, None), (505, 6, "FULL_NAME3", "string", 61, 0, 2, None),
    ]
    expr_id = 0
    for w, fid, name, typ, prec, scale, pt, lines in F:
        db.execute("INSERT INTO OPB_WIDGET_FIELD VALUES (?,?,?,?,?,?,?,2)", (w, fid, name, PM[typ], prec, scale, pt))
        if lines:
            expr_id += 1
            db.execute("INSERT INTO OPB_WIDGET_EXPR VALUES (?,?,?,2)", (w, fid, expr_id))
            q("INSERT INTO OPB_EXPRESSION VALUES (?,?,?,?,2)", [(w, expr_id, i + 1, t) for i, t in enumerate(lines)])
    # aeltere Version 1 von EXP_NAME: anderer Datentyp, andere Expression - darf nicht erscheinen
    db.execute("INSERT INTO OPB_WIDGET_FIELD VALUES (502,6,'O_FULL_NAME',4,10,0,2,1)")
    db.execute("INSERT INTO OPB_WIDGET_EXPR VALUES (502,6,900,1)")
    db.execute("INSERT INTO OPB_EXPRESSION VALUES (502,900,1,'CUST_ID',1)")
    db.execute("INSERT INTO OPB_WIDGET_FIELD VALUES (999,1,'ALT',12,1,0,2,1)")
    # Lookup-Bedingungen (Attribut-ID 5 beim Lookup) und eine Tabelle (ID 2)
    q("INSERT INTO OPB_ATTR VALUES (?,?,?)", [(11, 2, "Lookup table name"), (11, 5, "Lookup condition"), (5, 5, "Anderes Attribut")])
    q("INSERT INTO OPB_WIDGET_ATTR VALUES (?,?,?,?,1)", [(504, 11, 5, "COUNTRY_CODE = IN_COUNTRY"), (504, 11, 2, "D_REGION"),
                                                         (503, 11, 5, "COUNTRY_CODE = IN_CODE")])
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
    """Oracle-SQL fuer SQLite umschreiben (nur Test): RECURSIVE, Expression-Verkettung, DBMS_LOB.SUBSTR, Parameter."""
    sql = open(path).read()
    sql = sql.replace("WITH\nparams AS", "WITH RECURSIVE\nparams AS", 1)
    sql = re.sub(r"/\*EXPR_AGG\*/.*? AS expression", "group_concat(e.EXPRESSION, '') AS expression", sql)
    sql = sql.replace("DBMS_LOB.SUBSTR(", "LOB_SUBSTR(")
    for k, v in params.items():
        sql = re.sub(r"'[^']*'(\s+AS p_%s\b)" % k, "'%s'\\1" % v, sql)
    return sql
