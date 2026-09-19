# ============================================================================
# SERVIDOR HTTP LOCAL PARA O DASHBOARD
# ============================================================================
# Resolve o problema de CORS ao abrir dashboard.html diretamente via file://
# O navegador bloqueia fetch() entre arquivos locais, mas nao entre http://

param(
    [int]$Porta = 8080
)

$pastaAtual = $PSScriptRoot
if (-not $pastaAtual) { $pastaAtual = Get-Location }

Add-Type -AssemblyName System.Net.HttpListener -ErrorAction SilentlyContinue

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$Porta/")

try {
    $listener.Start()
} catch {
    Write-Host "ERRO: Nao foi possivel iniciar na porta $Porta. Tente outra porta com -Porta 8081" -ForegroundColor Red
    exit 1
}

Write-Host "Servidor iniciado em http://localhost:$Porta/" -ForegroundColor Green
Write-Host "Dashboard: http://localhost:$Porta/dashboard.html" -ForegroundColor Cyan
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
