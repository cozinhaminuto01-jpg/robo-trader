# ============================================================================
# INICIAR TESTE DE AUTONOMIA — TESTNET
# ============================================================================
# Começa o sistema multi-agente em testnet
# Vê em tempo real como a IA pensa, decide e executa

Write-Host @"
╔════════════════════════════════════════════════════════════════╗
║   🚀 TESTE DE AUTONOMIA — Sistema Multi-Agente (TESTNET)      ║
╚════════════════════════════════════════════════════════════════╝

Este script vai:
1. Iniciar Fund Manager (gestor central)
2. Criar Agente 1 com 20 EUR testnet
3. IA decide autonomamente onde investir
4. Logs em tempo real de cada decisão
5. Teste até atingir 100 EUR (ou falhar)

Pressiona CTRL+C para parar.
"@

# Criar pastas
if (-not (Test-Path ".\logs")) { mkdir ".\logs" -Force | Out-Null }
if (-not (Test-Path ".\dados")) { mkdir ".\dados" -Force | Out-Null }

# Validar config
if (-not (Test-Path ".\config-testnet.json")) {
    Write-Host "❌ ERRO: config-testnet.json não encontrado!" -ForegroundColor Red
    Write-Host "Edita o ficheiro com as chaves (testnet é OK para teste)"
    exit 1
}

# Valida chaves mínimas
$config = Get-Content ".\config-testnet.json" | ConvertFrom-Json
if ($config.anthropic_api_key -eq "COLOCA_AQUI_CHAVE_ANTHROPIC" -or $config.anthropic_api_key -eq "") {
    Write-Host "⚠️  AVISO: Chave Anthropic não configurada!" -ForegroundColor Yellow
    Write-Host "Edita config-testnet.json com tua chave Anthropic"
    Write-Host "Podes obter em: https://console.anthropic.com/"
    Read-Host "Pressiona ENTER para continuar (IA terá erros, mas testes são locais)"
}

Write-Host "`n✅ Iniciando..." -ForegroundColor Green

# Inicia Fund Manager em background
Write-Host "📊 Iniciando Fund Manager..." -ForegroundColor Cyan
$fundJob = Start-Job -FilePath ".\fund-manager.ps1" -ArgumentList @(".\config-testnet.json")

# Aguarda um segundo para Fund Manager inicializar
Start-Sleep -Seconds 2

# Inicia Agente 1 em background
Write-Host "🤖 Iniciando Agente 1..." -ForegroundColor Cyan
$agente1Job = Start-Job -FilePath ".\agente-template.ps1" -ArgumentList @("Agente_1", 20, ".\config-testnet.json")

Write-Host "`n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Green
Write-Host "✅ Sistema em execução!" -ForegroundColor Green
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Green

Write-Host @"

📊 Monitorização em tempo real:
   Logs: .\logs\
   Estado Fundo: .\estado-fundo.json
   Estado Agente 1: .\estado-Agente_1.json

Outputs:
"@

# Mostra logs em tempo real
$logDir = ".\logs"
$lastFile = $null

while ($true) {
    $logFiles = Get-ChildItem $logDir -Filter "*.log" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending

    if ($logFiles) {
        $currentFile = $logFiles[0].FullName

        if ($lastFile -ne $currentFile) {
            Write-Host "`n📝 Lendo: $($logFiles[0].Name)" -ForegroundColor Yellow
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

    # Verifica se jobs ainda estão a rodar
    if ((Get-Job -ID $fundJob.ID -ErrorAction SilentlyContinue | Where-Object { $_.State -eq "Running" }) -eq $null) {
        Write-Host "`n❌ Fund Manager parou!" -ForegroundColor Red
        break
    }
    if ((Get-Job -ID $agente1Job.ID -ErrorAction SilentlyContinue | Where-Object { $_.State -eq "Running" }) -eq $null) {
        Write-Host "`n❌ Agente 1 parou!" -ForegroundColor Red
        break
    }
}

Write-Host "`nParando sistema..." -ForegroundColor Yellow
Stop-Job -ID $fundJob.ID, $agente1Job.ID -ErrorAction SilentlyContinue
Remove-Job -ID $fundJob.ID, $agente1Job.ID -ErrorAction SilentlyContinue

Write-Host "`n✅ Sistema parado. Consulta logs em: .\logs\" -ForegroundColor Green
