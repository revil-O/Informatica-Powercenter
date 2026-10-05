<#
.SYNOPSIS
  Findet verwaiste Shortcuts (ohne gueltige Referenz in den Shared Folder) und
  Duplikate mit Zahlen-Suffix (z.B. Shortcut_to_X1), die durch einen
  fehlgeschlagenen Import mit REPLACE entstanden sind.

.DESCRIPTION
  Standard ist TROCKENLAUF: es wird nur analysiert und ein Plan geschrieben.
  Geloescht wird ausschliesslich mit -Execute (und Bestaetigung).
  Gegenstueck zu shortcut_repair.sh (gleiche Logik, gleiche Ausgabedateien).
  Laeuft mit Windows PowerShell 5.1 und PowerShell 7.

  use it at own risk ! vorher Repository-Backup ziehen !

.EXAMPLE
  .\shortcut_repair.ps1 -Repository PM_PROD_REPO -Domain Prod_Domain -User admin -Folder DWH

.EXAMPLE
  .\shortcut_repair.ps1 -Repository PM_PROD_REPO -Domain Prod_Domain -User admin -Folder DWH -Execute

  Passwort: Umgebungsvariable INFA_PASSWORD, sonst interaktive Abfrage.
#>
[CmdletBinding()]
param(
  [string]$Repository,
  [string]$Domain,
  [string]$User,
  [Parameter(Mandatory = $true)][string]$Folder,
  [string]$SecurityDomain,
  [string[]]$SharedFolder = @(),                  # Shared Folder fuer das Control-File (Standard: aus den Shortcuts)
  [string]$SourceRepository,                      # Quell-Repository fuer das Control-File (Standard: Repository)
  [string[]]$Types = @('source', 'target', 'mapplet', 'transformation'),
  [string]$ObjectFile,                            # Objektliste statt listobjects; Zeilen: typ|name[|subtyp]
  [string]$Pmrep,                                 # Pfad zu pmrep(.exe)
  [string]$OutDir,
  [switch]$NoConnect,
  [switch]$IncludeSuspect,                        # auch Objekte loeschen, deren Export fehlschlug
  [switch]$Execute,
  [switch]$Yes
)

$ErrorActionPreference = 'Stop'

if (-not $NoConnect -and (-not $Repository -or -not $Domain -or -not $User)) {
  throw 'Repository, Domain und User sind Pflicht (oder -NoConnect fuer eine bestehende Verbindung).'
}
if (-not $SourceRepository) { $SourceRepository = $Repository }
# "-Types source,target" kommt je nach Aufruf (powershell -File) als ein String an
$Types = @($Types | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ })
$SharedFolder = @($SharedFolder | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

### ---------------------------------------------------------------- pmrep finden
if (-not $Pmrep) {
  $cmd = Get-Command pmrep -ErrorAction SilentlyContinue
  if ($cmd) { $Pmrep = $cmd.Source }
  elseif ($env:INFA_HOME) {
    foreach ($c in @('server\bin\pmrep.exe', 'server/bin/pmrep', 'clients\PowerCenterClient\client\bin\pmrep.exe')) {
      $p = Join-Path $env:INFA_HOME $c
      if (Test-Path $p) { $Pmrep = $p; break }
    }
  }
  if (-not $Pmrep) { throw 'pmrep nicht gefunden (-Pmrep oder PATH/INFA_HOME setzen).' }
}

if (-not $OutDir) { $OutDir = Join-Path (Get-Location) ('shortcut_repair_' + (Get-Date -Format 'yyyyMMdd_HHmmss')) }
New-Item -ItemType Directory -Force -Path (Join-Path $OutDir 'xml'), (Join-Path $OutDir 'log') | Out-Null
$OutDir = (Resolve-Path $OutDir).Path
$LogDir = Join-Path $OutDir 'log'
$XmlDir = Join-Path $OutDir 'xml'
$LogFile = Join-Path $OutDir 'run.log'
$Report = Join-Path $OutDir 'report.csv'
$PlanFile = Join-Path $OutDir 'plan.txt'
$CtrlFile = Join-Path $OutDir 'ctrl_reimport.xml'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# eigene Verbindungsdatei, damit kein fremdes pmrep.cnx ueberschrieben wird
if (-not $NoConnect) { $env:INFA_REPCNX_INFO = Join-Path $OutDir 'pmrep.cnx' }

function Write-Log([string]$Text) {
  Write-Host $Text
  Add-Content -Path $LogFile -Value $Text
}

# pmrep aufrufen, Ausgabe in Datei; liefert $true bei Exitcode 0
function Invoke-Pmrep([string[]]$PmArgs, [string]$OutFile) {
  # PS 5.1: stderr eines nativen Programms wird sonst bei 'Stop' zum Abbruch
  $ErrorActionPreference = 'Continue'
  $out = & $Pmrep @PmArgs 2>&1
  $rc = $LASTEXITCODE
  [IO.File]::WriteAllLines($OutFile, [string[]]@($out | ForEach-Object { "$_" }), $Utf8NoBom)
  return ($rc -eq 0)
}

function Get-SafeName([string]$Name) { return ($Name -replace '[^A-Za-z0-9_.-]', '_') }

# Name ohne DBD-Praefix (nur bei Sources: DBD.NAME)
function Get-ShortName([string]$Type, [string]$Name) {
  if ($Type -eq 'source' -and $Name.Contains('.')) { return $Name.Substring($Name.IndexOf('.') + 1) }
  return $Name
}

# Attribute eines Elements lesen (Informatica schreibt NAME ="x")
function Get-Attrs([string]$Element) {
  $h = @{}
  foreach ($m in [regex]::Matches($Element, '([A-Za-z_]+)\s*=\s*"([^"]*)"')) { $h[$m.Groups[1].Value] = $m.Groups[2].Value }
  return $h
}

# pmrep listobjects -> Objekte mit Type/Name/Sub; $null wenn fehlgeschlagen
function Get-FolderObjects([string]$Type, [string]$FolderName) {
  $raw = Join-Path $LogDir ("list_{0}_{1}.txt" -f (Get-SafeName $FolderName), $Type)
  if (-not (Invoke-Pmrep @('listobjects', '-o', $Type, '-f', $FolderName, '-c', '|') $raw)) { return $null }
  $result = @()
  foreach ($line in Get-Content $raw) {
    $cols = @($line -split '\|' | ForEach-Object { $_.Trim() })
    if ($cols.Count -lt 2 -or $cols[0].ToLower() -ne $Type) { continue }
    $vals = @($cols[1..($cols.Count - 1)] | Where-Object { $_ -and $_ -ne 'reusable' -and $_ -ne 'non-reusable' })
    if ($vals.Count -eq 0) { continue }
    $name = $vals[0]; $sub = ''
    if ($vals.Count -gt 1) { $sub = $vals[1] }
    # bei Transformationen steht der Subtyp i.d.R. vor dem Namen
    if ($Type -eq 'transformation' -and $sub) { $tmp = $name; $name = $sub; $sub = $tmp }
    $result += [pscustomobject]@{ Type = $Type; Name = $name; Sub = $sub }
  }
  return , $result
}

# Anzahl der Eltern-Objekte (Mappings, Sessions, ...) - '?' wenn unbekannt
function Get-ParentCount([string]$Type, [string]$Name, [string]$Sub) {
  $out = Join-Path $LogDir ("deps_{0}_{1}.txt" -f $Type, (Get-SafeName $Name))
  $a = @('listobjectdependencies', '-n', $Name, '-o', $Type, '-f', $Folder, '-p', 'parents')
  if ($Sub) { $a += @('-t', $Sub) }
  if (-not (Invoke-Pmrep $a $out)) { return '?' }
  return @(Get-Content $out | Where-Object { $_ -match '^\s*(mapping|mapplet|session|worklet|workflow|transformation|target|source|task)[\s|]' }).Count
}

function ConvertTo-XmlAttr([string]$s) { return [Security.SecurityElement]::Escape($s) }

### ---------------------------------------------------------------- Start
$mode = 'TROCKENLAUF'; if ($Execute) { $mode = 'AUSFUEHREN' }
$repoText = $Repository; if (-not $repoText) { $repoText = '(bestehende Verbindung)' }
Write-Log ("[SHORTCUT_REPAIR] - {0} - Modus: {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $mode)
Write-Log ("[INFO] - Repository={0} Folder={1} Typen={2} Ausgabe={3}" -f $repoText, $Folder, ($Types -join ','), $OutDir)

try {
  if (-not $NoConnect) {
    if (-not $env:INFA_PASSWORD) {
      $sec = Read-Host -AsSecureString ("Passwort fuer {0}" -f $User)
      $env:INFA_PASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
    }
    $conn = @('connect', '-r', $Repository, '-d', $Domain, '-n', $User, '-X', 'INFA_PASSWORD')
    if ($SecurityDomain) { $conn += @('-s', $SecurityDomain) }
    if (-not (Invoke-Pmrep $conn (Join-Path $LogDir 'connect.txt'))) {
      Write-Log ("[FEHLER] - Verbindung fehlgeschlagen, siehe {0}" -f (Join-Path $LogDir 'connect.txt'))
      exit 1
    }
    Write-Log "[STATUS] - verbunden mit $Repository"
  }

  ### ------------------------------------------------------------ 1. Objekte sammeln
  $objects = @()
  if ($ObjectFile) {
    foreach ($line in Get-Content $ObjectFile) {
      if ($line -match '^\s*(#|$)') { continue }
      $c = $line.Trim() -split '\|'
      $sub = ''; if ($c.Count -gt 2) { $sub = $c[2] }
      $objects += [pscustomobject]@{ Type = $c[0].ToLower(); Name = $c[1]; Sub = $sub }
    }
  } else {
    foreach ($t in $Types) {
      $list = Get-FolderObjects $t $Folder
      if ($null -eq $list) { Write-Log "[WARNUNG] - listobjects fuer Typ $t fehlgeschlagen (siehe log/list_*_$t.txt)"; continue }
      $objects += $list
    }
  }
  $objects | ForEach-Object { "{0}|{1}|{2}" -f $_.Type, $_.Name, $_.Sub } | Set-Content (Join-Path $OutDir 'objects.txt')
  Write-Log ("[INFO] - {0} Objekte im Ordner {1} gefunden" -f $objects.Count, $Folder)

  ### ------------------------------------------------------------ 2. Shortcuts analysieren
  $analysis = @()
  $refCache = @{}
  foreach ($o in $objects) {
    $xml = Join-Path $XmlDir ("{0}_{1}.xml" -f $o.Type, (Get-SafeName $o.Name))
    $a = @('objectexport', '-o', $o.Type, '-n', $o.Name, '-f', $Folder, '-u', $xml)
    if ($o.Sub) { $a += @('-t', $o.Sub) }
    $ok = Invoke-Pmrep $a (Join-Path $LogDir ("export_{0}_{1}.txt" -f $o.Type, (Get-SafeName $o.Name)))
    $entry = [pscustomobject]@{ Type = $o.Type; Name = $o.Name; Sub = $o.Sub; Status = ''; RefRepo = ''; RefFolder = ''; RefName = ''; RefType = ''; ObjSub = '' }
    if (-not $ok -or -not (Test-Path $xml) -or (Get-Item $xml).Length -eq 0) {
      $entry.Status = 'EXPORT_FAILED'; $analysis += $entry; continue
    }
    $sn = Get-ShortName $o.Type $o.Name
    $sc = $null
    foreach ($m in [regex]::Matches([IO.File]::ReadAllText($xml), '<SHORTCUT\s[^>]*>')) {
      $attrs = Get-Attrs $m.Value
      if ($attrs['NAME'] -eq $sn) { $sc = $attrs; break }
    }
    if ($null -eq $sc) { continue }   # kein Shortcut -> uninteressant

    $entry.RefRepo = "$($sc['REPOSITORYNAME'])"; $entry.RefFolder = "$($sc['FOLDERNAME'])"
    $entry.RefName = "$($sc['REFOBJECTNAME'])"; $entry.RefType = "$($sc['REFERENCETYPE'])"; $entry.ObjSub = "$($sc['OBJECTSUBTYPE'])"
    $entry.Status = 'OK'
    if ($entry.RefType -eq 'GLOBAL') {
      $entry.Status = 'GLOBAL_UNCHECKED'
    } elseif (-not $entry.RefFolder -or -not $entry.RefName) {
      $entry.Status = 'ORPHAN'
    } else {
      $key = "$($o.Type)|$($entry.RefFolder)"
      if (-not $refCache.ContainsKey($key)) {
        $l = Get-FolderObjects $o.Type $entry.RefFolder
        if ($null -eq $l) { $refCache[$key] = $null }
        else { $refCache[$key] = @($l | ForEach-Object { Get-ShortName $o.Type $_.Name }) }
      }
      if ($null -eq $refCache[$key] -or -not ($refCache[$key] -contains $entry.RefName)) { $entry.Status = 'ORPHAN' }
    }
    $analysis += $entry
  }
  $analysis | ForEach-Object { ($_.Type, $_.Name, $_.Sub, $_.Status, $_.RefRepo, $_.RefFolder, $_.RefName, $_.RefType, $_.ObjSub) -join '|' } |
    Set-Content (Join-Path $OutDir 'analysis.txt')

  ### ------------------------------------------------------------ 3. Plan erstellen
  $seen = @{}
  foreach ($e in $analysis) { $seen["$($e.Type)|$($e.Name)"] = $e.Status }
  # ist Name ein Zahlen-Suffix-Duplikat eines vorhandenen Shortcuts? -> Basisname, sonst $null
  function Get-DupBase([string]$Type, [string]$Name) {
    if ($Name -match '^(.*[^0-9])([0-9]+)$' -and $seen.ContainsKey("$Type|$($Matches[1])")) { return $Matches[1] }
    return $null
  }

  $deletable = @('source', 'target', 'mapplet')
  $rows = @(); $deletes = @(); $renames = @(); $plan = @()
  $nDel = 0; $nMan = 0; $nRen = 0; $nOk = 0
  foreach ($e in $analysis) {
    $parents = ''; $action = 'KEINE'; $hint = ''
    if ($e.Status -eq 'OK' -or $e.Status -eq 'GLOBAL_UNCHECKED') {
      $nOk++
      $base = Get-DupBase $e.Type $e.Name
      if ($base -and ($seen["$($e.Type)|$base"] -eq 'ORPHAN' -or $seen["$($e.Type)|$base"] -eq 'EXPORT_FAILED')) {
        $from = Get-ShortName $e.Type $e.Name; $to = Get-ShortName $e.Type $base
        $action = 'UMBENENNEN_IM_DESIGNER'
        $hint = "nach Loeschen von $to umbenennen: $from -> $to"
        $renames += "# Designer ($($e.Type)): $from in $to umbenennen (pmrep kann nicht umbenennen)"
        $nRen++
      }
    } elseif ($e.Status -eq 'ORPHAN' -or $e.Status -eq 'EXPORT_FAILED') {
      $parents = Get-ParentCount $e.Type $e.Name $e.Sub
      if ($e.Status -eq 'EXPORT_FAILED' -and -not $IncludeSuspect) {
        $action = 'MANUELL_PRUEFEN'; $hint = 'Export fehlgeschlagen - Shortcut-Status unbekannt (-IncludeSuspect zum Loeschen)'
      } elseif ($deletable -notcontains $e.Type) {
        $action = 'MANUELL_PRUEFEN'; $hint = "pmrep deleteobject unterstuetzt Typ $($e.Type) nicht - im Designer loeschen"
      } elseif ("$parents" -eq '?') {
        $action = 'MANUELL_PRUEFEN'; $hint = 'Abhaengigkeiten nicht ermittelbar - siehe log/deps_*'
      } elseif ($parents -gt 0) {
        $action = 'MANUELL_PRUEFEN'; $hint = "wird noch von $parents Objekt(en) verwendet - Mappings neu importieren (ctrl_reimport.xml)"
      } else {
        $action = 'LOESCHEN'
        $deletes += $e
        $plan += ('& "{0}" deleteobject -o {1} -f "{2}" -n "{3}"' -f $Pmrep, $e.Type, $Folder, $e.Name)
        $nDel++
      }
      if ($action -eq 'MANUELL_PRUEFEN') { $nMan++ }
    }
    $rows += [pscustomobject]@{
      typ = $e.Type; name = $e.Name; subtyp = $e.Sub; status = $e.Status; ref_repository = $e.RefRepo
      ref_folder = $e.RefFolder; ref_objekt = $e.RefName; verwendet_von = $parents; aktion = $action; hinweis = $hint
    }
  }
  # Reihenfolge im Plan: erst loeschen, dann umbenennen
  $plan += $renames
  if ($rows.Count -gt 0) {
    $rows | Export-Csv -Path $Report -Delimiter ';' -NoTypeInformation -Encoding UTF8
  } else {
    Set-Content -Path $Report -Value '"typ";"name";"subtyp";"status";"ref_repository";"ref_folder";"ref_objekt";"verwendet_von";"aktion";"hinweis"'
  }
  [IO.File]::WriteAllLines($PlanFile, [string[]]$plan, $Utf8NoBom)

  ### ------------------------------------------------------------ 4. Control-File fuer Re-Import (Variante A)
  $targetRepo = $Repository; if (-not $targetRepo) { $targetRepo = $SourceRepository }
  $shared = @($SharedFolder + @($analysis | Where-Object { $_.Status -eq 'OK' -and $_.RefFolder } | ForEach-Object { $_.RefFolder }) |
    Sort-Object -Unique)
  $x = @('<?xml version="1.0" encoding="UTF-8"?>',
         '<!DOCTYPE IMPORTPARAMS SYSTEM "impcntl.dtd">',
         '<!-- erzeugt von shortcut_repair.ps1 - vor Verwendung pruefen! -->',
         '<IMPORTPARAMS CHECKIN_AFTER_IMPORT="NO" RETAIN_GENERATED_VALUE="YES">')
  foreach ($f in @($Folder) + $shared) {
    $x += ('  <FOLDERMAP SOURCEFOLDERNAME="{0}" SOURCEREPOSITORYNAME="{1}" TARGETFOLDERNAME="{0}" TARGETREPOSITORYNAME="{2}"/>' -f
      (ConvertTo-XmlAttr $f), (ConvertTo-XmlAttr $SourceRepository), (ConvertTo-XmlAttr $targetRepo))
  }
  $x += '  <RESOLVECONFLICT>'
  # Shortcuts nie ersetzen, sondern wiederverwenden (Basisname, ohne Zahlen-Suffix-Duplikate)
  foreach ($e in $analysis | Where-Object { $_.Status -ne 'EXPORT_FAILED' }) {
    if (Get-DupBase $e.Type $e.Name) { continue }
    $sn = Get-ShortName $e.Type $e.Name
    $dbd = ''
    if ($e.Type -eq 'source' -and $e.Name -ne $sn) { $dbd = ' DBDNAME="{0}"' -f (ConvertTo-XmlAttr $e.Name.Substring(0, $e.Name.IndexOf('.'))) }
    $otn = $e.ObjSub; if (-not $otn) { $otn = $e.Type }
    $x += ('    <SPECIFICOBJECT NAME="{0}"{1} OBJECTTYPENAME="{2}" FOLDERNAME="{3}" REPOSITORYNAME="{4}" RESOLUTION="REUSE"/>' -f
      (ConvertTo-XmlAttr $sn), $dbd, (ConvertTo-XmlAttr $otn), (ConvertTo-XmlAttr $Folder), (ConvertTo-XmlAttr $SourceRepository))
  }
  $x += @('    <TYPEOBJECT OBJECTTYPENAME="All" RESOLUTION="REPLACE"/>', '  </RESOLVECONFLICT>', '</IMPORTPARAMS>')
  [IO.File]::WriteAllLines($CtrlFile, [string[]]$x, $Utf8NoBom)

  ### ------------------------------------------------------------ 5. Zusammenfassung
  Write-Log ''
  Write-Log ("[ERGEBNIS] - Shortcuts gueltig: {0} | zu loeschen: {1} | manuell pruefen: {2} | umbenennen (Designer): {3}" -f $nOk, $nDel, $nMan, $nRen)
  Write-Log "[ERGEBNIS] - Report:       $Report"
  Write-Log "[ERGEBNIS] - Plan:         $PlanFile"
  Write-Log "[ERGEBNIS] - Control-File: $CtrlFile"
  if ($plan.Count -gt 0) { Write-Log ''; Write-Log '----- Plan -----'; $plan | ForEach-Object { Write-Log $_ }; Write-Log '----------------' }

  if (-not $Execute) {
    Write-Log ''
    Write-Log '[TROCKENLAUF] - nichts geaendert. Zum Ausfuehren mit -Execute erneut starten.'
    exit 0
  }

  ### ------------------------------------------------------------ 6. Ausfuehren
  if ($nDel -eq 0) { Write-Log '[INFO] - nichts zu loeschen.'; exit 0 }
  if (-not $Yes) {
    $answer = Read-Host ("{0} Objekt(e) in {1} loeschen? Repository-Backup vorhanden? [JA eingeben]" -f $nDel, $Folder)
    if ($answer -cne 'JA') { Write-Log '[ABBRUCH] - nichts geloescht.'; exit 0 }
  }
  $nOkDel = 0; $nFail = 0
  foreach ($d in $deletes) {
    $lf = Join-Path $LogDir ("delete_{0}_{1}.txt" -f $d.Type, (Get-SafeName $d.Name))
    if (Invoke-Pmrep @('deleteobject', '-o', $d.Type, '-f', $Folder, '-n', $d.Name) $lf) {
      Write-Log "[GELOESCHT] - $($d.Type) $($d.Name)"; $nOkDel++
    } else {
      Write-Log "[FEHLER] - $($d.Type) $($d.Name) nicht geloescht, siehe $lf"; $nFail++
    }
  }
  Write-Log ''
  Write-Log ("[ERGEBNIS] - geloescht: {0} | Fehler: {1}" -f $nOkDel, $nFail)
  Write-Log '[HINWEIS] - versioniertes Repository: geloeschte Objekte einchecken (pmrep checkin / Designer), ggf. purgeversion.'
  if ($nRen -gt 0) { Write-Log "[HINWEIS] - jetzt die $nRen Duplikat(e) im Designer umbenennen und Mappings validieren (siehe Plan)." }
  if ($nFail -gt 0) { exit 1 }
  exit 0
}
finally {
  if (-not $NoConnect -and $env:INFA_REPCNX_INFO -and (Test-Path $env:INFA_REPCNX_INFO)) { Remove-Item $env:INFA_REPCNX_INFO -Force }
}
