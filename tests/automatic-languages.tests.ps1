$ErrorActionPreference = 'Stop'
$fails = 0
function Check($n, $c) { if ($c) { Microsoft.PowerShell.Utility\Write-Host "PASS $n" } else { Microsoft.PowerShell.Utility\Write-Host "FAIL $n"; $script:fails++ } }
function Failure([scriptblock]$Action) { try { & $Action; return '' } catch { return $_.Exception.Message } }
$tokens = $null; $errs = $null
$ast = [Management.Automation.Language.Parser]::ParseFile("$PSScriptRoot/v2body.ps1", [ref]$tokens, [ref]$errs)
Check 'automatic language engine parses' ($errs.Count -eq 0)
foreach ($f in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)) { . ([scriptblock]::Create($f.Extent.Text)) }
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('w10uautolang' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
$env:SystemDrive = $tmp; $env:SystemRoot = $tmp
$ToolsDir = Join-Path $tmp 'tools'; $Script:SettingsFile = Join-Path $tmp 'settings.json'
$Script:Cfg = Get-DefaultSettings; $Script:Cfg.WorkDir = Join-Path $tmp 'work'; Initialize-Paths
$Script:S = New-State
$Script:Sync = [hashtable]::Synchronized(@{ Queue = (New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]') })
New-Item -ItemType Directory -Force (Join-Path $Script:P.Media 'sources'), (Join-Path $tmp 'System32') | Out-Null
Set-Content (Join-Path $tmp 'System32/curl.exe') 'fake'
$Script:S.Unpacked = $true; $Script:S.Family = @{ Os = '11'; Build = 26200; Arch = 'x64' }
$Script:S.Images = @(@{ Index = 1; Name = 'Windows Pro'; Edition = 'Professional'; Build = 26200; Arch = 'x64'; Langs = 'en-US' })
$Script:S.Selected = @(1)
try {
    Check 'reference script exposes 38 selectable languages' (@(Get-AutomaticLanguageList).Count -eq 38)
    $target = Get-AutomaticLanguageTarget
    Check '25H2 x64 uses the reference 24H2 / 25H2 servicing source' ($target.Build -eq 26100 -and $target.Id -eq '82bfaf56-2ef9-49ce-89fa-daa9c9eaff11')
    $Script:S.Images[0].Build = 19045; $Script:S.Images[0].Arch = 'x86'
    Check 'Windows 10 22H2 x86 source detected from image metadata' ((Get-AutomaticLanguageTarget).Id -eq '70f4293c-6eaa-4db5-b059-9755ab5628d8')
    $Script:S.Images[0].Build = 18363; $Script:S.Images[0].Arch = 'arm64'
    Check '1909 uses the matching 1903 base source for ARM64' ((Get-AutomaticLanguageTarget).Id -eq '3d401b52-605e-4f68-9f85-9b2e5b0169cd')
    $Script:S.Images[0].Build = 14393
    Check 'unregistered versions stop with manual import guidance' ((Failure { Get-AutomaticLanguageTarget }) -match 'Import a matching full CAB')
    $Script:S.Images[0].Build = 26100; $Script:S.Images[0].Arch = 'x86'
    Check 'Windows 11 x86 cannot pick another architecture source' ((Failure { Get-AutomaticLanguageTarget }) -match 'No automatic language-pack source')
    $Script:S.Images[0].Arch = 'x64'
    $Script:S.Images += @{ Index = 2; Name = 'Other'; Edition = 'Core'; Build = 22621; Arch = 'x64'; Langs = 'en-US' }; $Script:S.Selected = @(1, 2)
    Check 'mixed servicing bases rejected before download' ((Failure { Get-AutomaticLanguageTarget }) -match 'same base build and architecture')
    $Script:S.Selected = @(1)

    $bytes = [Text.Encoding]::ASCII.GetBytes('language payload')
    $sha = [Convert]::ToHexString([Security.Cryptography.SHA1]::HashData($bytes)).ToLowerInvariant()
    $Script:PayloadBytes = $bytes; $Script:Hash = $sha
    function Entry($Url = 'http://tlu.dl.delivery.mp.microsoft.com/filestreamingservice/files/123?P1=a%3Db') { return @{ url = $Url; sha1 = $sha; size = $bytes.Length } }
    $esdName = 'cabs_microsoft-windows-client-languagepack-package_amd64_fr-fr.esd'
    $cabName = 'Microsoft-Windows-Client-LanguagePack-Package~31bf3856ad364e35~amd64~fr-FR~10.0.26100.1.cab'
    $files = @{}; $files[$esdName] = Entry; $files[$cabName] = Entry
    $files['Microsoft-Windows-LanguageFeatures-Basic-fr-fr-Package.cab'] = Entry
    $files['Microsoft-Windows-Client-LanguagePack-Package-amd64-fr-ca.cab'] = Entry
    $payload = Get-LanguagePayload $files 'fr-FR'
    Check 'full CAB preferred over ESD and optional language features excluded' ($payload.Name -eq $cabName -and $payload.Extension -eq '.cab')
    Check 'Microsoft HTTP payload URLs upgraded to HTTPS without losing encoded query' ($payload.Url -match '^https://tlu\.dl\.delivery\.mp\.microsoft\.com/' -and $payload.Url -match 'a%3Db')
    $objectFiles = [pscustomobject]@{ $esdName = (Entry) }
    Check 'JSON object file maps supported as well as hashtables' ((Get-LanguagePayload $objectFiles 'fr-FR').Extension -eq '.esd')
    Check 'language region must match exactly, not just its language prefix' ((Failure { Get-LanguagePayload $objectFiles 'fr-CA' }) -match 'no full fr-CA')
    $noHash = @{}; $noHash[$cabName] = @{ url = 'https://download.microsoft.com/lp.cab'; size = 10 }
    Check 'missing expected payload hash rejected' ((Failure { Get-LanguagePayload $noHash 'fr-FR' }) -match 'invalid size / SHA-1')
    foreach ($url in @('https://evil.example/lp.cab', 'https://download.microsoft.com.evil.example/lp.cab', 'https://user@download.microsoft.com/lp.cab', 'https://download.microsoft.com:444/lp.cab', 'file:///tmp/lp.cab')) {
        Check "unsafe payload location refused: $url" ((Failure { ConvertTo-LanguagePayloadUrl $url }) -ne '')
    }
    $item = $null; while ($Script:Sync.Queue.TryDequeue([ref]$item)) { }
    $exitCode = Invoke-Exe '/bin/pwd' '' -WorkingDirectory $tmp
    $lines = @(); while ($Script:Sync.Queue.TryDequeue([ref]$item)) { $lines += [string]$item[1] }
    Check 'native process helper really uses the requested working directory' ($exitCode -eq 0 -and @($lines | Where-Object { $_ -match [regex]::Escape($tmp) }).Count -gt 0)
    function Save-Url($Url, $Dest) { $Script:ToolUrl = $Url; Set-Content -LiteralPath $Dest 'incorrect tool bytes' }
    Check 'conversion tools cannot run with a wrong pinned SHA-256' ((Failure { Get-LanguageConversionTools }) -match 'SHA-256 verification failed')
    Check 'conversion tool source uses an immutable upstream revision' ($Script:ToolUrl -match 'raw\.githubusercontent\.com/abbodi1406/BatUtil/[a-f0-9]{40}/')
    $Script:Downloads = 0; $Script:WrongBytes = $false; $Script:DownloadFails = $false; $Script:CurlExit = 0
    function Invoke-Exe($File, $Arguments, [switch]$MergeErr, $WorkingDirectory) {
        if ($File -match 'curl\.exe$') {
            $Script:Downloads++
            if ($Arguments -match '--output "([^"]+)"') { [IO.File]::WriteAllBytes($Matches[1], $(if ($Script:WrongBytes) { [byte[]]@(1,2,3) } else { $Script:PayloadBytes })) }
            if ($Script:DownloadFails) { return 22 }; return $Script:CurlExit
        }
        if ($File -match 'cabarc\.exe$') {
            $Script:CabWorkingDir = $WorkingDirectory
            if ($Arguments -match ' N "([^"]+)"') { [IO.File]::WriteAllBytes($Matches[1], $Script:PayloadBytes) }
            return $Script:CabExit
        }
        throw 'Unexpected executable'
    }
    $cached = Save-AutomaticLanguagePayload $payload
    $again = Save-AutomaticLanguagePayload $payload
    Check 'verified payload cached without a second download' ($cached -eq $again -and $Script:Downloads -eq 1)
    Set-Content $cached 'tampered'; $Script:WrongBytes = $true
    Check 'changed or incomplete download cannot replace cached bytes as valid' ((Failure { Save-AutomaticLanguagePayload $payload }) -match 'size / SHA-1 mismatch')
    Check 'failed payload download leaves no .part file' (-not (Test-Path "$cached.part"))
    $Script:WrongBytes = $false; $Script:DownloadFails = $true
    Check 'HTTP failure is propagated even if a partial output file exists' ((Failure { Save-AutomaticLanguagePayload $payload }) -match 'download failed')
    $Script:DownloadFails = $false
    $null = Save-AutomaticLanguagePayload $payload

    # Reproduce the supplied v4.6.0 log: correct pt-PT discovery, then curl exit 60.
    $Script:WebCalls = 0; $Script:WebFails = $false; $Script:WebWrongBytes = $false; $Script:WebHttpStatus = 0
    function Invoke-WebRequest($Uri, $OutFile, [switch]$UseBasicParsing, [int]$MaximumRedirection, [int]$TimeoutSec, $ErrorAction) {
        $Script:WebCalls++
        $Script:WebParams = @{}; foreach ($k in $PSBoundParameters.Keys) { $Script:WebParams[$k] = $PSBoundParameters[$k] }
        $Script:HadPartial = Test-Path -LiteralPath $OutFile
        [IO.File]::WriteAllBytes($OutFile, $(if ($Script:WebWrongBytes) { [byte[]]@(4,5,6) } else { $Script:PayloadBytes }))
        if ($Script:WebHttpStatus) {
            $failure = New-Object Exception('HTTP request failed')
            Add-Member -InputObject $failure -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{ StatusCode = $Script:WebHttpStatus })
            throw $failure
        }
        if ($Script:WebFails) { throw 'The remote certificate is invalid according to the validation procedure.' }
    }
    Remove-Item -LiteralPath $cached
    $Script:CurlExit = 60
    $retried = Save-AutomaticLanguagePayload $payload
    Check 'curl exit 60 retries with Windows HTTPS and publishes only verified bytes' ($Script:WebCalls -eq 1 -and (Get-FileHash $retried -Algorithm SHA1).Hash -ieq $payload.Sha1)
    Check 'partial curl output is removed before Windows retry' (-not $Script:HadPartial)
    Check 'Windows retry keeps HTTPS and refuses redirects without skipping certificate checks' ($Script:WebParams.Uri -match '^https://' -and $Script:WebParams.MaximumRedirection -eq 0 -and -not $Script:WebParams.ContainsKey('SkipCertificateCheck'))
    Remove-Item -LiteralPath $cached
    $Script:CurlExit = 77
    $null = Save-AutomaticLanguagePayload $payload
    Check 'curl CA-file errors also use the verified Windows client' ($Script:WebCalls -eq 2)
    Remove-Item -LiteralPath $cached
    $Script:CurlExit = 60; $Script:WebWrongBytes = $true
    Check 'a Windows retry cannot bypass expected payload size / SHA-1' ((Failure { Save-AutomaticLanguagePayload $payload }) -match 'size / SHA-1 mismatch' -and -not (Test-Path $cached))
    $Script:WebWrongBytes = $false; $Script:WebFails = $true
    Check 'both TLS clients failing produces certificate repair guidance' ((Failure { Save-AutomaticLanguagePayload $payload }) -match 'Windows root-certificate updates')
    Check 'failed Windows retry removes all partial payload bytes' (-not (Test-Path "$cached.part") -and -not (Test-Path $cached))
    $Script:WebFails = $false; $Script:WebHttpStatus = 403
    $message = Failure { Save-AutomaticLanguagePayload $payload }
    Check 'fallback HTTP errors get refresh / access guidance instead of certificate guidance' ($message -match 'HTTP 403' -and $message -match 'fresh Microsoft link' -and $message -notmatch 'root-certificate')
    $Script:WebHttpStatus = 0; $Script:CurlExit = 22; $webCountBeforeRefusal = $Script:WebCalls
    Check 'HTTP refusals never trigger the alternate downloader' ((Failure { Save-AutomaticLanguagePayload $payload }) -match 'exit 22' -and $Script:WebCalls -eq $webCountBeforeRefusal)
    Remove-Item -LiteralPath (Join-Path $tmp 'System32/curl.exe')
    $null = Save-AutomaticLanguagePayload $payload
    Check 'Windows HTTPS downloader works when curl is missing' ($Script:WebCalls -eq $webCountBeforeRefusal + 1 -and (Test-Path $cached))
    Set-Content (Join-Path $tmp 'System32/curl.exe') 'fake'; $Script:CurlExit = 0

    # The real ESD-to-CAB path uses DISM, expands compressed manifests, then cabinets the package.
    $Script:CabExit = 0; $Script:ExpandFails = $false; $Script:InfoLanguage = 'fr-FR'; $Script:InfoArch = 'x64'
    function Get-LanguageConversionTools { @{ 'cabarc.exe' = 'cabarc.exe'; 'SxSExpand.exe' = 'SxSExpand.exe' } }
    function Get-ServicingDism { 'dism.exe' }
    function Invoke-Dism($Arguments) {
        if ($Arguments -match '/ApplyDir:"([^"]+)"') {
            Set-Content -LiteralPath (Join-Path $Matches[1] 'update.mum') '<assembly />'
            Set-Content -LiteralPath (Join-Path $Matches[1] 'component.manifest') 'compressed manifest'
        }
    }
    function Invoke-Native($File, $ArgList) {
        if (-not $Script:ExpandFails) { [IO.File]::WriteAllText($ArgList[1], '<assembly />') }
        return @{ Code = $(if ($Script:ExpandFails) { 1 } else { 0 }) }
    }
    function Get-LanguagePackInfo { @{ Language = $Script:InfoLanguage; Build = 26100; Arch = $Script:InfoArch } }
    $esd = Join-Path $tmp 'pack.esd'; [IO.File]::WriteAllBytes($esd, $bytes)
    $cab = Convert-LanguageEsdToCab $esd 26100
    Check 'ESD converted to CAB while keeping its source' ((Test-Path $cab) -and (Test-Path $esd) -and $Script:CabWorkingDir -match 'apply$')
    Check 'conversion scratch folders removed after success' (@(Get-ChildItem $Script:P.Temp -Directory -Filter 'language-convert-*').Count -eq 0)
    $Script:CabExit = 5
    Check 'cabinet-tool failure cannot publish a replacement CAB' ((Failure { Convert-LanguageEsdToCab $esd 26100 }) -match 'conversion failed' -and -not (Test-Path "$cab.part.cab"))
    $Script:CabExit = 0; $Script:ExpandFails = $true
    Check 'compressed manifest expansion errors stop conversion' ((Failure { Convert-LanguageEsdToCab $esd 26100 }) -match 'Could not expand')
    Check 'failed conversion also removes scratch folders and preserves ESD' (@(Get-ChildItem $Script:P.Temp -Directory -Filter 'language-convert-*').Count -eq 0 -and (Test-Path $esd))
    $Script:ExpandFails = $false

    $Script:ApiCalls = 0; $Script:ApiExtension = '.esd'
    function Invoke-UupApi($Method, $Values) {
        $Script:ApiCalls++; $Script:LastApi = @{ Method = $Method; Values = $Values }
        $name = 'Microsoft-Windows-Client-LanguagePack-Package-amd64-' + $Values.lang + $Script:ApiExtension
        return @{ files = @{ $name = @{ url = 'https://download.windowsupdate.com/lp'; sha1 = $Script:Hash; size = $Script:PayloadBytes.Length } } }
    }
    $Script:Cfg.LanguageDownloads = @('fr-FR')
    Invoke-AutomaticLanguageDownloads
    Check 'automatic ISO matching fetches the reference source without a manual URL' ($Script:LastApi.Method -eq 'get' -and $Script:LastApi.Values.id -eq '82bfaf56-2ef9-49ce-89fa-daa9c9eaff11' -and $Script:LastApi.Values.lang -eq 'fr-fr' -and $Script:LastApi.Values.edition -eq 'core')
    $queued = $Script:S.LanguagePacks[0]
    Check 'downloaded ESD is converted, validated and queued as a persistent CAB' ($queued.Language -eq 'fr-FR' -and $queued.Source -eq 'uup-language' -and (Test-Path $queued.File) -and (Import-State).LanguagePacks.Count -eq 1)
    $requests = $Script:ApiCalls
    Invoke-AutomaticLanguageDownloads
    Check 'second automatic pass reuses the verified queue without network requests' ($Script:ApiCalls -eq $requests)
    Set-Content $queued.File 'changed queued pack'
    Invoke-AutomaticLanguageDownloads
    Check 'changed queued pack repaired from a verified payload' ($Script:ApiCalls -eq $requests + 1 -and (Get-FileHash $Script:S.LanguagePacks[0].File -Algorithm SHA256).Hash -eq $Script:S.LanguagePacks[0].Sha256)
    $Script:S.LanguagePacks = @(); $Script:InfoLanguage = 'fr-CA'
    Check 'wrong language manifest cannot be queued' ((Failure { Invoke-AutomaticLanguageDownloads }) -match 'not fr-fr' -and $Script:S.LanguagePacks.Count -eq 0)
    $Script:InfoLanguage = 'fr-FR'; $Script:InfoArch = 'arm64'
    Check 'wrong architecture manifest cannot be queued' ((Failure { Invoke-AutomaticLanguageDownloads }) -match 'does not match' -and $Script:S.LanguagePacks.Count -eq 0)
    $Script:InfoArch = 'x64'; $Script:S.Serviced = @{ When = 'now' }
    Check 'new packs require a fresh ISO after servicing' ((Failure { Invoke-AutomaticLanguageDownloads }) -match 'Unpack the original ISO')
    $Script:S.Serviced = $null; $Script:Cfg.LanguageDownloads = @('en-US')
    $requests = $Script:ApiCalls
    Invoke-AutomaticLanguageDownloads
    Check 'languages already installed in every selected edition need no download' ($Script:ApiCalls -eq $requests)
    Check 'already installed languages satisfy ISO build requirements' ((Failure { Assert-AutomaticLanguagesServiced }) -eq '')
    $Script:Cfg.LanguageDownloads = @('fr-FR')
    Check 'ISO build refuses requested languages that were downloaded but not integrated' ((Failure { Assert-AutomaticLanguagesServiced }) -match 'has not been integrated')
    $Script:S.Serviced = @{ LanguagePacks = @('fr-FR'); LanguageEditions = @(1) }
    Check 'ISO build accepts languages integrated into the selected editions' ((Failure { Assert-AutomaticLanguagesServiced }) -eq '')
    $Script:S.Selected = @(1, 2)
    Check 'changing edition selection cannot bypass missing language integration' ((Failure { Assert-AutomaticLanguagesServiced }) -match 'has not been integrated')
    $Script:S.Selected = @(1); $Script:S.Serviced = $null

    $Script:Cfg.LanguageDownloads = @('fr-FR', 'pt-PT'); Save-Settings
    Check 'multiple requested languages survive settings serialization' (((Import-Settings).LanguageDownloads -join ',') -eq 'fr-FR,pt-PT')
    $Script:U = @{ LpAutoGrid = [pscustomobject]@{ ItemsSource = $null }; LpAutoTarget = [pscustomobject]@{ Text = '' }; LpGrid = [pscustomobject]@{ ItemsSource = $null } }
    $Script:Loading = $true; Update-AutomaticLanguagesUi; $Script:Loading = $false
    Check 'language picker preserves the saved selections' (@($Script:LpAutoTable.Rows | Where-Object { $_['Use'] }).Count -eq 2)
    $Script:S.LanguagePacks = @(@{ Language = 'fr-FR'; Source = 'uup-language' }, @{ Language = 'it-IT'; Source = 'manual' })
    foreach ($row in $Script:LpAutoTable.Rows) { if ($row['Code'] -eq 'fr-FR') { $row['Use'] = $false } }
    Check 'unticking a language removes its automatic queue entry but preserves manual imports' ($Script:S.LanguagePacks.Count -eq 1 -and $Script:S.LanguagePacks[0].Language -eq 'it-IT' -and 'fr-FR' -notin $Script:Cfg.LanguageDownloads)
} finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
if ($fails) { exit 1 }
exit 0
