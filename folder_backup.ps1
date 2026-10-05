<#
.SYNOPSIS
  Folderweises Backup eines PowerCenter-Repositorys mit pmrep (Gegenstueck zu folder_backup.sh).

.DESCRIPTION
  Erst die Shared Folder, danach alle anderen; je Folder ein XML pro Objekt, gruppiert nach
  Objekttyp in Import-Reihenfolge (oder ein XML pro Workflow). Jede Datei wird geprueft
  (vollstaendig, wohlgeformt, Objekt enthalten), alles landet im Manifest (mit SHA256).
  Fuer den Restore entstehen import_order.txt und je Folder ein Control-File.

  Exitcodes: 0 = OK, 1 = teilweise fehlerhaft (PARTIAL), 2 = Abbruch (FAILED)
  Aufruf aus einem Workflow: Command Task, siehe docs/FOLDER_BACKUP.md
  Laeuft mit Windows PowerShell 5.1 und PowerShell 7.

.EXAMPLE
  .\folder_backup.ps1 -Repository PM_PROD -Domain Dom_Prod -User admin -BackupDir D:\infa_backup

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File folder_backup.ps1 -ConfigFile D:\infa\folder_backup.conf

.EXAMPLE
  .\folder_backup.ps1 -ConfigFile .\folder_backup.conf -GitRepo D:\infa_git -GitAuthor "Backup Job <backup@firma.de>"

  Exporte zusaetzlich in ein Git-Repository uebernehmen (Zeitstempel im XML-Kopf neutralisiert) und committen.

.EXAMPLE
  .\folder_backup.ps1 -ConfigFile .\folder_backup.conf -Incremental Q_CHANGED_2D

  Nur Objekte sichern, die die gespeicherte Repository-Query Q_CHANGED_2D liefert (eigener Lauf ..._inc).
#>
[CmdletBinding()]
param(
  [string]$ConfigFile,
  [string]$Repository,
  [string]$Domain,
  [string]$User,
  [string]$SecurityDomain,
  [string]$PasswordVar = 'INFA_PASSWORD',     # Umgebungsvariable mit pmpasswd-verschluesseltem Passwort
  [string]$Pmrep,
  [string[]]$Folders = @(),                   # Standard: alle
  [string[]]$SharedFolders = @(),             # Standard: automatisch erkannt
  [string]$Exclude,                           # Regex fuer auszuschliessende Folder
  [string[]]$Types = @('source', 'target', 'User Defined Function', 'transformation', 'mapplet', 'mapping', 'sessionconfig', 'session', 'worklet', 'workflow'),
  [ValidateSet('objects', 'workflows')][string]$Mode = 'objects',
  [ValidateSet('full', 'none')][string]$Deps = 'full',
  [string]$BackupDir = '.\infa_backup',
  [int]$Retries = 2,
  [int]$Keep = 0,
  [int]$MinFreeMB = 500,
  [int]$MaxErrors = 0,
  [switch]$FailFast,
  [switch]$PartialOk,
  [switch]$Zip,
  [switch]$List,
  [string]$GitRepo,                           # Exporte zusaetzlich in dieses Git-Repository uebernehmen
  [string]$GitAuthor,                         # "Name <mail>" fuer die Commits
  [switch]$GitPush,
  [string]$Incremental,                       # gespeicherte Repository-Query: nur geaenderte Objekte sichern
  [ValidateSet('shared', 'personal')][string]$QueryType = 'shared',
  [switch]$NoExtras                           # keine ergaenzenden Sicherungen in _repository/
)

$ErrorActionPreference = 'Stop'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

### ---------------------------------------------------------------- Konfigurationsdatei (Kommandozeile hat Vorrang)
if ($ConfigFile) {
  if (-not (Test-Path $ConfigFile)) { Write-Host "[FEHLER] - Konfigurationsdatei nicht lesbar: $ConfigFile"; exit 2 }
  $map = @{ REPO = 'Repository'; DOMAIN = 'Domain'; USER = 'User'; SECDOMAIN = 'SecurityDomain'; PASSVAR = 'PasswordVar'
            PMREP = 'Pmrep'; FOLDERS = 'Folders'; SHARED = 'SharedFolders'; EXCLUDE = 'Exclude'; TYPES = 'Types'
            MODE = 'Mode'; DEPS = 'Deps'; BASEDIR = 'BackupDir'; RETRIES = 'Retries'; KEEP = 'Keep'
            MIN_FREE_MB = 'MinFreeMB'; MAX_ERRORS = 'MaxErrors'; FAIL_FAST = 'FailFast'; PARTIAL_OK = 'PartialOk'; ZIP = 'Zip'
            GIT_REPO = 'GitRepo'; GIT_AUTHOR = 'GitAuthor'; GIT_PUSH = 'GitPush'
            INCR_QUERY = 'Incremental'; QUERY_TYPE = 'QueryType'; EXTRAS = 'NoExtras' }
  foreach ($line in Get-Content $ConfigFile) {
    if ($line -match '^\s*(#|$)') { continue }
    if ($line -notmatch '^\s*([A-Z_]+)\s*=\s*(.*?)\s*$') { continue }
    $k = $Matches[1]; $v = $Matches[2]
    if (-not $map.ContainsKey($k)) { Write-Host "[WARNUNG] - unbekannter Schluessel in ${ConfigFile}: $k"; continue }
    $p = $map[$k]
    if ($PSBoundParameters.ContainsKey($p)) { continue }
    switch ($p) {
      { $_ -in 'Folders', 'SharedFolders', 'Types' } { Set-Variable -Name $p -Value @($v -split ','); break }
      { $_ -in 'Retries', 'Keep', 'MinFreeMB', 'MaxErrors' } { Set-Variable -Name $p -Value ([int]$v); break }
      { $_ -in 'FailFast', 'PartialOk', 'Zip', 'GitPush' } { Set-Variable -Name $p -Value ([bool][int]$v); break }
      'NoExtras' { Set-Variable -Name $p -Value (-not [bool][int]$v); break }   # EXTRAS=0 -> -NoExtras
      default { Set-Variable -Name $p -Value $v }
    }
  }
}
# "-Types a,b" kommt bei "powershell -File" als ein String an
$Folders = @($Folders | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$SharedFolders = @($SharedFolders | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$Types = @($Types | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

if (-not $Repository -or -not $Domain -or -not $User) { Write-Host '[FEHLER] - Repository, Domain und User sind Pflicht (Parameter oder -ConfigFile)'; exit 2 }
if ($Mode -notin 'objects', 'workflows') { Write-Host '[FEHLER] - Mode muss objects oder workflows sein'; exit 2 }
if ($Deps -notin 'full', 'none') { Write-Host '[FEHLER] - Deps muss full oder none sein'; exit 2 }
if ($Mode -eq 'workflows') { $Types = @('workflow'); $Deps = 'full' }

if (-not $Pmrep) {
  $cmd = Get-Command pmrep -ErrorAction SilentlyContinue
  if ($cmd) { $Pmrep = $cmd.Source }
  elseif ($env:INFA_HOME) {
    foreach ($c in @('server\bin\pmrep.exe', 'server/bin/pmrep', 'clients\PowerCenterClient\client\bin\pmrep.exe')) {
      $p = Join-Path $env:INFA_HOME $c
      if (Test-Path $p) { $Pmrep = $p; break }
    }
  }
  if (-not $Pmrep) { Write-Host '[FEHLER] - pmrep nicht gefunden (-Pmrep oder PATH/INFA_HOME setzen)'; exit 2 }
}

### ---------------------------------------------------------------- Laufverzeichnis, Sperre, Log
New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
$BackupDir = (Resolve-Path $BackupDir).Path
$Lock = Join-Path $BackupDir '.folder_backup.lock'
try {
  New-Item -ItemType Directory -Path $Lock -ErrorAction Stop | Out-Null
} catch {
  $oldPid = Get-Content (Join-Path $Lock 'pid') -ErrorAction SilentlyContinue
  if ($oldPid -and (Get-Process -Id ([int]$oldPid) -ErrorAction SilentlyContinue)) {
    Write-Host "[FEHLER] - es laeuft bereits ein Backup (PID $oldPid, Sperre $Lock)"; exit 2
  }
  Write-Host "[WARNUNG] - verwaiste Sperre von PID $oldPid entfernt"
  Remove-Item $Lock -Recurse -Force; New-Item -ItemType Directory -Path $Lock | Out-Null
}
Set-Content -Path (Join-Path $Lock 'pid') -Value $PID

function Get-SafeName([string]$Name) { return ($Name -replace '[^A-Za-z0-9_.-]', '_') }

$Stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$Prefix = (Get-SafeName $Repository) + '_'
$RunDir = Join-Path $BackupDir ($Prefix + $Stamp)
if ($Incremental) { $RunDir = "${RunDir}_inc" }
if ($List) { $RunDir = Join-Path $BackupDir "list_$Stamp" }
$n = 1; $baseRunDir = $RunDir
while (Test-Path $RunDir) { $n++; $RunDir = "${baseRunDir}_$n" }
$LogDir = Join-Path $RunDir 'log'
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$LogFile = Join-Path $RunDir 'backup.log'
$Manifest = Join-Path $RunDir 'manifest.csv'
$OrderFile = Join-Path $RunDir 'import_order.txt'
$prevCnx = $env:INFA_REPCNX_INFO
$env:INFA_REPCNX_INFO = Join-Path $RunDir 'pmrep.cnx'   # eigene Verbindungsdatei
New-Item -ItemType File -Path (Join-Path $RunDir 'RUNNING') | Out-Null

$script:Errors = 0; $script:Warnings = 0; $script:NObj = 0; $script:NOk = 0; $script:Status = 'RUNNING'
$script:PwPlain = $null
$manifestRows = New-Object System.Collections.Generic.List[string]
$orderRows = New-Object System.Collections.Generic.List[object]
$manifestRows.Add('folder;typ;name;datei;bytes;sha256;status;meldung')

function Write-Log([string]$Text) {
  $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Text
  Write-Host $line
  Add-Content -Path $LogFile -Value $line
}
function Write-Warn([string]$Text) { $script:Warnings++; Write-Log "[WARNUNG] - $Text" }

function Complete-Run([string]$Result) {
  $script:Status = $Result
  [IO.File]::WriteAllLines($Manifest, [string[]]$manifestRows, (New-Object System.Text.UTF8Encoding($true)))
  Remove-Item (Join-Path $RunDir 'RUNNING') -ErrorAction SilentlyContinue
  @("status=$Result", "repository=$Repository", "start=$Stamp", ("ende=" + (Get-Date -Format 'yyyyMMdd_HHmmss')),
    "objekte=$($script:NObj)", "ok=$($script:NOk)", "fehler=$($script:Errors)", "warnungen=$($script:Warnings)") |
    Set-Content -Path (Join-Path $RunDir $Result)
}

### ---------------------------------------------------------------- pmrep-Aufrufe mit Fehlerbehandlung
function Invoke-PmrepRaw([string[]]$PmArgs, [string]$OutFile) {
  $ErrorActionPreference = 'Continue'   # PS 5.1: stderr nativer Programme sonst als Abbruch
  $out = & $Pmrep @PmArgs 2>&1
  $rc = $LASTEXITCODE
  [IO.File]::WriteAllLines($OutFile, [string[]]@($out | ForEach-Object { "$_" }), $Utf8NoBom)
  return $rc
}

function Connect-Repo {
  $a = @('connect', '-r', $Repository, '-d', $Domain, '-n', $User)
  if ($SecurityDomain) { $a += @('-s', $SecurityDomain) }
  if ([Environment]::GetEnvironmentVariable($PasswordVar)) { $a += @('-X', $PasswordVar) }   # pmpasswd-verschluesselt
  elseif ($script:PwPlain) { $a += @('-x', $script:PwPlain) }
  else { return $false }
  return ((Invoke-PmrepRaw $a (Join-Path $LogDir 'connect.txt')) -eq 0)
}

# Wiederholung mit Neuverbindung
function Invoke-Pmrep([string[]]$PmArgs, [string]$OutFile) {
  $try = 0
  while ($true) {
    if ((Invoke-PmrepRaw $PmArgs $OutFile) -eq 0) { return $true }
    if ($try -ge $Retries) { return $false }
    $try++
    Start-Sleep -Seconds (5 * $try)
    [void](Connect-Repo)
  }
}

function Test-Space {
  try {
    $drive = New-Object IO.DriveInfo([IO.Path]::GetPathRoot($RunDir))
    $free = [int]($drive.AvailableFreeSpace / 1MB)
    if ($free -lt $MinFreeMB) { Write-Log "[FEHLER] - nur noch $free MB frei (Minimum $MinFreeMB MB)"; return $false }
  } catch { }
  return $true
}

function Test-Noise([string]$Line) {
  return ($Line -eq '' -or $Line -match '^(Informatica|Copyright|This Software|Invoked at|Completed at|\.?[A-Za-z]+ completed successfully|Connected to|@@END@@)')
}

function Get-Folders {
  $raw = Join-Path $LogDir 'list_folders.txt'
  if (-not (Invoke-Pmrep @('listobjects', '-o', 'folder') $raw)) { return $null }
  return , @(Get-Content $raw | ForEach-Object { $_.Trim() } | Where-Object { -not (Test-Noise $_) })
}

$formatWarnings = New-Object System.Collections.Generic.List[string]
$folderRows = New-Object System.Collections.Generic.List[string]
# -> Objekte mit Name/Sub (nur wiederverwendbare); $null bei Fehler
function Get-FolderObjects([string]$Type, [string]$FolderName) {
  $raw = Join-Path $LogDir ('list_{0}_{1}.txt' -f (Get-SafeName $FolderName), (Get-SafeName $Type))
  if (-not (Invoke-Pmrep @('listobjects', '-o', $Type, '-f', $FolderName, '-c', '|') $raw)) { return $null }
  $t = $Type.ToLower(); $res = @(); $data = 0
  foreach ($line in Get-Content $raw) {
    if (-not (Test-Noise $line.Trim())) { $data++ }
    $cols = @($line -split '\|' | ForEach-Object { $_.Trim() })
    if ($cols.Count -lt 2 -or $cols[0].ToLower() -ne $t) { continue }
    if ($cols -contains 'non-reusable') { continue }
    $vals = @($cols[1..($cols.Count - 1)] | Where-Object { $_ -and $_ -ne 'reusable' })
    if ($vals.Count -eq 0) { continue }
    $name = $vals[0]; $sub = ''
    if ($vals.Count -gt 1) { $sub = $vals[1] }
    if (($t -eq 'transformation' -or $t -eq 'task') -and $sub) { $tmp = $name; $name = $sub; $sub = $tmp }
    $res += [pscustomobject]@{ Name = $name; Sub = $sub }
  }
  if ($res.Count -eq 0 -and $data -gt 0) {
    $formatWarnings.Add("${FolderName}: listobjects -o $Type liefert $data Zeile(n) in unbekanntem Format, siehe log\$(Split-Path $raw -Leaf)")
  }
  return , $res
}

function Get-TypeIndex([string]$Type) {
  switch ($Type.ToLower()) {
    'source' { '01' } 'target' { '02' } 'user defined function' { '03' } 'transformation' { '04' }
    'mapplet' { '05' } 'mapping' { '06' } 'sessionconfig' { '07' } 'task' { '08' }
    'session' { '09' } 'worklet' { '10' } 'workflow' { '11' } default { '50' }
  }
}

# prueft eine Export-Datei; $null = ok, sonst Fehlertext
function Test-ExportXml([string]$Path, [string]$ObjName) {
  if (-not (Test-Path $Path) -or (Get-Item $Path).Length -eq 0) { return 'Datei fehlt oder leer' }
  $text = [IO.File]::ReadAllText($Path)
  if ($text.Substring([Math]::Max(0, $text.Length - 200)) -notmatch '</POWERMART>') { return 'XML unvollstaendig (kein </POWERMART>)' }
  if (-not ($text.Contains("NAME =""$ObjName""") -or $text.Contains("NAME=""$ObjName"""))) { return "Objekt $ObjName nicht im XML" }
  try {
    $settings = New-Object Xml.XmlReaderSettings
    $settings.DtdProcessing = [Xml.DtdProcessing]::Ignore
    $settings.XmlResolver = $null
    $reader = [Xml.XmlReader]::Create($Path, $settings)
    try { while ($reader.Read()) { } } finally { $reader.Close() }
  } catch { return "XML nicht wohlgeformt: $($_.Exception.Message -replace '[;\r\n]', ' ')" }
  return $null
}

function Add-Error([string]$Text) {
  $script:Errors++; Write-Log "[FEHLER] - $Text"
  if ($FailFast -or ($MaxErrors -gt 0 -and $script:Errors -ge $MaxErrors)) {
    Write-Log "[ABBRUCH] - Fehlergrenze erreicht ($($script:Errors))"
    throw 'ABBRUCH'
  }
}

function ConvertTo-XmlAttr([string]$s) { return [Security.SecurityElement]::Escape($s) }

### ---------------------------------------------------------------- Git-Versionierung
# Ablage: <GitRepo>/<Repository>/<folder>/<NN_typ>/<objekt>.xml (ohne Zeitstempel)
$script:GitBase = $null
$listFailed = @{}
$Latin1 = [Text.Encoding]::GetEncoding(28591)   # byte-genau lesen/schreiben (Exporte sind Windows-1252)

function Invoke-Git([string[]]$GitArgs, [string]$OutFile) {
  $ErrorActionPreference = 'Continue'
  $pre = @('-C', $GitRepo)
  if ($GitAuthor -and $GitAuthor -match '^\s*(.*?)\s*<([^>]+)>') { $pre += @('-c', "user.name=$($Matches[1])", '-c', "user.email=$($Matches[2])") }
  $out = & git @pre @GitArgs 2>&1
  $rc = $LASTEXITCODE
  if ($OutFile) { Add-Content -Path $OutFile -Value @($out | ForEach-Object { "$_" }) }
  return [pscustomobject]@{ Rc = $rc; Out = @($out | ForEach-Object { "$_" }) }
}

function Initialize-Git {
  if (-not (Get-Command git -ErrorAction SilentlyContinue)) { Add-Error 'Git: git nicht gefunden - Versionierung deaktiviert'; return }
  New-Item -ItemType Directory -Force -Path $GitRepo | Out-Null
  $script:GitRepo = (Resolve-Path $GitRepo).Path
  $gl = Join-Path $LogDir 'git.txt'
  if (-not (Test-Path (Join-Path $GitRepo '.git'))) {
    if ((Invoke-Git @('init', '-q') $gl).Rc -ne 0) { Add-Error 'Git: init fehlgeschlagen, siehe log\git.txt'; return }
    [IO.File]::WriteAllText((Join-Path $GitRepo '.gitattributes'), "# Informatica-Exporte: keine Zeilenende-Konvertierung, Diff als Text`n*.xml -text diff`n", $Utf8NoBom)
    Write-Log "[GIT] - neues Repository angelegt: $GitRepo"
  } elseif ((Invoke-Git @('status', '--porcelain') $null).Out.Count -gt 0) {
    Write-Warn "Git: Arbeitsverzeichnis $GitRepo hat uncommittete Aenderungen - sie werden mit committet"
  }
  $script:GitBase = Join-Path $GitRepo (Get-SafeName $Repository)
  New-Item -ItemType Directory -Force -Path $script:GitBase | Out-Null
}

# XML ohne wechselnden Zeitstempel (CREATION_DATE im POWERMART-Kopf) kopieren
function Copy-GitXml([string]$Src, [string]$Dst) {
  New-Item -ItemType Directory -Force -Path (Split-Path $Dst) | Out-Null
  $t = [IO.File]::ReadAllText($Src, $Latin1)
  $t = [regex]::Replace($t, '(<POWERMART[^>]*CREATION_DATE *= *")[^"]*"', '${1}01/01/1970 00:00:00"', 'None', [TimeSpan]::FromSeconds(10))
  [IO.File]::WriteAllText($Dst, $t, $Latin1)
}

# einen Folder spiegeln; fehlgeschlagene Exporte behalten ihre letzte Version
function Sync-GitFolder([string]$Folder) {
  $sf = Get-SafeName $Folder; $g = Join-Path $script:GitBase $sf
  New-Item -ItemType Directory -Force -Path $g | Out-Null
  $ok = @{}; $keep = @{}
  foreach ($row in $manifestRows) {
    $c = $row -split ';'
    if ($c.Count -lt 7 -or $c[0] -cne $Folder) { continue }
    $rel = $c[3] -replace '\\', '/'
    if ($c[6] -eq 'OK') { $ok[$rel] = $true } elseif ($c[6] -eq 'FEHLER') { $keep[($rel -replace '\.failed$', '')] = $true }
  }
  foreach ($rel in $ok.Keys) { Copy-GitXml (Join-Path $RunDir $rel) (Join-Path $script:GitBase $rel) }
  $ctrl = Join-Path (Join-Path $RunDir $sf) 'import_ctrl.xml'
  $gctrl = Join-Path $g 'import_ctrl.xml'
  if (Test-Path $ctrl) {
    if ($Incremental -and (Test-Path $gctrl)) { Merge-Ctrl $ctrl $gctrl }   # Shortcut-Eintraege ergaenzen statt ersetzen
    else { Copy-Item $ctrl $gctrl -Force }
  }
  if ($Incremental) { return }   # inkrementell: nichts loeschen
  if ($listFailed.ContainsKey($Folder)) { Write-Warn "Git: $Folder - Objektliste unvollstaendig, geloeschte Objekte werden nicht entfernt"; return }
  foreach ($x in Get-ChildItem -Path $g -Recurse -Filter '*.xml' -File | Where-Object Name -ne 'import_ctrl.xml') {
    $rel = $x.FullName.Substring($script:GitBase.Length + 1) -replace '\\', '/'
    if (-not $ok.ContainsKey($rel) -and -not $keep.ContainsKey($rel)) { Remove-Item $x.FullName -Force }
  }
  Get-ChildItem -Path $g -Recurse -Directory | Sort-Object { $_.FullName.Length } -Descending |
    Where-Object { -not (Get-ChildItem $_.FullName -Force) } | Remove-Item -Force
}

# Control-Files zusammenfuehren: FOLDERMAP- und SPECIFICOBJECT-Zeilen aus $Add in $Base ergaenzen (Base wird ueberschrieben)
function Merge-Ctrl([string]$Add, [string]$Base) {
  $addL = @(Get-Content $Add); $baseL = @(Get-Content $Base)
  $seen = @{}; foreach ($l in $baseL) { $seen[$l] = $true }
  $out = New-Object System.Collections.Generic.List[string]
  foreach ($l in $baseL) {
    if ($l -match '<RESOLVECONFLICT>') { foreach ($x in $addL) { if ($x -match '<FOLDERMAP ' -and -not $seen.ContainsKey($x)) { $out.Add($x); $seen[$x] = $true } } }
    if ($l -match '<TYPEOBJECT ') { foreach ($x in $addL) { if ($x -match '<SPECIFICOBJECT ' -and -not $seen.ContainsKey($x)) { $out.Add($x); $seen[$x] = $true } } }
    $out.Add($l)
  }
  [IO.File]::WriteAllLines($Base, [string[]]$out, $Utf8NoBom)
}

function Save-GitCommit([string]$State, [string[]]$Ordered) {
  $gl = Join-Path $LogDir 'git.txt'
  # ergaenzende Sicherungen (_repository) als Momentaufnahme spiegeln
  $xr = Join-Path $RunDir '_repository'; $xg = Join-Path $script:GitBase '_repository'
  if (Test-Path $xr) {
    $keepF = $null; $gf = Join-Path $xg 'folders.csv'
    # inkrementell enthaelt folders.csv nur die geaenderten Folder -> bisherige Fassung behalten
    if ($Incremental -and (Test-Path $gf)) { $keepF = [IO.File]::ReadAllBytes($gf) }
    if (Test-Path $xg) { Remove-Item $xg -Recurse -Force }
    Copy-Item $xr $xg -Recurse
    if ($keepF) { [IO.File]::WriteAllBytes($gf, $keepF) }
  }
  if ($Folders.Count -eq 0 -and -not $Incremental -and $Ordered.Count -gt 0) {   # Folder, die es nicht mehr gibt
    $names = @($Ordered | ForEach-Object { Get-SafeName $_ })
    foreach ($d in Get-ChildItem -Path $script:GitBase -Directory) {
      if ($d.Name -eq '_repository') { continue }
      if ($names -ccontains $d.Name) { continue }
      if ($Exclude -and $d.Name -match $Exclude) { continue }
      Remove-Item $d.FullName -Recurse -Force; Write-Log "[GIT] - Folder $($d.Name) existiert nicht mehr - aus Git entfernt"
    }
  }
  if ((Invoke-Git @('add', '-A', '--', '.') $gl).Rc -ne 0) { Add-Error 'Git: add fehlgeschlagen, siehe log\git.txt'; return }
  $stat = (Invoke-Git @('diff', '--cached', '--no-renames', '--name-status') $null).Out | Where-Object { $_ }
  if (-not $stat) { Write-Log '[GIT] - keine Aenderungen gegenueber dem letzten Backup'; return }
  $add = @($stat | Where-Object { $_ -like 'A*' }).Count; $mod = @($stat | Where-Object { $_ -like 'M*' }).Count; $del = @($stat | Where-Object { $_ -like 'D*' }).Count
  $kind = 'Backup'; if ($Incremental) { $kind = 'Inkrementell' }
  $msg = "$kind $Repository $Stamp ($State): $add neu, $mod geaendert, $del geloescht"
  if ((Invoke-Git @('commit', '-q', '-m', $msg, '-m', "Lauf: $(Split-Path $RunDir -Leaf)") $gl).Rc -ne 0) {
    Add-Error 'Git: commit fehlgeschlagen (Autor konfiguriert? -GitAuthor), siehe log\git.txt'; return
  }
  $head = ((Invoke-Git @('rev-parse', '--short', 'HEAD') $null).Out | Select-Object -First 1)
  Write-Log "[GIT] - Commit ${head}: $add neu, $mod geaendert, $del geloescht"
  [IO.File]::WriteAllLines((Join-Path $RunDir 'git_changes.txt'), [string[]]$stat, $Utf8NoBom)
  if ($GitPush) {
    if ((Invoke-Git @('push', '-q') $gl).Rc -eq 0) { Write-Log '[GIT] - gepusht' } else { Add-Error 'Git: push fehlgeschlagen, siehe log\git.txt' }
  }
}

### ---------------------------------------------------------------- Hauptteil
$exitCode = 2
try {
  Write-Log "[FOLDER_BACKUP] - Repository=$Repository Modus=$Mode Abhaengigkeiten=$Deps Ziel=$RunDir"
  if ($List) { Write-Log '[INFO] - Trockenlauf (-List): es wird nichts exportiert' }

  if (-not [Environment]::GetEnvironmentVariable($PasswordVar)) {
    if ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected) {
      $sec = Read-Host -AsSecureString "Passwort fuer $User"
      $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
      try { $script:PwPlain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
      finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr); $sec.Dispose() }
    } else {
      Write-Log "[FEHLER] - kein Passwort: Umgebungsvariable $PasswordVar (pmpasswd-verschluesselt) setzen"
      Complete-Run 'FAILED'; exit 2
    }
  }
  if (-not (Connect-Repo)) {
    Write-Log "[FEHLER] - Verbindung zu $Repository fehlgeschlagen, siehe $(Join-Path $LogDir 'connect.txt')"
    if (Select-String -Path (Join-Path $LogDir 'connect.txt') -Pattern 'password|passwort|decrypt' -Quiet) {
      Write-Log "[HINWEIS] - $PasswordVar muss das mit pmpasswd verschluesselte Passwort enthalten (pmpasswd <passwort>)"
    }
    Complete-Run 'FAILED'; exit 2
  }
  Write-Log "[STATUS] - verbunden mit $Repository"
  if (-not (Test-Space)) { Complete-Run 'FAILED'; exit 2 }
  if ($GitRepo -and -not $List) { Initialize-Git }

  ### ------------------------------------------------------------ Folder ermitteln und ordnen
  $allFolders = Get-Folders
  if ($null -eq $allFolders) { Write-Log '[FEHLER] - Folderliste nicht lesbar, siehe log\list_folders.txt'; Complete-Run 'FAILED'; exit 2 }
  if ($allFolders.Count -eq 0) { Write-Log '[FEHLER] - keine Folder gefunden'; Complete-Run 'FAILED'; exit 2 }

  $want = New-Object System.Collections.Generic.List[string]
  if ($Folders.Count -gt 0) {
    foreach ($f in $Folders) { if ($allFolders -ccontains $f) { $want.Add($f) } else { Add-Error "Folder $f existiert nicht" } }
  } else { foreach ($f in $allFolders) { $want.Add($f) } }
  if ($Exclude) { $want = [System.Collections.Generic.List[string]]@($want | Where-Object { $_ -notmatch $Exclude }) }

  # Inkrementell: geaenderte Objekte aus der gespeicherten Query.
  # Kandidaten (Zeile, Folder, Typ, Token) - der Objektname wird spaeter gegen listobjects abgeglichen
  $cand = New-Object System.Collections.Generic.List[object]; $candFT = @{}; $matched = @{}
  if ($Incremental) {
    Set-Content -Path (Join-Path $RunDir 'INCREMENTAL') -Value "query=$Incremental"
    $qOut = Join-Path $LogDir 'query_result.txt'; $qFile = Join-Path $LogDir 'query_persistent.txt'
    if (-not (Invoke-Pmrep @('executequery', '-q', $Incremental, '-t', $QueryType, '-c', '|', '-u', $qFile) $qOut)) {
      Write-Log "[FEHLER] - Query '$Incremental' ($QueryType) nicht ausfuehrbar, siehe log\query_result.txt"
      Write-Log '[HINWEIS] - Query im Repository Manager anlegen (Tools > Queries), siehe docs/FOLDER_BACKUP.md'
      Complete-Run 'FAILED'; exit 2
    }
    # Quelle: persistente Datei (Komma), sonst Bildschirmausgabe (|)
    if ((Test-Path $qFile) -and (Get-Item $qFile).Length -gt 0) { $qSrc = $qFile; $qSep = ',' } else { $qSrc = $qOut; $qSep = '|' }
    $known = @{}; foreach ($t in $Types) { $known[$t.ToLower()] = $true }
    $folderSet = @{}; foreach ($f in $allFolders) { $folderSet[$f] = $true }
    $ln = 0
    foreach ($line in Get-Content $qSrc) {
      $ln++
      $tok = @($line -split [regex]::Escape($qSep) | ForEach-Object { $_.Trim() })
      $ti = -1; for ($i = 0; $i -lt $tok.Count; $i++) { if ($known.ContainsKey($tok[$i].ToLower())) { $ti = $i; break } }
      if ($ti -lt 0) { continue }
      $t = $tok[$ti].ToLower(); $tok[$ti] = ''
      $fi = -1; for ($i = 0; $i -lt $tok.Count; $i++) { if ($tok[$i] -and $folderSet.ContainsKey($tok[$i])) { $fi = $i; break } }
      if ($fi -lt 0) { continue }
      $f = $tok[$fi]; $tok[$fi] = ''
      foreach ($v in $tok) {
        if (-not $v -or $v -match '^[0-9]+$' -or $v -match '%3[Aa]|^[0-9]+:' -or $v -in 'reusable', 'non-reusable' -or $v -eq 'none') { continue }
        $cand.Add([pscustomobject]@{ Line = $ln; Folder = $f; Type = $t; Token = $v }); $candFT["$f|$t"] = $true
      }
    }
    $nq = @($cand | Select-Object -ExpandProperty Line -Unique).Count
    Write-Log "[INKREMENTELL] - Query '$Incremental': $nq Objekt(e) in den gesicherten Typen"
    $cand | ForEach-Object { '{0}|{1}|{2}|{3}' -f $_.Line, $_.Folder, $_.Type, $_.Token } | Set-Content (Join-Path $LogDir 'query_candidates.txt')
    $want = [System.Collections.Generic.List[string]]@($want | Where-Object { $f = $_; @($candFT.Keys | Where-Object { $_.StartsWith("$f|") }).Count -gt 0 })
    if ($want.Count -eq 0) { Write-Log '[INKREMENTELL] - keine geaenderten Objekte - nichts zu sichern' }
  }

  $isShared = @{}
  if ($SharedFolders.Count -gt 0) {
    foreach ($f in $SharedFolders) { if ($want -ccontains $f) { $isShared[$f] = $true } else { Write-Warn "Shared Folder $f nicht im Backup-Umfang" } }
  } else {
    # automatisch per Probe-Export (Attribut SHARED im FOLDER-Element)
    foreach ($f in $want) {
      foreach ($t in 'source', 'target', 'transformation', 'mapplet', 'mapping', 'workflow') {
        $o = Get-FolderObjects $t $f
        if (-not $o -or $o.Count -eq 0) { continue }
        $probe = Join-Path $LogDir ('probe_{0}.xml' -f (Get-SafeName $f))
        if (Invoke-Pmrep @('objectexport', '-o', $t, '-n', $o[0].Name, '-f', $f, '-u', $probe) (Join-Path $LogDir ('probe_{0}.txt' -f (Get-SafeName $f)))) {
          if (Select-String -Path $probe -Pattern '<FOLDER [^>]*SHARED *= *"SHARED"' -Quiet) { $isShared[$f] = $true }
          Remove-Item $probe -ErrorAction SilentlyContinue
        }
        break
      }
    }
  }
  $ordered = @($want | Where-Object { $isShared.ContainsKey($_) } | Sort-Object) + @($want | Where-Object { -not $isShared.ContainsKey($_) } | Sort-Object)
  Write-Log ("[INFO] - {0} Folder, davon {1} shared: {2}" -f $ordered.Count, $isShared.Count, (@($isShared.Keys) -join ' '))

  ### ------------------------------------------------------------ Trockenlauf
  if ($List) {
    foreach ($f in $ordered) {
      $line = $f; if ($isShared.ContainsKey($f)) { $line += ' (shared)' }; $line += ':'
      foreach ($t in $Types) { $o = Get-FolderObjects $t $f; $c = 0; if ($o) { $c = $o.Count }; $line += " $t=$c" }
      Write-Log "[LISTE] - $line"
    }
    Complete-Run 'SUCCESS'; $exitCode = 0
    exit 0
  }

  ### ------------------------------------------------------------ Backup je Folder
  $depFlags = @(); if ($Deps -eq 'full') { $depFlags = @('-m', '-s', '-b', '-r') }
  foreach ($f in $ordered) {
    if (-not (Test-Space)) { Complete-Run 'FAILED'; exit 2 }
    $fdir = Join-Path $RunDir (Get-SafeName $f)
    New-Item -ItemType Directory -Force -Path $fdir | Out-Null
    $fErr = $script:Errors; $fCnt = 0
    $tag = ''; if ($isShared.ContainsKey($f)) { $tag = ' (shared)' }
    Write-Log "[FOLDER] - $f$tag"

    foreach ($t in $Types) {
      if ($Incremental -and -not $candFT.ContainsKey("$f|$($t.ToLower())")) { continue }
      $objs = Get-FolderObjects $t $f
      if ($null -eq $objs) { $listFailed[$f] = $true; Add-Error "${f}: listobjects fuer Typ $t fehlgeschlagen"; continue }
      if ($Incremental -and $objs.Count -gt 0) {
        # nur geaenderte Objekte; Name voll (DBD.NAME) oder ohne DBD-Praefix
        $mine = @($cand | Where-Object { $_.Folder -ceq $f -and $_.Type -eq $t.ToLower() })
        $objs = @($objs | Where-Object {
          $n = $_.Name; $s = $n; if ($t.ToLower() -eq 'source' -and $n.Contains('.')) { $s = $n.Substring($n.IndexOf('.') + 1) }
          $hit = @($mine | Where-Object { $_.Token -ceq $n -or ($t.ToLower() -eq 'source' -and $_.Token -ceq $s) })
          foreach ($h in $hit) { $matched[$h.Line] = $true }
          $hit.Count -gt 0 })
      }
      if ($objs.Count -eq 0) { continue }
      $tdir = Join-Path $fdir ('{0}_{1}' -f (Get-TypeIndex $t), (Get-SafeName ($t.ToLower() -replace ' ', '_')))
      New-Item -ItemType Directory -Force -Path $tdir | Out-Null
      foreach ($o in $objs) {
        $script:NObj++; $fCnt++
        $xml = Join-Path $tdir ((Get-SafeName $o.Name) + '.xml')
        $rel = $xml.Substring($RunDir.Length + 1)
        $a = @('objectexport', '-o', $t, '-n', $o.Name, '-f', $f) + $depFlags + @('-u', $xml)
        if ($o.Sub) { $a += @('-t', $o.Sub) }
        $sn = $o.Name; if ($t.ToLower() -eq 'source' -and $sn.Contains('.')) { $sn = $sn.Substring($sn.IndexOf('.') + 1) }
        $lf = Join-Path $LogDir ('export_{0}_{1}_{2}.txt' -f (Get-SafeName $f), (Get-SafeName $t), (Get-SafeName $o.Name))
        if (-not (Invoke-Pmrep $a $lf)) {
          $msg = (Select-String -Path $lf -Pattern 'error|fail|not found' | Select-Object -First 1 | ForEach-Object { $_.Line }) -replace ';', ','
          if (-not $msg) { $msg = 'pmrep objectexport fehlgeschlagen' }
          if (Test-Path $xml) { Move-Item -Force $xml "$xml.failed" }   # unvollstaendige Datei nie als gueltig liegen lassen
          $manifestRows.Add("$f;$t;$($o.Name);$rel.failed;0;-;FEHLER;$msg")
          Add-Error "${f}: $t $($o.Name) - Export fehlgeschlagen"
          continue
        }
        $vmsg = Test-ExportXml $xml $sn
        if ($vmsg) {
          $bytes = 0; if (Test-Path $xml) { $bytes = (Get-Item $xml).Length; Move-Item -Force $xml "$xml.failed" }
          $manifestRows.Add("$f;$t;$($o.Name);$rel.failed;$bytes;-;FEHLER;$vmsg")
          Add-Error "${f}: $t $($o.Name) - $vmsg"
          continue
        }
        $hash = (Get-FileHash -Algorithm SHA256 -Path $xml).Hash.ToLower()
        $manifestRows.Add("$f;$t;$($o.Name);$rel;$((Get-Item $xml).Length);$hash;OK;")
        $orderRows.Add([pscustomobject]@{ Folder = $f; Rel = $rel; Ctrl = ((Get-SafeName $f) + '/import_ctrl.xml') })
        $script:NOk++
      }
    }

    # Shared-Status aus den Exporten bestaetigen
    $first = Get-ChildItem -Path $fdir -Recurse -Filter '*.xml' -File | Select-Object -First 1
    if (-not $NoExtras -and $first) {
      $fm = [regex]::Match([IO.File]::ReadAllText($first.FullName), '<FOLDER\s[^>]*>')
      if ($fm.Success) {
        $fa = @{}; foreach ($am in [regex]::Matches($fm.Value, '([A-Za-z_]+)\s*=\s*"([^"]*)"')) { $fa[$am.Groups[1].Value] = $am.Groups[2].Value }
        $folderRows.Add(('{0};{1};{2};{3};{4};{5}' -f $f, $fa['SHARED'], $fa['OWNER'], $fa['GROUP'], $fa['PERMISSIONS'], ("$($fa['DESCRIPTION'])" -replace ';', ',')))
      }
    }
    if ($first -and -not $isShared.ContainsKey($f) -and (Select-String -Path $first.FullName -Pattern '<FOLDER [^>]*SHARED *= *"SHARED"' -Quiet)) {
      Write-Warn "$f ist ein Shared Folder, wurde aber nicht zuerst gesichert - im Restore zuerst importieren (-SharedFolders angeben)"
      $isShared[$f] = $true
    }

    # Control-File fuer den Restore: Folder + referenzierte Shared Folder, Shortcuts wiederverwenden
    $srcRepo = $Repository
    if ($first) { $m = Select-String -Path $first.FullName -Pattern '<REPOSITORY NAME *= *"([^"]*)"' | Select-Object -First 1; if ($m) { $srcRepo = $m.Matches[0].Groups[1].Value } }
    $shortcuts = @{}; $mapFolders = @{ $f = $true }
    foreach ($x in Get-ChildItem -Path $fdir -Recurse -Filter '*.xml' -File) {
      foreach ($sm in [regex]::Matches([IO.File]::ReadAllText($x.FullName), '<SHORTCUT\s[^>]*>')) {
        $at = @{}; foreach ($am in [regex]::Matches($sm.Value, '([A-Za-z_]+)\s*=\s*"([^"]*)"')) { $at[$am.Groups[1].Value] = $am.Groups[2].Value }
        if ($at['FOLDERNAME']) { $mapFolders[$at['FOLDERNAME']] = $true }
        if ($at['NAME']) { $shortcuts["$($at['NAME'])|$($at['OBJECTSUBTYPE'])|$($at['DBDNAME'])"] = $at }
      }
    }
    $cx = @('<?xml version="1.0" encoding="UTF-8"?>', '<!DOCTYPE IMPORTPARAMS SYSTEM "impcntl.dtd">',
            "<!-- Restore von Folder $(ConvertTo-XmlAttr $f); TARGETREPOSITORYNAME bei Import in ein anderes Repository anpassen -->",
            '<IMPORTPARAMS CHECKIN_AFTER_IMPORT="NO" RETAIN_GENERATED_VALUE="YES">')
    foreach ($mf in ($mapFolders.Keys | Sort-Object)) {
      $cx += ('  <FOLDERMAP SOURCEFOLDERNAME="{0}" SOURCEREPOSITORYNAME="{1}" TARGETFOLDERNAME="{0}" TARGETREPOSITORYNAME="{2}"/>' -f (ConvertTo-XmlAttr $mf), (ConvertTo-XmlAttr $srcRepo), (ConvertTo-XmlAttr $Repository))
    }
    $cx += '  <RESOLVECONFLICT>'
    # Shortcuts nie ersetzen (REPLACE erzeugt bei Shortcuts Duplikate mit Zahlen-Suffix)
    foreach ($k in ($shortcuts.Keys | Sort-Object)) {
      $at = $shortcuts[$k]; $db = ''
      if ($at['DBDNAME']) { $db = ' DBDNAME="{0}"' -f (ConvertTo-XmlAttr $at['DBDNAME']) }
      $cx += ('    <SPECIFICOBJECT NAME="{0}"{1} OBJECTTYPENAME="{2}" FOLDERNAME="{3}" REPOSITORYNAME="{4}" RESOLUTION="REUSE"/>' -f
        (ConvertTo-XmlAttr $at['NAME']), $db, (ConvertTo-XmlAttr $at['OBJECTSUBTYPE']), (ConvertTo-XmlAttr $f), (ConvertTo-XmlAttr $srcRepo))
    }
    $cx += @('    <TYPEOBJECT OBJECTTYPENAME="All" RESOLUTION="REPLACE"/>', '  </RESOLVECONFLICT>', '</IMPORTPARAMS>')
    [IO.File]::WriteAllLines((Join-Path $fdir 'import_ctrl.xml'), [string[]]$cx, $Utf8NoBom)

    # ins Git-Verzeichnis spiegeln (vor dem Packen)
    if ($script:GitBase) { Sync-GitFolder $f }

    # optional packen (nur wenn der Folder fehlerfrei war)
    if ($Zip -and $script:Errors -eq $fErr) {
      $zipFile = "$fdir.zip"
      try {
        Compress-Archive -Path $fdir -DestinationPath $zipFile -Force
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $za = [IO.Compression.ZipFile]::OpenRead($zipFile); $cnt = $za.Entries.Count; $za.Dispose()
        if ($cnt -gt 0) { Remove-Item $fdir -Recurse -Force } else { throw 'leeres Archiv' }
      } catch { Add-Error "${f}: Archiv $zipFile fehlerhaft - XML-Dateien bleiben erhalten ($($_.Exception.Message))" }
    }
    Write-Log ("[FOLDER] - {0} fertig: {1} Objekte, {2} Fehler" -f $f, $fCnt, ($script:Errors - $fErr))
  }

  # Import-Reihenfolge: Shared Folder zuerst, innerhalb des Folders nach Typ-Praefix
  $orderLines = @()
  foreach ($grp in @($true, $false)) {
    foreach ($f in $ordered) {
      if ($isShared.ContainsKey($f) -ne $grp) { continue }
      $orderLines += @($orderRows | Where-Object { $_.Folder -ceq $f } | Sort-Object Rel | ForEach-Object { '{0}|{1}|{2}' -f $_.Folder, ($_.Rel -replace '\\', '/'), $_.Ctrl })
    }
  }
  [IO.File]::WriteAllLines($OrderFile, [string[]]$orderLines, $Utf8NoBom)
  # Inkrementell: Query-Treffer ohne passendes wiederverwendbares Objekt
  if ($Incremental -and $cand.Count -gt 0) {
    $unm = @($cand | Select-Object -ExpandProperty Line -Unique | Where-Object { -not $matched.ContainsKey($_) }).Count
    if ($unm -gt 0) { Write-Log "[INKREMENTELL] - $unm Query-Treffer ohne passendes wiederverwendbares Objekt (nicht wiederverwendbar, geloescht oder ausserhalb des Umfangs), siehe log\query_candidates.txt" }
  }

  # ergaenzende Sicherungen: Connections (ohne Passwoerter), Folder, ausgecheckte Objekte, globale Objekte
  if (-not $NoExtras) {
    $x = Join-Path $RunDir '_repository'; $xc = Join-Path $x 'connections'
    New-Item -ItemType Directory -Force -Path $xc | Out-Null
    $cl = Join-Path $x 'connections.txt'
    if (Invoke-Pmrep @('listconnections', '-t') $cl) {
      foreach ($line in Get-Content $cl) {
        if (Test-Noise $line.Trim()) { continue }
        $parts = @($line -split '[,|\s]+' | Where-Object { $_ })
        if ($parts.Count -eq 0) { continue }
        $name = $parts[0]
        $typ = $parts | Where-Object { $_ -match '^(relational|application|ftp|loader|queue)$' } | Select-Object -First 1
        if (-not $typ) { $typ = 'relational' }
        $tmp = Join-Path $xc ((Get-SafeName $name) + '.tmp')
        if (Invoke-Pmrep @('getconnectiondetails', '-n', $name, '-t', $typ) $tmp) {
          Get-Content $tmp | Where-Object { $_ -notmatch 'password|passwort' } | Set-Content (Join-Path $xc ((Get-SafeName $name) + '.txt'))
        } else { Write-Warn "Extras: Details fuer Connection $name nicht lesbar" }
        Remove-Item $tmp -ErrorAction SilentlyContinue
      }
      $clean = @(Get-Content $cl | Where-Object { $_ -notmatch 'password|passwort' }); [IO.File]::WriteAllLines($cl, [string[]]$clean, $Utf8NoBom)
    } else { Write-Warn 'Extras: listconnections fehlgeschlagen, siehe _repository\connections.txt' }
    if ($folderRows.Count -gt 0) {
      [IO.File]::WriteAllLines((Join-Path $x 'folders.csv'), [string[]](@('folder;shared;owner;group;permissions;beschreibung') + $folderRows), $Utf8NoBom)
    }
    $co = Join-Path $x 'checkouts.txt'
    if (Invoke-Pmrep @('findcheckout', '-u', '-c', '|') $co) {
      $nco = @(Get-Content $co | Where-Object { -not (Test-Noise $_.Trim()) }).Count
      if ($nco -gt 0) { Write-Warn "$nco ausgecheckte(s) Objekt(e) - das Backup enthaelt die zuletzt eingecheckte Version, siehe _repository\checkouts.txt" }
    } else { Write-Log '[INFO] - findcheckout nicht verfuegbar (nicht versioniertes Repository?) - siehe _repository\checkouts.txt' }
    foreach ($o in @(@('label', 'labels'), @('deploymentgroup', 'deploymentgroups'), @('query', 'queries'))) {
      if (-not (Invoke-Pmrep @('listobjects', '-o', $o[0]) (Join-Path $x "$($o[1]).txt"))) { Write-Log "[INFO] - listobjects -o $($o[0]) nicht verfuegbar" }
    }
    Write-Log '[EXTRAS] - Connections, Folder-Eigenschaften, Checkouts, Labels, Deployment Groups, Queries in _repository/'
  }

  foreach ($w in $formatWarnings) { Write-Warn $w }

  ### ------------------------------------------------------------ Abschluss
  $result = 'SUCCESS'; if ($script:Errors -gt 0) { $result = 'PARTIAL' }
  if ($script:GitBase) {
    Save-GitCommit $result $ordered
    $result = 'SUCCESS'; if ($script:Errors -gt 0) { $result = 'PARTIAL' }
  }
  Write-Log ("[ERGEBNIS] - {0}: {1} von {2} Objekten gesichert, {3} Fehler, {4} Warnungen" -f $result, $script:NOk, $script:NObj, $script:Errors, $script:Warnings)
  Write-Log "[ERGEBNIS] - Manifest: $Manifest"
  Write-Log "[ERGEBNIS] - Import-Reihenfolge: $OrderFile"
  Complete-Run $result
  if ($result -eq 'SUCCESS') {
    $latest = 'LATEST_SUCCESS'; if ($Incremental) { $latest = 'LATEST_INCREMENTAL' }
    Set-Content -Path (Join-Path $BackupDir $latest) -Value (Split-Path $RunDir -Leaf)
  }

  # Aufbewahrung: nur nach Erfolg; alles aelter als das N-te erfolgreiche Backup loeschen
  if ($result -eq 'SUCCESS' -and $Keep -gt 0 -and -not $Incremental) {
    # nur Vollsicherungen zaehlen (ohne Marker INCREMENTAL); aeltere inkrementelle Laeufe werden mit geloescht
    $good = @(Get-ChildItem -Path $BackupDir -Directory -Filter "$Prefix*" | Where-Object { (Test-Path (Join-Path $_.FullName 'SUCCESS')) -and -not (Test-Path (Join-Path $_.FullName 'INCREMENTAL')) } | Sort-Object Name -Descending)
    if ($good.Count -ge $Keep) {
      $cut = $good[$Keep - 1].Name
      foreach ($d in Get-ChildItem -Path $BackupDir -Directory -Filter "$Prefix*") {
        if ([string]::CompareOrdinal($d.Name, $cut) -lt 0) {
          Remove-Item $d.FullName -Recurse -Force
          Add-Content -Path $LogFile -Value ('{0} [AUFRAEUMEN] - {1} geloescht' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $d.Name)
        }
      }
    }
  }
  if ($result -eq 'SUCCESS' -or $PartialOk) { $exitCode = 0 } else { $exitCode = 1 }
}
catch {
  if ($_.Exception.Message -ne 'ABBRUCH') { Write-Log "[FEHLER] - unerwarteter Fehler: $($_.Exception.Message)" }
  if ($script:Status -eq 'RUNNING') { Complete-Run 'FAILED' }
  $exitCode = 2
}
finally {
  if ($script:Status -eq 'RUNNING') { Complete-Run 'FAILED' }   # z.B. Strg+C
  $script:PwPlain = $null
  Remove-Item $env:INFA_REPCNX_INFO -ErrorAction SilentlyContinue
  if ($null -eq $prevCnx) { Remove-Item Env:INFA_REPCNX_INFO -ErrorAction SilentlyContinue } else { $env:INFA_REPCNX_INFO = $prevCnx }
  Remove-Item $Lock -Recurse -Force -ErrorAction SilentlyContinue
}
exit $exitCode
