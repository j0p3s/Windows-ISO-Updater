#region ---------------------------------------------------------------- Image conversions
function Invoke-ImageConversion([string]$Source, [string]$Destination, [string]$Mode) {
    if ($Mode -notin 'EsdToWim', 'WimToEsd', 'StoreToWim') { throw 'Choose an image conversion.' }
    $srcExt = if ($Mode -eq 'WimToEsd') { '.wim' } else { '.esd' }
    $dstExt = if ($Mode -eq 'WimToEsd') { '.esd' } else { '.wim' }
    $Source = [IO.Path]::GetFullPath($Source)
    $Destination = [IO.Path]::GetFullPath($Destination)
    if (-not (Test-Path -LiteralPath $Source -PathType Leaf) -or [IO.Path]::GetExtension($Source) -ine $srcExt) { throw "Choose an existing $srcExt source image." }
    if ([IO.Path]::GetExtension($Destination) -ine $dstExt) { throw "The destination must end in $dstExt." }
    if ($Source -ieq $Destination -or (Test-Path -LiteralPath $Destination)) { throw 'Choose a new destination file. Existing files are never overwritten.' }
    try { $images = Get-ImageList $Source }
    catch { throw "Cannot read this image. Encrypted Store ESDs must be decrypted with a legitimate key before conversion. DISM: $($_.Exception.Message)" }
    if ($Mode -eq 'StoreToWim') {
        # Store ESDs also contain media / WinPE / Setup indexes. Export only Windows installations.
        $images = @($images | Where-Object { $_.Edition -and $_.Edition -notmatch '^(WindowsPE|WindowsSetup)$' -and $_.Name -notmatch '(?i)Windows (PE|Setup|Recovery)|Windows Setup Media' })
    }
    if (-not $images.Count) { throw 'No Windows installation editions found in this image.' }
    $Script:Dism = Get-ServicingDism ([int]$images[0].Build) -Install
    New-Item -ItemType Directory -Force -Path (Split-Path $Destination -Parent) | Out-Null
    $need = [double]($images | Measure-Object -Property Size -Sum).Sum + 256MB
    $free = Get-FreeBytes $Destination
    if ($free -ge 0 -and $free -lt $need) { throw "Not enough space for conversion. Allow about $(Format-Size $need) for the uncompressed image data." }
    $part = Join-Path (Split-Path $Destination -Parent) (([guid]::NewGuid().ToString('N')) + $dstExt)
    Write-Title 'Convert Windows image'
    if ($Mode -eq 'WimToEsd') { Write-Info 'ESD: slower, CPU-intensive solid compression; smaller media. Setup may need more CPU time to decompress, but reads fewer bytes.' }
    else { Write-Info 'WIM: generally faster to create and service; larger media. Setup usually needs less decompression work, but reads more bytes.' }
    Write-Info 'Setup speed depends on CPU and storage. Installed Windows performance is unchanged by this conversion.'
    $start = Get-Date
    try {
        $n = 0
        foreach ($i in $images) {
            $n++
            Write-Step "Source index $($i.Index) ($($i.Name)) -> destination index $n"
            $compress = if ($Mode -eq 'WimToEsd') { 'recovery' } else { 'max' }
            Invoke-Dism "/Export-Image /SourceImageFile:$(Q $Source) /SourceIndex:$($i.Index) /DestinationImageFile:$(Q $part) /Compress:$compress /CheckIntegrity" 'Convert image'
        }
        $check = Get-ImageList $part
        if ($check.Count -ne $images.Count) { throw 'The converted image failed edition-count verification.' }
        # File.Move refuses an existing destination, even if it appeared while the export was running.
        [IO.File]::Move($part, $Destination)
    } finally { Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue }
    Write-Ok ("Image ready: $Destination ({0}; {1:hh\:mm\:ss})" -f (Format-Size (Get-Item -LiteralPath $Destination).Length), ((Get-Date) - $start))
    Write-Info 'The source image is unchanged. A Store ESD conversion creates an install image, not a bootable ISO; use matching Windows setup media.'
}
#endregion

#region ---------------------------------------------------------------- Windows language packs
function Test-LanguageDownloadUrl([string]$Url) {
    $uri = $null
    if (-not [uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne 'https' -or $uri.UserInfo -or $uri.Fragment) { throw 'Use a direct HTTPS Microsoft language-pack CAB URL.' }
    if ($Url -match '[\s"\x00-\x1f]' -or $uri.DnsSafeHost -notmatch '(^|\.)(download\.windowsupdate\.com|download\.microsoft\.com)$' -or $uri.AbsolutePath -notmatch '(?i)\.cab$') { throw 'Use a direct CAB link on download.windowsupdate.com or download.microsoft.com.' }
}
function Read-LanguagePackManifest([string]$Text) {
    # Do not resolve external entities from imported manifests.
    $settings = New-Object Xml.XmlReaderSettings
    $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $reader = [Xml.XmlReader]::Create((New-Object IO.StringReader($Text)), $settings)
    try { $xml = New-Object Xml.XmlDocument; $xml.XmlResolver = $null; $xml.Load($reader) } finally { $reader.Dispose() }
    $id = $xml.SelectSingleNode('/*[local-name()="assembly"]/*[local-name()="assemblyIdentity"]')
    if (-not $id -or [string]$id.name -notmatch '(?i)^Microsoft-Windows-(Client|Server)-LanguagePack-Package$' -or [string]$id.publicKeyToken -ine '31bf3856ad364e35') { throw 'This CAB is not a full Microsoft Windows language pack. LXP, WinPE and Features on Demand packages are not supported here.' }
    $v = [version]([string]$id.version)
    $culture = [Globalization.CultureInfo]::GetCultureInfo([string]$id.language)
    if ($culture.IsNeutralCulture -or -not $culture.Name) { throw 'The language pack has no specific Windows language.' }
    return [ordered]@{ Language = $culture.Name; Arch = (ConvertTo-ArchName ([string]$id.processorArchitecture)); Build = $v.Build }
}
function Get-LanguagePackInfo([string]$File) {
    $dir = Join-Path $Script:P.Temp ('lp-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    try {
        $r = Invoke-Native (Join-Path $env:SystemRoot 'System32\expand.exe') @($File, '-F:update.mum', $dir)
        $mum = Join-Path $dir 'update.mum'
        if ($r.Code -ne 0 -or -not (Test-Path -LiteralPath $mum)) { throw 'Cannot read update.mum from this language-pack CAB.' }
        return Read-LanguagePackManifest ([IO.File]::ReadAllText($mum))
    } finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
}
function Assert-LanguagePackTarget($Pack) {
    Assert-Analyzed
    foreach ($img in @($Script:S.Images | Where-Object { $Script:S.Selected -contains $_.Index })) {
        if ($Pack.Arch -ne $img.Arch -or (Get-BaseBuild $Pack.Build) -ne (Get-BaseBuild ([int]$img.Build))) { throw "Language pack $($Pack.Language) build $($Pack.Build) / $($Pack.Arch) does not match edition $($img.Name) build $($img.Build) / $($img.Arch)." }
    }
    if (-not @($Script:S.Selected).Count) { throw 'Tick at least one edition before adding language packs.' }
}
function Add-LanguagePack([string]$File) {
    Assert-Analyzed
    if ($Script:S.Serviced) { throw 'Add language packs to fresh media before slipstreaming. Unpack the original ISO again first.' }
    if (-not (Test-Path -LiteralPath $File -PathType Leaf) -or [IO.Path]::GetExtension($File) -ine '.cab') { throw 'Choose an existing full language-pack CAB.' }
    $pack = Get-LanguagePackInfo $File
    Assert-LanguagePackTarget $pack
    $hash = (Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash
    $dir = Join-Path $Script:P.Work 'languages'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $dest = Join-Path $dir ("$($pack.Language)-$($pack.Build)-$($pack.Arch)-$hash.cab")
    if (-not (Test-Path -LiteralPath $dest) -or (Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash -ine $hash) { Copy-Item -LiteralPath $File -Destination $dest -Force }
    $pack.File = $dest; $pack.Sha256 = $hash
    $Script:S.LanguagePacks = @($Script:S.LanguagePacks | Where-Object { $_ -and $_.Language -ne $pack.Language }) + @($pack)
    Save-State
    Write-Ok "$($pack.Language) queued for the ticked Windows editions. DISM verifies package applicability and signatures when integrating."
}
function Save-LanguagePack([string]$Url, [string]$Sha256) {
    Assert-Analyzed
    if ($Script:S.Serviced) { throw 'Add language packs to fresh media before slipstreaming. Unpack the original ISO again first.' }
    if (-not @($Script:S.Selected).Count) { throw 'Tick at least one edition before adding language packs.' }
    Test-LanguageDownloadUrl $Url
    if ($Sha256 -and $Sha256 -notmatch '^[A-Fa-f0-9]{64}$') { throw 'SHA-256 must contain exactly 64 hexadecimal characters, or be left empty.' }
    $dir = Join-Path $Script:P.Temp ('lp-download-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $file = Join-Path $dir 'language.cab'
    try {
        # Reject redirects: a Microsoft URL must not send this downloader to an arbitrary host.
        $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
        if (-not (Test-Path -LiteralPath $curl)) { throw 'curl.exe is required for direct language-pack downloads (included with current Windows 10/11).' }
        $code = Invoke-Exe $curl ("--fail --location --proto =https --max-redirs 0 --retry 2 --output $(Q $file) $(Q $Url)") -MergeErr
        if ($code -ne 0 -or -not (Test-Path -LiteralPath $file) -or (Get-Item -LiteralPath $file).Length -eq 0) { throw 'Language-pack download failed. Use a direct Microsoft CAB link.' }
        if ($Sha256 -and (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ine $Sha256) { throw 'Language-pack SHA-256 mismatch. The download was not queued.' }
        Add-LanguagePack $file
    } finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
}
function Test-QueuedLanguagePacks {
    foreach ($pack in @($Script:S.LanguagePacks | Where-Object { $_ })) {
        Assert-LanguagePackTarget $pack
        if (-not (Test-Path -LiteralPath $pack.File -PathType Leaf) -or (Get-FileHash -LiteralPath $pack.File -Algorithm SHA256).Hash -ine $pack.Sha256) { throw "Language pack $($pack.Language) is missing or changed. Add it again before slipstreaming." }
    }
}
function Add-QueuedLanguagePacks([string]$MountDir) {
    foreach ($pack in @($Script:S.LanguagePacks | Where-Object { $_ })) {
        # No -Soft: a rejected language pack must stop the job before media is replaced.
        Add-Pkg $MountDir $pack.File "Windows language $($pack.Language)"
    }
}
#endregion
