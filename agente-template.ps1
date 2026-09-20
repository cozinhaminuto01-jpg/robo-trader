# ============================================================================
# AGENTE GENERICO - Trader Autonomo com IA Local (Ollama/Mistral)
# ============================================================================
# Cada instancia roda em paralelo, toma decisoes proprias
# Usa Mistral (Ollama local) para pensar onde investir, como, quando
# Sem estrategia pre-configurada: IA descobre autonomamente

param(
    [string]$AgenteID = "Agente_1",
    [decimal]$SaldoInicial = 20,
    [string]$ConfigPath = ".\config-testnet.json",
    [decimal]$ObjetivoPatrimonio = 1000,
    [string]$MissaoAtribuida = ""
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

# Quantos ciclos de pura observacao (sem trades reais) antes do primeiro compra/reforco -
# ela continua a pensar e a decidir livremente desde o ciclo 1, sem qualquer orientacao
# de estrategia; isto so atrasa a EXECUCAO de uma compra/reforco real, dando-lhe mais
# ciclos de mercado observado antes de arriscar dinheiro pela primeira vez. Configuravel
# via "ciclos_aprendizagem" no config; 5 por omissao se nao estiver definido.
$ciclosAprendizagem = if ($config.ciclos_aprendizagem) { [int]$config.ciclos_aprendizagem } else { 5 }

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
    ultimaPesquisa = $null
    precoHistorico = @()
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

# Limpa o output bruto capturado do Ollama (codigos ANSI do terminal, caracteres de
# substituicao Unicode e o spinner Braille "a pensar...") - usado tanto na resposta
# principal dela como na traducao para o Telegram, para nao duplicar esta logica.
function Limpa-OutputOllama {
    param([string]$outputText)

    $outputText = [System.Text.RegularExpressions.Regex]::Replace($outputText, '\x1b(\[[0-9;?]*[a-zA-Z]|\][^\x07]*\x07)', '')
    $caracterSubstituicao = [char]0xFFFD
    $outputText = $outputText -replace $caracterSubstituicao, ''
    $brailleInicio = [char]0x2800
    $brailleFim = [char]0x28FF
    $outputText = [System.Text.RegularExpressions.Regex]::Replace($outputText, "[$brailleInicio-$brailleFim]", '')
    return $outputText
}

# So para a mensagem que chega ao Telegram - traduz o pensamento dela para portugues
# quando ela escreve noutra lingua (Mistral, sendo um modelo pequeno, nem sempre segue
# a instrucao de idioma pedida no prompt principal). O raciocinio guardado no historico/
# memoria dela NAO passa por aqui - fica exatamente como ela escreveu, para nao alterar
# nada daquilo que ela propria vai reler depois.
function Traduz-Para-Portugues {
    param([string]$texto)

    if ([string]::IsNullOrWhiteSpace($texto)) { return $texto }

    try {
        $promptTraducao = "Traduz TODO o texto seguinte para portugues europeu. E MUITO IMPORTANTE: a tua resposta tem de estar inteiramente em portugues, nunca em ingles, espanhol ou qualquer outra lingua, mesmo que o texto original esteja nessas linguas. Nao acrescentes comentarios nem explicacoes, nao repitas o texto original, nao uses aspas a volta - responde APENAS com o texto traduzido.`n`nTexto a traduzir:`n$texto"
        Log "A traduzir pensamento para o Telegram..." "IA"
        $output = $promptTraducao | & ollama run mistral 2>&1

        if (-not $output) {
            Log "AVISO: Traducao nao devolveu nada, a usar texto original no Telegram" "AVISO"
            return $texto
        }
        $outputText = ($output -join "`n")

        if ($outputText -match '^Error:|RemoteException|is not recognized as|ollama: command not found') {
            Log "AVISO: Traducao falhou (erro de CLI do Ollama), a usar texto original no Telegram: $outputText" "AVISO"
            return $texto
        }

        $outputText = (Limpa-OutputOllama $outputText).Trim()
        if ([string]::IsNullOrWhiteSpace($outputText)) {
            Log "AVISO: Traducao veio vazia apos limpeza, a usar texto original no Telegram" "AVISO"
            return $texto
        }
        Log "Traducao para o Telegram: $outputText" "IA"
        return $outputText
    } catch {
        Log "AVISO: Falha ao traduzir pensamento para o Telegram, a usar original: $_" "AVISO"
        return $texto
    }
}

function Load-Estado {
    if (Test-Path ".\estado-$AgenteID.json") {
        $obj = Get-Content ".\estado-$AgenteID.json" -Encoding UTF8 | ConvertFrom-Json
        # FIX: Ensure numeric fields are actually decimals/ints, not PSObjects
        #
        # FIX: a virgula unaria (,@(...)) e essencial aqui - sem ela, um campo com
        # exatamente 1 elemento guardado no ultimo Save-Estado (ex: mesmo depois de um
        # unico ciclo) faz o "if{} else{}" usado como valor colapsar o array de volta a
        # um objeto escalar (o mesmo colapso de array de 1 elemento do PowerShell que ja
        # nos mordeu noutros sitios do codigo). Sem a virgula, a proxima linha que fizer
        # "$estado.X += novoItem" rebenta com "nao contem um metodo denominado
        # 'op_Addition'" - foi exatamente isto que aconteceu ao reiniciar logo a seguir
        # ao primeiro ciclo alguma vez gravado (ciclosHistorico com so 1 entrada).
        return @{
            id = if ($obj.id) { [string]$obj.id } else { $AgenteID }
            saldo = if ($obj.saldo) { [decimal]$obj.saldo } else { [decimal]$SaldoInicial }
            saldoInicial = if ($obj.saldoInicial) { [decimal]$obj.saldoInicial } else { [decimal]$SaldoInicial }
            posicoes = if ($obj.posicoes) { ,@($obj.posicoes) } else { @() }
            historico = if ($obj.historico) { ,@($obj.historico) } else { @() }
            trades = if ($obj.trades) { ,@($obj.trades) } else { @() }
            ciclosHistorico = if ($obj.ciclosHistorico) { ,@($obj.ciclosHistorico) } else { @() }
            winRate = if ($obj.winRate) { [decimal]$obj.winRate } else { 0 }
            ultimaTradaEm = if ($obj.ultimaTradaEm) { $obj.ultimaTradaEm } else { $null }
            ultimaPesquisa = if ($obj.ultimaPesquisa) { $obj.ultimaPesquisa } else { $null }
            precoHistorico = if ($obj.precoHistorico) { ,@($obj.precoHistorico) } else { @() }
        }
    }
    return $null
}

# Limpa uma string com marcacao HTML (tags, entidades como &amp;) para texto simples -
# usado para converter os resultados de pesquisa na internet num texto legivel no prompt.
function Limpa-HtmlTexto {
    param([string]$texto)
    $t = $texto -replace '<[^>]+>', ''
    $t = [System.Net.WebUtility]::HtmlDecode($t)
    return $t.Trim()
}

# Pesquisa na internet (DuckDuckGo, sem chave de API) quando ela propria pede - para
# obter informacao que nao esta disponivel so com os precos da Binance (noticias,
# eventos, contexto). Nao corre sozinho: so quando ela escreve algo no campo
# "pesquisar" da sua propria decisao. Falha em silencio (aviso no log, sem rebentar
# o ciclo) se a rede estiver em baixo ou a pagina mudar de estrutura.
function Pesquisa-Internet {
    param([string]$query)

    if ([string]::IsNullOrWhiteSpace($query)) { return $null }

    try {
        $url = "https://html.duckduckgo.com/html/?q=" + [System.Uri]::EscapeDataString($query)
        $headers = @{ "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64)" }
        $resposta = Invoke-WebRequest -Uri $url -Headers $headers -UseBasicParsing -TimeoutSec 15
        $html = $resposta.Content

        $titulos = [System.Text.RegularExpressions.Regex]::Matches($html, '<a[^>]*class="result__a"[^>]*>([\s\S]*?)</a>')
        $snippets = [System.Text.RegularExpressions.Regex]::Matches($html, '<a[^>]*class="result__snippet"[^>]*>([\s\S]*?)</a>')

        $resultados = @()
        for ($i = 0; $i -lt [Math]::Min(3, $titulos.Count); $i++) {
            $titulo = Limpa-HtmlTexto $titulos[$i].Groups[1].Value
            $snippet = if ($i -lt $snippets.Count) { Limpa-HtmlTexto $snippets[$i].Groups[1].Value } else { "" }
            if ($titulo) { $resultados += "- $($titulo): $snippet" }
        }

        if ($resultados.Count -eq 0) {
            Log "AVISO: Pesquisa na internet por '$query' nao encontrou resultados (ou a pagina mudou de estrutura)." "AVISO"
            return $null
        }

        return ($resultados -join "`n")
    } catch {
        Log "AVISO: Falha ao pesquisar na internet por '$query': $_" "AVISO"
        return $null
    }
}

# ============================================================================
# BINANCE API (Testnet real - testnet.binance.vision)
# ============================================================================
# Liga-se a conta de testes da propria Binance (dinheiro sempre falso, nunca a
# conta real) - precos de mercado, saldo e execucao de ordens passam a vir de
# la, em vez de serem simulados localmente. So se ativa quando ha chaves da
# testnet configuradas; sem elas, mantem-se o mercado simulado (Avanca-Mercado)
# para nao partir instalacoes que ainda nao tenham chaves.

$BINANCE_TESTNET_URL = "https://testnet.binance.vision"

# Pares que o sistema conhece e o simbolo correspondente na Binance (sem a barra)
$PARES_BINANCE = [ordered]@{
    "BTC/USDT" = "BTCUSDT"
    "ETH/USDT" = "ETHUSDT"
    "SOL/USDT" = "SOLUSDT"
    "XRP/USDT" = "XRPUSDT"
    "ADA/USDT" = "ADAUSDT"
}

$script:FiltrosBinanceCache = @{}

# O ficheiro de configuracao do utilizador ja usava binance_testnet_key/secret antes
# de este codigo existir; aceita tambem os nomes binance_api_key_testnet/secret_testnet
# usados no template do repositorio, para funcionar com qualquer um dos dois sem
# obrigar a editar o ficheiro outra vez.
function Get-BinanceKey {
    $valor = if ($config.binance_testnet_key) { $config.binance_testnet_key } else { $config.binance_api_key_testnet }
    if ($valor) { return $valor.Trim() }
    return $valor
}
function Get-BinanceSecret {
    $valor = if ($config.binance_testnet_secret) { $config.binance_testnet_secret } else { $config.binance_api_secret_testnet }
    if ($valor) { return $valor.Trim() }
    return $valor
}

function Tem-BinanceConfigurado {
    $key = Get-BinanceKey
    $secret = Get-BinanceSecret
    if (-not $key -or -not $secret) { return $false }
    if ($key -match "COLOCA_AQUI" -or $secret -match "COLOCA_AQUI") { return $false }
    return $true
}

# Converte um valor JSON (sempre texto na API da Binance, ex: "43250.00000000") para
# decimal SEM depender do locale da maquina. Um cast direto [decimal]$texto usa a
# cultura atual - numa maquina configurada em portugues (virgula como separador
# decimal), isto corrompe silenciosamente o numero (ex: "43250.00000000" passava a
# 43250, perdendo os decimais) em vez de dar erro, o que passaria despercebido.
function ConvertTo-DecimalInvariante {
    param($valor)
    if ($null -eq $valor) { return $null }
    return [decimal]::Parse([string]$valor, [System.Globalization.NumberStyles]::Any, [System.Globalization.CultureInfo]::InvariantCulture)
}

# O inverso: converte um decimal para texto para enviar num pedido a Binance, sempre
# com ponto decimal, nunca com a virgula que o locale portugues usaria por omissao
# (.ToString() simples dava "0,015" em vez de "0.015", que a API rejeitaria ou
# interpretaria mal)
function ConvertFrom-DecimalInvariante {
    param([decimal]$valor)
    return $valor.ToString([System.Globalization.CultureInfo]::InvariantCulture)
}

function Get-BinanceSignature {
    param([string]$queryString, [string]$secret)
    $hmac = New-Object System.Security.Cryptography.HMACSHA256
    $hmac.Key = [Text.Encoding]::UTF8.GetBytes($secret)
    $hash = $hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($queryString))
    return -join ($hash | ForEach-Object { $_.ToString("x2") })
}

function ConvertTo-BinanceQueryString {
    param([System.Collections.Specialized.OrderedDictionary]$parametros)
    return ($parametros.Keys | ForEach-Object {
        $valor = $parametros[$_]
        $valorTexto = if ($valor -is [decimal]) { ConvertFrom-DecimalInvariante $valor } else { [string]$valor }
        "$_=$([uri]::EscapeDataString($valorTexto))"
    }) -join "&"
}

function Invoke-BinancePublico {
    param([string]$caminho, [string]$queryString = "")
    $uri = "$BINANCE_TESTNET_URL$caminho"
    if ($queryString) { $uri += "?$queryString" }
    return Invoke-RestMethod -Uri $uri -Method Get -TimeoutSec 15
}

function Invoke-BinanceAssinado {
    param([string]$caminho, [string]$metodo = "GET", [System.Collections.Specialized.OrderedDictionary]$parametros = [ordered]@{})

    $params = [ordered]@{}
    foreach ($k in $parametros.Keys) { $params[$k] = $parametros[$k] }
    $params["recvWindow"] = 10000
    $params["timestamp"] = [long]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())

    $queryString = ConvertTo-BinanceQueryString $params
    $assinatura = Get-BinanceSignature -queryString $queryString -secret (Get-BinanceSecret)
    $uri = "$BINANCE_TESTNET_URL$caminho`?$queryString&signature=$assinatura"
    $headers = @{ "X-MBX-APIKEY" = (Get-BinanceKey) }
    return Invoke-RestMethod -Uri $uri -Method $metodo -Headers $headers -TimeoutSec 15
}

# Preco, variacao 24h e volume reais de todos os pares seguidos, numa unica chamada -
# substitui o passeio aleatorio local (Avanca-Mercado) quando ha chaves configuradas.
function Get-BinanceDadosMercado {
    $simbolos = @($PARES_BINANCE.Values)
    $simboloParaPar = @{}
    foreach ($par in $PARES_BINANCE.Keys) { $simboloParaPar[$PARES_BINANCE[$par]] = $par }

    try {
        $simbolosJson = ($simbolos | ConvertTo-Json -Compress)
        $queryString = "symbols=" + [uri]::EscapeDataString($simbolosJson)
        $tickers = Invoke-BinancePublico -caminho "/api/v3/ticker/24hr" -queryString $queryString
    } catch {
        Log "AVISO: Falha ao obter dados de mercado reais da Binance Testnet: $_" "AVISO"
        return $null
    }

    $precos = @{}
    $variacoes = @{}
    $volumes = @{}
    foreach ($t in $tickers) {
        $par = $simboloParaPar[$t.symbol]
        if (-not $par) { continue }
        $precos[$par] = ConvertTo-DecimalInvariante $t.lastPrice
        $variacoes[$par] = ConvertTo-DecimalInvariante $t.priceChangePercent
        $volumes[$par] = ConvertTo-DecimalInvariante $t.quoteVolume
    }
    if ($precos.Count -eq 0) { return $null }
    return @{ precos = $precos; variacoes = $variacoes; volumes = $volumes }
}

# Saldo real (USDT livre) da conta testnet - substitui o saldo so guardado localmente
function Get-BinanceSaldoReal {
    try {
        $conta = Invoke-BinanceAssinado -caminho "/api/v3/account" -metodo "GET"
        $usdt = $conta.balances | Where-Object { $_.asset -eq "USDT" } | Select-Object -First 1
        if ($usdt) { return ConvertTo-DecimalInvariante $usdt.free }
        return $null
    } catch {
        Log "AVISO: Falha ao obter saldo real da Binance Testnet: $_" "AVISO"
        return $null
    }
}

# Regras de lote/valor minimo de cada simbolo (obrigatorias para uma ordem ser aceite
# pela Binance) - cada uma so e pedida uma vez por simbolo e fica em cache
function Get-BinanceFiltros {
    param([string]$simbolo)

    if ($script:FiltrosBinanceCache.ContainsKey($simbolo)) { return $script:FiltrosBinanceCache[$simbolo] }

    $filtrosPorOmissao = @{ stepSize = [decimal]0.00000001; minQty = [decimal]0; minNotional = [decimal]0 }
    try {
        $info = Invoke-BinancePublico -caminho "/api/v3/exchangeInfo" -queryString "symbol=$simbolo"
        $simboloInfo = $info.symbols | Select-Object -First 1
        if (-not $simboloInfo) { return $filtrosPorOmissao }

        $lotSize = $simboloInfo.filters | Where-Object { $_.filterType -eq "LOT_SIZE" } | Select-Object -First 1
        $notional = $simboloInfo.filters | Where-Object { $_.filterType -eq "MIN_NOTIONAL" -or $_.filterType -eq "NOTIONAL" } | Select-Object -First 1

        $minNotionalValor = [decimal]0
        if ($notional) {
            if ($notional.minNotional) { $minNotionalValor = ConvertTo-DecimalInvariante $notional.minNotional }
            elseif ($notional.notional) { $minNotionalValor = ConvertTo-DecimalInvariante $notional.notional }
        }

        $filtros = @{
            stepSize = if ($lotSize) { ConvertTo-DecimalInvariante $lotSize.stepSize } else { [decimal]0.00000001 }
            minQty = if ($lotSize) { ConvertTo-DecimalInvariante $lotSize.minQty } else { [decimal]0 }
            minNotional = $minNotionalValor
        }
        $script:FiltrosBinanceCache[$simbolo] = $filtros
        return $filtros
    } catch {
        Log "AVISO: Falha ao obter filtros de $simbolo, a usar valores por omissao: $_" "AVISO"
        return $filtrosPorOmissao
    }
}

# Arredonda para baixo ate ao multiplo de stepSize mais proximo - a Binance rejeita
# quantidades com mais casas decimais do que o lote minimo do simbolo permite
function Arredonda-QuantidadeBinance {
    param([decimal]$quantidade, [decimal]$stepSize)
    if ($stepSize -le 0) { return $quantidade }
    $passos = [Math]::Floor($quantidade / $stepSize)
    return $passos * $stepSize
}

# Coloca uma ordem de mercado real (compra ou venda) na Binance Testnet e devolve o
# que foi mesmo executado - nunca assume que o preco pedido foi o preco de execucao,
# tal como aconteceria numa exchange real
function Coloca-OrdemBinance {
    param([string]$simbolo, [string]$lado, [decimal]$quantidade)

    try {
        $parametros = [ordered]@{
            symbol = $simbolo
            side = $lado
            type = "MARKET"
            quantity = $quantidade
        }
        $ordem = Invoke-BinanceAssinado -caminho "/api/v3/order" -metodo "POST" -parametros $parametros

        $qtyExecutada = ConvertTo-DecimalInvariante $ordem.executedQty
        $valorExecutado = ConvertTo-DecimalInvariante $ordem.cummulativeQuoteQty
        $precoMedio = if ($qtyExecutada -gt 0) { $valorExecutado / $qtyExecutada } else { [decimal]0 }

        if ($qtyExecutada -le 0) {
            Log "AVISO: Ordem $lado $simbolo aceite mas nao executou nenhuma quantidade (estado: $($ordem.status))" "AVISO"
            return @{ sucesso = $false }
        }

        return @{
            sucesso = $true
            quantidade = $qtyExecutada
            valorTotal = $valorExecutado
            precoMedio = $precoMedio
            ordemId = $ordem.orderId
        }
    } catch {
        Log "AVISO: Ordem $lado $simbolo de $quantidade falhou na Binance Testnet: $_" "AVISO"
        return @{ sucesso = $false }
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
    param([hashtable]$precos, [hashtable]$variacoes, [hashtable]$volumes = $null, [array]$precoHistorico = @())

    $pares = @()
    foreach ($par in $precos.Keys) {
        $pares += @{
            par = $par
            preco = [Math]::Round($precos[$par], 4)
            mudanca24h = $variacoes[$par]
            # Com Binance Testnet real ha volume real de 24h; sem ela (mercado simulado),
            # nao existe volume nenhum para mostrar - inventar um numero apenas
            # preencheria a conversa com informacao falsa sem qualquer utilidade
            volume = if ($volumes -and $volumes.ContainsKey($par)) { [Math]::Round($volumes[$par], 2) } else { $null }
            # Variacoes de 1h/6h calculadas a partir do historico local de precos (nao
            # vem da Binance) - a mudanca24h por si so nao diz se um movimento e recente
            # ou se vem de ha muitas horas, o que dificultava perceber a tendencia real
            mudanca1h = Calcula-VariacaoHistorica -precoHistorico $precoHistorico -par $par -precoAtual $precos[$par] -minutosAlvo 60
            mudanca6h = Calcula-VariacaoHistorica -precoHistorico $precoHistorico -par $par -precoAtual $precos[$par] -minutosAlvo 360
        }
    }
    return $pares | Get-Random -Count (Get-Random -Minimum 2 -Maximum ($pares.Count + 1))
}

# Guarda um instantaneo dos precos atuais a cada ciclo, para calcular variacoes de 1h/6h
# sem depender de mais chamadas a Binance - a variacao24h que a Binance ja da nao chega
# para perceber se um movimento e recente ou se vem de ha muitas horas
function Atualiza-PrecoHistorico {
    param([array]$precoHistorico, [hashtable]$precosAtuais)

    $agora = Get-Date
    $novoHistorico = @($precoHistorico) + @{
        timestamp = $agora.ToString("yyyy-MM-ddTHH:mm:ss")
        precos = $precosAtuais
    }

    # So guarda as ultimas ~7h de instantaneos - chega para calcular a variacao de 6h
    # com alguma margem, sem o ficheiro de estado crescer sem limite
    $limiar = $agora.AddHours(-7)
    $novoHistorico = @($novoHistorico | Where-Object {
        try { [DateTime]::Parse($_.timestamp) -ge $limiar } catch { $true }
    })

    return ,$novoHistorico
}

# Procura no historico local o instantaneo mais proximo de X minutos atras e calcula a
# variacao percentual do preco desse par desde ai ate ao preco atual
function Calcula-VariacaoHistorica {
    param([array]$precoHistorico, [string]$par, [decimal]$precoAtual, [int]$minutosAlvo)

    if (-not $precoHistorico -or $precoHistorico.Count -eq 0) { return $null }

    $agora = Get-Date
    $alvoTimestamp = $agora.AddMinutes(-$minutosAlvo)

    $melhorCandidato = $null
    $melhorDiferenca = $null
    foreach ($instantaneo in $precoHistorico) {
        try { $ts = [DateTime]::Parse($instantaneo.timestamp) } catch { continue }
        # So considera instantaneos com pelo menos metade da idade alvo, para nao usar
        # o preco de ha 2 minutos como se fosse "a variacao de 1h"
        if ($ts -gt $agora.AddMinutes(-($minutosAlvo * 0.5))) { continue }
        $diferenca = [Math]::Abs(($ts - $alvoTimestamp).TotalSeconds)
        if ($null -eq $melhorDiferenca -or $diferenca -lt $melhorDiferenca) {
            $melhorDiferenca = $diferenca
            $melhorCandidato = $instantaneo
        }
    }

    if (-not $melhorCandidato) { return $null }

    $precoAntigo = $melhorCandidato.precos.$par
    if (-not $precoAntigo -or $precoAntigo -eq 0) { return $null }

    return [Math]::Round((($precoAtual - [decimal]$precoAntigo) / [decimal]$precoAntigo) * 100, 3)
}

# ============================================================================
# CHAMADA A IA (Ollama/Mistral - IA Local)
# ============================================================================

# Resume o historico estruturado (ciclosHistorico, nao o texto cru) em factos concretos
# - quantas vezes fez cada acao, resultado das posicoes fechadas - em vez de repetir os
# paragrafos inteiros das ultimas respostas dela. Isto da-lhe mais sinal util por menos
# texto do que reler o mesmo raciocinio 3 vezes seguidas.
function Resume-Historico {
    param([array]$ciclosHistorico)

    if (-not $ciclosHistorico -or $ciclosHistorico.Count -eq 0) {
        return "(ainda nao pensaste nisto antes, e a primeira vez que conversas sobre isto)"
    }

    $recentes = @($ciclosHistorico | Select-Object -Last 20)

    $porAcao = $recentes | Group-Object -Property acao | Sort-Object Count -Descending
    $resumoAcoes = ($porAcao | ForEach-Object { "$($_.Name): $($_.Count)x" }) -join ", "

    $fechados = @($recentes | Where-Object { $null -ne $_.resultado })
    $resumoFechados = if ($fechados.Count -gt 0) {
        $ganhoTotal = [Math]::Round((($fechados | Measure-Object -Property ganho -Sum).Sum), 2)
        "Fechaste $($fechados.Count) posicao(oes) nesse periodo, com um ganho total de $ganhoTotal EUR."
    } else {
        "Nao fechaste nenhuma posicao nesse periodo."
    }

    $ultimo = $recentes | Select-Object -Last 1
    $ultimoRaciocinio = $ultimo.raciocinio
    if ($ultimoRaciocinio -and $ultimoRaciocinio.Length -gt 350) {
        $ultimoRaciocinio = $ultimoRaciocinio.Substring(0, 350) + "(...)"
    }

    return "Nos ultimos $($recentes.Count) ciclos, as tuas decisoes foram: $resumoAcoes. $resumoFechados`nO teu ultimo pensamento foi: $ultimoRaciocinio"
}

function Chama-IA {
    param([hashtable]$contexto)

    # Usa um resumo estruturado (contagens de acoes, resultado das posicoes fechadas) em
    # vez de repetir os paragrafos inteiros das ultimas respostas - um historico completo
    # e muito longo (ela por vezes escreve varios paragrafos) estava a fazer o prompt
    # crescer para milhares de palavras de texto repetido a cada ciclo, o que a levava a
    # citar o proprio prompt de volta como se fosse a resposta dela, e a confundir-se
    # sobre unidades (quantidade de ETH em vez de USD a investir). O historico completo
    # continua guardado no estado para o dashboard - isto so muda o que lhe e relembrado
    # a cada ciclo, nao apaga nada
    $memoria = if ($contexto.ciclosHistorico -and $contexto.ciclosHistorico.Count -gt 0) {
        Resume-Historico -ciclosHistorico $contexto.ciclosHistorico
    } else {
        "(ainda nao pensaste nisto antes, e a primeira vez que conversas sobre isto)"
    }

    $agentesInfo = if ($contexto.numAgentes -gt 1) { "Tens tambem $($contexto.numAgentes - 1) outra(s) conta(s)/agente(s) que ja criaste antes." } else { "" }

    $missaoTexto = if (-not [string]::IsNullOrWhiteSpace($MissaoAtribuida)) { "`nA conta que te criou deu-te esta missao/foco: `"$MissaoAtribuida`" - tens liberdade total sobre como a cumpres, isto e so orientacao, nao uma regra obrigatoria." } else { "" }

    $pesquisaTexto = if ($contexto.ultimaPesquisa -and $contexto.ultimaPesquisa.resultados) {
        "`nPediste para pesquisar na internet por `"$($contexto.ultimaPesquisa.query)`" e isto foi o que encontraste:`n$($contexto.ultimaPesquisa.resultados)`n"
    } else {
        ""
    }

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
O objetivo e da empresa toda: a soma do patrimonio de todas as contas que fazem parte dela (incluindo a tua, e as que tu proprio criares) tem de chegar aos $ObjetivoPatrimonio USD. Quando a empresa lá chegar, todas as contas ganham um descanso.
Se O TEU patrimonio chegar a 0, e o fim para ti - perdes tudo e nao ha volta atras (as outras contas da empresa, se houver, continuam).
$agentesInfo$missaoTexto

As tuas posicoes abertas neste momento:
$posicoesTexto

O que ja pensaste sobre isto em conversas anteriores:
$memoria
$pesquisaTexto
Informacao disponivel na tua conta Binance neste momento:
$($contexto.mercado | ForEach-Object { "- $($_.par): `$$($_.preco) (mudanca 24h: $($_.mudanca24h)%$(if ($null -ne $_.mudanca6h) { ", 6h: $($_.mudanca6h)%" })$(if ($null -ne $_.mudanca1h) { ", 1h: $($_.mudanca1h)%" }))$(if ($null -ne $_.volume) { " volume: $($_.volume)" })" } | Out-String)

Ninguem te vai dizer o que fazer nem como fazer. Pensa livremente sobre a tua situacao e decide tu mesmo o que fazer a seguir - podes abrir uma posicao nova, reforcar ou vender uma que ja tens, ou nao fazer nada agora.

(Escreve os teus pensamentos em portugues - isto e so para eu conseguir acompanhar o que pensas, nao influencia em nada a tua decisao.)

No fim da tua resposta, regista a tua decisao neste formato (usa null nos campos que nao se aplicarem, e 0 se nao quiseres criar nada). O "montante" e sempre o valor em USD que queres investir (nao a quantidade de moeda) - por exemplo, para comprar 20 USD de ETH e "montante": 20, seja qual for o preco do ETH. Se pedires "criarAgentes", o novo agente fica na mesma empresa (o objetivo de $ObjetivoPatrimonio USD passa a contar a soma dele com a tua) mas ele pensa e decide por si mesmo - usa "missaoNovoAgente" para lhe dares uma missao/foco (ex: "foca-te so em ADA e XRP"), ou deixa null para lhe dares liberdade total. Se quiseres saber algo que nao esta nesta informacao (noticias, o que aconteceu com uma moeda, contexto do mercado), usa "pesquisar" para escreveres o que queres pesquisar na internet - o resultado aparece-te na proxima vez que pensares nisto:

{"acao": "...", "par": "...", "montante": ..., "stopLoss": ..., "alvo": ..., "criarAgentes": 0, "missaoNovoAgente": null, "pesquisar": null}
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

            # Remove codigos ANSI de escape do terminal, caracteres de substituicao e o
            # spinner Braille do Ollama antes de qualquer uso, para nao poluir nem o
            # parsing nem a memoria guardada entre ciclos (mesma limpeza usada na traducao
            # para o Telegram, ver Limpa-OutputOllama)
            $outputText = Limpa-OutputOllama $outputText
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
                    $alvo = if ($jsonText -match '"?alvo"?\s*:[\s"]*(\d+\.?\d*)') { [decimal]$matches[1] } else { $null }
                    $estrategia = if ($jsonText -match '"?estrategia"?\s*:[\s"]*([^"]*)"') { $matches[1] } else { "Extraida da IA" }
                    $risco = if ($jsonText -match '"?risco"?\s*:[\s"]*([a-zA-Z]+)') { $matches[1].ToLower() } else { "baixo" }
                    $confianca = if ($jsonText -match '"?confianca"?\s*:[\s"]*(\d+\.?\d*)') { [decimal]$matches[1] } else { 0.5 }
                    $criarAgentes = if ($jsonText -match '"?criarAgentes"?\s*:[\s"]*(\d+)') { [int]$matches[1] } else { 0 }
                    $missaoNovoAgente = if ($jsonText -match '"?missaoNovoAgente"?\s*:[\s"]*"([^"]*)"' -and $matches[1] -ne 'null') { $matches[1] } else { $null }
                    $pesquisar = if ($jsonText -match '"?pesquisar"?\s*:[\s"]*"([^"]*)"' -and $matches[1] -ne 'null') { $matches[1] } else { $null }

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
                        missaoNovoAgente = $missaoNovoAgente
                        pesquisar = $pesquisar
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
                $alvo = if ($outputText -match '"?alvo"?\s*:[\s"]*(\d+\.?\d*)') { [decimal]$matches[1] } else { $null }
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
    param([int]$numeroAgente, [decimal]$capital, [string]$missao = "")

    $missaoLog = if ([string]::IsNullOrWhiteSpace($missao)) { "(sem missao especifica, liberdade total)" } else { $missao }
    Log "CEO DECISION: Criando novo Agente_$numeroAgente com capital de $capital EUR - missao: $missaoLog" "DECISAO"

    $novoAgenteFile = ".\agente-$numeroAgente.ps1"
    $conteudoScript = Get-Content ".\agente-template.ps1" -Raw -Encoding UTF8

    $conteudoScript | Set-Content $novoAgenteFile -Encoding UTF8

    # A nova conta fica na mesma empresa: corre o proprio Ollama e decide por si mesma a
    # cada ciclo (nao e o CEO a executar as ordens dela), mas recebe o objetivo/missao que
    # o CEO lhe deu, e o patrimonio dela passa a contar para o objetivo somado da empresa
    # (ver Sincroniza-PatrimonioEmpresa).
    $job = Start-Job -FilePath $novoAgenteFile -ArgumentList @("Agente_$numeroAgente", $capital, ".\config-testnet.json", $ObjetivoPatrimonio, $missao)

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
        patrimonioAtual = $capital
        missao = $missao
        criadoEm = Get-Date -Format "yyyy-MM-ddTHH:mm:ss"
        status = "ativo"
    }

    $agentes | ConvertTo-Json | Set-Content ".\agentes-ativos.json" -Encoding UTF8

    return @{ id = "Agente_$numeroAgente"; jobId = $job.Id }
}

function Sincroniza-PatrimonioEmpresa {
    param([decimal]$patrimonioProprio)

    # Cada conta da empresa (o CEO e cada agente que ele criar) grava aqui o seu proprio
    # patrimonio mais recente, para que o objetivo dos $ObjetivoPatrimonio USD seja avaliado
    # pela empresa toda, nao por cada conta isolada. Cada processo so le/escreve a sua
    # propria entrada - um cruzamento raro de escritas simultaneas de duas contas no mesmo
    # segundo, quando muito, atrasa a deteccao do objetivo por um ciclo, nunca perde dinheiro
    # real nem corrompe posicoes.
    $agentes = @()
    if (Test-Path ".\agentes-ativos.json") {
        try {
            $lido = Get-Content ".\agentes-ativos.json" -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($lido) { $agentes = @($lido) }
        } catch {
            $agentes = @()
        }
    }

    $entradaPropria = $agentes | Where-Object { $_.id -eq $AgenteID } | Select-Object -First 1
    if ($entradaPropria) {
        # Add-Member -Force em vez de atribuicao direta: uma entrada gravada antes desta
        # funcionalidade existir (ou por qualquer outro codigo mais antigo) pode nao ter
        # a propriedade "patrimonioAtual" - um PSCustomObject vindo de ConvertFrom-Json
        # rebenta com "propriedade nao encontrada" ao tentar atribuir a uma propriedade
        # que ainda nao existe. Add-Member funciona nos dois casos (existe ou nao).
        $entradaPropria | Add-Member -NotePropertyName "patrimonioAtual" -NotePropertyValue $patrimonioProprio -Force
    } else {
        $novaEntrada = @{
            id = $AgenteID
            capital = $SaldoInicial
            patrimonioAtual = $patrimonioProprio
            missao = $MissaoAtribuida
            criadoEm = Get-Date -Format "yyyy-MM-ddTHH:mm:ss"
            status = "ativo"
        }
        $agentes = @($agentes) + $novaEntrada
    }

    $agentes | ConvertTo-Json | Set-Content ".\agentes-ativos.json" -Encoding UTF8

    $somaPatrimonio = [decimal]0
    foreach ($a in $agentes) {
        if ($a.id -eq $AgenteID) {
            $somaPatrimonio += $patrimonioProprio
        } elseif ($null -ne $a.patrimonioAtual) {
            $somaPatrimonio += [decimal]$a.patrimonioAtual
        } elseif ($null -ne $a.capital) {
            $somaPatrimonio += [decimal]$a.capital
        }
    }
    return $somaPatrimonio
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

    # Ela desvia frequentemente de lingua a meio da resposta (portugues, espanhol, ingles),
    # e usa muitas palavras diferentes para dizer "nao fazer nada" (manter, mantener,
    # maintain, observe, watch, aguardar, ...) - impossivel cobrir todos os sinonimos
    # possiveis com uma lista. Por isso o DEFAULT e "hold" (seguro, nao gasta dinheiro),
    # e so classificamos como compra/venda quando reconhecemos explicitamente essa
    # intencao. Isto evita que uma palavra nao reconhecida (como aconteceu com "mantener"
    # e "maintain") seja interpretada por omissao como uma ordem de compra real.
    if ($a -match "vend|sair|fechar|close|sell") { return "venda" }
    if ($a -match "compra|comprar|buy|abrir|refor|reinforce|aumentar|adicionar|entrar|invest|^open$|purchase|acquire|^long$") { return "compra" }
    # Ela pode querer so mudar o stop loss/alvo de uma posicao que ja tem, sem reforcar
    # nem vender nada (ex: "setStopLoss", "ajustar") - a Binance real tambem permite
    # alterar uma ordem de stop loss/take profit sem mexer na posicao em si
    if ($a -match "ajust|atualiz|alterar|modificar|stoploss|takeprofit") { return "ajustar" }
    return "hold"
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

# Ajusta so o stopLoss/alvo de uma posicao que ja tem aberta, sem tocar na quantidade,
# no montante investido ou no preco de entrada - equivalente a alterar uma ordem de
# stop loss/take profit numa exchange real sem mexer na posicao em si.
function Ajusta-Risco-Posicao {
    param([array]$posicoes, [string]$par, [decimal]$precoAtual, $stopLoss, $alvo)

    $existente = $posicoes | Where-Object { $_.par -eq $par } | Select-Object -First 1
    if (-not $existente) { return @{ posicoes = $posicoes; ajustado = $false } }

    $stopLossInterpretado = Interpreta-Percentagem -valor $stopLoss -precoReferencia $precoAtual
    $alvoInterpretado = Interpreta-Percentagem -valor $alvo -precoReferencia $precoAtual

    # Mesma regra universal de sinal usada ao abrir posicao: stop loss e sempre baixa,
    # alvo e sempre subida, seja qual for o sinal com que ela escreveu o numero
    if ($null -ne $stopLossInterpretado) { $existente.stopLoss = -[Math]::Abs($stopLossInterpretado) }
    if ($null -ne $alvoInterpretado) { $existente.alvo = [Math]::Abs($alvoInterpretado) }

    return @{ posicoes = ,$posicoes; ajustado = $true; stopLoss = $existente.stopLoss; alvo = $existente.alvo }
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

    # So DETETA quais posicoes atingiram o stop loss/alvo - nao as fecha aqui. Fechar
    # de verdade pode envolver colocar uma ordem real na Binance, que pode falhar; quem
    # chama esta funcao e que decide como fechar cada uma e o que fazer se falhar.
    $aFechar = @()
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
            $aFechar += @{ posicao = $p; precoAtual = $precoAtual; motivo = $motivo }
        } else {
            $posicoesRestantes += $p
        }
    }

    return @{ posicoesRestantes = $posicoesRestantes; aFechar = $aFechar }
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

    # Com chaves da Binance Testnet configuradas, os precos, o saldo e as ordens sao
    # reais (dinheiro sempre falso, conta de testes da propria Binance) - sem chaves,
    # mantem-se o mercado simulado localmente como ate aqui
    $usaBinanceReal = Tem-BinanceConfigurado
    if ($usaBinanceReal -and -not $script:DiagnosticoBinanceMostrado) {
        # So uma vez por execucao - nunca regista a key/secret em si, so o comprimento,
        # para ajudar a diagnosticar um erro tipo "API-key format invalid" (normalmente
        # significa que a key nao foi gerada em testnet.binance.vision, ou tem espacos/
        # caracteres a mais) sem expor nada sensivel no log
        $keyDiag = Get-BinanceKey
        $secretDiag = Get-BinanceSecret
        Log "Binance Testnet configurada - key com $($keyDiag.Length) caracteres, secret com $($secretDiag.Length) caracteres" "INFO"
        $script:DiagnosticoBinanceMostrado = $true
    }
    if ($usaBinanceReal) {
        $dadosBinance = Get-BinanceDadosMercado
        if ($dadosBinance) {
            $precosAtuais = $dadosBinance.precos
            $variacoes = $dadosBinance.variacoes
            $volumesReais = $dadosBinance.volumes
        } else {
            Log "AVISO: Sem dados reais da Binance Testnet neste ciclo, a usar mercado simulado como reserva" "AVISO"
            $mercadoAvancado = Avanca-Mercado
            $precosAtuais = $mercadoAvancado.precos
            $variacoes = $mercadoAvancado.variacoes
            $volumesReais = $null
            $usaBinanceReal = $false
        }
    } else {
        $mercadoAvancado = Avanca-Mercado
        $precosAtuais = $mercadoAvancado.precos
        $variacoes = $mercadoAvancado.variacoes
        $volumesReais = $null
    }

    if ($usaBinanceReal -and -not $script:SaldoRealConfirmado) {
        # NAO sincroniza o saldo dela com o saldo TOTAL da conta testnet - contas
        # testnet vem com um saldo inicial de fabrica (ex: 10000 USDT) que nada tem a
        # ver com o capital que lhe foi dado para gerir. O saldo dela continua a ser
        # o mesmo contador local de sempre (comeca em $SaldoInicial), so que agora as
        # compras/vendas que decide sao executadas como ordens reais na Binance Testnet,
        # dentro desse limite - o resto do dinheiro da conta fica de fora, intocado.
        # So confirma aqui, uma vez, que a conta tem fundos suficientes para cobrir o
        # capital atribuido, para nao passar o resto da execucao as cegas.
        $saldoReal = Get-BinanceSaldoReal
        if ($null -ne $saldoReal) {
            Log "Conta Binance Testnet confirmada com $saldoReal USDT disponiveis (capital atribuido a ela: $($estado.saldoInicial) EUR, o resto fica reservado e nunca e usado)" "INFO"
            if ($saldoReal -lt $estado.saldoInicial) {
                Log "AVISO: A conta testnet tem menos fundos ($saldoReal USDT) do que o capital atribuido ($($estado.saldoInicial) EUR) - as ordens reais podem falhar por saldo insuficiente" "AVISO"
            }
        } else {
            Log "AVISO: Nao foi possivel confirmar o saldo da conta Binance Testnet" "AVISO"
        }
        $script:SaldoRealConfirmado = $true
    }

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

    # O objetivo e da empresa toda (esta conta + todas as que ela ou outras tenham criado),
    # nao so do dinheiro desta conta isolada - ver Sincroniza-PatrimonioEmpresa.
    $patrimonioEmpresa = Sincroniza-PatrimonioEmpresa -patrimonioProprio $patrimonio

    if ($patrimonioEmpresa -ge $ObjetivoPatrimonio) {
        Log "OBJETIVO ATINGIDO PELA EMPRESA! Patrimonio somado de todas as contas: $patrimonioEmpresa EUR (o teu: $patrimonio EUR)" "SUCESSO"
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
    $posicoesFinal = @($verificacao.posicoesRestantes)
    $fechosAutomaticos = @()
    foreach ($item in $verificacao.aFechar) {
        $p = $item.posicao
        $valorAtual = $null

        if ($usaBinanceReal -and $PARES_BINANCE.Contains($p.par)) {
            $simbolo = $PARES_BINANCE[$p.par]
            $filtros = Get-BinanceFiltros -simbolo $simbolo
            $quantidadeVenda = Arredonda-QuantidadeBinance -quantidade $p.quantidade -stepSize $filtros.stepSize
            if ($quantidadeVenda -gt 0) {
                $ordem = Coloca-OrdemBinance -simbolo $simbolo -lado "SELL" -quantidade $quantidadeVenda
                if ($ordem.sucesso) { $valorAtual = $ordem.valorTotal }
            }
            if ($null -eq $valorAtual) {
                # A ordem real falhou (ou a quantidade era pequena demais para o lote
                # minimo) - mantem a posicao aberta em vez de a dar como fechada sem
                # ter mesmo vendido nada, e tenta outra vez no proximo ciclo
                Log "AVISO: Fecho automatico de $($p.par) ($($item.motivo)) nao conseguiu executar ordem real - posicao mantida aberta, tenta de novo no proximo ciclo" "AVISO"
                $posicoesFinal += $p
                continue
            }
        } else {
            $valorAtual = $p.quantidade * $item.precoAtual
        }

        $ganho = $valorAtual - $p.montanteInvestido
        $estado.saldo += $valorAtual
        $tradeAuto = @{
            acao = "venda (automatica)"
            par = $p.par
            montante = $p.montanteInvestido
            resultado = if ($p.montanteInvestido -gt 0) { [Math]::Round(($ganho / $p.montanteInvestido) * 100, 2) } else { 0 }
            ganho = $ganho
            estrategia = $item.motivo
            raciocinio = "Fechado automaticamente: $($item.motivo)"
            timestamp = Get-Date -Format "yyyy-MM-ddTHH:mm:ss"
        }
        $estado.trades += $tradeAuto
        $fechosAutomaticos += $tradeAuto
        Log "AUTO: Posicao $($p.par) fechada automaticamente - $($item.motivo) - Ganho: $ganho EUR" "TRADE"
    }
    $estado.posicoes = $posicoesFinal

    $estado.precoHistorico = Atualiza-PrecoHistorico -precoHistorico $estado.precoHistorico -precosAtuais $precosAtuais
    $dadosMercado = Get-MercadoData -precos $precosAtuais -variacoes $variacoes -volumes $volumesReais -precoHistorico $estado.precoHistorico

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
        ciclosHistorico = $estado.ciclosHistorico
        posicoes = $posicoesContexto
        ultimaPesquisa = $estado.ultimaPesquisa
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

    # Pesquisa na internet so quando ela propria pede - o resultado fica guardado para
    # lhe aparecer no proximo ciclo (o Ollama nao suporta pesquisar a meio de uma resposta)
    if ($deciso.pesquisar) {
        Log "Ela pediu para pesquisar na internet: $($deciso.pesquisar)" "INFO"
        $resultadoPesquisa = Pesquisa-Internet -query $deciso.pesquisar
        if ($resultadoPesquisa) {
            $estado.ultimaPesquisa = @{
                query = $deciso.pesquisar
                resultados = $resultadoPesquisa
                timestamp = Get-Date -Format "yyyy-MM-ddTHH:mm:ss"
            }
            Log "Resultado da pesquisa: $resultadoPesquisa" "INFO"
        }
    }

    $novasAgentes = if ($deciso.criarAgentes) { $deciso.criarAgentes } else { 0 }
    if ($novasAgentes -gt 0) {
        Log "CEO CRIANDO $novasAgentes NOVOS AGENTES!" "DECISAO"
        for ($i = 1; $i -le $novasAgentes; $i++) {
            $proximoID = $numAgentes + $i
            if ($estado.saldo -ge 20) {
                Cria-NovoAgente -numeroAgente $proximoID -capital 20 -missao $deciso.missaoNovoAgente
                $estado.saldo -= 20
                Log "Novo agente criado. Saldo restante: $($estado.saldo) EUR" "INFO"
            } else {
                Log "AVISO: Quis criar um novo agente mas so ha $($estado.saldo) EUR na conta (minimo: 20 EUR). Sem novo agente." "AVISO"
            }
        }
    }

    $tipoAcao = Classifica-Acao -acao $deciso.acao
    $trade = $null

    if ($tipoAcao -eq "compra" -and $ciclo -le $ciclosAprendizagem) {
        # So atrasa a execucao real - a decisao dela (raciocinio, acao escolhida) fica
        # registada na memoria dela normalmente, exatamente como se tivesse decidido
        # comprar mas nao tivesse fundos: ela continua a pensar e a decidir sozinha,
        # so nao arrisca dinheiro real nestes primeiros ciclos de observacao do mercado
        Log "AVISO: Ainda em periodo de observacao (ciclo $ciclo de $ciclosAprendizagem) - decisao de comprar/reforcar registada, mas sem trade real ainda." "AVISO"
    } elseif ($tipoAcao -eq "compra" -and -not $deciso.par) {
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
            if ($montante -gt 0 -and $usaBinanceReal -and $PARES_BINANCE.Contains($parResolvido)) {
                $simbolo = $PARES_BINANCE[$parResolvido]
                $filtros = Get-BinanceFiltros -simbolo $simbolo
                $quantidadePedida = Arredonda-QuantidadeBinance -quantidade ($montante / $precoAtualPar) -stepSize $filtros.stepSize
                if ($quantidadePedida -le 0 -or ($quantidadePedida * $precoAtualPar) -lt $filtros.minNotional) {
                    Log "AVISO: Montante de $montante EUR e demasiado pequeno para uma ordem valida em $parResolvido (minimo da Binance: ~$($filtros.minNotional) USD). Sem trade." "AVISO"
                } else {
                    $ordem = Coloca-OrdemBinance -simbolo $simbolo -lado "BUY" -quantidade $quantidadePedida
                    if ($ordem.sucesso) {
                        $estado.posicoes = Abre-OuAdiciona-Posicao -posicoes $estado.posicoes -par $parResolvido -montante $ordem.valorTotal -precoAtual $ordem.precoMedio -stopLoss $deciso.stopLoss -alvo $deciso.alvo
                        $estado.saldo -= $ordem.valorTotal
                        Log "POSICAO (Binance Testnet real): Investidos $($ordem.valorTotal) EUR em $parResolvido a `$$($ordem.precoMedio) (ordem #$($ordem.ordemId))" "TRADE"
                    }
                }
            } elseif ($montante -gt 0) {
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
        $posicaoExistente = if ($parResolvido) { $estado.posicoes | Where-Object { $_.par -eq $parResolvido } | Select-Object -First 1 } else { $null }
        if (-not $precoAtualPar) {
            Log "AVISO: Par '$($deciso.par)' desconhecido no mercado. Sem trade." "AVISO"
        } elseif ($usaBinanceReal -and $posicaoExistente -and $PARES_BINANCE.Contains($parResolvido)) {
            $simbolo = $PARES_BINANCE[$parResolvido]
            $filtros = Get-BinanceFiltros -simbolo $simbolo
            $quantidadeVenda = Arredonda-QuantidadeBinance -quantidade $posicaoExistente.quantidade -stepSize $filtros.stepSize
            if ($quantidadeVenda -le 0) {
                Log "AVISO: Quantidade de $parResolvido demasiado pequena para uma ordem de venda valida na Binance. Sem trade." "AVISO"
            } else {
                $ordem = Coloca-OrdemBinance -simbolo $simbolo -lado "SELL" -quantidade $quantidadeVenda
                if ($ordem.sucesso) {
                    $ganho = $ordem.valorTotal - $posicaoExistente.montanteInvestido
                    $estado.posicoes = @($estado.posicoes | Where-Object { $_.par -ne $parResolvido })
                    $estado.saldo += $ordem.valorTotal
                    $trade = @{
                        acao = "venda"
                        par = $parResolvido
                        montante = $posicaoExistente.montanteInvestido
                        resultado = if ($posicaoExistente.montanteInvestido -gt 0) { [Math]::Round(($ganho / $posicaoExistente.montanteInvestido) * 100, 2) } else { 0 }
                        ganho = $ganho
                        estrategia = $deciso.estrategia
                        raciocinio = $deciso.raciocinio
                        timestamp = Get-Date -Format "yyyy-MM-ddTHH:mm:ss"
                    }
                    Log "TRADE (Binance Testnet real): Vendeu $parResolvido | Recebido: $($ordem.valorTotal) EUR | Ganho: $ganho EUR (ordem #$($ordem.ordemId))" "TRADE"
                }
            }
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
    } elseif ($tipoAcao -eq "ajustar" -and -not $deciso.par) {
        Log "AVISO: Quis ajustar stopLoss/alvo mas nao especificou um par." "AVISO"
    } elseif ($tipoAcao -eq "ajustar") {
        $parResolvido = Resolve-Par -par $deciso.par -precosAtuais $precosAtuais
        $precoAtualPar = if ($parResolvido) { $precosAtuais[$parResolvido] } else { $null }
        if (-not $precoAtualPar) {
            Log "AVISO: Par '$($deciso.par)' desconhecido no mercado. Sem ajuste." "AVISO"
        } else {
            $ajuste = Ajusta-Risco-Posicao -posicoes $estado.posicoes -par $parResolvido -precoAtual $precoAtualPar -stopLoss $deciso.stopLoss -alvo $deciso.alvo
            if ($ajuste.ajustado) {
                $estado.posicoes = $ajuste.posicoes
                Log "AJUSTE: $parResolvido - novo stopLoss: $($ajuste.stopLoss)% | novo alvo: $($ajuste.alvo)%" "TRADE"
            } else {
                Log "AVISO: Pediu para ajustar $($deciso.par) mas nao tem posicao aberta nesse par." "AVISO"
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

    if ($patrimonioApos -ge $ObjetivoPatrimonio) {
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

    # Traduz so a copia enviada para o Telegram - o raciocinio guardado em $deciso e no
    # historico dela fica sempre exatamente como ela escreveu, sem qualquer alteracao.
    # Quando nao ha texto real (so o placeholder), pular a traducao: dar a um modelo
    # pequeno uma frase quase vazia para "traduzir" e o que mais o leva a divagar e
    # inventar conteudo completamente aleatorio (ja aconteceu: perguntas sobre a
    # capital de Franca) - e o placeholder ja esta em portugues, nao precisa traduzir.
    $raciocinioTelegram = if ($deciso.raciocinio -eq "(sem texto de raciocinio nesta resposta)") {
        $deciso.raciocinio
    } else {
        Traduz-Para-Portugues $deciso.raciocinio
    }

    $resumoTelegram = "Ciclo #$ciclo - Patrimonio: $patrimonioApos EUR (cash: $($estado.saldo) EUR)`n`n" + `
        "Pensamento:`n$raciocinioTelegram`n`n" + `
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
