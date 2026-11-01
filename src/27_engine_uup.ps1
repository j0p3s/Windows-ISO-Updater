#region ---------------------------------------------------------------- UUP dump: Windows downloads and ISO creation
function New-UupQuery($Values) {
    return (@(foreach ($k in $Values.Keys) { '{0}={1}' -f [uri]::EscapeDataString([string]$k), [uri]::EscapeDataString([string]$Values[$k]) }) -join '&')
}
function Assert-UupId([string]$Id) {
    if ($Id -notmatch '^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$') { throw 'Choose a valid UUP dump build first.' }
}
function Invoke-UupApi([string]$Method, $Values) {
    if ($Method -notin 'listid', 'listlangs', 'listeditions') { throw 'Unsupported UUP dump API request.' }
    $url = 'https://api.uupdump.net/' + $Method + '.php?' + (New-UupQuery $Values)
    try { $r = Invoke-RestMethod -Uri $url -Method Get -TimeoutSec 60 -ErrorAction Stop }
    catch { throw "UUP dump could not be reached or refused the request. Try again later or open uupdump.net; no ISO was created. $($_.Exception.Message)" }
    if (-not $r.response -or $r.response.error) { throw "UUP dump returned an error: $($r.response.error). Try another build or try again later." }
    return $r.response
}
# PHP returns a JSON array when its numeric keys are contiguous, an object when they are not.
function Get-UupValues($Value) {
    if ($Value -is [Collections.IDictionary]) { return @($Value.Values) }
    if ($Value -is [Management.Automation.PSCustomObject]) { return @($Value.PSObject.Properties | ForEach-Object { $_.Value }) }
    return @($Value)
}
function Find-UupBuilds([string]$Os, [string]$Arch, [string]$Build, [bool]$Preview = $false) {
    if ($Os -notin '10', '11' -or $Arch -notin 'amd64', 'arm64', 'x86') { throw 'Choose Windows 10 or 11 and an architecture.' }
    if ($Build -and $Build -notmatch '^\d{4,5}(\.\d{1,6})?$') { throw 'Use a build number such as 19045 or 26100.1, or leave it empty.' }
    $query = "Windows $Os " + $(if ($Build) { "$Build " }) + $Arch
    Write-Step "UUP dump: $query"
    $r = Invoke-UupApi 'listid' @{ search = $query; sortByDate = 1 }
    $items = @(foreach ($b in (Get-UupValues $r.builds)) {
        if (-not $b -or [string]$b.build -notmatch '^\d{4,5}(\.\d{1,6})?$' -or $b.arch -ne $Arch) { continue }
        $n = [int](([string]$b.build -split '\.')[0])
        if (($Os -eq '10' -and ($n -lt 10240 -or $n -ge 22000)) -or ($Os -eq '11' -and $n -lt 22000)) { continue }
        if ($b.title -match '(?i)server|\.NET|Dynamic Update|Servicing Stack') { continue }
        if (-not $Preview -and $b.title -match '(?i)preview|insider') { continue }
        if ($Build -and [string]$b.build -ne $Build -and -not ([string]$b.build).StartsWith($Build + '.')) { continue }
        if ([string]$b.uuid -notmatch '^[a-fA-F0-9-]{36}$') { continue }
        Assert-UupId ([string]$b.uuid)
        [pscustomobject]@{ Id = [string]$b.uuid; Title = [string]$b.title; Build = [string]$b.build; Architecture = (ConvertTo-ArchName $b.arch); Arch = [string]$b.arch; Os = $Os; Created = [long]$b.created }
    })
    $items = @($items | Sort-Object Created -Descending | Select-Object -First 80)
    if (-not $items.Count) { throw 'No matching Windows builds found. Try another build number or include preview builds.' }
    Write-Ok "$($items.Count) UUP dump build(s) found. Load languages to check which have complete installation packages."
    return $items
}
function Get-UupLanguages([string]$Id) {
    Assert-UupId $Id
    $r = Invoke-UupApi 'listlangs' @{ id = $Id }
    $items = @(foreach ($code in @(Get-UupValues $r.langList)) {
        if ([string]$code -notmatch '^[a-zA-Z]{2,3}-[a-zA-Z0-9-]{2,12}$') { continue }
        $name = [string]$r.langFancyNames.$code
        if (-not $name) { $name = [string]$code }
        [pscustomobject]@{ Code = ([string]$code).ToLowerInvariant(); Name = $name }
    })
    if (-not $items.Count) { throw 'This build has no downloadable language packs / complete installation set. Choose another build.' }
    return @($items | Sort-Object Name)
}
function Get-UupEditions([string]$Id, [string]$Language) {
    Assert-UupId $Id
    if ($Language -notmatch '^[a-zA-Z]{2,3}-[a-zA-Z0-9-]{2,12}$') { throw 'Choose a UUP dump language.' }
    $r = Invoke-UupApi 'listeditions' @{ id = $Id; lang = $Language }
    $items = @(foreach ($code in @(Get-UupValues $r.editionList)) {
        if ([string]$code -notmatch '^[a-zA-Z0-9]{1,64}$') { continue }
        $name = [string]$r.editionFancyNames.$code
        if (-not $name) { $name = [string]$code }
        [pscustomobject]@{ Code = [string]$code; Name = $name }
    })
    if (-not $items.Count) { throw 'This build and language have no installation editions. Choose another combination.' }
    return @($items | Sort-Object Name)
}
function Save-UupPackage([string]$Id, [string]$Language, [string]$Edition, [string]$Destination) {
    Assert-UupId $Id
    $query = New-UupQuery @{ id = $Id; pack = $Language; edition = $Edition; autodl = '2' }
    Write-Step 'Downloading the UUP dump download-and-convert package'
    # Query + POST body support the public package endpoint's old and current forms.
    try { Invoke-WebRequest -Uri ('https://uupdump.net/get.php?' + $query) -Method Post -Body @{ autodl = '2'; updates = '1'; cleanup = '0' } -OutFile $Destination -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop | Out-Null }
    catch { throw "UUP dump package download failed. Try again later; the source ISO and unpacked media are unchanged. $($_.Exception.Message)" }
}
function Expand-UupPackage([string]$Archive, [string]$Destination) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = $null
    try {
        $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
        if ($zip.Entries.Count -gt 2000) { throw 'Too many package entries.' }
        $root = [IO.Path]::GetFullPath($Destination).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
        $total = 0L
        foreach ($entry in $zip.Entries) {
            $total += $entry.Length
            if ($total -gt 512MB) { throw 'The download package is unexpectedly large.' }
            $name = $entry.FullName.Replace('\', '/')
            if ($name -match '(^/|(^|/)\.\.(/|$)|:)' -or $name -match '[\x00-\x1f]' -or (($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000) { throw 'Unsafe path in UUP dump package.' }
            $target = [IO.Path]::GetFullPath((Join-Path $Destination $name))
            if (-not $target.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe path in UUP dump package.' }
        }
        foreach ($entry in $zip.Entries) {
            $target = Join-Path $Destination $entry.FullName.Replace('\', '/')
            if ($entry.FullName.EndsWith('/')) { New-Item -ItemType Directory -Force -Path $target | Out-Null; continue }
            New-Item -ItemType Directory -Force -Path (Split-Path $target -Parent) | Out-Null
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
        }
    } catch { throw "Cannot use the UUP dump package (it may be an error page instead of a ZIP). $($_.Exception.Message)" }
    finally { if ($zip) { $zip.Dispose() } }
}
function Set-UupConvertConfig([string]$Directory) {
    $configs = @(Get-ChildItem -LiteralPath $Directory -Filter 'ConvertConfig.ini' -File -Recurse)
    if (-not $configs.Count) { throw 'The UUP dump package has no ConvertConfig.ini. Download a download-and-convert package.' }
    foreach ($file in $configs) {
        $text = [IO.File]::ReadAllText($file.FullName)
        if ($text -notmatch '(?im)^\[convert-UUP\]\s*$') { throw 'Unsupported UUP converter configuration.' }
        foreach ($kv in @{ AutoStart = 1; AutoExit = 1; SkipISO = 0; wim2esd = 0; StartVirtual = 0 }.GetEnumerator()) {
            $pattern = '(?im)^' + [regex]::Escape($kv.Key) + '\s*=.*$'
            $line = $kv.Key + '=' + $kv.Value
            if ($text -match $pattern) { $text = [regex]::Replace($text, $pattern, $line) }
            else { $text = [regex]::Replace($text, '(?im)^\[convert-UUP\]\s*$', ('[convert-UUP]' + "`r`n" + $line)) }
        }
        [IO.File]::WriteAllText($file.FullName, $text, [Text.Encoding]::ASCII)
    }
}
function Invoke-UupRunner([string]$Directory) {
    $entry = $null
    foreach ($name in 'uup_download_windows.cmd', 'aria2_download_windows.cmd') {
        $candidate = Join-Path $Directory $name
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { $entry = $candidate; break }
    }
    if (-not $entry) { throw 'The UUP dump package has no supported Windows download-and-convert script.' }
    Set-UupConvertConfig $Directory
    Write-Step 'Downloading Windows files and converting UUP / ESD / CAB files into a bootable ISO'
    Write-Info 'Running the UUP dump community downloader and UUP converter. Several GB are downloaded from Microsoft. This can take an hour or more.'
    $code = Invoke-Exe (Join-Path $env:SystemRoot 'System32\cmd.exe') ('/d /s /c "' + (Q $entry) + ' <nul"')
    if ($code -ne 0) { throw "UUP dump download / conversion failed (exit $code). Files are kept in $Directory for retry and diagnosis." }
}
function New-UupIsoFromMedia([string]$Media, [string]$Destination) {
    $etfs = Join-Path $Media 'boot\etfsboot.com'
    $efi = Join-Path $Media 'efi\microsoft\boot\efisys.bin'
    if (-not (Test-Path -LiteralPath $efi)) { throw 'The converter did not produce an ISO or complete bootable setup media. A bare WIM / ESD cannot be renamed into an ISO.' }
    $osc = Find-Oscdimg
    if (-not $osc) { $osc = Get-Oscdimg }
    $boot = if (Test-Path -LiteralPath $etfs) { "-bootdata:2#p0,e,b$(Q $etfs)#pEF,e,b$(Q $efi)" } else { "-bootdata:1#pEF,e,b$(Q $efi)" }
    Write-Step 'Building a standard bootable ISO from the downloaded setup media'
    $code = Invoke-Exe $osc ("-m -o -u2 -udfver102 -lWINDOWS_UUP $boot $(Q $Media) $(Q $Destination)") -MergeErr
    if ($code -ne 0 -or -not (Test-Path -LiteralPath $Destination)) { Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue; throw "UUP setup media ISO build failed (exit $code)." }
}
function Test-UupIso([string]$Iso, $Choice) {
    $disk = Get-DiskImage -ImagePath $Iso -ErrorAction Stop
    $wasAttached = [bool]$disk.Attached
    if (-not $wasAttached) { $disk = Mount-DiskImage -ImagePath $Iso -PassThru -ErrorAction Stop }
    try {
        $vol = $disk | Get-Volume
        if (-not $vol.DriveLetter) { throw 'The downloaded ISO could not be mounted with a drive letter.' }
        $root = "$($vol.DriveLetter):\"
        $efiName = @{ amd64 = 'bootx64.efi'; arm64 = 'bootaa64.efi'; x86 = 'bootia32.efi' }[[string]$Choice.Arch]
        foreach ($rel in @('setup.exe', 'sources\boot.wim', "efi\boot\$efiName")) {
            if (-not (Test-Path -LiteralPath (Join-Path $root $rel) -PathType Leaf)) { throw "The downloaded ISO is missing $rel." }
        }
        $image = $null
        foreach ($name in 'install.wim', 'install.esd') {
            $f = Join-Path $root "sources\$name"
            if (Test-Path -LiteralPath $f -PathType Leaf) { $image = $f; break }
        }
        if (-not $image) { throw 'The downloaded ISO contains no Windows install.wim / install.esd.' }
        $images = Get-ImageList $image
        $parts = [string]$Choice.Build -split '\.'
        $build = [int]$parts[0]
        $revision = if ($parts.Count -gt 1) { [int]$parts[1] } else { 0 }
        $matching = @($images | Where-Object { $_.Edition -ieq $Choice.Edition -and $_.Arch -eq (ConvertTo-ArchName $Choice.Arch) -and [int]$_.Build -eq $build -and [int]$_.Revision -ge $revision -and $_.Langs -match ('(?i)(^|[,;\s])' + [regex]::Escape([string]$Choice.Language) + '($|[,;\s])') })
        if (-not $matching.Count) { throw 'The ISO does not contain the chosen Windows build, architecture, language and edition.' }
    } finally { if (-not $wasAttached) { Dismount-DiskImage -ImagePath $Iso -ErrorAction SilentlyContinue | Out-Null } }
}
function Invoke-UupDownload($Choice) {
    Assert-UupId ([string]$Choice.Id)
    if ($Choice.Arch -notin 'amd64', 'arm64', 'x86' -or [string]$Choice.Build -notmatch '^\d{4,5}(\.\d{1,6})?$') { throw 'Choose a valid Windows build and architecture.' }
    if ([string]$Choice.Edition -notmatch '^[a-zA-Z0-9]{1,64}$' -or [string]$Choice.Language -notmatch '^[a-zA-Z]{2,3}-[a-zA-Z0-9-]{2,12}$') { throw 'Choose a language and edition first.' }
    if ($Script:P.Work -match '[\s"&|<>^%!()]') { throw 'UUP conversion needs a short work path without spaces or shell characters, such as C:\W10U. Change it on Options first.' }
    $langs = @(Get-UupLanguages $Choice.Id)
    if (-not @($langs | Where-Object { $_.Code -ieq $Choice.Language }).Count) { throw 'The selected language is no longer available. Load languages again.' }
    $editions = @(Get-UupEditions $Choice.Id $Choice.Language)
    if (-not @($editions | Where-Object { $_.Code -ieq $Choice.Edition }).Count) { throw 'The selected edition is no longer available. Load editions again.' }
    Test-WorkDir 35
    $dir = Join-Path (Join-Path $Script:P.Work 'downloads\uup') ("$($Choice.Id)_$($Choice.Language)_$($Choice.Edition)")
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $zip = Join-Path $dir 'download-package.zip'
    Write-Title "Download Windows from UUP dump - $($Choice.Build) / $($Choice.Language) / $($Choice.Edition)"
    Save-UupPackage $Choice.Id $Choice.Language $Choice.Edition $zip
    Expand-UupPackage $zip $dir
    Invoke-UupRunner $dir
    $iso = @(Get-ChildItem -LiteralPath $dir -Filter '*.iso' -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1)
    if (-not $iso.Count) {
        $media = @(foreach ($n in 'ISOFOLDER', 'ISO', 'media') {
            $d = Join-Path $dir $n
            if ((Test-Path -LiteralPath (Join-Path $d 'sources\boot.wim')) -and ((Test-Path -LiteralPath (Join-Path $d 'sources\install.wim')) -or (Test-Path -LiteralPath (Join-Path $d 'sources\install.esd')))) { $d }
        })
        if (-not $media.Count) { throw "No bootable ISO or complete setup media was produced. UUP files are kept in $dir; check the conversion log." }
        $candidate = Join-Path $dir 'Windows.iso'
        New-UupIsoFromMedia $media[0] $candidate
        $iso = @(Get-Item -LiteralPath $candidate)
    }
    $source = $iso[0].FullName
    Test-UupIso $source $Choice
    New-Item -ItemType Directory -Force -Path $Script:P.Output | Out-Null
    $os = if ([int](([string]$Choice.Build -split '\.')[0]) -ge 22000) { '11' } else { '10' }
    $name = 'Win{0}_{1}_{2}_{3}_{4}_{5}.iso' -f $os, $Choice.Build, $Choice.Arch, $Choice.Language, $Choice.Edition, ([guid]::NewGuid().ToString('N').Substring(0, 8))
    $target = Join-Path $Script:P.Output $name
    $part = "$target.part"
    try {
        Copy-Item -LiteralPath $source -Destination $part -ErrorAction Stop
        $hash = (Get-FileHash -LiteralPath $part -Algorithm SHA256).Hash
        [IO.File]::Move($part, $target)
    } finally { Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue }
    [IO.File]::WriteAllText("$target.sha256", "$hash *$name`n", (New-Object Text.UTF8Encoding $false))
    $meta = [ordered]@{ Provider = 'UUP dump'; Id = $Choice.Id; Build = $Choice.Build; Arch = $Choice.Arch; Language = $Choice.Language; Edition = $Choice.Edition; Sha256 = $hash; Iso = $target }
    $meta | ConvertTo-Json | Set-Content -LiteralPath "$target.uup.json" -Encoding UTF8
    Write-Ok "Bootable Windows ISO ready: $target"
    Write-Info 'This ISO was assembled locally from UUP files. It will not match a Microsoft-published ISO hash. Select Unpack and analyze to use it.'
    return $meta
}
#endregion
