#region ---------------------------------------------------------------- Automatic language packs
# Update IDs and language set are based on the user-supplied win10_11lp.ps1 v2.13.
# These are servicing-base sources; the downloaded package manifest must still match the ISO.
function Get-LanguageDownloadSources {
    return @'
Build,Arch,Id
28000,x64,0e1cec91-9bb2-41ad-929f-fe36a5beda02
28000,arm64,02242beb-9b26-4445-b9b8-978df2430b1c
26100,x64,82bfaf56-2ef9-49ce-89fa-daa9c9eaff11
26100,arm64,294aa40d-f466-4071-8654-d952a9a68ac1
22621,x64,356c1621-04e7-4e66-8928-03a687c3db73
22621,arm64,8c9cea2a-b4d5-49dd-82c4-f79bfac1108e
22000,x64,6cc7ea68-b7fb-4de1-bf9b-1f43c6218f6f
22000,arm64,a1b78728-530f-443f-b672-d742e7c14bcb
19041,x64,3ead9b43-aa9d-4973-8195-24be0b0ce1e1
19041,x86,70f4293c-6eaa-4db5-b059-9755ab5628d8
19041,arm64,bb720c43-af68-4dc6-a397-42f278183314
18362,x64,71cd47f8-e9b2-422b-b289-103a76016851
18362,x86,fe1f4dc3-a596-495d-ad9a-810da62d7ddc
18362,arm64,3d401b52-605e-4f68-9f85-9b2e5b0169cd
17763,x64,6ce50996-86a2-48fd-9080-4169135a1f51
17763,x86,c5619e9f-a040-472a-a9b7-f7c13e1b935e
17763,arm64,298d5b36-db90-4e68-81dc-523a337480a9
'@ | ConvertFrom-Csv
}
function Get-AutomaticLanguageList {
    foreach ($code in ('ar-SA,bg-BG,cs-CZ,da-DK,de-DE,el-GR,en-GB,en-US,es-ES,es-MX,et-EE,fi-FI,fr-CA,fr-FR,he-IL,hr-HR,hu-HU,it-IT,ja-JP,ko-KR,lt-LT,lv-LV,nb-NO,nl-NL,pl-PL,pt-BR,pt-PT,ro-RO,ru-RU,sk-SK,sl-SI,sr-Latn-RS,sv-SE,th-TH,tr-TR,uk-UA,zh-CN,zh-TW' -split ',')) {
        $culture = [Globalization.CultureInfo]::GetCultureInfo($code)
        [pscustomobject]@{ Code = $culture.Name; Language = $culture.EnglishName }
    }
}
function Get-AutomaticLanguageTarget {
    Assert-Analyzed
    $images = @($Script:S.Images | Where-Object { $Script:S.Selected -contains $_.Index })
    if (-not $images.Count) { throw 'Tick at least one Windows edition before downloading language packs.' }
    $keys = @($images | ForEach-Object { '{0}/{1}' -f (Get-BaseBuild ([int]$_.Build)), $_.Arch } | Select-Object -Unique)
    if ($keys.Count -ne 1 -or @($images | Where-Object { $_.Edition -match '^Server' }).Count) { throw 'Automatic language packs need Windows client editions with the same base build and architecture.' }
    $base = Get-BaseBuild ([int]$images[0].Build)
    $arch = [string]$images[0].Arch
    $source = @(Get-LanguageDownloadSources | Where-Object { [int]$_.Build -eq $base -and $_.Arch -eq $arch })
    if ($source.Count -ne 1) { throw "No automatic language-pack source is registered for build $base / $arch. Import a matching full CAB or use a direct Microsoft CAB link." }
    return [pscustomobject]@{ Build = $base; Arch = $arch; Id = [string]$source[0].Id }
}
function ConvertTo-LanguagePayloadUrl([string]$Url, [switch]$AllowHttp) {
    $uri = $null
    if ($Url -match '[\s"\x00-\x1f]' -or -not [uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri) -or $uri.UserInfo -or $uri.Fragment -or $uri.Scheme -notin 'http', 'https') { throw 'Invalid language-pack download URL.' }
    if ($uri.DnsSafeHost -notmatch '(^|\.)(download\.windowsupdate\.com|download\.microsoft\.com|dl\.delivery\.mp\.microsoft\.com)$' -or -not $uri.IsDefaultPort) { throw 'Automatic language packs must come from a Microsoft download host.' }
    if ($uri.Scheme -eq 'http' -and -not $AllowHttp) { throw 'HTTP language downloads require the expected size and SHA-1 from HTTPS UUP metadata.' }
    # Microsoft can return an HTTP-only CDN endpoint. Changing its scheme causes
    # SEC_E_WRONG_PRINCIPAL; changing its host can invalidate the signed URL.
    return $Url
}
function Get-LanguagePayload($Files, [string]$Language) {
    $pairs = if ($Files -is [Collections.IDictionary]) { @(foreach ($e in $Files.GetEnumerator()) { [pscustomobject]@{ Name = [string]$e.Key; Value = $e.Value } }) }
             else { @($Files.PSObject.Properties) }
    $region = [regex]::Escape($Language)
    $found = @(foreach ($p in $pairs) {
        $name = [string]$p.Name
        if ($name -notmatch '(?i)^(cabs_)?Microsoft-Windows-Client-LanguagePack-Package[~_-]' -or $name -notmatch "(?i)[~_-]$region([~_.]|$)" -or $name -notmatch '(?i)\.(cab|esd)$') { continue }
        if ($name -match '[\\/:\x00-\x1f]') { throw 'Invalid language-pack file name in UUP metadata.' }
        $ext = [IO.Path]::GetExtension($name).ToLowerInvariant()
        $data = $p.Value
        if ([string]$data.sha1 -notmatch '^[a-fA-F0-9]{40}$' -or [long]$data.size -le 0 -or [long]$data.size -gt 2GB) { throw "Missing or invalid size / SHA-1 for $name." }
        [pscustomobject]@{ Name = $name; Url = (ConvertTo-LanguagePayloadUrl ([string]$data.url) -AllowHttp); Sha1 = ([string]$data.sha1).ToLowerInvariant(); Size = [long]$data.size; Extension = $ext; Priority = $(if ($ext -eq '.cab') { 0 } else { 1 }) }
    })
    if (-not $found.Count) { throw "UUP dump returned no full $Language language pack. Language features / LXP files are not used in place of the display-language pack." }
    return @($found | Sort-Object Priority, @{ Expression = { $_.Size }; Descending = $true })[0]
}
function Save-AutomaticLanguagePayload($Payload) {
    $dir = Join-Path $Script:P.Work 'languages\downloads'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $path = Join-Path $dir ($Payload.Sha1 + $Payload.Extension)
    if ((Test-Path -LiteralPath $path -PathType Leaf) -and (Get-Item -LiteralPath $path).Length -eq $Payload.Size -and (Get-FileHash -LiteralPath $path -Algorithm SHA1).Hash -ieq $Payload.Sha1) { Write-Info "Cached: $($Payload.Name)"; return $path }
    $part = "$path.part"
    try {
        Write-Step "Downloading $($Payload.Name) ($(Format-Size $Payload.Size))"
        Save-LanguageDownloadFile $Payload.Url $part -ExpectedSha1 $Payload.Sha1 -ExpectedSize $Payload.Size
        if ((Get-Item -LiteralPath $part).Length -ne $Payload.Size -or (Get-FileHash -LiteralPath $part -Algorithm SHA1).Hash -ine $Payload.Sha1) { throw 'Language-pack size / SHA-1 mismatch. The payload was not queued.' }
        Move-Item -LiteralPath $part -Destination $path -Force
        return $path
    } finally { Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue }
}
function Save-LanguageDownloadFile([string]$Url, [string]$Destination, [string]$ExpectedSha1 = '', [long]$ExpectedSize = 0) {
    $verifiedPayload = $ExpectedSha1 -ne '' -or $ExpectedSize -ne 0
    if ($verifiedPayload -and ($ExpectedSha1 -notmatch '^[a-fA-F0-9]{40}$' -or $ExpectedSize -le 0 -or $ExpectedSize -gt 2GB)) { throw 'Missing or invalid expected language-pack size / SHA-1.' }
    $url = ConvertTo-LanguagePayloadUrl $Url -AllowHttp:$verifiedPayload
    $httpPayload = ([uri]$url).Scheme -eq 'http'
    if ($httpPayload) { Write-Info 'Microsoft supplied an HTTP payload link. Expected size / SHA-1 will be verified before use; HTTPS metadata and package-signature checks remain required.' }
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    $code = -1
    try {
        if (Test-Path -LiteralPath $curl -PathType Leaf) {
            # No cmd.exe layer: signed, percent-encoded UUP URLs must stay byte-for-byte intact.
            # HTTP is used only when supplied in metadata with mandatory integrity checks.
            $protocols = if ($httpPayload) { '=http,https' } else { '=https' }
            $code = Invoke-Exe $curl ("--fail --location --proto $protocols --max-redirs 0 --retry 2 --output $(Q $Destination) $(Q $url)")
            if ($code -ne 0) {
                # HTTP / server refusals do not trigger another client or a protocol change.
                if ($httpPayload -or $code -notin 60, 77) { throw "Language-pack download failed (exit $code)." }
                Write-Warn "curl certificate validation failed (exit $code). Retrying with the Windows HTTPS downloader, with certificate validation enabled."
            }
        } else { Write-Info 'curl.exe is unavailable; using the Windows downloader.' }
        if ($code -ne 0) {
            Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
            try {
                # Do not disable TLS verification, change the supplied URL or follow redirects.
                Invoke-WebRequest -Uri $url -OutFile $Destination -UseBasicParsing -MaximumRedirection 0 -TimeoutSec 120 -ErrorAction Stop | Out-Null
            } catch {
                $status = 0
                if ($_.Exception.Response -and $_.Exception.Response.StatusCode) { $status = [int]$_.Exception.Response.StatusCode }
                if ($status -ge 400) { throw "Windows language-pack download failed: the download server returned HTTP $status. Retry the language download later to obtain a fresh Microsoft link; check proxy / server access if it remains unavailable." }
                if ($code -in 60, 77) { throw "Language-pack HTTPS download failed with curl (exit $code) and the Windows downloader. Check the PC date/time, Windows root-certificate updates and any proxy or antivirus HTTPS-inspection certificate. Windows error: $($_.Exception.Message)" }
                throw "Windows language-pack download failed: $($_.Exception.Message)"
            }
        }
        if (-not (Test-Path -LiteralPath $Destination -PathType Leaf) -or (Get-Item -LiteralPath $Destination).Length -eq 0) { throw 'Language-pack download failed: no payload file was produced.' }
        if ($verifiedPayload -and ((Get-Item -LiteralPath $Destination).Length -ne $ExpectedSize -or (Get-FileHash -LiteralPath $Destination -Algorithm SHA1).Hash -ine $ExpectedSha1)) { throw 'Language-pack size / SHA-1 mismatch. The payload was not queued.' }
    } catch {
        Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
        throw
    }
}
function Get-LanguageConversionTools {
    # Immutable upstream revision of the ESD2CAB tools used by the supplied reference script.
    $rev = '4c02e02d86d2f01e4ef556bc6a080382bd21cae4'
    $hashes = @{
        'cabarc.exe' = 'cceaa59cb4e67f993b099c5e2693eb15231de3863e29da14ff130f24b66ff260'
        'SxSExpand.exe' = '9e889abd2d6068bc59aededc64a45d96e04c7ad5cb1d70f606f8ab0a96433b4a'
    }
    $dir = Join-Path $ToolsDir 'language-esd2cab'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $tools = @{}
    foreach ($name in $hashes.Keys) {
        $file = Join-Path $dir $name
        if (-not (Test-Path -LiteralPath $file -PathType Leaf) -or (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ine $hashes[$name]) {
            Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
            Save-Url ("https://raw.githubusercontent.com/abbodi1406/BatUtil/$rev/ESD2CAB-CAB2ESD/bin/$name") $file
        }
        if ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ine $hashes[$name]) { Remove-Item -LiteralPath $file -Force; throw "SHA-256 verification failed for $name." }
        $tools[$name] = $file
    }
    [IO.File]::WriteAllText((Join-Path $dir 'UPSTREAM.txt'), "ESD2CAB tools from abbodi1406/BatUtil ($rev).`r`nhttps://github.com/abbodi1406/BatUtil/tree/$rev/ESD2CAB-CAB2ESD`r`nSxSExpand: Melinda Bellemore; cabarc: Microsoft. Upstream terms apply. Tools are downloaded on demand, not bundled.`r`n")
    return $tools
}
function Test-LanguageManifestXml([string]$Path) {
    $reader = $null
    try {
        $settings = New-Object Xml.XmlReaderSettings
        $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit; $settings.XmlResolver = $null
        $reader = [Xml.XmlReader]::Create($Path, $settings)
        [void]$reader.MoveToContent()
        return $reader.LocalName -eq 'assembly'
    } catch { return $false }
    finally { if ($reader) { $reader.Dispose() } }
}
function Convert-LanguageEsdToCab([string]$Esd, [int]$Build) {
    $tools = Get-LanguageConversionTools
    $dir = Join-Path $Script:P.Temp ('language-convert-' + [guid]::NewGuid().ToString('N'))
    $apply = Join-Path $dir 'apply'; $expanded = Join-Path $dir 'expanded'
    New-Item -ItemType Directory -Force -Path $apply, $expanded | Out-Null
    $dest = [IO.Path]::ChangeExtension($Esd, '.cab')
    $part = "$dest.part.cab"
    try {
        $Script:Dism = Get-ServicingDism $Build -Install
        Write-Step 'Converting the language ESD into an integration CAB'
        Invoke-Dism "/Apply-Image /ImageFile:$(Q $Esd) /Index:1 /ApplyDir:$(Q $apply) /CheckIntegrity" 'Apply language-pack ESD'
        $n = 0
        foreach ($m in @(Get-ChildItem -LiteralPath $apply -Filter '*.manifest' -File -Recurse)) {
            if (Test-LanguageManifestXml $m.FullName) { continue }
            $n++; $out = Join-Path $expanded "$n.manifest"
            $r = Invoke-Native $tools['SxSExpand.exe'] @($m.FullName, $out)
            if ($r.Code -ne 0 -or -not (Test-Path -LiteralPath $out) -or -not (Test-LanguageManifestXml $out)) { throw "Could not expand $($m.Name) from the language ESD." }
            Copy-Item -LiteralPath $out -Destination $m.FullName -Force
        }
        if (-not (Test-Path -LiteralPath (Join-Path $apply 'update.mum'))) { throw 'The language ESD does not contain a Windows package manifest.' }
        $code = Invoke-Exe $tools['cabarc.exe'] ("-m LZX:21 -r -p N $(Q $part) *.*") -WorkingDirectory $apply
        if ($code -ne 0 -or -not (Test-Path -LiteralPath $part -PathType Leaf)) { throw "Language ESD-to-CAB conversion failed (exit $code)." }
        $null = Get-LanguagePackInfo $part
        Move-Item -LiteralPath $part -Destination $dest -Force
        return $dest
    } finally {
        Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
function Invoke-AutomaticLanguageDownloads {
    $requested = @($Script:Cfg.LanguageDownloads | Where-Object { $_ } | ForEach-Object { ([string]$_).ToLowerInvariant() } | Select-Object -Unique)
    if (-not $requested.Count) { return }
    $allowed = @(Get-AutomaticLanguageList | ForEach-Object { $_.Code })
    foreach ($lang in $requested) { if ($lang -notin $allowed) { throw "Unsupported automatic language selection: $lang." } }
    $missing = @($requested | Where-Object { -not (Test-LanguageInSelectedImages $_) })
    if (-not $missing.Count) { Write-Info 'The requested languages are already present in the ticked editions.'; return }
    $target = Get-AutomaticLanguageTarget
    foreach ($lang in $missing) {
        $ready = @($Script:S.LanguagePacks | Where-Object { $_ -and $_.Language -ieq $lang -and $_.Arch -eq $target.Arch -and (Get-BaseBuild ([int]$_.Build)) -eq $target.Build })
        if ($ready.Count -and (Test-Path -LiteralPath $ready[0].File -PathType Leaf) -and (Get-FileHash -LiteralPath $ready[0].File -Algorithm SHA256).Hash -ieq $ready[0].Sha256) { Write-Info "Language already queued: $lang"; continue }
        if ($Script:S.Serviced) { throw 'Unpack the original ISO again before downloading / adding new languages.' }
        Write-Step "Finding $lang language pack for build $($target.Build) / $($target.Arch)"
        $response = Invoke-UupApi 'get' @{ id = $target.Id; lang = $lang; edition = 'core' }
        $payload = Get-LanguagePayload $response.files $lang
        $file = Save-AutomaticLanguagePayload $payload
        if ($payload.Extension -eq '.esd') { $file = Convert-LanguageEsdToCab $file $target.Build }
        $info = Get-LanguagePackInfo $file
        if ($info.Language -ine $lang) { throw "The downloaded language pack is $($info.Language), not $lang." }
        Assert-LanguagePackTarget $info
        Add-LanguagePack $file
        foreach ($pack in @($Script:S.LanguagePacks | Where-Object { $_.Language -ieq $lang })) {
            $pack.Source = 'uup-language'; $pack.UpdateId = $target.Id; $pack.PayloadSha1 = $payload.Sha1
        }
        Save-State
        Write-Ok "$lang downloaded and queued for integration."
    }
}
function Test-LanguageInSelectedImages([string]$Language) {
    $images = @($Script:S.Images | Where-Object { $Script:S.Selected -contains $_.Index })
    if (-not $images.Count) { return $false }
    $pattern = '(?i)(^|[,;\s])' + [regex]::Escape($Language) + '($|[,;\s])'
    return @($images | Where-Object { $_.Langs -notmatch $pattern }).Count -eq 0
}
function Assert-AutomaticLanguagesServiced {
    foreach ($lang in @($Script:Cfg.LanguageDownloads | Where-Object { $_ })) {
        if (Test-LanguageInSelectedImages $lang) { continue }
        if ($Script:S.Serviced -and $lang -in @($Script:S.Serviced.LanguagePacks) -and @($Script:S.Selected).Count -gt 0 -and @($Script:S.Selected | Where-Object { $_ -notin @($Script:S.Serviced.LanguageEditions) }).Count -eq 0) { continue }
        throw "Requested language $lang has not been integrated into the ticked editions. Run Download updates and Slipstream, or Run everything, before building the ISO."
    }
}
#endregion
