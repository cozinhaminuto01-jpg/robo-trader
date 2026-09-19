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
    ciclosHistorico = @()
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
        $json = $estado | ConvertTo-Json -Depth 6
        $json | Set-Content ".\estado-$AgenteID.json" -Force -Encoding UTF8
    } catch {
        Log "AVISO: Erro ao guardar estado: $_" "AVISO"
    }
}

function Send-Telegram {
    param([string]$mensagem)

    try {
        if (-not $config.telegram_token -or $config.telegram_token -eq "COLOCA_AQUI_TOKEN_TELEGRAM") { return }
        if (-not $config.telegram_chat_id -or $config.telegram_chat_id -eq "COLOCA_AQUI_CHAT_ID") { return }

        $uri = "https://api.telegram.org/bot$($config.telegram_token)/sendMessage"
        $body = @{
            chat_id = $config.telegram_chat_id
            text = $mensagem
        } | ConvertTo-Json

        Invoke-RestMethod -Uri $uri -Method Post -ContentType "application/json; charset=utf-8" -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) | Out-Null
    } catch {
        Log "AVISO: Erro ao enviar mensagem Telegram: $_" "AVISO"
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
            posicoes = if ($obj.posicoes) { @($obj.posicoes) } else { @() }
            historico = if ($obj.historico) { @($obj.historico) } else { @() }
            trades = if ($obj.trades) { @($obj.trades) } else { @() }
            ciclosHistorico = if ($obj.ciclosHistorico) { @($obj.ciclosHistorico) } else { @() }
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

    $memoria = if ($contexto.historico -and $contexto.historico.Count -gt 0) {
        ($contexto.historico | Select-Object -Last 5 | ForEach-Object { "- $_" }) -join "`n"
    } else {
        "(ainda nao pensaste nisto antes, e a primeira vez que conversas sobre isto)"
    }

    $agentesInfo = if ($contexto.numAgentes -gt 1) { "Tens tambem $($contexto.numAgentes - 1) outra(s) conta(s)/agente(s) que ja criaste antes." } else { "" }

    $prompt = @"
Tens uma conta na Binance. Saldo actual: $($contexto.saldo) USD.
O teu objetivo: fazer este saldo crescer ate aos 100 USD. Quando lá chegares, ganhas um descanso.
$agentesInfo

O que ja pensaste sobre isto em conversas anteriores:
$memoria

Informacao disponivel na tua conta Binance neste momento:
$($contexto.mercado | ForEach-Object { "- $($_.par): `$$($_.preco) (mudanca 24h: $($_.mudanca24h)%) volume: $($_.volume)" } | Out-String)

Ninguem te vai dizer o que fazer nem como fazer. Pensa livremente sobre a tua situacao e decide tu mesmo o que fazer a seguir.

No fim da tua resposta, regista a tua decisao neste formato (usa null nos campos que nao se aplicarem, e 0 se nao quiseres criar nada):

{"acao": "...", "par": "...", "montante": ..., "stopLoss": ..., "alvo": ..., "criarAgentes": 0}
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
            # Remove codigos ANSI de escape do terminal (ex: [2D[K) antes de qualquer uso,
            # para nao poluir nem o parsing nem a memoria guardada entre ciclos
            $outputText = [System.Text.RegularExpressions.Regex]::Replace($outputText, '\x1b(\[[0-9;?]*[a-zA-Z]|\][^\x07]*\x07)', '')
            # Remove caracteres de substituicao Unicode (lixo do spinner "a pensar..." do Ollama,
            # corrompido pela dupla conversao de encoding) para nao poluir o parsing nem a memoria
            $outputText = $outputText -replace '�', ''
            Log "========== RESPOSTA COMPLETA DO MISTRAL ==========" "IA"
            Log $outputText "IA"
            Log "========== FIM RESPOSTA ==========" "IA"

            $jsonMatch = $outputText -match '\{[\s\S]*?"?acao"?\s*:[\s\S]*?\}'
            if ($jsonMatch) {
                $jsonText = $matches[0]
                Log "JSON bruto extraido: $jsonText" "DEBUG"

                # FIX: DIRECT FIELD EXTRACTION VIA REGEX (bypasses ConvertFrom-Json entirely)
                # Ollama's terminal output can corrupt individual bytes (encoding double-conversion,
                # ANSI codes, line-wrap truncation) which breaks strict JSON parsing no matter how
                # much we try to "repair" it. Extracting each field independently with a tolerant
                # regex is immune to broken quotes/braces elsewhere in the blob. The leading quote
                # is optional (the AI is never taught the exact JSON syntax) and a colon is required
                # right after the field name so we never match a field name as a substring of a
                # normal word (e.g. "par" inside "para").
                try {
                    $acao = if ($jsonText -match '"?acao"?\s*:\s*"?([a-zA-Z]+)') { $matches[1].ToLower() } else { "hold" }
                    $par = if ($jsonText -match '"?par"?\s*:\s*"?([A-Za-z0-9]+(?:\s*/\s*[A-Za-z0-9]+)?)') { ($matches[1] -replace '\s', '').ToUpper() } else { $null }
                    $montante = if ($jsonText -match '"?montante"?\s*:\s*"?(\d+\.?\d*)') { [decimal]$matches[1] } else { 5.0 }
                    $stopLoss = if ($jsonText -match '"?stopLoss"?\s*:\s*"?(\d+\.?\d*)') { [decimal]$matches[1] } else { $null }
                    $alvo = if ($jsonText -match '"?alvo"?\s*:\s*"?(\d+\.?\d*)') { [decimal]$matches[1] } else { 10 }
                    $estrategia = if ($jsonText -match '"?estrategia"?\s*:\s*"([^"]*)"') { $matches[1] } else { "Extraida da IA" }
                    $risco = if ($jsonText -match '"?risco"?\s*:\s*"?([a-zA-Z]+)') { $matches[1].ToLower() } else { "baixo" }
                    $confianca = if ($jsonText -match '"?confianca"?\s*:\s*"?(\d+\.?\d*)') { [decimal]$matches[1] } else { 0.5 }
                    $criarAgentes = if ($jsonText -match '"?criarAgentes"?\s*:\s*"?(\d+)') { [int]$matches[1] } else { 0 }

                    # Guarda o texto de raciocinio livre para servir de memoria nos proximos ciclos.
                    # Ela nem sempre coloca a explicacao antes do JSON - as vezes decide primeiro e
                    # explica depois - por isso apanha-se tudo o resto do texto, nao so o que vem antes.
                    $raciocinio = $outputText.Replace($jsonText, "").Trim()
                    if ([string]::IsNullOrWhiteSpace($raciocinio)) { $raciocinio = "(sem texto de raciocinio nesta resposta)" }

                    $deciso = @{
                        acao = $acao
                        par = $par
                        montante = $montante
                        stopLoss = $stopLoss
                        alvo = $alvo
                        estrategia = $estrategia
                        risco = $risco
                        confianca = $confianca
                        raciocinio = $raciocinio
                        criarAgentes = $criarAgentes
                    }

                    Log "IA: Acao=$($deciso.acao), Par=$($deciso.par), Confianca=$($deciso.confianca), CriarAgentes=$($deciso.criarAgentes)" "IA"
                    return $deciso
                } catch {
                    Log "Erro na extracao direta de campos: $_ (tentando fallback text extraction...)" "AVISO"
                }
            } else {
                Log "Regex nao encontrou JSON na resposta. Tentando extrair do texto..." "AVISO"

                $acao = if ($outputText -match '"?acao"?\s*:\s*"?([a-z]+)') { $matches[1] } else { "hold" }
                $par = if ($outputText -match '"?par"?\s*:\s*"?([A-Za-z0-9]+(?:\s*/\s*[A-Za-z0-9]+)?)') { ($matches[1] -replace '\s', '').ToUpper() } else { $null }
                $montante = if ($outputText -match '"?montante"?\s*:\s*"?(\d+\.?\d*)') { [decimal]$matches[1] } else { 5.0 }
                $stopLoss = if ($outputText -match '"?stopLoss"?\s*:\s*"?(\d+\.?\d*)') { [decimal]$matches[1] } else { $null }
                $alvo = if ($outputText -match '"?alvo"?\s*:\s*"?(\d+\.?\d*)') { [decimal]$matches[1] } else { 10 }
                $risco = if ($outputText -match '"?risco"?\s*:\s*"?([a-z]+)') { $matches[1] } else { "baixo" }
                $confianca = if ($outputText -match '"?confi[a-z]*"?\s*:\s*"?(\d\.?\d*)') { [decimal]$matches[1] } else { 0.5 }

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
                    raciocinio = $outputText.Trim()
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
        criadoEm = Get-Date -Format "yyyy-MM-ddTHH:mm:ss"
        status = "ativo"
    }

    $agentes | ConvertTo-Json | Set-Content ".\agentes-ativos.json" -Encoding UTF8

    return @{ id = "Agente_$numeroAgente"; jobId = $job.Id }
}

# ============================================================================
# SIMULADOR DE TRADES (Testnet)
# ============================================================================

function Simula-Trade {
    param([hashtable]$deciso, [decimal]$saldoAtual)

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

    # Uma exchange real nunca executa uma ordem maior que o saldo disponivel na conta -
    # isto nao e uma regra de estrategia, e um limite fisico de qualquer conta real
    if ($montante -gt $saldoAtual) {
        Log "AVISO: Pediu para investir $montante EUR mas so ha $saldoAtual EUR na conta. Uma exchange real limitaria a ordem ao saldo disponivel." "AVISO"
        $montante = $saldoAtual
    }

    # O resultado de um trade nunca pode variar mais que -100% (perda total) ou +100%;
    # isto evita percentagens irrealistas quando stopLoss/alvo sao escritos como precos
    # absolutos em vez de percentagens - nao dita como definir stop loss, so mantem o
    # resultado da simulacao dentro do fisicamente possivel
    $stopLoss = [Math]::Min([Math]::Max($stopLoss, -100), 100)
    $alvo = [Math]::Min([Math]::Max($alvo, -100), 100)

    # Get-Random exige Minimum < Maximum ou o script crasha; isto e apenas para o
    # simulador nao rebentar com valores inesperados, nao impoe nenhuma regra de trading
    if ($stopLoss -ge $alvo) {
        if ($stopLoss -ge 100) {
            $stopLoss = 99
        }
        $alvo = $stopLoss + 1
    }

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
        acao = $deciso.acao
        par = $deciso.par
        montante = $montante
        resultado = $resultado
        ganho = $ganho
        estrategia = $deciso.estrategia
        raciocinio = $deciso.raciocinio
        timestamp = Get-Date -Format "yyyy-MM-ddTHH:mm:ss"
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
        historico = $estado.historico
    }
    $deciso = Chama-IA -contexto $contexto

    # Guarda o raciocinio deste ciclo como memoria para os proximos (ela "conversa consigo mesma" ao longo do tempo)
    if ($deciso.raciocinio) {
        $estado.historico += $deciso.raciocinio
        if ($estado.historico.Count -gt 20) {
            $estado.historico = $estado.historico | Select-Object -Last 20
        }
    }

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

    $trade = Simula-Trade -deciso $deciso -saldoAtual $estado.saldo
    if ($trade) {
        $estado.trades += $trade
        $estado.saldo += $trade.ganho
        $estado.ultimaTradaEm = Get-Date -Format "yyyy-MM-ddTHH:mm:ss"

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

    # Regista este ciclo completo (pensamento + decisao + resultado) para o dashboard e Telegram
    # poderem mostrar o historico de pensamentos dela, ciclo a ciclo - nao so o ultimo trade
    $entradaCiclo = @{
        ciclo = $ciclo
        timestamp = Get-Date -Format "yyyy-MM-ddTHH:mm:ss"
        raciocinio = $deciso.raciocinio
        acao = $deciso.acao
        par = $deciso.par
        montante = $deciso.montante
        resultado = if ($trade) { $trade.resultado } else { $null }
        ganho = if ($trade) { $trade.ganho } else { 0 }
        saldoApos = $estado.saldo
    }
    $estado.ciclosHistorico += $entradaCiclo
    if ($estado.ciclosHistorico.Count -gt 100) {
        $estado.ciclosHistorico = $estado.ciclosHistorico | Select-Object -Last 100
    }

    $resumoTelegram = "Ciclo #$ciclo - Saldo: $($estado.saldo) EUR`n`n" + `
        "Pensamento:`n$($deciso.raciocinio)`n`n" + `
        "Decisao: $($deciso.acao) $($deciso.montante) em $($deciso.par)" + `
        $(if ($trade) { "`nResultado: $($trade.resultado)% | Ganho: $($trade.ganho) EUR" } else { "" })
    if ($resumoTelegram.Length -gt 3500) {
        $resumoTelegram = $resumoTelegram.Substring(0, 3500) + "..."
    }
    Send-Telegram -mensagem $resumoTelegram

    Save-Estado
    Log "===== Ciclo $ciclo Terminado =====`n" "CICLO"
}

# ============================================================================
# PONTO DE ENTRADA
# ============================================================================

Log "Agente iniciado com $SaldoInicial EUR (IA: Ollama/Mistral)" "INIT"

# Forca o Ollama a descarregar qualquer sessao/contexto anterior do modelo, para
# garantir que a IA comeca mesmo do zero, sem vestigios de conversas passadas
# que nao sejam a memoria que nos proprios controlamos (estado.historico)
try {
    Log "A limpar sessao anterior do Ollama (mistral)..." "INIT"
    & ollama stop mistral 2>&1 | Out-Null
} catch {
    Log "Aviso: nao foi possivel limpar sessao do Ollama (pode nao estar a correr ainda): $_" "AVISO"
}

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
