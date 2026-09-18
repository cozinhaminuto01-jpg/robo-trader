# ============================================================================
# AGENTE GENÉRICO — Trader Autónomo com IA
# ============================================================================
# Cada instância roda em paralelo, toma decisões próprias
# Usa Claude Haiku para pensar onde investir, como, quando
# Sem estratégia pré-configurada: IA descobre

param(
    [string]$AgenteID = "Agente_1",
    [decimal]$SaldoInicial = 20,
    [string]$ConfigPath = ".\config-testnet.json"
)

# Carrega config
$config = Get-Content $ConfigPath | ConvertFrom-Json

# Estado do agente
$estado = @{
    id = $AgenteID
    saldo = $SaldoInicial
    saldoInicial = $SaldoInicial
    posicoes = @()
    historico = @()
    trades = @()
    winRate = 0
    ultimaTradaEm = $null
}

# Ficheiro de log pessoal
$logDir = ".\logs"
if (-not (Test-Path $logDir)) { mkdir $logDir -Force | Out-Null }
$logFile = "$logDir\$AgenteID-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"

# ============================================================================
# FUNÇÕES AUXILIARES
# ============================================================================

function Log {
    param([string]$msg, [string]$tipo = "INFO")
    $ts = Get-Date -Format "HH:mm:ss"
    $linha = "[$ts] [$tipo] $msg"
    Write-Host "[$AgenteID] $linha"
    Add-Content -Path $logFile -Value $linha
}

function Save-Estado {
    $estado | ConvertTo-Json | Set-Content ".\estado-$AgenteID.json"
}

function Load-Estado {
    if (Test-Path ".\estado-$AgenteID.json") {
        return Get-Content ".\estado-$AgenteID.json" | ConvertFrom-Json
    }
    return $null
}

# ============================================================================
# BINANCE API (Testnet/Real)
# ============================================================================

function Get-BalanceBinance {
    # Em testnet, retorna simulação
    # Em real, chama API real

    if ($config.ambiente -eq "testnet") {
        # Simulação: retorna saldo atual
        return @{
            USDT = $estado.saldo
            BTC = 0
            ETH = 0
            SOL = 0
        }
    } else {
        # TODO: Chamada real à API Binance
        Write-Host "Função real não implementada"
    }
}

function Get-MercadoData {
    # Busca dados do mercado (pares com movimento)
    # Em testnet: dados simulados

    if ($config.ambiente -eq "testnet") {
        # Simula pares em movimento
        $pares = @(
            @{ par = "BTC/USDT"; preco = 43250; mudanca24h = 2.5; volume = 1500000000 },
            @{ par = "ETH/USDT"; preco = 2280; mudanca24h = 1.8; volume = 900000000 },
            @{ par = "SOL/USDT"; preco = 185; mudanca24h = -1.2; volume = 450000000 },
            @{ par = "XRP/USDT"; preco = 2.45; mudanca24h = 0.5; volume = 300000000 },
            @{ par = "ADA/USDT"; preco = 1.15; mudanca24h = 3.2; volume = 250000000 }
        )
        return $pares | Get-Random -Count (Get-Random -Minimum 2 -Maximum 5)
    }
}

# ============================================================================
# CHAMADA À IA (Claude Haiku)
# ============================================================================

function Chama-IA {
    param([hashtable]$contexto)

    $prompt = @"
Tu és um trader autónomo com 20 EUR. Tens liberdade total.
Capital atual: $($contexto.saldo) EUR
Histórico de trades: $($contexto.nTrades) trades, $($contexto.winRate)% vitórias
Mercado agora (pares com movimento):

$($contexto.mercado | ForEach-Object { "- $($_.par): $($_.preco)$ (mudança 24h: $($_.mudanca24h)% | volume: $($_.volume))" } | Out-String)

Contexto:
- Risco máximo por trade: 2% (0.4 EUR)
- Máximo 3 posições abertas
- Se saldo < 15 EUR: modo seguro (só hold, sem compras)
- Se saldo >= 100 EUR: ciclo termina, repouso 24h

Decide AGORA:
1. Que estratégia vê neste mercado? (scalping, swing, grid, hold, etc)
2. Em que par entra? (se entra)
3. Montante? Stop loss? Alvo?
4. Por quê?

Sê conciso. Responde em JSON:
{
  "acao": "compra|venda|hold|analisa",
  "par": "BTC/USDT ou null",
  "montante": 2.5,
  "stopLoss": 1.5,
  "alvo": 3.5,
  "estrategia": "descrição breve",
  "risco": "baixo|médio|alto",
  "confianca": 0.75
}
"@

    # Chama API Anthropic
    $apiKey = $config.anthropic_api_key
    $headers = @{
        "x-api-key" = $apiKey
        "anthropic-version" = "2023-06-01"
        "content-type" = "application/json"
    }

    $body = @{
        model = "claude-3-5-haiku-20241022"
        max_tokens = 500
        messages = @(
            @{
                role = "user"
                content = $prompt
            }
        )
    } | ConvertTo-Json

    try {
        $response = Invoke-RestMethod -Uri "https://api.anthropic.com/v1/messages" `
            -Method POST `
            -Headers $headers `
            -Body $body

        $resposta = $response.content[0].text

        # Tenta parse JSON
        $deciso = $resposta | ConvertFrom-Json
        return $deciso
    } catch {
        Log "Erro ao chamar IA: $_" "ERRO"
        return @{ acao = "hold"; risco = "erro" }
    }
}

# ============================================================================
# SIMULADOR DE TRADES (Testnet)
# ============================================================================

function Simula-Trade {
    param([hashtable]$deciso)

    if ($deciso.acao -eq "hold" -or $deciso.acao -eq "analisa") {
        Log "IA decidiu: $($deciso.acao) — Aguardando próxima oportunidade" "INFO"
        return $null
    }

    # Simula execução do trade
    $resultado = Get-Random -Minimum -5 -Maximum 15  # -5% a +15%
    $montante = $deciso.montante
    $ganho = $montante * ($resultado / 100)
    $novoSaldo = $estado.saldo + $ganho

    Log "TRADE: $($deciso.acao) $montante EUR em $($deciso.par) | Resultado: $resultado% | Ganho: $ganho EUR" "TRADE"

    return @{
        par = $deciso.par
        montante = $montante
        resultado = $resultado
        ganho = $ganho
        estrategia = $deciso.estrategia
        timestamp = Get-Date
    }
}

# ============================================================================
# CICLO PRINCIPAL
# ============================================================================

function Executa-Ciclo {
    param([int]$ciclo)

    Log "═══════ Ciclo $ciclo Iniciado ═══════" "CICLO"

    # 1. Check modo seguro
    if ($estado.saldo -lt 15) {
        Log "⚠️ Modo Seguro: saldo $($estado.saldo) EUR < 15 EUR" "AVISO"
        Log "Aguardando recuperação..." "AVISO"
        return
    }

    # 2. Fetch dados do mercado
    $dadosMercado = Get-MercadoData
    Log "Analisando $($dadosMercado.Count) pares em movimento..." "INFO"

    # 3. Chama IA para decisão
    Log "Consultando IA para decisão..." "IA"
    $contexto = @{
        saldo = $estado.saldo
        nTrades = $estado.trades.Count
        winRate = $estado.winRate
        mercado = $dadosMercado
    }
    $deciso = Chama-IA -contexto $contexto

    Log "IA respondeu: $($deciso | ConvertTo-Json -Compress)" "IA"

    # 4. Executa trade (simulado em testnet)
    $trade = Simula-Trade -deciso $deciso
    if ($trade) {
        $estado.trades += $trade
        $estado.saldo += $trade.ganho
        $estado.ultimaTradaEm = Get-Date

        # Calcula win rate
        $vitorias = @($estado.trades | Where-Object { $_.ganho -gt 0 }).Count
        $estado.winRate = [Math]::Round(($vitorias / $estado.trades.Count) * 100, 1)

        Log "Novo saldo: $($estado.saldo) EUR | Win Rate: $($estado.winRate)%" "RESULTADO"
    }

    # 5. Check objetivo (100 EUR)
    if ($estado.saldo -ge 100) {
        Log "🎉 OBJETIVO ATINGIDO! Saldo: $($estado.saldo) EUR" "SUCESSO"
        $estado.objetivo = "atingido"
    }

    # 6. Salva estado
    Save-Estado
    Log "═══════ Ciclo $ciclo Terminado ═══════`n" "CICLO"
}

# ============================================================================
# PONTO DE ENTRADA
# ============================================================================

Log "🤖 $AgenteID iniciado com $SaldoInicial EUR" "INIT"

# Tenta carregar estado anterior
$estadoAnterior = Load-Estado
if ($estadoAnterior) {
    $estado = $estadoAnterior
    Log "📂 Estado anterior carregado" "INFO"
}

$ciclo = 1
while ($true) {
    Executa-Ciclo -ciclo $ciclo
    $ciclo++

    # Aguarda próximo ciclo
    Start-Sleep -Seconds $config.ciclo_segundos
}
