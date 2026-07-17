#powershell script to run all services during indev (i dont want to have to build iamges over and over)

#allow to ingest -Stop so use can be ./dev.ps1 -Stop
param([switch]$Stop)

$py = "C:\Users\Jomar\VSCode\ML\Work\work\Scripts\python.exe"


if ($Stop){
    #if there is something listening on these ports, kill the process
    foreach ($port in 3000, 8000, 5000){
        Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue | ForEach-Object { Stop-Process -Id $_.OwningProcess -Force }
    }
    Write-Host "All Servers Stopped"
    return
}

#if not stop, run all scripts necessary
Start-Process powershell -ArgumentList "-NoExit", "-Command",
    "`$Host.UI.RawUI.WindowTitle = 'backend :5000'; Set-Location '$PSScriptRoot\backend_routeit'; & '$py' app.py"

Start-Process powershell -ArgumentList "-NoExit", "-Command",
    "`$Host.UI.RawUI.WindowTitle = 'gateway :8080'; Set-Location '$PSScriptRoot\rate_limiter'; go run ."

Start-Process powershell -ArgumentList "-NoExit", "-Command",
    "`$Host.UI.RawUI.WindowTitle = 'frontend :3000'; Set-Location '$PSScriptRoot\routeit'; npm run dev"

Write-Host "backend  -> http://localhost:5000"
Write-Host "gateway  -> http://localhost:8080"
Write-Host "frontend -> http://localhost:3000"
