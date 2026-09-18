# 🤖 Teste de Autonomia — Sistema Multi-Agente de Trading

## O Que É?

Um **sistema de trading autónomo** onde:
- ✅ IA (Claude Haiku) decide **onde** investir
- ✅ IA decide **como** (estratégia)
- ✅ IA decide **quando** entrar/sair
- ✅ Múltiplos agentes trabalham em paralelo
- ✅ Agentes criam novos agentes quando ganham
- ✅ Nenhuma configuração pré-definida (RSI/EMA/etc)
- ✅ Teste em **TESTNET** (grátis, sem risco)

---

## 🎯 Objetivo

Testar até onde a IA consegue:
1. **Pensar** autonomamente sobre oportunidades
2. **Decidir** onde investir sem regras pré-programadas
3. **Executar** trades baseado na sua lógica
4. **Aprender** com histórico
5. **Crescer** de 20 EUR até 100 EUR (ou falhar)

---

## 📋 Arquitetura

```
┌─────────────────────────────┐
│   FUND MANAGER (Central)    │
│ - Sincroniza agentes        │
│ - Check metas               │
│ - Coordena repouso          │
└──────────────┬──────────────┘
               │
       ┌───────┴───────┐
       │               │
   ┌───▼────┐      ┌───▼────┐
   │ Agente │      │ Agente │
   │   1    │      │   2    │
   │ (20€)  │      │ (20€)  │
   └────────┘      └────────┘
       │               │
       └───────┬───────┘
               │
         ┌─────▼──────┐
         │ IA (Claude)│
         │  a cada min│
         └────────────┘
```

### Ficheiros

- **config-testnet.json** — Configuração (testnet, chaves, parâmetros)
- **fund-manager.ps1** — Gestor central, sincroniza tudo
- **agente-template.ps1** — Template que cada agente usa (roda em paralelo)
- **INICIAR-TESTNET.ps1** — Script para começar tudo

### Ficheiros Gerados

- `./logs/` — Logs detalhados de cada agente e do fundo
- `./estado-fundo.json` — Estado do fundo (capital, agentes, meta)
- `./estado-Agente_N.json` — Estado de cada agente

---

## 🚀 Como Começar

### 1. Configurar Chaves

Edita `config-testnet.json`:

```json
{
  "ambiente": "testnet",
  "anthropic_api_key": "sk-ant-...",  // Obtém em https://console.anthropic.com/
  "binance_api_key_testnet": "opcional_para_ja",
  "telegram_token": "opcional_para_ja"
}
```

### 2. Rodar em PowerShell (Windows)

```powershell
# Abre PowerShell como Admin
# Muda para pasta do projeto
cd C:\caminhoDoProto\robo-trader

# Executa
.\INICIAR-TESTNET.ps1
```

### 3. Observar

- Verá logs em tempo real
- Cada decisão da IA é registada
- Mostra trades, ganhos, win rate
- Sistema roda 24/7 (ou até CTRL+C)

---

## 📊 O Que Esperar

### Primeiro Ciclo (Minuto 1)
```
[Agente_1] Consultando IA para decisão...
[IA] {"acao": "compra", "par": "BTC/USDT", "montante": 5, ...}
[Agente_1] TRADE: compra 5 EUR em BTC/USDT | Resultado: +2.3% | Ganho: 0.11 EUR
[Agente_1] Novo saldo: 20.11 EUR | Win Rate: 100%
```

### Depois de Vários Ciclos
```
RELATÓRIO DO FUNDO — Ciclo 150
═══════════════════════════════════════════════════════════════
💰 Capital Total: 65.3 EUR
🤖 Agentes Ativos: 2
🎯 Meta Atual: 100 EUR
📊 Progresso: 65.3%
😴 Em Repouso: Não
═══════════════════════════════════════════════════════════════
║ Agente_1: 45.2 EUR (ROI: 126% | Win Rate: 58%)
║ Agente_2: 20.1 EUR (ROI: 0.5% | Win Rate: 50%)
```

### Se Atingir 100 EUR
```
🎉 META ATINGIDA! Total: 102 EUR
Nova meta definida: 200 EUR
😴 Sistema em repouso por 24h...
```

---

## 🧠 Como a IA Pensa

Cada ciclo (~1 min), a IA recebe:

```
Tu és um trader autónomo com 20 EUR.
Capital atual: 43.5 EUR
Histórico: 150 trades, 58% vitórias

Mercado agora:
- BTC/USDT: 43250$ (+2.5% | volume: 1.5B)
- ETH/USDT: 2280$ (+1.8% | volume: 900M)
- SOL/USDT: 185$ (-1.2% | volume: 450M)

Decide:
1. Que estratégia vê?
2. Em que par entra?
3. Montante, stop loss, alvo?
4. Por quê?

Responde em JSON...
```

E a IA responde algo como:

```json
{
  "acao": "compra",
  "par": "ETH/USDT",
  "montante": 7,
  "stopLoss": 1.5,
  "alvo": 3,
  "estrategia": "ETH com breakout de suporte, momentum positivo, baixo risco",
  "risco": "médio",
  "confianca": 0.72
}
```

---

## 📈 Métricas a Observar

1. **Capital Total** — Soma de todos os agentes
2. **Win Rate** — % de trades com lucro
3. **Tempo para 100 EUR** — Quanto demora o ciclo
4. **Estratégias Descobertas** — Que aprende a IA
5. **Número de Agentes** — Quantos consegue criar
6. **ROI por Agente** — Desempenho individual

---

## ⚠️ Limitações em Testnet

- ✅ **Sem custos reais**
- ✅ **IA consegue testar ideias**
- ❌ **Sem slippage real**
- ❌ **Sem spread real**
- ❌ **Sem fees reais**
- ❌ **Sem liquidez limitada**

**Resultado:** Em testnet a IA pode parecer melhor do que é. No real, fees e spreads vão consumir ganhos.

---

## 🔄 Próximos Passos (Após Testnet)

1. **Analisar logs** — Como a IA pensou?
2. **Validar estratégias** — Que funcionaram?
3. **Calcular real ROI** — Com fees e spreads
4. **Decidir se passa para REAL** — 20 EUR reais

---

## 🐛 Se der Erro

### "Chave Anthropic inválida"
→ Obtém em https://console.anthropic.com/

### "Agente parou"
→ Verifica `./logs/Agente_*.log`

### "Fund Manager não começa"
→ Verifica `./logs/fundo-*.log`

### "IA responde lentamente"
→ Normal, API Anthropic pode levar 1-2 seg

---

## 📝 O Código Está Pronto?

- ✅ **Fund Manager** — Completo
- ✅ **Agente Template** — Completo (simulação testnet)
- ⚠️ **IA Brain** — Básico (funcionará, mas pode melhorar)
- ⚠️ **Binance Real** — Ainda não implementado
- ⚠️ **Telegram** — Ainda não implementado

Para rodar agora: **usar TESTNET (não precisa chaves Binance)**

---

## 🎮 Experiência Esperada

```
[Hora 0] Inicia Agente 1 com 20 EUR
[Hora 1] IA faz 1-2 trades, ganha 1-2 EUR
[Hora 6] Saldo cresceu para ~35 EUR
[Hora 12] Já tem 55 EUR, cria Agente 2
[Hora 24] Meta de 100 EUR atingida (ou não, depende da IA)
[Hora 25] Repouso 24h, depois continua
```

---

## 💡 Ideia Experimental

Este é um **teste de autonomia real**. A IA não tem regras pré-configuradas. Pode:
- Descobrir strategies por si
- Falhar completamente
- Aprender com erros
- Ou surpreender-te positivamente

**É um experimento, não uma garantia de lucro.**

---

## ✅ Próximos Passos

1. **Edita config-testnet.json** com tua chave Anthropic
2. **Abre PowerShell** na pasta do projeto
3. **Executa: `.\INICIAR-TESTNET.ps1`**
4. **Observa a IA a pensar e agir**
5. **Deixa rodar e coleta dados**

---

**Boa sorte! 🚀**

Qualquer questão, os logs estão em `./logs/`
