# Lance le test de l'eventail "main de cartes" (HeldFan) avec un delai maximum ; ne tue que sa propre instance.
# Les fenetres du test sont placees hors de l'ecran (ne derange pas un jeu en cours) ; -GameArgs --onscreen pour les voir.
# Usage : powershell -File godot/tests/run_held_fan_test.ps1 [-Timeout 90] [-GameArgs --scale=1.5]
# Captures : %APPDATA%\Pompom\held_fan_*.png
param([int]$Timeout = 90, [string[]]$GameArgs = @())
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$godot = Join-Path $root "tools\godot\Godot_v4.7.2-stable_win64_console.exe"
$log = Join-Path $env:TEMP "pompom_fan_test.log"
$err = Join-Path $env:TEMP "pompom_fan_test.err"
$argList = @("--path", (Join-Path $root "godot"), "--position", "-32000,-32000", "res://tests/held_fan_test.tscn")
if ($GameArgs.Count -gt 0) { $argList += "--"; $argList += $GameArgs }
$p = Start-Process -FilePath $godot -ArgumentList $argList -RedirectStandardOutput $log -RedirectStandardError $err -PassThru -NoNewWindow
if (-not $p.WaitForExit($Timeout * 1000)) { Write-Output "TIMEOUT after $Timeout s"; Stop-Process -Id $p.Id -Force }
$noise = "Leaked instance|leaked|PagedAllocator|never freed|still in use"
Get-Content $err -Encoding utf8 -ErrorAction SilentlyContinue | Where-Object { $_ -notmatch $noise } | Select-Object -First 40
Get-Content $log -Encoding utf8 | Where-Object { $_ -notmatch "^PASS " }
