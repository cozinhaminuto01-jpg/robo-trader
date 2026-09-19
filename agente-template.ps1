# ============================================================================
# AGENTE GENERICO - Trader Autonomo com IA Local (Ollama/Mistral)
# ============================================================================
# Cada instancia roda em paralelo, toma decisoes proprias
# Usa Mistral (Ollama local) para pensar onde investir, como, quando
# Sem estrategia pre-configurada: IA descobre autonomamente

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
# FUNCOES AUXILIARES
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
    if ($config.ambiente -eq "testnet") {
        return @{
            USDT = $estado.saldo
            BTC = 0
            ETH = 0
            SOL = 0
        }
    }
}

function Get-MercadoData {
    if ($config.ambiente -eq "testnet") {
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
# CHAMADA A IA (Ollama/Mistral - IA Local)
# ============================================================================

function Chama-IA {
    param([hashtable]$contexto)

    $prompt = @"
Tu es um trader autonomo. Saldo: $($contexto.saldo) EUR
Trades executados: $($contexto.nTrades), Taxa vitoria: $($contexto.winRate)%

Pares em movimento:
$($contexto.mercado | ForEach-Object { "- $($_.par): USD `$$($_.preco) (24h: $($_.mudanca24h)%)" } | Out-String)

Restricoes:
- Risco maximo: 2% ($($contexto.saldo * 0.02) EUR por trade)
- Max 3 posicoes abertas
- Se saldo < 15 EUR: apenas hold
- Se saldo >= 100 EUR: repouso

RESPONDE APENAS COM JSON (nenhuma outra explicacao):
{
  "acao": "compra|venda|hold",
  "par": "BTC/USDT|null",
  "montante": 2.5,
  "stopLoss": 1.5,
  "alvo": 3.5,
  "estrategia": "descricao breve",
  "risco": "baixo|medio|alto",
  "confianca": 0.75
}
"@

    try {
        Log "========== PROMPT ENVIADO AO MISTRAL ==========" "IA"
        Log $prompt "IA"
        Log "========== FIM PROMPT ==========" "IA"

        Log "Consultando Ollama/Mistral (IA local)..." "IA"

        $output = & ollama run mistral $prompt 2>&1

        if ($output) {
            $outputText = $output -join "`n"
            Log "========== RESPOSTA COMPLETA DO MISTRAL ==========" "IA"
            Log $outputText "IA"
            Log "========== FIM RESPOSTA ==========" "IA"

            $jsonMatch = $outputText -match '\{[\s\S]*?"acao"[\s\S]*?\}'
            if ($jsonMatch) {
                $jsonText = $matches[0]
                $jsonText = $jsonText -replace "`r`n", " "
                $jsonText = $jsonText -replace "`n", " "
                $jsonText = $jsonText -replace '\s+', ' '
                Log "JSON extraido: $jsonText" "DEBUG"
                try {
                    $obj = $jsonText | ConvertFrom-Json
                    $deciso = @{
                        acao = $obj.acao
                        par = $obj.par
                        montante = $obj.montante
                        stopLoss = $obj.stopLoss
                        alvo = $obj.alvo
                        estrategia = $obj.estrategia
                        risco = $obj.risco
                        confianca = $obj.confianca
                    }

                    if ($deciso.acao -and $deciso.risco) {
                        Log "IA: Acao=$($deciso.acao), Par=$($deciso.par), Confianca=$($deciso.confianca)" "IA"
                        return $deciso
                    }
                } catch {
                    Log "Erro JSON parse: $_" "AVISO"
                }
            } else {
                Log "Regex nao encontrou JSON na resposta" "AVISO"
            }
        }

        Log "Nao conseguiu extrair JSON valido. Modo hold defensivo." "AVISO"
        return @{
            acao = "hold"
            par = $null
            risco = "baixo"
            confianca = 0.3
            estrategia = "Aguardando proxima oportunidade"
        }

    } catch {
        Log "Erro ao chamar Ollama: $_" "ERRO"
        return @{
            acao = "hold"
            par = $null
            risco = "baixo"
            confianca = 0
            estrategia = "Erro de comunicacao"
        }
    }
}

# ============================================================================
# SIMULADOR DE TRADES (Testnet)
# ============================================================================

function Simula-Trade {
    param([hashtable]$deciso)

    if ($deciso.acao -eq "hold" -or $deciso.acao -eq "analisa") {
        Log "IA decidiu: $($deciso.acao) - Aguardando proxima oportunidade" "INFO"
        return $null
    }

    $resultado = Get-Random -Minimum -5 -Maximum 15
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

    Log "===== Ciclo $ciclo Iniciado =====" "CICLO"

    if ($estado.saldo -lt 15) {
        Log "Modo Seguro: saldo $($estado.saldo) EUR menor que 15 EUR" "AVISO"
        Log "Aguardando recuperacao..." "AVISO"
        return
    }

    $dadosMercado = Get-MercadoData
    Log "Analisando $($dadosMercado.Count) pares em movimento..." "INFO"

    $contexto = @{
        saldo = $estado.saldo
        nTrades = $estado.trades.Count
        winRate = $estado.winRate
        mercado = $dadosMercado
    }
    $deciso = Chama-IA -contexto $contexto

    Log "Decisao: $($deciso | ConvertTo-Json -Compress)" "IA"

    $trade = Simula-Trade -deciso $deciso
    if ($trade) {
        $estado.trades += $trade
        $estado.saldo += $trade.ganho
        $estado.ultimaTradaEm = Get-Date

        $vitorias = @($estado.trades | Where-Object { $_.ganho -gt 0 }).Count
        $estado.winRate = [Math]::Round(($vitorias / $estado.trades.Count) * 100, 1)

        Log "Novo saldo: $($estado.saldo) EUR | Win Rate: $($estado.winRate)%" "RESULTADO"
    }

    if ($estado.saldo -ge 100) {
        Log "OBJETIVO ATINGIDO! Saldo: $($estado.saldo) EUR" "SUCESSO"
        $estado.objetivo = "atingido"
    }

    Save-Estado
    Log "===== Ciclo $ciclo Terminado =====`n" "CICLO"
}

# ============================================================================
# PONTO DE ENTRADA
# ============================================================================

Log "Agente iniciado com $SaldoInicial EUR (IA: Ollama/Mistral)" "INIT"

$estadoAnterior = Load-Estado
if ($estadoAnterior) {
    $estado = $estadoAnterior
    Log "Estado anterior carregado" "INFO"
}

$ciclo = 1
while ($true) {
    Executa-Ciclo -ciclo $ciclo
    $ciclo++

    Start-Sleep -Seconds $config.ciclo_segundos
}
