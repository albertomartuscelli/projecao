
# =============================================================================
# FUNÇÕES COMPARTILHADAS - BACKTESTING E PROJEÇÃO DE CONSUMO (VOLUME/ECONOMIA)
#
# Usado por:
#   01_Backtesting_Residencial.R
#   02_Backtesting_Nao_Residencial.R
#   03_Projecao.R
#
# Conteúdo:
#   0. Pacotes, tema e definições (alvos, agrupamentos, modelos)
#   1. Importação e ETL
#   2. Tratamento de outliers
#   3. Séries por agrupamento
#   4. Exógenas ex-ante (cenários)
#   5. Ajuste, previsão e fallback
#   6. Acurácia
#   7. Elasticidades
#   8. LCA
#   9. Backtest completo de um alvo
#  10. Gráficos e exportação
# =============================================================================

pacman::p_load(tidyverse, data.table, readxl, writexl, glue, zoo,
               tsibble, fable, fabletools, feasts, forecast, scales,
               future, future.apply, tictoc)

# Limite de dados enviados aos workers no fit (padrão do future: 500 MB)
options(future.globals.maxSize = 4 * 1024^3)


# 0. DEFINIÇÕES ----------------------------------------------------------------

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

cores_cenario = c("Real" = "black", "Imputado" = "grey60", "LCA" = "#f68c1f",
                  "realizado" = "#003853", "base" = "#12d0ff",
                  "quente_seco" = "#e4572e", "frio_umido" = "#76b041")

# Alvos: volume e economias de cada conceito
alvos_def = list(
  med_agua = c(vol = "vol_med_agua", econ = "n_economias_agua"),
  fat_agua = c(vol = "vol_fat_agua", econ = "n_economias_agua"),
  med_esg  = c(vol = "vol_med_esg",  econ = "n_economias_esg"),
  fat_esg  = c(vol = "vol_fat_esg",  econ = "n_economias_esg")
)

# Chave das séries modeladas. Toda regra de agrupamento mantém superintendência,
# categoria e recorte, para que os agrupamentos sejam comparáveis nesses níveis.
# No não residencial o recorte é sempre "Total".
chaves_ts = c("cd_regiao_adj", "grupo", "categoria_detalhe", "recorte")

regressoras = c("temp_med", "prec_tot", "lag_nv_sim", "tarifa", "caged")

mun_atc = c("SAO PAULO", "OSASCO", "GUARULHOS")

regras_agrupamento = list(
  # SP/Osasco/Guarulhos por ATC, municípios A individuais, B/C por regional
  G1_original = quo(case_when(municipio %in% mun_atc ~ paste0(municipio, "_", cd_atc),
                              classificacao_abc == "A" ~ municipio,
                              T ~ paste0("cluster_", cd_regiao))),
  # Uma série por superintendência
  G2_superintendencia = quo(cd_regiao_adj),
  # Uma série por município (SP/Osasco/Guarulhos por ATC) = nível da chave
  G3_municipio = quo(if_else(municipio %in% mun_atc,
                             paste0(municipio, "_", cd_atc),
                             municipio))
)

modelos_candidatos = list(
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

# Modelos que já têm a tarifa como regressora (na projeção, não recebem o
# ajuste de elasticidade, para não contar o efeito duas vezes)
modelos_com_tarifa = c("arima_4", "arima_5")

# Termos em log -> coeficiente já é elasticidade.
# Termos em nível -> semi-elasticidade; elasticidade = beta x média no treino.
termos_elast = tribble(
  ~term,           ~var,                            ~em_log, ~sinal_esperado,
  "log(temp_med)", "Temperatura",                   TRUE,     1,
  "log(prec_tot)", "Precipitação",                  TRUE,    -1,
  "lag_nv_sim",    "Nível dos Reservatórios (t-1)", FALSE,    1,
  "tarifa",        "IRT real (Base 100)",           FALSE,   -1,
  "log(caged)",    "CAGED (estoque)",               TRUE,     1
)

# Texto seguro para nome de arquivo
nome_arq = function(x) {
  x %>%
    stringi::stri_trans_general("Latin-ASCII") %>%
    str_replace_all("[^A-Za-z0-9]+", "_")
}

# Filtra um mable (ou tibble) pelas chaves presentes em outra tabela
filtra_chaves = function(df, chaves_df) {
  k = do.call(paste, c(distinct(as_tibble(chaves_df), across(all_of(chaves_ts))), sep = "|"))
  df %>%
    filter(do.call(paste, c(pick(all_of(chaves_ts)), sep = "|")) %in% k)
}


# 1. IMPORTAÇÃO E ETL ----------------------------------------------------------

carrega_base = function(arq, categorias) {

  base = fread(arq, encoding = "UTF-8") %>%
    as_tibble()

  # Compatibilidade: tarifa pode vir como irt_real
  if ("irt_real" %in% names(base) & !"tarifa" %in% names(base)) {
    base = rename(base, tarifa = irt_real)
  }

  base = base %>%
    filter(categoria %in% categorias) %>%
    mutate(periodo = as.Date(periodo),
           chave = paste(cd_regiao, municipio, cd_atc, categoria_detalhe, recorte, sep = "_"),
           cd_regiao_adj = if_else(municipio == "SAO PAULO",
                                   paste0("SP_", cd_regiao),
                                   cd_regiao))

  stopifnot(nrow(base) > 0,
            !anyDuplicated(base[c("chave", "periodo")]))

  base
}

# Exógenas municipais (1 valor por município x mês), sem buracos
exog_municipal = function(base) {
  base %>%
    distinct(municipio, periodo, prec_tot, temp_med, caged) %>%
    group_by(municipio) %>%
    complete(periodo = seq(min(base$periodo), max(base$periodo), by = "month")) %>%
    arrange(periodo, .by_group = TRUE) %>%
    mutate(across(c(prec_tot, temp_med, caged), ~ na.approx(., na.rm = FALSE, rule = 2))) %>%
    ungroup()
}

# Exógenas globais (1 valor por mês)
exog_global = function(base) {
  glob = base %>%
    distinct(periodo, tarifa, nv_sim, lag_nv_sim) %>%
    arrange(periodo)
  stopifnot(!anyDuplicated(glob$periodo))
  glob
}


# 2. TRATAMENTO DE OUTLIERS ----------------------------------------------------

# tsclean robusto: séries curtas usam frequência 1; se falhar, só interpola.
# outliers = FALSE apenas interpola zeros/negativos (o log exige consumo > 0).
limpa_serie = function(x, freq = 12, outliers = TRUE) {
  x = as.numeric(x)
  x[!is.finite(x) | x <= 0] = NA
  if (sum(!is.na(x)) < 4) return(x)
  x_ts = ts(x, frequency = if (length(x) >= 2 * freq + 1) freq else 1)
  out = tryCatch(as.numeric(if (outliers) forecast::tsclean(x_ts) else forecast::na.interp(x_ts)),
                 error = function(e) NULL)
  if (is.null(out)) {
    out = tryCatch(as.numeric(na.approx(x, na.rm = FALSE, rule = 2)),
                   error = function(e) x)
  }
  out
}

# Limpa só a janela (treino); fora dela mantém o valor bruto
limpa_janela = function(x, janela, outliers) {
  out = as.numeric(x)
  out[!is.finite(out) | out <= 0] = NA
  if (any(janela)) out[janela] = limpa_serie(x[janela], outliers = outliers)
  out
}

# Base por chave para um alvo, com consumo/economia tratado até `fim_limpeza`.
# Linhas sem volume ou sem economias (ex.: esgoto medido ausente em mar-abr/26,
# chaves sem esgoto) saem; os buracos são interpolados só no consumo modelado.
prepara_chave = function(base, alvo, fim_limpeza,
                         tratar_outliers = TRUE, limpar_economias = FALSE) {

  def = alvos_def[[alvo]]

  base %>%
    transmute(chave, cd_regiao, cd_regiao_adj, municipio, cd_atc, categoria_detalhe,
              recorte, classificacao_abc, periodo,
              vol = .data[[def[["vol"]]]],
              econ = .data[[def[["econ"]]]]) %>%
    filter(!is.na(vol), !is.na(econ), econ > 0) %>%
    group_by(chave) %>%
    complete(periodo = seq(min(periodo), max(periodo), by = "month")) %>%
    fill(cd_regiao, cd_regiao_adj, municipio, cd_atc, categoria_detalhe, recorte,
         classificacao_abc, .direction = "downup") %>%
    arrange(periodo, .by_group = TRUE) %>%
    mutate(preenchido = is.na(econ),
           consumo = vol/econ,
           janela = periodo <= fim_limpeza,
           consumo_ajust = limpa_janela(consumo, janela, tratar_outliers),
           econ_ajust = if (limpar_economias) limpa_janela(econ, janela, TRUE) else econ) %>%
    ungroup() %>%
    # buracos internos servem só para a limpeza; não viram volume
    filter(!preenchido) %>%
    mutate(econ_ajust = coalesce(econ_ajust, econ),
           consumo_ajust = coalesce(consumo_ajust, consumo),
           vol_ajust = coalesce(econ_ajust * consumo_ajust, vol),
           outlier = abs(consumo_ajust - consumo) > 1e-8 * pmax(1, abs(consumo))) %>%
    select(-preenchido, -janela)
}

resumo_outliers = function(base_chave, fim_limpeza) {
  base_chave %>%
    mutate(janela = if_else(periodo <= fim_limpeza, "treino", "teste/projecao")) %>%
    group_by(janela) %>%
    summarise(perc_obs_ajustadas = mean(outlier, na.rm = T),
              var_vol_total = sum(vol_ajust, na.rm = T)/sum(vol, na.rm = T) - 1,
              .groups = "drop")
}

graf_outliers = function(base_chave, titulo) {
  base_chave %>%
    group_by(periodo, categoria_detalhe) %>%
    summarise(Bruto = sum(vol, na.rm = T)/sum(econ, na.rm = T),
              Ajustado = sum(vol_ajust, na.rm = T)/sum(econ_ajust, na.rm = T),
              .groups = "drop") %>%
    pivot_longer(c(Bruto, Ajustado)) %>%
    ggplot(aes(x = periodo, y = value, color = name)) +
    geom_line() +
    facet_wrap(~categoria_detalhe, scales = "free_y", ncol = 1) +
    scale_color_manual("", values = c("Bruto" = "black", "Ajustado" = "red")) +
    labs(title = titulo, subtitle = "Consumo médio (m³/economia) - bruto x ajustado") +
    tema
}


# 3. SÉRIES POR AGRUPAMENTO ----------------------------------------------------

monta_base_ts = function(base_chave, regra, mun_exog, glob_exog) {

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
    # buracos internos: interpola consumo, economias e exógenas
    # (o volume real continua NA nesses meses: `preenchido`)
    fill_gaps() %>%
    as_tibble() %>%
    group_by(across(all_of(chaves_ts))) %>%
    arrange(periodo, .by_group = TRUE) %>%
    mutate(preenchido = is.na(vol_ajust),
           consumo = vol_ajust/econ_ajust,
           consumo = if_else(is.finite(consumo) & consumo > 0, consumo, NA_real_),
           across(c(consumo, econ_ajust, prec_tot, temp_med, caged),
                  ~ na.approx(., na.rm = FALSE, rule = 2))) %>%
    ungroup() %>%
    left_join(glob_exog %>% mutate(periodo = yearmonth(periodo)), by = "periodo") %>%
    as_tsibble(key = all_of(chaves_ts), index = periodo)
}

# Séries elegíveis para modelo: histórico mínimo e ativas no fim do histórico
resumo_series = function(base_ts, fim_hist, min_obs) {
  base_ts %>%
    as_tibble() %>%
    group_by(across(all_of(chaves_ts))) %>%
    summarise(n_hist = sum(periodo <= fim_hist & !is.na(consumo)),
              ult_hist = if (any(periodo <= fim_hist)) max(periodo[periodo <= fim_hist]) else NA,
              vol_12m = sum(vol_bruto[periodo <= fim_hist & periodo > fim_hist - 12], na.rm = T),
              .groups = "drop") %>%
    mutate(ativa = !is.na(ult_hist) & ult_hist == fim_hist,
           elegivel = ativa & n_hist >= min_obs)
}


# 4. EXÓGENAS EX-ANTE ----------------------------------------------------------

# Nível dos reservatórios projetado (série única). lag_nv_sim em t = nv_sim em
# t-1, então o 1º mês projetado já é conhecido.
projeta_nivel = function(glob_exog, fim_hist, periodos) {
  hist = glob_exog %>%
    filter(yearmonth(periodo) <= fim_hist)
  fc = hist$nv_sim %>%
    ts(frequency = 12,
       start = c(year(min(hist$periodo)), month(min(hist$periodo)))) %>%
    auto.arima() %>%
    forecast::forecast(h = length(periodos)) %>%
    .$mean %>%
    as.numeric() %>%
    pmin(1) %>% pmax(0)
  tibble(periodo = periodos,
         nv_sim = fc,
         lag_nv_sim = c(last(hist$nv_sim), head(fc, -1)))
}

# Cenários ex-ante das exógenas por série:
#   base        : clima = média do mês no histórico; CAGED = tendência dos
#                 últimos 12 meses; nível e tarifa vindos de `glob_proj`
#   quente_seco : base com temperatura +1 dp e precipitação -1 dp
#   frio_umido  : base com temperatura -1 dp e precipitação +1 dp
# `grade`: chaves x períodos futuros. `glob_proj`: periodo, lag_nv_sim, tarifa.
cenarios_ex_ante = function(hist, grade, fim_hist, glob_proj) {

  hist = as_tibble(hist) %>%
    filter(periodo <= fim_hist)

  clim = hist %>%
    mutate(mes = month(periodo)) %>%
    group_by(across(all_of(chaves_ts)), mes) %>%
    summarise(temp_mu = mean(temp_med), temp_sd = coalesce(sd(temp_med), 0),
              prec_mu = mean(prec_tot), prec_sd = coalesce(sd(prec_tot), 0),
              prec_min = min(prec_tot),
              .groups = "drop")

  caged_tend = hist %>%
    group_by(across(all_of(chaves_ts))) %>%
    arrange(periodo, .by_group = TRUE) %>%
    summarise(caged_T = last(caged),
              g = if (n() >= 13) (last(caged)/nth(caged, -13))^(1/12) - 1 else 0,
              .groups = "drop") %>%
    mutate(g = if_else(is.finite(g), g, 0))

  base = grade %>%
    as_tibble() %>%
    select(all_of(chaves_ts), periodo) %>%
    mutate(mes = month(periodo),
           k = as.numeric(periodo) - as.numeric(fim_hist)) %>%
    left_join(clim, by = c(chaves_ts, "mes")) %>%
    left_join(caged_tend, by = chaves_ts) %>%
    left_join(glob_proj %>% select(periodo, lag_nv_sim, tarifa), by = "periodo") %>%
    mutate(caged = caged_T * (1 + g)^k)

  list(
    base        = base %>%
      mutate(temp_med = temp_mu,
             prec_tot = prec_mu),
    quente_seco = base %>%
      mutate(temp_med = temp_mu + temp_sd,
             prec_tot = pmax(prec_mu - prec_sd, prec_min)),
    frio_umido  = base %>%
      mutate(temp_med = pmax(temp_mu - temp_sd, 1),
             prec_tot = prec_mu + prec_sd)
  ) %>%
    map(~ select(.x, all_of(chaves_ts), periodo, all_of(regressoras)))
}

resumo_cenarios = function(cenarios, pesos) {
  imap_dfr(cenarios, function(nd, nm) {
    nd %>%
      as_tibble() %>%
      left_join(pesos, by = chaves_ts) %>%
      group_by(periodo) %>%
      summarise(temp_med = weighted.mean(temp_med, peso, na.rm = T),
                prec_tot = weighted.mean(prec_tot, peso, na.rm = T),
                caged = sum(caged),
                lag_nv_sim = first(lag_nv_sim),
                tarifa = first(tarifa),
                .groups = "drop") %>%
      mutate(cenario = nm)
  })
}


# 5. AJUSTE, PREVISÃO E FALLBACK -----------------------------------------------

# multisession só no fit; tryCatch garante a volta ao sequential
ajusta_modelos = function(dados, modelos, n_workers) {
  plan(multisession, workers = n_workers)
  tic("Fit")
  fit = tryCatch(dados %>% model(!!!modelos),
                 finally = plan(sequential))
  toc()
  fit
}

# Forecast sempre sequencial: copiar os modelos para os workers custa mais que
# prever (e pode estourar future.globals.maxSize)
prever = function(fit, cenarios) {
  plan(sequential)
  imap_dfr(cenarios, function(nd, nm) {
    nd = as_tsibble(nd, key = all_of(chaves_ts), index = periodo)
    fit %>%
      filtra_chaves(nd) %>%
      fabletools::forecast(new_data = nd) %>%
      as_tibble() %>%
      select(all_of(chaves_ts), .model, periodo, consumo_prev = .mean) %>%
      mutate(cenario = nm)
  })
}

# Fallback para séries sem modelo (curtas, iniciadas recentemente, ou ARIMA que
# falhou): sazonal ingênuo -> média dos últimos 12 meses -> média do
# segmento (superintendência x categoria x recorte) -> categoria x recorte
monta_fallback = function(base_ts, grade, fim_hist) {

  hist = base_ts %>%
    as_tibble() %>%
    filter(periodo <= fim_hist, !preenchido, !is.na(consumo))

  ult12 = hist %>%
    group_by(across(all_of(chaves_ts))) %>%
    slice_max(periodo, n = 12) %>%
    summarise(consumo_media12 = mean(consumo), .groups = "drop")

  seg = hist %>%
    filter(periodo > fim_hist - 12) %>%
    group_by(cd_regiao_adj, categoria_detalhe, recorte) %>%
    summarise(consumo_seg = sum(vol_ajust)/sum(econ_ajust), .groups = "drop")

  cat_rec = hist %>%
    filter(periodo > fim_hist - 12) %>%
    group_by(categoria_detalhe, recorte) %>%
    summarise(consumo_cat_rec = sum(vol_ajust)/sum(econ_ajust), .groups = "drop")

  grade %>%
    distinct(across(all_of(chaves_ts)), periodo) %>%
    mutate(periodo_snaive = periodo - 12 * ceiling((as.numeric(periodo) - as.numeric(fim_hist))/12)) %>%
    left_join(hist %>% select(all_of(chaves_ts), periodo_snaive = periodo, consumo_snaive = consumo),
              by = c(chaves_ts, "periodo_snaive")) %>%
    left_join(ult12, by = chaves_ts) %>%
    left_join(seg, by = c("cd_regiao_adj", "categoria_detalhe", "recorte")) %>%
    left_join(cat_rec, by = c("categoria_detalhe", "recorte")) %>%
    mutate(consumo_fb = coalesce(consumo_snaive, consumo_media12, consumo_seg, consumo_cat_rec)) %>%
    select(all_of(chaves_ts), periodo, consumo_fb)
}

# Backtest de um agrupamento: base, fit, forecast por cenário e fallback
backtest_agrupamento = function(base_chave, agrup, cfg, ctx) {

  message(glue("\n===== {ctx$rotulo} | {agrup} ====="))
  tic(agrup)

  base_ts = monta_base_ts(base_chave, regras_agrupamento[[agrup]], ctx$mun_exog, ctx$glob_exog)

  info_series = resumo_series(base_ts, ctx$fim_treino, cfg$min_obs_treino)

  message(glue("Séries: {nrow(info_series)} | elegíveis p/ modelo: {sum(info_series$elegivel)}"))

  eleg = info_series %>% filter(elegivel)

  train = base_ts %>%
    filter(periodo <= ctx$fim_treino) %>%
    semi_join(eleg, by = chaves_ts)

  new_data = base_ts %>%
    filter(periodo %in% ctx$periodos_teste) %>%
    semi_join(eleg, by = chaves_ts)

  # FIT
  arq_fit = file.path(cfg$dir_saida, "modelos", glue("fit_{ctx$rotulo}_{agrup}.rds"))

  if (cfg$reaproveitar_fit & file.exists(arq_fit)) {
    fit_model = readRDS(arq_fit)
  } else {
    fit_model = ajusta_modelos(train, modelos_candidatos, cfg$n_workers)
    saveRDS(fit_model, arq_fit)
  }

  # FORECAST: realizado (ex-post) + cenários ex-ante
  cenarios = c(list(realizado = new_data %>%
                      as_tibble() %>%
                      select(all_of(chaves_ts), periodo, all_of(regressoras))),
               cenarios_ex_ante(train, new_data, ctx$fim_treino, ctx$glob_proj))

  fc = prever(fit_model, cenarios)

  # Real do teste (só meses observados) x todos modelos x cenários
  teste_real = base_ts %>%
    as_tibble() %>%
    filter(periodo %in% ctx$periodos_teste, !preenchido)

  grade = teste_real %>%
    select(all_of(chaves_ts), periodo) %>%
    crossing(.model = names(modelos_candidatos), cenario = names(cenarios))

  fallback = monta_fallback(base_ts, grade, ctx$fim_treino)

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
    mutate(n_economias  = if (cfg$alvo_real == "ajustado") econ_ajust else econ_bruto,
           vol_med_real = if (cfg$alvo_real == "ajustado") vol_ajust else vol_bruto,
           vol_med_fit  = consumo_prev * n_economias,
           agrupamento  = agrup) %>%
    select(agrupamento, cenario, .model, all_of(chaves_ts), periodo,
           n_economias, vol_med_real, vol_med_fit, fallback)

  toc()

  list(base_ts = base_ts,
       info_series = info_series,
       train = train,
       fit_model = fit_model,
       cenarios = cenarios,
       fit_x_real = fit_x_real)
}


# Economias projetadas por série: ETS amortecido no log (séries com pelo menos
# `min_obs` meses); nas demais, repete o último valor
projeta_economias = function(base_ts, ativas, periodos, fim_hist, n_workers, min_obs = 24) {

  hist = base_ts %>%
    filter(periodo <= fim_hist) %>%
    semi_join(ativas, by = chaves_ts) %>%
    select(all_of(chaves_ts), periodo, econ = econ_ajust)

  longas = hist %>%
    as_tibble() %>%
    count(across(all_of(chaves_ts))) %>%
    filter(n >= min_obs)

  fc = hist %>%
    semi_join(longas, by = chaves_ts) %>%
    ajusta_modelos(list(ets = ETS(log(econ) ~ error("A") + trend("Ad") + season("N"))),
                   n_workers) %>%
    fabletools::forecast(h = length(periodos)) %>%
    as_tibble() %>%
    select(all_of(chaves_ts), periodo, econ_prev = .mean)

  ult = hist %>%
    as_tibble() %>%
    group_by(across(all_of(chaves_ts))) %>%
    slice_max(periodo, n = 1) %>%
    ungroup() %>%
    select(all_of(chaves_ts), econ_ult = econ)

  ativas %>%
    select(all_of(chaves_ts)) %>%
    crossing(periodo = periodos) %>%
    left_join(fc, by = c(chaves_ts, "periodo")) %>%
    left_join(ult, by = chaves_ts) %>%
    mutate(econ_metodo = if_else(is.finite(econ_prev), "ets_amortecido", "ultimo_valor"),
           n_economias = if_else(is.finite(econ_prev), econ_prev, econ_ult)) %>%
    select(-econ_prev, -econ_ult)
}


# 6. ACURÁCIA ------------------------------------------------------------------

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
calc_acc = function(base, nivel, lca = NULL, detalhe = FALSE) {

  if (!is.null(lca$x_real) && all(nivel %in% lca$chaves)) {
    base = bind_rows(base, lca$x_real)
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

# Pergunta 1 - qual o melhor modelo? (melhor agrupamento de cada modelo)
tabela_modelos = function(acc_sel, metrica) {
  acc_sel %>%
    filter(agrupamento != "LCA") %>%
    group_by(.model) %>%
    summarise(melhor_agrupamento = agrupamento[which.min(.data[[metrica]])],
              metrica_melhor = min(.data[[metrica]]),
              metrica_media_agrupamentos = mean(.data[[metrica]]),
              .groups = "drop") %>%
    arrange(metrica_melhor) %>%
    mutate(rank = row_number(), .before = 1)
}

# Pergunta 2 - qual a melhor agregação? (melhor modelo de cada agrupamento)
tabela_agregacao = function(acc_sel, metrica, n_series) {
  acc_sel %>%
    filter(agrupamento != "LCA") %>%
    group_by(agrupamento) %>%
    summarise(melhor_modelo = .model[which.min(.data[[metrica]])],
              metrica_melhor = min(.data[[metrica]]),
              metrica_mediana_modelos = median(.data[[metrica]]),
              .groups = "drop") %>%
    left_join(n_series, by = "agrupamento") %>%
    arrange(metrica_melhor) %>%
    mutate(rank = row_number(), .before = 1)
}


# 7. ELASTICIDADES -------------------------------------------------------------

flag_iqr = function(x, k = 2) {
  q1 = quantile(x, 0.25, na.rm = TRUE)
  q3 = quantile(x, 0.75, na.rm = TRUE)
  iqr = q3 - q1
  x < (q1 - k * iqr) | x > (q3 + k * iqr)
}

calc_coeficientes = function(res) {
  imap_dfr(res, function(r, agrup) {

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
      inner_join(termos_elast, by = "term") %>%
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
}

resume_elast = function(coeficientes, nivel) {
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

# Violinos por modelo; `dim` = dimensão das linhas (recorte ou categoria)
gera_graf = function(base, dim, filtra_outlier = T) {

  if (filtra_outlier) {
    base = base %>%
      filter(!outlier)
  }

  base = base %>%
    group_by(across(all_of(c(dim, "term", ".model")))) %>%
    mutate(estimate_median = median(elasticidade)) %>%
    ungroup()

  medianas = base %>%
    distinct(across(all_of(c(".model", "term", dim, "estimate_median"))))

  base %>%
    ggplot(aes(x = "", y = elasticidade)) +
    facet_grid(rows = vars(.data[[dim]]), cols = vars(.model)) +
    geom_violin(linewidth = 0.6) +
    geom_jitter(aes(color = sig),
                alpha = 0.6,
                size = 3,
                width = 0.2) +
    geom_hline(data = medianas,
               aes(yintercept = estimate_median,
                   color = "Mediana"),
               linewidth = 1.5) +
    geom_label(data = medianas,
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

# Mediana e intervalo interquartil por agregação
graf_elast_nivel = function(elast_nivel, var_x, titulo) {
  elast_nivel %>%
    ggplot(aes(x = .data[[var_x]], y = mediana)) +
    geom_hline(yintercept = 0, color = "grey60") +
    geom_pointrange(aes(ymin = p25, ymax = p75), color = "#003853") +
    facet_wrap(~var, scales = "free_x", nrow = 1) +
    coord_flip() +
    labs(title = titulo,
         subtitle = "Mediana e intervalo interquartil (sem outliers)") +
    tema
}

# Diagnóstico por série dos melhores: especificação, AICc, desvio-padrão
# residual (em log ~ erro % no ajuste) e Ljung-Box (24 lags) nas inovações
diag_series = function(res, agrup, mod, fit_x_real, cenario) {

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
    filter(agrupamento == agrup, .model == mod, cenario == !!cenario) %>%
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

resume_diag = function(estat_series, resumo_fallback, melhores) {
  estat_series %>%
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
}


# 8. LCA -----------------------------------------------------------------------

# Previsão da consultoria (vol_med e n_economias). O nível de comparação é
# detectado pelas colunas presentes no arquivo. Volume LCA = consumo LCA x
# economias reais, igual aos modelos.
lca_chaves_possiveis = c("cd_regiao_adj", "cd_regiao", "municipio", "categoria_detalhe", "recorte")

carrega_lca = function(arq) {

  if (is.null(arq) || !file.exists(arq)) {
    message(glue("Arquivo LCA não encontrado ({arq}) - comparação ignorada."))
    return(NULL)
  }

  lca = arq %>%
    fread() %>%
    as_tibble()

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

# Monta a comparação LCA x real no nível do arquivo da LCA
compara_lca = function(lca, base_chave, periodos_teste, alvo_real, cenarios) {

  if (is.null(lca)) return(NULL)

  chaves = attr(lca, "chaves")

  real_lca = base_chave %>%
    mutate(periodo = yearmonth(periodo)) %>%
    filter(periodo %in% periodos_teste) %>%
    group_by(across(all_of(chaves)), periodo) %>%
    summarise(vol_med_real = sum(if (alvo_real == "ajustado") vol_ajust else vol, na.rm = T),
              n_economias = sum(if (alvo_real == "ajustado") econ_ajust else econ, na.rm = T),
              .groups = "drop")

  # consumo do nível = soma do volume / soma das economias
  x_real = real_lca %>%
    left_join(lca %>%
                group_by(across(all_of(chaves)), periodo) %>%
                summarise(consumo_lca = sum(vol_med)/sum(n_economias), .groups = "drop"),
              by = c(chaves, "periodo"))

  cobertura = x_real %>%
    summarise(perc_vol_coberto = sum(vol_med_real[!is.na(consumo_lca)])/sum(vol_med_real))

  message(glue("LCA - chaves: {paste(chaves, collapse = ', ')} | ",
               "volume coberto: {percent(cobertura$perc_vol_coberto, 0.1)}"))

  # Replicado em todos os cenários para aparecer em todas as comparações
  x_real = x_real %>%
    filter(!is.na(consumo_lca)) %>%
    mutate(vol_med_fit = consumo_lca * n_economias,
           agrupamento = "LCA",
           .model = "LCA",
           fallback = "modelo") %>%
    crossing(cenario = cenarios) %>%
    select(-consumo_lca)

  list(x_real = x_real, chaves = chaves, cobertura = cobertura)
}


# 9. BACKTEST COMPLETO DE UM ALVO ----------------------------------------------

executa_backtest = function(base, alvo, cfg) {

  rotulo = nome_arq(glue("{cfg$segmento}_{alvo}_{format(cfg$periodo_corte, '%Y%m')}"))
  tic(rotulo)

  dir.create(file.path(cfg$dir_saida, "graficos"), recursive = TRUE, showWarnings = FALSE)
  dir.create(file.path(cfg$dir_saida, "modelos"),  recursive = TRUE, showWarnings = FALSE)

  fim_treino = yearmonth(cfg$periodo_corte) - 1
  periodos_teste = yearmonth(cfg$periodo_corte) + 0:(cfg$horizonte - 1)

  glob_exog = exog_global(base)

  # Ex-ante: nível projetado; tarifa realizada (reajuste conhecido) ou constante
  glob_proj = projeta_nivel(glob_exog, fim_treino, periodos_teste) %>%
    left_join(glob_exog %>% transmute(periodo = yearmonth(periodo), tarifa_real = tarifa),
              by = "periodo") %>%
    mutate(tarifa = if (cfg$tarifa_ex_ante == "constante") {
      glob_exog$tarifa[yearmonth(glob_exog$periodo) == fim_treino]
    } else tarifa_real)

  ctx = list(rotulo = rotulo,
             fim_treino = fim_treino,
             periodos_teste = periodos_teste,
             mun_exog = exog_municipal(base),
             glob_exog = glob_exog,
             glob_proj = glob_proj)

  ## Outliers (só na janela de treino) -----------------------------------------

  base_chave = prepara_chave(base, alvo, as.Date(fim_treino),
                             cfg$tratar_outliers, cfg$limpar_economias)

  outliers = resumo_outliers(base_chave, as.Date(fim_treino))
  g_outlier = graf_outliers(base_chave, glue("{cfg$segmento} - {alvo}"))

  ## Fit e forecast por agrupamento --------------------------------------------

  res = cfg$agrupamentos %>%
    set_names() %>%
    map(~ backtest_agrupamento(base_chave, .x, cfg, ctx))

  fit_x_real = map_dfr(res, "fit_x_real")

  series = imap_dfr(res, ~ .x$info_series %>%
                      summarise(n_series = n(), n_elegiveis = sum(elegivel)) %>%
                      mutate(agrupamento = .y, .before = 1))

  resumo_fallback = fit_x_real %>%
    filter(cenario == "realizado") %>%
    group_by(agrupamento, .model, fallback) %>%
    summarise(vol = sum(vol_med_real, na.rm = T), n = n(), .groups = "drop_last") %>%
    mutate(perc_vol = vol/sum(vol)) %>%
    ungroup()

  cenarios_exog = imap_dfr(res, function(r, agrup) {
    pesos = r$info_series %>% select(all_of(chaves_ts), peso = vol_12m)
    resumo_cenarios(r$cenarios, pesos) %>%
      mutate(agrupamento = agrup, .before = 1)
  })

  ## LCA -----------------------------------------------------------------------

  lca = if (!is.null(cfg$arq_lca) && alvo %in% cfg$lca_alvos) {
    compara_lca(carrega_lca(cfg$arq_lca), base_chave, periodos_teste,
                cfg$alvo_real, unique(fit_x_real$cenario))
  } else NULL

  ## Acurácia ------------------------------------------------------------------

  acc = map(cfg$niveis, ~ calc_acc(fit_x_real, .x, lca))

  acc_detalhe_superint = calc_acc(fit_x_real, "cd_regiao_adj", lca, detalhe = T)

  acc_sel = acc[[cfg$nivel_selecao]] %>%
    filter(cenario == cfg$cenario_selecao)

  ranking = acc_sel %>%
    arrange(.data[[cfg$metrica_selecao]]) %>%
    mutate(rank = row_number(), .before = 1) %>%
    left_join(acc$total %>%
                select(agrupamento, cenario, .model,
                       MAPE_total = MAPE, WAPE_total = WAPE, Vies_total = Vies),
              by = c("agrupamento", "cenario", ".model"))

  melhor = ranking %>%
    filter(agrupamento != "LCA") %>%
    slice(1)

  tab_modelos = tabela_modelos(acc_sel, cfg$metrica_selecao)
  tab_agregacao = tabela_agregacao(acc_sel, cfg$metrica_selecao, series)

  decisao = melhor %>%
    transmute(segmento = cfg$segmento,
              alvo = alvo,
              agrupamento,
              modelo = .model,
              nivel = cfg$nivel_selecao,
              cenario = cfg$cenario_selecao,
              metrica = cfg$metrica_selecao,
              valor = .data[[cfg$metrica_selecao]],
              MAPE_total, WAPE_total, Vies_total)

  message(glue("Melhor: {melhor$agrupamento} / {melhor$.model} ",
               "({cfg$metrica_selecao} {cfg$nivel_selecao} = {number(melhor[[cfg$metrica_selecao]], 0.01)}%, ",
               "cenário {cfg$cenario_selecao})"))

  ## Elasticidades -------------------------------------------------------------

  coeficientes = calc_coeficientes(res)

  elasticidades = map(cfg$niveis_elast, ~ resume_elast(coeficientes, .x))

  # gráficos do melhor agrupamento; nas agregações usa o melhor modelo com
  # regressoras (ou arima_5, se o melhor não tiver)
  mod_elast = if (melhor$.model %in% unique(coeficientes$.model)) melhor$.model else "arima_5"

  graf_elast = coeficientes %>%
    filter(agrupamento == melhor$agrupamento) %>%
    split(.$term) %>%
    map(~ gera_graf(.x, cfg$dim_graf_elast))

  graf_elast_niveis = cfg$niveis_elast %>%
    keep(~ length(.x) == 1) %>%
    imap(~ graf_elast_nivel(elasticidades[[.y]] %>%
                              filter(agrupamento == melhor$agrupamento, .model == mod_elast),
                            .x, glue("Elasticidade por {.y} - {mod_elast}")))

  ## Estatísticas dos melhores -------------------------------------------------

  melhores = ranking %>%
    filter(agrupamento != "LCA") %>%
    slice_head(n = cfg$n_melhores) %>%
    select(rank, agrupamento, .model)

  estat_series = map2_dfr(melhores$agrupamento, melhores$.model,
                          ~ diag_series(res, .x, .y, fit_x_real, cfg$cenario_selecao)) %>%
    # SNAIVE não tem AICc
    mutate(AICc = if ("AICc" %in% names(.)) AICc else NA_real_)

  estat_melhores = resume_diag(estat_series, resumo_fallback, melhores)

  estat_melhores_acc = imap_dfr(acc, ~ mutate(.x, nivel = .y, .before = 1)) %>%
    inner_join(melhores, by = c("agrupamento", ".model")) %>%
    relocate(rank) %>%
    arrange(rank, nivel, cenario)

  estat_melhores_coef = elasticidades$geral %>%
    inner_join(melhores, by = c("agrupamento", ".model")) %>%
    relocate(rank) %>%
    arrange(rank, var)

  ## Gráficos ------------------------------------------------------------------

  real_hist = res[[1]]$base_ts %>%
    as_tibble() %>%
    filter(!preenchido) %>%
    mutate(vol_med = if (cfg$alvo_real == "ajustado") vol_ajust else vol_bruto)

  real_total = real_hist %>%
    filter(periodo >= ctx$fim_treino - 12) %>%
    group_by(periodo) %>%
    summarise(vol_med = sum(vol_med, na.rm = T)/10^6)

  fc_total = bind_rows(fit_x_real, lca$x_real) %>%
    group_by(agrupamento, cenario, .model, periodo) %>%
    summarise(vol_med = sum(vol_med_fit, na.rm = T)/10^6, .groups = "drop")

  graficos = list(
    outliers = g_outlier,
    cenarios_exog = graf_cenarios_exog(cenarios_exog %>% filter(agrupamento == cfg$agrupamentos[1])),
    real_x_forecast = graf_real_fc(real_total, fc_total, cfg$cenario_selecao,
                                   glue("{cfg$segmento} - {alvo}: real x forecast")),
    melhor_cenarios = graf_melhor_cenarios(real_total, fc_total, melhor,
                                           glue("{cfg$segmento} - {alvo}: melhor modelo ({melhor$agrupamento} / {melhor$.model}) por cenário")),
    melhor_superint = graf_superint(real_hist, fit_x_real, melhor, cfg$cenario_selecao, ctx$fim_treino - 12),
    heatmap = graf_heat(acc_sel, cfg$metrica_selecao,
                        glue("{cfg$segmento} - {alvo}: {cfg$metrica_selecao} {cfg$nivel_selecao} - cenário {cfg$cenario_selecao}"))
  )

  ## Exportação ----------------------------------------------------------------

  write_xlsx(
    c(list(decisao = decisao,
           melhor_modelo = tab_modelos,
           melhor_agregacao = tab_agregacao,
           ranking = ranking,
           melhores_resumo = estat_melhores,
           melhores_acuracia = estat_melhores_acc,
           melhores_elasticidade = estat_melhores_coef,
           melhores_series = estat_series),
      set_names(acc, paste0("acc_", names(acc))),
      list(acc_detalhe_superint = acc_detalhe_superint,
           series = series,
           fallback = resumo_fallback,
           outliers = outliers)),
    file.path(cfg$dir_saida, glue("01_Acuracia_{rotulo}.xlsx")))

  write_xlsx(
    list(real_x_forecast = fit_x_real %>%
           group_by(agrupamento, cenario, .model, cd_regiao_adj, categoria_detalhe, recorte, periodo) %>%
           summarise(across(c(n_economias, vol_med_real, vol_med_fit), ~ sum(., na.rm = T)),
                     .groups = "drop") %>%
           mutate(periodo = as.Date(periodo)),
         real_x_forecast_total = fc_total %>% mutate(periodo = as.Date(periodo)),
         cenarios_exogenas = cenarios_exog %>% mutate(periodo = as.Date(periodo))),
    file.path(cfg$dir_saida, glue("02_Real_x_Forecast_{rotulo}.xlsx")))

  write_xlsx(
    c(set_names(elasticidades, paste0("elast_", names(elasticidades))),
      list(coeficientes = coeficientes)),
    file.path(cfg$dir_saida, glue("03_Elasticidades_{rotulo}.xlsx")))

  iwalk(graficos, ~ salva_graf(.x, file.path(cfg$dir_saida, "graficos", glue("{rotulo}_{.y}.png"))))
  iwalk(graf_elast, ~ salva_graf(.x, file.path(cfg$dir_saida, "graficos",
                                               glue("{rotulo}_elast_{nome_arq(.y)}.png")),
                                 w = 16, h = 9))
  iwalk(graf_elast_niveis, ~ salva_graf(.x, file.path(cfg$dir_saida, "graficos",
                                                      glue("{rotulo}_elast_por_{.y}.png")),
                                        w = 16, h = 7))

  toc()

  list(res = res, fit_x_real = fit_x_real, acc = acc, ranking = ranking,
       decisao = decisao, tab_modelos = tab_modelos, tab_agregacao = tab_agregacao,
       coeficientes = coeficientes, elasticidades = elasticidades,
       estat_melhores = estat_melhores, outliers = outliers,
       graficos = c(graficos, graf_elast, graf_elast_niveis))
}


# 10. GRÁFICOS E EXPORTAÇÃO ----------------------------------------------------

salva_graf = function(g, arq, w = 14, h = 8) {
  ggsave(arq, g, width = w, height = h, dpi = 150)
}

graf_cenarios_exog = function(cenarios_exog) {
  cenarios_exog %>%
    pivot_longer(temp_med:tarifa) %>%
    ggplot(aes(x = periodo, y = value, color = cenario)) +
    geom_line(lwd = 1) +
    facet_wrap(~name, scales = "free_y") +
    scale_color_manual("", values = cores_cenario) +
    labs(title = "Exógenas no período de teste por cenário") +
    tema
}

graf_real_fc = function(real_total, fc_total, cenario, titulo) {
  fc = fc_total %>% filter(cenario == !!cenario)
  ggplot(data = NULL, aes(x = periodo, y = vol_med)) +
    geom_line(data = real_total, aes(group = "Real"), lwd = 1) +
    geom_line(data = fc %>% filter(agrupamento != "LCA"),
              aes(color = agrupamento), lwd = 0.8) +
    {if (any(fc$agrupamento == "LCA"))
      list(geom_line(data = fc %>% filter(agrupamento == "LCA") %>% select(-.model),
                     aes(linetype = "LCA"), color = "#f68c1f", lwd = 0.8),
           labs(linetype = ""))} +
    facet_wrap(~.model, nrow = 2) +
    scale_color_manual(values = c("#12d0ff", "#003853", "#76b041", "#e4572e", "#9b5de5")) +
    labs(title = titulo,
         subtitle = glue("Volume (milhões m³) | cenário: {cenario}")) +
    tema
}

graf_melhor_cenarios = function(real_total, fc_total, melhor, titulo) {
  ggplot(data = NULL, aes(x = periodo, y = vol_med)) +
    geom_line(data = real_total, aes(color = "Real"), lwd = 1.2) +
    geom_line(data = fc_total %>%
                filter(agrupamento == melhor$agrupamento, .model == melhor$.model),
              aes(color = cenario), lwd = 0.8) +
    {if (any(fc_total$agrupamento == "LCA"))
      geom_line(data = fc_total %>% filter(agrupamento == "LCA", cenario == "base"),
                aes(color = "LCA"), lwd = 0.8, linetype = "dashed")} +
    scale_color_manual("", values = cores_cenario) +
    labs(title = titulo, subtitle = "Volume (milhões m³)") +
    tema
}

graf_superint = function(real_hist, fit_x_real, melhor, cenario, desde) {
  fit_x_real %>%
    filter(agrupamento == melhor$agrupamento, .model == melhor$.model, cenario == !!cenario) %>%
    group_by(cd_regiao_adj, periodo) %>%
    summarise(vol_med_fit = sum(vol_med_fit)/10^6, .groups = "drop") %>%
    ggplot(aes(x = periodo)) +
    geom_line(data = real_hist %>%
                filter(periodo >= desde) %>%
                group_by(cd_regiao_adj, periodo) %>%
                summarise(vol_med = sum(vol_med, na.rm = T)/10^6, .groups = "drop"),
              aes(y = vol_med, color = "Real"), lwd = 0.8) +
    geom_line(aes(y = vol_med_fit, color = "Forecast"), lwd = 0.8) +
    facet_wrap(~cd_regiao_adj, scales = "free_y") +
    scale_color_manual("", values = c("Real" = "black", "Forecast" = "#12d0ff")) +
    labs(title = glue("Real x forecast por superintendência - {melhor$agrupamento} / {melhor$.model}"),
         subtitle = "Volume (milhões m³)") +
    tema
}

graf_heat = function(acc_sel, metrica, titulo) {
  acc_sel %>%
    ggplot(aes(x = .model, y = agrupamento, fill = .data[[metrica]])) +
    geom_tile(color = "white") +
    geom_text(aes(label = number(.data[[metrica]], 0.01)), size = 3) +
    scale_fill_gradient(low = "#12d0ff", high = "#f9b17f") +
    labs(title = titulo) +
    tema
}
