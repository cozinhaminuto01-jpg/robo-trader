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
$config = Get-Content $ConfigPath -Encoding UTF8 | ConvertFrom-Json

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
    try {
        $ts = Get-Date -Format "HH:mm:ss"
        $agenteStr = if ($AgenteID) { $AgenteID } else { "Agent" }
        $linha = "[$ts] [$tipo] $msg"
        Write-Host "[$agenteStr] $linha" -ErrorAction SilentlyContinue
        if ($logFile -and (Test-Path (Split-Path $logFile))) {
            Add-Content -Path $logFile -Value $linha -ErrorAction SilentlyContinue
        }
    } catch {
        Write-Host "Log error: $_"
    }
}

function Save-Estado {
    try {
        $json = $estado | ConvertTo-Json
        $json | Set-Content ".\estado-$AgenteID.json" -Force -Encoding UTF8
    } catch {
        Log "AVISO: Erro ao guardar estado: $_" "AVISO"
    }
}

function Load-Estado {
    if (Test-Path ".\estado-$AgenteID.json") {
        $obj = Get-Content ".\estado-$AgenteID.json" -Encoding UTF8 | ConvertFrom-Json
        # FIX: Ensure numeric fields are actually decimals/ints, not PSObjects
        return @{
            id = if ($obj.id) { [string]$obj.id } else { $AgenteID }
            saldo = if ($obj.saldo) { [decimal]$obj.saldo } else { [decimal]$SaldoInicial }
            saldoInicial = if ($obj.saldoInicial) { [decimal]$obj.saldoInicial } else { [decimal]$SaldoInicial }
            posicoes = if ($obj.posicoes) { $obj.posicoes } else { @() }
            historico = if ($obj.historico) { $obj.historico } else { @() }
            trades = if ($obj.trades) { $obj.trades } else { @() }
            winRate = if ($obj.winRate) { [decimal]$obj.winRate } else { 0 }
            ultimaTradaEm = if ($obj.ultimaTradaEm) { $obj.ultimaTradaEm } else { $null }
        }
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

        # FIX ENCODING: Force UTF-8 output from ollama
        $output = & ollama run mistral $prompt 2>&1 | ForEach-Object { [System.Text.Encoding]::UTF8.GetString([System.Text.Encoding]::Default.GetBytes($_)) }

        if ($output) {
            $outputText = $output -join "`n"
            Log "========== RESPOSTA COMPLETA DO MISTRAL ==========" "IA"
            Log $outputText "IA"
            Log "========== FIM RESPOSTA ==========" "IA"

            $jsonMatch = $outputText -match '\{[\s\S]*?"acao"[\s\S]*?\}'
            if ($jsonMatch) {
                $jsonText = $matches[0]

                # FIX: COMPREHENSIVE JSON CLEANING (Handles ALL Unicode spaces, ANSI codes, and encoding issues)
                try {
                    # Step 1: Remove ANSI escape codes from terminal output (e.g., [2D[K, [7D[K)
                    $jsonText = [System.Text.RegularExpressions.Regex]::Replace($jsonText, '\x1b\[[0-9;]*[a-zA-Z]', '')

                    # Step 2: Remove encoding artifacts like n+úo, tend+¬ncia
                    $jsonText = $jsonText -replace '\+.', ''

                    # Step 3: Normalize ALL whitespace types to regular space
                    # .NET Regex: \r, \n, \t, and \p{Zs} for Unicode spaces
                    $jsonText = [System.Text.RegularExpressions.Regex]::Replace($jsonText, '[\r\n\t\p{Zs}]', ' ')

                    # Step 4: Remove control characters that break JSON (but keep space, tab, newline)
                    $jsonText = [System.Text.RegularExpressions.Regex]::Replace($jsonText, '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]', '')

                    # Step 5: Remove unwanted units and symbols
                    $jsonText = $jsonText -replace ' EUR', ''
                    $jsonText = $jsonText -replace '%', ''

                    # Step 6: Collapse ALL consecutive spaces to single space
                    $jsonText = $jsonText -replace ' {2,}', ' '

                    # Step 7: Remove spaces BEFORE JSON syntax
                    $jsonText = $jsonText -replace ' +:', ':'
                    $jsonText = $jsonText -replace ' +,', ','
                    $jsonText = $jsonText -replace ' +}', '}'
                    $jsonText = $jsonText -replace ' +\]', ']'
                    $jsonText = $jsonText -replace ' +\{', '{'
                    $jsonText = $jsonText -replace ' +\[', '['

                    # Step 8: Remove spaces AFTER opening brackets and BEFORE closing
                    $jsonText = $jsonText -replace '\{\s+', '{'
                    $jsonText = $jsonText -replace '\[\s+', '['
                    $jsonText = $jsonText -replace '\s+}', '}'
                    $jsonText = $jsonText -replace '\s+\]', ']'

                    # Step 9: Remove remaining control/truncation characters (like [alv, [confia)
                    # These are line truncation artifacts: [2D[K, [7D[K, etc that slip through
                    $jsonText = [System.Text.RegularExpressions.Regex]::Replace($jsonText, '\[\w+', '')

                    # Step 10: Fix quoted numbers and null values (Mistral sometimes wraps them in quotes)
                    # "5.0" -> 5.0, "20" -> 20, "null" -> null
                    $jsonText = $jsonText -replace '": "(\d+\.?\d*)"', ': $1'  # Remove quotes from numbers after colon
                    $jsonText = $jsonText -replace '": "null"', ': null'       # Fix "null" to null
                    $jsonText = $jsonText -replace '": "([a-z]+)"', ': "$1"'   # Keep quotes for strings but clean them up

                    # Step 11: Final trim
                    $jsonText = $jsonText.Trim()

                    Log "JSON extraido (limpo): $jsonText" "DEBUG"
                } catch {
                    Log "Aviso: Erro durante limpeza de JSON: $_" "AVISO"
                }
                try {
                    $obj = $jsonText | ConvertFrom-Json
                    # FIX: Aceita JSON incompleto com valores padrão
                    $deciso = @{
                        acao = if ($obj.acao) { $obj.acao } else { "hold" }
                        par = if ($obj.par) { $obj.par } else { $null }
                        montante = if ($obj.montante) { [decimal]$obj.montante } else { 5.0 }
                        stopLoss = if ($obj.stopLoss) { $obj.stopLoss } else { $null }
                        alvo = if ($obj.alvo) { [int]$obj.alvo } else { 10 }
                        estrategia = if ($obj.estrategia) { $obj.estrategia } else { "Extraida da IA" }
                        risco = if ($obj.risco) { $obj.risco } else { "baixo" }
                        confianca = if ($obj.confianca) { [decimal]$obj.confianca } else { 0.5 }
                        raciocinio = if ($obj.raciocinio) { $obj.raciocinio } else { "JSON incompleto, usando valores padrão" }
                        criarAgentes = if ($obj.criarAgentes) { [int]$obj.criarAgentes } else { 0 }
                    }

                    if ($deciso.acao) {
                        Log "IA: Acao=$($deciso.acao), Par=$($deciso.par), Confianca=$($deciso.confianca), CriarAgentes=$($deciso.criarAgentes)" "IA"
                        return $deciso
                    }
                } catch {
                    Log "Erro JSON parse: $_ (tentando fallback text extraction...)" "AVISO"
                }
            } else {
                Log "Regex nao encontrou JSON na resposta. Tentando extrair do texto..." "AVISO"

                $acao = if ($outputText -match 'acao["\s:]*([a-z]+)') { $matches[1] } else { "hold" }
                $par = if ($outputText -match 'par["\s:]*([A-Z0-9/]+)') { $matches[1] } else { $null }
                $montante = if ($outputText -match 'montante["\s:]*(\d+\.?\d*)') { [decimal]$matches[1] } else { 5.0 }
                $stopLoss = if ($outputText -match 'stopLoss["\s:]*(\d+)') { [int]$matches[1] } else { $null }
                $alvo = if ($outputText -match 'alvo["\s:]*(\d+)') { [int]$matches[1] } else { 10 }
                $risco = if ($outputText -match 'risco["\s:]*([a-z]+)') { $matches[1] } else { "baixo" }
                $confianca = if ($outputText -match 'confi[a-z]*["\s:]*(\d\.?\d*)') { [decimal]$matches[1] } else { 0.5 }

                Log "Valores extraidos do texto: Acao=$acao, Par=$par, Montante=$montante, Risco=$risco" "INFO"

                return @{
                    acao = $acao
                    par = $par
                    montante = $montante
                    stopLoss = $stopLoss
                    alvo = $alvo
                    estrategia = "Extraida do texto"
                    risco = $risco
                    confianca = $confianca
                    raciocinio = "Valores extraidos da resposta textual"
                    criarAgentes = 0
                }
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
    $conteudoScript = Get-Content ".\agente-template.ps1" -Raw -Encoding UTF8

    $conteudoScript | Set-Content $novoAgenteFile -Encoding UTF8

    $job = Start-Job -FilePath $novoAgenteFile -ArgumentList @("Agente_$numeroAgente", $capital, ".\config-testnet.json")

    Log "Agente_$numeroAgente iniciado (PID: $($job.Id))" "INFO"

    if (-not (Test-Path ".\agentes-ativos.json")) {
        $agentes = @()
    } else {
        $agentes = Get-Content ".\agentes-ativos.json" -Encoding UTF8 | ConvertFrom-Json
    }

    $agentes += @{
        id = "Agente_$numeroAgente"
        jobId = $job.Id
        capital = $capital
        criadoEm = Get-Date
        status = "ativo"
    }

    $agentes | ConvertTo-Json | Set-Content ".\agentes-ativos.json" -Encoding UTF8

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

    try {
        Log "===== Ciclo $ciclo Iniciado =====" "CICLO"

        if ($estado.saldo -lt 20) {
            Log "GAME OVER! Saldo caiu abaixo de 20 EUR!" "ERRO"
            Log "Saldo final: $($estado.saldo) EUR (inicial: $($estado.saldoInicial) EUR)" "RESULTADO"
            Log "Trades executados: $($estado.trades.Count) | Win Rate: $($estado.winRate)%" "RESULTADO"
            Save-Estado
            exit 1
        }
    } catch {
        Log "Erro no inicio do ciclo: $_" "ERRO"
        throw
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
    try {
        Executa-Ciclo -ciclo $ciclo
        $ciclo++
        Start-Sleep -Seconds $config.ciclo_segundos
    } catch {
        Log "ERRO NAO APANHADO: $_" "ERRO"
        Log "Stack: $($_.ScriptStackTrace)" "ERRO"
        Log "Continuando apos erro..." "AVISO"
        $ciclo++
        Start-Sleep -Seconds 5
    }
}
