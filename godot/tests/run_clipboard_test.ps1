# Lance le test du presse-papiers avec un delai maximum (une seule instance, toujours tuee a la fin).
# Usage : powershell -File godot/tests/run_clipboard_test.ps1 [-Timeout 200] [-GameArgs --scale=1.5]
param([int]$Timeout = 200, [string[]]$GameArgs = @())
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$godot = Join-Path $root "tools\godot\Godot_v4.7.2-stable_win64_console.exe"
$log = Join-Path $env:TEMP "pompom_clip_test.log"
$err = Join-Path $env:TEMP "pompom_clip_test.err"
$argList = @("--path", (Join-Path $root "godot"), "res://tests/clipboard_test.tscn")
if ($GameArgs.Count -gt 0) { $argList += "--"; $argList += $GameArgs }
$p = Start-Process -FilePath $godot -ArgumentList $argList -RedirectStandardOutput $log -RedirectStandardError $err -PassThru -NoNewWindow
if (-not $p.WaitForExit($Timeout * 1000)) { Write-Output "TIMEOUT after $Timeout s"; Stop-Process -Id $p.Id -Force }
Get-Process | Where-Object { $_.ProcessName -like "Godot_v4.7.2*" } | Stop-Process -Force -ErrorAction SilentlyContinue
$noise = "Leaked instance|leaked|PagedAllocator|never freed|still in use"
Get-Content $err -Encoding utf8 -ErrorAction SilentlyContinue | Where-Object { $_ -notmatch $noise } | Select-Object -First 40
Get-Content $log -Encoding utf8 | Where-Object { $_ -notmatch "^PASS " }
