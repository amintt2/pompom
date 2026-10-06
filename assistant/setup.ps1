# Pompom - installation de l'assistant local.
#
# Installation normale (joueurs) : SANS PyTorch.
#   powershell -ExecutionPolicy Bypass -File assistant\setup.ps1
#   -> .venv (Python 3.11 + onnxruntime-directml, numpy, tokenizers, pillow, mss, comtypes : ~170 Mo)
#   -> verifie models\ (~690 Mo d'ONNX : livres avec le jeu, ou fabriques par -Dev ci-dessous)
#
# Developpement (une fois, pour fabriquer models\) :
#   powershell -ExecutionPolicy Bypass -File assistant\setup.ps1 -Dev [-Retrain]
#   -> dev\.venv (torch 2.4.1 CPU + torch-directml + stuntd[train] + laya + transformers<5 + onnx : ~1,5 Go)
#   -> dev\laya_model (Laya multilingual, Apache-2.0), dev\siglip (SigLIP base ONNX, Apache-2.0)
#   -> dev\heads : tetes stuntd (re)entrainees hors ligne si absentes ou -Retrain (CPU, ~1 h 30)
#   -> export_onnx.py ecrit models\
# Apres l'installation, plus rien ne passe par Internet.
param([switch]$Dev, [switch]$Retrain, [string]$Python = "")
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $root

if (-not $Python) {
    $cands = @("$env:LOCALAPPDATA\Programs\Python\Python311\python.exe", "$env:LOCALAPPDATA\Programs\Python\Python312\python.exe")
    $Python = $cands | Where-Object { Test-Path $_ } | Select-Object -First 1
}
if (-not $Python) {
    Write-Host "Python 3.11 introuvable : winget install --id Python.Python.3.11 --scope user"
    exit 1
}

# ---------------------------------------------------------------- execution (toujours)
if (-not (Test-Path .venv\Scripts\python.exe)) { & $Python -m venv .venv }
# --no-deps : onnxruntime et tokenizers tireraient sympy, huggingface_hub, httpx... inutiles ici (~100 Mo)
& .venv\Scripts\python.exe -m pip install -q --no-deps "onnxruntime-directml==1.24.4" "numpy>=2,<3" "tokenizers==0.23.2" "pillow>=11" "mss>=10" "comtypes>=1.4"

if ($Dev) {
    New-Item -ItemType Directory -Force dev | Out-Null
    if (-not (Test-Path dev\.venv\Scripts\python.exe)) { & $Python -m venv dev\.venv }
    $py = "dev\.venv\Scripts\python.exe"
    & $py -m pip install -q --upgrade pip
    # torch-directml impose torch 2.4.1 ; transformers 5 demande un torch plus recent -> transformers<5
    & $py -m pip install -q "torch-directml==0.2.5.dev240914" "stuntd[train]==0.1.3" "transformers>=4.48,<5" `
        "onnx" "onnxruntime-directml==1.24.4" "comtypes>=1.4" "mss>=10" "psutil"
    & $py -c "from huggingface_hub import snapshot_download as d; d('convaiinnovations/laya', local_dir='dev/laya_model', allow_patterns=['multilingual/rl_agent_config.json','multilingual/model.safetensors','multilingual/tokenizer/*','multilingual/encoder/*','README.md'])"
    & $py -c "from huggingface_hub import snapshot_download as d; d('Xenova/siglip-base-patch16-224', local_dir='dev/siglip', allow_patterns=['onnx/vision_model_fp16.onnx','onnx/text_model.onnx','*.json'])"
    & $py data\gen_synthetic.py | Out-Null
    if ($Retrain -or -not (Test-Path dev\heads\text_kind\head.safetensors)) { & $py train_heads.py }
    & $py export_onnx.py
}

$need = @('laya_encoder.mixed.onnx', 'head_field_kind.fp16.onnx', 'head_text_kind.fp16.onnx', 'head_base.fp16.onnx',
          'heads.json', 'laya_tokenizer.json', 'siglip_vision.fp16.onnx', 'siglip_prompts.npz', 'siglip_logit.json')
$missing = $need | Where-Object { -not (Test-Path "models\$_") }
if ($missing) {
    Write-Host "models\ incomplet ($($missing -join ', ')) : copiez models\ livre avec le jeu, ou lancez setup.ps1 -Dev."
    Write-Host "Sans models\, les suggestions marchent quand meme (regles seules) ; la vision reste desactivee."
    exit 2
}
Write-Host "OK. Test : .venv\Scripts\python.exe tests\smoke_service.py"
