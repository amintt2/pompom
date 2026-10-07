# Configure le serveur MCP "coolify" (github:amintt2/coolify-mcp) pour Claude Code
# SANS que le jeton passe par le chat : il est lu dans TON presse-papiers, verifie, masque, puis vide.
#
#   1. https://mciut.fr/security/api-tokens > Create (droits : read, read:sensitive, write, deploy ; pas root)
#   2. Copie le jeton (Ctrl+C)
#   3. powershell -ExecutionPolicy Bypass -File server\feedback\setup-coolify-mcp.ps1
param([string]$Url = "https://mciut.fr")
$ErrorActionPreference = 'Stop'

if (-not $Url) { $Url = Read-Host "Adresse de ton Coolify (ex. https://mciut.fr)" }
$Url = $Url.Trim().TrimEnd('/')
if ($Url -notmatch '^https?://[^\s/]+') { Write-Host "Adresse invalide : $Url" -ForegroundColor Red; exit 1 }

$tok = Get-Clipboard -Raw
if ($tok) { $tok = $tok.Trim() }
if (-not $tok) { Write-Host "Le presse-papiers est vide : copie d'abord le jeton ($Url/security/api-tokens), puis relance." -ForegroundColor Red; exit 1 }
if ($tok -match '\s' -or $tok -notmatch '^\d+\|[A-Za-z0-9]{20,}$') {
  Write-Host "Le presse-papiers ne ressemble pas a un jeton Coolify (attendu : 12|abc...). Rien n'a ete modifie." -ForegroundColor Red
  exit 1
}
$masked = $tok.Substring(0, 4) + "..." + $tok.Substring($tok.Length - 4) + " ($($tok.Length) caracteres)"
Write-Host ""
Write-Host "Coolify : $Url"
Write-Host "Jeton   : $masked"

# l'API repond-elle avec ce jeton ?
try {
  $v = Invoke-RestMethod -Uri "$Url/api/v1/version" -Headers @{ Authorization = "Bearer $tok" } -TimeoutSec 20
  Write-Host "API Coolify OK (version $v)" -ForegroundColor Green
} catch {
  Write-Host "L'API ne repond pas avec ce jeton : $($_.Exception.Message)" -ForegroundColor Red
  Write-Host "Verifie : Settings > Advanced > API Access active (et 'Allowed IPs' si renseigne)."
  exit 1
}

$ok = Read-Host "Configurer le MCP 'coolify' de Claude Code avec ces valeurs ? [o/N]"
if ($ok -notin @('o', 'O', 'oui', 'y', 'yes')) { Write-Host "Annule, rien n'a ete modifie."; exit 1 }

# on remplace l'ancienne entree (cassee) ; sous Windows, npx doit passer par "cmd /c"
# (PowerShell 5.1 transforme la moindre sortie d'erreur d'un programme en erreur bloquante : on passe par cmd)
$ErrorActionPreference = 'Continue'
cmd /c "claude mcp remove coolify -s user >nul 2>&1"
# (Windows PowerShell 5.1 avale un "--" nu : on le passe entre guillemets)
& claude mcp add coolify --scope user -e "COOLIFY_URL=$Url" -e "COOLIFY_TOKEN=$tok" '--' cmd /c npx -y github:amintt2/coolify-mcp
if ($LASTEXITCODE -ne 0) { Write-Host "La commande 'claude mcp add' a echoue." -ForegroundColor Red; exit 1 }

Set-Clipboard -Value " "
$tok = $null
Write-Host "MCP 'coolify' configure. Presse-papiers vide." -ForegroundColor Green
Write-Host "Reviens dans Claude : il faut reconnecter le serveur MCP (ou ouvrir une nouvelle session)."
