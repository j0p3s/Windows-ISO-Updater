$ErrorActionPreference = 'Stop'
$fails = 0
function Check($n, $c) { if ($c) { Microsoft.PowerShell.Utility\Write-Host "PASS $n" } else { Microsoft.PowerShell.Utility\Write-Host "FAIL $n"; $script:fails++ } }
$tokens = $null; $errs = $null
$ast = [Management.Automation.Language.Parser]::ParseFile("$PSScriptRoot/v2body.ps1", [ref]$tokens, [ref]$errs)
Check 'generated PowerShell parses' ($errs.Count -eq 0)
foreach ($f in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)) { . ([scriptblock]::Create($f.Extent.Text)) }
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('w10u_images_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
$env:SystemDrive = $tmp; $env:SystemRoot = $tmp
$Script:Cfg = Get-DefaultSettings; $Script:Cfg.WorkDir = Join-Path $tmp 'work'; Initialize-Paths
$Script:S = New-State
$Script:Sync = [hashtable]::Synchronized(@{ Queue = (New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]') })
$Script:Calls = New-Object 'System.Collections.Generic.List[string]'
$Script:FailExport = $false; $Script:WrongCount = $false; $Script:Store = $false; $Script:Free = 100GB
function Get-FreeBytes { $Script:Free }
function Get-ServicingDism { 'dism.exe' }
function Get-ImageList($File) {
    if ((Split-Path $File -Leaf) -match '^[a-f0-9]{32}\.') {
        if ($Script:WrongCount) { return ,@() }
        $count = if ($Script:Store) { 1 } else { 2 }
        return ,@(1..$count | ForEach-Object { @{ Index = $_ } })
    }
    if ($Script:Store) {
        return ,@(@{ Index = 1; Name = 'Windows Setup Media'; Edition = ''; Build = 19041; Size = 1MB },
                  @{ Index = 2; Name = 'Windows PE'; Edition = 'WindowsPE'; Build = 19041; Size = 1MB },
                  @{ Index = 3; Name = 'Windows Setup'; Edition = 'WindowsPE'; Build = 19041; Size = 1MB },
                  @{ Index = 4; Name = 'Windows 10 Pro'; Edition = 'Professional'; Build = 19041; Size = 1MB })
    }
    return ,@(@{ Index = 1; Name = 'Home'; Edition = 'Core'; Build = 19041; Size = 1MB }, @{ Index = 2; Name = 'Pro'; Edition = 'Professional'; Build = 19041; Size = 1MB })
}
function Invoke-Dism($Arguments) {
    $Script:Calls.Add($Arguments)
    if ($Arguments -match '/DestinationImageFile:"([^"]+)"') { Set-Content -LiteralPath $Matches[1] 'image' }
    if ($Script:FailExport) { throw 'export failed' }
}
function Failure([scriptblock]$Action) { try { & $Action; return '' } catch { return $_.Exception.Message } }
try {
    $esd = Join-Path $tmp 'source.esd'; $wim = Join-Path $tmp 'source.wim'
    Set-Content $esd 'original'; Set-Content $wim 'original'
    $out = Join-Path $tmp 'result.wim'
    Invoke-ImageConversion $esd $out 'EsdToWim'
    Check 'ESD to WIM exports all editions with max compression and integrity checks' ($Script:Calls.Count -eq 2 -and $Script:Calls[0] -match '/Compress:max /CheckIntegrity' -and $Script:Calls[1] -match '/SourceIndex:2')
    Check 'source preserved and completed WIM published' ((Get-Content $esd) -eq 'original' -and (Get-Content $out) -eq 'image')
    $Script:Calls.Clear()
    Invoke-ImageConversion $wim (Join-Path $tmp 'result.esd') 'WimToEsd'
    Check 'WIM to ESD uses solid recovery compression' ($Script:Calls.Count -eq 2 -and $Script:Calls[0] -match '/Compress:recovery')
    $Script:Store = $true; $Script:Calls.Clear()
    Invoke-ImageConversion $esd (Join-Path $tmp 'store.wim') 'StoreToWim'
    Check 'Store ESD omits first three non-OS indexes and exports original index 4' ($Script:Calls.Count -eq 1 -and $Script:Calls[0] -match '/SourceIndex:4')
    $Script:Calls.Clear()
    Check 'existing destination refused before export' ((Failure { Invoke-ImageConversion $esd $out 'EsdToWim' }) -match 'never overwritten' -and $Script:Calls.Count -eq 0)
    Check 'wrong extensions refused' ((Failure { Invoke-ImageConversion $wim (Join-Path $tmp 'bad.wim') 'EsdToWim' }) -match 'existing .esd')
    $Script:FailExport = $true
    $failed = Join-Path $tmp 'failed.wim'
    Check 'failed conversion reported' ((Failure { Invoke-ImageConversion $esd $failed 'StoreToWim' }) -eq 'export failed')
    Check 'failed conversion removes temporary image and does not publish' (-not (Test-Path $failed) -and @(Get-ChildItem $tmp | Where-Object Name -match '^[a-f0-9]{32}\.').Count -eq 0)
    $Script:FailExport = $false; $Script:WrongCount = $true
    Check 'edition-count mismatch cannot publish' ((Failure { Invoke-ImageConversion $esd $failed 'StoreToWim' }) -match 'edition-count' -and -not (Test-Path $failed))
    $Script:WrongCount = $false; $Script:Free = 1
    Check 'low free space prevents export' ((Failure { Invoke-ImageConversion $esd $failed 'StoreToWim' }) -match 'Not enough space')

    # Full language-pack metadata: base-build families, not file names, decide applicability.
    $manifest = '<assembly><assemblyIdentity name="Microsoft-Windows-Client-LanguagePack-Package" version="10.0.19041.1" processorArchitecture="amd64" language="fr-FR" publicKeyToken="31bf3856ad364e35" /></assembly>'
    $pack = Read-LanguagePackManifest $manifest
    Check 'language metadata read from assembly identity' ($pack.Language -eq 'fr-FR' -and $pack.Arch -eq 'x64' -and $pack.Build -eq 19041)
    Check 'FOD CAB rejected' ((Failure { Read-LanguagePackManifest ($manifest.Replace('Client-LanguagePack', 'LanguageFeatures-Basic')) }) -match 'not a full')
    Check 'external entities rejected' ((Failure { Read-LanguagePackManifest ('<!DOCTYPE x [<!ENTITY secret SYSTEM "file:///etc/passwd">]>' + $manifest) }) -ne '')
    $Script:ManifestText = $manifest; $Script:ExpandFails = $false
    function Invoke-Native($File, $NativeArgs) {
        if (-not $Script:ExpandFails) { Set-Content -LiteralPath (Join-Path $NativeArgs[2] 'update.mum') $Script:ManifestText }
        return @{ Code = $(if ($Script:ExpandFails) { 1 } else { 0 }) }
    }
    Check 'CAB manifest extraction reads actual metadata' ((Get-LanguagePackInfo 'pack.cab').Language -eq 'fr-FR')
    $Script:ExpandFails = $true
    Check 'CAB extraction errors reported and temporary manifests removed' ((Failure { Get-LanguagePackInfo 'pack.cab' }) -match 'Cannot read update.mum' -and @(Get-ChildItem $Script:P.Temp -Directory -Filter 'lp-*').Count -eq 0)
    New-Item -ItemType Directory -Force (Join-Path $Script:P.Media 'sources') | Out-Null
    $Script:S.Unpacked = $true; $Script:S.Family = @{ Os = '10'; Build = 19045; Arch = 'x64' }
    $Script:S.Images = @(@{ Index = 1; Name = 'Pro'; Build = 19045; Arch = 'x64' }); $Script:S.Selected = @(1)
    Check 'Windows 10 enablement build accepts matching base language pack' ((Failure { Assert-LanguagePackTarget $pack }) -eq '')
    $pack.Arch = 'arm64'
    Check 'wrong architecture rejected' ((Failure { Assert-LanguagePackTarget $pack }) -match 'does not match')
    $pack.Arch = 'x64'; $pack.Build = 26100
    Check 'wrong release rejected' ((Failure { Assert-LanguagePackTarget $pack }) -match 'does not match')
    $pack.Build = 19041
    function Get-LanguagePackInfo { return $pack }
    $cab = Join-Path $tmp 'lp.cab'; Set-Content $cab 'cab bytes'
    Add-LanguagePack $cab
    $queued = $Script:S.LanguagePacks[0]
    Check 'language CAB copied outside temporary servicing folder and persisted' ((Test-Path -LiteralPath $queued.File) -and $queued.File.StartsWith((Join-Path $Script:P.Work 'languages')) -and (Import-State).LanguagePacks.Count -eq 1)
    Check 'queued CAB passes hash verification' ((Failure { Test-QueuedLanguagePacks }) -eq '')
    Set-Content -LiteralPath $queued.File 'tampered'
    Check 'changed CAB refused before servicing' ((Failure { Test-QueuedLanguagePacks }) -match 'missing or changed')
    Add-LanguagePack $cab
    Check 'importing original CAB repairs a changed cached copy' ((Failure { Test-QueuedLanguagePacks }) -eq '')
    Check 'languages require a downloaded LCU before any servicing' ((Failure { Invoke-Service -Auto }) -match 'Download a matching cumulative update')
    $Script:S.Serviced = @{ When = 'now' }
    Check 'adding a language to already serviced media refused' ((Failure { Add-LanguagePack $cab }) -match 'fresh media')
    $Script:S.Serviced = $null

    foreach ($url in @('http://download.microsoft.com/lp.cab', 'https://evil.example/lp.cab', 'https://download.microsoft.com.evil.example/lp.cab', 'https://download.microsoft.com/lp.exe', 'https://user@download.microsoft.com/lp.cab', 'https://download.microsoft.com/lp.cab?x=" --output attack')) {
        Check "invalid download URL rejected: $url" ((Failure { Test-LanguageDownloadUrl $url }) -ne '')
    }
    Check 'direct Microsoft HTTPS CAB accepted' ((Failure { Test-LanguageDownloadUrl 'https://download.windowsupdate.com/c/msdownload/update/software/updt/lp.cab' }) -eq '')
    # Run actual download orchestration with a fake curl writing the requested output file.
    $curl = Join-Path $env:SystemRoot 'System32/curl.exe'; New-Item -ItemType Directory -Force (Split-Path $curl -Parent) | Out-Null; Set-Content $curl 'fake'
    $Script:DownloadArgs = ''; $Script:CurlExit = 0
    function Invoke-Exe($File, $Arguments, [switch]$MergeErr) {
        $Script:DownloadArgs = $Arguments
        if ($Arguments -match '--output "([^"]+)"') { Set-Content -LiteralPath $Matches[1] 'cab bytes' }
        return $Script:CurlExit
    }
    $Script:Added = $false
    function Add-LanguagePack($File) { $Script:Added = $true }
    $url = 'https://download.microsoft.com/lp.cab'
    Check 'bad download hash never queues CAB' ((Failure { Save-LanguagePack $url ('0' * 64) }) -match 'SHA-256 mismatch' -and -not $Script:Added)
    Save-LanguagePack $url (Get-FileHash $cab -Algorithm SHA256).Hash
    Check 'matching download hash queues CAB and redirects are refused' ($Script:Added -and $Script:DownloadArgs -match '--location .*--max-redirs 0')
    Check 'download staging removed after success or failure' (@(Get-ChildItem $Script:P.Temp -Directory -Filter 'lp-download-*').Count -eq 0)
    $Script:CurlExit = 22; $Script:Added = $false
    Check 'failed HTTP download never queues CAB' ((Failure { Save-LanguagePack $url '' }) -match 'download failed' -and -not $Script:Added)

    # Run the real edition update function. A current LCU must still be applied after a new language.
    $Script:Cfg = @{ NetFx3 = $false; ResetBase = $false }
    $Script:S.LanguagePacks = @($queued)
    $Script:Order = New-Object 'System.Collections.Generic.List[string]'
    function Add-Pkg($MountDir, $Package, $Label, $IgnoreHex, [switch]$Soft) {
        $Script:Order.Add($Label)
        if ($Label -eq 'Cumulative update' -and @($IgnoreHex).Count) { throw 'LCU applicability must not be ignored with languages' }
    }
    function Test-UpdateInImage { $true }
    $upd = @{ SSU = @('ssu'); LCU = @('lcu'); EKB = @(); NET = @(); NET481 = @() }
    Add-EditionUpdates '/mount' $upd '' '' $false (New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]') 'Pro' '19045.1' @{ lcu = @{ Build = 19041; Rev = 1 } }
    Check 'SSU then language then LCU, even when the LCU is already installed' (($Script:Order -join '|') -eq 'Servicing stack|Windows language fr-FR|Cumulative update')
} finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
if ($fails) { exit 1 }
exit 0
