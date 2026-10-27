<#
.SYNOPSIS
    Deploys the Basic Company (Unicorn) package to an existing Sitecore XP 10.3 instance on this machine.

.DESCRIPTION
    Run from the extracted package folder (the one that contains website\, transforms\, tools\),
    in an elevated PowerShell. The script is safe to run again for every new package.

      1. Copies website\ into the Sitecore web root (App_Data\unicorn is mirrored so removed items disappear).
      2. Applies the Helix modules' XDT transforms (App_Config\Layers.config, Views\Web.config).
         The first run keeps the original as <file>.basiccompany-original and every later run
         transforms that original again, so entries are never added twice.
      3. Sets the site host name, adds the IIS binding and the hosts file entry (skip with -SkipBinding).
      4. Optionally writes a Unicorn shared secret and runs a Unicorn sync (-UnicornSecret ... -Sync).

.EXAMPLE
    .\deploy.ps1 -WebRoot C:\inetpub\wwwroot\sc103.dev.local

.EXAMPLE
    .\deploy.ps1 -WebRoot C:\inetpub\wwwroot\sc103.dev.local -HostName basiccompany.local `
        -UnicornSecret "a-long-random-string-of-at-least-64-characters-......................" -Sync
#>
[CmdletBinding()]
param(
    # Physical path of the Sitecore XP 10.3 web root (the folder that contains bin\Sitecore.Kernel.dll).
    [Parameter(Mandatory = $true)]
    [string]$WebRoot,

    # Host name for the Basic Company site.
    [string]$HostName = "basiccompany.local",

    # IIS site name. Defaults to the site whose physical path is $WebRoot.
    [string]$IisSiteName,

    # Do not touch IIS bindings or the hosts file.
    [switch]$SkipBinding,

    # Shared secret for Unicorn remote sync (64+ characters). Written to App_Config\Include\zzz\BasicCompany.UnicornSecret.config.
    [string]$UnicornSecret,

    # Run a Unicorn sync of all configurations after deploying. Requires -UnicornSecret.
    [switch]$Sync,

    # CM base URL used for the sync, e.g. https://sc103.dev.local. Defaults to the IIS site's first https (else http) binding.
    [string]$CmUrl
)

$ErrorActionPreference = "Stop"
$packageRoot = $PSScriptRoot

function Assert-Admin {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Run this script from an elevated (Administrator) PowerShell."
    }
}

function Invoke-Robocopy([string]$Source, [string]$Destination, [string[]]$Options) {
    & robocopy $Source $Destination @Options /NFL /NDL /NJH /NJS /NP | Out-Null
    # Robocopy exit codes 0-7 mean success (with or without copied files)
    if ($LASTEXITCODE -ge 8) { throw "robocopy $Source -> $Destination failed with exit code $LASTEXITCODE" }
    $global:LASTEXITCODE = 0
}

# IIS bindings and the hosts file need elevation (copying into C:\inetpub usually does too)
if (-not $SkipBinding) { Assert-Admin }

# --- 0. Validate target ------------------------------------------------------
$WebRoot = (Resolve-Path $WebRoot).Path.TrimEnd('\')
$kernel = Join-Path $WebRoot "bin\Sitecore.Kernel.dll"
if (-not (Test-Path $kernel)) { throw "$WebRoot does not look like a Sitecore web root (bin\Sitecore.Kernel.dll not found)." }
# Sitecore 10.3.x ships Sitecore.Kernel 18.0.x
$kernelVersion = [Version](Get-Item $kernel).VersionInfo.FileVersion
if ($kernelVersion.Major -ne 18) {
    Write-Warning "Sitecore.Kernel.dll is version $kernelVersion; this package was built for Sitecore 10.3 (Kernel 18.x)."
}
# Rainbow refuses tree roots longer than Rainbow.SFS.SerializationFolderPathMaxLength (150). The longest root is
# <WebRoot>\App_Data\unicorn\Project\BasicCompany\serialization\siteroot-insertrule (web root + 70 characters).
if ($WebRoot.Length -gt 80) {
    throw "Web root path '$WebRoot' is $($WebRoot.Length) characters; Unicorn needs it to be 80 or less. Point sourceFolder at a shorter folder (see BasicCompany.Environment.config)."
}
foreach ($folder in "website", "transforms", "tools") {
    if (-not (Test-Path (Join-Path $packageRoot $folder))) { throw "Folder '$folder' not found next to deploy.ps1. Run the script from the extracted package." }
}

# --- 1. Copy files -----------------------------------------------------------
Write-Host "Copying website files to $WebRoot" -ForegroundColor Cyan
$websiteSource = Join-Path $packageRoot "website"
Invoke-Robocopy $websiteSource $WebRoot @("/E", "/XD", (Join-Path $websiteSource "App_Data\unicorn"))
Invoke-Robocopy (Join-Path $websiteSource "App_Data\unicorn") (Join-Path $WebRoot "App_Data\unicorn") @("/MIR")

# --- 2. XDT transforms -------------------------------------------------------
Write-Host "Applying XDT transforms" -ForegroundColor Cyan
Add-Type -Path (Join-Path $packageRoot "tools\Microsoft.Web.XmlTransform.dll")
$transformsRoot = Join-Path $packageRoot "transforms"
$layerOrder = @{ "Foundation" = 0; "Feature" = 1; "Project" = 2 }
$transforms = Get-ChildItem $transformsRoot -Recurse -Filter *.xdt | ForEach-Object {
    # transforms\<Layer>\<Module>\<path>.xdt -> <WebRoot>\<path>
    $parts = $_.FullName.Substring($transformsRoot.Length + 1) -split '\\', 3
    [pscustomobject]@{
        Xdt    = $_.FullName
        Order  = $layerOrder[$parts[0]]
        Module = "$($parts[0]).$($parts[1])"
        Target = Join-Path $WebRoot ($parts[2] -replace '\.xdt$', '')
    }
}
foreach ($group in ($transforms | Group-Object Target)) {
    $target = $group.Name
    if (-not (Test-Path $target)) { throw "Transform target $target does not exist." }
    $original = "$target.basiccompany-original"
    if (-not (Test-Path $original)) { Copy-Item $target $original }

    $doc = New-Object Microsoft.Web.XmlTransform.XmlTransformableDocument
    $doc.PreserveWhitespace = $true
    $doc.Load($original)
    foreach ($t in ($group.Group | Sort-Object Order, Module)) {
        $transformation = New-Object Microsoft.Web.XmlTransform.XmlTransformation($t.Xdt)
        if (-not $transformation.Apply($doc)) { throw "Transform $($t.Xdt) failed on $target" }
        Write-Host "  $($t.Module): $($target.Substring($WebRoot.Length + 1))"
    }
    $doc.Save($target)
}

# --- 3. Host name, IIS binding, hosts file ----------------------------------
$environmentConfig = Join-Path $WebRoot "App_Config\Include\zzz\BasicCompany.Environment.config"
[xml]$envXml = Get-Content $environmentConfig -Raw
$ns = New-Object Xml.XmlNamespaceManager($envXml.NameTable)
$ns.AddNamespace("patch", "http://www.sitecore.net/xmlconfig/")
$hostNode = $envXml.SelectSingleNode("/configuration/sitecore/sites/site[@name='basic-company']/patch:attribute[@name='hostName']", $ns)
if ($hostNode.InnerText -ne $HostName) {
    $hostNode.InnerText = $HostName
    $envXml.Save($environmentConfig)
}
Write-Host "Basic Company host name: $HostName" -ForegroundColor Cyan

if (-not $SkipBinding) {
    Import-Module WebAdministration
    if (-not $IisSiteName) {
        $site = Get-Website | Where-Object { [Environment]::ExpandEnvironmentVariables($_.physicalPath).TrimEnd('\') -ieq $WebRoot } | Select-Object -First 1
        if (-not $site) { throw "No IIS site found with physical path $WebRoot. Pass -IisSiteName." }
        $IisSiteName = $site.Name
    }
    foreach ($name in ($HostName -split '\|')) {
        if (-not (Get-WebBinding -Name $IisSiteName -Protocol http -Port 80 -HostHeader $name)) {
            New-WebBinding -Name $IisSiteName -Protocol http -Port 80 -HostHeader $name
            Write-Host "  added IIS binding http://${name} to '$IisSiteName'"
        }
        $hostsFile = Join-Path $env:SystemRoot "System32\drivers\etc\hosts"
        if (-not (Select-String -Path $hostsFile -Pattern "^\s*127\.0\.0\.1\s+$([regex]::Escape($name))\s*$" -Quiet)) {
            Add-Content -Path $hostsFile -Value "127.0.0.1`t$name" -Encoding ASCII
            Write-Host "  added hosts entry 127.0.0.1 $name"
        }
    }
}

# --- 4. Unicorn secret and sync ---------------------------------------------
if ($UnicornSecret) {
    if ($UnicornSecret.Length -lt 32) { throw "-UnicornSecret should be at least 32 (preferably 64+) characters." }
    $secretConfig = Join-Path $WebRoot "App_Config\Include\zzz\BasicCompany.UnicornSecret.config"
    $escaped = [Security.SecurityElement]::Escape($UnicornSecret)
    @"
<configuration xmlns:role="http://www.sitecore.net/xmlconfig/role/">
  <sitecore>
    <unicorn role:require="Standalone or ContentManagement">
      <authenticationProvider>
        <SharedSecret>$escaped</SharedSecret>
      </authenticationProvider>
    </unicorn>
  </sitecore>
</configuration>
"@ | Set-Content -Path $secretConfig -Encoding UTF8
    Write-Host "Unicorn shared secret written to $secretConfig" -ForegroundColor Cyan
}

if ($Sync) {
    if (-not $UnicornSecret) { throw "-Sync requires -UnicornSecret." }
    if (-not $CmUrl) {
        Import-Module WebAdministration
        if (-not $IisSiteName) {
            $IisSiteName = (Get-Website | Where-Object { [Environment]::ExpandEnvironmentVariables($_.physicalPath).TrimEnd('\') -ieq $WebRoot } | Select-Object -First 1).Name
        }
        $bindings = Get-WebBinding -Name $IisSiteName | Where-Object {
            $_.protocol -in "https", "http" -and ($_.bindingInformation -split ':')[2] -and ($HostName -split '\|') -notcontains ($_.bindingInformation -split ':')[2]
        } | Sort-Object { if ($_.protocol -eq "https") { 0 } else { 1 } }
        if (-not $bindings) { throw "Could not work out the CM URL. Pass -CmUrl, e.g. https://sc103.dev.local" }
        $b = @($bindings)[0]
        $CmUrl = "{0}://{1}" -f $b.protocol, ($b.bindingInformation -split ':')[2]
    }
    Import-Module (Join-Path $packageRoot "tools\Unicorn.psm1") -Force
    Write-Host "Running Unicorn sync on $CmUrl (the first request waits for Sitecore to start)" -ForegroundColor Cyan
    Sync-Unicorn -ControlPanelUrl ("{0}/unicorn.aspx" -f $CmUrl.TrimEnd('/')) -SharedSecret $UnicornSecret
}

Write-Host ""
Write-Host "Deployment finished." -ForegroundColor Green
if (-not $Sync) {
    Write-Host "Next: log in to Sitecore and open /unicorn.aspx, then click 'Sync' for all configurations."
}
Write-Host "Then: Publish site (smart), Control Panel > Populate Solr Managed Schema, Indexing Manager > rebuild sitecore_master_index and sitecore_web_index."
Write-Host "Site: http://$(($HostName -split '\|')[0])/"
