# ============================================================================
# TESTE DIAGNOSTICO - Verifica Ollama e Parse JSON
# ============================================================================
# Rode este script para diagnosticar problemas

Write-Host "=========================================================="
Write-Host "TESTE DIAGNOSTICO - Ollama + JSON Parse"
Write-Host "=========================================================="
Write-Host ""

# 1. Verifica se Ollama esta rodando
Write-Host "1. Verificando Ollama..." -ForegroundColor Cyan
try {
    $ollamaList = & ollama list 2>&1
    Write-Host "   OK - Ollama disponivel" -ForegroundColor Green
    Write-Host "   Modelos: $ollamaList" -ForegroundColor Gray
} catch {
    Write-Host "   ERRO - Ollama nao encontrado!" -ForegroundColor Red
    Write-Host "   Inicia com: ollama serve" -ForegroundColor Yellow
    exit 1
}

Write-Host ""
Write-Host "2. Testando Mistral com prompt simples..." -ForegroundColor Cyan

$prompt = @"
Responde exatamente neste JSON (sem explicacao extra):
{
  "teste": "ok",
  "numero": 42,
  "booleano": true
}
"@

Write-Host "   Prompt:" -ForegroundColor Gray
Write-Host $prompt -ForegroundColor Gray
Write-Host ""

try {
    Write-Host "   Chamando ollama run mistral..." -ForegroundColor Yellow
    $output = & ollama run mistral $prompt 2>&1

    Write-Host "   Resposta completa:" -ForegroundColor Gray
    Write-Host $output -ForegroundColor Gray
    Write-Host ""

    # Tenta extrair JSON
    Write-Host "3. Tentando extrair JSON..." -ForegroundColor Cyan
    $outputText = $output -join "`n"

    if ($outputText -match '\{[\s\S]*?"teste"[\s\S]*?\}') {
        $jsonMatch = $matches[0]
        Write-Host "   JSON encontrado:" -ForegroundColor Green
        Write-Host $jsonMatch -ForegroundColor Gray

        # Limpa
        $jsonText = $jsonMatch -replace "`r`n", " " -replace "`n", " "
        Write-Host "   JSON limpo:" -ForegroundColor Green
        Write-Host $jsonText -ForegroundColor Gray

        # Tenta parse
        try {
            $obj = $jsonText | ConvertFrom-Json
            Write-Host "   SUCESSO! JSON parseado:" -ForegroundColor Green
            Write-Host "     teste=$($obj.teste)" -ForegroundColor Green
            Write-Host "     numero=$($obj.numero)" -ForegroundColor Green
        } catch {
            Write-Host "   ERRO ao fazer parse: $_" -ForegroundColor Red
        }
    } else {
        Write-Host "   AVISO - JSON nao encontrado no regex!" -ForegroundColor Yellow
        Write-Host "   Output foi:" -ForegroundColor Gray
        Write-Host $outputText -ForegroundColor Gray
    }

} catch {
    Write-Host "   ERRO ao chamar Ollama: $_" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "=========================================================="
Write-Host "Diagnostico completo!" -ForegroundColor Green
Write-Host "=========================================================="
Write-Host ""
Write-Host "Se Ollama esta OK e o JSON foi parseado:"
Write-Host "  -> Execute: .\INICIAR-TESTNET.ps1"
Write-Host ""
Write-Host "Se houve erro:"
Write-Host "  -> Verifica os logs em: .\logs\"
Write-Host "  -> Comeca Ollama: ollama serve"
Write-Host ""
