# ============================================================================
# TESTE SIMPLES DO AGENTE - Apenas 1 ciclo para debug
# ============================================================================

param(
    [string]$ConfigPath = ".\config-testnet.json"
)

Write-Host "=========================================================="
Write-Host "TESTE AGENTE SIMPLES - 1 Ciclo"
Write-Host "=========================================================="
Write-Host ""

# Carrega config
if (-not (Test-Path $ConfigPath)) {
    Write-Host "ERRO: $ConfigPath nao encontrado!" -ForegroundColor Red
    exit 1
}

$config = Get-Content $ConfigPath | ConvertFrom-Json
Write-Host "Config carregado: ambiente=$($config.ambiente)" -ForegroundColor Green

# Estado inicial
$estado = @{
    id = "TESTE"
    saldo = 20.00
    trades = @()
    winRate = 0
}

# Log simples
function Log {
    param([string]$msg, [string]$tipo = "INFO")
    $ts = Get-Date -Format "HH:mm:ss"
    Write-Host "[$ts] [$tipo] $msg"
}

# Obtem dados de mercado (testnet)
function Get-MercadoData {
    $pares = @(
        @{ par = "BTC/USDT"; preco = 43250; mudanca24h = 2.5; volume = 1500000000 },
        @{ par = "ETH/USDT"; preco = 2280; mudanca24h = 1.8; volume = 900000000 },
        @{ par = "SOL/USDT"; preco = 185; mudanca24h = -1.2; volume = 450000000 },
        @{ par = "XRP/USDT"; preco = 2.45; mudanca24h = 0.5; volume = 300000000 },
        @{ par = "ADA/USDT"; preco = 1.15; mudanca24h = 3.2; volume = 250000000 }
    )
    return $pares | Get-Random -Count (Get-Random -Minimum 2 -Maximum 5)
}

# IA call
function Chama-IA {
    param([hashtable]$contexto)

    $prompt = @"
=== TESTE SIMPLES ===
Tu tens:
- Saldo: $($contexto.saldo) EUR
- Meta: 100 EUR
- Limite: nao podes perder abaixo de 20 EUR

Mercado:
$($contexto.mercado | ForEach-Object { "- $($_.par): `$$($_.preco) (mudanca: $($_.mudanca24h)%)" } | Out-String)

Responde EXATAMENTE neste JSON (e nada mais):
{
  "acao": "compra",
  "par": "BTC/USDT",
  "montante": 5.0,
  "stopLoss": 10,
  "alvo": 20,
  "risco": "baixo",
  "confianca": 0.7,
  "criarAgentes": 0
}
"@

    Log "Enviando prompt para Mistral..." "IA"
    Log $prompt "DEBUG"

    try {
        $output = & ollama run mistral $prompt 2>&1

        if ($output) {
            Log "Resposta recebida (raw):" "DEBUG"
            Log ($output | Out-String) "DEBUG"

            $outputText = $output -join "`n"

            # Tenta extrair JSON
            if ($outputText -match '\{[\s\S]*?"acao"[\s\S]*?\}') {
                $jsonText = $matches[0]
                $jsonText = $jsonText -replace "`r`n", " " -replace "`n", " "

                Log "JSON extraido: $jsonText" "DEBUG"

                try {
                    $obj = $jsonText | ConvertFrom-Json
                    $deciso = @{
                        acao = $obj.acao
                        par = $obj.par
                        montante = $obj.montante
                        stopLoss = $obj.stopLoss
                        alvo = $obj.alvo
                        risco = $obj.risco
                        confianca = $obj.confianca
                        criarAgentes = if ($obj.criarAgentes) { $obj.criarAgentes } else { 0 }
                    }

                    Log "SUCESSO! Decisao: Acao=$($deciso.acao), Par=$($deciso.par), Confianca=$($deciso.confianca)" "IA"
                    return $deciso
                } catch {
                    Log "Erro parse JSON: $_" "ERRO"
                }
            } else {
                Log "AVISO: JSON nao encontrado no regex!" "AVISO"
            }
        }

        Log "Fallback: Hold defensivo" "AVISO"
        return @{ acao = "hold"; risco = "baixo"; confianca = 0.3 }

    } catch {
        Log "ERRO ao chamar Ollama: $_" "ERRO"
        return @{ acao = "hold"; risco = "baixo"; confianca = 0 }
    }
}

# Main test
Write-Host ""
Log "Iniciando teste..." "INIT"
Log "Saldo inicial: $($estado.saldo) EUR" "INFO"

Write-Host ""
$dadosMercado = Get-MercadoData
Log "Mercado analisado: $($dadosMercado.Count) pares" "INFO"

Write-Host ""
$contexto = @{
    saldo = $estado.saldo
    nTrades = $estado.trades.Count
    winRate = $estado.winRate
    mercado = $dadosMercado
    numAgentes = 0
}

Write-Host ""
Write-Host "Chamando IA..." -ForegroundColor Cyan
Write-Host ""

$deciso = Chama-IA -contexto $contexto

Write-Host ""
Log "Decisao completa:" "RESULTADO"
$deciso | Format-Table | Out-String | ForEach-Object { Log $_ "RESULTADO" }

Write-Host ""
Write-Host "=========================================================="
Write-Host "Teste concluido!" -ForegroundColor Green
Write-Host "=========================================================="
Write-Host ""
Write-Host "Se viste a acao corretamente parseada:"
Write-Host "  -> IA esta funcionando!"
Write-Host "  -> JSON parse esta OK!"
Write-Host ""
Write-Host "Agora podes correr: .\INICIAR-TESTNET.ps1" -ForegroundColor Green
Write-Host ""
