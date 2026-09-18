# ============================================================================
# FUND MANAGER — Sistema Multi-Agente de Trading Autónomo
# ============================================================================
# Gestor central que coordena múltiplos agentes de IA
# Cada agente roda em paralelo, decide autonomamente onde investir
# Meta: crescimento contínuo até meta global, depois repouso

param(
    [string]$ConfigPath = ".\config-testnet.json"
)

# Carrega config
$config = Get-Content $ConfigPath | ConvertFrom-Json

# Estrutura global do fundo
$global:fundoGlobal = @{
    capitalTotal = $config.capital_inicial
    agentes = @()
    metaAtual = $config.meta_descanso
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
# FUNÇÕES AUXILIARES
# ============================================================================

function Log-Evento {
    param([string]$mensagem, [string]$nivel = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $linha = "[$timestamp] [$nivel] $mensagem"
    Write-Host $linha
    Add-Content -Path $logFile -Value $linha
}

function Read-Config {
    return Get-Content $ConfigPath | ConvertFrom-Json
}

function Save-Estado {
    $estado = @{
        timestamp = Get-Date
        capitalTotal = $global:fundoGlobal.capitalTotal
        agentes = $global:fundoGlobal.agentes
        metaAtual = $global:fundoGlobal.metaAtual
        cicloAtual = $global:fundoGlobal.cicloAtual
    }
    $estado | ConvertTo-Json | Set-Content ".\estado-fundo.json"
}

function Load-Estado {
    if (Test-Path ".\estado-fundo.json") {
        return Get-Content ".\estado-fundo.json" | ConvertFrom-Json
    }
    return $null
}

function Atualiza-SaldoGlobal {
    $totalista = 0
    foreach ($agente in $global:fundoGlobal.agentes) {
        if ($agente.saldo -gt 0) {
            $totalista += $agente.saldo
        }
    }
    $global:fundoGlobal.capitalTotal = $totalista
    return $totalista
}

function Check-MetaGlobal {
    $total = Atualiza-SaldoGlobal

    if ($total -ge $global:fundoGlobal.metaAtual) {
        Log-Evento "🎉 META ATINGIDA! Total: $total EUR | Meta: $($global:fundoGlobal.metaAtual) EUR" "SUCESSO"
        $global:fundoGlobal.emRepouso = $true
        $global:fundoGlobal.ultimoRepouso = Get-Date

        # Dobra meta para próximo ciclo
        $global:fundoGlobal.metaAtual *= 2
        Log-Evento "Nova meta definida: $($global:fundoGlobal.metaAtual) EUR" "INFO"

        return $true
    }
    return $false
}

function Cria-NovoAgente {
    param([decimal]$capitalInicial = 20)

    $novoID = "Agente_$(Get-Random -Minimum 10000 -Maximum 99999)"
    $novoAgente = @{
        id = $novoID
        saldo = $capitalInicial
        saldoInicial = $capitalInicial
        posicoes = @()
        historico = @()
        estrategia = "Aguardando IA"
        criado = Get-Date
        ultimoTrade = $null
        winRate = 0
    }

    $global:fundoGlobal.agentes += $novoAgente
    Log-Evento "✨ Novo agente criado: $novoID com $capitalInicial EUR" "INFO"

    return $novoAgente
}

function Aloca-CapitalParaNovoAgente {
    param([decimal]$montante = 20)

    # Verifica se há capital disponível
    $total = Atualiza-SaldoGlobal
    if ($total -lt ($montante + 5)) {
        Log-Evento "⚠️ Capital insuficiente para criar novo agente (disponível: $total EUR)" "AVISO"
        return $false
    }

    # Remove montante do agente que está a contribuir
    # (será feito pelo próprio agente no seu ciclo)
    Cria-NovoAgente -capitalInicial $montante
    return $true
}

function Relatorio-Status {
    $total = Atualiza-SaldoGlobal
    $count = @($global:fundoGlobal.agentes | Where-Object { $_.saldo -gt 0 }).Count
    $emRepouso = $global:fundoGlobal.emRepouso

    $relatorio = @"
╔════════════════════════════════════════════════════╗
║          RELATÓRIO DO FUNDO — Ciclo $($global:fundoGlobal.cicloAtual)           ║
╠════════════════════════════════════════════════════╣
║ 💰 Capital Total: $total EUR
║ 🤖 Agentes Ativos: $count
║ 🎯 Meta Atual: $($global:fundoGlobal.metaAtual) EUR
║ 📊 Progresso: $([Math]::Round(($total / $global:fundoGlobal.metaAtual) * 100, 1))%
║ 😴 Em Repouso: $emRepouso
╠════════════════════════════════════════════════════╣
"@

    foreach ($agente in $global:fundoGlobal.agentes) {
        if ($agente.saldo -gt 0) {
            $roi = [Math]::Round((($agente.saldo - $agente.saldoInicial) / $agente.saldoInicial) * 100, 1)
            $relatorio += "`n║ $($agente.id): $($agente.saldo) EUR (ROI: $roi% | Win Rate: $($agente.winRate)%)"
        }
    }

    $relatorio += "`n╚════════════════════════════════════════════════════╝"
    return $relatorio
}

# ============================================================================
# INICIALIZAÇÃO
# ============================================================================

function Inicializa {
    Log-Evento "═══════════════════════════════════════════════════════" "INFO"
    Log-Evento "🚀 FUND MANAGER — Sistema de Trading Autónomo" "INFO"
    Log-Evento "Ambiente: $($config.ambiente) | Capital: $($config.capital_inicial) EUR" "INFO"
    Log-Evento "═══════════════════════════════════════════════════════" "INFO"

    # Tenta carregar estado anterior
    $estadoAnterior = Load-Estado
    if ($estadoAnterior) {
        Log-Evento "📂 Estado anterior carregado" "INFO"
        $global:fundoGlobal.capitalTotal = $estadoAnterior.capitalTotal
        $global:fundoGlobal.agentes = $estadoAnterior.agentes
        $global:fundoGlobal.metaAtual = $estadoAnterior.metaAtual
        $global:fundoGlobal.cicloAtual = $estadoAnterior.cicloAtual
    } else {
        Log-Evento "🆕 Novo sistema, criando primeiro agente..." "INFO"
        Cria-NovoAgente -capitalInicial $config.capital_inicial
    }

    Save-Estado
    Write-Host (Relatorio-Status)
}

# ============================================================================
# LOOP PRINCIPAL
# ============================================================================

function Executa-Loop {
    $contador = 0
    $intervaloRelatrio = 10  # a cada 10 ciclos

    while ($true) {
        $contador++
        $global:fundoGlobal.cicloAtual = $contador

        # 1. Check repouso
        if ($global:fundoGlobal.emRepouso) {
            if ((Get-Date) - $global:fundoGlobal.ultimoRepouso -gt [TimeSpan]::FromHours(24)) {
                Log-Evento "✅ Repouso terminado! Voltando ao normal." "INFO"
                $global:fundoGlobal.emRepouso = $false
            } else {
                Log-Evento "😴 Sistema em repouso... zzz" "INFO"
                Start-Sleep -Seconds 60
                continue
            }
        }

        # 2. Check meta
        if (Check-MetaGlobal) {
            Write-Host "`n$(Relatorio-Status)`n"
        }

        # 3. Relatório periódico
        if ($contador % $intervaloRelatrio -eq 0) {
            Write-Host "`n$(Relatorio-Status)`n"
        }

        # 4. Salva estado
        Save-Estado

        # 5. Aguarda próximo ciclo
        Start-Sleep -Seconds $config.ciclo_segundos
    }
}

# ============================================================================
# PONTO DE ENTRADA
# ============================================================================

Inicializa
Executa-Loop
