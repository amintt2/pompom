# Lance le test d'interface avec un delai maximum et affiche le rapport.
# Usage : powershell -File godot/tests/run_ui_test.ps1 [-Timeout 300] [-- args]
param([int]$Timeout = 420, [string[]]$GameArgs = @())
Remove-Item (Join-Path $PSScriptRoot "ui_test_log.txt"), (Join-Path $PSScriptRoot "ui_test_errors.txt") -ErrorAction SilentlyContinue
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$godot = Join-Path $root "tools\godot\Godot_v4.7.2-stable_win64_console.exe"
$log = Join-Path $env:TEMP "pompom_ui_test.log"
$err = Join-Path $env:TEMP "pompom_ui_test.err"
$argList = @("--path", (Join-Path $root "godot"), "res://tests/ui_test.tscn")
if ($GameArgs.Count -gt 0) { $argList += "--"; $argList += $GameArgs }
$p = Start-Process -FilePath $godot -ArgumentList $argList -RedirectStandardOutput $log -RedirectStandardError $err -PassThru -NoNewWindow
if (-not $p.WaitForExit($Timeout * 1000)) { Write-Output "TIMEOUT after $Timeout s"; Stop-Process -Id $p.Id -Force; Get-Process | Where-Object { $_.ProcessName -like "Godot_v4.7.2*" } | Stop-Process -Force }
$noise = "Leaked instance|utilities.cpp|leaked|rendering_device.cpp|PagedAllocator|paged_allocator|object.cpp:|resource.cpp|shader_rd|never freed|instance_notify_deleted"
Get-Content $err -Encoding utf8 -ErrorAction SilentlyContinue | Where-Object { $_ -notmatch $noise } | Where-Object { $_ -match "ERROR|SCRIPT|at: |Parse" } | Select-Object -First 60
$tl = Join-Path $PSScriptRoot "ui_test_log.txt"
if (Test-Path $tl) { Get-Content $tl -Encoding utf8 | Where-Object { $_ -notmatch "^(PASS|SHOT) " } }
$te = Join-Path $PSScriptRoot "ui_test_errors.txt"
if (Test-Path $te) { "--- errors file ---"; Get-Content $te -Encoding utf8 | Select-Object -First 40 }
Get-Process | Where-Object { $_.ProcessName -like "Godot_v4.7.2*" } | Stop-Process -Force -ErrorAction SilentlyContinue

