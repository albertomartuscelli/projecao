
# =============================================================================
# PROJEÇÃO DE VOLUME - RESIDENCIAL E NÃO RESIDENCIAL ATÉ DEZ/2027
#
# Volume = consumo/economia (modelo do backtest) x economias (ETS amortecido)
#          x fator tarifário (elasticidade x variação da tarifa real)
#
# Alvos: volume medido e faturado de água e esgoto.
#
# Fluxo (funções em 00_Funcoes.R):
#   0. Premissas
#   1. Importação e premissas globais (tarifa real, nível dos reservatórios)
#   2. Escolha de agregação e modelo (decisão dos backtests)
#   3. Projeção por segmento x alvo
#   4. Consolidação (mensal e anual)
#   5. Gráficos e exportação
# =============================================================================

source("00_Funcoes.R", encoding = "UTF-8")


# 0. PREMISSAS -----------------------------------------------------------------

dir_bases = "05_FRAMEWORK_5/01_BASES"
dir_bt    = "05_FRAMEWORK_5/03_BACKTESTING"    # decisão dos backtests
dir_saida = "05_FRAMEWORK_5/04_PROJECAO"

# Base única com todas as categorias; cada segmento filtra as suas
arq_base = file.path(dir_bases, "02_Base Analítica Ajustada_202201-202608.csv")

segmentos = list(
  Residencial = list(
    arq_base    = arq_base,
    categorias  = "Residencial",
    arq_decisao = file.path(dir_bt, "Residencial", "00_Decisao_Residencial.xlsx")),
  Nao_Residencial = list(
    arq_base    = arq_base,
    categorias  = c("Comercial", "Industrial", "Pública"),
    arq_decisao = file.path(dir_bt, "Nao_Residencial", "00_Decisao_Nao_Residencial.xlsx"))
)

alvos = c("med_agua", "fat_agua", "med_esg", "fat_esg")

fim_projecao   = as.Date("2027-12-01")
min_obs_modelo = 36            # mínimo de meses para ajustar modelo (demais: fallback)
min_obs_econ   = 24            # mínimo de meses para o ETS das economias

# Economias: projetar o total das categorias do grupo e repartir pela
# participação do último mês? No residencial há migração normal -> social
# (tarifa social: 0,5 mi -> 1,4 mi de economias desde 2022) que, projetada
# por categoria, inflaria o total. No não residencial as categorias são estáveis.
economias_agrega_categorias = c(Residencial = TRUE, Nao_Residencial = FALSE)

## Premissa de novas economias (engenharia) -------------------------------------
# Planilha "ALAVANCA DE VOLUME - NOVAS ECONOMIAS": entregas mensais de 2027 por
# município x utilização x tipo de ligação. Nos meses cobertos ela substitui o
# ETS: estoque = estoque do mês anterior + entregas acumuladas. Antes dela
# (set-dez/2026) vale o ETS. Com usar_premissa_economias = FALSE, só ETS.
usar_premissa_economias      = TRUE
arq_premissa_economias       = file.path(dir_bases, "ALAVANCA DE VOLUME - NOVAS ECONOMIAS 2027.xlsx")
premissa_economias_segmentos = "Residencial"

# "Utilização" da engenharia -> categoria_detalhe x recorte da base. O
# incremento é repartido entre as chaves do município pelo estoque de economias
# do último mês (inclusive entre as ATCs de SP, Osasco e Guarulhos).
de_para_utilizacao = tribble(
  ~utilizacao,     ~categoria_detalhe,              ~recorte,
  "Normal",        "Residencial Normal",            "Urbano",
  "Normal",        "Residencial Normal",            "Informal",
  "Rural",         "Residencial Normal",            "Rural",
  "Tarifa Social", "Residencial Social",            "Urbano",
  "Tarifa Social", "Residencial Social",            "Informal",
  "Tarifa Social", "Residencial Social Vulnerável", "Urbano",
  "Tarifa Social", "Residencial Social Vulnerável", "Informal"
)

# Municípios fora da premissa: "ets" (seguem a tendência) | "zero" (estoque constante)
economias_fora_premissa = "ets"

# Cobertura: "municipio_servico" = município sem linha de esgoto na planilha
# segue o ETS no esgoto (~110 municípios têm linha de esgoto, 204 de água);
# "municipio" = estar na planilha cobre água e esgoto (sem linha = sem entrega)
cobertura_premissa = "municipio_servico"

# Outliers: tsclean no consumo/economia em todo o histórico (que é o treino)
tratar_outliers = TRUE

## Agregação e modelo ----------------------------------------------------------
# Lidos de 00_Decisao_<segmento>.xlsx (backtests). Sem o arquivo, vale o
# padrão abaixo, que foi o vencedor no backtest de água medida residencial.
escolha_padrao = list(agrupamento = "G1_municipioA_clusterBC", modelo = "arima_2")

# Sobrepõe a decisão do backtest, se preenchido. Exemplo:
#   add_row(segmento = "Nao_Residencial", alvo = "med_esg",
#           agrupamento = "G2_superintendencia", modelo = "arima_1")
escolha_manual = tibble(segmento = character(), alvo = character(),
                        agrupamento = character(), modelo = character())

## Tarifa ----------------------------------------------------------------------
# A variável do modelo é o IRT real (base 100). O reajuste é nominal: entre
# reajustes, a tarifa real cai com a inflação.
reajuste_nominal = 0.065                  # reajuste esperado para 2027
mes_reajuste     = as.Date("2027-04-01")  # 2026: vigência em jan, chegou às contas em mar-abr
ipca_aa          = 0.045                  # IPCA projetado (a.a.) - atualizar com o Focus

## Elasticidade-preço (consumo/economia x tarifa real) ---------------------------
# Aplicada sobre a projeção quando o modelo NÃO tem tarifa (os vencedores do
# backtest não têm). Modelos com tarifa (arima_4/5) já recebem a trajetória do
# IRT como regressora e não recebem o ajuste, para não contar o efeito duas vezes.
# Referência: medianas do backtest (arima_4/5) e o projeto elasticidade_tarifa.
elasticidade_tarifa = c("Residencial Normal"            = -0.10,
                        "Residencial Social"            = -0.10,
                        "Residencial Social Vulnerável" = -0.10,
                        "Comercial"                     = -0.10,
                        "Industrial"                    = -0.10,
                        "Pública"                       = -0.10)
elasticidade_padrao = -0.10               # categorias fora da lista
elasticidade_sens   = c(baixa = 0.5, alta = 1.5)   # multiplicadores (sensibilidade)

## Clima -----------------------------------------------------------------------
# base        : média do mês no histórico, por série
# el_nino     : base + anomalias do El Niño análogo nos meses de `el_nino_periodo`
# quente_seco : base com temperatura +1 dp e chuva -1 dp
# frio_umido  : base com temperatura -1 dp e chuva +1 dp
cenarios_proj     = c("base", "el_nino", "quente_seco", "frio_umido")
cenario_principal = "el_nino"

# El Niño em 2027. Análogo: o El Niño forte de jun/2023-mai/2024, único da
# amostra (+1,3 °C e chuva 5% abaixo da média no estado). As anomalias são por
# superintendência e mês do ano, suavizadas em 3 meses.
el_nino_analogo     = c(inicio = "2023-06-01", fim = "2024-05-01")
el_nino_periodo     = c(inicio = "2027-01-01", fim = "2027-12-01")
el_nino_intensidade = 1          # 1 = igual ao análogo; 0,5 = metade (El Niño fraco)
el_nino_suavizacao  = 3          # meses da média móvel das anomalias (1 = sem)

# Processamento (Windows/RStudio: multisession)
n_workers = 20

dir.create(file.path(dir_saida, "graficos"), recursive = TRUE, showWarnings = FALSE)

tic("Total")


# 1. IMPORTAÇÃO E PREMISSAS GLOBAIS --------------------------------------------

bases = map(segmentos, ~ carrega_base(.x$arq_base, .x$categorias))

premissa_economias = if (usar_premissa_economias) {
  le_premissa_economias(arq_premissa_economias)
} else NULL

if (!is.null(premissa_economias)) {
  premissa_economias %>%
    group_by(utilizacao, tipo) %>%
    summarise(municipios = n_distinct(municipio), incremento = sum(incremento), .groups = "drop") %>%
    print()
}

glob_exog = exog_global(bases$Residencial)
fim_hist  = yearmonth(max(glob_exog$periodo))

n_meses       = as.numeric(yearmonth(fim_projecao)) - as.numeric(fim_hist)
periodos_proj = fim_hist + seq_len(n_meses)

message(glue("Histórico até {fim_hist} | projeção {first(periodos_proj)} a {last(periodos_proj)}"))

## 1.1 Tarifa real -------------------------------------------------------------

ipca_m  = (1 + ipca_aa)^(1/12) - 1
irt_ult = last(glob_exog$tarifa)

# Referência do fator tarifário: tarifa real média dos últimos 12 meses, que é
# o nível embutido no consumo recente que o modelo projeta
irt_ref = mean(tail(glob_exog$tarifa, 12))

irt_proj = tibble(periodo = periodos_proj) %>%
  mutate(k = row_number(),
         tarifa = irt_ult / (1 + ipca_m)^k *
           if_else(periodo >= yearmonth(mes_reajuste), 1 + reajuste_nominal, 1)) %>%
  select(-k)

## 1.2 Nível dos reservatórios e exógenas globais ------------------------------

glob_proj = projeta_nivel(glob_exog, fim_hist, periodos_proj) %>%
  left_join(irt_proj, by = "periodo")

g_premissas = bind_rows(
  glob_exog %>%
    transmute(periodo = yearmonth(periodo), `IRT real` = tarifa, `Nível (t)` = nv_sim, tipo = "Histórico"),
  glob_proj %>%
    transmute(periodo, `IRT real` = tarifa, `Nível (t)` = nv_sim, tipo = "Projeção")) %>%
  pivot_longer(c(`IRT real`, `Nível (t)`)) %>%
  ggplot(aes(x = periodo, y = value, color = tipo)) +
  geom_line(lwd = 1) +
  geom_hline(data = tibble(name = "IRT real", ref = irt_ref),
             aes(yintercept = ref), linetype = "dashed", color = "grey50") +
  facet_wrap(~name, scales = "free_y", ncol = 1) +
  scale_color_manual("", values = c("Histórico" = "black", "Projeção" = "#12d0ff")) +
  labs(title = "Premissas globais",
       subtitle = glue("Reajuste nominal de {percent(reajuste_nominal, 0.1)} em {format(mes_reajuste, '%m/%Y')}, ",
                       "IPCA {percent(ipca_aa, 0.1)} a.a. | tracejado: referência do fator tarifário")) +
  tema

g_premissas


# 2. ESCOLHA DE AGREGAÇÃO E MODELO ---------------------------------------------

le_decisao = function(seg) {
  arq = segmentos[[seg]]$arq_decisao
  dec = if (file.exists(arq)) {
    read_excel(arq, "decisao") %>% select(alvo, agrupamento, modelo)
  } else {
    message(glue("Decisão não encontrada ({arq}) - usando padrão para {seg}."))
    tibble(alvo = character(), agrupamento = character(), modelo = character())
  }
  tibble(segmento = seg, alvo = alvos) %>%
    left_join(dec, by = "alvo") %>%
    mutate(fonte = if_else(is.na(modelo), "padrão", "backtest"),
           agrupamento = coalesce(agrupamento, escolha_padrao$agrupamento),
           modelo = coalesce(modelo, escolha_padrao$modelo))
}

escolhas = map_dfr(names(segmentos), le_decisao) %>%
  rows_update(escolha_manual %>% mutate(fonte = "manual"),
              by = c("segmento", "alvo"), unmatched = "ignore") %>%
  mutate(ajuste_elasticidade = !modelo %in% modelos_com_tarifa)

escolhas %>%
  print(n = Inf)


# 3. PROJEÇÃO POR SEGMENTO X ALVO ----------------------------------------------

projeta_alvo = function(seg, alvo, agrup, modelo, ajuste_elasticidade) {

  rotulo = glue("{seg} | {alvo} | {agrup} / {modelo}")
  message(glue("\n===== {rotulo} ====="))
  tic(rotulo)

  base = bases[[seg]]

  ## Séries --------------------------------------------------------------------

  base_chave = prepara_chave(base, alvo, as.Date(fim_hist), tratar_outliers)

  base_ts = monta_base_ts(base_chave, regras_agrupamento[[agrup]],
                          exog_municipal(base), glob_exog)

  info = resumo_series(base_ts, fim_hist, min_obs_modelo)
  ativas = info %>% filter(ativa)
  eleg = info %>% filter(elegivel)

  message(glue("Séries: {nrow(info)} | ativas: {nrow(ativas)} | com modelo: {nrow(eleg)}"))

  ## Consumo/economia ----------------------------------------------------------

  hist = base_ts %>%
    filter(periodo <= fim_hist) %>%
    semi_join(eleg, by = chaves_ts)

  fit = ajusta_modelos(hist, modelos_candidatos[modelo], n_workers)

  grade = ativas %>%
    select(all_of(chaves_ts)) %>%
    crossing(periodo = periodos_proj)

  cenarios = cenarios_ex_ante(base_ts, grade, fim_hist, glob_proj)

  anomalias = anomalias_analogo(base_ts, el_nino_analogo[["inicio"]], el_nino_analogo[["fim"]],
                                el_nino_suavizacao)

  cenarios$el_nino = cenario_analogo(cenarios$base, anomalias,
                                     periodos_proj[periodos_proj >= yearmonth(el_nino_periodo[["inicio"]]) &
                                                     periodos_proj <= yearmonth(el_nino_periodo[["fim"]])],
                                     el_nino_intensidade)

  cenarios = cenarios[cenarios_proj]

  fc = prever(fit, map(cenarios, ~ semi_join(.x, eleg, by = chaves_ts))) %>%
    select(-.model)

  fallback = monta_fallback(base_ts, grade, fim_hist)

  ## Economias -----------------------------------------------------------------

  econ = projeta_economias(base_ts, ativas, periodos_proj, fim_hist, n_workers, min_obs_econ,
                           agrega_categorias = economias_agrega_categorias[[seg]]) %>%
    mutate(n_economias_ets = n_economias)

  premissa_resumo = NULL

  if (!is.null(premissa_economias) && seg %in% premissa_economias_segmentos) {

    alocacao = aloca_premissa_economias(premissa_economias, base_chave, alvo,
                                        de_para_utilizacao, fim_hist, cobertura_premissa)

    econ = aplica_premissa_economias(econ %>% select(-n_economias_ets), alocacao, base_chave,
                                     regras_agrupamento[[agrup]], fim_hist, economias_fora_premissa)

    premissa_resumo = alocacao$alocado %>%
      inner_join(base_chave %>% distinct(chave, cd_regiao_adj, categoria_detalhe, recorte), by = "chave") %>%
      group_by(cd_regiao_adj, categoria_detalhe, recorte, periodo, regra) %>%
      summarise(incremento = sum(incremento), .groups = "drop")

    message(glue("Premissa de economias: {number(alocacao$total, big.mark = '.')} no total | ",
                 "não alocado: {number(alocacao$nao_alocado, big.mark = '.')}"))
  }

  ## Volume --------------------------------------------------------------------

  proj = grade %>%
    crossing(cenario = cenarios_proj) %>%
    left_join(fc, by = c(chaves_ts, "periodo", "cenario")) %>%
    left_join(fallback, by = c(chaves_ts, "periodo")) %>%
    left_join(info %>% select(all_of(chaves_ts), elegivel), by = chaves_ts) %>%
    mutate(fallback = case_when(!elegivel ~ "nao_elegivel",
                                !is.finite(consumo_prev) ~ "falha_modelo",
                                T ~ "modelo"),
           consumo_modelo = if_else(fallback == "modelo", consumo_prev, consumo_fb)) %>%
    left_join(econ, by = c(chaves_ts, "periodo")) %>%
    left_join(irt_proj, by = "periodo") %>%
    mutate(eps = unname(coalesce(elasticidade_tarifa[categoria_detalhe], elasticidade_padrao)) *
             ajuste_elasticidade,
           fator_tarifa = (tarifa/irt_ref)^eps,
           consumo = consumo_modelo * fator_tarifa,
           vol = consumo * n_economias,
           vol_eps_baixa = consumo_modelo * (tarifa/irt_ref)^(eps * elasticidade_sens[["baixa"]]) * n_economias,
           vol_eps_alta  = consumo_modelo * (tarifa/irt_ref)^(eps * elasticidade_sens[["alta"]]) * n_economias,
           vol_econ_ets  = consumo * n_economias_ets,
           tipo = "PROJ") %>%
    select(all_of(chaves_ts), periodo, tipo, cenario, n_economias, n_economias_ets, consumo_modelo,
           fator_tarifa, consumo, vol, vol_eps_baixa, vol_eps_alta, vol_econ_ets, fallback, econ_metodo)

  ## Histórico (real; meses sem dado viram "IMPUTADO") -------------------------

  real = base_ts %>%
    as_tibble() %>%
    filter(periodo <= fim_hist) %>%
    transmute(across(all_of(chaves_ts)), periodo,
              tipo = if_else(preenchido, "IMPUTADO", "REAL"),
              n_economias = if_else(preenchido, econ_ajust, econ_bruto),
              vol = if_else(preenchido, consumo * econ_ajust, vol_bruto),
              consumo = vol/n_economias)

  # Peso das séries encerradas antes do fim do histórico (não projetadas)
  encerradas = info %>%
    summarise(n_encerradas = sum(!ativa),
              perc_vol12m_encerradas = sum(vol_12m[!ativa])/sum(vol_12m),
              n_fallback = sum(ativa & !elegivel),
              perc_vol12m_fallback = sum(vol_12m[ativa & !elegivel])/sum(vol_12m))

  resumo_exog = resumo_cenarios(cenarios, info %>% select(all_of(chaves_ts), peso = vol_12m))

  toc()

  rm(fit, base_ts, base_chave, hist)
  gc()

  list(proj = proj, real = real, encerradas = encerradas,
       resumo_exog = resumo_exog, anomalias = anomalias, premissa = premissa_resumo)
}

resultados = escolhas %>%
  mutate(res = pmap(list(segmento, alvo, agrupamento, modelo, ajuste_elasticidade),
                    projeta_alvo))


# 4. CONSOLIDAÇÃO --------------------------------------------------------------

desaninha = function(item) {
  resultados %>%
    select(segmento, alvo, res) %>%
    mutate(x = map(res, item)) %>%
    select(-res) %>%
    unnest(x)
}

proj  = desaninha("proj")
real  = desaninha("real")

# Série mensal completa por superintendência x categoria x recorte. O histórico
# é repetido em cada cenário para facilitar os totais anuais.
mensal = bind_rows(
  real %>%
    crossing(cenario = cenarios_proj) %>%
    mutate(vol_eps_baixa = vol, vol_eps_alta = vol,
           n_economias_ets = n_economias, vol_econ_ets = vol),
  proj) %>%
  group_by(segmento, alvo, cenario, cd_regiao_adj, categoria_detalhe, recorte, periodo, tipo) %>%
  summarise(across(c(n_economias, n_economias_ets, vol, vol_eps_baixa, vol_eps_alta, vol_econ_ets),
                   ~ sum(., na.rm = T)),
            .groups = "drop") %>%
  mutate(consumo = vol/n_economias,
         periodo = as.Date(periodo))

# Totais anuais (2026 = real jan-ago + projeção set-dez)
resume_anual = function(nivel) {
  mensal %>%
    group_by(segmento, alvo, cenario, across(all_of(nivel)), periodo) %>%
    summarise(across(c(n_economias, n_economias_ets, vol, vol_eps_baixa, vol_eps_alta, vol_econ_ets), sum),
              meses_proj = any(tipo == "PROJ"),
              .groups = "drop") %>%
    mutate(ano = year(periodo)) %>%
    group_by(segmento, alvo, cenario, across(all_of(nivel)), ano) %>%
    summarise(vol = sum(vol),
              vol_eps_baixa = sum(vol_eps_baixa),
              vol_eps_alta = sum(vol_eps_alta),
              vol_econ_ets = sum(vol_econ_ets),
              economias_media = mean(n_economias),
              economias_media_ets = mean(n_economias_ets),
              meses_proj = sum(meses_proj),
              .groups = "drop") %>%
    mutate(consumo_medio = vol/economias_media/12) %>%
    group_by(segmento, alvo, cenario, across(all_of(nivel))) %>%
    arrange(ano, .by_group = TRUE) %>%
    mutate(var_vol = vol/lag(vol) - 1,
           var_economias = economias_media/lag(economias_media) - 1,
           var_consumo = consumo_medio/lag(consumo_medio) - 1) %>%
    ungroup()
}

anual_total     = resume_anual(character(0))
anual_categoria = resume_anual("categoria_detalhe")
anual_superint  = resume_anual("cd_regiao_adj")

anual_total %>%
  filter(cenario == cenario_principal, ano >= 2025) %>%
  select(segmento, alvo, ano, vol, var_vol, var_economias, var_consumo, meses_proj) %>%
  print(n = Inf)

series = resultados %>%
  transmute(segmento, alvo, agrupamento, modelo, ajuste_elasticidade,
            map_dfr(res, "encerradas"))

exog_cenarios = desaninha("resumo_exog") %>%
  mutate(periodo = as.Date(periodo))

premissa_alocada = if (!is.null(premissa_economias)) {
  desaninha("premissa") %>%
    mutate(periodo = as.Date(periodo))
} else tibble()

anomalias_el_nino = desaninha("anomalias") %>%
  filter(segmento == "Residencial", alvo == "med_agua") %>%
  select(-segmento, -alvo)

anomalias_el_nino %>%
  group_by(mes) %>%
  summarise(temp_anom = mean(temp_anom), prec_razao = mean(prec_razao)) %>%
  print(n = 12)

premissas = tribble(
  ~premissa, ~valor,
  "Histórico até", as.character(fim_hist),
  "Projeção até", as.character(yearmonth(fim_projecao)),
  "Reajuste nominal", percent(reajuste_nominal, 0.1),
  "Mês do reajuste (nas contas)", format(mes_reajuste, "%m/%Y"),
  "IPCA projetado (a.a.)", percent(ipca_aa, 0.1),
  "IRT real - último", number(irt_ult, 0.01),
  "IRT real - referência (média 12m)", number(irt_ref, 0.01),
  "Elasticidade-preço", paste(names(elasticidade_tarifa), elasticidade_tarifa, sep = ": ", collapse = " | "),
  "Sensibilidade da elasticidade", paste(names(elasticidade_sens), elasticidade_sens, sep = " x", collapse = " | "),
  "Cenário principal", cenario_principal,
  "Clima (cenário base)", "média do mês no histórico, por série",
  "Clima (el_nino)", glue("base + anomalias do análogo {el_nino_analogo[['inicio']]} a {el_nino_analogo[['fim']]} ",
                          "entre {el_nino_periodo[['inicio']]} e {el_nino_periodo[['fim']]} ",
                          "(intensidade {el_nino_intensidade}, suavização {el_nino_suavizacao} meses)"),
  "Clima (quente_seco / frio_umido)", "média ± 1 desvio-padrão do mês",
  "CAGED", "tendência dos últimos 12 meses",
  "Nível dos reservatórios", "auto.arima na série histórica",
  "Economias", glue("ETS amortecido no log (séries com {min_obs_econ}+ meses); demais: último valor"),
  "Economias - total entre categorias", paste(names(economias_agrega_categorias), economias_agrega_categorias, sep = ": ", collapse = " | "),
  "Economias - premissa da engenharia", if (usar_premissa_economias) {
    glue("{basename(arq_premissa_economias)} ({paste(premissa_economias_segmentos, collapse = ', ')}); ",
         "fora da premissa: {economias_fora_premissa}; cobertura: {cobertura_premissa}; colunas *_ets = só ETS")
  } else "não usada",
  "Outliers", if (tratar_outliers) "tsclean no consumo/economia (histórico)" else "sem tratamento",
  "Séries curtas/sem modelo", "fallback: sazonal ingênuo -> média 12m -> segmento"
)


# 5. GRÁFICOS E EXPORTAÇÃO -----------------------------------------------------

rotulos_alvo = c(med_agua = "Água - medido", fat_agua = "Água - faturado",
                 med_esg = "Esgoto - medido", fat_esg = "Esgoto - faturado")

graf_total = function(seg) {
  dados = mensal %>%
    filter(segmento == seg, periodo >= as.Date("2024-01-01")) %>%
    group_by(alvo, cenario, periodo, tipo) %>%
    summarise(vol = sum(vol)/10^6, .groups = "drop") %>%
    mutate(alvo = rotulos_alvo[alvo])

  ggplot(data = NULL, aes(x = periodo, y = vol)) +
    geom_line(data = dados %>% filter(tipo != "PROJ", cenario == cenario_principal),
              aes(color = "Real"), lwd = 1) +
    geom_point(data = dados %>% filter(tipo == "IMPUTADO", cenario == cenario_principal),
               aes(color = "Imputado"), size = 2) +
    geom_line(data = dados %>% filter(tipo == "PROJ"),
              aes(color = cenario), lwd = 0.9) +
    facet_wrap(~alvo, scales = "free_y") +
    scale_color_manual("", values = cores_cenario) +
    labs(title = glue("Projeção de volume - {str_replace(seg, '_', ' ')}"),
         subtitle = "Milhões de m³ por mês") +
    tema
}

graf_categoria = function(seg) {
  mensal %>%
    filter(segmento == seg, cenario == cenario_principal, periodo >= as.Date("2024-01-01")) %>%
    group_by(alvo, categoria_detalhe, periodo, tipo) %>%
    summarise(vol = sum(vol)/10^6, .groups = "drop") %>%
    mutate(alvo = rotulos_alvo[alvo],
           tipo = if_else(tipo == "PROJ", "Projeção", "Real")) %>%
    ggplot(aes(x = periodo, y = vol, color = categoria_detalhe, linetype = tipo)) +
    geom_line(lwd = 0.9) +
    facet_wrap(~alvo, scales = "free_y") +
    scale_color_manual("", values = c("#003853", "#12d0ff", "#76b041")) +
    scale_linetype_manual("", values = c("Real" = "solid", "Projeção" = "dashed")) +
    labs(title = glue("Projeção por categoria - {str_replace(seg, '_', ' ')} (cenário {cenario_principal})"),
         subtitle = "Milhões de m³ por mês") +
    tema
}

g_exog = exog_cenarios %>%
  filter(segmento == "Residencial", alvo == "med_agua") %>%
  select(cenario, periodo, `Temperatura (°C)` = temp_med, `Chuva (mm/dia)` = prec_tot) %>%
  pivot_longer(-c(cenario, periodo)) %>%
  ggplot(aes(x = periodo, y = value, color = cenario)) +
  geom_line(lwd = 1) +
  facet_wrap(~name, scales = "free_y", ncol = 1) +
  scale_color_manual("", values = cores_cenario) +
  labs(title = "Clima projetado por cenário",
       subtitle = "Média ponderada pelo volume (residencial)") +
  tema

graficos = c(list(premissas = g_premissas, clima = g_exog),
             set_names(map(names(segmentos), graf_total), paste0("total_", names(segmentos))),
             set_names(map(names(segmentos), graf_categoria), paste0("categoria_", names(segmentos))))

graficos

iwalk(graficos, ~ salva_graf(.x, file.path(dir_saida, "graficos",
                                           glue("{.y}_{format(fim_projecao, '%Y%m')}.png"))))

write_xlsx(
  list(premissas = premissas,
       escolhas = escolhas,
       series = series,
       anual_total = anual_total,
       anual_categoria = anual_categoria,
       anual_superintendencia = anual_superint,
       mensal = mensal,
       tarifa_e_nivel = glob_proj %>% mutate(periodo = as.Date(periodo)),
       exogenas_cenarios = exog_cenarios,
       anomalias_el_nino = anomalias_el_nino,
       premissa_economias = premissa_alocada,
       de_para_utilizacao = de_para_utilizacao),
  file.path(dir_saida, glue("Projecao_Volume_{format(fim_projecao, '%Y%m')}.xlsx")))

toc()
