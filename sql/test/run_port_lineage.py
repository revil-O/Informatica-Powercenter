"""Fuehrt sql/oracle/port_lineage.sql gegen das nachgebaute Repository (SQLite) aus und prueft das Ergebnis.

Aufruf:  python3 sql/test/run_port_lineage.py [p_param=wert ...]
         z.B. python3 sql/test/run_port_lineage.py end_port=T_CUSTOMER.FULL_NAME
Ohne Parameter: Ausgabe aller Pfade plus Pruefung der erwarteten Pfade (Exitcode 1 bei Abweichung).
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import mockrepo  # noqa: E402

SQL = os.path.join(HERE, "..", "oracle", "port_lineage.sql")

EXPECTED = {
    "CUSTOMER.CUST_ID -> SQ_CUSTOMER.CUST_ID -> EXP_NAME.CUST_ID -> RTR_CTRY.CUST_ID -> RTR_CTRY.CUST_ID1 -> T_CUSTOMER.CUST_ID",
    "CUSTOMER.FIRST_NAME -> SQ_CUSTOMER.FIRST_NAME -> EXP_NAME.FIRST_NAME -> EXP_NAME.O_FULL_NAME -> RTR_CTRY.FULL_NAME -> RTR_CTRY.FULL_NAME1 -> T_CUSTOMER.FULL_NAME",
    "CUSTOMER.LAST_NAME -> SQ_CUSTOMER.LAST_NAME -> EXP_NAME.LAST_NAME -> EXP_NAME.O_FULL_NAME -> RTR_CTRY.FULL_NAME -> RTR_CTRY.FULL_NAME1 -> T_CUSTOMER.FULL_NAME",
    "CUSTOMER.COUNTRY -> SQ_CUSTOMER.COUNTRY -> EXP_NAME.COUNTRY -> EXP_NAME.V_CTRY -> EXP_NAME.O_COUNTRY_NAME -> T_CUSTOMER.COUNTRY_NAME",
    "CUSTOMER.COUNTRY -> SQ_CUSTOMER.COUNTRY -> EXP_NAME.COUNTRY -> EXP_NAME.V_CTRY -> LKP_COUNTRY.IN_CODE -> LKP_COUNTRY.COUNTRY_NAME -> EXP_NAME.O_COUNTRY_NAME -> T_CUSTOMER.COUNTRY_NAME",
    "CUSTOMER.COUNTRY -> SQ_CUSTOMER.COUNTRY -> LKP_REGION.IN_COUNTRY -> LKP_REGION.REGION -> T_CUSTOMER.REGION",
    "EXP_NAME.O_LOAD_TS -> T_CUSTOMER.LOAD_TS",
}


def main():
    params = dict(a.split("=", 1) for a in sys.argv[1:])
    db = mockrepo.connect()
    cur = db.execute(mockrepo.load_sql(SQL, **params))
    cols = [d[0] for d in cur.description]
    rows = [dict(zip(cols, r)) for r in cur.fetchall()]
    last = None
    for d in rows:
        if d["pfad_id"] != last:
            last = d["pfad_id"]
            print(f"\nPfad {d['pfad_id']} ({d['schritte']} Schritte): {d['pfad']}")
        print(f"  {d['schritt']:>2} {d['kante']:<8} {d['instanz']:<12} {d['objekttyp']:<18} {d['port']:<15} "
              f"{d['porttyp']:<13} {d['datentyp']:<16} {d['expression'] or ''}")
    paths = {d["pfad"] for d in rows}
    print(f"\n{len(paths)} Pfade, {len(rows)} Zeilen")
    if not params:
        missing, extra = EXPECTED - paths, paths - EXPECTED
        for p in sorted(missing):
            print("FEHLT:     ", p)
        for p in sorted(extra):
            print("UNERWARTET:", p)
        print("Pruefung:", "OK" if not missing and not extra else "ABWEICHUNG")
        sys.exit(1 if missing or extra else 0)


if __name__ == "__main__":
    main()
