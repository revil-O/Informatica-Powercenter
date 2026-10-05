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
  [switch]$List
)

$ErrorActionPreference = 'Stop'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

### ---------------------------------------------------------------- Konfigurationsdatei (Kommandozeile hat Vorrang)
if ($ConfigFile) {
  if (-not (Test-Path $ConfigFile)) { Write-Host "[FEHLER] - Konfigurationsdatei nicht lesbar: $ConfigFile"; exit 2 }
  $map = @{ REPO = 'Repository'; DOMAIN = 'Domain'; USER = 'User'; SECDOMAIN = 'SecurityDomain'; PASSVAR = 'PasswordVar'
            PMREP = 'Pmrep'; FOLDERS = 'Folders'; SHARED = 'SharedFolders'; EXCLUDE = 'Exclude'; TYPES = 'Types'
            MODE = 'Mode'; DEPS = 'Deps'; BASEDIR = 'BackupDir'; RETRIES = 'Retries'; KEEP = 'Keep'
            MIN_FREE_MB = 'MinFreeMB'; MAX_ERRORS = 'MaxErrors'; FAIL_FAST = 'FailFast'; PARTIAL_OK = 'PartialOk'; ZIP = 'Zip' }
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
      { $_ -in 'FailFast', 'PartialOk', 'Zip' } { Set-Variable -Name $p -Value ([bool][int]$v); break }
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

  ### ------------------------------------------------------------ Folder ermitteln und ordnen
  $allFolders = Get-Folders
  if ($null -eq $allFolders) { Write-Log '[FEHLER] - Folderliste nicht lesbar, siehe log\list_folders.txt'; Complete-Run 'FAILED'; exit 2 }
  if ($allFolders.Count -eq 0) { Write-Log '[FEHLER] - keine Folder gefunden'; Complete-Run 'FAILED'; exit 2 }

  $want = New-Object System.Collections.Generic.List[string]
  if ($Folders.Count -gt 0) {
    foreach ($f in $Folders) { if ($allFolders -ccontains $f) { $want.Add($f) } else { Add-Error "Folder $f existiert nicht" } }
  } else { foreach ($f in $allFolders) { $want.Add($f) } }
  if ($Exclude) { $want = [System.Collections.Generic.List[string]]@($want | Where-Object { $_ -notmatch $Exclude }) }

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
    return
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
      $objs = Get-FolderObjects $t $f
      if ($null -eq $objs) { Add-Error "${f}: listobjects fuer Typ $t fehlgeschlagen"; continue }
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
  foreach ($w in $formatWarnings) { Write-Warn $w }

  ### ------------------------------------------------------------ Abschluss
  $result = 'SUCCESS'; if ($script:Errors -gt 0) { $result = 'PARTIAL' }
  Write-Log ("[ERGEBNIS] - {0}: {1} von {2} Objekten gesichert, {3} Fehler, {4} Warnungen" -f $result, $script:NOk, $script:NObj, $script:Errors, $script:Warnings)
  Write-Log "[ERGEBNIS] - Manifest: $Manifest"
  Write-Log "[ERGEBNIS] - Import-Reihenfolge: $OrderFile"
  Complete-Run $result
  if ($result -eq 'SUCCESS') { Set-Content -Path (Join-Path $BackupDir 'LATEST_SUCCESS') -Value (Split-Path $RunDir -Leaf) }

  # Aufbewahrung: nur nach Erfolg; alles aelter als das N-te erfolgreiche Backup loeschen
  if ($result -eq 'SUCCESS' -and $Keep -gt 0) {
    $good = @(Get-ChildItem -Path $BackupDir -Directory -Filter "$Prefix*" | Where-Object { Test-Path (Join-Path $_.FullName 'SUCCESS') } | Sort-Object Name -Descending)
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
