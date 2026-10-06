# Pompom - installe les outils portables dans tools/ (rien n'est installe dans le systeme).
#   powershell -ExecutionPolicy Bypass -File setup_tools.ps1             # Godot seul
#   powershell -ExecutionPolicy Bypass -File setup_tools.ps1 -Templates  # + modeles d'export (1,3 Go)
#   powershell -ExecutionPolicy Bypass -File setup_tools.ps1 -Blender    # + Blender (pour regenerer les modeles)
param([switch]$Templates, [switch]$Blender)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$GodotVersion = '4.7.2'
$BlenderVersion = '5.2.2'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$tools = Join-Path $root 'tools'
New-Item -ItemType Directory -Force $tools | Out-Null

$godotDir = Join-Path $tools 'godot'
if (-not (Test-Path (Join-Path $godotDir "Godot_v$GodotVersion-stable_win64_console.exe"))) {
  Write-Host "Telechargement de Godot $GodotVersion..."
  $zip = Join-Path $tools 'godot.zip'
  Invoke-WebRequest "https://github.com/godotengine/godot/releases/download/$GodotVersion-stable/Godot_v$GodotVersion-stable_win64.exe.zip" -OutFile $zip
  Expand-Archive $zip $godotDir -Force
  Remove-Item $zip
}

if ($Templates) {
  $dst = Join-Path $env:APPDATA "Godot\export_templates\$GodotVersion.stable"
  if (-not (Test-Path (Join-Path $dst 'windows_release_x86_64.exe'))) {
    Write-Host "Telechargement des modeles d'export (1,3 Go)..."
    New-Item -ItemType Directory -Force $dst | Out-Null
    $tpz = Join-Path $tools 'templates.tpz'
    Invoke-WebRequest "https://github.com/godotengine/godot/releases/download/$GodotVersion-stable/Godot_v$GodotVersion-stable_export_templates.tpz" -OutFile $tpz
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $z = [System.IO.Compression.ZipFile]::OpenRead($tpz)
    foreach ($e in $z.Entries) {
      if ($e.Name -and ($e.FullName -match 'windows_|version.txt')) {
        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($e, (Join-Path $dst $e.Name), $true)
      }
    }
    $z.Dispose()
    Remove-Item $tpz
  }
}

if ($Blender) {
  $bdir = Join-Path $tools "blender-$BlenderVersion-windows-x64"
  if (-not (Test-Path (Join-Path $bdir 'blender.exe'))) {
    Write-Host "Telechargement de Blender $BlenderVersion (portable)..."
    $bzip = Join-Path $tools 'blender.zip'
    $major = ($BlenderVersion -split '\.')[0..1] -join '.'
    Invoke-WebRequest "https://download.blender.org/release/Blender$major/blender-$BlenderVersion-windows-x64.zip" -OutFile $bzip
    Expand-Archive $bzip $tools -Force
    Remove-Item $bzip
  }
}
Write-Host "Outils prets dans $tools"
