
# =============================================================================
# BACKTESTING - CONSUMO NÃO RESIDENCIAL (VOLUME / ECONOMIA)
#
# Mesmo fluxo do residencial (funções em 00_Funcoes.R). Diferenças:
#   - categorias Comercial, Industrial e Pública (sem recorte: "Total")
#   - níveis de acurácia e de elasticidade por categoria, não por recorte
#
# Responde, para cada alvo (água/esgoto, medido/faturado):
#   1. Qual o melhor modelo?     -> aba `melhor_modelo`
#   2. Qual a melhor agregação?  -> aba `melhor_agregacao`
# A combinação vencedora vai para 00_Decisao_Nao_Residencial.xlsx, lida pelo
# 03_Projecao.R.
# =============================================================================

source("00_Funcoes.R", encoding = "UTF-8")


# 0. PARÂMETROS ----------------------------------------------------------------

cfg = list(
  segmento   = "Não Residencial",
  arq_base   = "05_FRAMEWORK_4/01_BASES/02_Base Analítica Ajustada_202201-202608_Não Residencial.csv",
  categorias = c("Comercial", "Industrial", "Pública"),
  dir_saida  = "05_FRAMEWORK_4/03_BACKTESTING/Nao_Residencial",

  # Alvos (definidos em `alvos_def`): med_agua | fat_agua | med_esg | fat_esg
  alvos = c("med_agua", "fat_agua", "med_esg", "fat_esg"),

  # Janela de backtest
  periodo_corte  = as.Date("2026-01-01"),   # 1º mês de teste
  horizonte      = 8,                       # meses de teste
  min_obs_treino = 36,                      # mínimo de meses p/ ajustar modelo

  # Outliers: tsclean no consumo/economia só na janela de treino.
  # A acurácia é medida contra o volume bruto (o que de fato foi medido/faturado).
  tratar_outliers  = TRUE,
  limpar_economias = FALSE,
  alvo_real        = "bruto",               # bruto | ajustado

  # Agrupamentos a testar (nomes de `regras_agrupamento`)
  agrupamentos = c("G1_original", "G2_superintendencia", "G3_municipio"),

  # Tarifa nos cenários ex-ante: realizada (reajuste conhecido) | constante
  tarifa_ex_ante = "realizada",

  # Critério de seleção
  nivel_selecao   = "superintendencia",     # nome em `niveis`
  metrica_selecao = "WAPE",                 # MAPE | WAPE | sMAPE | RMSE | MAE
  cenario_selecao = "base",                 # realizado | base | quente_seco | frio_umido
  tolerancia_selecao = 0.05,                # p.p.: empate técnico -> agregação com menos séries
  n_melhores      = 5,

  # Níveis de acurácia
  niveis = list(total = character(0),
                superintendencia = "cd_regiao_adj",
                categoria = "categoria_detalhe",
                superint_categoria = c("cd_regiao_adj", "categoria_detalhe")),

  # Níveis das elasticidades e dimensão das linhas dos violinos
  niveis_elast = list(geral = character(0),
                      categoria = "categoria_detalhe",
                      superintendencia = "cd_regiao_adj"),
  dim_graf_elast = "categoria_detalhe",

  # LCA (NULL para ignorar). Só ligue se o arquivo tiver a coluna
  # categoria_detalhe com as categorias não residenciais.
  arq_lca   = NULL,
  lca_alvos = "med_agua",

  # Processamento (Windows/RStudio: multisession)
  n_workers        = 20,
  reaproveitar_fit = TRUE                   # lê o fit salvo em disco se existir
)

tic("Total")


# 1. IMPORTAÇÃO ----------------------------------------------------------------

base = carrega_base(cfg$arq_base, cfg$categorias)

base %>%
  group_by(categoria_detalhe) %>%
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
