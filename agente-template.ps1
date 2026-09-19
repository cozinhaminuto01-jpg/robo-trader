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
=== PROPRIETARIO DA EMPRESA - AUTONOMIA TOTAL ===
Tu es o DONO desta empresa de trading. Saldo actual: $($contexto.saldo) EUR

OBJECTIVOS CLAROS:
- Se saldo cair abaixo de 20 EUR: MORRES (game over)
- Se saldo atingir 100 EUR: descansas 24h depois reinicia
- PODES CRIAR NOVOS AGENTES QUANDO QUISERES para acelerar o crescimento
- Cada novo agente: 20 EUR capital inicial

ESTADO ACTUAL DA EMPRESA:
- Saldo do CEO (tu): $($contexto.saldo) EUR
- Agentes trabalhando: $($contexto.numAgentes)
- Trades executados: $($contexto.nTrades)
- Taxa de vitória: $($contexto.winRate)%
- Capital disponivel para novos agentes: $([Math]::Floor($contexto.saldo / 20)) agentes

MERCADO ACTUAL (pares em movimento):
$($contexto.mercado | ForEach-Object { "- $($_.par): `$$($_.preco) (mudanca 24h: $($_.mudanca24h)%) volume: $($_.volume)" } | Out-String)

=== PODER TOTAL - NENHUMA RESTRICAO ===
TU DECIDES TUDO:
- Quanto arriscar por trade
- Que estrategia usar
- Quando criar novos agentes (nao precisa pedir permissao a ninguem)
- Como alocar capital entre agentes
- Quanto expandir a operacao

=== PENSA COMO CEO ===
1. ANALISA: Qual eh a melhor estrategia para crescer rapido sem morrer?
   - Continuo sozinho ou crio novos agentes?
   - Se mercado esta bom, posso dar risco maior
   - Se crescer rapido, posso delegar

2. CONVERSA COMIGO: Explica teu raciocinio
   - Por que esta estrategia eh boa?
   - Vale a pena criar novos agentes?
   - Como me protejo?

3. DECIDE: Que fazes agora?
   - Compra? Venda? Hold?
   - Cria novo agente? Quantos?

=== RESPOSTA OBRIGATORIA (CONVERSACAO + JSON PERFEITO) ===

PARTE 1: CONVERSACAO (opcional mas recomendada)
Pensa em voz alta, explica teu raciocinio, fala dos riscos.

PARTE 2: JSON VALIDO (OBRIGATORIO - DEVE SER PERFEITO)
Responde EXATAMENTE neste formato JSON, sem aspas extras, sem unidades:

{
  "acao": "compra",
  "par": "BTC/USDT",
  "montante": 5.0,
  "stopLoss": 10,
  "alvo": 20,
  "estrategia": "Compra com stop loss",
  "risco": "medio",
  "confianca": 0.7,
  "raciocinio": "O mercado esta em tendencia positiva",
  "criarAgentes": 0
}

CRITICO:
- montante: APENAS NUMERO (ex: 5.0, nao "5.0 EUR")
- stopLoss: APENAS NUMERO ou null (ex: 10, nao "10%")
- alvo: APENAS NUMERO (ex: 20)
- confianca: NUMERO entre 0 e 1 (ex: 0.7)
- criarAgentes: NUMERO inteiro (ex: 0, 1, 2)
- acao, risco: MINUSCULO (compra, venda, hold, baixo, medio, alto, critico)
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
                $jsonText = $jsonText -replace ' EUR', ''
                $jsonText = $jsonText -replace '%', ''
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
                        raciocinio = $obj.raciocinio
                        criarAgentes = if ($obj.criarAgentes) { $obj.criarAgentes } else { 0 }
                    }

                    if ($deciso.acao -and $deciso.risco) {
                        Log "IA: Acao=$($deciso.acao), Par=$($deciso.par), Confianca=$($deciso.confianca), CriarAgentes=$($deciso.criarAgentes)" "IA"
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
            criarAgentes = 0
        }

    } catch {
        Log "Erro ao chamar Ollama: $_" "ERRO"
        return @{
            acao = "hold"
            par = $null
            risco = "baixo"
            confianca = 0
            estrategia = "Erro de comunicacao"
            criarAgentes = 0
        }
    }
}

# ============================================================================
# CRIAR NOVOS AGENTES (CEO DECIDE EXPANDIR)
# ============================================================================

function Cria-NovoAgente {
    param([int]$numeroAgente, [decimal]$capital)

    Log "CEO DECISION: Criando novo Agente_$numeroAgente com capital de $capital EUR" "DECISAO"

    $novoAgenteFile = ".\agente-$numeroAgente.ps1"
    $conteudoScript = Get-Content ".\agente-template.ps1" -Raw

    $conteudoScript | Set-Content $novoAgenteFile

    $job = Start-Job -FilePath $novoAgenteFile -ArgumentList @("Agente_$numeroAgente", $capital, ".\config-testnet.json")

    Log "Agente_$numeroAgente iniciado (PID: $($job.Id))" "INFO"

    if (-not (Test-Path ".\agentes-ativos.json")) {
        $agentes = @()
    } else {
        $agentes = Get-Content ".\agentes-ativos.json" | ConvertFrom-Json
    }

    $agentes += @{
        id = "Agente_$numeroAgente"
        jobId = $job.Id
        capital = $capital
        criadoEm = Get-Date
        status = "ativo"
    }

    $agentes | ConvertTo-Json | Set-Content ".\agentes-ativos.json"

    return @{ id = "Agente_$numeroAgente"; jobId = $job.Id }
}

# ============================================================================
# SIMULADOR DE TRADES (Testnet)
# ============================================================================

function Simula-Trade {
    param([hashtable]$deciso)

    if ($deciso.acao -eq "hold") {
        Log "IA decidiu: HOLD - Aguardando proxima oportunidade" "INFO"
        if ($deciso.raciocinio) {
            Log "Razao: $($deciso.raciocinio)" "IA"
        }
        return $null
    }

    $montante = $deciso.montante
    $alvo = [int]$deciso.alvo
    $stopLoss = if ($deciso.stopLoss) { [int]$deciso.stopLoss } else { -100 }

    $resultado = Get-Random -Minimum $stopLoss -Maximum $alvo

    $ganho = $montante * ($resultado / 100)

    $statusRisco = if ($resultado -le $stopLoss) { "PARADO NO STOP" } `
                   elseif ($resultado -lt -5) { "PREJUIZO GRANDE" } `
                   elseif ($resultado -lt 0) { "PREJUIZO" } `
                   elseif ($resultado -eq 0) { "NEUTRO" } `
                   elseif ($resultado -ge $alvo) { "ALVO ATINGIDO!" } `
                   elseif ($resultado -gt 0) { "GANHO" } `
                   else { "RISCO ALTO" }

    Log "TRADE: $($deciso.acao) $montante EUR em $($deciso.par) | Resultado: $resultado% | Ganho: $ganho EUR | $statusRisco" "TRADE"

    if ($deciso.raciocinio) {
        Log "Raciocinio IA: $($deciso.raciocinio)" "IA"
    }

    return @{
        par = $deciso.par
        montante = $montante
        resultado = $resultado
        ganho = $ganho
        estrategia = $deciso.estrategia
        raciocinio = $deciso.raciocinio
        timestamp = Get-Date
    }
}

# ============================================================================
# CICLO PRINCIPAL
# ============================================================================

function Executa-Ciclo {
    param([int]$ciclo)

    Log "===== Ciclo $ciclo Iniciado =====" "CICLO"

    if ($estado.saldo -lt 20) {
        Log "GAME OVER! Saldo caiu abaixo de 20 EUR!" "ERRO"
        Log "Saldo final: $($estado.saldo) EUR (inicial: $($estado.saldoInicial) EUR)" "RESULTADO"
        Log "Trades executados: $($estado.trades.Count) | Win Rate: $($estado.winRate)%" "RESULTADO"
        Save-Estado
        exit 1
    }

    if ($estado.saldo -ge 100) {
        Log "OBJETIVO ATINGIDO! Saldo: $($estado.saldo) EUR" "SUCESSO"
        Log "Agente entra em repouso por 24 horas..." "INFO"
        Log "Volta a rodar amanha! Descansando..." "INFO"
        Save-Estado
        Start-Sleep -Seconds 86400
        Log "Repouso de 24h concluido. Reiniciando ciclos..." "INFO"
        return
    }

    $dadosMercado = Get-MercadoData

    $numAgentes = 0
    if (Test-Path ".\agentes-ativos.json") {
        $agentes = Get-Content ".\agentes-ativos.json" | ConvertFrom-Json
        $numAgentes = if ($agentes -is [array]) { $agentes.Count } else { 1 }
    }

    Log "Analisando $($dadosMercado.Count) pares em movimento ($numAgentes agentes ativos)..." "INFO"

    $contexto = @{
        saldo = $estado.saldo
        nTrades = $estado.trades.Count
        winRate = $estado.winRate
        mercado = $dadosMercado
        numAgentes = $numAgentes
    }
    $deciso = Chama-IA -contexto $contexto

    Log "Decisao: $($deciso | ConvertTo-Json -Compress)" "IA"

    $novasAgentes = if ($deciso.criarAgentes) { $deciso.criarAgentes } else { 0 }
    if ($novasAgentes -gt 0) {
        Log "CEO CRIANDO $novasAgentes NOVOS AGENTES!" "DECISAO"
        for ($i = 1; $i -le $novasAgentes; $i++) {
            $proximoID = $numAgentes + $i
            if ($estado.saldo -ge 20) {
                Cria-NovoAgente -numeroAgente $proximoID -capital 20
                $estado.saldo -= 20
                Log "Novo agente criado. Saldo restante: $($estado.saldo) EUR" "INFO"
            }
        }
    }

    $trade = Simula-Trade -deciso $deciso
    if ($trade) {
        $estado.trades += $trade
        $estado.saldo += $trade.ganho
        $estado.ultimaTradaEm = Get-Date

        $vitorias = @($estado.trades | Where-Object { $_.ganho -gt 0 }).Count
        $estado.winRate = [Math]::Round(($vitorias / $estado.trades.Count) * 100, 1)

        Log "Novo saldo: $($estado.saldo) EUR | Win Rate: $($estado.winRate)%" "RESULTADO"

        if ($vitorias -ge 5 -and $vitorias % 5 -eq 0) {
            Log "===== CONSOLIDACAO DE GANHOS =====" "SUCESSO"
            Log "5 trades ganhadoras atingidas! Saldo protegido: $($estado.saldo) EUR" "SUCESSO"
            Log "IA vai entrar em modo +conservador para proteger ganhos" "AVISO"
        }
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
