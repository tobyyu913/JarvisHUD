# Build a self-contained single-file JarvisHUD.exe for Windows (run on Windows with the .NET 8 SDK installed).
#   .\build.ps1            -> windows\dist\JarvisHUD-win-x64.zip
#   .\build.ps1 -Arch arm64
param([string]$Arch = "x64")
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot
$rid = "win-$Arch"
dotnet publish JarvisHUD/JarvisHUD.csproj -c Release -r $rid --self-contained -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -o "dist/$rid"
Copy-Item JarvisHUD/AppIcon.ico "dist/$rid/" -Force
Compress-Archive -Path "dist/$rid/*" -DestinationPath "dist/JarvisHUD-$rid.zip" -Force
Write-Host "Built dist/JarvisHUD-$rid.zip"
