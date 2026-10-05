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
  [string]$SourceRepository,                      # Quell-Repository fuer das Control-File (Standard: Repository; bei -NoConnect Pflicht, falls Repository fehlt)
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
if (-not $Repository -and -not $SourceRepository) {
  throw 'Repository-Name fehlt: -Repository (oder bei -NoConnect mindestens -SourceRepository) angeben - wird fuer das Control-File gebraucht.'
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
$prevCnxInfo = $env:INFA_REPCNX_INFO
$createdPassword = $false
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
      $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
      try {
        $env:INFA_PASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        $createdPassword = $true
      } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        $sec.Dispose()
      }
    }
    $conn = @('connect', '-r', $Repository, '-d', $Domain, '-n', $User, '-X', 'INFA_PASSWORD')
    if ($SecurityDomain) { $conn += @('-s', $SecurityDomain) }
    $connected = Invoke-Pmrep $conn (Join-Path $LogDir 'connect.txt')
    # selbst abgefragtes Passwort sofort wieder entfernen (nur fuer connect noetig)
    if ($createdPassword) { Remove-Item Env:INFA_PASSWORD -ErrorAction SilentlyContinue; $createdPassword = $false }
    if (-not $connected) {
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
      # ORPHAN nur, wenn die Liste des Referenz-Ordners gelesen werden konnte und das Objekt fehlt
      if ($null -eq $refCache[$key]) { $entry.Status = 'REF_CHECK_FAILED' }
      elseif (-not ($refCache[$key] -contains $entry.RefName)) { $entry.Status = 'ORPHAN' }
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
  $deletes = @(); $renames = @(); $plan = @(); $reimport = @()
  $nDel = 0; $nMan = 0; $nRen = 0; $nOk = 0; $nReimp = 0
  $act = @{}; $par = @{}; $hnt = @{}
  $ReimportFile = Join-Path $OutDir 'reimport_plan.txt'

  # Eltern-Objekte aus dem deps-Log: Objekte mit Type/Name
  function Get-ParentList([string]$Type, [string]$Name) {
    $f = Join-Path $LogDir ("deps_{0}_{1}.txt" -f $Type, (Get-SafeName $Name))
    if (-not (Test-Path $f)) { return @() }
    $res = @()
    foreach ($line in Get-Content $f) {
      $tok = @($line.Trim() -split '\s+' | Where-Object { $_ })
      if ($tok.Count -lt 2 -or $tok[0].ToLower() -notmatch '^(mapping|mapplet|session|worklet|workflow|transformation|target|source|task)$') { continue }
      $n = @($tok[1..($tok.Count - 1)] | Where-Object { $_ -ne 'reusable' -and $_ -ne 'non-reusable' })
      if ($n.Count -gt 0) { $res += [pscustomobject]@{ Type = $tok[0].ToLower(); Name = $n[0] } }
    }
    return , $res
  }

  # gestufter Ablauf (Variante A) fuer einen verwaisten Shortcut, der noch verwendet wird - wird nie automatisch ausgefuehrt
  function Get-ReimportBlock($e, $count) {
    $pl = Get-ParentList $e.Type $e.Name
    $b = @("### $($e.Type) $($e.Name) - verwaist, verwendet von $count Objekt(en)", '# 1. Verwender sichern')
    foreach ($p in $pl) { $b += ('& "{0}" objectexport -o {1} -f "{2}" -n "{3}" -m -s -b -r -u "backup_{1}_{4}.xml"' -f $Pmrep, $p.Type, $Folder, $p.Name, (Get-SafeName $p.Name)) }
    $b += '# 2. Verwender loeschen, danach den verwaisten Shortcut'
    $b += '#    (Sessions/Workflows, die diese Mappings nutzen, muessen im Import-XML aus Schritt 3 enthalten sein)'
    foreach ($p in $pl) {
      if ($p.Type -eq 'mapping' -or $p.Type -eq 'mapplet') { $b += ('& "{0}" deleteobject -o {1} -f "{2}" -n "{3}"' -f $Pmrep, $p.Type, $Folder, $p.Name) }
      else { $b += "#   $($p.Type) $($p.Name): wird ueber den Re-Import ersetzt" }
    }
    if ($deletable -contains $e.Type) { $b += ('& "{0}" deleteobject -o {1} -f "{2}" -n "{3}"' -f $Pmrep, $e.Type, $Folder, $e.Name) }
    else { $b += "# Designer: $($e.Type) $($e.Name) loeschen (pmrep deleteobject unterstuetzt Typ $($e.Type) nicht)" }
    $b += '# 3. Re-Import aus dem Original-Export (Workflow-Ebene, exportiert mit -m -s -b -r)'
    $b += ('& "{0}" objectimport -i "<ORIGINAL_EXPORT.xml>" -c "{1}"' -f $Pmrep, $CtrlFile)
    $b += "# 4. ueberzaehlige Zahlen-Duplikate von $(Get-ShortName $e.Type $e.Name) loeschen, sobald unbenutzt; Mappings/Sessions validieren"
    $b += ''
    return $b
  }

  # Durchlauf 1: verwaiste / unklare Shortcuts bewerten
  foreach ($e in $analysis | Where-Object { 'ORPHAN', 'EXPORT_FAILED', 'REF_CHECK_FAILED' -contains $_.Status }) {
    $k = "$($e.Type)|$($e.Name)"
    $p = Get-ParentCount $e.Type $e.Name $e.Sub; $par[$k] = "$p"
    if ($e.Status -eq 'REF_CHECK_FAILED') {
      $act[$k] = 'MANUELL_PRUEFEN'; $hnt[$k] = "Referenz-Ordner $($e.RefFolder) nicht lesbar (fehlt oder pmrep-Fehler) - siehe log/list_*"
    } elseif ($e.Status -eq 'EXPORT_FAILED' -and -not $IncludeSuspect) {
      $act[$k] = 'MANUELL_PRUEFEN'; $hnt[$k] = 'Export fehlgeschlagen - Shortcut-Status unbekannt (-IncludeSuspect zum Loeschen)'
    } elseif ("$p" -eq '?') {
      $act[$k] = 'MANUELL_PRUEFEN'; $hnt[$k] = 'Abhaengigkeiten nicht ermittelbar - siehe log/deps_*'
    } elseif ([int]$p -gt 0) {
      $act[$k] = 'REIMPORT'; $hnt[$k] = "wird noch von $p Objekt(en) verwendet - gestufter Ablauf in reimport_plan.txt"
      $reimport += Get-ReimportBlock $e $p; $nReimp++
    } elseif ($deletable -notcontains $e.Type) {
      $act[$k] = 'MANUELL_PRUEFEN'; $hnt[$k] = "pmrep deleteobject unterstuetzt Typ $($e.Type) nicht - im Designer loeschen"
    } else {
      $act[$k] = 'LOESCHEN'
      $deletes += $e
      $plan += ('& "{0}" deleteobject -o {1} -f "{2}" -n "{3}"' -f $Pmrep, $e.Type, $Folder, $e.Name)
      $nDel++
    }
    if ($act[$k] -eq 'MANUELL_PRUEFEN') { $nMan++ }
  }

  # Durchlauf 2: Report in Original-Reihenfolge, Duplikate einordnen
  $rows = @()
  foreach ($e in $analysis) {
    $k = "$($e.Type)|$($e.Name)"
    $action = 'KEINE'; if ($act.ContainsKey($k)) { $action = $act[$k] }
    $parents = "$($par[$k])"; $hint = "$($hnt[$k])"
    if ($e.Status -eq 'OK' -or $e.Status -eq 'GLOBAL_UNCHECKED') {
      $nOk++
      if ($e.Name -match '^(.*[^0-9])([0-9]+)$') {
        $base = $Matches[1]; $bact = $act["$($e.Type)|$base"]
        $from = Get-ShortName $e.Type $e.Name; $to = Get-ShortName $e.Type $base
        if ($bact -eq 'LOESCHEN') {
          $action = 'UMBENENNEN_IM_DESIGNER'; $hint = "nach Loeschen von $to umbenennen: $from -> $to"
          $renames += "# Designer ($($e.Type)): $from in $to umbenennen (pmrep kann nicht umbenennen)"
          $nRen++
        } elseif ($bact) {
          $action = 'NACH_BASIS_PRUEFEN'; $hint = "Duplikat von $to ($bact) - erst $to klaeren, dann $from loeschen oder umbenennen"
          $nMan++
        }
      }
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
  if ($reimport.Count -gt 0) { [IO.File]::WriteAllLines($ReimportFile, [string[]]$reimport, $Utf8NoBom) }

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
  # verwaiste Shortcuts duerfen beim Import nicht mehr existieren (REUSE wuerde sie behalten,
  # REPLACE ist bei Shortcuts nicht moeglich) -> vorher loeschen, siehe plan.txt / reimport_plan.txt
  foreach ($e in $analysis | Where-Object { 'ORPHAN', 'EXPORT_FAILED', 'REF_CHECK_FAILED' -contains $_.Status }) {
    $x += ('  <!-- vor dem Import loeschen/klaeren: {0} {1} ({2}) -->' -f $e.Type, ($e.Name -replace '--', '- -'), $e.Status)
  }
  $x += '  <RESOLVECONFLICT>'
  # gueltige Shortcuts nie ersetzen, sondern wiederverwenden (ohne Zahlen-Suffix-Duplikate)
  foreach ($e in $analysis | Where-Object { $_.Status -eq 'OK' -or $_.Status -eq 'GLOBAL_UNCHECKED' }) {
    $name = $e.Name
    $base = Get-DupBase $e.Type $e.Name
    if ($base) {
      # Duplikat: nur wenn es nach dem Loeschen des Originals auf den Basisnamen umbenannt wird
      if ($act["$($e.Type)|$base"] -ne 'LOESCHEN') { continue }
      $name = $base
    }
    $sn = Get-ShortName $e.Type $name
    $dbd = ''
    if ($e.Type -eq 'source' -and $name -ne $sn) { $dbd = ' DBDNAME="{0}"' -f (ConvertTo-XmlAttr $name.Substring(0, $name.IndexOf('.'))) }
    $otn = $e.ObjSub; if (-not $otn) { $otn = $e.Type }
    $x += ('    <SPECIFICOBJECT NAME="{0}"{1} OBJECTTYPENAME="{2}" FOLDERNAME="{3}" REPOSITORYNAME="{4}" RESOLUTION="REUSE"/>' -f
      (ConvertTo-XmlAttr $sn), $dbd, (ConvertTo-XmlAttr $otn), (ConvertTo-XmlAttr $Folder), (ConvertTo-XmlAttr $SourceRepository))
  }
  $x += @('    <TYPEOBJECT OBJECTTYPENAME="All" RESOLUTION="REPLACE"/>', '  </RESOLVECONFLICT>', '</IMPORTPARAMS>')
  [IO.File]::WriteAllLines($CtrlFile, [string[]]$x, $Utf8NoBom)

  ### ------------------------------------------------------------ 5. Zusammenfassung
  Write-Log ''
  Write-Log ("[ERGEBNIS] - Shortcuts gueltig: {0} | zu loeschen: {1} | Re-Import noetig: {2} | manuell pruefen: {3} | umbenennen (Designer): {4}" -f $nOk, $nDel, $nReimp, $nMan, $nRen)
  Write-Log "[ERGEBNIS] - Report:       $Report"
  Write-Log "[ERGEBNIS] - Plan:         $PlanFile"
  Write-Log "[ERGEBNIS] - Control-File: $CtrlFile"
  if ($reimport.Count -gt 0) { Write-Log "[ERGEBNIS] - Re-Import:    $ReimportFile  (gestufter Ablauf, wird nie automatisch ausgefuehrt)" }
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
  # nur selbst gesetzte Umgebungswerte zuruecknehmen
  if ($createdPassword) { Remove-Item Env:INFA_PASSWORD -ErrorAction SilentlyContinue }
  if (-not $NoConnect) {
    if ($null -eq $prevCnxInfo) { Remove-Item Env:INFA_REPCNX_INFO -ErrorAction SilentlyContinue } else { $env:INFA_REPCNX_INFO = $prevCnxInfo }
  }
}
