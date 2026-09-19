# ============================================================================
# SERVIDOR HTTP LOCAL PARA O DASHBOARD
# ============================================================================
# Resolve o problema de CORS ao abrir dashboard.html diretamente via file://
# O navegador bloqueia fetch() entre arquivos locais, mas nao entre http://
#
# Tambem escuta em todas as interfaces de rede (nao so localhost), para poderes
# abrir o dashboard/conversa a partir do telemovel, desde que este esteja na
# MESMA rede WiFi que este PC.

param(
    [int]$Porta = 8080
)

$pastaAtual = $PSScriptRoot
if (-not $pastaAtual) { $pastaAtual = Get-Location }

Add-Type -AssemblyName System.Net.HttpListener -ErrorAction SilentlyContinue

$listener = New-Object System.Net.HttpListener
$escutaRede = $false

try {
    # "+" escuta em todas as interfaces de rede (necessario para aceder pelo telemovel).
    # No Windows isto normalmente exige privilegios de administrador ou uma reserva de
    # URL previa - se falhar, cai para localhost-only (so funciona neste PC).
    $listener.Prefixes.Clear()
    $listener.Prefixes.Add("http://+:$Porta/")
    $listener.Start()
    $escutaRede = $true
} catch {
    Write-Host "AVISO: Nao foi possivel escutar em todas as interfaces (precisa de admin)." -ForegroundColor Yellow
    Write-Host "A cair para modo localhost-only (so funciona neste PC, nao no telemovel)." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Para funcionar tambem no telemovel, escolhe UMA destas opcoes:" -ForegroundColor Cyan
    Write-Host "  1) Corre este script numa PowerShell como Administrador; OU" -ForegroundColor Cyan
    Write-Host "  2) Numa PowerShell como Administrador (uma unica vez), corre:" -ForegroundColor Cyan
    Write-Host "     netsh http add urlacl url=http://+:$Porta/ user=Everyone" -ForegroundColor White
    Write-Host ""

    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add("http://localhost:$Porta/")
    try {
        $listener.Start()
    } catch {
        Write-Host "ERRO: Nao foi possivel iniciar nem em modo localhost na porta $Porta. Tenta outra porta com -Porta 8081" -ForegroundColor Red
        exit 1
    }
}

Write-Host "Servidor iniciado na porta $Porta" -ForegroundColor Green
Write-Host "Dashboard (neste PC): http://localhost:$Porta/dashboard.html" -ForegroundColor Cyan
Write-Host "Conversa (neste PC):  http://localhost:$Porta/conversa.html" -ForegroundColor Cyan

if ($escutaRede) {
    $ips = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.254.*" } |
        Select-Object -ExpandProperty IPAddress

    if ($ips) {
        Write-Host ""
        Write-Host "No TELEMOVEL (mesma rede WiFi), abre um destes enderecos:" -ForegroundColor Green
        foreach ($ip in $ips) {
            Write-Host "  http://${ip}:$Porta/conversa.html" -ForegroundColor White
        }
    } else {
        Write-Host "AVISO: Nao foi possivel detetar o IP local automaticamente. Corre 'ipconfig' e usa o endereco IPv4." -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "Pressione Ctrl+C para parar o servidor" -ForegroundColor Yellow

Start-Process "http://localhost:$Porta/dashboard.html"

$mimeTypes = @{
    ".html" = "text/html; charset=utf-8"
    ".json" = "application/json; charset=utf-8"
    ".js"   = "application/javascript; charset=utf-8"
    ".css"  = "text/css; charset=utf-8"
}

while ($listener.IsListening) {
    try {
        $context = $listener.GetContext()
        $request = $context.Request
        $response = $context.Response

        $caminhoRelativo = $request.Url.LocalPath.TrimStart('/')
        if ([string]::IsNullOrWhiteSpace($caminhoRelativo)) { $caminhoRelativo = "dashboard.html" }

        $caminhoCompleto = Join-Path $pastaAtual $caminhoRelativo

        if (Test-Path $caminhoCompleto -PathType Leaf) {
            $extensao = [System.IO.Path]::GetExtension($caminhoCompleto)
            $tipoConteudo = if ($mimeTypes.ContainsKey($extensao)) { $mimeTypes[$extensao] } else { "application/octet-stream" }

            $bytes = [System.IO.File]::ReadAllBytes($caminhoCompleto)
            $response.ContentType = $tipoConteudo
            $response.ContentLength64 = $bytes.Length
            $response.Headers.Add("Cache-Control", "no-cache, no-store, must-revalidate")
            $response.OutputStream.Write($bytes, 0, $bytes.Length)
        } else {
            $response.StatusCode = 404
            $mensagem404 = [System.Text.Encoding]::UTF8.GetBytes("404 - Arquivo nao encontrado: $caminhoRelativo")
            $response.OutputStream.Write($mensagem404, 0, $mensagem404.Length)
        }

        $response.OutputStream.Close()
    } catch {
        Write-Host "Erro ao processar pedido: $_" -ForegroundColor Red
    }
}
