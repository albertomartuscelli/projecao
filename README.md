# Projeção de consumo de água e esgoto

Backtesting e projeção mensal de volume medido e faturado de água e esgoto,
residencial e não residencial.

## Estrutura

| Script | O que faz |
|---|---|
| `00_Funcoes.R` | Funções compartilhadas: ETL, outliers, agrupamentos, modelos, cenários, acurácia, elasticidades, gráficos |
| `01_Backtesting_Residencial.R` | Backtest residencial (categorias × recorte) |
| `02_Backtesting_Nao_Residencial.R` | Backtest não residencial (Comercial, Industrial, Pública) |
| `03_Projecao.R` | Projeção até dez/2027 com a agregação e o modelo escolhidos nos backtests |

Rode na ordem 01 → 02 → 03, com o diretório de trabalho na pasta que contém
`05_FRAMEWORK_5/`. A base de entrada é única, com todas as categorias:
`05_FRAMEWORK_5/01_BASES/02_Base Analítica Ajustada_202201-202608.csv`. Cada
script filtra as categorias do seu segmento. Os scripts fazem `source("00_Funcoes.R")`, então o arquivo
de funções precisa estar no mesmo diretório de trabalho (ou ajuste o caminho).

## Backtesting

Responde duas perguntas para cada alvo (`med_agua`, `fat_agua`, `med_esg`, `fat_esg`):

1. **Qual o melhor modelo?** SNAIVE, ETS e ARIMA com regressoras incrementais
   (temperatura, chuva, nível dos reservatórios, tarifa, CAGED).
2. **Qual a melhor agregação?** `G1_original` (SP/Osasco/Guarulhos por ATC,
   municípios A, clusters B/C por regional), `G2_superintendencia` e
   `G3_municipio` (nível da chave).

Como funciona:

- Variável modelada: consumo por economia (`log`). O volume do teste é
  consumo previsto × economias reais.
- Outliers: `tsclean` no consumo só na janela de treino; a acurácia é medida
  contra o volume bruto.
- Exógenas no teste: `realizado` (ex-post) e três cenários ex-ante
  (`base`, `quente_seco`, `frio_umido`).
- Seleção: WAPE por superintendência no cenário `base` (parametrizável). O WAPE
  em nível de superintendência não deixa erros de regiões diferentes se
  compensarem, como acontece no MAPE do total.
- Séries curtas ou sem modelo entram com fallback (sazonal ingênuo → média de
  12 meses → média do segmento), para o total do teste ficar completo.

Saídas em `05_FRAMEWORK_5/03_BACKTESTING/<segmento>/`:

- `00_Decisao_<segmento>.xlsx`: decisão por alvo (lida pela projeção), abas
  `melhor_modelo` e `melhor_agregacao`
- `01_Acuracia_*.xlsx`, `02_Real_x_Forecast_*.xlsx`, `03_Elasticidades_*.xlsx` por alvo
- `graficos/` e `modelos/` (fits salvos; `reaproveitar_fit = TRUE` reutiliza)

## Projeção

Volume = consumo/economia × economias × fator tarifário

| Componente | Premissa |
|---|---|
| Consumo/economia | Modelo e agregação da decisão do backtest, ajustados em todo o histórico |
| Clima | Cenário principal `el_nino`: média do mês no histórico + anomalias do El Niño análogo em 2027. Alternativas: `base` (só a média), `quente_seco` e `frio_umido` (±1 desvio-padrão) |
| CAGED | Tendência dos últimos 12 meses |
| Nível dos reservatórios | `auto.arima` na série histórica |
| Economias | ETS amortecido no log; no residencial, projeta o total das categorias e reparte pela participação do último mês (migração normal → social); séries curtas repetem o último valor |
| Tarifa real (IRT) | Último valor deflacionado pelo IPCA mês a mês; reajuste nominal de 6,5% em abr/2027 |
| Fator tarifário | (IRT projetado / IRT médio dos últimos 12 meses) ^ elasticidade |

### Cenário El Niño (2027)

O único El Niño da amostra (forte, jun/2023-mai/2024) serve de análogo:
+1,3 °C e chuva 5% abaixo da média no estado, com até +3 °C entre set/2023 e
mai/2024. Para cada superintendência e mês do ano, a anomalia é a diferença
entre o valor no evento e a média do mês no histórico (temperatura, aditiva) ou
a razão (chuva, multiplicativa, limitada a 0,5-2). As anomalias são suavizadas
em 3 meses, porque um único evento não se repete mês a mês, e aplicadas sobre
o cenário base nos meses de `el_nino_periodo`. `el_nino_intensidade` escala o
evento (0,5 = El Niño fraco).

O efeito no volume passa pela temperatura e pela chuva dos modelos. O nível
dos reservatórios segue a projeção do `auto.arima` em todos os cenários.

### Elasticidade e reajuste como parâmetros

A elasticidade e o reajuste ficam parametrizados fora do modelo porque:

- Os modelos que vencem o backtest não têm tarifa. O IRT é um índice único
  estadual, com um salto por ano, e o efeito dele se confunde com a
  sazonalidade e a tendência. Os modelos com tarifa ficaram atrás no backtest.
- A elasticidade deve vir de uma estimação própria (microdados, projeto
  `elasticidade_tarifa`), não do coeficiente de um ARIMA agregado.
- Reajuste e elasticidade viram alavancas de cenário, independentes do modelo.

Cuidados implementados:

- **Sem dupla contagem.** Se a decisão escolher um modelo com tarifa
  (`arima_4`/`arima_5`), o fator não é aplicado; a trajetória do IRT entra
  como regressora.
- **Referência.** O fator compara a tarifa projetada com a tarifa real média
  dos últimos 12 meses, que é o nível já embutido no consumo recente.
- **Sensibilidade.** As colunas `vol_eps_baixa` e `vol_eps_alta` aplicam
  0,5× e 1,5× a elasticidade.

Saídas em `05_FRAMEWORK_5/04_PROJECAO/`: `Projecao_Volume_202712.xlsx` (premissas,
escolhas, totais anuais por segmento/categoria/superintendência, série mensal)
e `graficos/`.

## Observações sobre os dados

- Mar/2026 e abr/2026 tiveram problema de faturamento; os volumes foram
  rebalanceados entre os dois meses pela razão histórica (economias com casas
  decimais em ~99% das linhas). Só o total do bimestre é real, por isso o
  backtest avalia mar+abr/2026 como um único período (`meses_agrupados`).
- Linhas sem volume ou sem economias saem da modelagem; os buracos são
  interpolados no consumo e marcados como `IMPUTADO` no histórico da projeção.
- A LCA é lida de `05_FRAMEWORK_5/01_BASES/compilado_LCA.csv`; sem o arquivo,
  a comparação é ignorada com um aviso.
- Os scripts são lidos como UTF-8 (padrão do R 4.2+ no Windows).
