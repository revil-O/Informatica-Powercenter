#!/bin/bash
### shortcut_repair.sh
### Findet verwaiste Shortcuts (ohne gueltige Referenz in den Shared Folder) und
### Duplikate mit Zahlen-Suffix (z.B. Shortcut_to_X1), die durch einen
### fehlgeschlagenen Import mit REPLACE entstanden sind.
###
### Standard ist TROCKENLAUF: es wird nur analysiert und ein Plan geschrieben.
### Geloescht wird ausschliesslich mit --execute (und Bestaetigung).
###
### use it at own risk ! vorher Repository-Backup ziehen !

set -u

usage() {
cat <<'EOF'
Aufruf:
  shortcut_repair.sh -r REPO -d DOMAIN -n USER -f FOLDER [Optionen]

Pflicht:
  -r REPO           Repository-Name (z.B. PM_PROD_REPO)
  -d DOMAIN         Domain-Name (z.B. Prod_Domain)
  -n USER           Repository-User
  -f FOLDER         zu pruefender Ordner (der mit den kaputten Shortcuts)

Optional:
  -s SECDOMAIN      Security Domain (LDAP), falls benoetigt
  -S SHARED[,..]    Shared Folder fuer das Control-File (Standard: aus den Shortcuts ermittelt)
  -R SRC_REPO       Quell-Repository-Name fuer das Control-File (Standard: REPO)
  -t TYPEN          Objekttypen, kommagetrennt (Standard: source,target,mapplet,transformation)
  -L DATEI          Objektliste statt "pmrep listobjects"; Zeilen: typ|name[|subtyp]
  -P PFAD           Pfad zu pmrep (Standard: pmrep aus PATH bzw. $INFA_HOME/server/bin)
  -o VERZ           Ausgabeverzeichnis (Standard: ./shortcut_repair_<Zeitstempel>)
  --no-connect      kein "pmrep connect" (bestehende Verbindung nutzen)
  --include-suspect auch Objekte loeschen, deren Export fehlschlug und die nirgends verwendet werden
  --execute         Plan ausfuehren (loeschen) - ohne diese Option nur Trockenlauf
  --yes             keine Rueckfrage bei --execute
  -h | --help       diese Hilfe

Passwort: Umgebungsvariable INFA_PASSWORD, sonst interaktive Abfrage.
EOF
}

### ---------------------------------------------------------------- Parameter
REPO=""; DOMAIN=""; REPUSER=""; FOLDER=""; SECDOMAIN=""; SHARED_ARG=""; SRC_REPO=""
TYPES="source,target,mapplet,transformation"; OBJ_FILE=""; PMREP=""; OUTDIR=""
DO_CONNECT=1; INCLUDE_SUSPECT=0; EXECUTE=0; ASSUME_YES=0

while [ $# -gt 0 ]; do
  case "$1" in
    -r) REPO="$2"; shift 2 ;;
    -d) DOMAIN="$2"; shift 2 ;;
    -n) REPUSER="$2"; shift 2 ;;
    -f) FOLDER="$2"; shift 2 ;;
    -s) SECDOMAIN="$2"; shift 2 ;;
    -S) SHARED_ARG="$2"; shift 2 ;;
    -R) SRC_REPO="$2"; shift 2 ;;
    -t) TYPES="$2"; shift 2 ;;
    -L) OBJ_FILE="$2"; shift 2 ;;
    -P) PMREP="$2"; shift 2 ;;
    -o) OUTDIR="$2"; shift 2 ;;
    --no-connect) DO_CONNECT=0; shift ;;
    --include-suspect) INCLUDE_SUSPECT=1; shift ;;
    --execute) EXECUTE=1; shift ;;
    --yes) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "[FEHLER] - unbekannte Option: $1"; usage; exit 2 ;;
  esac
done

if [ -z "$FOLDER" ] || { [ $DO_CONNECT -eq 1 ] && { [ -z "$REPO" ] || [ -z "$DOMAIN" ] || [ -z "$REPUSER" ]; }; }; then
  usage; exit 2
fi
[ -z "$SRC_REPO" ] && SRC_REPO="$REPO"

if [ -z "$PMREP" ]; then
  if command -v pmrep >/dev/null 2>&1; then PMREP="pmrep"
  elif [ -n "${INFA_HOME:-}" ] && [ -x "${INFA_HOME}/server/bin/pmrep" ]; then PMREP="${INFA_HOME}/server/bin/pmrep"
  else echo "[FEHLER] - pmrep nicht gefunden (Option -P oder PATH/INFA_HOME setzen)"; exit 2
  fi
fi

[ -z "$OUTDIR" ] && OUTDIR="./shortcut_repair_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUTDIR/xml" "$OUTDIR/log" || exit 2
OUTDIR=$(cd "$OUTDIR" && pwd)
LOG="$OUTDIR/run.log"
REPORT="$OUTDIR/report.csv"
PLAN="$OUTDIR/plan.txt"
CTRL="$OUTDIR/ctrl_reimport.xml"

### eigene Verbindungsdatei, damit kein fremdes pmrep.cnx ueberschrieben wird
if [ $DO_CONNECT -eq 1 ]; then
  export INFA_REPCNX_INFO="$OUTDIR/pmrep.cnx"
fi

log() { echo "$*" | tee -a "$LOG"; }

### Liste der Typen, die pmrep deleteobject unterstuetzt
DELETABLE=" source target mapplet "

### ---------------------------------------------------------------- Hilfsfunktionen
# XML-Attribut aus einem einzeiligen Element lesen (Informatica schreibt NAME ="x")
get_attr() {
  printf '%s\n' "$1" | sed -n "s/.*[[:space:]]$2[[:space:]]*=[[:space:]]*\"\([^\"]*\)\".*/\1/p"
}

# Name ohne DBD-Praefix (nur bei Sources: DBD.NAME)
short_name() {
  if [ "$1" = "source" ]; then printf '%s\n' "${2#*.}"; else printf '%s\n' "$2"; fi
}

# Dateiname-sicherer Name
safe() { printf '%s\n' "$1" | tr -c 'A-Za-z0-9_.\n-' '_'; }

# pmrep listobjects -> Zeilen "typ|name|subtyp"
list_objects() {  # $1=typ $2=folder $3=ausgabedatei
  local raw; raw="$OUTDIR/log/list_$(safe "$2")_$1.txt"
  if ! "$PMREP" listobjects -o "$1" -f "$2" -c "|" > "$raw" 2>&1; then
    return 1
  fi
  awk -F'|' -v t="$1" '
    tolower($1)==t {
      name=""; sub_t="";
      for (i=2;i<=NF;i++) {
        v=$i; gsub(/^[ \t]+|[ \t\r]+$/,"",v);
        if (v=="" || v=="reusable" || v=="non-reusable") continue;
        if (name=="") name=v; else if (sub_t=="") sub_t=v;
      }
      # bei Transformationen steht der Subtyp i.d.R. vor dem Namen
      if (t=="transformation" && sub_t!="") { tmp=name; name=sub_t; sub_t=tmp }
      if (name!="") print t "|" name "|" sub_t
    }' "$raw" > "$3"
  return 0
}

# Anzahl der Eltern-Objekte (Mappings, Sessions, ...) - "?" wenn unbekannt
count_parents() {  # $1=typ $2=name $3=subtyp
  local out; out="$OUTDIR/log/deps_$1_$(safe "$2").txt"
  local args=(listobjectdependencies -n "$2" -o "$1" -f "$FOLDER" -p parents)
  [ -n "$3" ] && args+=(-t "$3")
  if ! "$PMREP" "${args[@]}" > "$out" 2>&1; then
    echo "?"; return
  fi
  grep -ciE '^[[:space:]]*(mapping|mapplet|session|worklet|workflow|transformation|target|source|task)[[:space:]|]' "$out"
}

### ---------------------------------------------------------------- Start
log "[SHORTCUT_REPAIR] - $(date '+%Y-%m-%d %H:%M:%S') - Modus: $([ $EXECUTE -eq 1 ] && echo AUSFUEHREN || echo TROCKENLAUF)"
log "[INFO] - Repository=${REPO:-(bestehende Verbindung)} Folder=$FOLDER Typen=$TYPES Ausgabe=$OUTDIR"

if [ $DO_CONNECT -eq 1 ]; then
  if [ -z "${INFA_PASSWORD:-}" ]; then
    printf 'Passwort fuer %s: ' "$REPUSER"
    stty -echo 2>/dev/null; read -r INFA_PASSWORD; stty echo 2>/dev/null; echo
  fi
  export INFA_PASSWORD
  CONN=(connect -r "$REPO" -d "$DOMAIN" -n "$REPUSER" -X INFA_PASSWORD)
  [ -n "$SECDOMAIN" ] && CONN+=(-s "$SECDOMAIN")
  if ! "$PMREP" "${CONN[@]}" > "$OUTDIR/log/connect.txt" 2>&1; then
    log "[FEHLER] - Verbindung fehlgeschlagen, siehe $OUTDIR/log/connect.txt"; exit 1
  fi
  log "[STATUS] - verbunden mit $REPO"
fi

cleanup() { [ $DO_CONNECT -eq 1 ] && rm -f "$INFA_REPCNX_INFO"; }
trap cleanup EXIT

### ---------------------------------------------------------------- 1. Objekte sammeln
OBJLIST="$OUTDIR/objects.txt"
: > "$OBJLIST"
if [ -n "$OBJ_FILE" ]; then
  grep -v '^[[:space:]]*\(#\|$\)' "$OBJ_FILE" | tr -d '\r' > "$OBJLIST"
else
  for T in $(echo "$TYPES" | tr ',' ' '); do
    if list_objects "$T" "$FOLDER" "$OUTDIR/log/objs_$T.txt"; then
      cat "$OUTDIR/log/objs_$T.txt" >> "$OBJLIST"
    else
      log "[WARNUNG] - listobjects fuer Typ $T fehlgeschlagen (siehe log/list_*_$T.txt)"
    fi
  done
fi
log "[INFO] - $(wc -l < "$OBJLIST" | tr -d ' ') Objekte im Ordner $FOLDER gefunden"

### ---------------------------------------------------------------- 2. Shortcuts analysieren
# Ergebnis je Shortcut: typ|name|subtyp|status|ref_repo|ref_folder|ref_name|reftype|objsubtype
ANALYSIS="$OUTDIR/analysis.txt"
: > "$ANALYSIS"
declare -A REFCACHE   # "typ|folder" -> Datei mit Kurznamen oder "FAIL"

while IFS='|' read -r T NAME SUB; do
  [ -z "$T" ] && continue
  T=$(echo "$T" | tr 'A-Z' 'a-z')
  XML="$OUTDIR/xml/${T}_$(safe "$NAME").xml"
  ARGS=(objectexport -o "$T" -n "$NAME" -f "$FOLDER" -u "$XML")
  [ -n "$SUB" ] && ARGS+=(-t "$SUB")
  if ! "$PMREP" "${ARGS[@]}" > "$OUTDIR/log/export_${T}_$(safe "$NAME").txt" 2>&1 || [ ! -s "$XML" ]; then
    echo "$T|$NAME|$SUB|EXPORT_FAILED||||||" >> "$ANALYSIS"
    continue
  fi
  SN=$(short_name "$T" "$NAME")
  # Elemente auf je eine Zeile bringen und das SHORTCUT-Element dieses Objekts suchen
  SC=$(tr '\r\n' '  ' < "$XML" | sed 's/</\n</g' | grep '^<SHORTCUT[[:space:]]' | while IFS= read -r L; do
         [ "$(get_attr "$L" NAME)" = "$SN" ] && { printf '%s\n' "$L"; break; }
       done)
  [ -z "$SC" ] && continue   # kein Shortcut -> uninteressant

  RREPO=$(get_attr "$SC" REPOSITORYNAME)
  RFOLDER=$(get_attr "$SC" FOLDERNAME)
  RNAME=$(get_attr "$SC" REFOBJECTNAME)
  RTYPE=$(get_attr "$SC" REFERENCETYPE)
  OSUB=$(get_attr "$SC" OBJECTSUBTYPE)

  STATUS="OK"
  if [ "$RTYPE" = "GLOBAL" ]; then
    STATUS="GLOBAL_UNCHECKED"
  elif [ -z "$RFOLDER" ] || [ -z "$RNAME" ]; then
    STATUS="ORPHAN"
  else
    KEY="$T|$RFOLDER"
    if [ -z "${REFCACHE[$KEY]:-}" ]; then
      F="$OUTDIR/log/ref_$(safe "$RFOLDER")_$T.txt"
      if list_objects "$T" "$RFOLDER" "$F.tmp"; then
        cut -d'|' -f2 "$F.tmp" | while IFS= read -r n; do short_name "$T" "$n"; done > "$F"
        REFCACHE[$KEY]="$F"
      else
        REFCACHE[$KEY]="FAIL"
      fi
    fi
    if [ "${REFCACHE[$KEY]}" = "FAIL" ] || ! grep -qixF "$RNAME" "${REFCACHE[$KEY]}"; then
      STATUS="ORPHAN"
    fi
  fi
  echo "$T|$NAME|$SUB|$STATUS|$RREPO|$RFOLDER|$RNAME|$RTYPE|$OSUB" >> "$ANALYSIS"
done < "$OBJLIST"

### ---------------------------------------------------------------- 3. Plan erstellen
declare -A SEEN       # "typ|name" -> Status
while IFS='|' read -r T NAME SUB STATUS _; do SEEN["$T|$NAME"]="$STATUS"; done < "$ANALYSIS"

# ist NAME ein Zahlen-Suffix-Duplikat eines vorhandenen Shortcuts?  -> Basisname auf stdout
dup_base() {  # $1=typ $2=name
  [[ "$2" =~ ^(.*[^0-9])([0-9]+)$ ]] || return 1
  [ -n "${SEEN[$1|${BASH_REMATCH[1]}]:-}" ] || return 1
  printf '%s\n' "${BASH_REMATCH[1]}"
}
echo "typ;name;subtyp;status;ref_repository;ref_folder;ref_objekt;verwendet_von;aktion;hinweis" > "$REPORT"
: > "$PLAN"
DELETES="$OUTDIR/deletes.txt"; : > "$DELETES"
RENAMES="$OUTDIR/renames.txt"; : > "$RENAMES"
n_del=0; n_man=0; n_ren=0; n_ok=0

while IFS='|' read -r T NAME SUB STATUS RREPO RFOLDER RNAME RTYPE OSUB; do
  PARENTS=""; ACTION="KEINE"; HINT=""
  case "$STATUS" in
    OK|GLOBAL_UNCHECKED)
      n_ok=$((n_ok+1))
      # Suffix-Duplikat? (Name = Basisname + Ziffern, Basisname ist verwaist)
      if [[ "$NAME" =~ ^(.*[^0-9])([0-9]+)$ ]]; then
        BASE="${BASH_REMATCH[1]}"
        BSTAT="${SEEN[$T|$BASE]:-}"
        if [ "$BSTAT" = "ORPHAN" ] || [ "$BSTAT" = "EXPORT_FAILED" ]; then
          ACTION="UMBENENNEN_IM_DESIGNER"
          HINT="nach Loeschen von $(short_name "$T" "$BASE") umbenennen: $(short_name "$T" "$NAME") -> $(short_name "$T" "$BASE")"
          n_ren=$((n_ren+1))
          echo "# Designer ($T): $(short_name "$T" "$NAME") in $(short_name "$T" "$BASE") umbenennen (pmrep kann nicht umbenennen)" >> "$RENAMES"
        fi
      fi
      ;;
    ORPHAN|EXPORT_FAILED)
      PARENTS=$(count_parents "$T" "$NAME" "$SUB")
      if [ "$STATUS" = "EXPORT_FAILED" ] && [ $INCLUDE_SUSPECT -eq 0 ]; then
        ACTION="MANUELL_PRUEFEN"; HINT="Export fehlgeschlagen - Shortcut-Status unbekannt (--include-suspect zum Loeschen)"
      elif [[ "$DELETABLE" != *" $T "* ]]; then
        ACTION="MANUELL_PRUEFEN"; HINT="pmrep deleteobject unterstuetzt Typ $T nicht - im Designer loeschen"
      elif [ "$PARENTS" = "?" ]; then
        ACTION="MANUELL_PRUEFEN"; HINT="Abhaengigkeiten nicht ermittelbar - siehe log/deps_*"
      elif [ "$PARENTS" -gt 0 ]; then
        ACTION="MANUELL_PRUEFEN"; HINT="wird noch von $PARENTS Objekt(en) verwendet - Mappings neu importieren (ctrl_reimport.xml)"
      else
        ACTION="LOESCHEN"
        echo "$T|$NAME" >> "$DELETES"
        echo "\"$PMREP\" deleteobject -o $T -f \"$FOLDER\" -n \"$NAME\"" >> "$PLAN"
        n_del=$((n_del+1))
      fi
      [ "$ACTION" = "MANUELL_PRUEFEN" ] && n_man=$((n_man+1))
      ;;
  esac
  echo "$T;$NAME;$SUB;$STATUS;$RREPO;$RFOLDER;$RNAME;$PARENTS;$ACTION;$HINT" >> "$REPORT"
done < "$ANALYSIS"

# Reihenfolge im Plan: erst loeschen, dann umbenennen
cat "$RENAMES" >> "$PLAN"

### ---------------------------------------------------------------- 4. Control-File fuer Re-Import (Variante A)
SHARED_LIST=$( { echo "$SHARED_ARG" | tr ',' '\n'; awk -F'|' '$4=="OK" && $6!="" {print $6}' "$ANALYSIS"; } | grep -v '^$' | sort -u)
xml_esc() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/"/\&quot;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
{
  echo '<?xml version="1.0" encoding="UTF-8"?>'
  echo '<!DOCTYPE IMPORTPARAMS SYSTEM "impcntl.dtd">'
  echo '<!-- erzeugt von shortcut_repair.sh - vor Verwendung pruefen! -->'
  echo '<IMPORTPARAMS CHECKIN_AFTER_IMPORT="NO" RETAIN_GENERATED_VALUE="YES">'
  echo "  <FOLDERMAP SOURCEFOLDERNAME=\"$(xml_esc "$FOLDER")\" SOURCEREPOSITORYNAME=\"$(xml_esc "$SRC_REPO")\" TARGETFOLDERNAME=\"$(xml_esc "$FOLDER")\" TARGETREPOSITORYNAME=\"$(xml_esc "${REPO:-$SRC_REPO}")\"/>"
  printf '%s\n' "$SHARED_LIST" | while IFS= read -r SF; do
    [ -z "$SF" ] && continue
    echo "  <FOLDERMAP SOURCEFOLDERNAME=\"$(xml_esc "$SF")\" SOURCEREPOSITORYNAME=\"$(xml_esc "$SRC_REPO")\" TARGETFOLDERNAME=\"$(xml_esc "$SF")\" TARGETREPOSITORYNAME=\"$(xml_esc "${REPO:-$SRC_REPO}")\"/>"
  done
  echo '  <RESOLVECONFLICT>'
  # Shortcuts nie ersetzen, sondern wiederverwenden (Basisname, ohne Zahlen-Suffix-Duplikate)
  awk -F'|' '$4!="EXPORT_FAILED"' "$ANALYSIS" | while IFS='|' read -r T NAME SUB STATUS RREPO RFOLDER RNAME RTYPE OSUB; do
    dup_base "$T" "$NAME" >/dev/null && continue
    SN=$(short_name "$T" "$NAME")
    DBD=""; [ "$T" = "source" ] && [ "$NAME" != "$SN" ] && DBD=" DBDNAME=\"$(xml_esc "${NAME%%.*}")\""
    echo "    <SPECIFICOBJECT NAME=\"$(xml_esc "$SN")\"$DBD OBJECTTYPENAME=\"$(xml_esc "${OSUB:-$T}")\" FOLDERNAME=\"$(xml_esc "$FOLDER")\" REPOSITORYNAME=\"$(xml_esc "$SRC_REPO")\" RESOLUTION=\"REUSE\"/>"
  done
  echo '    <TYPEOBJECT OBJECTTYPENAME="All" RESOLUTION="REPLACE"/>'
  echo '  </RESOLVECONFLICT>'
  echo '</IMPORTPARAMS>'
} > "$CTRL"

### ---------------------------------------------------------------- 5. Zusammenfassung
log ""
log "[ERGEBNIS] - Shortcuts gueltig: $n_ok | zu loeschen: $n_del | manuell pruefen: $n_man | umbenennen (Designer): $n_ren"
log "[ERGEBNIS] - Report:       $REPORT"
log "[ERGEBNIS] - Plan:         $PLAN"
log "[ERGEBNIS] - Control-File: $CTRL"
if [ -s "$PLAN" ]; then log ""; log "----- Plan -----"; tee -a "$LOG" < "$PLAN"; log "----------------"; fi

if [ $EXECUTE -eq 0 ]; then
  log ""
  log "[TROCKENLAUF] - nichts geaendert. Zum Ausfuehren mit --execute erneut starten."
  exit 0
fi

### ---------------------------------------------------------------- 6. Ausfuehren
if [ $n_del -eq 0 ]; then log "[INFO] - nichts zu loeschen."; exit 0; fi
if [ $ASSUME_YES -eq 0 ]; then
  printf '%s Objekt(e) in %s loeschen? Repository-Backup vorhanden? [JA eingeben]: ' "$n_del" "$FOLDER"
  read -r ANSWER
  [ "$ANSWER" = "JA" ] || { log "[ABBRUCH] - nichts geloescht."; exit 0; }
fi

n_okdel=0; n_fail=0
while IFS='|' read -r T NAME; do
  if "$PMREP" deleteobject -o "$T" -f "$FOLDER" -n "$NAME" > "$OUTDIR/log/delete_${T}_$(safe "$NAME").txt" 2>&1; then
    log "[GELOESCHT] - $T $NAME"; n_okdel=$((n_okdel+1))
  else
    log "[FEHLER] - $T $NAME nicht geloescht, siehe log/delete_${T}_$(safe "$NAME").txt"; n_fail=$((n_fail+1))
  fi
done < "$DELETES"

log ""
log "[ERGEBNIS] - geloescht: $n_okdel | Fehler: $n_fail"
log "[HINWEIS] - versioniertes Repository: geloeschte Objekte einchecken (pmrep checkin / Designer), ggf. purgeversion."
[ $n_ren -gt 0 ] && log "[HINWEIS] - jetzt die $n_ren Duplikat(e) im Designer umbenennen und Mappings validieren (siehe Plan)."
[ $n_fail -eq 0 ] || exit 1
exit 0
