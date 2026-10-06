# Pompom - installation de l'assistant local (une seule fois, ~1,1 Go a telecharger).
#   powershell -ExecutionPolicy Bypass -File assistant\setup.ps1 [-Light] [-Python C:\chemin\python.exe]
# -Light : modele Qwen2.5-0.5B (491 Mo, Apache-2.0) au lieu de Llama-3.2-1B (808 Mo, meilleur).
# Apres l'installation, plus rien ne passe par Internet.
param([switch]$Light, [string]$Python = "")
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$build = 'b11443'  # version de llama.cpp testee
Set-Location $root

# 1) Python 3.11 + venv (dependance unique : comtypes, pour UI Automation)
if (-not $Python) {
    $cands = @("$env:LOCALAPPDATA\Programs\Python\Python311\python.exe", "$env:LOCALAPPDATA\Programs\Python\Python312\python.exe")
    $Python = $cands | Where-Object { Test-Path $_ } | Select-Object -First 1
}
if (-not $Python) {
    Write-Host "Python 3.11 introuvable : winget install --id Python.Python.3.11 --scope user"
    exit 1
}
if (-not (Test-Path .venv\Scripts\python.exe)) { & $Python -m venv .venv }
& .venv\Scripts\python.exe -m pip install -q --upgrade pip
& .venv\Scripts\python.exe -m pip install -q "comtypes>=1.4"

# 2) llama.cpp officiel (Vulkan pour AMD/NVIDIA/Intel + CPU en secours)
foreach ($k in 'vulkan', 'cpu') {
    if (-not (Test-Path "llama\$k\llama-server.exe")) {
        $zip = "llama\llama-$build-$k.zip"
        New-Item -ItemType Directory -Force "llama\$k" | Out-Null
        Invoke-WebRequest -UseBasicParsing "https://github.com/ggml-org/llama.cpp/releases/download/$build/llama-$build-bin-win-$k-x64.zip" -OutFile $zip
        Expand-Archive $zip -DestinationPath "llama\$k" -Force
        Remove-Item $zip
    }
}

# 3) modele GGUF (Hugging Face)
New-Item -ItemType Directory -Force models | Out-Null
$models = @(
    @{ f = 'Llama-3.2-1B-Instruct-Q4_K_M.gguf'; u = 'https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf' },
    @{ f = 'qwen2.5-0.5b-instruct-q4_k_m.gguf'; u = 'https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf' }
)
if ($Light) { $models = @($models[1]) }
foreach ($m in $models) {
    if (-not (Test-Path "models\$($m.f)")) {
        Write-Host "Telechargement $($m.f)..."
        Invoke-WebRequest -UseBasicParsing $m.u -OutFile "models\$($m.f).part"
        Move-Item "models\$($m.f).part" "models\$($m.f)"
    }
}
& .venv\Scripts\python.exe data\gen_synthetic.py | Out-Null
Write-Host "OK. Test : .venv\Scripts\python.exe tests\smoke_service.py"
if ($Light) { Write-Host "Mode leger : definir POMPOM_ASSIST_MODEL=qwen2.5-0.5b-instruct-q4_k_m.gguf" }
