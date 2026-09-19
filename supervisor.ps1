# ============================================================================
# SUPERVISOR - Reinicia o agente automaticamente se o processo morrer
# ============================================================================
# O agente corre indefinidamente por design, mas processos externos (Ollama a
# escrever sequencias de controlo de terminal, por exemplo) podem em casos raros
# derrubar todo o processo PowerShell sem passar pelo try/catch do proprio script.
# Este supervisor garante que isso nunca para o sistema de vez: se o processo
# do agente morrer por qualquer razao, e sem excecao "ERRO NAO APANHADO" no log,
# reinicia-o automaticamente ao fim de alguns segundos.

param(
    [string]$AgenteID = "Agente_1",
    [decimal]$SaldoInicial = 20,
    [string]$ConfigPath = ".\config-testnet.json"
)

Write-Host "===== SUPERVISOR iniciado para $AgenteID =====" -ForegroundColor Cyan
Write-Host "Reinicia automaticamente o agente se o processo morrer inesperadamente."
Write-Host "Pressiona Ctrl+C para parar o supervisor (e o agente)."

while ($true) {
    $inicio = Get-Date
    Write-Host "`n[$( Get-Date -Format 'HH:mm:ss')] A iniciar/reiniciar $AgenteID..." -ForegroundColor Yellow

    $codigoSaida = $null
    try {
        # Um erro fatal nao apanhado dentro do script invocado tambem mataria este
        # supervisor, a menos que a chamada esteja protegida aqui - e exatamente o
        # tipo de crash que este supervisor existe para sobreviver
        & ".\agente-template.ps1" -AgenteID $AgenteID -SaldoInicial $SaldoInicial -ConfigPath $ConfigPath
        $codigoSaida = $LASTEXITCODE
    } catch {
        Write-Host "SUPERVISOR: o agente crashou com um erro fatal: $_" -ForegroundColor Red
    }

    $duracao = (Get-Date) - $inicio
    Write-Host "`n[$( Get-Date -Format 'HH:mm:ss')] Processo do agente terminou (esteve a correr $([Math]::Round($duracao.TotalSeconds))s, codigo de saida: $codigoSaida)." -ForegroundColor Red

    if ($codigoSaida -eq 1) {
        # exit 1 e o GAME OVER deliberado do proprio script - e uma consequencia real,
        # nao um crash. O supervisor NAO reinicia automaticamente sobre isto: isso
        # mascararia a consequencia. Fica a espera de reinicio manual (limpar o
        # estado e voltar a correr), tal como sempre foi.
        Write-Host "GAME OVER - o agente morreu (saldo abaixo de 20 EUR). O supervisor NAO reinicia automaticamente." -ForegroundColor Red
        Write-Host "Para tentar de novo do zero, apaga o estado-$AgenteID.json e corre o supervisor outra vez." -ForegroundColor Yellow
        break
    }

    if ($duracao.TotalSeconds -lt 10) {
        Write-Host "AVISO: o agente morreu quase de imediato (nao foi GAME OVER). A esperar 30s antes de tentar de novo, para nao entrar em loop descontrolado." -ForegroundColor Red
        Start-Sleep -Seconds 30
    } else {
        Write-Host "Nao foi um GAME OVER (provavelmente um crash inesperado). A reiniciar em 5 segundos, retomando o estado guardado..." -ForegroundColor Yellow
        Start-Sleep -Seconds 5
    }
}
