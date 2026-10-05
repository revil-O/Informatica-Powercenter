#!/bin/bash
### folder_backup.sh
### Folderweises Backup eines PowerCenter-Repositorys mit pmrep:
### erst die Shared Folder, danach alle anderen; je Folder ein XML pro Objekt,
### gruppiert nach Objekttyp in Import-Reihenfolge (oder ein XML pro Workflow).
### Jede Datei wird geprueft, alles landet im Manifest (mit Pruefsumme),
### fuer den Restore entstehen import_order.txt und je Folder ein Control-File.
###
### Exitcodes: 0 = OK, 1 = teilweise fehlerhaft (PARTIAL), 2 = Abbruch (FAILED)
### Aufruf aus einem Workflow: Command Task, siehe docs/FOLDER_BACKUP.md

set -u
umask 027

usage() {
cat <<'EOF'
Aufruf:
  folder_backup.sh [-c CONFIG] -r REPO -d DOMAIN -n USER [Optionen]

Verbindung:
  -r REPO             Repository-Name
  -d DOMAIN           Domain-Name
  -n USER             Repository-User
  -s SECDOMAIN        Security Domain (LDAP), falls benoetigt
  -X VAR              Umgebungsvariable mit dem pmpasswd-verschluesselten Passwort
                      (Standard: INFA_PASSWORD). Ist sie leer, wird interaktiv gefragt.
  -P PFAD             Pfad zu pmrep (Standard: PATH bzw. $INFA_HOME/server/bin)

Umfang:
  -F A,B              nur diese Folder (Standard: alle)
  -S A,B              Shared Folder - werden zuerst gesichert (Standard: automatisch erkannt)
  -E REGEX            Folder ausschliessen (erweiterter Regex, z.B. '^(TMP|TEST)_')
  -t TYP,TYP          Objekttypen (Standard: source,target,User Defined Function,transformation,
                      mapplet,mapping,sessionconfig,session,worklet,workflow)
  -m MODUS            objects   = ein XML pro Objekt, nach Typ gruppiert (Standard)
                      workflows = ein selbststaendiges XML pro Workflow
  --deps full|none    full = mit Abhaengigkeiten (-m -s -b -r), jede Datei einzeln importierbar (Standard)
                      none = nur das Objekt (kleiner, Import nur vollstaendig in Reihenfolge)

Ablage und Betrieb:
  -b VERZ             Backup-Basisverzeichnis (Standard: ./infa_backup)
  -c DATEI            Konfigurationsdatei (KEY=VALUE, siehe folder_backup.conf.example)
  --retries N         Wiederholungen je pmrep-Aufruf mit Neuverbindung (Standard: 2)
  --keep N            nur die N neuesten erfolgreichen Backups behalten (Standard: 0 = alle)
  --min-free-mb N     Mindest-Speicherplatz, sonst Abbruch (Standard: 500)
  --max-errors N      Abbruch ab N Fehlern (Standard: 0 = nie)
  --fail-fast         beim ersten Fehler abbrechen
  --partial-ok        Exitcode 0 auch bei einzelnen Fehlern (Status bleibt PARTIAL)
  --zip               jeden Folder nach erfolgreicher Pruefung als .tar.gz packen
  --list              Trockenlauf: nur Folder und Objektanzahl auflisten, nichts exportieren
  -h | --help         diese Hilfe

Versionierung mit Git (optional):
  --git VERZ          Exporte zusaetzlich in dieses Git-Repository uebernehmen und committen
                      (wird bei Bedarf angelegt; Zeitstempel im XML-Kopf werden neutralisiert)
  --git-author "Name <mail>"  Autor der Commits (Standard: git-Konfiguration)
  --git-push          nach dem Commit pushen (Remote muss eingerichtet sein)
EOF
}

### ---------------------------------------------------------------- Parameter
REPO=""; DOMAIN=""; REPUSER=""; SECDOMAIN=""; PASSVAR="INFA_PASSWORD"; PMREP=""
FOLDERS=""; SHARED=""; EXCLUDE=""; MODE="objects"; DEPS="full"
TYPES="source,target,User Defined Function,transformation,mapplet,mapping,sessionconfig,session,worklet,workflow"
BASEDIR="./infa_backup"; RETRIES=2; KEEP=0; MIN_FREE_MB=500; MAX_ERRORS=0
FAIL_FAST=0; PARTIAL_OK=0; ZIP=0; LIST_ONLY=0; CONFIG=""
GIT_REPO=""; GIT_AUTHOR=""; GIT_PUSH=0

# Konfigurationsdatei: nur bekannte Schluessel, kein eval
load_config() {
  local key val
  [ -r "$1" ] || { echo "[FEHLER] - Konfigurationsdatei nicht lesbar: $1"; exit 2; }
  while IFS='=' read -r key val; do
    key=$(printf '%s' "$key" | tr -d ' \t\r'); val=$(printf '%s' "$val" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/\r$//')
    case "$key" in
      ''|\#*) continue ;;
      REPO|DOMAIN|SECDOMAIN|PASSVAR|PMREP|FOLDERS|SHARED|EXCLUDE|MODE|DEPS|TYPES|BASEDIR|RETRIES|KEEP|MIN_FREE_MB|MAX_ERRORS|FAIL_FAST|PARTIAL_OK|ZIP|GIT_REPO|GIT_AUTHOR|GIT_PUSH)
        printf -v "$key" '%s' "$val" ;;
      USER) REPUSER="$val" ;;
      *) echo "[WARNUNG] - unbekannter Schluessel in $1: $key" ;;
    esac
  done < "$1"
}

# 1. Durchlauf: Konfigurationsdatei finden; 2. Durchlauf: Kommandozeile ueberschreibt
ARGS=("$@")
for ((i=0; i<${#ARGS[@]}; i++)); do
  [ "${ARGS[$i]}" = "-c" ] && CONFIG="${ARGS[$((i+1))]:-}"
done
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
    -F) FOLDERS="$2"; shift 2 ;;
    -S) SHARED="$2"; shift 2 ;;
    -E) EXCLUDE="$2"; shift 2 ;;
    -t) TYPES="$2"; shift 2 ;;
    -m) MODE="$2"; shift 2 ;;
    -b) BASEDIR="$2"; shift 2 ;;
    --deps) DEPS="$2"; shift 2 ;;
    --retries) RETRIES="$2"; shift 2 ;;
    --keep) KEEP="$2"; shift 2 ;;
    --min-free-mb) MIN_FREE_MB="$2"; shift 2 ;;
    --max-errors) MAX_ERRORS="$2"; shift 2 ;;
    --fail-fast) FAIL_FAST=1; shift ;;
    --partial-ok) PARTIAL_OK=1; shift ;;
    --zip) ZIP=1; shift ;;
    --git) GIT_REPO="$2"; shift 2 ;;
    --git-author) GIT_AUTHOR="$2"; shift 2 ;;
    --git-push) GIT_PUSH=1; shift ;;
    --list) LIST_ONLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "[FEHLER] - unbekannte Option: $1"; usage; exit 2 ;;
  esac
done

fatal_usage() { echo "[FEHLER] - $1"; exit 2; }
[ -n "$REPO" ] && [ -n "$DOMAIN" ] && [ -n "$REPUSER" ] || { usage; exit 2; }
case "$MODE" in objects|workflows) ;; *) fatal_usage "Modus muss objects oder workflows sein" ;; esac
case "$DEPS" in full|none) ;; *) fatal_usage "--deps muss full oder none sein" ;; esac
for n in RETRIES KEEP MIN_FREE_MB MAX_ERRORS FAIL_FAST PARTIAL_OK ZIP GIT_PUSH; do
  [[ "${!n}" =~ ^[0-9]+$ ]] || fatal_usage "$n muss eine Zahl sein: ${!n}"
done
[ "$MODE" = "workflows" ] && { TYPES="workflow"; DEPS="full"; }

if [ -z "$PMREP" ]; then
  if command -v pmrep >/dev/null 2>&1; then PMREP="pmrep"
  elif [ -n "${INFA_HOME:-}" ] && [ -x "${INFA_HOME}/server/bin/pmrep" ]; then PMREP="${INFA_HOME}/server/bin/pmrep"
  else fatal_usage "pmrep nicht gefunden (-P oder PATH/INFA_HOME setzen)"
  fi
fi

### ---------------------------------------------------------------- Laufverzeichnis, Sperre, Log
mkdir -p "$BASEDIR" || fatal_usage "Basisverzeichnis nicht anlegbar: $BASEDIR"
BASEDIR=$(cd "$BASEDIR" && pwd)
LOCK="$BASEDIR/.folder_backup.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  OLDPID=$(cat "$LOCK/pid" 2>/dev/null)
  if [ -n "$OLDPID" ] && kill -0 "$OLDPID" 2>/dev/null; then
    echo "[FEHLER] - es laeuft bereits ein Backup (PID $OLDPID, Sperre $LOCK)"; exit 2
  fi
  echo "[WARNUNG] - verwaiste Sperre von PID ${OLDPID:-?} entfernt"
  rm -rf "$LOCK"; mkdir "$LOCK" || fatal_usage "Sperre nicht anlegbar: $LOCK"
fi
echo $$ > "$LOCK/pid"

STAMP=$(date +%Y%m%d_%H%M%S)
RUNDIR="$BASEDIR/$(printf '%s' "$REPO" | tr -c 'A-Za-z0-9_.\n-' '_')_$STAMP"
[ $LIST_ONLY -eq 1 ] && RUNDIR="$BASEDIR/list_$STAMP"
# eindeutig machen (zwei Laeufe in derselben Sekunde)
n=1; BASE_RUNDIR="$RUNDIR"
while [ -e "$RUNDIR" ]; do n=$((n+1)); RUNDIR="${BASE_RUNDIR}_$n"; done
mkdir -p "$RUNDIR/log" || { rm -rf "$LOCK"; fatal_usage "Laufverzeichnis nicht anlegbar: $RUNDIR"; }
LOG="$RUNDIR/backup.log"
MANIFEST="$RUNDIR/manifest.csv"
ORDER="$RUNDIR/import_order.txt"
export INFA_REPCNX_INFO="$RUNDIR/pmrep.cnx"   # eigene Verbindungsdatei, keine Konflikte mit anderen pmrep-Laeufen
STATUS="RUNNING"; touch "$RUNDIR/RUNNING"
ERRORS=0; WARNINGS=0; N_OBJ=0; N_OK=0

log()  { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG"; }
warn() { WARNINGS=$((WARNINGS+1)); log "[WARNUNG] - $*"; }
safe() { printf '%s\n' "$1" | tr -c 'A-Za-z0-9_.\n-' '_'; }
get_attr() { printf '%s\n' "$1" | sed -n "s/.*[[:space:]]$2[[:space:]]*=[[:space:]]*\"\([^\"]*\)\".*/\1/p"; }
xml_esc() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/"/\&quot;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

finish() {  # $1 = Status (SUCCESS|PARTIAL|FAILED)
  STATUS="$1"
  rm -f "$RUNDIR/RUNNING" "$INFA_REPCNX_INFO"
  {
    echo "status=$STATUS"; echo "repository=$REPO"; echo "start=$STAMP"; echo "ende=$(date +%Y%m%d_%H%M%S)"
    echo "objekte=$N_OBJ"; echo "ok=$N_OK"; echo "fehler=$ERRORS"; echo "warnungen=$WARNINGS"
  } > "$RUNDIR/$STATUS"
  rm -rf "$LOCK"
}
on_signal() { log "[ABBRUCH] - Signal empfangen"; finish FAILED; exit 2; }
trap on_signal INT TERM
trap 'rm -rf "$LOCK"; rm -f "$INFA_REPCNX_INFO"' EXIT

### ---------------------------------------------------------------- pmrep-Aufrufe mit Fehlerbehandlung
PW_PLAIN=""
connect() {
  local args=(connect -r "$REPO" -d "$DOMAIN" -n "$REPUSER")
  [ -n "$SECDOMAIN" ] && args+=(-s "$SECDOMAIN")
  if [ -n "${!PASSVAR:-}" ]; then
    args+=(-X "$PASSVAR")                # verschluesseltes Passwort (pmpasswd) aus der Umgebung
  elif [ -n "$PW_PLAIN" ]; then
    args+=(-x "$PW_PLAIN")
  else
    return 1
  fi
  "$PMREP" "${args[@]}" > "$RUNDIR/log/connect.txt" 2>&1
}

# run_pmrep AUSGABEDATEI pmrep-Argumente...  -> Wiederholung mit Neuverbindung
run_pmrep() {
  local out="$1"; shift
  local try=0 rc
  while :; do
    "$PMREP" "$@" > "$out" 2>&1; rc=$?
    [ $rc -eq 0 ] && return 0
    [ $try -ge "$RETRIES" ] && return $rc
    try=$((try+1))
    sleep $((5 * try))
    connect || true
  done
}

check_space() {
  local free
  free=$(df -Pk "$RUNDIR" 2>/dev/null | awk 'NR==2 {print int($4/1024)}')
  [ -z "$free" ] && return 0
  if [ "$free" -lt "$MIN_FREE_MB" ]; then
    log "[FEHLER] - nur noch ${free} MB frei (Minimum $MIN_FREE_MB MB)"; return 1
  fi
}

checksum() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  elif command -v openssl >/dev/null 2>&1; then openssl dgst -sha256 "$1" | sed 's/.*= //'
  else echo "-"
  fi
}

# Zeilen der pmrep-Ausgabe, die keine Daten sind
is_noise() {
  [[ "$1" =~ ^(Informatica|Copyright|This\ Software|Invoked\ at|Completed\ at|\.?[A-Za-z]+\ completed\ successfully|Connected\ to|@@END@@) ]] || [ -z "$1" ]
}

### ---------------------------------------------------------------- Listen
list_folders() {  # -> Foldernamen auf stdout
  local raw="$RUNDIR/log/list_folders.txt" line
  run_pmrep "$raw" listobjects -o folder || return 1
  while IFS= read -r line; do
    line="${line%$'\r'}"; line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
    is_noise "$line" || printf '%s\n' "$line"
  done < "$raw"
}

list_objects() {  # $1=typ $2=folder -> "name|subtyp" (nur wiederverwendbare Objekte)
  local raw; raw="$RUNDIR/log/list_$(safe "$2")_$(safe "$1").txt"
  run_pmrep "$raw" listobjects -o "$1" -f "$2" -c "|" || return 1
  local parsed data line
  parsed=$(parse_objects "$1" "$raw")
  # Datenzeilen vorhanden, aber nichts erkannt -> Ausgabeformat unbekannt (sonst wuerde still nichts gesichert)
  data=0
  while IFS= read -r line; do
    line="${line%$'\r'}"; line="${line#"${line%%[![:space:]]*}"}"
    is_noise "$line" || data=$((data+1))
  done < "$raw"
  if [ -z "$parsed" ] && [ "$data" -gt 0 ]; then
    echo "$2: listobjects -o $1 liefert $data Zeile(n) in unbekanntem Format, siehe ${raw#"$RUNDIR"/}" >> "$RUNDIR/log/format_warnings.txt"
  fi
  [ -n "$parsed" ] && printf '%s\n' "$parsed"
  return 0
}

parse_objects() {  # $1=typ $2=rohdatei -> "name|subtyp"
  awk -F'|' -v t="$(printf '%s' "$1" | tr 'A-Z' 'a-z')" '
    { c1=tolower($1); gsub(/^[ \t]+|[ \t\r]+$/,"",c1) }
    c1==t {
      name=""; sub_t=""; nonreuse=0
      for (i=2;i<=NF;i++) {
        v=$i; gsub(/^[ \t]+|[ \t\r]+$/,"",v)
        if (v=="non-reusable") { nonreuse=1; continue }
        if (v=="" || v=="reusable") continue
        if (name=="") name=v; else if (sub_t=="") sub_t=v
      }
      # bei Transformationen und Tasks steht der Subtyp vor dem Namen
      if ((t=="transformation" || t=="task") && sub_t!="") { tmp=name; name=sub_t; sub_t=tmp }
      if (!nonreuse && name!="") print name "|" sub_t
    }' "$2"
}

### ---------------------------------------------------------------- Export und Pruefung
type_index() {  # Import-Reihenfolge der Typen
  case "$(printf '%s' "$1" | tr 'A-Z' 'a-z')" in
    source) echo 01 ;; target) echo 02 ;; "user defined function") echo 03 ;; transformation) echo 04 ;;
    mapplet) echo 05 ;; mapping) echo 06 ;; sessionconfig) echo 07 ;; task) echo 08 ;;
    session) echo 09 ;; worklet) echo 10 ;; workflow) echo 11 ;; *) echo 50 ;;
  esac
}

# prueft eine Export-Datei: vorhanden, nicht leer, vollstaendig, enthaelt das Objekt
verify_xml() {  # $1=datei $2=objektname (ohne DBD) -> 0 oder Fehlertext auf stdout
  [ -s "$1" ] || { echo "Datei fehlt oder leer"; return 1; }
  tail -c 200 "$1" | grep -q '</POWERMART>' || { echo "XML unvollstaendig (kein </POWERMART>)"; return 1; }
  grep -qF "NAME =\"$2\"" "$1" || grep -qF "NAME=\"$2\"" "$1" || { echo "Objekt $2 nicht im XML"; return 1; }
  if command -v xmllint >/dev/null 2>&1; then
    xmllint --noout --nonet "$1" >/dev/null 2>&1 || { echo "XML nicht wohlgeformt (xmllint)"; return 1; }
  fi
  return 0
}

record_error() {  # $1=text
  ERRORS=$((ERRORS+1)); log "[FEHLER] - $1"
  if [ "$FAIL_FAST" -eq 1 ] || { [ "$MAX_ERRORS" -gt 0 ] && [ "$ERRORS" -ge "$MAX_ERRORS" ]; }; then
    log "[ABBRUCH] - Fehlergrenze erreicht ($ERRORS)"; finish FAILED; exit 2
  fi
}

DEPFLAGS=(); [ "$DEPS" = "full" ] && DEPFLAGS=(-m -s -b -r)

### ---------------------------------------------------------------- Git-Versionierung
# Ablage im Git-Repository: <GIT_REPO>/<REPO>/<folder>/<NN_typ>/<objekt>.xml (ohne Zeitstempel)
GIT_BASE=""
declare -A LIST_FAILED=()
git_run() {  # git mit optionalem Autor
  if [ -n "$GIT_AUTHOR" ]; then
    local name="${GIT_AUTHOR%%<*}" mail="${GIT_AUTHOR#*<}"
    name="${name%"${name##*[![:space:]]}"}"; mail="${mail%>*}"
    git -C "$GIT_REPO" -c user.name="$name" -c user.email="$mail" "$@"
  else
    git -C "$GIT_REPO" "$@"
  fi
}

git_prepare() {
  command -v git >/dev/null 2>&1 || { record_error "Git: git nicht gefunden - Versionierung deaktiviert"; GIT_REPO=""; return 1; }
  mkdir -p "$GIT_REPO" || { record_error "Git: Verzeichnis $GIT_REPO nicht anlegbar"; GIT_REPO=""; return 1; }
  GIT_REPO=$(cd "$GIT_REPO" && pwd)
  if [ ! -d "$GIT_REPO/.git" ]; then
    git -C "$GIT_REPO" init -q > "$RUNDIR/log/git.txt" 2>&1 || { record_error "Git: init fehlgeschlagen, siehe log/git.txt"; GIT_REPO=""; return 1; }
    printf '# Informatica-Exporte: keine Zeilenende-Konvertierung, Diff als Text\n*.xml -text diff\n' > "$GIT_REPO/.gitattributes"
    log "[GIT] - neues Repository angelegt: $GIT_REPO"
  elif [ -n "$(git -C "$GIT_REPO" status --porcelain 2>/dev/null)" ]; then
    warn "Git: Arbeitsverzeichnis $GIT_REPO hat uncommittete Aenderungen - sie werden mit committet"
  fi
  GIT_BASE="$GIT_REPO/$(safe "$REPO")"
  mkdir -p "$GIT_BASE"
}

# XML ohne wechselnden Zeitstempel (CREATION_DATE im POWERMART-Kopf) ins Git-Verzeichnis kopieren
git_copy() {  # $1=quelle $2=ziel
  mkdir -p "$(dirname "$2")"
  LC_ALL=C sed 's|\(<POWERMART[^>]*CREATION_DATE *= *"\)[^"]*"|\101/01/1970 00:00:00"|' "$1" > "$2"
}

# einen Folder ins Git-Verzeichnis spiegeln; fehlgeschlagene Exporte behalten ihre letzte Version
git_sync_folder() {  # $1=folder
  local sf g rel p
  sf=$(safe "$1"); g="$GIT_BASE/$sf"
  local okl="$RUNDIR/log/git_ok_$sf.txt" keep="$RUNDIR/log/git_keep_$sf.txt"
  awk -F';' -v f="$1" '$1==f && $7=="OK" {print $4}' "$MANIFEST" > "$okl"
  awk -F';' -v f="$1" '$1==f && $7=="FEHLER" {sub(/\.failed$/,"",$4); print $4}' "$MANIFEST" > "$keep"
  mkdir -p "$g"
  while IFS= read -r rel; do git_copy "$RUNDIR/$rel" "$GIT_BASE/$rel"; done < "$okl"
  [ -f "$RUNDIR/$sf/import_ctrl.xml" ] && cp "$RUNDIR/$sf/import_ctrl.xml" "$g/import_ctrl.xml"
  # nicht mehr vorhandene Objekte entfernen - nur wenn alle Objektlisten des Folders lesbar waren
  if [ -n "${LIST_FAILED[$1]:-}" ]; then
    warn "Git: $1 - Objektliste unvollstaendig, geloeschte Objekte werden nicht entfernt"
    return 0
  fi
  [ -d "$g" ] || return 0
  find "$g" -type f -name '*.xml' ! -name import_ctrl.xml | while IFS= read -r p; do
    rel="${p#"$GIT_BASE"/}"
    grep -qxF "$rel" "$okl" || grep -qxF "$rel" "$keep" || rm -f "$p"
  done
  find "$g" -mindepth 1 -type d -empty -delete 2>/dev/null
}

git_commit() {  # $1=status
  local stat add mod del
  # Folder, die es im Repository nicht mehr gibt (nur bei Sicherung aller Folder)
  if [ -z "$FOLDERS" ] && [ ${#ORDERED[@]} -gt 0 ]; then
    local d name keep_it f
    for d in "$GIT_BASE"/*/; do
      [ -d "$d" ] || continue
      name=$(basename "$d"); keep_it=0
      for f in "${ORDERED[@]}"; do [ "$(safe "$f")" = "$name" ] && keep_it=1; done
      [ -n "$EXCLUDE" ] && printf '%s\n' "$name" | grep -qE "$EXCLUDE" && keep_it=1
      [ $keep_it -eq 0 ] && { rm -rf "$d"; log "[GIT] - Folder $name existiert nicht mehr - aus Git entfernt"; }
    done
  fi
  git_run add -A -- . > "$RUNDIR/log/git.txt" 2>&1 || { record_error "Git: add fehlgeschlagen, siehe log/git.txt"; return 1; }
  stat=$(git -C "$GIT_REPO" diff --cached --no-renames --name-status 2>/dev/null)
  if [ -z "$stat" ]; then log "[GIT] - keine Aenderungen gegenueber dem letzten Backup"; return 0; fi
  add=$(printf '%s\n' "$stat" | grep -c '^A'); mod=$(printf '%s\n' "$stat" | grep -c '^M'); del=$(printf '%s\n' "$stat" | grep -c '^D')
  if ! git_run commit -q -m "Backup $REPO $STAMP ($1): $add neu, $mod geaendert, $del geloescht" \
         -m "Lauf: $(basename "$RUNDIR")" >> "$RUNDIR/log/git.txt" 2>&1; then
    record_error "Git: commit fehlgeschlagen (Autor konfiguriert? --git-author), siehe log/git.txt"; return 1
  fi
  log "[GIT] - Commit $(git -C "$GIT_REPO" rev-parse --short HEAD): $add neu, $mod geaendert, $del geloescht"
  printf '%s\n' "$stat" > "$RUNDIR/git_changes.txt"
  if [ "$GIT_PUSH" -eq 1 ]; then
    if git -C "$GIT_REPO" push -q >> "$RUNDIR/log/git.txt" 2>&1; then log "[GIT] - gepusht"
    else record_error "Git: push fehlgeschlagen, siehe log/git.txt"; fi
  fi
}

### ---------------------------------------------------------------- Start
log "[FOLDER_BACKUP] - Repository=$REPO Modus=$MODE Abhaengigkeiten=$DEPS Ziel=$RUNDIR"
[ $LIST_ONLY -eq 1 ] && log "[INFO] - Trockenlauf (--list): es wird nichts exportiert"
echo "folder;typ;name;datei;bytes;sha256;status;meldung" > "$MANIFEST"

if [ -z "${!PASSVAR:-}" ]; then
  if [ -t 0 ]; then
    printf 'Passwort fuer %s: ' "$REPUSER"; stty -echo 2>/dev/null; read -r PW_PLAIN; stty echo 2>/dev/null; echo
  else
    log "[FEHLER] - kein Passwort: Umgebungsvariable $PASSVAR (pmpasswd-verschluesselt) setzen"; finish FAILED; exit 2
  fi
fi
if ! connect; then
  log "[FEHLER] - Verbindung zu $REPO fehlgeschlagen, siehe $RUNDIR/log/connect.txt"
  grep -qi 'password\|passwort\|decrypt' "$RUNDIR/log/connect.txt" && \
    log "[HINWEIS] - $PASSVAR muss das mit pmpasswd verschluesselte Passwort enthalten (pmpasswd <passwort>)"
  finish FAILED; exit 2
fi
log "[STATUS] - verbunden mit $REPO"
check_space || { finish FAILED; exit 2; }
[ -n "$GIT_REPO" ] && [ $LIST_ONLY -eq 0 ] && git_prepare

### ---------------------------------------------------------------- Folder ermitteln und ordnen
ALL_FOLDERS=$(list_folders) || { log "[FEHLER] - Folderliste nicht lesbar, siehe log/list_folders.txt"; finish FAILED; exit 2; }
[ -n "$ALL_FOLDERS" ] || { log "[FEHLER] - keine Folder gefunden"; finish FAILED; exit 2; }

declare -A WANT=() IS_SHARED=()
if [ -n "$FOLDERS" ]; then
  IFS=',' read -ra _F <<< "$FOLDERS"
  for f in "${_F[@]}"; do
    f="${f#"${f%%[![:space:]]*}"}"; f="${f%"${f##*[![:space:]]}"}"
    if printf '%s\n' "$ALL_FOLDERS" | grep -qxF "$f"; then WANT[$f]=1; else record_error "Folder $f existiert nicht"; fi
  done
else
  while IFS= read -r f; do WANT[$f]=1; done <<< "$ALL_FOLDERS"
fi
if [ -n "$EXCLUDE" ]; then
  for f in "${!WANT[@]}"; do printf '%s\n' "$f" | grep -qE "$EXCLUDE" && unset "WANT[$f]"; done
fi

# Shared Folder: aus -S, sonst automatisch per Probe-Export (Attribut SHARED im FOLDER-Element)
detect_shared() {  # $1=folder -> 0 wenn shared
  local t n probe rc; probe="$RUNDIR/log/probe_$(safe "$1").xml"
  for t in source target transformation mapplet mapping workflow; do
    n=$(list_objects "$t" "$1" 2>/dev/null | head -1 | cut -d'|' -f1)
    [ -z "$n" ] && continue
    run_pmrep "$RUNDIR/log/probe_$(safe "$1").txt" objectexport -o "$t" -n "$n" -f "$1" -u "$probe" || return 1
    grep -q '<FOLDER [^>]*SHARED *= *"SHARED"' "$probe"; rc=$?; rm -f "$probe"; return $rc
  done
  return 1
}
if [ -n "$SHARED" ]; then
  IFS=',' read -ra _S <<< "$SHARED"
  for f in "${_S[@]}"; do
    f="${f#"${f%%[![:space:]]*}"}"; f="${f%"${f##*[![:space:]]}"}"
    [ -n "${WANT[$f]:-}" ] && IS_SHARED[$f]=1 || warn "Shared Folder $f nicht im Backup-Umfang"
  done
else
  for f in "${!WANT[@]}"; do detect_shared "$f" && IS_SHARED[$f]=1; done
fi

ORDERED=()
while IFS= read -r f; do [ -n "${IS_SHARED[$f]:-}" ] && ORDERED+=("$f"); done < <(printf '%s\n' "${!WANT[@]}" | sort)
while IFS= read -r f; do [ -z "${IS_SHARED[$f]:-}" ] && [ -n "$f" ] && ORDERED+=("$f"); done < <(printf '%s\n' "${!WANT[@]}" | sort)
log "[INFO] - ${#ORDERED[@]} Folder, davon ${#IS_SHARED[@]} shared: ${!IS_SHARED[*]}"

IFS=',' read -ra TYPELIST <<< "$TYPES"

### ---------------------------------------------------------------- Trockenlauf
if [ $LIST_ONLY -eq 1 ]; then
  for f in "${ORDERED[@]}"; do
    line="$f$([ -n "${IS_SHARED[$f]:-}" ] && echo ' (shared)'):"
    for t in "${TYPELIST[@]}"; do
      cnt=$(list_objects "$t" "$f" 2>/dev/null | grep -c .)
      line="$line $t=$cnt"
    done
    log "[LISTE] - $line"
  done
  finish SUCCESS; exit 0
fi

### ---------------------------------------------------------------- Backup je Folder
: > "$ORDER"
for f in "${ORDERED[@]}"; do
  check_space || { finish FAILED; exit 2; }
  FDIR="$RUNDIR/$(safe "$f")"; mkdir -p "$FDIR"
  f_err=$ERRORS; f_cnt=0
  log "[FOLDER] - $f$([ -n "${IS_SHARED[$f]:-}" ] && echo ' (shared)')"

  for t in "${TYPELIST[@]}"; do
    t="${t#"${t%%[![:space:]]*}"}"; t="${t%"${t##*[![:space:]]}"}"
    OBJS=$(list_objects "$t" "$f") || { LIST_FAILED[$f]=1; record_error "$f: listobjects fuer Typ $t fehlgeschlagen"; continue; }
    [ -z "$OBJS" ] && continue
    TDIR="$FDIR/$(type_index "$t")_$(safe "$(printf '%s' "$t" | tr 'A-Z ' 'a-z_')")"; mkdir -p "$TDIR"
    while IFS='|' read -r NAME SUB; do
      [ -z "$NAME" ] && continue
      N_OBJ=$((N_OBJ+1)); f_cnt=$((f_cnt+1))
      XML="$TDIR/$(safe "$NAME").xml"; REL="${XML#"$RUNDIR"/}"
      ARGS=(objectexport -o "$t" -n "$NAME" -f "$f" "${DEPFLAGS[@]}" -u "$XML")
      [ -n "$SUB" ] && ARGS+=(-t "$SUB")
      SN="$NAME"; [ "$(printf '%s' "$t" | tr 'A-Z' 'a-z')" = "source" ] && SN="${NAME#*.}"
      if ! run_pmrep "$RUNDIR/log/export_$(safe "$f")_$(safe "$t")_$(safe "$NAME").txt" "${ARGS[@]}"; then
        MSG=$(grep -iE 'error|fail|not found' "$RUNDIR/log/export_$(safe "$f")_$(safe "$t")_$(safe "$NAME").txt" | head -1 | tr ';' ',')
        [ -f "$XML" ] && mv -f "$XML" "$XML.failed"   # unvollstaendige Datei nie als gueltig liegen lassen
        echo "$f;$t;$NAME;$REL.failed;0;-;FEHLER;${MSG:-pmrep objectexport fehlgeschlagen}" >> "$MANIFEST"
        record_error "$f: $t $NAME - Export fehlgeschlagen"
        continue
      fi
      if ! VMSG=$(verify_xml "$XML" "$SN"); then
        BYTES=$(wc -c < "$XML" 2>/dev/null | tr -d ' '); [ -f "$XML" ] && mv -f "$XML" "$XML.failed"
        echo "$f;$t;$NAME;$REL.failed;${BYTES:-0};-;FEHLER;$VMSG" >> "$MANIFEST"
        record_error "$f: $t $NAME - $VMSG"
        continue
      fi
      echo "$f;$t;$NAME;$REL;$(wc -c < "$XML" | tr -d ' ');$(checksum "$XML");OK;" >> "$MANIFEST"
      echo "$f|$REL|$(safe "$f")/import_ctrl.xml" >> "$ORDER"
      N_OK=$((N_OK+1))
    done <<< "$OBJS"
  done

  # Shared-Status aus den Exporten bestaetigen
  FIRST=$(find "$FDIR" -name '*.xml' -type f 2>/dev/null | head -1)
  if [ -n "$FIRST" ] && grep -q '<FOLDER [^>]*SHARED *= *"SHARED"' "$FIRST" && [ -z "${IS_SHARED[$f]:-}" ]; then
    warn "$f ist ein Shared Folder, wurde aber nicht zuerst gesichert - im Restore zuerst importieren (-S angeben)"
    IS_SHARED[$f]=1
  fi

  # Control-File fuer den Restore: Folder + referenzierte Shared Folder, Shortcuts wiederverwenden
  SRCREPO=$( [ -n "$FIRST" ] && grep -o '<REPOSITORY NAME *= *"[^"]*"' "$FIRST" | head -1 | sed 's/.*"\(.*\)"/\1/' )
  SRCREPO="${SRCREPO:-$REPO}"
  SC=$(find "$FDIR" -name '*.xml' -type f -exec cat {} + 2>/dev/null | tr '\r\n' '  ' | sed 's/</\n</g' | grep '^<SHORTCUT[[:space:]]')
  {
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo '<!DOCTYPE IMPORTPARAMS SYSTEM "impcntl.dtd">'
    echo "<!-- Restore von Folder $(xml_esc "$f"); TARGETREPOSITORYNAME bei Import in ein anderes Repository anpassen -->"
    echo '<IMPORTPARAMS CHECKIN_AFTER_IMPORT="NO" RETAIN_GENERATED_VALUE="YES">'
    { echo "$f"; printf '%s\n' "$SC" | while IFS= read -r L; do [ -n "$L" ] && get_attr "$L" FOLDERNAME; done; } | grep -v '^$' | sort -u |
      while IFS= read -r MF; do
        echo "  <FOLDERMAP SOURCEFOLDERNAME=\"$(xml_esc "$MF")\" SOURCEREPOSITORYNAME=\"$(xml_esc "$SRCREPO")\" TARGETFOLDERNAME=\"$(xml_esc "$MF")\" TARGETREPOSITORYNAME=\"$(xml_esc "$REPO")\"/>"
      done
    echo '  <RESOLVECONFLICT>'
    # Shortcuts nie ersetzen (REPLACE erzeugt bei Shortcuts Duplikate mit Zahlen-Suffix)
    printf '%s\n' "$SC" | while IFS= read -r L; do
      [ -z "$L" ] && continue
      N=$(get_attr "$L" NAME); OT=$(get_attr "$L" OBJECTSUBTYPE); D=$(get_attr "$L" DBDNAME)
      [ -n "$N" ] && printf '%s|%s|%s\n' "$N" "$OT" "$D"
    done | sort -u | while IFS='|' read -r N OT D; do
      DB=""; [ -n "$D" ] && DB=" DBDNAME=\"$(xml_esc "$D")\""
      echo "    <SPECIFICOBJECT NAME=\"$(xml_esc "$N")\"$DB OBJECTTYPENAME=\"$(xml_esc "$OT")\" FOLDERNAME=\"$(xml_esc "$f")\" REPOSITORYNAME=\"$(xml_esc "$SRCREPO")\" RESOLUTION=\"REUSE\"/>"
    done
    echo '    <TYPEOBJECT OBJECTTYPENAME="All" RESOLUTION="REPLACE"/>'
    echo '  </RESOLVECONFLICT>'
    echo '</IMPORTPARAMS>'
  } > "$FDIR/import_ctrl.xml"

  # ins Git-Verzeichnis spiegeln (vor dem Packen)
  [ -n "$GIT_BASE" ] && git_sync_folder "$f"

  # optional packen (nur wenn der Folder fehlerfrei war)
  if [ "$ZIP" -eq 1 ] && [ $ERRORS -eq $f_err ]; then
    if tar czf "$FDIR.tar.gz" -C "$RUNDIR" "$(basename "$FDIR")" && tar tzf "$FDIR.tar.gz" >/dev/null 2>&1; then
      rm -rf "$FDIR"
    else
      record_error "$f: Archiv $FDIR.tar.gz fehlerhaft - XML-Dateien bleiben erhalten"
    fi
  fi
  log "[FOLDER] - $f fertig: $f_cnt Objekte, $((ERRORS - f_err)) Fehler"
done

# Import-Reihenfolge: Shared Folder zuerst, innerhalb des Folders nach Typ-Praefix (01_source ... 11_workflow)
if [ -s "$ORDER" ]; then
  {
    for f in "${ORDERED[@]}"; do [ -n "${IS_SHARED[$f]:-}" ] && awk -F'|' -v f="$f" '$1==f' "$ORDER" | sort -t'|' -k2,2; done
    for f in "${ORDERED[@]}"; do [ -z "${IS_SHARED[$f]:-}" ] && awk -F'|' -v f="$f" '$1==f' "$ORDER" | sort -t'|' -k2,2; done
  } > "$ORDER.tmp" && mv "$ORDER.tmp" "$ORDER"
fi

# Formatwarnungen aus listobjects uebernehmen
if [ -s "$RUNDIR/log/format_warnings.txt" ]; then
  while IFS= read -r L; do warn "$L"; done < "$RUNDIR/log/format_warnings.txt"
fi

### ---------------------------------------------------------------- Abschluss
if [ $ERRORS -eq 0 ]; then RESULT=SUCCESS; else RESULT=PARTIAL; fi
if [ -n "$GIT_BASE" ]; then
  git_commit "$RESULT"
  if [ $ERRORS -eq 0 ]; then RESULT=SUCCESS; else RESULT=PARTIAL; fi
fi
log "[ERGEBNIS] - $RESULT: $N_OK von $N_OBJ Objekten gesichert, $ERRORS Fehler, $WARNINGS Warnungen"
log "[ERGEBNIS] - Manifest: $MANIFEST"
log "[ERGEBNIS] - Import-Reihenfolge: $ORDER"
finish "$RESULT"
[ "$RESULT" = "SUCCESS" ] && echo "$(basename "$RUNDIR")" > "$BASEDIR/LATEST_SUCCESS"

# Aufbewahrung: nur nach Erfolg; alles aelter als das N-te erfolgreiche Backup loeschen
if [ "$RESULT" = "SUCCESS" ] && [ "$KEEP" -gt 0 ]; then
  PREFIX="$(printf '%s' "$REPO" | tr -c 'A-Za-z0-9_.\n-' '_')_"
  CUT=$(find "$BASEDIR" -maxdepth 2 -path "$BASEDIR/$PREFIX*/SUCCESS" -type f 2>/dev/null | sed 's|/SUCCESS$||' | sort -r | sed -n "${KEEP}p")
  if [ -n "$CUT" ]; then
    find "$BASEDIR" -maxdepth 1 -type d -name "$PREFIX*" 2>/dev/null | sort | while IFS= read -r D; do
      [[ "$D" < "$CUT" ]] && { rm -rf "$D"; echo "$(date '+%Y-%m-%d %H:%M:%S') [AUFRAEUMEN] - $(basename "$D") geloescht" >> "$LOG"; }
    done
  fi
fi

if [ "$RESULT" = "SUCCESS" ] || [ "$PARTIAL_OK" -eq 1 ]; then exit 0; fi
exit 1
