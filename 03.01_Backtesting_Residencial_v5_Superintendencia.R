
# =============================================================================
# BACKTESTING - CONSUMO RESIDENCIAL (VOLUME / ECONOMIA)
# v5 - Superintendência
#
# Fluxo:
#   0. Parâmetros
#   1. Importação e ETL
#   2. Tratamento de outliers (por chave)
#   3. Estimação
#      3.0 Regras de agrupamento (cada regra é um "candidato" do backtest)
#      3.1 Treino, teste e cenários das variáveis exógenas
#      3.2 Fit
#      3.3 Forecast (por cenário + fallback para chaves sem modelo) + LCA
#      3.4 Acurácia (MAPE, WAPE, sMAPE, RMSE, MAE, viés) por nível
#      3.5 Elasticidades (geral, categoria, recorte, superintendência)
#   4. Exportação (Excel + gráficos)
# =============================================================================

pacman::p_load(tidyverse, data.table, readxl, writexl, glue, zoo,
               tsibble, fable, fabletools, feasts, forecast, scales,
               future, future.apply, tictoc)

tema = theme(axis.ticks = element_blank(),
             panel.grid.major.x = element_blank(),
             panel.grid.major.y = element_line(color = "grey85",
                                               linetype = "dashed"),
             panel.grid.minor = element_blank(),
             strip.text = element_text(color = "white", face = "bold",
                                       size = 9,
                                       angle = 0),
             strip.text.y.left = element_text(color = "white", face = "bold",
                                              size = 9,
                                              angle = 0),
             strip.background = element_rect(color = "white", fill = "#003853"),
             plot.background = element_rect(fill = "white"),
             panel.background = element_rect(fill = "grey98"),
             plot.title = element_text(face = "bold", size = 16),
             plot.subtitle = element_text(size = 14),
             legend.position = "right",
             axis.text = element_text(size = 9),
             axis.title = element_blank())


# 0. PARÂMETROS ----------------------------------------------------------------

arq_base  = "05_FRAMEWORK_4/01_BASES/02_Base Analítica Ajustada_202201-202608_Residencial.csv"
arq_lca   = "05_FRAMEWORK_4/01_BASES/compilado_LCA.xlsx"   # .xlsx ou .csv
dir_saida = "05_FRAMEWORK_4/03_BACKTESTING"

# Variável de interesse (trocar para esgoto / faturado nos próximos testes)
var_vol  = "vol_med_agua"        # vol_med_esg | vol_fat_agua | vol_fat_esg
var_econ = "n_economias_agua"    # n_economias_esg

# Janela de backtest
periodo_corte  = as.Date("2026-01-01")   # 1º mês de teste
horizonte      = 8                       # meses de teste
min_obs_treino = 36                      # mínimo de meses de treino p/ ajustar ARIMA

# Real usado como referência na acurácia: "ajustado" (pós-tsclean) ou "bruto"
alvo_real = "ajustado"

# tsclean nas economias? Saltos de economias costumam ser reais (novas
# ligações, recadastramento), por isso o padrão limpa só o consumo/economia
limpar_economias = FALSE

# Agrupamentos a testar (nomes de `regras_agrupamento`, seção 3.0)
agrupamentos = c("G1_original", "G2_superintendencia", "G3_municipio", "G4_abc_regiao")

# Tarifa nos cenários ex-ante: "realizada" (reajuste conhecido/regulado)
# ou "constante" (último valor real do treino)
tarifa_ex_ante = "realizada"

# Seleção do melhor modelo
nivel_selecao   = "superintendencia"   # total | superintendencia | categoria | recorte | superint_cat_rec
metrica_selecao = "WAPE"               # MAPE | WAPE | sMAPE | RMSE | MAE
cenario_selecao = "base"               # realizado | base | quente_seco | frio_umido
n_melhores      = 5                    # nº de modelos detalhados na seção 3.6

# Processamento (Windows/RStudio: multisession; multicore não funciona)
n_workers        = 20
reaproveitar_fit = TRUE                # lê o fit salvo em disco se existir

dir.create(file.path(dir_saida, "graficos"), recursive = TRUE, showWarnings = FALSE)
dir.create(file.path(dir_saida, "modelos"),  recursive = TRUE, showWarnings = FALSE)

sufixo = format(periodo_corte, "%Y%m")

tic("Total")


# 1. IMPORTAÇÃO e ETL ----------------------------------------------------------

base = fread(arq_base, encoding = "UTF-8") %>%
  as_tibble()

# Compatibilidade com versões antigas da base
if ("irt_real" %in% names(base) & !"tarifa" %in% names(base)) {
  base = rename(base, tarifa = irt_real)
}

base_res = base %>%
  filter(categoria == "Residencial") %>%
  mutate(periodo = as.Date(periodo),
         chave = paste(cd_regiao, municipio, cd_atc, categoria_detalhe, recorte, sep = "_"),
         vol = .data[[var_vol]],
         econ = .data[[var_econ]]) %>%
  select(chave, cd_regiao, municipio, cd_atc, categoria_detalhe, recorte,
         classificacao_abc, periodo, vol, econ,
         prec_tot, temp_med, caged, nv_sim, lag_nv_sim, tarifa)

stopifnot(!anyDuplicated(base_res[c("chave", "periodo")]))

# Exógenas municipais (1 valor por município x mês), sem buracos
mun_exog = base_res %>%
  distinct(municipio, periodo, prec_tot, temp_med, caged) %>%
  group_by(municipio) %>%
  complete(periodo = seq(min(base_res$periodo), max(base_res$periodo), by = "month")) %>%
  arrange(periodo, .by_group = TRUE) %>%
  mutate(across(c(prec_tot, temp_med, caged), ~ na.approx(., na.rm = FALSE, rule = 2))) %>%
  ungroup()

# Exógenas globais (1 valor por mês)
glob_exog = base_res %>%
  distinct(periodo, tarifa, nv_sim, lag_nv_sim) %>%
  arrange(periodo)

stopifnot(!anyDuplicated(glob_exog$periodo))

magnitude_catego_recorte = base_res %>%
  group_by(categoria_detalhe, recorte) %>%
  summarise(vol = sum(vol, na.rm = T),
            n = n_distinct(chave),
            .groups = "drop") %>%
  arrange(desc(vol)) %>%
  mutate(perc = vol/sum(vol))


# 2. TRATAMENTO DE OUTLIERS ----------------------------------------------------

# tsclean robusto: séries curtas usam frequência 1; se falhar, só interpola.
# Nunca devolve NA "silencioso" para uma série que tinha dados.
limpa_serie = function(x, freq = 12) {
  x = as.numeric(x)
  x[!is.finite(x) | x <= 0] = NA
  if (sum(!is.na(x)) < 4) return(x)
  f = if (length(x) >= 2 * freq + 1) freq else 1
  out = tryCatch(as.numeric(forecast::tsclean(ts(x, frequency = f))),
                 error = function(e) NULL)
  if (is.null(out)) {
    out = tryCatch(as.numeric(forecast::na.interp(ts(x, frequency = 1))),
                   error = function(e) x)
  }
  out
}

base_chave = base_res %>%
  select(chave, cd_regiao, municipio, cd_atc, categoria_detalhe, recorte,
         classificacao_abc, periodo, vol, econ) %>%
  group_by(chave) %>%
  complete(periodo = seq(min(periodo), max(periodo), by = "month")) %>%
  fill(cd_regiao, municipio, cd_atc, categoria_detalhe, recorte, classificacao_abc,
       .direction = "downup") %>%
  arrange(periodo, .by_group = TRUE) %>%
  mutate(preenchido = is.na(econ),
         consumo = vol/econ,
         econ_ajust = if (limpar_economias) limpa_serie(econ) else econ,
         consumo_ajust = limpa_serie(consumo)) %>%
  ungroup() %>%
  # buracos internos servem só para o tsclean; não viram volume
  filter(!preenchido) %>%
  mutate(econ_ajust = coalesce(econ_ajust, econ),
         consumo_ajust = coalesce(consumo_ajust, consumo),
         vol_ajust = econ_ajust * consumo_ajust,
         vol_ajust = coalesce(vol_ajust, vol),
         outlier_consumo = abs(consumo_ajust - consumo) > 1e-8 * pmax(1, abs(consumo)),
         outlier_econ = abs(econ_ajust - econ) > 1e-8 * pmax(1, abs(econ))) %>%
  select(-preenchido)

resumo_outliers = base_chave %>%
  summarise(perc_obs_outlier_consumo = mean(outlier_consumo, na.rm = T),
            perc_obs_outlier_econ = mean(outlier_econ, na.rm = T),
            var_vol_total = sum(vol_ajust, na.rm = T)/sum(vol, na.rm = T) - 1)

print(resumo_outliers)

agg_compara_outlier = base_chave %>%
  group_by(periodo, categoria_detalhe) %>%
  summarise(consumo_agua = sum(vol, na.rm = T)/sum(econ, na.rm = T),
            consumo_agua_ajust = sum(vol_ajust, na.rm = T)/sum(econ_ajust, na.rm = T),
            .groups = "drop")

g_outlier = agg_compara_outlier %>%
  ggplot(aes(x = periodo)) +
  geom_line(aes(y = consumo_agua, color = "Bruto")) +
  geom_line(aes(y = consumo_agua_ajust, color = "Ajustado")) +
  facet_wrap(~categoria_detalhe, scales = "free_y", ncol = 1) +
  scale_color_manual("", values = c("Bruto" = "black", "Ajustado" = "red")) +
  labs(title = "Consumo médio (m³/economia) - bruto x ajustado") +
  tema

g_outlier


# 3. ESTIMAÇÃO -----------------------------------------------------------------

## 3.0 Regras de agrupamento ---------------------------------------------------

# Toda regra mantém cd_regiao_adj, categoria_detalhe e recorte na chave da
# série, para que todos os agrupamentos sejam comparáveis nesses níveis.
mun_atc = c("SAO PAULO", "OSASCO", "GUARULHOS")

regras_agrupamento = list(
  # Regra original: SP/Osasco/Guarulhos por ATC, A individual, B/C por regional
  G1_original = quo(case_when(municipio %in% mun_atc ~ paste0(municipio, "_", cd_atc),
                              classificacao_abc == "A" ~ municipio,
                              T ~ paste0("cluster_", cd_regiao))),
  # Uma série por superintendência
  G2_superintendencia = quo(cd_regiao_adj),
  # Uma série por município (SP/Osasco/Guarulhos por ATC)
  G3_municipio = quo(if_else(municipio %in% mun_atc,
                             paste0(municipio, "_", cd_atc),
                             municipio)),
  # Como G1, mas B e C viram clusters separados dentro da regional
  G4_abc_regiao = quo(case_when(municipio %in% mun_atc ~ paste0(municipio, "_", cd_atc),
                                classificacao_abc == "A" ~ municipio,
                                T ~ paste0("cluster_", cd_regiao, "_", classificacao_abc)))
)

chaves_ts = c("cd_regiao_adj", "grupo", "categoria_detalhe", "recorte")

base_chave = base_chave %>%
  mutate(cd_regiao_adj = if_else(municipio == "SAO PAULO",
                                 paste0("SP_", cd_regiao),
                                 cd_regiao))

monta_base_ts = function(regra) {

  df = base_chave %>%
    mutate(grupo = !!regra)

  # CAGED é estoque: soma dos municípios do grupo (composição fixa, sem
  # contar o mesmo município duas vezes quando há várias ATCs/chaves)
  caged_grp = df %>%
    distinct(across(all_of(chaves_ts)), municipio) %>%
    inner_join(mun_exog %>% select(municipio, periodo, caged),
               by = "municipio", relationship = "many-to-many") %>%
    group_by(across(all_of(chaves_ts)), periodo) %>%
    summarise(caged = sum(caged), .groups = "drop")

  df %>%
    left_join(mun_exog %>% select(municipio, periodo, prec_tot, temp_med),
              by = c("municipio", "periodo")) %>%
    group_by(across(all_of(chaves_ts)), periodo) %>%
    summarise(prec_tot = weighted.mean(prec_tot, w = econ_ajust, na.rm = T),
              temp_med = weighted.mean(temp_med, w = econ_ajust, na.rm = T),
              vol_ajust = sum(vol_ajust, na.rm = T),
              vol_bruto = sum(vol, na.rm = T),
              econ_ajust = sum(econ_ajust, na.rm = T),
              econ_bruto = sum(econ, na.rm = T),
              n_chaves = n_distinct(chave),
              n_mun = n_distinct(municipio),
              .groups = "drop") %>%
    left_join(caged_grp, by = c(chaves_ts, "periodo")) %>%
    mutate(periodo = yearmonth(periodo)) %>%
    as_tsibble(key = all_of(chaves_ts), index = periodo) %>%
    # buracos internos: interpola consumo e exógenas (não cria volume real)
    fill_gaps() %>%
    as_tibble() %>%
    group_by(across(all_of(chaves_ts))) %>%
    arrange(periodo, .by_group = TRUE) %>%
    mutate(preenchido = is.na(vol_ajust),
           consumo = vol_ajust/econ_ajust,
           consumo = if_else(is.finite(consumo) & consumo > 0, consumo, NA_real_),
           across(c(consumo, prec_tot, temp_med, caged),
                  ~ na.approx(., na.rm = FALSE, rule = 2))) %>%
    ungroup() %>%
    left_join(glob_exog %>% mutate(periodo = yearmonth(periodo)), by = "periodo") %>%
    as_tsibble(key = all_of(chaves_ts), index = periodo)
}


## 3.1 Treino, teste e cenários ------------------------------------------------

fim_treino     = yearmonth(periodo_corte) - 1
periodos_teste = yearmonth(periodo_corte) + 0:(horizonte - 1)

regressoras = c("temp_med", "prec_tot", "lag_nv_sim", "tarifa", "caged")

# Nível dos reservatórios projetado (série única) - usado no lag_nv_sim ex-ante
nv_hist = glob_exog %>%
  filter(yearmonth(periodo) <= fim_treino)

nv_fc = nv_hist$nv_sim %>%
  ts(frequency = 12,
     start = c(year(min(nv_hist$periodo)), month(min(nv_hist$periodo)))) %>%
  auto.arima() %>%
  forecast::forecast(h = horizonte) %>%
  .$mean %>%
  as.numeric() %>%
  pmin(1) %>% pmax(0)

# lag_nv_sim em t = nv_sim em t-1: o 1º mês de teste já é conhecido
exog_global_ex_ante = tibble(periodo = periodos_teste,
                             lag_nv_proj = c(last(nv_hist$nv_sim), head(nv_fc, -1)),
                             tarifa_proj = last(nv_hist$tarifa))

# Cenários das exógenas no período de teste
#   realizado   : ex-post (valores observados)
#   base        : clima = média do mês no treino; CAGED = tendência dos últimos
#                 12 meses; nível = ARIMA; tarifa conforme `tarifa_ex_ante`
#   quente_seco : base com temperatura +1 dp e precipitação -1 dp
#   frio_umido  : base com temperatura -1 dp e precipitação +1 dp
monta_cenarios = function(train, new_data) {

  clim = train %>%
    as_tibble() %>%
    mutate(mes = month(periodo)) %>%
    group_by(across(all_of(chaves_ts)), mes) %>%
    summarise(temp_mu = mean(temp_med), temp_sd = coalesce(sd(temp_med), 0),
              prec_mu = mean(prec_tot), prec_sd = coalesce(sd(prec_tot), 0),
              prec_min = min(prec_tot),
              .groups = "drop")

  caged_tend = train %>%
    as_tibble() %>%
    group_by(across(all_of(chaves_ts))) %>%
    arrange(periodo, .by_group = TRUE) %>%
    summarise(caged_T = last(caged),
              g = (last(caged)/nth(caged, -13))^(1/12) - 1,
              .groups = "drop") %>%
    mutate(g = if_else(is.finite(g), g, 0))

  base_ex_ante = new_data %>%
    as_tibble() %>%
    mutate(mes = month(periodo),
           k = as.numeric(periodo) - as.numeric(fim_treino)) %>%
    left_join(clim, by = c(chaves_ts, "mes")) %>%
    left_join(caged_tend, by = chaves_ts) %>%
    left_join(exog_global_ex_ante, by = "periodo") %>%
    mutate(caged = caged_T * (1 + g)^k,
           lag_nv_sim = lag_nv_proj,
           tarifa = if (tarifa_ex_ante == "constante") tarifa_proj else tarifa)

  list(
    realizado   = new_data %>% as_tibble(),
    base        = base_ex_ante %>%
      mutate(temp_med = temp_mu,
             prec_tot = prec_mu),
    quente_seco = base_ex_ante %>%
      mutate(temp_med = temp_mu + temp_sd,
             prec_tot = pmax(prec_mu - prec_sd, prec_min)),
    frio_umido  = base_ex_ante %>%
      mutate(temp_med = pmax(temp_mu - temp_sd, 1),
             prec_tot = prec_mu + prec_sd)
  ) %>%
    map(~ .x %>%
          select(all_of(chaves_ts), periodo, all_of(regressoras)) %>%
          as_tsibble(key = all_of(chaves_ts), index = periodo))
}

# Fallback para séries sem modelo (curtas, iniciadas no teste, ou ARIMA que
# falhou): sazonal ingênuo -> média dos últimos 12 meses -> média do
# segmento (superintendência x categoria x recorte) -> categoria x recorte
monta_fallback = function(base_ts, grade) {

  hist = base_ts %>%
    as_tibble() %>%
    filter(periodo <= fim_treino, !preenchido, !is.na(consumo))

  ult12 = hist %>%
    group_by(across(all_of(chaves_ts))) %>%
    slice_max(periodo, n = 12) %>%
    summarise(consumo_media12 = mean(consumo), .groups = "drop")

  seg = hist %>%
    filter(periodo > fim_treino - 12) %>%
    group_by(cd_regiao_adj, categoria_detalhe, recorte) %>%
    summarise(consumo_seg = sum(vol_ajust)/sum(econ_ajust), .groups = "drop")

  cat_rec = hist %>%
    filter(periodo > fim_treino - 12) %>%
    group_by(categoria_detalhe, recorte) %>%
    summarise(consumo_cat_rec = sum(vol_ajust)/sum(econ_ajust), .groups = "drop")

  grade %>%
    distinct(across(all_of(chaves_ts)), periodo) %>%
    mutate(periodo_snaive = periodo - 12 * ceiling((as.numeric(periodo) - as.numeric(fim_treino))/12)) %>%
    left_join(hist %>% select(all_of(chaves_ts), periodo_snaive = periodo, consumo_snaive = consumo),
              by = c(chaves_ts, "periodo_snaive")) %>%
    left_join(ult12, by = chaves_ts) %>%
    left_join(seg, by = c("cd_regiao_adj", "categoria_detalhe", "recorte")) %>%
    left_join(cat_rec, by = c("categoria_detalhe", "recorte")) %>%
    mutate(consumo_fb = coalesce(consumo_snaive, consumo_media12, consumo_seg, consumo_cat_rec)) %>%
    select(all_of(chaves_ts), periodo, consumo_fb)
}


## 3.2 Fit ---------------------------------------------------------------------

modelos = list(
  # benchmarks
  snaive  = SNAIVE(log(consumo)),
  ets     = ETS(log(consumo)),
  # candidatos
  arima_0 = ARIMA(log(consumo) ~ pdq(0:2, 0:1, 0:2) + PDQ(0:1, 0:1, 0:1)),
  arima_1 = ARIMA(log(consumo) ~ pdq(0:2, 0:1, 0:2) + PDQ(0:1, 0:1, 0:1) + log(temp_med)),
  arima_2 = ARIMA(log(consumo) ~ pdq(0:2, 0:1, 0:2) + PDQ(0:1, 0:1, 0:1) + log(temp_med) + log(prec_tot)),
  arima_3 = ARIMA(log(consumo) ~ pdq(0:2, 0:1, 0:2) + PDQ(0:1, 0:1, 0:1) + log(temp_med) + log(prec_tot) + lag_nv_sim),
  arima_4 = ARIMA(log(consumo) ~ pdq(0:2, 0:1, 0:2) + PDQ(0:1, 0:1, 0:1) + log(temp_med) + log(prec_tot) + lag_nv_sim + tarifa),
  arima_5 = ARIMA(log(consumo) ~ pdq(0:2, 0:1, 0:2) + PDQ(0:1, 0:1, 0:1) + log(temp_med) + log(prec_tot) + lag_nv_sim + tarifa + log(caged))
)

res = list()

for (agrup in agrupamentos) {

  message(glue("\n===== {agrup} ====="))
  tic(agrup)

  base_ts = monta_base_ts(regras_agrupamento[[agrup]])

  info_series = base_ts %>%
    as_tibble() %>%
    group_by(across(all_of(chaves_ts))) %>%
    summarise(n_treino = sum(periodo <= fim_treino & !is.na(consumo)),
              ult_treino = if (any(periodo <= fim_treino)) max(periodo[periodo <= fim_treino]) else NA,
              .groups = "drop") %>%
    mutate(elegivel = n_treino >= min_obs_treino & !is.na(ult_treino) & ult_treino == fim_treino)

  message(glue("Séries: {nrow(info_series)} | elegíveis p/ modelo: {sum(info_series$elegivel)}"))

  train = base_ts %>%
    filter(periodo <= fim_treino) %>%
    semi_join(info_series %>% filter(elegivel), by = chaves_ts)

  new_data = base_ts %>%
    filter(periodo %in% periodos_teste) %>%
    semi_join(info_series %>% filter(elegivel), by = chaves_ts)

  # FIT
  arq_fit = file.path(dir_saida, "modelos", glue("fit_{agrup}_{sufixo}_{var_vol}.rds"))

  if (reaproveitar_fit & file.exists(arq_fit)) {
    fit_model = readRDS(arq_fit)
  } else {
    # multisession só no fit: no forecast a cópia dos modelos p/ os workers
    # custa mais que o cálculo. tryCatch garante a volta ao sequential.
    plan(multisession, workers = n_workers)
    tic("Fit")
    fit_model = tryCatch(train %>% model(!!!modelos),
                         finally = plan(sequential))
    toc()
    saveRDS(fit_model, arq_fit)
  }

  ## 3.3 Forecast --------------------------------------------------------------

  cenarios = monta_cenarios(train, new_data)

  fc = imap_dfr(cenarios, function(nd, nm) {
    fit_model %>%
      fabletools::forecast(new_data = nd) %>%
      as_tibble() %>%
      select(all_of(chaves_ts), .model, periodo, consumo_prev = .mean) %>%
      mutate(cenario = nm)
  })

  # Real do teste (só meses observados) x todos modelos x cenários
  teste_real = base_ts %>%
    as_tibble() %>%
    filter(periodo %in% periodos_teste, !preenchido)

  grade = teste_real %>%
    select(all_of(chaves_ts), periodo) %>%
    crossing(.model = names(modelos), cenario = names(cenarios))

  fallback = monta_fallback(base_ts, grade)

  fit_x_real = grade %>%
    left_join(fc, by = c(chaves_ts, "periodo", ".model", "cenario")) %>%
    left_join(fallback, by = c(chaves_ts, "periodo")) %>%
    left_join(info_series %>% select(all_of(chaves_ts), elegivel), by = chaves_ts) %>%
    mutate(fallback = case_when(!elegivel ~ "nao_elegivel",
                                !is.finite(consumo_prev) ~ "falha_modelo",
                                T ~ "modelo"),
           consumo_prev = if_else(fallback == "modelo", consumo_prev, consumo_fb)) %>%
    left_join(teste_real %>% select(all_of(chaves_ts), periodo,
                                    vol_ajust, vol_bruto, econ_ajust, econ_bruto),
              by = c(chaves_ts, "periodo")) %>%
    mutate(n_economias  = if (alvo_real == "ajustado") econ_ajust else econ_bruto,
           vol_med_real = if (alvo_real == "ajustado") vol_ajust else vol_bruto,
           vol_med_fit  = consumo_prev * n_economias,
           agrupamento  = agrup) %>%
    select(agrupamento, cenario, .model, all_of(chaves_ts), periodo,
           n_economias, vol_med_real, vol_med_fit, fallback)

  res[[agrup]] = list(base_ts = base_ts,
                      info_series = info_series,
                      train = train,
                      fit_model = fit_model,
                      cenarios = cenarios,
                      fit_x_real = fit_x_real)

  toc()
}

fit_x_real = map_dfr(res, "fit_x_real")


### Diagnóstico: séries e fallback ---------------------------------------------

resumo_series = imap_dfr(res, function(r, nm) {
  r$info_series %>%
    summarise(n_series = n(),
              n_elegiveis = sum(elegivel)) %>%
    mutate(agrupamento = nm, .before = 1)
})

resumo_fallback = fit_x_real %>%
  filter(cenario == "realizado") %>%
  group_by(agrupamento, .model, fallback) %>%
  summarise(vol = sum(vol_med_real, na.rm = T), n = n(), .groups = "drop_last") %>%
  mutate(perc_vol = vol/sum(vol)) %>%
  ungroup()

resumo_fallback %>%
  filter(fallback != "modelo") %>%
  print(n = 50)


### Cenários das exógenas ------------------------------------------------------

cenarios_exog = imap_dfr(res, function(r, agrup) {
  imap_dfr(r$cenarios, function(nd, nm) {
    nd %>%
      as_tibble() %>%
      left_join(r$base_ts %>% as_tibble() %>% select(all_of(chaves_ts), periodo, econ_ajust),
                by = c(chaves_ts, "periodo")) %>%
      group_by(periodo) %>%
      summarise(temp_med = weighted.mean(temp_med, econ_ajust, na.rm = T),
                prec_tot = weighted.mean(prec_tot, econ_ajust, na.rm = T),
                caged = sum(caged),
                lag_nv_sim = first(lag_nv_sim),
                tarifa = first(tarifa),
                .groups = "drop") %>%
      mutate(cenario = nm)
  }) %>%
    mutate(agrupamento = agrup, .before = 1)
})

g_cenarios_exog = cenarios_exog %>%
  filter(agrupamento == agrupamentos[1]) %>%
  pivot_longer(temp_med:tarifa) %>%
  ggplot(aes(x = periodo, y = value, color = cenario)) +
  geom_line(lwd = 1) +
  facet_wrap(~name, scales = "free_y") +
  labs(title = "Exógenas no período de teste por cenário") +
  tema

g_cenarios_exog


### LCA ------------------------------------------------------------------------

# Previsão de consumo (volume/economia) da consultoria. O nível de comparação é
# detectado pelas colunas presentes no arquivo (ex.: categoria_detalhe,
# recorte, cd_regiao_adj, cd_regiao, municipio). Volume LCA = consumo LCA x
# economias reais, igual aos modelos.
lca_col_periodo = "periodo"
lca_col_consumo = "consumo"
lca_chaves_possiveis = c("cd_regiao_adj", "cd_regiao", "municipio", "categoria_detalhe", "recorte")

carrega_lca = function(arq) {

  if (!file.exists(arq)) {
    message(glue("Arquivo LCA não encontrado ({arq}) - comparação ignorada."))
    return(NULL)
  }

  lca = if (str_detect(arq, "\\.xlsx?$")) read_excel(arq) else fread(arq, encoding = "UTF-8")

  lca = lca %>%
    as_tibble() %>%
    rename(periodo = all_of(lca_col_periodo), consumo_lca = all_of(lca_col_consumo))

  if ("categoria" %in% names(lca)) lca = filter(lca, categoria == "Residencial")

  # periodo: Date, POSIXct, "AAAA-MM-DD" ou AAAAMM
  lca$periodo = if (is.numeric(lca$periodo) && all(lca$periodo > 190000, na.rm = T)) {
    as.Date(paste0(lca$periodo, "01"), "%Y%m%d")
  } else {
    as.Date(lca$periodo)
  }
  lca$periodo = yearmonth(lca$periodo)

  attr(lca, "chaves") = intersect(lca_chaves_possiveis, names(lca))
  lca
}

lca = carrega_lca(arq_lca)
lca_chaves = attr(lca, "chaves")

if (!is.null(lca)) {

  real_lca = base_chave %>%
    mutate(periodo = yearmonth(periodo)) %>%
    filter(periodo %in% periodos_teste) %>%
    group_by(across(all_of(lca_chaves)), periodo) %>%
    summarise(vol_med_real = sum(if (alvo_real == "ajustado") vol_ajust else vol, na.rm = T),
              n_economias = sum(if (alvo_real == "ajustado") econ_ajust else econ, na.rm = T),
              .groups = "drop")

  lca_x_real = real_lca %>%
    left_join(lca %>%
                group_by(across(all_of(lca_chaves)), periodo) %>%
                summarise(consumo_lca = mean(consumo_lca), .groups = "drop"),
              by = c(lca_chaves, "periodo"))

  cobertura_lca = lca_x_real %>%
    summarise(perc_vol_coberto = sum(vol_med_real[!is.na(consumo_lca)])/sum(vol_med_real))

  message(glue("LCA - chaves: {paste(lca_chaves, collapse = ', ')} | ",
               "volume coberto: {percent(cobertura_lca$perc_vol_coberto, 0.1)}"))

  # Replicado em todos os cenários para aparecer em todas as comparações
  lca_x_real = lca_x_real %>%
    filter(!is.na(consumo_lca)) %>%
    mutate(vol_med_fit = consumo_lca * n_economias,
           agrupamento = "LCA",
           .model = "LCA",
           fallback = "modelo") %>%
    crossing(cenario = unique(fit_x_real$cenario)) %>%
    select(-consumo_lca)

} else {
  lca_x_real = NULL
}


### Real x Forecast ------------------------------------------------------------

# O real é o mesmo em qualquer agrupamento
real_hist = res[[1]]$base_ts %>%
  as_tibble() %>%
  filter(!preenchido) %>%
  mutate(vol_med = if (alvo_real == "ajustado") vol_ajust else vol_bruto,
         n_economias = if (alvo_real == "ajustado") econ_ajust else econ_bruto) %>%
  select(cd_regiao_adj, categoria_detalhe, recorte, periodo, vol_med, n_economias)

# Base de comparação em nível superintendência x categoria x recorte
real_fc = fit_x_real %>%
  group_by(agrupamento, cenario, .model, cd_regiao_adj, categoria_detalhe, recorte, periodo) %>%
  summarise(across(c(n_economias, vol_med_real, vol_med_fit), ~ sum(., na.rm = T)),
            .groups = "drop") %>%
  mutate(consumo_real = vol_med_real/n_economias,
         consumo_fit = vol_med_fit/n_economias)


## 3.4 Acurácia ----------------------------------------------------------------

niveis = list(total = character(0),
              superintendencia = "cd_regiao_adj",
              categoria = "categoria_detalhe",
              recorte = "recorte",
              superint_cat_rec = c("cd_regiao_adj", "categoria_detalhe", "recorte"))

metricas = function(real, fit, econ) {
  e = fit - real
  tibble(MAPE  = mean(abs(e)/real) * 100,
         WAPE  = sum(abs(e))/sum(real) * 100,
         sMAPE = mean(2 * abs(e)/(abs(real) + abs(fit))) * 100,
         APE_max = max(abs(e)/real) * 100,
         Vies  = sum(e)/sum(real) * 100,
         MAE   = mean(abs(e)),
         RMSE  = sqrt(mean(e^2)),
         RMSE_consumo = sqrt(mean((e/econ)^2)),
         n = length(e))
}

# Agrega no nível, calcula erros por célula (elemento x mês) e resume.
# `detalhe = TRUE` devolve as métricas por elemento do nível.
calc_acc = function(base, nivel, detalhe = FALSE) {

  if (!is.null(lca_x_real) && all(nivel %in% lca_chaves)) {
    base = bind_rows(base, lca_x_real)
  }

  agg = base %>%
    group_by(agrupamento, cenario, .model, across(all_of(nivel)), periodo) %>%
    summarise(across(c(n_economias, vol_med_real, vol_med_fit), ~ sum(., na.rm = T)),
              .groups = "drop") %>%
    filter(vol_med_real > 0)

  grp = c("agrupamento", "cenario", ".model", if (detalhe) nivel)

  agg %>%
    group_by(across(all_of(grp))) %>%
    summarise(metricas(vol_med_real, vol_med_fit, n_economias), .groups = "drop") %>%
    arrange(cenario, MAPE)
}

acc = map(niveis, ~ calc_acc(fit_x_real, .x))

acc_detalhe_superint = calc_acc(fit_x_real, "cd_regiao_adj", detalhe = T)

# Ranking
ranking = acc[[nivel_selecao]] %>%
  filter(cenario == cenario_selecao) %>%
  arrange(.data[[metrica_selecao]]) %>%
  mutate(rank = row_number(), .before = 1) %>%
  left_join(acc$total %>%
              select(agrupamento, cenario, .model,
                     MAPE_total = MAPE, WAPE_total = WAPE, Vies_total = Vies),
            by = c("agrupamento", "cenario", ".model"))

melhor = ranking %>%
  filter(agrupamento != "LCA") %>%
  slice(1)

message(glue("Melhor: {melhor$agrupamento} / {melhor$.model} ",
             "({metrica_selecao} {nivel_selecao} = {number(melhor[[metrica_selecao]], 0.01)}%, ",
             "cenário {cenario_selecao})"))

# Tabela larga como no script original (MAPE do total)
acc_bu = acc$total %>%
  select(agrupamento, cenario, .model, MAPE) %>%
  pivot_wider(names_from = .model, values_from = MAPE)

acc_bu


### Gráficos -------------------------------------------------------------------

real_total = real_hist %>%
  filter(year(periodo) >= 2025) %>%
  group_by(periodo) %>%
  summarise(vol_med = sum(vol_med, na.rm = T)/10^6)

fc_total = bind_rows(fit_x_real, lca_x_real) %>%
  group_by(agrupamento, cenario, .model, periodo) %>%
  summarise(vol_med = sum(vol_med_fit, na.rm = T)/10^6, .groups = "drop")

# Real x forecast por modelo e agrupamento (cenário de seleção)
g_real_fc = ggplot(data = NULL, aes(x = periodo, y = vol_med)) +
  geom_line(data = real_total, aes(group = "Real"), lwd = 1) +
  geom_line(data = fc_total %>% filter(cenario == cenario_selecao, agrupamento != "LCA"),
            aes(color = agrupamento), lwd = 0.8) +
  {if (!is.null(lca_x_real))
    geom_line(data = fc_total %>% filter(cenario == cenario_selecao, agrupamento == "LCA") %>%
                select(-.model),
              aes(linetype = "LCA"), color = "grey40", lwd = 0.8)} +
  facet_wrap(~.model, nrow = 2) +
  labs(title = "Volume medido (milhões m³) - real x forecast",
       subtitle = glue("Cenário: {cenario_selecao} | Corte: {format(periodo_corte, '%m/%Y')}"),
       linetype = "") +
  tema

g_real_fc

# Melhor modelo nos diferentes cenários
g_cenarios = ggplot(data = NULL, aes(x = periodo, y = vol_med)) +
  geom_line(data = real_total, aes(color = "Real"), lwd = 1.2) +
  geom_line(data = fc_total %>%
              filter(agrupamento == melhor$agrupamento, .model == melhor$.model),
            aes(color = cenario), lwd = 0.8) +
  {if (!is.null(lca_x_real))
    geom_line(data = fc_total %>% filter(agrupamento == "LCA", cenario == cenario_selecao),
              aes(color = "LCA"), lwd = 0.8, linetype = "dashed")} +
  scale_color_manual("", values = c("Real" = "black", "LCA" = "grey50",
                                    "realizado" = "#003853", "base" = "#12d0ff",
                                    "quente_seco" = "#e4572e", "frio_umido" = "#76b041")) +
  labs(title = glue("Melhor modelo ({melhor$agrupamento} / {melhor$.model}) por cenário"),
       subtitle = "Volume medido (milhões m³)") +
  tema

g_cenarios

# Melhor modelo por superintendência
g_superint = real_fc %>%
  filter(agrupamento == melhor$agrupamento, .model == melhor$.model, cenario == cenario_selecao) %>%
  group_by(cd_regiao_adj, periodo) %>%
  summarise(vol_med_fit = sum(vol_med_fit)/10^6, .groups = "drop") %>%
  ggplot(aes(x = periodo)) +
  geom_line(data = real_hist %>%
              filter(year(periodo) >= 2025) %>%
              group_by(cd_regiao_adj, periodo) %>%
              summarise(vol_med = sum(vol_med, na.rm = T)/10^6, .groups = "drop"),
            aes(y = vol_med, color = "Real"), lwd = 0.8) +
  geom_line(aes(y = vol_med_fit, color = "Forecast"), lwd = 0.8) +
  facet_wrap(~cd_regiao_adj, scales = "free_y") +
  scale_color_manual("", values = c("Real" = "black", "Forecast" = "#12d0ff")) +
  labs(title = glue("Real x forecast por superintendência - {melhor$agrupamento} / {melhor$.model}"),
       subtitle = "Volume medido (milhões m³)") +
  tema

g_superint

# Mapa de calor da métrica de seleção
g_heat = acc[[nivel_selecao]] %>%
  filter(cenario == cenario_selecao) %>%
  ggplot(aes(x = .model, y = agrupamento, fill = .data[[metrica_selecao]])) +
  geom_tile(color = "white") +
  geom_text(aes(label = number(.data[[metrica_selecao]], 0.01)), size = 3) +
  scale_fill_gradient(low = "#12d0ff", high = "#f9b17f") +
  labs(title = glue("{metrica_selecao} - nível {nivel_selecao} - cenário {cenario_selecao}")) +
  tema


g_heat


## 3.5 Elasticidades -----------------------------------------------------------

# Termos em log -> coeficiente já é elasticidade.
# Termos em nível -> semi-elasticidade; elasticidade = beta x média no treino.
termos = tribble(
  ~term,           ~var,                            ~em_log, ~sinal_esperado,
  "log(temp_med)", "Temperatura",                   TRUE,     1,
  "log(prec_tot)", "Precipitação",                  TRUE,    -1,
  "lag_nv_sim",    "Nível dos Reservatórios (t-1)", FALSE,    1,
  "tarifa",        "IRT real (Base 100)",           FALSE,   -1,
  "log(caged)",    "CAGED (estoque)",               TRUE,     1
)

flag_iqr = function(x, k = 2) {
  q1 = quantile(x, 0.25, na.rm = TRUE)
  q3 = quantile(x, 0.75, na.rm = TRUE)
  iqr = q3 - q1
  x < (q1 - k * iqr) | x > (q3 + k * iqr)
}

coeficientes = imap_dfr(res, function(r, agrup) {

  # médias de treino (para converter semi-elasticidade) e peso = volume 12m
  medias = r$train %>%
    as_tibble() %>%
    group_by(across(all_of(chaves_ts))) %>%
    summarise(tarifa_med = mean(tarifa),
              lag_nv_med = mean(lag_nv_sim),
              peso = sum(tail(vol_ajust, 12), na.rm = T),
              .groups = "drop")

  r$fit_model %>%
    select(all_of(chaves_ts), starts_with("arima")) %>%
    coef() %>%
    inner_join(termos, by = "term") %>%
    left_join(medias, by = chaves_ts) %>%
    mutate(agrupamento = agrup, .before = 1)
}) %>%
  mutate(elasticidade = case_when(em_log ~ estimate,
                                  term == "tarifa" ~ estimate * tarifa_med,
                                  term == "lag_nv_sim" ~ estimate * lag_nv_med),
         # p-valor NA quando a matriz de covariância do ARIMA não é positiva
         # definida (aviso "NaNs produced" no fit): tratado como não significante
         sig = factor(if_else(coalesce(p.value <= 0.05, FALSE), "Significante", "Não Significante")),
         sinal_ok = sign(estimate) == sinal_esperado) %>%
  group_by(agrupamento, .model, term) %>%
  mutate(outlier = flag_iqr(elasticidade)) %>%
  ungroup()

niveis_elast = list(geral = character(0),
                    categoria = "categoria_detalhe",
                    recorte = "recorte",
                    superintendencia = "cd_regiao_adj",
                    categoria_recorte = c("categoria_detalhe", "recorte"))

resume_elast = function(nivel) {
  coeficientes %>%
    group_by(agrupamento, .model, var, term, across(all_of(nivel))) %>%
    summarise(n_series = n(),
              n_outlier = sum(outlier),
              mediana = median(elasticidade[!outlier]),
              media_ponderada = weighted.mean(elasticidade[!outlier], peso[!outlier]),
              p25 = quantile(elasticidade[!outlier], 0.25),
              p75 = quantile(elasticidade[!outlier], 0.75),
              perc_signif = mean(sig[!outlier] == "Significante"),
              perc_sinal_esperado = mean(sinal_ok[!outlier]),
              .groups = "drop")
}

elasticidades = map(niveis_elast, resume_elast)

elasticidades$geral %>%
  filter(agrupamento == melhor$agrupamento) %>%
  print(n = 50)


gera_graf = function(base, filtra_outlier = T) {

  if (filtra_outlier) {
    base = base %>%
      filter(!outlier)
  }

  base = base %>%
    group_by(recorte, term, .model) %>%
    mutate(estimate_median = median(elasticidade)) %>%
    ungroup()

  base %>%
    ggplot(aes(x = "", y = elasticidade)) +
    facet_grid(recorte ~ .model) +
    geom_violin(linewidth = 0.6) +
    geom_jitter(aes(color = sig),
                alpha = 0.6,
                size = 3,
                width = 0.2) +
    geom_hline(data = base %>% distinct(.model, term, recorte, estimate_median),
               aes(yintercept = estimate_median,
                   color = "Mediana"),
               linewidth = 1.5) +
    geom_label(data = base %>% distinct(.model, term, recorte, estimate_median),
               aes(y = estimate_median,
                   label = number(estimate_median, 0.001),
                   color = "Mediana"),
               show.legend = F,
               fontface = "bold") +
    scale_color_manual("",
                       values = c("Significante" = "#12d0ff",
                                  "Não Significante" = "#f9b17f",
                                  "Mediana" = "#003853")) +
    labs(title = glue("Elasticidade - {first(base$var)}"),
         subtitle = glue("Agrupamento: {first(base$agrupamento)}")) +
    tema
}

graf_elast = coeficientes %>%
  filter(agrupamento == melhor$agrupamento) %>%
  split(.$term) %>%
  map(gera_graf)

graf_elast

# Mediana e intervalo interquartil por agregação (melhor agrupamento/modelo)
graf_elast_nivel = function(nivel) {
  elasticidades[[nivel]] %>%
    filter(agrupamento == melhor$agrupamento,
           .model == if (str_detect(melhor$.model, "arima_[1-5]")) melhor$.model else "arima_5") %>%
    ggplot(aes(x = .data[[niveis_elast[[nivel]][1]]], y = mediana)) +
    geom_hline(yintercept = 0, color = "grey60") +
    geom_pointrange(aes(ymin = p25, ymax = p75), color = "#003853") +
    facet_wrap(~var, scales = "free_x", nrow = 1) +
    coord_flip() +
    labs(title = glue("Elasticidade por {nivel}"),
         subtitle = "Mediana e intervalo interquartil (sem outliers)") +
    tema
}

graf_elast_niveis = map(c("categoria", "recorte", "superintendencia"), graf_elast_nivel) %>%
  set_names(c("categoria", "recorte", "superintendencia"))

graf_elast_niveis


## 3.6 Estatísticas dos melhores modelos --------------------------------------

melhores = ranking %>%
  filter(agrupamento != "LCA") %>%
  slice_head(n = n_melhores) %>%
  select(rank, agrupamento, .model)

# Diagnóstico por série: especificação, AICc, desvio-padrão residual (em log
# ~ erro % no ajuste) e Ljung-Box (24 lags) nas inovações
diag_series = function(agrup, mod) {

  fit = res[[agrup]]$fit_model %>%
    select(all_of(chaves_ts), all_of(mod))

  espec = fit %>%
    as_tibble() %>%
    transmute(across(all_of(chaves_ts)),
              espec = str_remove_all(format(.data[[mod]]), "^<|>$"))

  n_arma = fit %>%
    coef() %>%
    filter(str_detect(term, "^s?(ar|ma)\\d")) %>%
    count(across(all_of(chaves_ts)), name = "dof")

  ljung = fit %>%
    augment() %>%
    as_tibble() %>%
    group_by(across(all_of(chaves_ts))) %>%
    summarise(innov = list(.innov), .groups = "drop") %>%
    left_join(n_arma, by = chaves_ts) %>%
    mutate(dof = coalesce(dof, 0L),
           lb_pvalor = map2_dbl(innov, dof, ~ tryCatch(
             Box.test(na.omit(.x), lag = 24, type = "Ljung-Box", fitdf = .y)$p.value,
             error = function(e) NA_real_))) %>%
    select(-innov)

  acc_serie = fit_x_real %>%
    filter(agrupamento == agrup, .model == mod, cenario == cenario_selecao) %>%
    group_by(across(all_of(chaves_ts))) %>%
    summarise(WAPE = sum(abs(vol_med_fit - vol_med_real))/sum(vol_med_real) * 100,
              Vies = sum(vol_med_fit - vol_med_real)/sum(vol_med_real) * 100,
              vol_teste = sum(vol_med_real),
              .groups = "drop")

  fit %>%
    glance() %>%
    select(all_of(chaves_ts), any_of(c("sigma2", "AICc"))) %>%
    left_join(espec, by = chaves_ts) %>%
    left_join(ljung, by = chaves_ts) %>%
    left_join(acc_serie, by = chaves_ts) %>%
    mutate(agrupamento = agrup, .model = mod, .before = 1)
}

estat_series = map2_dfr(melhores$agrupamento, melhores$.model, diag_series) %>%
  # SNAIVE não tem AICc
  mutate(AICc = if ("AICc" %in% names(.)) AICc else NA_real_)

estat_melhores = estat_series %>%
  group_by(agrupamento, .model) %>%
  summarise(n_series = n(),
            perc_null_model = mean(espec == "NULL model"),
            perc_diferenciada = mean(str_detect(espec, "ARIMA\\(\\d,[1-9]")),
            perc_sazonal = mean(str_detect(espec, "\\)\\(")),
            AICc_mediano = median(AICc, na.rm = T),
            sd_residual_mediano = median(sqrt(sigma2), na.rm = T),
            perc_ljung_box_ok = mean(lb_pvalor > 0.05, na.rm = T),
            WAPE_serie_mediano = median(WAPE, na.rm = T),
            WAPE_serie_p90 = quantile(WAPE, 0.9, na.rm = T),
            especificacoes_comuns = names(sort(table(espec), decreasing = T))[1:3] %>%
              na.omit() %>%
              paste(collapse = " | "),
            .groups = "drop") %>%
  left_join(resumo_fallback %>%
              filter(fallback != "modelo") %>%
              group_by(agrupamento, .model) %>%
              summarise(perc_vol_fallback = sum(perc_vol), .groups = "drop"),
            by = c("agrupamento", ".model")) %>%
  mutate(perc_vol_fallback = coalesce(perc_vol_fallback, 0)) %>%
  right_join(melhores, by = c("agrupamento", ".model")) %>%
  relocate(rank) %>%
  arrange(rank)

# Acurácia dos melhores em todos os níveis e cenários
estat_melhores_acc = imap_dfr(acc, ~ mutate(.x, nivel = .y, .before = 1)) %>%
  inner_join(melhores, by = c("agrupamento", ".model")) %>%
  relocate(rank) %>%
  arrange(rank, nivel, cenario)

# Coeficientes dos melhores (elasticidade geral)
estat_melhores_coef = elasticidades$geral %>%
  inner_join(melhores, by = c("agrupamento", ".model")) %>%
  relocate(rank) %>%
  arrange(rank, var)

estat_melhores %>%
  select(rank:.model, n_series, perc_ljung_box_ok, sd_residual_mediano,
         WAPE_serie_mediano, perc_vol_fallback) %>%
  print()


# 4. EXPORTAÇÃO ----------------------------------------------------------------

write_xlsx(
  c(list(ranking = ranking,
         mape_total_wide = acc_bu,
         melhores_resumo = estat_melhores,
         melhores_acuracia = estat_melhores_acc,
         melhores_elasticidade = estat_melhores_coef,
         melhores_series = estat_series),
    set_names(acc, paste0("acc_", names(acc))),
    list(acc_detalhe_superint = acc_detalhe_superint,
         series = resumo_series,
         fallback = resumo_fallback,
         outliers = resumo_outliers)),
  file.path(dir_saida, glue("01_Acuracia_Residencial_{var_vol}_{sufixo}.xlsx")))

write_xlsx(
  list(real_x_forecast = real_fc %>% mutate(periodo = as.Date(periodo)),
       real_x_forecast_total = fc_total %>% mutate(periodo = as.Date(periodo)),
       real_historico = real_hist %>% mutate(periodo = as.Date(periodo))),
  file.path(dir_saida, glue("02_Real_x_Forecast_Residencial_{var_vol}_{sufixo}.xlsx")))

write_xlsx(
  list(cenarios = cenarios_exog %>% mutate(periodo = as.Date(periodo))),
  file.path(dir_saida, glue("03_Cenarios_Exogenas_{sufixo}.xlsx")))

write_xlsx(
  c(set_names(elasticidades, paste0("elast_", names(elasticidades))),
    list(coeficientes = coeficientes)),
  file.path(dir_saida, glue("04_Elasticidades_Residencial_{var_vol}_{sufixo}.xlsx")))

salva_graf = function(g, nome, w = 14, h = 8) {
  ggsave(file.path(dir_saida, "graficos", glue("{nome}_{sufixo}.png")),
         g, width = w, height = h, dpi = 150)
}

salva_graf(g_outlier, "00_outliers", h = 9)
salva_graf(g_cenarios_exog, "01_cenarios_exogenas")
salva_graf(g_real_fc, "02_real_x_forecast_modelos")
salva_graf(g_cenarios, "03_melhor_modelo_cenarios")
salva_graf(g_superint, "04_melhor_modelo_superintendencia", w = 16, h = 10)
salva_graf(g_heat, "05_heatmap_acuracia")
iwalk(graf_elast, ~ salva_graf(.x, glue("06_elasticidade_{make.names(.y)}"), w = 16, h = 9))
iwalk(graf_elast_niveis, ~ salva_graf(.x, glue("07_elasticidade_por_{.y}"), w = 16, h = 7))

saveRDS(list(res = res, fit_x_real = fit_x_real, acc = acc, ranking = ranking,
             coeficientes = coeficientes, elasticidades = elasticidades),
        file.path(dir_saida, glue("BT_{var_vol}_{sufixo}.rds")))

toc()
