# ============================================================================
# INICIAR TESTE DE AUTONOMIA - TESTNET
# ============================================================================
# Comeca o sistema multi-agente em testnet
# Ve em tempo real como a IA pensa, decide e executa

Write-Host "=========================================================="
Write-Host "TESTE DE AUTONOMIA - Sistema Multi-Agente (TESTNET)"
Write-Host "=========================================================="
Write-Host ""
Write-Host "Este script vai:"
Write-Host "1. Iniciar Fund Manager (gestor central)"
Write-Host "2. Criar Agente 1 com 20 EUR testnet"
Write-Host "3. IA decide autonomamente onde investir"
Write-Host "4. Logs em tempo real de cada decisao"
Write-Host "5. Teste ate atingir 100 EUR (ou falhar)"
Write-Host ""
Write-Host "Pressiona CTRL+C para parar."
Write-Host ""

# Criar pastas
if (-not (Test-Path ".\logs")) { mkdir ".\logs" -Force | Out-Null }
if (-not (Test-Path ".\dados")) { mkdir ".\dados" -Force | Out-Null }

# Validar config
if (-not (Test-Path ".\config-testnet.json")) {
    Write-Host "ERRO: config-testnet.json nao encontrado!" -ForegroundColor Red
    Write-Host "Edita o ficheiro com as chaves (testnet eh OK para teste)"
    exit 1
}

# Valida chaves minimas
$config = Get-Content ".\config-testnet.json" | ConvertFrom-Json
if ($config.anthropic_api_key -eq "COLOCA_AQUI_CHAVE_ANTHROPIC" -or $config.anthropic_api_key -eq "") {
    Write-Host "AVISO: Chave Anthropic nao configurada!" -ForegroundColor Yellow
    Write-Host "Edita config-testnet.json com tua chave Anthropic"
    Write-Host "Podes obter em: https://console.anthropic.com/"
    Read-Host "Pressiona ENTER para continuar (IA tera erros, mas testes sao locais)"
}

Write-Host "Iniciando..." -ForegroundColor Green

# Inicia Fund Manager em background
Write-Host "Iniciando Fund Manager..." -ForegroundColor Cyan
$fundJob = Start-Job -FilePath ".\fund-manager.ps1" -ArgumentList @(".\config-testnet.json")

# Aguarda um segundo para Fund Manager inicializar
Start-Sleep -Seconds 2

# Inicia Agente 1 em background
Write-Host "Iniciando Agente 1..." -ForegroundColor Cyan
$agente1Job = Start-Job -FilePath ".\agente-template.ps1" -ArgumentList @("Agente_1", 20, ".\config-testnet.json")

Write-Host ""
Write-Host "========================================================" -ForegroundColor Green
Write-Host "Sistema em execucao!" -ForegroundColor Green
Write-Host "========================================================" -ForegroundColor Green

Write-Host ""
Write-Host "Monitorizacao em tempo real:"
Write-Host "   Logs: .\logs\"
Write-Host "   Estado Fundo: .\estado-fundo.json"
Write-Host "   Estado Agente 1: .\estado-Agente_1.json"
Write-Host ""
Write-Host "Outputs:"
Write-Host ""

# Mostra logs em tempo real
$logDir = ".\logs"
$lastFile = $null

while ($true) {
    $logFiles = Get-ChildItem $logDir -Filter "*.log" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending

    if ($logFiles) {
        $currentFile = $logFiles[0].FullName

        if ($lastFile -ne $currentFile) {
            Write-Host ""
            Write-Host "Lendo: $($logFiles[0].Name)" -ForegroundColor Yellow
            $lastFile = $currentFile
            $lastLines = 0
        }

        # Mostra novas linhas
        $content = Get-Content $currentFile
        if ($content) {
            $lineCount = if ($content -is [array]) { $content.Count } else { 1 }
            if ($lineCount -gt $lastLines) {
                if ($content -is [array]) {
                    $content[$lastLines..($lineCount-1)] | ForEach-Object { Write-Host $_ }
                } else {
                    Write-Host $content
                }
                $lastLines = $lineCount
            }
        }
    }

    # Aguarda um pouco antes de verificar novamente
    Start-Sleep -Milliseconds 500

    # Verifica se jobs ainda estao a rodar
    if ((Get-Job -ID $fundJob.ID -ErrorAction SilentlyContinue | Where-Object { $_.State -eq "Running" }) -eq $null) {
        Write-Host ""
        Write-Host "Fund Manager parou!" -ForegroundColor Red
        break
    }
    if ((Get-Job -ID $agente1Job.ID -ErrorAction SilentlyContinue | Where-Object { $_.State -eq "Running" }) -eq $null) {
        Write-Host ""
        Write-Host "Agente 1 parou!" -ForegroundColor Red
        break
    }
}

Write-Host ""
Write-Host "Parando sistema..." -ForegroundColor Yellow
Stop-Job -ID $fundJob.ID, $agente1Job.ID -ErrorAction SilentlyContinue
Remove-Job -ID $fundJob.ID, $agente1Job.ID -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "Sistema parado. Consulta logs em: .\logs" -ForegroundColor Green
