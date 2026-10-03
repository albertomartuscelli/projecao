# Projeção de consumo de água e esgoto

Backtesting e projeção mensal de volume medido e faturado de água e esgoto,
residencial e não residencial.

## Fluxo

```
Databricks                                                    R (local)
01_Base_Analitica_Porte ─┐
                         ├─> 03_Base_Analitica_Final ─> CSV ─> 01/02_Backtesting ─> 03_Projecao
02_Covariaveis (APIs) ───┘
```

## Estrutura

| Arquivo | O que faz |
|---|---|
| `databricks/01_Base_Analitica_Porte.sql` | Faturas → PDE × mês, porte dos clientes, correção de volumes absurdos, base por categoria × ATC × recorte × porte |
| `databricks/02_Covariaveis.py` | IPCA e Focus (BCB), tarifa real por categoria (tabela de reajustes), clima e CAGED |
| `databricks/03_Base_Analitica_Final.sql` | Ajustes da base (categorias, recorte, ABC, séries inválidas, mar/abr 2026), covariáveis e exportação do CSV |
| `00_Funcoes.R` | Funções compartilhadas: ETL, outliers, agrupamentos, modelos, cenários, acurácia, elasticidades, gráficos |
| `01_Backtesting_Residencial.R` | Backtest residencial (categorias × recorte) |
| `02_Backtesting_Nao_Residencial.R` | Backtest não residencial (Comercial, Industrial, Pública) |
| `03_Projecao.R` | Projeção até dez/2027 com a agregação e o modelo escolhidos nos backtests |
| `legado/` | Scripts R antigos da base e das covariáveis (referência) |

Detalhes do Databricks (rotina mensal, arquivos no Volume, fontes, validações) em
[`databricks/README.md`](databricks/README.md).

No R, rode na ordem 01 → 02 → 03, com o diretório de trabalho na pasta que contém
`05_FRAMEWORK_5/`. A base de entrada é única, com todas as categorias:
`05_FRAMEWORK_5/01_BASES/02_Base Analítica Ajustada_202201-202608.csv` (saída do notebook 03). Cada
script filtra as categorias do seu segmento. Os scripts fazem `source("00_Funcoes.R")`, então o arquivo
de funções precisa estar no mesmo diretório de trabalho (ou ajuste o caminho).

## Base de dados

### Grandes clientes (porte)

Um PDE é **Grande** quando a mediana do seu volume medido em 2025 é ao menos `share_min` da série
(superintendência × categoria) e ao menos `v_min` m³/mês, com 6 meses ou mais de fatura. Os limiares saíram
da calibração D4: variação líquida jan–ago/2026 sobre jan–ago/2025 de cada série, grandes × demais.

| Categoria | Limiar | % do volume | % da variação | Variação grandes × demais |
|---|---|---|---|---|
| Pública | 0,1% da série e 1.000 m³ | 32% | 63% | 11,3% × 3,1% |
| Industrial | 0,05% da série e 5.000 m³ | 12% | 24% | 13,6% × 6,2% |
| Comercial | sem separação | — | — | grandes variam como os demais (queda de 2026 espalhada) |
| Residencial | sem separação | < 2% | — | — |

A base sai com a coluna `porte`. No R, `cfg$porte = "somar"` (padrão) junta Grande + Demais e reproduz as
séries de antes; `"demais"` serve para medir o erro do backtest sem os grandes. Modelar só os Demais e dar
premissa própria aos grandes ainda não está implementado.

### Correção de volumes absurdos

O diagnóstico D6 achou ~300 PDE-mês com volume ≥ 50 mil m³ e ≥ 10× a mediana do próprio PDE, somando 94 mi
m³ de excesso no medido de água (até 10% do volume do estado num mês; −28% na Pública e na Industrial e −22%
no Comercial nos piores meses). Em ~80% dos casos o volume é 9.99x, 99.99x ou 999.99x m³: hidrômetro que
"virou". A etapa 2b do notebook 01 troca o volume desses PDE-mês pela mediana do PDE, separadamente no medido
e no faturado de água e de esgoto (o esgoto tem erros próprios: 25 mi m³ em 2024). As colunas `*_bruto`
guardam o valor antes da correção.

Outros diagnósticos do notebook 01:

- **Faturas múltiplas no mês (D1b)**: não há medido em dobro. O faturado líquido é igual ou maior que o
  medido somado em todos os tipos; os lançamentos negativos são acertos dentro da própria fatura. A soma das
  faturas está certa.
- **Descartes (D2)**: ~75 mil m³ sem categoria no histórico inteiro.
- **Conferência (D5)**: sem a correção, a base nova bate com a antiga (0,000%), exceto Outras (+Caminhão e
  Embarcação).

### Ajustes da base final (antes no R)

As regras do `02_Análise_Exploratória_e_Ajustes.R` foram para o notebook 03, com correções:

| No R | Agora |
|---|---|
| Recorte nulo excluído antes de o não residencial virar "Total" | Não residencial vira "Total" antes; residencial sem recorte vira "Urbano" |
| Séries inválidas pela média por linha de `catego` | Média do total mensal da série, somando os portes |
| Série sem o último mês excluída inteira | Tolerância de 2 meses |
| Mar/abr 2026: economias pela participação do volume | Economias interpoladas entre fev e mai; volumes pela participação histórica |
| ABC por um único mês | Últimos 12 meses |
| Amostra por linha | Amostra por chave (séries inteiras) |
| CAGED com `na_locf` sem agrupar por município | Último valor dentro de cada município |

## Backtesting

Responde duas perguntas para cada alvo (`med_agua`, `med_esg`) e **cada
categoria** (Normal, Social e Social Vulnerável; Comercial, Industrial e
Pública):

1. **Qual o melhor modelo?** Catálogo em `modelos_catalogo`:

   | Modelo | Variável | Especificação |
   |---|---|---|
   | `arima_0`, `arima_1`, `arima_2` | consumo/economia | ordens automáticas; sem regressoras, temperatura, temperatura + chuva |
   | `arima_2_caged` | consumo/economia | `arima_2` + CAGED (`arima_2` × `arima_2_caged` testa o CAGED) |
   | `arima_2_dsaz` | consumo/economia | `arima_2` com diferença sazonal forçada (parte do mesmo mês do ano anterior) |
   | `arima_2_sem_drift` | consumo/economia | `arima_2` com diferença simples forçada e sem constante (não extrapola tendência) |
   | `vol_arima_2`, `vol_arima_2_caged` | volume direto | mesmas regressoras, sem passar pelas economias |
   | `vol_arima_2_dsaz_sem_drift` | volume direto | diferença sazonal forçada, sem constante |

   Tarifa e nível dos reservatórios não entram nos modelos (ver "Tarifa" e "Nível dos reservatórios").
   | `snaive` | consumo/economia | benchmark: entra nas tabelas, mas não é escolhido |

2. **Qual a melhor agregação?** `G1_municipioA_clusterBC` (municípios A
   individuais, B/C agrupados por regional; SP/Osasco/Guarulhos por ATC) e
   `G2_superintendencia`. `G3_municipio` (nível da chave) fica definido, fora
   da lista por desempenho.

Como funciona:

- Medida principal: **erro de consumo (volume/economia)**. Com
  `economias_teste = "reais"` (padrão), o volume previsto é consumo previsto ×
  economias reais, então o erro % de cada célula é o erro % do consumo; os
  modelos de volume direto são avaliados pelo consumo implícito. Com
  `"projetadas"`, o erro inclui o do ETS das economias (erro de volume).
- Outliers: `tsclean` no consumo só na janela de treino; a acurácia é medida
  contra o volume bruto. Mar+abr/2026 são avaliados como um bimestre. Com os
  volumes absurdos corrigidos na origem (notebook 01), vale comparar
  `tratar_outliers = TRUE` × `FALSE` (com `FALSE`, só interpola zeros e buracos).
- Exógenas no teste: `realizado` (ex-post) e três cenários ex-ante
  (`base`, `quente_seco`, `frio_umido`).
- Seleção: WAPE por superintendência dentro de cada categoria, no cenário
  `base`. Em empate técnico (`tolerancia_selecao`), fica o modelo sem drift
  (o teste de 8 meses quase não pune um drift errado, e a projeção vai 16
  meses à frente) e, depois, a agregação com menos séries. A linha `COMBINADO / escolha` nas tabelas de acurácia mede o
  conjunto (cada categoria com a sua escolha).
- Séries curtas ou sem modelo entram com fallback (sazonal ingênuo → média de
  12 meses → média do segmento), para o total do teste ficar completo.

Saídas em `05_FRAMEWORK_5/03_BACKTESTING/<segmento>/`:

- `00_Decisao_<segmento>.xlsx`: decisão por alvo (lida pela projeção), abas
  `melhor_modelo` e `melhor_agregacao`
- `01_Acuracia_*.xlsx`, `02_Real_x_Forecast_*.xlsx`, `03_Elasticidades_*.xlsx` por alvo
- `graficos/` e `modelos/` (fits salvos; `reaproveitar_fit = TRUE` reutiliza
  só se os dados de treino e as fórmulas forem os mesmos)

## Projeção

Volume = consumo/economia × economias × fator tarifário (nos modelos `vol_*`,
o volume vem direto do modelo e só recebe o fator tarifário)

| Componente | Premissa |
|---|---|
| Consumo/economia ou volume | Modelo e agregação da decisão do backtest **por categoria**, ajustados em todo o histórico. Água e esgoto faturados usam a escolha do medido do mesmo serviço |
| Clima | Cenário principal `el_nino`: média do mês no histórico + anomalias do El Niño análogo em 2027. Alternativas: `base` (só a média), `quente_seco` e `frio_umido` (±1 desvio-padrão) |
| CAGED | Tendência dos últimos 12 meses |
| Economias | Projetadas por chave, uma vez por alvo: ETS amortecido no log do total de cada nível (`nivel_economias`: superintendência × recorte no residencial, somando as categorias por causa da migração normal → social; superintendência × categoria no não residencial), repartido pela participação de cada chave no último mês. Residencial em 2027: premissa da engenharia somada ao estoque de dez/2026 nas chaves dos municípios cobertos. Colunas `*_ets` mostram o resultado só com ETS |
| Tarifa real (IRT) | Último valor deflacionado pelo IPCA mês a mês; reajuste nominal de 6,5% em abr/2027 (ver "Pontos em aberto") |
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

O efeito no volume passa pela temperatura e pela chuva dos modelos.

### Tarifa: fora dos modelos, elasticidade como parâmetro

Nenhum modelo tem a tarifa como regressora. O efeito do reajuste entra na projeção pela elasticidade
parametrizada (`elasticidade_tarifa`, no `03_Projecao.R`), aplicada a todos os modelos. Motivos:

- **Não há como identificar o efeito no ARIMA.** O IRT é um índice único estadual: nenhuma variação entre
  séries, só 4 a 5 degraus em 2022–2026. Os degraus caem sempre em transições sazonais e se misturam com a
  sazonalidade e com mudanças de nível:

  | Reajuste | Vigência | Fonte |
  |---|---|---|
  | +12,80% | 10/05/2022 | Arsesp |
  | +9,56% | 10/05/2023 | Arsesp (inclui revisão extraordinária de 5,55%) |
  | +6,45% | 10/05/2024 | Arsesp |
  | −1% residencial, −10% social e vulnerável, −0,5% comercial e industrial | jul/2024 | desestatização |
  | +6,11% na URAE-1 (média de 6,5%) | 01/01/2026 | Deliberação Arsesp 1.748/2025 (IPCA jun/2024 a out/2025) |

- **O sinal é pequeno.** A tarifa real oscila poucos pontos em torno de um nível estável (o reajuste repõe
  o IPCA). Com elasticidade entre −0,1 e −0,3, o efeito no consumo fica abaixo de ~1,5%, menor que o erro
  dos modelos. Um coeficiente mal estimado, por outro lado, pode mover a projeção em vários pontos depois
  de cada reajuste.
- **A elasticidade certa vem de microdados**, com variação entre faixas, categorias e tarifa social
  (projeto `elasticidade_tarifa`).

**Tarifa real por categoria.** O IRT vem da tabela de reajustes do notebook `02_Covariaveis` (percentuais
das deliberações da Arsesp e mês em que chegaram às contas) deflacionada pelo IPCA, uma série por
categoria. Substitui o `Tarifa_final.csv` (faixa 1 do Residencial Normal da regional OC), que tinha o
reajuste de 2024 com +6,95% (oficial: 6,45%) e um índice só para todas as categorias. Reajuste novo = uma
linha na tabela.

Cuidados implementados:

- **Referência.** O fator compara a tarifa projetada com a tarifa real média dos últimos 12 meses da
  própria categoria, que é o nível já embutido no consumo recente.
- **Sensibilidade.** As colunas `vol_eps_baixa` e `vol_eps_alta` aplicam 0,5× e 1,5× a elasticidade.

Pontos em aberto:

- **Mês do reajuste de 2027.** Pelo contrato da URAE-1, o ciclo é anual com vigência em 1º de janeiro
  (IPCA até outubro). O `03_Projecao.R` usa abril, porque em 2026 o reajuste só chegou às contas em
  mar/abr. Se o atraso de 2026 foi pontual, o mais provável é janeiro.
- **Tamanho do reajuste.** 6,5% nominal repete a média de 2026, que cobriu 16 meses de IPCA. Para um ciclo
  de 12 meses, o reajuste tende a ficar perto do IPCA do período (Focus em `gmm_projecao_cov_focus_ipca`).
- **Redução de jul/2024 na Pública.** A tabela de reajustes usa 0% (a confirmar); as demais categorias
  seguem a desestatização (−1% residencial, −10% social, −0,5% comercial e industrial).
- **Série neutra de tarifa.** Com a elasticidade final, dá para tirar do histórico o efeito dos reajustes
  passados (consumo ÷ (IRT/IRT_ref)^ε) antes de ajustar os modelos e reaplicar na projeção. Hoje o efeito
  passado fica embutido no nível e na tendência do ARIMA.

Saídas em `05_FRAMEWORK_5/04_PROJECAO/`: `Projecao_Volume_202712.xlsx` (premissas,
escolhas, totais anuais por segmento/categoria/superintendência, série mensal)
e `graficos/`.

### Nível dos reservatórios: fora dos modelos

O nível do Sistema Integrado Metropolitano não entra nos modelos. Motivos:

- **Abrangência errada.** Abastece a RMSP, mas entrava em todas as séries, inclusive interior e litoral,
  que dependem de outros mananciais.
- **Pouca informação própria.** É uma série única, sazonal e movida pela chuva acumulada: colinear com a
  sazonalidade e com `prec_tot`.
- **O mecanismo não é linear.** O nível só muda o consumo quando dispara medidas operacionais (gestão de
  pressão, campanhas, bônus/multa, como em 2014-15). Um coeficiente linear mistura os dois regimes.
- **Projeção sem cenário.** Exigia um `auto.arima` próprio que ignorava os cenários de clima.

A alternativa para o efeito real é uma variável de intervenção nas séries da RMSP (1 nos meses com gestão
de pressão ou restrição), com o cenário de manter ou retirar a medida em 2027. A extração do nível saiu
do `02_Covariaveis`. Para retomar: `legado/ETL_MANANCIAIS.R` ou a API v4 da Sabesp
(`https://mananciais.sabesp.com.br/api/v4/sistemas/dados/resumo-diario/AAAA-MM-DD`, `idSistema = 75`,
campo `volumeUtilArmazenadoPorcentagem`; cabeçalho `Referer: https://mananciais.sabesp.com.br/`).

### CAGED: candidato, decidido no backtest

O CAGED tem variação por município e um mecanismo plausível no não residencial (atividade econômica
local). Fica como candidato: `arima_2_caged` × `arima_2` (e `vol_arima_2_caged` × `vol_arima_2`) diferem
só pelo CAGED, e a seleção por categoria decide. Cuidados:

- **Dentro de cada série, o CAGED é quase uma tendência suave** (sem recessão em 2022–2026). O coeficiente
  tende a capturar a tendência do consumo, não o ciclo econômico.
- **Na projeção, vira tendência imposta**: o CAGED é extrapolado pelo crescimento dos últimos 12 meses
  até dez/2027, e o efeito no consumo é coeficiente × esse crescimento. Se ficar, vale um cenário de
  emprego externo (consultoria) no lugar da extrapolação.
- **Ruído nos municípios pequenos** (empregos agrícolas sazonais com saltos de 50% a 90% no mês). Nas séries
  agregadas o efeito dilui, porque o CAGED do grupo é a soma dos municípios.

Critério para manter numa categoria: o modelo com CAGED vence o sem CAGED por mais que a tolerância (WAPE,
cenário `base`) **e** a elasticidade do CAGED (aba de elasticidades) tem sinal positivo e magnitude
plausível (0 a 1) na maioria das séries. Para tirar de vez, retire `arima_2_caged` e `vol_arima_2_caged`
de `cfg$modelos`.

## Observações sobre os dados

- `prec_tot` é a **média diária** de chuva do mês (mm/dia), não o total. Os modelos usam `log(prec_tot)`;
  meses quase sem chuva (ex.: jul/2022 e jun-jul/2024 no norte do estado, 0,002 mm/dia) viram pontos
  extremos no log. Vale testar `log1p(prec_tot)`.
- Mar/2026 e abr/2026 tiveram problema de faturamento; os volumes foram
  rebalanceados entre os dois meses pela razão histórica (economias com casas
  decimais em ~99% das linhas). Só o total do bimestre é real, por isso o
  backtest avalia mar+abr/2026 como um único período (`meses_agrupados`).
- Linhas sem volume ou sem economias saem da modelagem; os buracos são
  interpolados no consumo e marcados como `IMPUTADO` no histórico da projeção.
- A LCA é lida de `cfg$arq_lca`; sem o arquivo, a comparação é ignorada com um
  aviso. O benchmark é o consumo/economia da LCA × as economias reais. Aceita o
  compilado bruto (`tp, periodo, categoria, regiao, var, valor`): o consumo da
  LCA, que vem por região (capital = "M"; OI+OX, OC+OS, OM+OP, OT+OU) e por
  Normal/Social, é pareado com cada série em `lca_de_para()`. Também aceita um
  arquivo já pareado nas chaves do framework. Mar+abr/2026 são agregados só nas
  métricas; os gráficos mostram os meses separados.
- Os scripts são lidos como UTF-8 (padrão do R 4.2+ no Windows).
