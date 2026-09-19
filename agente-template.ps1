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

# FIX ENCODING: O Windows PowerShell 5.1 escreve na consola e em ficheiros usando o
# codepage local (ANSI) por omissao, nao UTF-8. Como o texto (respostas do Mistral,
# acentos em portugues) e sempre UTF-8, isto corrompe visualmente tudo o que e escrito
# (ex: "decisao" aparece como "decis+o") mesmo que o texto em memoria esteja correto -
# nenhuma limpeza de conteudo resolve isto, e um problema de escrita, nao do texto.
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
} catch {
    # Em hosts sem consola interativa (ex: corrido como job) isto pode falhar - inofensivo
}

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
            Add-Content -Path $logFile -Value $linha -Encoding UTF8 -ErrorAction SilentlyContinue
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

$MERCADO_ESTADO_PATH = ".\mercado-estado.json"
$MERCADO_PRECOS_BASE = @{
    "BTC/USDT" = 43250.0
    "ETH/USDT" = 2280.0
    "SOL/USDT" = 185.0
    "XRP/USDT" = 2.45
    "ADA/USDT" = 1.15
}

function Load-MercadoEstado {
    if (Test-Path $MERCADO_ESTADO_PATH) {
        try {
            $obj = Get-Content $MERCADO_ESTADO_PATH -Encoding UTF8 | ConvertFrom-Json
            $precos = @{}
            foreach ($p in $obj.PSObject.Properties) {
                $precos[$p.Name] = [decimal]$p.Value
            }
            if ($precos.Count -gt 0) { return $precos }
        } catch {
            Log "AVISO: Erro ao carregar estado do mercado, a usar precos base: $_" "AVISO"
        }
    }
    return $MERCADO_PRECOS_BASE.Clone()
}

function Save-MercadoEstado {
    param([hashtable]$precos)
    try {
        $precos | ConvertTo-Json | Set-Content $MERCADO_ESTADO_PATH -Force -Encoding UTF8
    } catch {
        Log "AVISO: Erro ao guardar estado do mercado: $_" "AVISO"
    }
}

# Evolui os precos do mercado uma vez por ciclo (passeio aleatorio) e persiste-os num
# ficheiro partilhado, para que todos os agentes (incluindo os criados por ela) vejam
# o MESMO mercado a mudar ao longo do tempo, em vez de cada um simular a sua propria
# realidade de precos desligada das outras.
function Avanca-Mercado {
    $precos = Load-MercadoEstado
    $variacoes = @{}
    foreach ($par in @($precos.Keys)) {
        $variacaoPct = (Get-Random -Minimum -300 -Maximum 301) / 100.0
        $precos[$par] = [Math]::Max([decimal]($precos[$par] * (1 + ($variacaoPct / 100))), 0.0001)
        $variacoes[$par] = $variacaoPct
    }
    Save-MercadoEstado -precos $precos
    return @{ precos = $precos; variacoes = $variacoes }
}

function Get-MercadoData {
    param([hashtable]$precos, [hashtable]$variacoes)

    $pares = @()
    foreach ($par in $precos.Keys) {
        $pares += @{
            par = $par
            preco = [Math]::Round($precos[$par], 4)
            mudanca24h = $variacoes[$par]
            volume = Get-Random -Minimum 100000000 -Maximum 2000000000
        }
    }
    return $pares | Get-Random -Count (Get-Random -Minimum 2 -Maximum ($pares.Count + 1))
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

    $posicoesTexto = if ($contexto.posicoes -and $contexto.posicoes.Count -gt 0) {
        ($contexto.posicoes | ForEach-Object {
            $pct = if ($_.precoEntrada -gt 0) { [Math]::Round((($_.precoAtual - $_.precoEntrada) / $_.precoEntrada) * 100, 2) } else { 0 }
            "- $($_.par): investiste $([Math]::Round($_.montanteInvestido,2)) USD a `$$($_.precoEntrada), preco atual `$$($_.precoAtual) ($pct%), valor atual $([Math]::Round($_.valorAtual,2)) USD"
        }) -join "`n"
    } else {
        "(nenhuma posicao aberta neste momento - todo o dinheiro esta em cash)"
    }

    $prompt = @"
Tens uma conta na Binance. Dinheiro disponivel (cash): $($contexto.saldo) USD.
O teu objetivo: fazer o teu patrimonio total crescer ate aos 100 USD. Quando lá chegares, ganhas um descanso.
Se o teu patrimonio total chegar a 0, e o fim - perdes tudo e nao ha volta atras.
$agentesInfo

As tuas posicoes abertas neste momento:
$posicoesTexto

O que ja pensaste sobre isto em conversas anteriores:
$memoria

Informacao disponivel na tua conta Binance neste momento:
$($contexto.mercado | ForEach-Object { "- $($_.par): `$$($_.preco) (mudanca 24h: $($_.mudanca24h)%) volume: $($_.volume)" } | Out-String)

Ninguem te vai dizer o que fazer nem como fazer. Pensa livremente sobre a tua situacao e decide tu mesmo o que fazer a seguir - podes abrir uma posicao nova, reforcar ou vender uma que ja tens, ou nao fazer nada agora.

No fim da tua resposta, regista a tua decisao neste formato (usa null nos campos que nao se aplicarem, e 0 se nao quiseres criar nada):

{"acao": "...", "par": "...", "montante": ..., "stopLoss": ..., "alvo": ..., "criarAgentes": 0}
"@

    try {
        Log "========== PROMPT ENVIADO AO MISTRAL ==========" "IA"
        Log $prompt "IA"
        Log "========== FIM PROMPT ==========" "IA"

        Log "Consultando Ollama/Mistral (IA local)..." "IA"

        # Nota: ja NAO se faz aqui a dupla conversao GetString(Default.GetBytes(...)) que
        # existia antes. Essa conversao so era necessaria porque a consola nao estava a
        # decodificar o UTF-8 do Ollama corretamente por omissao. Agora que forcamos
        # [Console]::OutputEncoding para UTF-8 no arranque do script, a captura do
        # output do Ollama ja vem correta - manter aquela dupla conversao aqui em cima
        # disto corromperia texto que ja esta certo (foi o que causou a corrupcao "?"
        # e "�" vista depois de aplicar o fix da consola)
        #
        # FIX CRITICO: o prompt e passado via STDIN (pipe), nao como argumento de linha
        # de comando. Quando o prompt continha algo como "mudanca 24h: -1.2%)", o ollama
        # (biblioteca de CLI em Go) interpretava "-1" como uma FLAG desconhecida e falhava
        # de imediato ("Error: unknown shorthand flag") sem sequer consultar o modelo -
        # e essa mensagem de erro ainda era guardada como se fosse raciocinio dela.
        # Passar por stdin evita todo o parsing de argumentos da linha de comando.
        $output = $prompt | & ollama run mistral 2>&1

        if ($output) {
            $outputText = $output -join "`n"

            # Se o proprio comando ollama falhou (erro de CLI, processo nao encontrado, etc.),
            # isto NAO e uma resposta dela - nunca deve ser guardado como raciocinio/memoria.
            # Sem isto, uma mensagem de erro do sistema era gravada como se fosse algo que
            # ela pensou, e depois devolvida a ela propria no proximo ciclo como "memoria".
            if ($outputText -match '^Error:|RemoteException|is not recognized as|ollama: command not found') {
                Log "Ollama falhou a responder (erro de CLI, nao do modelo): $outputText" "ERRO"
                return @{
                    acao = "hold"
                    par = $null
                    risco = "baixo"
                    confianca = 0
                    estrategia = "Erro de comunicacao com o Ollama"
                    raciocinio = "(sem resposta - falha tecnica na chamada ao Ollama, nao gravado como pensamento)"
                    criarAgentes = 0
                }
            }

            # Remove codigos ANSI de escape do terminal (ex: [2D[K) antes de qualquer uso,
            # para nao poluir nem o parsing nem a memoria guardada entre ciclos
            $outputText = [System.Text.RegularExpressions.Regex]::Replace($outputText, '\x1b(\[[0-9;?]*[a-zA-Z]|\][^\x07]*\x07)', '')
            # Remove caracteres de substituicao Unicode (lixo do spinner "a pensar..." do Ollama,
            # corrompido pela dupla conversao de encoding) para nao poluir o parsing nem a memoria
            $outputText = $outputText -replace '�', ''
            # Agora que a decodificacao esta correta, o spinner do Ollama aparece como os seus
            # proprios caracteres reais (Braille, ex: "⠙⠹⠸⠼"), ja nao como "�" - remove tambem
            # este bloco Unicode especifico (usado so por animacoes de spinner em CLIs)
            $outputText = [System.Text.RegularExpressions.Regex]::Replace($outputText, '[⠀-⣿]', '')
            Log "========== RESPOSTA COMPLETA DO MISTRAL ==========" "IA"
            Log $outputText "IA"
            Log "========== FIM RESPOSTA ==========" "IA"

            # Usa o ULTIMO bloco de decisao encontrado, nao o primeiro: as vezes ela escreve
            # uma decisao, reconsidera e escreve outra mais a frente na mesma resposta -
            # a ultima e a que reflete a decisao final dela, nao um rascunho anterior
            $todosOsBlocos = [System.Text.RegularExpressions.Regex]::Matches($outputText, '\{[\s\S]*?"?acao"?\s*:[\s\S]*?\}')
            $jsonMatch = $todosOsBlocos.Count -gt 0
            if ($jsonMatch) {
                $jsonText = $todosOsBlocos[$todosOsBlocos.Count - 1].Value
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
                    # Nota: [\s"]* (nao so "?) logo apos os dois pontos, porque o terminal por vezes
                    # quebra a linha mesmo a meio do valor, duplicando a aspa de cada lado da quebra
                    # (ex: stopLoss: " seguido de quebra de linha e so depois "1.75) - uma unica aspa
                    # opcional nao chega, é preciso tolerar varias aspas/espacos misturados seguidos
                    # Nota: exclui "null" do que e capturado - ela segue a nossa instrucao de
                    # escrever null quando um campo nao se aplica, mas isso e a PALAVRA "null",
                    # que a regex de resto capturaria como se fosse um valor real (ex: um par
                    # chamado "NULL"), quando na verdade significa ausencia de valor
                    $acao = if ($jsonText -match '"?acao"?\s*:[\s"]*([a-zA-Z]+)' -and $matches[1] -ne 'null') { $matches[1].ToLower() } else { "hold" }
                    $par = if ($jsonText -match '"?par"?\s*:[\s"]*([A-Za-z0-9]+(?:\s*/\s*[A-Za-z0-9]+)?)' -and $matches[1] -ne 'null') { ($matches[1] -replace '\s', '').ToUpper() } else { $null }
                    $montante = if ($jsonText -match '"?montante"?\s*:[\s"]*(\d+\.?\d*)') { [decimal]$matches[1] } else { 5.0 }
                    $stopLoss = if ($jsonText -match '"?stopLoss"?\s*:[\s"]*(\d+\.?\d*)') { [decimal]$matches[1] } else { $null }
                    $alvo = if ($jsonText -match '"?alvo"?\s*:[\s"]*(\d+\.?\d*)') { [decimal]$matches[1] } else { 10 }
                    $estrategia = if ($jsonText -match '"?estrategia"?\s*:[\s"]*([^"]*)"') { $matches[1] } else { "Extraida da IA" }
                    $risco = if ($jsonText -match '"?risco"?\s*:[\s"]*([a-zA-Z]+)') { $matches[1].ToLower() } else { "baixo" }
                    $confianca = if ($jsonText -match '"?confianca"?\s*:[\s"]*(\d+\.?\d*)') { [decimal]$matches[1] } else { 0.5 }
                    $criarAgentes = if ($jsonText -match '"?criarAgentes"?\s*:[\s"]*(\d+)') { [int]$matches[1] } else { 0 }

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

                $acao = if ($outputText -match '"?acao"?\s*:[\s"]*([a-z]+)' -and $matches[1] -ne 'null') { $matches[1] } else { "hold" }
                $par = if ($outputText -match '"?par"?\s*:[\s"]*([A-Za-z0-9]+(?:\s*/\s*[A-Za-z0-9]+)?)' -and $matches[1] -ne 'null') { ($matches[1] -replace '\s', '').ToUpper() } else { $null }
                $montante = if ($outputText -match '"?montante"?\s*:[\s"]*(\d+\.?\d*)') { [decimal]$matches[1] } else { 5.0 }
                $stopLoss = if ($outputText -match '"?stopLoss"?\s*:[\s"]*(\d+\.?\d*)') { [decimal]$matches[1] } else { $null }
                $alvo = if ($outputText -match '"?alvo"?\s*:[\s"]*(\d+\.?\d*)') { [decimal]$matches[1] } else { 10 }
                $risco = if ($outputText -match '"?risco"?\s*:[\s"]*([a-z]+)') { $matches[1] } else { "baixo" }
                $confianca = if ($outputText -match '"?confi[a-z]*"?\s*:[\s"]*(\d\.?\d*)') { [decimal]$matches[1] } else { 0.5 }

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
# POSICOES PERSISTENTES (Testnet)
# ============================================================================
# Em vez de resolver cada trade instantaneamente com um resultado aleatorio, uma
# compra abre (ou reforca) uma posicao real que persiste entre ciclos, com preco de
# entrada e quantidade. O valor da posicao flutua com o preco de mercado (que tambem
# evolui a cada ciclo), e so se realiza o ganho/perda quando ela vende ou quando um
# stop loss / alvo que ela propria definiu e atingido - tal como numa exchange real.

# Ela nao e ensinada a dizer "compra"/"venda"/"hold" especificamente - usa as suas
# proprias palavras. Classifica a intencao pela presenca de radicais comuns em
# portugues, sem lhe impor nenhum vocabulario exato.
function Classifica-Acao {
    param([string]$acao)

    if ([string]::IsNullOrWhiteSpace($acao)) { return "hold" }
    $a = $acao.ToLower()

    if ($a -match "vend|sair|fechar") { return "venda" }
    if ($a -match "^hold$|manter|aguardar|esperar|^nada$") { return "hold" }
    return "compra"
}

# Ela normalmente pensa em precos absolutos para o stop loss/alvo (ex: "vender a 1.05
# USD"), nao em percentagens, mesmo o sistema so aceitando percentagens - confirmado
# pelo proprio raciocinio dela ("alvo 2.5, which is a 116.45% increase from my current
# position price"). Sem isto, um stopLoss positivo tipo "1.05" seria comparado
# diretamente como percentagem, e como qualquer queda negativa e sempre menor que um
# numero positivo, a posicao fechava-se quase de imediato em qualquer ciclo seguinte,
# independentemente do movimento real do preco. Quando o valor dado esta na mesma
# ordem de grandeza do preco atual (entre 50% e 300% dele), interpreta-o como um
# preco-alvo e converte para a percentagem de variacao equivalente; caso contrario,
# assume que ja e uma percentagem.
function Interpreta-Percentagem {
    param($valor, [decimal]$precoReferencia)

    if ($null -eq $valor -or $precoReferencia -le 0) { return $valor }
    $valorDecimal = [decimal]$valor
    $razao = [Math]::Abs($valorDecimal) / $precoReferencia

    if ($razao -ge 0.5 -and $razao -le 3) {
        return (($valorDecimal - $precoReferencia) / $precoReferencia) * 100
    }
    return $valorDecimal
}

function Abre-OuAdiciona-Posicao {
    param([array]$posicoes, [string]$par, [decimal]$montante, [decimal]$precoAtual, $stopLoss, $alvo)

    $stopLoss = Interpreta-Percentagem -valor $stopLoss -precoReferencia $precoAtual
    $alvo = Interpreta-Percentagem -valor $alvo -precoReferencia $precoAtual

    # "Stop loss" so pode significar protecao contra descida, e "alvo" so pode significar
    # objetivo de subida - isto e o significado universal destas duas palavras, nao uma
    # regra de formato. Independentemente do sinal com que ela escreveu o numero (ela usa
    # varias convencoes: percentagem, preco absoluto, ou o valor em USD da posicao),
    # forca sempre o stopLoss a ser negativo e o alvo a ser positivo. Sem isto, um
    # stopLoss positivo (ex: ela pensando no valor em USD, nao numa percentagem) fazia
    # a posicao fechar-se em qualquer movimento normal do mercado, na direcao errada.
    if ($null -ne $stopLoss) { $stopLoss = -[Math]::Abs($stopLoss) }
    if ($null -ne $alvo) { $alvo = [Math]::Abs($alvo) }

    $quantidadeNova = $montante / $precoAtual
    $existente = $posicoes | Where-Object { $_.par -eq $par } | Select-Object -First 1

    if ($existente) {
        $novaQuantidade = $existente.quantidade + $quantidadeNova
        $novoMontanteInvestido = $existente.montanteInvestido + $montante
        $existente.quantidade = $novaQuantidade
        $existente.montanteInvestido = $novoMontanteInvestido
        $existente.precoEntrada = $novoMontanteInvestido / $novaQuantidade
        if ($null -ne $stopLoss) { $existente.stopLoss = $stopLoss }
        if ($null -ne $alvo) { $existente.alvo = $alvo }
        # FIX: a virgula unaria forca isto a sair como array mesmo com 1 so elemento -
        # sem ela, o PowerShell "desembrulha" um array de 1 elemento devolvido por uma
        # funcao para o proprio elemento, transformando $posicoes de volta numa hashtable
        # solta (e ".Count" passaria a contar propriedades da posicao, nao posicoes)
        return ,$posicoes
    }

    $novaPosicao = @{
        par = $par
        quantidade = $quantidadeNova
        montanteInvestido = $montante
        precoEntrada = $precoAtual
        stopLoss = $stopLoss
        alvo = $alvo
        abertoEm = Get-Date -Format "yyyy-MM-ddTHH:mm:ss"
    }
    return ,(@($posicoes) + @($novaPosicao))
}

function Fecha-Posicao {
    param([array]$posicoes, [string]$par, [decimal]$precoAtual)

    $posicao = $posicoes | Where-Object { $_.par -eq $par } | Select-Object -First 1
    if (-not $posicao) { return @{ posicoes = $posicoes; resultado = $null } }

    $valorAtual = $posicao.quantidade * $precoAtual
    $ganho = $valorAtual - $posicao.montanteInvestido
    $novasPosicoes = @($posicoes | Where-Object { $_.par -ne $par })

    return @{
        posicoes = $novasPosicoes
        resultado = @{
            par = $par
            montanteInvestido = $posicao.montanteInvestido
            valorAtual = $valorAtual
            ganho = $ganho
            resultadoPct = if ($posicao.montanteInvestido -gt 0) { [Math]::Round(($ganho / $posicao.montanteInvestido) * 100, 2) } else { 0 }
        }
    }
}

# Verifica todas as posicoes abertas contra o preco atual e fecha automaticamente
# qualquer uma que tenha atingido o stop loss ou o alvo que ela propria definiu -
# exatamente como uma ordem de stop loss / take profit reagiria numa exchange real.
function Verifica-StopLossAlvo {
    param([array]$posicoes, [hashtable]$precosAtuais)

    $fechadas = @()
    $posicoesRestantes = @()

    foreach ($p in $posicoes) {
        $precoAtual = $precosAtuais[$p.par]
        if (-not $precoAtual) { $posicoesRestantes += $p; continue }

        $pctMovimento = (($precoAtual - $p.precoEntrada) / $p.precoEntrada) * 100
        $motivo = $null

        if ($null -ne $p.stopLoss -and $pctMovimento -le $p.stopLoss) {
            $motivo = "stop loss atingido ($([Math]::Round($pctMovimento,2))% <= $($p.stopLoss)%)"
        } elseif ($null -ne $p.alvo -and $pctMovimento -ge $p.alvo) {
            $motivo = "alvo atingido ($([Math]::Round($pctMovimento,2))% >= $($p.alvo)%)"
        }

        if ($motivo) {
            $valorAtual = $p.quantidade * $precoAtual
            $fechadas += @{
                par = $p.par
                montanteInvestido = $p.montanteInvestido
                valorAtual = $valorAtual
                ganho = $valorAtual - $p.montanteInvestido
                motivo = $motivo
            }
        } else {
            $posicoesRestantes += $p
        }
    }

    return @{ posicoes = $posicoesRestantes; fechadas = $fechadas }
}

# Patrimonio total = dinheiro disponivel + valor atual de tudo o que tem investido.
# O game over e o objetivo de 100 usam isto, nao so o saldo em dinheiro - caso
# contrario, alguem com pouco dinheiro solto mas uma posicao valiosa aberta seria
# injustamente declarado "morto" apesar de ter riqueza real por realizar.
function Calcula-Patrimonio {
    param([decimal]$saldo, [array]$posicoes, [hashtable]$precosAtuais)

    $valorPosicoes = 0
    foreach ($p in $posicoes) {
        $precoAtual = if ($precosAtuais[$p.par]) { $precosAtuais[$p.par] } else { $p.precoEntrada }
        $valorPosicoes += $p.quantidade * $precoAtual
    }
    return $saldo + $valorPosicoes
}

# Ela as vezes nomeia so o simbolo (ex: "BTC") em vez do par completo do mercado
# (BTC/USDT), ja que nunca lhe foi ensinado esse formato. Resolve para o par
# conhecido correspondente, para o par escrito por ela nao deixar de bater certo
# com os precos de mercado ou com uma posicao que ela ja tenha aberta.
function Resolve-Par {
    param([string]$par, [hashtable]$precosAtuais)

    if (-not $par) { return $null }
    if ($precosAtuais.ContainsKey($par)) { return $par }

    return $precosAtuais.Keys | Where-Object { $_ -like "$par/*" } | Select-Object -First 1
}

# ============================================================================
# CICLO PRINCIPAL
# ============================================================================

function Executa-Ciclo {
    param([int]$ciclo)

    Log "===== Ciclo $ciclo Iniciado =====" "CICLO"

    # O mercado evolui uma vez por ciclo, partilhado entre todos os agentes
    $mercadoAvancado = Avanca-Mercado
    $precosAtuais = $mercadoAvancado.precos
    $variacoes = $mercadoAvancado.variacoes

    # Patrimonio = dinheiro + valor atual de tudo o que tem investido. E isto que
    # decide game over / objetivo atingido, nao so o dinheiro solto em caixa.
    $patrimonio = Calcula-Patrimonio -saldo $estado.saldo -posicoes $estado.posicoes -precosAtuais $precosAtuais

    try {
        # So morre se perder tudo (patrimonio a zero ou negativo). O limiar nao e os 20
        # EUR iniciais - isso mataria o agente por qualquer flutuacao minima de mercado
        # mesmo com margem saudavel, sem lhe dar hipotese real de arriscar e recuperar.
        # Com o risco real de morrer so ao chegar a zero, ela tem de facto de se
        # esforcar para encontrar formas de nao lá chegar, em vez de um limiar arbitrario
        # que a mata por uma oscilacao de ruido perto do valor inicial.
        if ($patrimonio -le 0) {
            Log "GAME OVER! Patrimonio chegou a zero!" "ERRO"
            Log "Patrimonio final: $patrimonio EUR (inicial: $($estado.saldoInicial) EUR)" "RESULTADO"
            Log "Trades executados: $($estado.trades.Count) | Win Rate: $($estado.winRate)%" "RESULTADO"
            Save-Estado
            exit 1
        }
    } catch {
        Log "Erro no inicio do ciclo: $_" "ERRO"
        throw
    }

    if ($patrimonio -ge 100) {
        Log "OBJETIVO ATINGIDO! Patrimonio: $patrimonio EUR" "SUCESSO"
        Log "Agente entra em repouso por 24 horas..." "INFO"
        Log "Volta a rodar amanha! Descansando..." "INFO"
        Save-Estado
        Start-Sleep -Seconds 86400
        Log "Repouso de 24h concluido. Reiniciando ciclos..." "INFO"
        return
    }

    # Verifica stop loss / alvo automaticos em todas as posicoes abertas, antes dela
    # sequer pensar neste ciclo - tal como uma ordem real dispararia sozinha
    $verificacao = Verifica-StopLossAlvo -posicoes $estado.posicoes -precosAtuais $precosAtuais
    $estado.posicoes = $verificacao.posicoes
    $fechosAutomaticos = @()
    foreach ($f in $verificacao.fechadas) {
        $estado.saldo += $f.valorAtual
        $tradeAuto = @{
            acao = "venda (automatica)"
            par = $f.par
            montante = $f.montanteInvestido
            resultado = if ($f.montanteInvestido -gt 0) { [Math]::Round(($f.ganho / $f.montanteInvestido) * 100, 2) } else { 0 }
            ganho = $f.ganho
            estrategia = $f.motivo
            raciocinio = "Fechado automaticamente: $($f.motivo)"
            timestamp = Get-Date -Format "yyyy-MM-ddTHH:mm:ss"
        }
        $estado.trades += $tradeAuto
        $fechosAutomaticos += $tradeAuto
        Log "AUTO: Posicao $($f.par) fechada automaticamente - $($f.motivo) - Ganho: $($f.ganho) EUR" "TRADE"
    }

    $dadosMercado = Get-MercadoData -precos $precosAtuais -variacoes $variacoes

    $numAgentes = 0
    if (Test-Path ".\agentes-ativos.json") {
        $agentes = Get-Content ".\agentes-ativos.json" | ConvertFrom-Json
        $numAgentes = if ($agentes -is [array]) { $agentes.Count } else { 1 }
    }

    Log "Analisando $($dadosMercado.Count) pares em movimento ($numAgentes agentes ativos)..." "INFO"

    $posicoesContexto = @($estado.posicoes | ForEach-Object {
        $precoAtual = if ($precosAtuais[$_.par]) { $precosAtuais[$_.par] } else { $_.precoEntrada }
        @{
            par = $_.par
            montanteInvestido = $_.montanteInvestido
            precoEntrada = $_.precoEntrada
            precoAtual = $precoAtual
            valorAtual = $_.quantidade * $precoAtual
        }
    })

    $contexto = @{
        saldo = $estado.saldo
        nTrades = $estado.trades.Count
        winRate = $estado.winRate
        mercado = $dadosMercado
        numAgentes = $numAgentes
        historico = $estado.historico
        posicoes = $posicoesContexto
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

    $tipoAcao = Classifica-Acao -acao $deciso.acao
    $trade = $null

    if ($tipoAcao -eq "compra" -and -not $deciso.par) {
        Log "AVISO: Quis comprar mas nao especificou um par." "AVISO"
    } elseif ($tipoAcao -eq "compra") {
        $parResolvido = Resolve-Par -par $deciso.par -precosAtuais $precosAtuais
        $precoAtualPar = if ($parResolvido) { $precosAtuais[$parResolvido] } else { $null }
        if (-not $precoAtualPar) {
            Log "AVISO: Par '$($deciso.par)' desconhecido no mercado. Sem trade." "AVISO"
        } else {
            $montante = $deciso.montante
            # Uma exchange real nunca executa uma ordem maior que o dinheiro disponivel -
            # isto nao e uma regra de estrategia, e um limite fisico de qualquer conta real
            if ($montante -gt $estado.saldo) {
                Log "AVISO: Pediu para investir $montante EUR mas so ha $($estado.saldo) EUR na conta. Uma exchange real limitaria a ordem ao saldo disponivel." "AVISO"
                $montante = $estado.saldo
            }
            if ($montante -gt 0) {
                $estado.posicoes = Abre-OuAdiciona-Posicao -posicoes $estado.posicoes -par $parResolvido -montante $montante -precoAtual $precoAtualPar -stopLoss $deciso.stopLoss -alvo $deciso.alvo
                $estado.saldo -= $montante
                Log "POSICAO: Investidos $montante EUR em $parResolvido a `$$precoAtualPar" "TRADE"
            }
        }
    } elseif ($tipoAcao -eq "venda" -and -not $deciso.par) {
        Log "AVISO: Quis vender mas nao especificou um par." "AVISO"
    } elseif ($tipoAcao -eq "venda") {
        $parResolvido = Resolve-Par -par $deciso.par -precosAtuais $precosAtuais
        $precoAtualPar = if ($parResolvido) { $precosAtuais[$parResolvido] } else { $null }
        if (-not $precoAtualPar) {
            Log "AVISO: Par '$($deciso.par)' desconhecido no mercado. Sem trade." "AVISO"
        } else {
            $fecho = Fecha-Posicao -posicoes $estado.posicoes -par $parResolvido -precoAtual $precoAtualPar
            if ($fecho.resultado) {
                $estado.posicoes = $fecho.posicoes
                $estado.saldo += $fecho.resultado.valorAtual
                $trade = @{
                    acao = "venda"
                    par = $fecho.resultado.par
                    montante = $fecho.resultado.montanteInvestido
                    resultado = $fecho.resultado.resultadoPct
                    ganho = $fecho.resultado.ganho
                    estrategia = $deciso.estrategia
                    raciocinio = $deciso.raciocinio
                    timestamp = Get-Date -Format "yyyy-MM-ddTHH:mm:ss"
                }
                Log "TRADE: Vendeu $($deciso.par) | Resultado: $($fecho.resultado.resultadoPct)% | Ganho: $($fecho.resultado.ganho) EUR" "TRADE"
            } else {
                Log "AVISO: Pediu para vender $($deciso.par) mas nao tem posicao aberta nesse par." "AVISO"
            }
        }
    } else {
        Log "IA decidiu nao abrir/fechar nada agora (acao='$($deciso.acao)')" "INFO"
    }

    if ($trade) {
        $estado.trades += $trade
        $estado.ultimaTradaEm = Get-Date -Format "yyyy-MM-ddTHH:mm:ss"
    }

    if ($estado.trades.Count -gt 0) {
        $vitorias = @($estado.trades | Where-Object { $_.ganho -gt 0 }).Count
        $estado.winRate = [Math]::Round(($vitorias / $estado.trades.Count) * 100, 1)
    }

    $patrimonioApos = Calcula-Patrimonio -saldo $estado.saldo -posicoes $estado.posicoes -precosAtuais $precosAtuais
    Log "Saldo (cash): $($estado.saldo) EUR | Patrimonio total: $patrimonioApos EUR | Win Rate: $($estado.winRate)%" "RESULTADO"

    if ($patrimonioApos -ge 100) {
        Log "OBJETIVO ATINGIDO! Patrimonio: $patrimonioApos EUR" "SUCESSO"
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
        patrimonioApos = $patrimonioApos
        posicoesFechadasAutomaticamente = $fechosAutomaticos
    }
    $estado.ciclosHistorico += $entradaCiclo
    if ($estado.ciclosHistorico.Count -gt 100) {
        $estado.ciclosHistorico = $estado.ciclosHistorico | Select-Object -Last 100
    }

    $resumoTelegram = "Ciclo #$ciclo - Patrimonio: $patrimonioApos EUR (cash: $($estado.saldo) EUR)`n`n" + `
        "Pensamento:`n$($deciso.raciocinio)`n`n" + `
        "Decisao: $($deciso.acao) $($deciso.montante) em $($deciso.par)" + `
        $(if ($trade) { "`nResultado: $($trade.resultado)% | Ganho: $($trade.ganho) EUR" } else { "" }) + `
        $(if ($fechosAutomaticos.Count -gt 0) { "`n`nFechados automaticamente:`n" + (($fechosAutomaticos | ForEach-Object { "- $($_.par): $($_.estrategia) | Ganho: $($_.ganho) EUR" }) -join "`n") } else { "" })
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

# Continua a contagem de ciclos de onde ficou (nao reinicia para 1 a cada reinicio do
# processo) - senao os logs mostram numeros de ciclo repetidos apos um crash/reinicio
# do supervisor, o que confunde a leitura do historico
$ciclo = if ($estado.ciclosHistorico -and $estado.ciclosHistorico.Count -gt 0) {
    ($estado.ciclosHistorico | Select-Object -Last 1).ciclo + 1
} else { 1 }
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
