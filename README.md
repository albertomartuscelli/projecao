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

Responde duas perguntas para cada alvo (`med_agua`, `med_esg`) e **cada
categoria** (Normal, Social e Social Vulnerável; Comercial, Industrial e
Pública):

1. **Qual o melhor modelo?** Catálogo em `modelos_catalogo`:

   | Modelo | Variável | Especificação |
   |---|---|---|
   | `arima_0` a `arima_5` | consumo/economia | ARIMA com regressoras incrementais: temperatura, chuva, nível dos reservatórios, tarifa, CAGED |
   | `arima_2_D1` | consumo/economia | diferença sazonal forçada (segue o nível do ano anterior) |
   | `arima_5_d1_0` | consumo/economia | diferença simples forçada, sem constante (sem drift) |
   | `vol_arima_2`, `vol_arima_5`, `vol_arima_5_D1_0` | volume direto | mesmas regressoras, sem passar pelas economias |
   | `snaive` | consumo/economia | benchmark: entra nas tabelas, mas não é escolhido |

2. **Qual a melhor agregação?** `G1_municipioA_clusterBC` (municípios A
   individuais, B/C agrupados por regional; SP/Osasco/Guarulhos por ATC) e
   `G2_superintendencia`. `G3_municipio` (nível da chave) fica definido, fora
   da lista por desempenho.

Como funciona:

- Consumo/economia × **economias projetadas** (ETS) no teste, como na
  projeção. Assim a comparação com o volume direto é justa
  (`economias_teste = "reais"` isola só o modelo de consumo).
- Outliers: `tsclean` no consumo só na janela de treino; a acurácia é medida
  contra o volume bruto. Mar+abr/2026 são avaliados como um bimestre.
- Exógenas no teste: `realizado` (ex-post) e três cenários ex-ante
  (`base`, `quente_seco`, `frio_umido`).
- Seleção: WAPE por superintendência dentro de cada categoria, no cenário
  `base`. Em empate técnico (`tolerancia_selecao`), fica a agregação com
  menos séries. A linha `COMBINADO / escolha` nas tabelas de acurácia mede o
  conjunto (cada categoria com a sua escolha).
- Séries curtas ou sem modelo entram com fallback (sazonal ingênuo → média de
  12 meses → média do segmento), para o total do teste ficar completo.

Saídas em `05_FRAMEWORK_5/03_BACKTESTING/<segmento>/`:

- `00_Decisao_<segmento>.xlsx`: decisão por alvo (lida pela projeção), abas
  `melhor_modelo` e `melhor_agregacao`
- `01_Acuracia_*.xlsx`, `02_Real_x_Forecast_*.xlsx`, `03_Elasticidades_*.xlsx` por alvo
- `graficos/` e `modelos/` (fits salvos; `reaproveitar_fit = TRUE` reutiliza)

## Projeção

Volume = consumo/economia × economias × fator tarifário (nos modelos `vol_*`,
o volume vem direto do modelo e só recebe o fator tarifário)

| Componente | Premissa |
|---|---|
| Consumo/economia ou volume | Modelo e agregação da decisão do backtest **por categoria**, ajustados em todo o histórico. Água e esgoto faturados usam a escolha do medido do mesmo serviço |
| Clima | Cenário principal `el_nino`: média do mês no histórico + anomalias do El Niño análogo em 2027. Alternativas: `base` (só a média), `quente_seco` e `frio_umido` (±1 desvio-padrão) |
| CAGED | Tendência dos últimos 12 meses |
| Nível dos reservatórios | `auto.arima` na série histórica |
| Economias | Projetadas por chave, uma vez por alvo: ETS amortecido no log do total de cada nível (`nivel_economias`: superintendência × recorte no residencial, somando as categorias por causa da migração normal → social; superintendência × categoria no não residencial), repartido pela participação de cada chave no último mês. Residencial em 2027: premissa da engenharia somada ao estoque de dez/2026 nas chaves dos municípios cobertos. Colunas `*_ets` mostram o resultado só com ETS |
| Tarifa real (IRT) | Último valor deflacionado pelo IPCA mês a mês; reajuste nominal de 6,5% em abr/2027 |
| Fator tarifário | (IRT projetado / IRT médio dos últimos 12 meses) ^ elasticidade |

### Premissa de novas economias (engenharia)

A planilha `ALAVANCA DE VOLUME - NOVAS ECONOMIAS 2027.xlsx` (em `01_BASES`) traz
as entregas mensais de 2027 por categoria, utilização, município, projeto e tipo
de ligação. Os nomes são casados com a base sem acento, maiúsculas ou
pontuação. A "Utilização" mistura categoria e recorte; o de-para fica em
`de_para_utilizacao` no `03_Projecao.R`:

| Utilização | categoria_detalhe × recorte |
|---|---|
| Normal | Residencial Normal × Urbano/Informal |
| Rural | Residencial Normal × Rural |
| Tarifa Social | Residencial Social e Social Vulnerável × Urbano/Informal |

O incremento é repartido entre as chaves do município pelo estoque de
economias do último mês. Sem chave correspondente (ex.: rural onde a base não
tem chave rural), vai para todas as chaves do município. Municípios fora da
planilha seguem o ETS (`economias_fora_premissa`).

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
