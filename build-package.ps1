<#
.SYNOPSIS
    Builds the Basic Company (Unicorn) solution and creates a deployment package for an
    existing Sitecore XP 10.3 instance (no Docker required).

.DESCRIPTION
    Run this on the development machine (needs Visual Studio 2019/2022 or Build Tools with the
    "ASP.NET and web development" workload). The result is .\artifacts and a .zip of it:

        artifacts\
            website\      files to copy into the Sitecore web root (dlls, views, configs, App_Data\unicorn\*.yml)
            transforms\   XDT transforms per Helix module (applied by deploy.ps1 on the target)
            tools\        Microsoft.Web.XmlTransform.dll and the Unicorn remote-sync module
            deploy.ps1    the script to run on the Sitecore machine

.EXAMPLE
    .\build-package.ps1
#>
[CmdletBinding()]
param(
    [string]$Configuration = "Release",
    [string]$OutputPath = (Join-Path $PSScriptRoot "artifacts")
)

$ErrorActionPreference = "Stop"

function Find-MSBuild {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path $vswhere) {
        $path = & $vswhere -latest -products * -requires Microsoft.Component.MSBuild -find "MSBuild\**\Bin\MSBuild.exe" | Select-Object -First 1
        if ($path) { return $path }
    }
    $cmd = Get-Command msbuild.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    throw "MSBuild.exe not found. Install Visual Studio 2019/2022 (or Build Tools) with the ASP.NET and web development workload."
}

$msbuild = Find-MSBuild
$websiteOut = Join-Path $OutputPath "website"
$transformsOut = Join-Path $OutputPath "transforms"
$toolsOut = Join-Path $OutputPath "tools"

if (Test-Path $OutputPath) { Remove-Item $OutputPath -Recurse -Force }
New-Item -ItemType Directory -Path $websiteOut, $transformsOut, $toolsOut | Out-Null

Write-Host "Building and publishing website with $msbuild" -ForegroundColor Cyan
& $msbuild (Join-Path $PSScriptRoot "src\Environment\Website\Website.csproj") /restore /nologo /v:m `
    /p:Configuration=$Configuration /p:DeployOnBuild=true /p:DeployDefaultTarget=WebPublish `
    /p:WebPublishMethod=FileSystem /p:PublishUrl="$websiteOut"
if ($LASTEXITCODE -ne 0) { throw "MSBuild failed with exit code $LASTEXITCODE" }

# Transforms keep their module folder (<Layer>\<Module>\...) so two modules may transform the same file.
Write-Host "Collecting XDT transforms" -ForegroundColor Cyan
$srcRoot = Join-Path $PSScriptRoot "src"
Get-ChildItem $srcRoot -Recurse -Filter *.xdt | Where-Object { $_.FullName -notmatch '\\(bin|obj)\\' } | ForEach-Object {
    # src\<Layer>\<Module>\website\<path>.xdt -> transforms\<Layer>\<Module>\<path>.xdt
    $relative = $_.FullName.Substring($srcRoot.Length + 1)
    $parts = $relative -split '\\', 4
    if ($parts.Count -lt 4 -or $parts[2] -ne "website") {
        Write-Warning "Skipping transform outside a module website folder: $relative"
        return
    }
    $target = Join-Path $transformsOut (Join-Path $parts[0] (Join-Path $parts[1] $parts[3]))
    New-Item -ItemType Directory -Path (Split-Path $target) -Force | Out-Null
    Copy-Item $_.FullName $target
}

Write-Host "Copying deployment tools" -ForegroundColor Cyan
$msbuildRoot = $msbuild -replace '\\MSBuild\\(Current|\d+\.\d+)\\Bin\\.*$', '\MSBuild'
$xdtDll = Get-ChildItem (Join-Path $msbuildRoot "Microsoft\VisualStudio") -Recurse -Filter Microsoft.Web.XmlTransform.dll -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $xdtDll) { throw "Microsoft.Web.XmlTransform.dll not found next to MSBuild. Install the ASP.NET and web development workload." }
Copy-Item $xdtDll.FullName $toolsOut
Copy-Item (Join-Path $PSScriptRoot "docker\build\cm\unicorn\Unicorn.psm1") $toolsOut
Copy-Item (Join-Path $PSScriptRoot "docker\build\cm\unicorn\MicroCHAP.dll") $toolsOut
Copy-Item (Join-Path $PSScriptRoot "deploy.ps1") $OutputPath

$zip = Join-Path $PSScriptRoot ("BasicCompany-Unicorn-{0}.zip" -f (Get-Date -Format "yyyyMMdd-HHmm"))
Compress-Archive -Path (Join-Path $OutputPath "*") -DestinationPath $zip -Force

$itemCount = (Get-ChildItem (Join-Path $websiteOut "App_Data\unicorn") -Recurse -Filter *.yml).Count
Write-Host ""
Write-Host "Package ready: $zip" -ForegroundColor Green
Write-Host "  serialized items: $itemCount"
Write-Host "Copy the zip to the Sitecore machine, extract it and run deploy.ps1 as Administrator."
