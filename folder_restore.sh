#!/bin/bash
### folder_restore.sh
### Restore aus einem Lauf von folder_backup.sh: alles, einzelne Folder oder einzelne Objekte,
### in der Reihenfolge von import_order.txt (Shared Folder zuerst).
###
### Standard ist TROCKENLAUF: Dateien werden geprueft (Pruefsumme), Ziel-Folder abgeglichen,
### ein Plan geschrieben - importiert wird nur mit --execute.
### Der Backup-Lauf bleibt unveraendert: gearbeitet wird in einem eigenen Arbeitsverzeichnis.
###
### Exitcodes: 0 = OK, 1 = teilweise fehlerhaft, 2 = Abbruch

set -u
umask 027

usage() {
cat <<'EOF'
Aufruf:
  folder_restore.sh [-c CONFIG] -r ZIEL_REPO -d DOMAIN -n USER [Optionen]

Verbindung (Ziel-Repository):
  -r REPO             Ziel-Repository (wird in den Control-Files als TARGETREPOSITORYNAME gesetzt)
  -d DOMAIN           Domain-Name
  -n USER             Repository-User
  -s SECDOMAIN        Security Domain (LDAP), falls benoetigt
  -X VAR              Umgebungsvariable mit dem pmpasswd-verschluesselten Passwort (Standard: INFA_PASSWORD)
  -P PFAD             Pfad zu pmrep

Quelle und Umfang:
  -b VERZ             Backup-Basisverzeichnis (wie bei folder_backup, Standard: ./infa_backup)
  -L LAUF             Backup-Lauf (Verzeichnisname oder Pfad; Standard: Inhalt von LATEST_SUCCESS)
  -F A,B              nur diese Folder
  -O REGEX            nur Dateien, deren Pfad passt (z.B. 'DWH/06_mapping/m_load_sales')
  --dtd DATEI         impcntl.dtd (Standard: neben pmrep bzw. $INFA_HOME/server/bin)

Ausfuehrung:
  -w VERZ             Arbeitsverzeichnis (Standard: <BASEDIR>/restore_<REPO>_<Zeitstempel>)
  -c DATEI            Konfigurationsdatei (gleiches Format wie folder_backup.conf)
  --create-folders    fehlende Ziel-Folder anlegen (Shared-Eigenschaft aus dem Backup)
  --checkin TEXT      versioniertes Repository: nach dem Import mit diesem Kommentar einchecken
  --validate          importierte Mappings, Mapplets, Sessions, Worklets, Workflows validieren
  --no-verify         Pruefsummen nicht kontrollieren
  --fail-fast         beim ersten Fehler abbrechen
  --max-errors N      Abbruch ab N Fehlern (Standard: 0 = nie)
  --execute           importieren (sonst Trockenlauf)
  --yes               keine Rueckfrage bei --execute
  -h | --help         diese Hilfe
EOF
}

### ---------------------------------------------------------------- Parameter
REPO=""; DOMAIN=""; REPUSER=""; SECDOMAIN=""; PASSVAR="INFA_PASSWORD"; PMREP=""
BASEDIR="./infa_backup"; RUN=""; FOLDERS=""; OBJ_RE=""; DTD=""; WORKDIR=""; CONFIG=""
CREATE_FOLDERS=0; CHECKIN=""; VALIDATE=0; VERIFY=1; FAIL_FAST=0; MAX_ERRORS=0; EXECUTE=0; ASSUME_YES=0

load_config() {  # gleiche Datei wie folder_backup; backup-spezifische Schluessel werden ignoriert
  local key val
  [ -r "$1" ] || { echo "[FEHLER] - Konfigurationsdatei nicht lesbar: $1"; exit 2; }
  while IFS='=' read -r key val; do
    key=$(printf '%s' "$key" | tr -d ' \t\r'); val=$(printf '%s' "$val" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/\r$//')
    case "$key" in
      REPO|DOMAIN|SECDOMAIN|PASSVAR|PMREP|BASEDIR) printf -v "$key" '%s' "$val" ;;
      USER) REPUSER="$val" ;;
    esac
  done < "$1"
}
ARGS=("$@")
for ((i=0; i<${#ARGS[@]}; i++)); do [ "${ARGS[$i]}" = "-c" ] && CONFIG="${ARGS[$((i+1))]:-}"; done
[ -n "$CONFIG" ] && load_config "$CONFIG"

while [ $# -gt 0 ]; do
  case "$1" in
    -c) shift 2 ;;
    -r) REPO="$2"; shift 2 ;;
    -d) DOMAIN="$2"; shift 2 ;;
    -n) REPUSER="$2"; shift 2 ;;
    -s) SECDOMAIN="$2"; shift 2 ;;
    -X) PASSVAR="$2"; shift 2 ;;
    -P) PMREP="$2"; shift 2 ;;
    -b) BASEDIR="$2"; shift 2 ;;
    -L) RUN="$2"; shift 2 ;;
    -F) FOLDERS="$2"; shift 2 ;;
    -O) OBJ_RE="$2"; shift 2 ;;
    -w) WORKDIR="$2"; shift 2 ;;
    --dtd) DTD="$2"; shift 2 ;;
    --create-folders) CREATE_FOLDERS=1; shift ;;
    --checkin) CHECKIN="$2"; shift 2 ;;
    --validate) VALIDATE=1; shift ;;
    --no-verify) VERIFY=0; shift ;;
    --fail-fast) FAIL_FAST=1; shift ;;
    --max-errors) MAX_ERRORS="$2"; shift 2 ;;
    --execute) EXECUTE=1; shift ;;
    --yes) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "[FEHLER] - unbekannte Option: $1"; usage; exit 2 ;;
  esac
done

die() { echo "[FEHLER] - $1"; exit 2; }
[ -n "$REPO" ] && [ -n "$DOMAIN" ] && [ -n "$REPUSER" ] || { usage; exit 2; }
[[ "$MAX_ERRORS" =~ ^[0-9]+$ ]] || die "--max-errors muss eine Zahl sein"

if [ -z "$PMREP" ]; then
  if command -v pmrep >/dev/null 2>&1; then PMREP="pmrep"
  elif [ -n "${INFA_HOME:-}" ] && [ -x "${INFA_HOME}/server/bin/pmrep" ]; then PMREP="${INFA_HOME}/server/bin/pmrep"
  else die "pmrep nicht gefunden (-P oder PATH/INFA_HOME setzen)"
  fi
fi
if [ -z "$DTD" ]; then
  for c in "$(dirname "$(command -v "$PMREP" 2>/dev/null || echo "$PMREP")")/impcntl.dtd" "${INFA_HOME:-/nonexistent}/server/bin/impcntl.dtd"; do
    [ -f "$c" ] && { DTD="$c"; break; }
  done
fi
[ -n "$DTD" ] && [ -f "$DTD" ] || die "impcntl.dtd nicht gefunden (--dtd angeben)"

### ---------------------------------------------------------------- Backup-Lauf bestimmen
[ -d "$BASEDIR" ] || die "Backup-Basisverzeichnis fehlt: $BASEDIR"
BASEDIR=$(cd "$BASEDIR" && pwd)
if [ -z "$RUN" ]; then
  [ -s "$BASEDIR/LATEST_SUCCESS" ] || die "kein Lauf angegeben (-L) und $BASEDIR/LATEST_SUCCESS fehlt"
  RUN=$(head -1 "$BASEDIR/LATEST_SUCCESS")
fi
case "$RUN" in /*) RUNDIR="$RUN" ;; *) RUNDIR="$BASEDIR/$RUN" ;; esac
[ -d "$RUNDIR" ] || die "Backup-Lauf nicht gefunden: $RUNDIR"
[ -f "$RUNDIR/RUNNING" ] && die "Backup-Lauf $RUNDIR laeuft noch oder wurde abgebrochen (RUNNING)"
[ -f "$RUNDIR/import_order.txt" ] && [ -f "$RUNDIR/manifest.csv" ] || die "import_order.txt oder manifest.csv fehlt in $RUNDIR"

STAMP=$(date +%Y%m%d_%H%M%S)
[ -z "$WORKDIR" ] && WORKDIR="$BASEDIR/restore_$(printf '%s' "$REPO" | tr -c 'A-Za-z0-9_.\n-' '_')_$STAMP"
n=1; BASE_WD="$WORKDIR"; while [ -e "$WORKDIR" ]; do n=$((n+1)); WORKDIR="${BASE_WD}_$n"; done
mkdir -p "$WORKDIR/src" "$WORKDIR/log" || die "Arbeitsverzeichnis nicht anlegbar: $WORKDIR"
WORKDIR=$(cd "$WORKDIR" && pwd)
LOG="$WORKDIR/restore.log"; REPORT="$WORKDIR/restore_report.csv"; PLAN="$WORKDIR/restore_plan.txt"
export INFA_REPCNX_INFO="$WORKDIR/pmrep.cnx"
trap 'rm -f "$INFA_REPCNX_INFO"' EXIT
ERRORS=0; WARNINGS=0

log()  { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG"; }
warn() { WARNINGS=$((WARNINGS+1)); log "[WARNUNG] - $*"; }
safe() { printf '%s\n' "$1" | tr -c 'A-Za-z0-9_.\n-' '_'; }
record_error() {
  ERRORS=$((ERRORS+1)); log "[FEHLER] - $1"
  if [ "$FAIL_FAST" -eq 1 ] || { [ "$MAX_ERRORS" -gt 0 ] && [ "$ERRORS" -ge "$MAX_ERRORS" ]; }; then
    log "[ABBRUCH] - Fehlergrenze erreicht ($ERRORS)"; exit 2
  fi
}
checksum() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  elif command -v openssl >/dev/null 2>&1; then openssl dgst -sha256 "$1" | sed 's/.*= //'
  else echo "-"
  fi
}

log "[FOLDER_RESTORE] - Modus: $([ $EXECUTE -eq 1 ] && echo AUSFUEHREN || echo TROCKENLAUF)"
log "[INFO] - Quelle: $RUNDIR  Ziel-Repository: $REPO  Arbeitsverzeichnis: $WORKDIR"
for st in SUCCESS PARTIAL FAILED; do
  [ -f "$RUNDIR/$st" ] && BSTATUS=$st
done
case "${BSTATUS:-?}" in
  SUCCESS) ;;
  PARTIAL) warn "Backup-Lauf ist PARTIAL - fehlende Objekte siehe manifest.csv (Status FEHLER)" ;;
  *) warn "Backup-Lauf hat Status ${BSTATUS:-unbekannt} - Restore nur mit Vorsicht" ;;
esac

### ---------------------------------------------------------------- Auswahl
SEL="$WORKDIR/selection.txt"
awk -F'|' -v flist="$FOLDERS" 'BEGIN { n=split(flist, a, ","); for (i=1;i<=n;i++) { gsub(/^[ \t]+|[ \t]+$/,"",a[i]); if (a[i]!="") want[a[i]]=1 } }
  NF>=3 && (n==0 || ($1 in want))' "$RUNDIR/import_order.txt" > "$SEL"
if [ -n "$OBJ_RE" ]; then grep -E "^[^|]*\|[^|]*($OBJ_RE)" "$SEL" > "$SEL.tmp"; mv "$SEL.tmp" "$SEL"; fi
if [ -n "$FOLDERS" ]; then
  IFS=',' read -ra _F <<< "$FOLDERS"
  for f in "${_F[@]}"; do
    f="${f#"${f%%[![:space:]]*}"}"; f="${f%"${f##*[![:space:]]}"}"
    grep -q "^$(printf '%s' "$f" | sed 's/[][\.*^$|+?(){}]/\\&/g')|" "$RUNDIR/import_order.txt" || record_error "Folder $f ist nicht im Backup-Lauf"
  done
fi
[ -s "$SEL" ] || { log "[FEHLER] - keine Dateien ausgewaehlt"; exit 2; }
log "[INFO] - $(wc -l < "$SEL" | tr -d ' ') Datei(en) in $(cut -d'|' -f1 "$SEL" | sort -u | wc -l | tr -d ' ') Folder(n) ausgewaehlt"

### ---------------------------------------------------------------- Dateien bereitstellen und pruefen
# Folder-Verzeichnis oder Archiv (.tar.gz) ins Arbeitsverzeichnis uebernehmen
declare -A PREPARED=()
prepare_folder() {  # $1=sicherer Foldername
  [ -n "${PREPARED[$1]:-}" ] && return "${PREPARED[$1]}"
  if [ -d "$RUNDIR/$1" ]; then
    mkdir -p "$WORKDIR/src/$1" && cp "$RUNDIR/$1/import_ctrl.xml" "$WORKDIR/src/$1/" 2>/dev/null
  elif [ -f "$RUNDIR/$1.tar.gz" ]; then
    tar xzf "$RUNDIR/$1.tar.gz" -C "$WORKDIR/src" 2>> "$WORKDIR/log/extract.txt" || { PREPARED[$1]=1; return 1; }
  else
    PREPARED[$1]=1; return 1
  fi
  PREPARED[$1]=0; return 0
}

xml_esc()  { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/"/\&quot;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
sed_repl() { printf '%s' "$1" | sed -e 's/[\\|&]/\\&/g'; }   # fuer die Ersetzung in sed "s|...|...|"

# Control-File anpassen: Ziel-Repository, ggf. Check-in
prepare_ctrl() {  # $1=ctrl-Datei im Arbeitsverzeichnis
  local c="$1" esc
  esc=$(sed_repl "$(xml_esc "$REPO")")
  sed -i "s|TARGETREPOSITORYNAME=\"[^\"]*\"|TARGETREPOSITORYNAME=\"$esc\"|g" "$c"
  if [ -n "$CHECKIN" ]; then
    local cm; cm=$(sed_repl "$(xml_esc "$CHECKIN")")
    sed -i "s|CHECKIN_AFTER_IMPORT=\"NO\"|CHECKIN_AFTER_IMPORT=\"YES\" CHECKIN_COMMENTS=\"$cm\"|" "$c"
  fi
  cp "$DTD" "$(dirname "$c")/impcntl.dtd"
}

ITEMS="$WORKDIR/items.txt"; : > "$ITEMS"
declare -A CTRL_DONE=() FOLDER_SHARED=()
while IFS='|' read -r F REL CTRL; do
  SF="${REL%%/*}"
  if ! prepare_folder "$SF"; then record_error "$F: weder Verzeichnis noch Archiv $SF.tar.gz im Backup-Lauf"; continue; fi
  if [ -d "$RUNDIR/$SF" ]; then
    mkdir -p "$(dirname "$WORKDIR/src/$REL")"
    cp "$RUNDIR/$REL" "$WORKDIR/src/$REL" 2>/dev/null || { record_error "$F: $REL fehlt im Backup-Lauf"; continue; }
  fi
  [ -f "$WORKDIR/src/$REL" ] || { record_error "$F: $REL fehlt im Backup-Lauf"; continue; }
  if [ $VERIFY -eq 1 ]; then
    EXP=$(awk -F';' -v d="$REL" '$4==d {print $6; exit}' "$RUNDIR/manifest.csv")
    if [ -n "$EXP" ] && [ "$EXP" != "-" ] && [ "$(checksum "$WORKDIR/src/$REL")" != "$EXP" ]; then
      record_error "$F: $REL - Pruefsumme stimmt nicht mit manifest.csv ueberein, wird nicht importiert"; continue
    fi
  fi
  if [ -z "${CTRL_DONE[$CTRL]:-}" ]; then
    [ -f "$WORKDIR/src/$CTRL" ] || { record_error "$F: Control-File $CTRL fehlt"; continue; }
    prepare_ctrl "$WORKDIR/src/$CTRL"; CTRL_DONE[$CTRL]=1
  fi
  if [ -z "${FOLDER_SHARED[$F]:-}" ]; then
    grep -q '<FOLDER [^>]*SHARED *= *"SHARED"' "$WORKDIR/src/$REL" && FOLDER_SHARED[$F]=1 || FOLDER_SHARED[$F]=0
  fi
  echo "$F|$REL|$CTRL" >> "$ITEMS"
done < "$SEL"

### ---------------------------------------------------------------- Verbindung, Ziel-Folder
PW_PLAIN=""
connect() {
  local args=(connect -r "$REPO" -d "$DOMAIN" -n "$REPUSER")
  [ -n "$SECDOMAIN" ] && args+=(-s "$SECDOMAIN")
  if [ -n "${!PASSVAR:-}" ]; then args+=(-X "$PASSVAR")
  elif [ -n "$PW_PLAIN" ]; then args+=(-x "$PW_PLAIN")
  else return 1; fi
  "$PMREP" "${args[@]}" > "$WORKDIR/log/connect.txt" 2>&1
}
if [ -z "${!PASSVAR:-}" ]; then
  if [ -t 0 ]; then printf 'Passwort fuer %s: ' "$REPUSER"; stty -echo 2>/dev/null; read -r PW_PLAIN; stty echo 2>/dev/null; echo
  else log "[FEHLER] - kein Passwort: Umgebungsvariable $PASSVAR (pmpasswd-verschluesselt) setzen"; exit 2; fi
fi
if ! connect; then
  log "[FEHLER] - Verbindung zu $REPO fehlgeschlagen, siehe $WORKDIR/log/connect.txt"
  [ -n "${!PASSVAR:-}" ] && log "[HINWEIS] - $PASSVAR muss das mit pmpasswd verschluesselte Passwort enthalten"
  exit 2
fi
log "[STATUS] - verbunden mit $REPO"

"$PMREP" listobjects -o folder > "$WORKDIR/log/list_folders.txt" 2>&1 || { log "[FEHLER] - Folderliste nicht lesbar"; exit 2; }
declare -A MISSING=()
# Folder in Import-Reihenfolge (Shared Folder zuerst)
mapfile -t FOLDER_ORDER < <(cut -d'|' -f1 "$ITEMS" | awk '!seen[$0]++')
while IFS= read -r F; do
  awk '{ gsub(/^[ \t]+|[ \t\r]+$/,""); print }' "$WORKDIR/log/list_folders.txt" | grep -qxF "$F" || MISSING[$F]=1
done < <(printf '%s\n' "${FOLDER_ORDER[@]}")

### ---------------------------------------------------------------- Plan
{
  echo "# Restore-Plan $STAMP - Quelle $RUNDIR -> Repository $REPO"
  for F in "${FOLDER_ORDER[@]}"; do
    [ -n "${MISSING[$F]:-}" ] || continue
    if [ $CREATE_FOLDERS -eq 1 ]; then
      echo "\"$PMREP\" createfolder -n \"$F\"$([ "${FOLDER_SHARED[$F]:-0}" = 1 ] && echo ' -s')"
    else
      echo "# FEHLT: Folder $F existiert im Ziel nicht (--create-folders) - seine Dateien werden uebersprungen"
    fi
  done
  while IFS='|' read -r F REL CTRL; do
    echo "\"$PMREP\" objectimport -i \"$WORKDIR/src/$REL\" -c \"$WORKDIR/src/$CTRL\""
  done < "$ITEMS"
} > "$PLAN"
for F in "${FOLDER_ORDER[@]}"; do
  [ -n "${MISSING[$F]:-}" ] || continue
  if [ $CREATE_FOLDERS -eq 1 ]; then log "[INFO] - Folder $F fehlt im Ziel und wird angelegt$([ "${FOLDER_SHARED[$F]:-0}" = 1 ] && echo ' (shared)')"
  else record_error "Folder $F existiert im Ziel-Repository nicht - --create-folders angeben oder anlegen"; fi
done
log "[INFO] - $(wc -l < "$ITEMS" | tr -d ' ') Import(e) geplant, Plan: $PLAN"

echo "folder;datei;import;validierung;meldung" > "$REPORT"
if [ $EXECUTE -eq 0 ]; then
  log "[TROCKENLAUF] - nichts importiert. Zum Ausfuehren mit --execute erneut starten."
  [ $ERRORS -eq 0 ] && exit 0 || exit 1
fi

### ---------------------------------------------------------------- Ausfuehren
if [ $ASSUME_YES -eq 0 ]; then
  printf '%s Datei(en) nach %s importieren? Bestehende Objekte werden ersetzt. [JA eingeben]: ' "$(wc -l < "$ITEMS" | tr -d ' ')" "$REPO"
  read -r ANSWER; [ "$ANSWER" = "JA" ] || { log "[ABBRUCH] - nichts importiert."; exit 0; }
fi

for F in "${FOLDER_ORDER[@]}"; do
  [ -n "${MISSING[$F]:-}" ] || continue
  [ $CREATE_FOLDERS -eq 1 ] || continue
  CF=(createfolder -n "$F"); [ "${FOLDER_SHARED[$F]:-0}" = 1 ] && CF+=(-s)
  if "$PMREP" "${CF[@]}" > "$WORKDIR/log/createfolder_$(safe "$F").txt" 2>&1; then log "[FOLDER] - $F angelegt"; unset "MISSING[$F]"
  else record_error "Folder $F konnte nicht angelegt werden, siehe log/createfolder_$(safe "$F").txt"; fi
done

N_OK=0; N_IMP=0
VALIDATE_LIST="$WORKDIR/validate.txt"; : > "$VALIDATE_LIST"
while IFS='|' read -r F REL CTRL; do
  if [ -n "${MISSING[$F]:-}" ]; then echo "$F;$REL;UEBERSPRUNGEN;;Folder fehlt im Ziel" >> "$REPORT"; continue; fi
  N_IMP=$((N_IMP+1))
  LOGF="$WORKDIR/log/import_$(safe "$REL").log"; OUTF="$WORKDIR/log/import_$(safe "$REL").out"
  "$PMREP" objectimport -i "$WORKDIR/src/$REL" -c "$WORKDIR/src/$CTRL" -l "$LOGF" > "$OUTF" 2>&1; RC=$?
  # Verbindungsverlust: einmal neu verbinden und wiederholen
  if [ $RC -ne 0 ] && grep -qiE 'not connected|failed to connect|repository service is not available|connection' "$OUTF"; then
    connect && { "$PMREP" objectimport -i "$WORKDIR/src/$REL" -c "$WORKDIR/src/$CTRL" -l "$LOGF" > "$OUTF" 2>&1; RC=$?; }
  fi
  ALL=$(cat "$OUTF" "$LOGF" 2>/dev/null)
  # Fehlerzeilen, aber keine Zusammenfassungen wie "0 errors"
  ERRL=$(printf '%s\n' "$ALL" | grep -iE '\berrors?\b|failed' | grep -viE '\b0 (errors?|failed)\b|no errors')
  if [ $RC -ne 0 ] || [ -n "$ERRL" ]; then
    MSG=$(printf '%s\n' "$ERRL" | head -1 | tr ';' ',')
    echo "$F;$REL;FEHLER;;${MSG:-objectimport rc=$RC}" >> "$REPORT"
    record_error "$F: $REL - Import fehlgeschlagen"
    continue
  fi
  if printf '%s\n' "$ALL" | grep -qiE 'renamed|rename'; then
    MSG=$(printf '%s\n' "$ALL" | grep -iE 'renamed|rename' | head -1 | tr ';' ',')
    echo "$F;$REL;WARNUNG;;$MSG" >> "$REPORT"
    warn "$F: $REL - beim Import umbenannt (Duplikat?): $MSG"
  else
    echo "$F;$REL;OK;;" >> "$REPORT"
  fi
  N_OK=$((N_OK+1))
  awk -F';' -v d="$REL" '$4==d {print $1 "|" $2 "|" $3 "|" d; exit}' "$RUNDIR/manifest.csv" >> "$VALIDATE_LIST"
done < "$ITEMS"

### ---------------------------------------------------------------- Validierung
N_INV=0
if [ $VALIDATE -eq 1 ]; then
  VSTAT="$WORKDIR/validate_status.txt"; : > "$VSTAT"
  while IFS='|' read -r F T NAME REL; do
    case "$(printf '%s' "$T" | tr 'A-Z' 'a-z')" in mapping|mapplet|session|worklet|workflow) ;; *) continue ;; esac
    VOUT="$WORKDIR/log/validate_$(safe "$F")_$(safe "$NAME").txt"
    VA=(validate -n "$NAME" -o "$T" -f "$F" -s)
    [ -n "$CHECKIN" ] && VA+=(-k -m "$CHECKIN")
    if "$PMREP" "${VA[@]}" > "$VOUT" 2>&1 && ! grep -viE '\b0 invalid' "$VOUT" | grep -qiE '\binvalid\b'; then
      log "[VALIDIERT] - $F: $T $NAME"; echo "$REL;GUELTIG" >> "$VSTAT"
    else
      N_INV=$((N_INV+1)); echo "$REL;UNGUELTIG" >> "$VSTAT"
      record_error "$F: $T $NAME ist nach dem Import ungueltig, siehe log/$(basename "$VOUT")"
    fi
  done < "$VALIDATE_LIST"
  # Validierungsergebnis in den Report uebernehmen (Spalte 4)
  awk -F';' -v OFS=';' 'NR==FNR {v[$1]=$2; next} FNR>1 && ($2 in v) {$4=v[$2]} {print}' "$VSTAT" "$REPORT" > "$REPORT.tmp" && mv "$REPORT.tmp" "$REPORT"
fi

log "[ERGEBNIS] - $N_OK von $N_IMP importiert, $ERRORS Fehler, $WARNINGS Warnungen$([ $VALIDATE -eq 1 ] && echo ", $N_INV ungueltig")"
log "[ERGEBNIS] - Report: $REPORT"
[ $ERRORS -eq 0 ] && exit 0
exit 1
