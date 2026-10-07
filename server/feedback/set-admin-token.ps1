# Cree le jeton d'administration du serveur de contributions (export, stats) SANS qu'il passe par le chat :
# genere au hasard ici, envoye a Coolify, garde dans un fichier lisible par toi seul, puis le serveur redemarre.
#
#   powershell -ExecutionPolicy Bypass -File server\feedback\set-admin-token.ps1
# Utilise l'adresse et le jeton Coolify du MCP "coolify" de Claude Code (~/.claude.json).
param([string]$App = "rob7ngpwkwkf3f3yoccdvc7h")
$ErrorActionPreference = 'Stop'

$cfgPath = Join-Path $env:USERPROFILE ".claude.json"
if (-not (Test-Path $cfgPath)) { Write-Host "~/.claude.json introuvable." -ForegroundColor Red; exit 1 }
# (lu avec Node : le ConvertFrom-Json de PowerShell 5.1 refuse ce fichier, cles en double a la casse pres)
$js = "const c=require(process.argv[1]);const e=(c.mcpServers&&c.mcpServers.coolify&&c.mcpServers.coolify.env)||{};process.stdout.write(JSON.stringify({COOLIFY_URL:e.COOLIFY_URL||'',COOLIFY_TOKEN:e.COOLIFY_TOKEN||''}))"
$cool = (node -e $js $cfgPath) | ConvertFrom-Json
if (-not $cool -or -not $cool.COOLIFY_URL -or -not $cool.COOLIFY_TOKEN) {
  Write-Host "Le MCP 'coolify' n'est pas configure (lance d'abord setup-coolify-mcp.ps1)." -ForegroundColor Red; exit 1
}
$base = $cool.COOLIFY_URL.TrimEnd('/') + "/api/v1"
$headers = @{ Authorization = "Bearer $($cool.COOLIFY_TOKEN)"; Accept = "application/json" }

# 32 octets aleatoires (generateur cryptographique) -> 64 caracteres hexadecimaux
$bytes = New-Object byte[] 32
[System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
$admin = ($bytes | ForEach-Object { $_.ToString("x2") }) -join ""

$body = @{ data = @(@{ key = "ADMIN_TOKEN"; value = $admin; is_preview = $false; is_runtime = $true; is_buildtime = $false; is_build_time = $false; is_literal = $true }) } | ConvertTo-Json -Depth 5
Invoke-RestMethod -Method Patch -Uri "$base/applications/$App/envs/bulk" -Headers $headers -ContentType "application/json" -Body $body | Out-Null
Write-Host "ADMIN_TOKEN enregistre dans Coolify (valeur jamais affichee)." -ForegroundColor Green

# copie locale, lisible par toi seul
$dir = Join-Path $env:USERPROFILE ".pompom"
New-Item -ItemType Directory -Force $dir | Out-Null
$file = Join-Path $dir "feedback_admin_token.txt"
Set-Content -Path $file -Value $admin -NoNewline -Encoding ascii
icacls $file /inheritance:r /grant:r "$($env:USERNAME):(R,W)" | Out-Null
Write-Host "Copie gardee dans $file (toi seul peux la lire)."

Invoke-RestMethod -Method Get -Uri "$base/applications/$App/restart" -Headers $headers | Out-Null
Write-Host "Serveur redemarre : l'export et les stats sont actifs dans ~30 s." -ForegroundColor Green
$admin = $null
