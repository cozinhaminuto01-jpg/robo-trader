# 🔍 Diagnóstico - Sistema Parou? Segue Estes Passos

O sistema mostrou logs até Ciclo 8 e parou? Aqui está COMO ENCONTRAR O PROBLEMA.

## ✅ PASSO 1: Atualiza o Código do GitHub

Abre PowerShell na pasta do projeto e executa:

```powershell
git pull origin claude/pensive-galileo-4oyhwb
```

**Importante:** Isto vai trazer todas as correções que foram feitas.

Após o pull, verifica que os ficheiros foram atualizados:
```powershell
git log --oneline -5
```

## 🧪 PASSO 2: Testa Ollama (5 minutos)

Antes de correr o sistema completo, verifica se Ollama funciona sozinho:

```powershell
.\TESTE-OLLAMA.ps1
```

Este script:
- ✅ Verifica se Ollama está rodando
- ✅ Envia um prompt simples para Mistral
- ✅ Tenta fazer parse do JSON
- ✅ Mostra claramente se há erro

**O que esperar:**
```
OK - Ollama disponivel
Modelos: mistral:latest
...
SUCESSO! JSON parseado:
  teste=ok
  numero=42
```

**Se falhar:**
- Abre outro terminal
- Executa: `ollama serve`
- Volta e tenta o teste novamente

## 🤖 PASSO 3: Testa o Agente (5 minutos)

Se Ollama passou, testa se o agente consegue tomar 1 decisão:

```powershell
.\TESTE-AGENTE-SIMPLES.ps1
```

Este script:
- ✅ Carrega a config
- ✅ Cria dados de mercado fictícios  
- ✅ Chama a IA
- ✅ Mostra a decisão completa

**O que esperar:**
```
[HH:mm:ss] [IA] SUCESSO! Decisao: Acao=compra, Par=BTC/USDT, Confianca=0.7
```

**Se falhar:**
- Nota o erro mostrado
- Verifica que a config-testnet.json existe

## 🚀 PASSO 4: Corre o Sistema Completo

Se os testes 2 e 3 passaram, agora sim:

```powershell
.\INICIAR-TESTNET.ps1
```

O sistema vai iniciar e mostrar logs em tempo real.

## 📊 PASSO 5: Abre o Dashboard

Enquanto o sistema roda, em OUTRO PowerShell:

```powershell
start .\dashboard-premium.html
```

Abre no browser e vê o agente a trabalhar em tempo real.

---

## 🆘 O Sistema Ainda Parou?

Se seguiste TODOS os passos acima e ainda assim parou, faz o seguinte:

### 1. Verifica o Último Log

```powershell
Get-ChildItem .\logs -Filter "*.log" | Sort-Object LastWriteTime -Descending | Select-Object -First 1 | ForEach-Object { Get-Content $_.FullName -Tail 50 }
```

Isto mostra as últimas 50 linhas do ficheiro de log.

**Procura por:**
- `[ERRO]` ou `[RESULTADO]` com "GAME OVER" → Saldo caiu abaixo de 20 EUR
- `[IA]` com JSON inválido → Problema no parse
- Nada por vários minutos → Sistema travado/dormindo

### 2. Verifica o Estado do Agente

```powershell
Get-Content .\estado-Agente_1.json | ConvertFrom-Json | Format-Table -AutoSize
```

Isto mostra:
- `saldo` → Deve ser >= 20 EUR (senão game over)
- `trades` → Quantas transações foram feitas
- `winRate` → Percentagem de ganhos

### 3. Se o Saldo é < 20 EUR

O agente MORREU (game over). É normal em testnet. Podes:
- Deletar `estado-Agente_1.json` para reiniciar com 20 EUR
- Ou correr: `rm .\estado-Agente_1.json` antes de `.\INICIAR-TESTNET.ps1`

### 4. Se o Saldo é >= 100 EUR

O agente está A DESCANSAR 24 HORAS! Não parou. Está tudo OK.
- O log mostra: `Agente entra em repouso por 24 horas...`
- Volta a ciclos depois

---

## 💡 Dicas de Debug

**Ver logs em tempo real enquanto corre:**
```powershell
Get-Content .\logs\Agente_1-*.log -Tail 20 -Wait
```

**Contar quantos ciclos completou:**
```powershell
(Get-Content .\logs\Agente_1-*.log | Select-String "===== Ciclo").Count
```

**Ver apenas ERROS no log:**
```powershell
Get-Content .\logs\Agente_1-*.log | Select-String "\[ERRO\]"
```

**Ver apenas trades (decisões da IA):**
```powershell
Get-Content .\logs\Agente_1-*.log | Select-String "\[TRADE\]"
```

---

## 📋 Checklist Final

Antes de dizer "parou", verifica:

- [ ] `git pull origin claude/pensive-galileo-4oyhwb` foi executado?
- [ ] `.\TESTE-OLLAMA.ps1` passou com SUCESSO?
- [ ] `.\TESTE-AGENTE-SIMPLES.ps1` passou com SUCESSO?
- [ ] O ficheiro `estado-Agente_1.json` tem `saldo >= 20` EUR?
- [ ] Se saldo >= 100, o agente está a descansar (normal, aguarda 24h)?
- [ ] `.\logs\` tem ficheiros `.log` recentes (últimos 1-2 minutos)?

**Se todos passaram:** Sistema está FUNCIONANDO! 🎉

---

## 🚨 Última Resort - Reset Completo

Se nada funciona:

```powershell
# Para todos os jobs em background
Stop-Job -State Running

# Remove estado anterior
rm .\estado-*.json -Force
rm .\logs\*.log -Force

# Limpa agents anteriores
rm .\agente-*.ps1 -Force
rm .\agentes-ativos.json -Force

# Puxa código limpo
git fetch origin
git reset --hard origin/claude/pensive-galileo-4oyhwb

# Tenta novamente
.\TESTE-OLLAMA.ps1
.\TESTE-AGENTE-SIMPLES.ps1
.\INICIAR-TESTNET.ps1
```

---

**Precisa de ajuda? Envia:**
1. Saída completa do `.\TESTE-OLLAMA.ps1`
2. Saída completa do `.\TESTE-AGENTE-SIMPLES.ps1`
3. Últimas 50 linhas de `.\logs\Agente_1-*.log`
4. Conteúdo de `.\estado-Agente_1.json`

Pronto! Agora sim conseguimos diagnosticar. 🚀
