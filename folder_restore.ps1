<#
.SYNOPSIS
  Restore aus einem Lauf von folder_backup.ps1/.sh (Gegenstueck zu folder_restore.sh).

.DESCRIPTION
  Importiert alles, einzelne Folder oder einzelne Objekte in der Reihenfolge von import_order.txt
  (Shared Folder zuerst). Standard ist TROCKENLAUF: Dateien werden geprueft (SHA256), Ziel-Folder
  abgeglichen, ein Plan geschrieben - importiert wird nur mit -Execute.
  Der Backup-Lauf bleibt unveraendert: gearbeitet wird in einem eigenen Arbeitsverzeichnis.

  Exitcodes: 0 = OK, 1 = teilweise fehlerhaft, 2 = Abbruch
  Laeuft mit Windows PowerShell 5.1 und PowerShell 7.

.EXAMPLE
  .\folder_restore.ps1 -Repository PM_PROD -Domain Dom_Prod -User admin -BackupDir D:\infa_backup

  Trockenlauf fuer den letzten erfolgreichen Lauf (LATEST_SUCCESS).

.EXAMPLE
  .\folder_restore.ps1 -ConfigFile .\sandbox.conf -Repository PM_SANDBOX -CreateFolders -Validate -Execute -Yes

  Probe-Restore in ein Sandbox-Repository.
#>
[CmdletBinding()]
param(
  [string]$ConfigFile,
  [string]$Repository,                        # Ziel-Repository (TARGETREPOSITORYNAME in den Control-Files)
  [string]$Domain,
  [string]$User,
  [string]$SecurityDomain,
  [string]$PasswordVar = 'INFA_PASSWORD',
  [string]$Pmrep,
  [string]$BackupDir = '.\infa_backup',
  [string]$Run,                               # Laufverzeichnis (Name oder Pfad); Standard: LATEST_SUCCESS
  [string[]]$Folders = @(),
  [string]$ObjectFilter,                      # Regex auf den Dateipfad, z.B. 'DWH/06_mapping/m_load_sales'
  [string]$Dtd,
  [string]$WorkDir,
  [switch]$CreateFolders,
  [string]$Checkin,                           # Kommentar; versioniertes Repository: nach dem Import einchecken
  [switch]$Validate,
  [switch]$NoVerify,
  [switch]$FailFast,
  [int]$MaxErrors = 0,
  [switch]$Execute,
  [switch]$Yes
)

$ErrorActionPreference = 'Stop'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

if ($ConfigFile) {   # gleiche Datei wie folder_backup; backup-spezifische Schluessel werden ignoriert
  if (-not (Test-Path $ConfigFile)) { Write-Host "[FEHLER] - Konfigurationsdatei nicht lesbar: $ConfigFile"; exit 2 }
  $map = @{ REPO = 'Repository'; DOMAIN = 'Domain'; USER = 'User'; SECDOMAIN = 'SecurityDomain'; PASSVAR = 'PasswordVar'; PMREP = 'Pmrep'; BASEDIR = 'BackupDir' }
  foreach ($line in Get-Content $ConfigFile) {
    if ($line -notmatch '^\s*([A-Z_]+)\s*=\s*(.*?)\s*$') { continue }
    $p = $map[$Matches[1]]
    if ($p -and -not $PSBoundParameters.ContainsKey($p)) { Set-Variable -Name $p -Value $Matches[2] }
  }
}
$Folders = @($Folders | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
function Stop-Fatal([string]$Text) { Write-Host "[FEHLER] - $Text"; exit 2 }
if (-not $Repository -or -not $Domain -or -not $User) { Stop-Fatal 'Repository, Domain und User sind Pflicht (Parameter oder -ConfigFile)' }

if (-not $Pmrep) {
  $cmd = Get-Command pmrep -ErrorAction SilentlyContinue
  if ($cmd) { $Pmrep = $cmd.Source }
  elseif ($env:INFA_HOME) {
    foreach ($c in @('server\bin\pmrep.exe', 'server/bin/pmrep', 'clients\PowerCenterClient\client\bin\pmrep.exe')) {
      $p = Join-Path $env:INFA_HOME $c; if (Test-Path $p) { $Pmrep = $p; break }
    }
  }
  if (-not $Pmrep) { Stop-Fatal 'pmrep nicht gefunden (-Pmrep oder PATH/INFA_HOME setzen)' }
}
if (-not $Dtd) {
  $cands = @((Join-Path (Split-Path $Pmrep) 'impcntl.dtd'))
  if ($env:INFA_HOME) { $cands += @((Join-Path $env:INFA_HOME 'server\bin\impcntl.dtd'), (Join-Path $env:INFA_HOME 'server/bin/impcntl.dtd'),
                                    (Join-Path $env:INFA_HOME 'clients\PowerCenterClient\client\bin\impcntl.dtd')) }
  $Dtd = $cands | Where-Object { Test-Path $_ } | Select-Object -First 1
}
if (-not $Dtd -or -not (Test-Path $Dtd)) { Stop-Fatal 'impcntl.dtd nicht gefunden (-Dtd angeben)' }

### ---------------------------------------------------------------- Backup-Lauf bestimmen
if (-not (Test-Path $BackupDir)) { Stop-Fatal "Backup-Basisverzeichnis fehlt: $BackupDir" }
$BackupDir = (Resolve-Path $BackupDir).Path
if (-not $Run) {
  $ls = Join-Path $BackupDir 'LATEST_SUCCESS'
  if (-not (Test-Path $ls)) { Stop-Fatal "kein Lauf angegeben (-Run) und $ls fehlt" }
  $Run = (Get-Content $ls | Select-Object -First 1).Trim()
}
$RunDir = if ([IO.Path]::IsPathRooted($Run)) { $Run } else { Join-Path $BackupDir $Run }
if (-not (Test-Path $RunDir -PathType Container)) { Stop-Fatal "Backup-Lauf nicht gefunden: $RunDir" }
$RunDir = (Resolve-Path $RunDir).Path
if (Test-Path (Join-Path $RunDir 'RUNNING')) { Stop-Fatal "Backup-Lauf $RunDir laeuft noch oder wurde abgebrochen (RUNNING)" }
if (-not (Test-Path (Join-Path $RunDir 'import_order.txt')) -or -not (Test-Path (Join-Path $RunDir 'manifest.csv'))) { Stop-Fatal "import_order.txt oder manifest.csv fehlt in $RunDir" }

function Get-SafeName([string]$Name) { return ($Name -replace '[^A-Za-z0-9_.-]', '_') }
$Stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
if (-not $WorkDir) { $WorkDir = Join-Path $BackupDir ('restore_{0}_{1}' -f (Get-SafeName $Repository), $Stamp) }
$n = 1; $baseWd = $WorkDir; while (Test-Path $WorkDir) { $n++; $WorkDir = "${baseWd}_$n" }
$SrcDir = Join-Path $WorkDir 'src'; $LogDir = Join-Path $WorkDir 'log'
New-Item -ItemType Directory -Force -Path $SrcDir, $LogDir | Out-Null
$WorkDir = (Resolve-Path $WorkDir).Path; $SrcDir = (Resolve-Path $SrcDir).Path; $LogDir = (Resolve-Path $LogDir).Path
$LogFile = Join-Path $WorkDir 'restore.log'; $ReportFile = Join-Path $WorkDir 'restore_report.csv'; $PlanFile = Join-Path $WorkDir 'restore_plan.txt'
$prevCnx = $env:INFA_REPCNX_INFO
$env:INFA_REPCNX_INFO = Join-Path $WorkDir 'pmrep.cnx'
$script:Errors = 0; $script:Warnings = 0; $script:PwPlain = $null

function Write-Log([string]$Text) {
  $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Text
  Write-Host $line; Add-Content -Path $LogFile -Value $line
}
function Write-Warn([string]$Text) { $script:Warnings++; Write-Log "[WARNUNG] - $Text" }
function Add-Error([string]$Text) {
  $script:Errors++; Write-Log "[FEHLER] - $Text"
  if ($FailFast -or ($MaxErrors -gt 0 -and $script:Errors -ge $MaxErrors)) { Write-Log "[ABBRUCH] - Fehlergrenze erreicht ($($script:Errors))"; throw 'ABBRUCH' }
}
function Invoke-PmrepRaw([string[]]$PmArgs, [string]$OutFile) {
  $ErrorActionPreference = 'Continue'
  $out = & $Pmrep @PmArgs 2>&1
  $rc = $LASTEXITCODE
  [IO.File]::WriteAllLines($OutFile, [string[]]@($out | ForEach-Object { "$_" }), $Utf8NoBom)
  return $rc
}
function Connect-Repo {
  $a = @('connect', '-r', $Repository, '-d', $Domain, '-n', $User)
  if ($SecurityDomain) { $a += @('-s', $SecurityDomain) }
  if ([Environment]::GetEnvironmentVariable($PasswordVar)) { $a += @('-X', $PasswordVar) }
  elseif ($script:PwPlain) { $a += @('-x', $script:PwPlain) }
  else { return $false }
  return ((Invoke-PmrepRaw $a (Join-Path $LogDir 'connect.txt')) -eq 0)
}
function ConvertTo-XmlAttr([string]$s) { return [Security.SecurityElement]::Escape($s) }

$exitCode = 2
try {
  $mode = 'TROCKENLAUF'; if ($Execute) { $mode = 'AUSFUEHREN' }
  Write-Log "[FOLDER_RESTORE] - Modus: $mode"
  Write-Log "[INFO] - Quelle: $RunDir  Ziel-Repository: $Repository  Arbeitsverzeichnis: $WorkDir"
  $bStatus = @('SUCCESS', 'PARTIAL', 'FAILED') | Where-Object { Test-Path (Join-Path $RunDir $_) } | Select-Object -Last 1
  if ($bStatus -eq 'PARTIAL') { Write-Warn 'Backup-Lauf ist PARTIAL - fehlende Objekte siehe manifest.csv (Status FEHLER)' }
  elseif ($bStatus -ne 'SUCCESS') { Write-Warn "Backup-Lauf hat Status $(if ($bStatus) { $bStatus } else { 'unbekannt' }) - Restore nur mit Vorsicht" }

  ### ------------------------------------------------------------ Auswahl
  $order = @(Get-Content (Join-Path $RunDir 'import_order.txt') | Where-Object { $_ } | ForEach-Object {
    $c = $_ -split '\|'; if ($c.Count -ge 3) { [pscustomobject]@{ Folder = $c[0]; Rel = $c[1]; Ctrl = $c[2] } } })
  $sel = @($order | Where-Object { $Folders.Count -eq 0 -or $Folders -ccontains $_.Folder })
  if ($ObjectFilter) { $sel = @($sel | Where-Object { $_.Rel -match $ObjectFilter }) }
  foreach ($f in $Folders) { if (-not ($order | Where-Object { $_.Folder -ceq $f })) { Add-Error "Folder $f ist nicht im Backup-Lauf" } }
  if ($sel.Count -eq 0) { Write-Log '[FEHLER] - keine Dateien ausgewaehlt'; exit 2 }
  Write-Log ("[INFO] - {0} Datei(en) in {1} Folder(n) ausgewaehlt" -f $sel.Count, @($sel | Select-Object -ExpandProperty Folder -Unique).Count)

  ### ------------------------------------------------------------ Dateien bereitstellen und pruefen
  $manifest = @{}
  foreach ($m in (Import-Csv (Join-Path $RunDir 'manifest.csv') -Delimiter ';')) { $manifest[($m.datei -replace '\\', '/')] = $m }
  $prepared = @{}; $ctrlDone = @{}; $folderShared = @{}; $items = New-Object System.Collections.Generic.List[object]
  foreach ($it in $sel) {
    $rel = $it.Rel -replace '\\', '/'; $sf = $rel.Split('/')[0]
    if (-not $prepared.ContainsKey($sf)) {
      $srcFolder = Join-Path $RunDir $sf; $zip = Join-Path $RunDir "$sf.zip"; $tgz = Join-Path $RunDir "$sf.tar.gz"
      if (Test-Path $srcFolder -PathType Container) { $prepared[$sf] = 'dir' }
      elseif (Test-Path $zip) { Expand-Archive -Path $zip -DestinationPath $SrcDir -Force; $prepared[$sf] = 'archiv' }
      elseif (Test-Path $tgz) { & tar xzf $tgz -C $SrcDir; $prepared[$sf] = 'archiv' }
      else { $prepared[$sf] = 'fehlt' }
    }
    if ($prepared[$sf] -eq 'fehlt') { Add-Error "$($it.Folder): weder Verzeichnis noch Archiv $sf.zip/.tar.gz im Backup-Lauf"; continue }
    $dst = Join-Path $SrcDir $rel
    if ($prepared[$sf] -eq 'dir') {
      $src = Join-Path $RunDir $rel
      if (-not (Test-Path $src)) { Add-Error "$($it.Folder): $rel fehlt im Backup-Lauf"; continue }
      New-Item -ItemType Directory -Force -Path (Split-Path $dst) | Out-Null
      Copy-Item $src $dst -Force
      $ctrlSrc = Join-Path $RunDir $it.Ctrl; $ctrlDst = Join-Path $SrcDir $it.Ctrl
      if ((Test-Path $ctrlSrc) -and -not (Test-Path $ctrlDst)) { Copy-Item $ctrlSrc $ctrlDst }
    }
    if (-not (Test-Path $dst)) { Add-Error "$($it.Folder): $rel fehlt im Backup-Lauf"; continue }
    if (-not $NoVerify -and $manifest.ContainsKey($rel) -and $manifest[$rel].sha256 -and $manifest[$rel].sha256 -ne '-') {
      if ((Get-FileHash -Algorithm SHA256 $dst).Hash.ToLower() -ne $manifest[$rel].sha256.ToLower()) {
        Add-Error "$($it.Folder): $rel - Pruefsumme stimmt nicht mit manifest.csv ueberein, wird nicht importiert"; continue
      }
    }
    $ctrl = Join-Path $SrcDir $it.Ctrl
    if (-not $ctrlDone.ContainsKey($it.Ctrl)) {
      if (-not (Test-Path $ctrl)) { Add-Error "$($it.Folder): Control-File $($it.Ctrl) fehlt"; continue }
      # Control-File anpassen: Ziel-Repository, ggf. Check-in
      $t = [IO.File]::ReadAllText($ctrl)
      $t = [regex]::Replace($t, 'TARGETREPOSITORYNAME="[^"]*"', { param($m) 'TARGETREPOSITORYNAME="' + (ConvertTo-XmlAttr $Repository) + '"' })
      if ($Checkin) { $t = $t.Replace('CHECKIN_AFTER_IMPORT="NO"', 'CHECKIN_AFTER_IMPORT="YES" CHECKIN_COMMENTS="' + (ConvertTo-XmlAttr $Checkin) + '"') }
      [IO.File]::WriteAllText($ctrl, $t, $Utf8NoBom)
      Copy-Item $Dtd (Join-Path (Split-Path $ctrl) 'impcntl.dtd') -Force
      $ctrlDone[$it.Ctrl] = $true
    }
    if (-not $folderShared.ContainsKey($it.Folder)) { $folderShared[$it.Folder] = [bool](Select-String -Path $dst -Pattern '<FOLDER [^>]*SHARED *= *"SHARED"' -Quiet) }
    $items.Add([pscustomobject]@{ Folder = $it.Folder; Rel = $rel; Ctrl = $it.Ctrl; Src = $dst; CtrlPath = $ctrl })
  }

  ### ------------------------------------------------------------ Verbindung, Ziel-Folder
  if (-not [Environment]::GetEnvironmentVariable($PasswordVar)) {
    if ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected) {
      $sec = Read-Host -AsSecureString "Passwort fuer $User"
      $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
      try { $script:PwPlain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr); $sec.Dispose() }
    } else { Write-Log "[FEHLER] - kein Passwort: Umgebungsvariable $PasswordVar (pmpasswd-verschluesselt) setzen"; exit 2 }
  }
  if (-not (Connect-Repo)) {
    Write-Log "[FEHLER] - Verbindung zu $Repository fehlgeschlagen, siehe $(Join-Path $LogDir 'connect.txt')"
    if ([Environment]::GetEnvironmentVariable($PasswordVar)) { Write-Log "[HINWEIS] - $PasswordVar muss das mit pmpasswd verschluesselte Passwort enthalten" }
    exit 2
  }
  Write-Log "[STATUS] - verbunden mit $Repository"
  $lf = Join-Path $LogDir 'list_folders.txt'
  if ((Invoke-PmrepRaw @('listobjects', '-o', 'folder') $lf) -ne 0) { Write-Log '[FEHLER] - Folderliste nicht lesbar'; exit 2 }
  $existing = @(Get-Content $lf | ForEach-Object { $_.Trim() })
  $folderOrder = @($items | Select-Object -ExpandProperty Folder -Unique)   # Import-Reihenfolge, Shared zuerst
  $missing = @{}
  foreach ($f in $folderOrder) { if ($existing -cnotcontains $f) { $missing[$f] = $true } }

  ### ------------------------------------------------------------ Plan
  $plan = @("# Restore-Plan $Stamp - Quelle $RunDir -> Repository $Repository")
  foreach ($f in $folderOrder) {
    if (-not $missing.ContainsKey($f)) { continue }
    if ($CreateFolders) {
      $plan += ('& "{0}" createfolder -n "{1}"{2}' -f $Pmrep, $f, $(if ($folderShared[$f]) { ' -s' } else { '' }))
      Write-Log ("[INFO] - Folder $f fehlt im Ziel und wird angelegt" + $(if ($folderShared[$f]) { ' (shared)' } else { '' }))
    } else {
      $plan += "# FEHLT: Folder $f existiert im Ziel nicht (-CreateFolders) - seine Dateien werden uebersprungen"
      Add-Error "Folder $f existiert im Ziel-Repository nicht - -CreateFolders angeben oder anlegen"
    }
  }
  foreach ($i in $items) { $plan += ('& "{0}" objectimport -i "{1}" -c "{2}"' -f $Pmrep, $i.Src, $i.CtrlPath) }
  [IO.File]::WriteAllLines($PlanFile, [string[]]$plan, $Utf8NoBom)
  Write-Log "[INFO] - $($items.Count) Import(e) geplant, Plan: $PlanFile"

  $report = New-Object System.Collections.Generic.List[object]
  if (-not $Execute) {
    Write-Log '[TROCKENLAUF] - nichts importiert. Zum Ausfuehren mit -Execute erneut starten.'
    $exitCode = $(if ($script:Errors -eq 0) { 0 } else { 1 })
    exit $exitCode
  }

  ### ------------------------------------------------------------ Ausfuehren
  if (-not $Yes) {
    $answer = Read-Host ("{0} Datei(en) nach {1} importieren? Bestehende Objekte werden ersetzt. [JA eingeben]" -f $items.Count, $Repository)
    if ($answer -cne 'JA') { Write-Log '[ABBRUCH] - nichts importiert.'; $exitCode = 0; exit 0 }
  }
  foreach ($f in $folderOrder) {
    if (-not $missing.ContainsKey($f) -or -not $CreateFolders) { continue }
    $cf = @('createfolder', '-n', $f); if ($folderShared[$f]) { $cf += '-s' }
    if ((Invoke-PmrepRaw $cf (Join-Path $LogDir "createfolder_$(Get-SafeName $f).txt")) -eq 0) { Write-Log "[FOLDER] - $f angelegt"; $missing.Remove($f) }
    else { Add-Error "Folder $f konnte nicht angelegt werden, siehe log\createfolder_$(Get-SafeName $f).txt" }
  }

  $nOk = 0; $nImp = 0; $toValidate = @()
  foreach ($i in $items) {
    if ($missing.ContainsKey($i.Folder)) { $report.Add([pscustomobject]@{ folder = $i.Folder; datei = $i.Rel; import = 'UEBERSPRUNGEN'; validierung = ''; meldung = 'Folder fehlt im Ziel' }); continue }
    $nImp++
    $base = Get-SafeName $i.Rel
    $logF = Join-Path $LogDir "import_$base.log"; $outF = Join-Path $LogDir "import_$base.out"
    $rc = Invoke-PmrepRaw @('objectimport', '-i', $i.Src, '-c', $i.CtrlPath, '-l', $logF) $outF
    # Verbindungsverlust: einmal neu verbinden und wiederholen
    if ($rc -ne 0 -and (Select-String -Path $outF -Pattern 'not connected|failed to connect|repository service is not available|connection' -Quiet)) {
      if (Connect-Repo) { $rc = Invoke-PmrepRaw @('objectimport', '-i', $i.Src, '-c', $i.CtrlPath, '-l', $logF) $outF }
    }
    $all = @(Get-Content $outF -ErrorAction SilentlyContinue) + @(Get-Content $logF -ErrorAction SilentlyContinue)
    # Fehlerzeilen, aber keine Zusammenfassungen wie "0 errors"
    $errl = @($all | Where-Object { $_ -match '\berrors?\b|failed' -and $_ -notmatch '\b0 (errors?|failed)\b|no errors' })
    if ($rc -ne 0 -or $errl.Count -gt 0) {
      $msg = if ($errl.Count -gt 0) { $errl[0] -replace ';', ',' } else { "objectimport rc=$rc" }
      $report.Add([pscustomobject]@{ folder = $i.Folder; datei = $i.Rel; import = 'FEHLER'; validierung = ''; meldung = $msg })
      Add-Error "$($i.Folder): $($i.Rel) - Import fehlgeschlagen"
      continue
    }
    $ren = @($all | Where-Object { $_ -match 'renamed|rename' })
    if ($ren.Count -gt 0) {
      $report.Add([pscustomobject]@{ folder = $i.Folder; datei = $i.Rel; import = 'WARNUNG'; validierung = ''; meldung = ($ren[0] -replace ';', ',') })
      Write-Warn "$($i.Folder): $($i.Rel) - beim Import umbenannt (Duplikat?): $($ren[0])"
    } else {
      $report.Add([pscustomobject]@{ folder = $i.Folder; datei = $i.Rel; import = 'OK'; validierung = ''; meldung = '' })
    }
    $nOk++
    if ($manifest.ContainsKey($i.Rel)) { $toValidate += [pscustomobject]@{ Folder = $manifest[$i.Rel].folder; Type = $manifest[$i.Rel].typ; Name = $manifest[$i.Rel].name; Rel = $i.Rel } }
  }

  ### ------------------------------------------------------------ Validierung
  $nInv = 0
  if ($Validate) {
    foreach ($v in $toValidate | Where-Object { $_.Type.ToLower() -in 'mapping', 'mapplet', 'session', 'worklet', 'workflow' }) {
      $vo = Join-Path $LogDir ('validate_{0}_{1}.txt' -f (Get-SafeName $v.Folder), (Get-SafeName $v.Name))
      $va = @('validate', '-n', $v.Name, '-o', $v.Type, '-f', $v.Folder, '-s')
      if ($Checkin) { $va += @('-k', '-m', $Checkin) }
      $rc = Invoke-PmrepRaw $va $vo
      $row = $report | Where-Object { $_.datei -eq $v.Rel } | Select-Object -First 1
      $inv = @(Get-Content $vo | Where-Object { $_ -match '\binvalid\b' -and $_ -notmatch '\b0 invalid' })
      if ($rc -eq 0 -and $inv.Count -eq 0) { Write-Log "[VALIDIERT] - $($v.Folder): $($v.Type) $($v.Name)"; if ($row) { $row.validierung = 'GUELTIG' } }
      else {
        $nInv++; if ($row) { $row.validierung = 'UNGUELTIG' }
        Add-Error "$($v.Folder): $($v.Type) $($v.Name) ist nach dem Import ungueltig, siehe log\$(Split-Path $vo -Leaf)"
      }
    }
  }
  $vtxt = ''; if ($Validate) { $vtxt = ", $nInv ungueltig" }
  Write-Log ("[ERGEBNIS] - {0} von {1} importiert, {2} Fehler, {3} Warnungen{4}" -f $nOk, $nImp, $script:Errors, $script:Warnings, $vtxt)
  Write-Log "[ERGEBNIS] - Report: $ReportFile"
  $exitCode = $(if ($script:Errors -eq 0) { 0 } else { 1 })
}
catch {
  if ($_.Exception.Message -ne 'ABBRUCH') { Write-Log "[FEHLER] - unerwarteter Fehler: $($_.Exception.Message)" }
  $exitCode = 2
}
finally {
  if ($report) { $report | Export-Csv -Path $ReportFile -Delimiter ';' -NoTypeInformation -Encoding UTF8 }
  elseif (-not (Test-Path $ReportFile)) { Set-Content -Path $ReportFile -Value '"folder";"datei";"import";"validierung";"meldung"' }
  $script:PwPlain = $null
  Remove-Item $env:INFA_REPCNX_INFO -ErrorAction SilentlyContinue
  if ($null -eq $prevCnx) { Remove-Item Env:INFA_REPCNX_INFO -ErrorAction SilentlyContinue } else { $env:INFA_REPCNX_INFO = $prevCnx }
}
exit $exitCode
