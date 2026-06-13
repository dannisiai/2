$ErrorActionPreference = "Stop"

$Workspace = "C:\token"
$Python = Join-Path $Workspace ".venv\Scripts\python.exe"
$Script = Join-Path $Workspace "scripts\execute_buyback_once.py"
$LogDir = Join-Path $Workspace "logs"
$LogFile = Join-Path $LogDir "buyback-automation.log"

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
Set-Location $Workspace

$Now = Get-Date -Format "yyyy-MM-dd HH:mm:ss zzz"
Add-Content -Path $LogFile -Encoding utf8 -Value ""
Add-Content -Path $LogFile -Encoding utf8 -Value "===== $Now ====="

$Output = & $Python $Script 2>&1
$Output | Out-File -FilePath $LogFile -Append -Encoding utf8
exit $LASTEXITCODE
