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
  --with-incrementals neuere inkrementelle Laeufe (folder_backup --incremental) ueber den Lauf legen:
                      je Datei wird die neueste Version importiert
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
WITH_INC=0; CREATE_FOLDERS=0; CHECKIN=""; VALIDATE=0; VERIFY=1; FAIL_FAST=0; MAX_ERRORS=0; EXECUTE=0; ASSUME_YES=0

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
    --with-incrementals) WITH_INC=1; shift ;;
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

### ---------------------------------------------------------------- Laeufe: Basis + ggf. neuere inkrementelle Laeufe
RUNS=("$RUNDIR")
[ -f "$RUNDIR/INCREMENTAL" ] && warn "der gewaehlte Lauf ist inkrementell - er enthaelt nur geaenderte Objekte"
if [ $WITH_INC -eq 1 ]; then
  RPREFIX=$(basename "$RUNDIR" | sed -E 's/_[0-9]{8}_[0-9]{6}.*$//')
  while IFS= read -r D; do
    [ "$(basename "$D")" \> "$(basename "$RUNDIR")" ] || continue
    [ -f "$D/INCREMENTAL" ] || continue
    if [ -f "$D/RUNNING" ]; then
      warn "inkrementeller Lauf $(basename "$D") laeuft noch oder wurde abgebrochen - wird uebersprungen"
    elif { [ -f "$D/SUCCESS" ] || [ -f "$D/PARTIAL" ]; } && [ -f "$D/import_order.txt" ]; then
      RUNS+=("$D"); log "[INFO] - inkrementeller Lauf einbezogen: $(basename "$D")"
    else
      warn "inkrementeller Lauf $(basename "$D") ist fehlgeschlagen - wird uebersprungen"
    fi
  done < <(find "$BASEDIR" -maxdepth 1 -type d -name "${RPREFIX}_*_inc*" 2>/dev/null | sort)
  [ ${#RUNS[@]} -eq 1 ] && log "[INFO] - keine neueren inkrementellen Laeufe gefunden"
fi

### ---------------------------------------------------------------- Auswahl
# ALLORD: "laufindex|folder|datei|ctrl" aus allen Laeufen; je Datei gewinnt der neueste Lauf.
# Reihenfolge: Folder wie im Basislauf (Shared zuerst), neue Folder dahinter; im Folder nach Typ-Praefix.
ALLORD="$WORKDIR/all_order.txt"; : > "$ALLORD"
for i in "${!RUNS[@]}"; do awk -v i="$i" 'NF { print i "|" $0 }' "${RUNS[$i]}/import_order.txt" >> "$ALLORD"; done
SEL="$WORKDIR/selection.txt"
awk -F'|' -v flist="$FOLDERS" '
  BEGIN { n=split(flist, a, ","); for (i=1;i<=n;i++) { gsub(/^[ \t]+|[ \t]+$/,"",a[i]); if (a[i]!="") want[a[i]]=1 } }
  NF>=4 && (n==0 || ($2 in want)) { if (!($2 in fo)) fo[$2]=++nf; line[$3]=$0; fol[$3]=$2 }
  END { for (r in line) printf "%06d\t%s\t%s\n", fo[fol[r]], r, line[r] }' "$ALLORD" | sort -t"$(printf '\t')" -k1,1 -k2,2 | cut -f3 > "$SEL"
if [ -n "$OBJ_RE" ]; then grep -E "^[^|]*\|[^|]*\|[^|]*($OBJ_RE)" "$SEL" > "$SEL.tmp"; mv "$SEL.tmp" "$SEL"; fi
if [ -n "$FOLDERS" ]; then
  IFS=',' read -ra _F <<< "$FOLDERS"
  for f in "${_F[@]}"; do
    f="${f#"${f%%[![:space:]]*}"}"; f="${f%"${f##*[![:space:]]}"}"
    cut -d'|' -f2 "$ALLORD" | grep -qxF "$f" || record_error "Folder $f ist nicht im Backup-Lauf"
  done
fi
[ -s "$SEL" ] || { log "[FEHLER] - keine Dateien ausgewaehlt"; exit 2; }
log "[INFO] - $(wc -l < "$SEL" | tr -d ' ') Datei(en) in $(cut -d'|' -f2 "$SEL" | sort -u | wc -l | tr -d ' ') Folder(n) ausgewaehlt$([ ${#RUNS[@]} -gt 1 ] && echo ", davon $(grep -vc '^0|' "$SEL") aus inkrementellen Laeufen")"

### ---------------------------------------------------------------- Dateien bereitstellen und pruefen
# Folder eines Laufs bereitstellen: Verzeichnis direkt, Archiv (.tar.gz/.zip) ins Arbeitsverzeichnis auspacken
declare -A PBASE=()
prepare_folder() {  # $1=laufindex $2=sicherer Foldername -> Basisverzeichnis in PBASE
  local k="$1|$2" run="${RUNS[$1]}" x="$WORKDIR/extract/$1"
  [ -n "${PBASE[$k]:-}" ] && { [ "${PBASE[$k]}" != "FEHLT" ]; return; }
  if [ -d "$run/$2" ]; then PBASE[$k]="$run"
  elif [ -f "$run/$2.tar.gz" ] && mkdir -p "$x" && tar xzf "$run/$2.tar.gz" -C "$x" 2>> "$WORKDIR/log/extract.txt"; then PBASE[$k]="$x"
  elif [ -f "$run/$2.zip" ] && command -v unzip >/dev/null 2>&1 && mkdir -p "$x" && unzip -qo "$run/$2.zip" -d "$x" 2>> "$WORKDIR/log/extract.txt"; then PBASE[$k]="$x"
  else PBASE[$k]="FEHLT"; return 1
  fi
}

xml_esc()  { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/"/\&quot;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
sed_repl() { printf '%s' "$1" | sed -e 's/[\\|&]/\\&/g'; }   # fuer die Ersetzung in sed "s|...|...|"

# Control-Files zusammenfuehren: FOLDERMAP- und SPECIFICOBJECT-Zeilen aus $1 in $2 ergaenzen -> stdout
merge_ctrl() {  # $1=zusatz $2=basis
  awk 'NR==FNR { if ($0 ~ /<FOLDERMAP /) fm[++a]=$0; else if ($0 ~ /<SPECIFICOBJECT /) so[++b]=$0; next }
       { base[++m]=$0; seen[$0]=1 }
       END { for (i=1;i<=m;i++) { l=base[i]
               if (l ~ /<RESOLVECONFLICT>/) for (j=1;j<=a;j++) if (!(fm[j] in seen)) { print fm[j]; seen[fm[j]]=1 }
               if (l ~ /<TYPEOBJECT /)      for (j=1;j<=b;j++) if (!(so[j] in seen)) { print so[j]; seen[so[j]]=1 }
               print l } }' "$1" "$2"
}

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
declare -A CTRL_SRC=() FOLDER_SHARED=()
while IFS='|' read -r IX F REL CTRL; do
  SF="${REL%%/*}"; RUNI="${RUNS[$IX]}"
  if ! prepare_folder "$IX" "$SF"; then record_error "$F: weder Verzeichnis noch Archiv $SF.tar.gz/.zip in $(basename "$RUNI")"; continue; fi
  SRCB="${PBASE[$IX|$SF]}"
  mkdir -p "$(dirname "$WORKDIR/src/$REL")"
  cp "$SRCB/$REL" "$WORKDIR/src/$REL" 2>/dev/null || { record_error "$F: $REL fehlt in $(basename "$RUNI")"; continue; }
  if [ $VERIFY -eq 1 ]; then
    EXP=$(awk -F';' -v d="$REL" '$4==d {print $6; exit}' "$RUNI/manifest.csv")
    if [ -n "$EXP" ] && [ "$EXP" != "-" ] && [ "$(checksum "$WORKDIR/src/$REL")" != "$EXP" ]; then
      record_error "$F: $REL - Pruefsumme stimmt nicht mit manifest.csv ($(basename "$RUNI")) ueberein, wird nicht importiert"; continue
    fi
  fi
  # Control-File-Quellen je Folder sammeln (alle beteiligten Laeufe)
  case " ${CTRL_SRC[$CTRL]:-} " in *" $SRCB/$CTRL "*) ;; *) CTRL_SRC[$CTRL]="${CTRL_SRC[$CTRL]:-} $SRCB/$CTRL" ;; esac
  if [ -z "${FOLDER_SHARED[$F]:-}" ]; then
    grep -q '<FOLDER [^>]*SHARED *= *"SHARED"' "$WORKDIR/src/$REL" && FOLDER_SHARED[$F]=1 || FOLDER_SHARED[$F]=0
  fi
  echo "$F|$REL|$CTRL|$IX" >> "$ITEMS"
done < "$SEL"

# Control-Files: erstes als Basis, die weiteren zusammenfuehren, dann anpassen
declare -A CTRL_BAD=()
for CTRL in "${!CTRL_SRC[@]}"; do
  read -ra SRCS <<< "${CTRL_SRC[$CTRL]}"
  DST="$WORKDIR/src/$CTRL"; mkdir -p "$(dirname "$DST")"
  if ! cp "${SRCS[0]}" "$DST" 2>/dev/null; then record_error "Control-File $CTRL fehlt"; CTRL_BAD[$CTRL]=1; continue; fi
  for ((k=1; k<${#SRCS[@]}; k++)); do
    [ -f "${SRCS[$k]}" ] && merge_ctrl "${SRCS[$k]}" "$DST" > "$DST.tmp" && mv "$DST.tmp" "$DST"
  done
  prepare_ctrl "$DST"
done
if [ ${#CTRL_BAD[@]} -gt 0 ]; then
  awk -F'|' 'NR==FNR { bad[$0]=1; next } !($3 in bad)' <(printf '%s\n' "${!CTRL_BAD[@]}") "$ITEMS" > "$ITEMS.tmp" && mv "$ITEMS.tmp" "$ITEMS"
fi

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
  while IFS='|' read -r F REL CTRL _; do
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
while IFS='|' read -r F REL CTRL IX; do
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
  awk -F';' -v d="$REL" '$4==d {print $1 "|" $2 "|" $3 "|" d; exit}' "${RUNS[$IX]}/manifest.csv" >> "$VALIDATE_LIST"
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
