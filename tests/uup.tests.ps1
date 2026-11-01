$ErrorActionPreference = 'Stop'
$fails = 0
function Check($n, $c) { if ($c) { Microsoft.PowerShell.Utility\Write-Host "PASS $n" } else { Microsoft.PowerShell.Utility\Write-Host "FAIL $n"; $script:fails++ } }
function Failure([scriptblock]$Action) { try { & $Action; return '' } catch { return $_.Exception.Message } }
$tokens = $null; $errs = $null
$ast = [Management.Automation.Language.Parser]::ParseFile("$PSScriptRoot/v2body.ps1", [ref]$tokens, [ref]$errs)
Check 'UUP engine and generated app parse' ($errs.Count -eq 0)
foreach ($f in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)) { . ([scriptblock]::Create($f.Extent.Text)) }
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('w10uuup' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
$env:SystemDrive = $tmp; $env:SystemRoot = $tmp
$Script:Cfg = Get-DefaultSettings; $Script:Cfg.WorkDir = Join-Path $tmp 'work'; Initialize-Paths
$Script:S = New-State
$Script:Sync = [hashtable]::Synchronized(@{ Queue = (New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]') })
$id = '11111111-2222-3333-4444-555555555555'
$Script:Uri = ''; $Script:ApiError = $false
function Invoke-RestMethod($Uri) {
    $Script:Uri = $Uri
    if ($Script:ApiError) { throw '403 refused' }
    return [pscustomobject]@{ response = [pscustomobject]@{ apiVersion = '1' } }
}
try {
    $q = New-UupQuery @{ search = 'Windows 11 & amd64'; lang = 'en-us' }
    Check 'query values encoded rather than concatenated' ($q -match 'Windows%2011%20%26%20amd64' -and $q -match 'lang=en-us')
    Check 'malformed identifiers rejected' ((Failure { Assert-UupId '../get.php' }) -ne '')
    Check 'unsupported API endpoint rejected' ((Failure { Invoke-UupApi 'evil' @{} }) -match 'Unsupported')
    $null = Invoke-UupApi 'listid' @{ search = 'Windows 11 amd64' }
    Check 'API requests use the fixed official HTTPS endpoint' ($Script:Uri -match '^https://api\.uupdump\.net/listid\.php\?')
    $Script:ApiError = $true
    Check 'service refusal reported as failure instead of success' ((Failure { Invoke-UupApi 'listid' @{} }) -match 'refused the request')
    $Script:ApiError = $false
    $Script:Mode = 'builds'
    function Invoke-UupApi($Method, $Values) {
        if ($Method -eq 'listid') {
            return @{ builds = [pscustomobject]@{
                '2' = [pscustomobject]@{ uuid = $id; title = 'Windows 11 24H2'; build = '26100.1'; arch = 'amd64'; created = 2 }
                '5' = [pscustomobject]@{ uuid = $id; title = 'Windows 11 Insider Preview'; build = '26200.1'; arch = 'amd64'; created = 3 }
                '9' = [pscustomobject]@{ uuid = $id; title = 'Windows 10 22H2'; build = '19045.1'; arch = 'amd64'; created = 1 }
                '10' = [pscustomobject]@{ uuid = $id; title = 'Windows Server'; build = '26100.1'; arch = 'amd64'; created = 4 }
                '11' = [pscustomobject]@{ uuid = $id; title = 'Windows 11 ARM'; build = '26100.1'; arch = 'arm64'; created = 5 }
            } }
        }
        if ($Method -eq 'listlangs') { return [pscustomobject]@{ langList = @('en-us', 'pt-pt', '../evil'); langFancyNames = [pscustomobject]@{ 'en-us' = 'English'; 'pt-pt' = 'Portuguese' } } }
        return [pscustomobject]@{ editionList = @('Professional', 'Core', '../../evil'); editionFancyNames = [pscustomobject]@{ Professional = 'Windows Pro'; Core = 'Windows Home' } }
    }
    $builds = @(Find-UupBuilds '11' 'amd64' '')
    Check 'sparse PHP JSON objects handled and OS / architecture / previews filtered' ($builds.Count -eq 1 -and $builds[0].Build -eq '26100.1' -and $builds[0].Architecture -eq 'x64')
    Check 'preview builds included only when requested' (@(Find-UupBuilds '11' 'amd64' '' $true).Count -eq 2)
    Check 'Windows 10 selection filters Windows 11' (@(Find-UupBuilds '10' 'amd64' '').Count -eq 1)
    Check 'optional build filter respected' (@(Find-UupBuilds '11' 'amd64' '26100' $true).Count -eq 1)
    Check 'invalid build filter refused' ((Failure { Find-UupBuilds '11' 'amd64' 'x&bad' }) -match 'build number')
    Check 'empty build results reported' ((Failure { Find-UupBuilds '11' 'amd64' '99999' }) -match 'No matching')
    $langs = @(Get-UupLanguages $id); $editions = @(Get-UupEditions $id 'en-us')
    Check 'language names read and invalid language codes filtered' ($langs.Count -eq 2 -and $langs[0].Name -eq 'English')
    Check 'edition names read and path-like edition codes filtered' ($editions.Count -eq 2 -and $editions[0].Code -eq 'Core')
    Check 'both JSON array and sparse object build shapes supported' (@(Get-UupValues @(@{ a = 1 }, @{ a = 2 })).Count -eq 2 -and @(Get-UupValues ([pscustomobject]@{ '3' = 'a'; '7' = 'b' })).Count -eq 2)

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    function Make-Zip($Path, $Entries) {
        $z = [IO.Compression.ZipFile]::Open($Path, [IO.Compression.ZipArchiveMode]::Create)
        try { foreach ($kv in $Entries.GetEnumerator()) { $e = $z.CreateEntry($kv.Key); $w = New-Object IO.StreamWriter($e.Open()); try { $w.Write([string]$kv.Value) } finally { $w.Dispose() } } } finally { $z.Dispose() }
    }
    $zip = Join-Path $tmp 'good.zip'; $dest = Join-Path $tmp 'package'; New-Item -ItemType Directory $dest | Out-Null
    Make-Zip $zip @{ 'uup_download_windows.cmd' = '@echo off'; 'files/ConvertConfig.ini' = "[convert-UUP]`nAutoStart=0`nSkipISO=1`nAddUpdates=1`n[other]`nKeep=1" }
    $Script:FixtureZip = $zip
    Expand-UupPackage $zip $dest
    Set-UupConvertConfig $dest
    $cfg = Get-Content (Join-Path $dest 'files/ConvertConfig.ini') -Raw
    Check 'converter forced to start, create ISO and exit automatically' ($cfg -match 'AutoStart=1' -and $cfg -match 'SkipISO=0' -and $cfg -match 'AutoExit=1' -and $cfg -match 'wim2esd=0')
    Check 'converter keeps updates and unrelated config' ($cfg -match 'AddUpdates=1' -and $cfg -match '\[other\]' -and $cfg -match 'Keep=1')
    $bad = Join-Path $tmp 'traversal.zip'; Make-Zip $bad @{ '../escape.cmd' = 'bad' }
    Check 'ZIP traversal rejected before extraction' ((Failure { Expand-UupPackage $bad $dest }) -match 'Unsafe path' -and -not (Test-Path (Join-Path $tmp 'escape.cmd')))
    $bad2 = Join-Path $tmp 'windows-traversal.zip'; Make-Zip $bad2 @{ '..\escape.cmd' = 'bad' }
    Check 'Windows separator traversal rejected on all test platforms' ((Failure { Expand-UupPackage $bad2 $dest }) -match 'Unsafe path')
    $html = Join-Path $tmp 'blocked.zip'; Set-Content $html '<html>Access denied</html>'
    Check 'HTML error pages cannot be run as UUP packages' ((Failure { Expand-UupPackage $html $dest }) -match 'error page instead of a ZIP')
    $Script:Exit = 0; $Script:Arguments = ''
    function Invoke-Exe($File, $Arguments, [switch]$MergeErr) { $Script:Arguments = $Arguments; return $Script:Exit }
    Invoke-UupRunner $dest
    Check 'supported upstream script is run without an interactive pause' ($Script:Arguments -match 'uup_download_windows.cmd' -and $Script:Arguments -match '<nul')
    $Script:Exit = 5
    Check 'upstream download / conversion errors propagated' ((Failure { Invoke-UupRunner $dest }) -match 'failed \(exit 5\)')
    $Script:Exit = 0

    # Exercise the real mounted-ISO validation with Windows cmdlet stand-ins.
    $mounted = Join-Path $tmp 'mounted'; New-Item -ItemType Directory -Force $mounted | Out-Null
    New-PSDrive -Name UUPTEST -PSProvider FileSystem -Root $mounted | Out-Null
    foreach ($d in 'sources', 'efi/boot') { New-Item -ItemType Directory -Force (Join-Path 'UUPTEST:/' $d) | Out-Null }
    foreach ($f in 'setup.exe', 'sources/boot.wim', 'sources/install.wim', 'efi/boot/bootx64.efi') { Set-Content (Join-Path 'UUPTEST:/' $f) 'file' }
    $Script:Attached = $false; $Script:Unmounted = $false; $Script:TestLang = 'en-US'; $Script:TestArch = 'x64'; $Script:TestBuild = 26100; $Script:TestRevision = 1
    function Get-DiskImage { [pscustomobject]@{ Attached = $Script:Attached } }
    function Mount-DiskImage { [pscustomobject]@{ Attached = $true } }
    function Get-Volume { [pscustomobject]@{ DriveLetter = 'UUPTEST' } }
    function Dismount-DiskImage { $Script:Unmounted = $true }
    function Get-ImageList { return ,@(@{ Edition = 'Professional'; Arch = $Script:TestArch; Build = $Script:TestBuild; Revision = $Script:TestRevision; Langs = $Script:TestLang }) }
    $choice = @{ Id = $id; Build = '26100.1'; Arch = 'amd64'; Language = 'en-us'; Edition = 'Professional' }
    Check 'real ISO validator accepts matching setup files and image metadata' ((Failure { Test-UupIso 'test.iso' $choice }) -eq '' -and $Script:Unmounted)
    $Script:Attached = $true; $Script:Unmounted = $false
    $null = Test-UupIso 'test.iso' $choice
    Check 'ISO validator leaves an existing user mount attached' (-not $Script:Unmounted)
    $Script:TestLang = 'pt-PT'
    Check 'real ISO validator rejects the wrong installed language' ((Failure { Test-UupIso 'test.iso' $choice }) -match 'does not contain')
    $Script:TestLang = 'en-US'; $Script:TestArch = 'arm64'
    Check 'real ISO validator rejects the wrong installed architecture' ((Failure { Test-UupIso 'test.iso' $choice }) -match 'does not contain')
    $Script:TestArch = 'x64'; $Script:TestBuild = 19045
    Check 'real ISO validator rejects a different Windows build family' ((Failure { Test-UupIso 'test.iso' $choice }) -match 'does not contain')
    $Script:TestBuild = 26200
    Check 'real ISO validator rejects a different release sharing a servicing base' ((Failure { Test-UupIso 'test.iso' $choice }) -match 'does not contain')
    $Script:TestBuild = 26100; $Script:TestRevision = 0
    Check 'real ISO validator rejects missing selected cumulative updates' ((Failure { Test-UupIso 'test.iso' $choice }) -match 'does not contain')
    $Script:TestRevision = 1
    $Script:TestBuild = 26100
    Remove-Item 'UUPTEST:/efi/boot/bootx64.efi'
    Check 'real ISO validator rejects missing boot files' ((Failure { Test-UupIso 'test.iso' $choice }) -match 'missing')
    Remove-PSDrive UUPTEST

    # Real orchestration, with small stand-ins for upstream download, conversion and ISO mount validation.
    function Test-WorkDir { }
    $Script:NoIso = $false; $Script:Media = $false; $Script:InvalidIso = $false; $Script:RunnerFails = $false; $Script:Fallback = $false
    function Save-UupPackage($Id, $Language, $Edition, $Destination) { Copy-Item -LiteralPath $Script:FixtureZip -Destination $Destination -Force }
    function Invoke-UupRunner($Directory) {
        Get-ChildItem -LiteralPath $Directory -Filter '*.iso' -File | Remove-Item -Force
        if ($Script:RunnerFails) { throw 'upstream download failed' }
        if (-not $Script:NoIso) { Set-Content -LiteralPath (Join-Path $Directory 'download.iso') 'ISO bytes' }
        if ($Script:Media) {
            $m = Join-Path $Directory 'ISOFOLDER/sources'; New-Item -ItemType Directory -Force $m | Out-Null
            Set-Content (Join-Path $m 'boot.wim') 'boot'; Set-Content (Join-Path $m 'install.wim') 'install'
        }
    }
    function Test-UupIso($Iso, $Choice) { if ($Script:InvalidIso) { throw 'ISO edition mismatch' } }
    function New-UupIsoFromMedia($Media, $Destination) { $Script:Fallback = $true; Set-Content -LiteralPath $Destination 'built ISO' }
    $choice = @{ Id = $id; Build = '26100.1'; Arch = 'amd64'; Language = 'en-us'; Edition = 'Professional' }
    $Script:S.SourceIso = 'existing.iso'; $Script:S.Unpacked = $true
    $result = Invoke-UupDownload $choice
    Check 'completed ISO is published with checksum and provenance' ((Test-Path $result.Iso) -and (Test-Path "$($result.Iso).sha256") -and (Test-Path "$($result.Iso).uup.json") -and $result.Build -eq '26100.1')
    Check 'UUP result does not replace existing source or unpacked state' ($Script:S.SourceIso -eq 'existing.iso' -and $Script:S.Unpacked)
    $count = @(Get-ChildItem $Script:P.Output -Filter '*.iso').Count
    $Script:RunnerFails = $true
    Check 'failed download leaves existing ISOs untouched and publishes no new one' ((Failure { Invoke-UupDownload $choice }) -match 'upstream download failed' -and @(Get-ChildItem $Script:P.Output -Filter '*.iso').Count -eq $count)
    $Script:RunnerFails = $false; $Script:InvalidIso = $true
    Check 'ISO with incorrect requested edition cannot be published' ((Failure { Invoke-UupDownload $choice }) -match 'ISO edition mismatch' -and @(Get-ChildItem $Script:P.Output -Filter '*.iso').Count -eq $count)
    $Script:InvalidIso = $false; $Script:NoIso = $true
    Check 'raw incomplete UUP files cannot be renamed to an ISO' ((Failure { Invoke-UupDownload $choice }) -match 'No bootable ISO or complete setup media')
    $Script:Media = $true
    $converted = Invoke-UupDownload $choice
    Check 'complete setup folder is converted to ISO when converter returns no ISO' ($Script:Fallback -and (Get-Content $converted.Iso) -eq 'built ISO')
    $choice.Language = '../evil'
    Check 'malformed download selections rejected before running scripts' ((Failure { Invoke-UupDownload $choice }) -match 'Choose a language and edition')
    Check 'no output .part files left behind' (@(Get-ChildItem $Script:P.Output -Filter '*.part').Count -eq 0)
} finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
if ($fails) { exit 1 }
exit 0
