
# =============================================================================
# BACKTESTING - CONSUMO RESIDENCIAL (VOLUME / ECONOMIA)
#
# Responde, para cada alvo (água/esgoto, medido/faturado):
#   1. Qual o melhor modelo?     -> aba `melhor_modelo`
#   2. Qual a melhor agregação?  -> aba `melhor_agregacao`
# A combinação vencedora vai para 00_Decisao_Residencial.xlsx, lida pelo
# 03_Projecao.R.
#
# Fluxo (funções em 00_Funcoes.R):
#   0. Parâmetros
#   1. Importação
#   2. Backtest por alvo: outliers (só treino) -> séries por agrupamento ->
#      fit -> forecast por cenário (+ fallback) -> acurácia -> elasticidades
#   3. Respostas e exportação
# =============================================================================

source("00_Funcoes.R", encoding = "UTF-8")


# 0. PARÂMETROS ----------------------------------------------------------------

cfg = list(
  segmento   = "Residencial",
  arq_base   = "05_FRAMEWORK_5/01_BASES/02_Base Analítica Ajustada_202201-202608.csv",
  categorias = "Residencial",
  # Grandes clientes (coluna `porte` da base do Databricks): "somar" reproduz
  # as séries de antes; "demais" testa o erro sem os grandes (só experimento)
  porte      = "somar",
  dir_saida  = "05_FRAMEWORK_5/03_BACKTESTING/Residencial",

  # Alvos (definidos em `alvos_def`): med_agua | fat_agua | med_esg | fat_esg.
  # Só os medidos por desempenho; na projeção, o faturado usa a escolha do
  # medido do mesmo serviço.
  alvos = c("med_agua", "med_esg"),

  # Janela de backtest
  periodo_corte  = as.Date("2026-01-01"),   # 1º mês de teste
  horizonte      = 8,                       # meses de teste
  min_obs_treino = 36,                      # mínimo de meses p/ ajustar modelo

  # Meses avaliados como um único período (soma). Mar-abr/2026 tiveram
  # problema de faturamento e os volumes foram rebalanceados pela razão
  # histórica: só o total do bimestre é real. list() para avaliar mês a mês.
  meses_agrupados = list(c("2026-03-01", "2026-04-01")),

  # Outliers: tsclean no consumo/economia só na janela de treino.
  # A acurácia é medida contra o volume bruto (o que de fato foi medido/faturado).
  tratar_outliers  = TRUE,
  limpar_economias = FALSE,
  alvo_real        = "bruto",               # bruto | ajustado

  # Picos de faturamento no teste: até max_meses_pico meses seguidos da chave
  # acima de fator_pico x mediana 12m do treino, voltando ao normal depois. O
  # real volta à mediana antes das métricas. Lista na aba picos_teste.
  corrigir_picos_teste = TRUE,
  fator_pico           = 3,
  max_meses_pico       = 3,

  # Agrupamentos a testar (nomes de `regras_agrupamento`)
  # G3_municipio fica fora por desempenho (empatou com G1 a 4x o custo)
  agrupamentos = c("G1_municipioA_clusterBC", "G2_superintendencia"),

  # Modelos testados (catálogo `modelos_catalogo` em 00_Funcoes.R). vol_* =
  # volume direto; snaive = benchmark (não é escolhido); em empate técnico, ganha o modelo sem drift. Menos modelos = mais rápido.
  modelos = names(modelos_catalogo),

  # Economias no teste: "reais" -> o erro medido é o de consumo/economia
  # (por célula, erro % de volume = erro % de consumo); o volume direto é
  # avaliado pelo consumo implícito (volume previsto / economias reais).
  # "projetadas" -> erro de volume, somando o erro do ETS das economias.
  economias_teste = "reais",
  economias_agrega_categorias = TRUE,     # ETS no total das categorias do grupo

  # Critério de seleção: agregação e modelo escolhidos em cada categoria
  selecao_por     = "categoria_detalhe",    # NULL = uma escolha para o segmento
  nivel_selecao   = "superintendencia",     # nome em `niveis`
  metrica_selecao = "WAPE",                 # MAPE | WAPE | sMAPE | RMSE | MAE
  cenario_selecao = "base",                 # realizado | base | quente_seco | frio_umido
  tolerancia_selecao = 0.05,                # p.p.: empate técnico -> agregação com menos séries
  n_melhores      = 5,

  # Níveis de acurácia
  niveis = list(total = character(0),
                superintendencia = "cd_regiao_adj",
                categoria = "categoria_detalhe",
                recorte = "recorte",
                superint_cat_rec = c("cd_regiao_adj", "categoria_detalhe", "recorte")),

  # Níveis das elasticidades e dimensão das linhas dos violinos
  niveis_elast = list(geral = character(0),
                      categoria = "categoria_detalhe",
                      recorte = "recorte",
                      superintendencia = "cd_regiao_adj",
                      categoria_recorte = c("categoria_detalhe", "recorte")),
  dim_graf_elast = "recorte",

  # LCA (NULL para ignorar); comparada só nos alvos indicados
  arq_lca   = "05_FRAMEWORK_5/01_BASES/compilado_LCA.csv",
  lca_alvos = "med_agua",

  # Processamento (Windows/RStudio: multisession)
  n_workers        = 20,
  reaproveitar_fit = TRUE,                  # lê o fit salvo em disco se existir
  manter_modelos   = FALSE                  # TRUE: guarda os fits em memória (mais RAM)
)

tic("Total")


# 1. IMPORTAÇÃO ----------------------------------------------------------------

base = carrega_base(cfg$arq_base, cfg$categorias, cfg$porte)

base %>%
  group_by(categoria_detalhe, recorte) %>%
  summarise(vol = sum(vol_med_agua, na.rm = T),
            n = n_distinct(chave),
            .groups = "drop") %>%
  mutate(perc = vol/sum(vol)) %>%
  arrange(desc(vol))


# 2. BACKTEST POR ALVO ---------------------------------------------------------

bt = cfg$alvos %>%
  set_names() %>%
  map(~ executa_backtest(base, .x, cfg))


# 3. RESPOSTAS E EXPORTAÇÃO ----------------------------------------------------

## 3.1 Qual o melhor modelo? ---------------------------------------------------

melhor_modelo = imap_dfr(bt, ~ mutate(.x$tab_modelos, alvo = .y, .before = 1))

melhor_modelo %>%
  filter(rank <= 3) %>%
  print(n = Inf)

## 3.2 Qual a melhor agregação? ------------------------------------------------

melhor_agregacao = imap_dfr(bt, ~ mutate(.x$tab_agregacao, alvo = .y, .before = 1))

melhor_agregacao %>%
  print(n = Inf)

## 3.3 Decisão (lida pela projeção) --------------------------------------------

decisao = map_dfr(bt, "decisao")

decisao %>%
  print()

write_xlsx(list(decisao = decisao,
                melhor_modelo = melhor_modelo,
                melhor_agregacao = melhor_agregacao,
                elasticidade_geral = imap_dfr(bt, ~ mutate(.x$elasticidades$geral, alvo = .y, .before = 1)),
                parametros = tibble(parametro = names(cfg),
                                    valor = map_chr(cfg, ~ paste(format(unlist(.x)), collapse = ", ")))),
           file.path(cfg$dir_saida, glue("00_Decisao_{nome_arq(cfg$segmento)}.xlsx")))

# Resultados leves (sem os modelos ajustados, que ficam em /modelos)
saveRDS(map(bt, ~ .x[c("acc", "ranking", "decisao", "tab_modelos", "tab_agregacao",
                       "coeficientes", "elasticidades", "estat_melhores", "fit_x_real")]),
        file.path(cfg$dir_saida, glue("BT_{nome_arq(cfg$segmento)}_{format(cfg$periodo_corte, '%Y%m')}.rds")))

toc()
