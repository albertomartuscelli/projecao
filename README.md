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
`05_FRAMEWORK_4/`. Os scripts fazem `source("00_Funcoes.R")`, então o arquivo
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

Saídas em `05_FRAMEWORK_4/03_BACKTESTING/<segmento>/`:

- `00_Decisao_<segmento>.xlsx`: decisão por alvo (lida pela projeção), abas
  `melhor_modelo` e `melhor_agregacao`
- `01_Acuracia_*.xlsx`, `02_Real_x_Forecast_*.xlsx`, `03_Elasticidades_*.xlsx` por alvo
- `graficos/` e `modelos/` (fits salvos; `reaproveitar_fit = TRUE` reutiliza)

## Projeção

Volume = consumo/economia × economias × fator tarifário

| Componente | Premissa |
|---|---|
| Consumo/economia | Modelo e agregação da decisão do backtest, ajustados em todo o histórico |
| Clima | Média do mês no histórico (`base`); ±1 desvio-padrão nos cenários `quente_seco` e `frio_umido` |
| CAGED | Tendência dos últimos 12 meses |
| Nível dos reservatórios | `auto.arima` na série histórica |
| Economias | ETS amortecido no log por série; séries curtas repetem o último valor |
| Tarifa real (IRT) | Último valor deflacionado pelo IPCA mês a mês; reajuste nominal de 6,5% em abr/2027 |
| Fator tarifário | (IRT projetado / IRT médio dos últimos 12 meses) ^ elasticidade |

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

Saídas em `05_FRAMEWORK_4/04_PROJECAO/`: `Projecao_Volume_202712.xlsx` (premissas,
escolhas, totais anuais por segmento/categoria/superintendência, série mensal)
e `graficos/`.

## Observações sobre os dados

- O volume medido de esgoto está vazio em mar/2026 e abr/2026 em todas as
  chaves. O backtest exclui esses meses das métricas; a projeção interpola o
  consumo e marca os meses como `IMPUTADO` no histórico.
- O nome do arquivo da base não residencial no script é
  `02_Base Analítica Ajustada_202201-202608_Não Residencial.csv`; ajuste
  `arq_base` se o nome for outro.
- Os scripts são lidos como UTF-8 (padrão do R 4.2+ no Windows).
