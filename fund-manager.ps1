# ============================================================================
# FUND MANAGER - Sistema Multi-Agente de Trading Autonomo
# ============================================================================
# Gestor central que coordena multiplos agentes de IA
# Cada agente roda em paralelo, decide autonomamente onde investir
# Meta: crescimento continuo ate meta global, depois repouso

param(
    [string]$ConfigPath = ".\config-testnet.json"
)

# Carrega config
$config = Get-Content $ConfigPath | ConvertFrom-Json

# Estrutura global do fundo
$fundoGlobal = @{
    capitalTotal = $config.capital_inicial
    agentes = @()
    metaAtual = 100
    cicloAtual = 1
    emRepouso = $false
    ultimoRepouso = $null
    historico = @()
}

# Ficheiros de log
$logDir = ".\logs"
if (-not (Test-Path $logDir)) { mkdir $logDir -Force | Out-Null }
$logFile = "$logDir\fundo-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"

# ============================================================================
# FUNCOES AUXILIARES
# ============================================================================

function Log-Evento {
    param([string]$mensagem, [string]$nivel = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $linha = "[$timestamp] [$nivel] $mensagem"
    Write-Host $linha
    Add-Content -Path $logFile -Value $linha
}

function Save-Estado {
    $fundoGlobal | ConvertTo-Json | Set-Content ".\estado-fundo.json"
}

# ============================================================================
# LOOP PRINCIPAL
# ============================================================================

Log-Evento "Fund Manager iniciado" "INIT"
Log-Evento "Capital Total: $($fundoGlobal.capitalTotal) EUR" "INFO"
Log-Evento "Meta Atual: $($fundoGlobal.metaAtual) EUR" "INFO"

$ciclo = 1
while ($true) {
    Log-Evento "===== Ciclo $ciclo =====" "CICLO"

    # Verifica estado dos ficheiros
    if (Test-Path ".\estado-Agente_1.json") {
        $estado = Get-Content ".\estado-Agente_1.json" | ConvertFrom-Json
        Log-Evento "Agente_1: Saldo=$($estado.saldo) EUR | Trades=$($estado.trades.Count) | WinRate=$($estado.winRate)%" "STATUS"

        if ($estado.saldo -ge $fundoGlobal.metaAtual) {
            Log-Evento "META ATINGIDA! Novo saldo: $($estado.saldo) EUR" "SUCESSO"
            $fundoGlobal.metaAtual = $fundoGlobal.metaAtual * 2
            Log-Evento "Nova meta: $($fundoGlobal.metaAtual) EUR" "INFO"
        }
    }

    Save-Estado
    Log-Evento "===== Ciclo $ciclo Concluido =====" "CICLO"

    $ciclo++
    Start-Sleep -Seconds $config.ciclo_segundos
}
