

pacman::p_load(tidyverse, data.table, janitor, readxl, writexl, glue, 
               broom, zoo,  stringi, tsibble,
               fable,
               fabletools,
               feasts, imputeTS,
               scales)

tema = theme(axis.ticks = element_blank(),
             panel.grid.major.x = element_blank(),
             panel.grid.major.y = element_line(color = "grey85", 
                                               linetype = "dashed"),
             panel.grid.minor = element_blank(),
             #axis.text = element_text(size = 18),
             #panel.background = element_rect(fill = "grey98"),
             #strip.text = element_blank(),
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


# IMPORTAÇÃO --------------------------------------------------------------

# Base água: seleciona só variáveis de água
base_raw = glue("05_FRAMEWORK_5/01_BASES/01_Base Analítica_202201-202608.csv") %>% 
  fread() 

base = base_raw %>% 
  rename(cd_regiao = sg_superintendencia, recorte = tp_recorte) %>% 
  relocate(cd_regiao, municipio, cd_ibge, cd_atc, categoria, categoria_detalhe, ds_catego, catego, recorte, periodo) %>% 
  arrange(cd_regiao, municipio, cd_ibge, cd_atc, categoria, categoria_detalhe, ds_catego, catego, recorte, periodo) 

# Ajusta SANTO ANDRE

base = base %>% 
  mutate(cd_regiao = ifelse(cd_ibge == 354780, "OC", cd_regiao),
         municipio = ifelse(cd_ibge == 354780, "SANTO ANDRE", municipio),
         cd_atc = ifelse(cd_ibge == 354780, 72, cd_atc))


# Cria a base filtrada
base_ajust = base

# FUNÇÕES AUXILIAR --------------------------------------------------------


calc_magnitude = function(base, grupos, 
                          var = "vol_medido_reg_agua", 
                          perc = T,
                          wider = T) {
  
  grupos = c(grupos, "mes")
  
  magnitude = base %>% 
    filter(year(periodo) == max(year(periodo))) %>% 
    mutate(mes = lubridate::month(periodo, label = T)) %>% 
    group_by(across(all_of(grupos))) %>% 
    summarise(valor = sum(.data[[var]])) %>% 
    ungroup()
  
  
  if (perc == T) {
    magnitude = magnitude %>% 
      group_by(mes) %>% 
      mutate(valor = valor/sum(valor)) %>% 
      ungroup()
    
  }
  
  
  if (wider) {

    
    ultimo_mes = magnitude %>%
      distinct(mes) %>% 
      filter(mes == max(mes)) %>% 
      pull() %>% 
      as.character()
    
    magnitude = magnitude %>% 
      pivot_wider(names_from = mes, values_from = valor) %>% 
      arrange(desc(.data[[ultimo_mes]]))
    
    if (perc == T) {
      magnitude = magnitude %>% 
        mutate(across(!any_of(grupos), ~percent(., accuracy = 0.01))) 
    } else {
      magnitude = magnitude %>% 
        mutate(across(!any_of(grupos), ~number(., accuracy = 0.01, scale = 1/10^6))) 
    }
    
    
    return(magnitude)
    
  } else {
    return(magnitude)
  }
}



# 2. Categoria ------------------------------------------------------------

# Magnitude em 2026 por categoria / catego

calc_magnitude(base_ajust,
               grupos =  c("categoria", "categoria_detalhe", "catego", "ds_catego"),
               perc = T)

# por categoria detalhedetalhe 

calc_magnitude(base_ajust,
               grupos =  c("categoria", "categoria_detalhe"))


## Dropa categorias pequenas (<1% e Atacado) -------------------------------------------------------------

categoria_detalhe_drop = c('Atacado', "Outras", "Industrial - DF", "Comercial - DF")

base_ajust = base_ajust %>% 
  filter_out(categoria_detalhe %in% categoria_detalhe_drop)


# 2. Recortes inconsistentes -------------------------------------------------------------

recorte_inconsistente = c('null', "0")

base_null = base_ajust %>% 
  filter(recorte %in% recorte_inconsistente) 

calc_magnitude(base_null,
               grupos =  c("categoria", "cd_regiao", 'municipio'))

## Dropa recortes inconsistentes-------------------------------------------------------------

base_ajust = base_ajust %>% 
  filter_out(recorte %in% recorte_inconsistente)


# 3. Recorte Residencial -------------------------------------------------------------

base_resid = base_ajust %>% 
  filter(categoria == "Residencial")

# Magnitude
calc_magnitude(base_resid,
               grupos =  c("categoria_detalhe", "recorte"))


## Ajusta RS e RSV Rural-------------------------------------------------------------

# 
# magnitude_resid_mun = base_resid %>% 
#   filter(periodo == max(periodo)) %>% 
#   group_by(municipio, categoria_detalhe, recorte) %>% 
#   summarise(vol = sum(vol_medido_reg_agua)) %>% 
#   group_by(municipio) %>% 
#   mutate(perc = vol/sum(vol),
#          categoria_recorte = paste0(categoria_detalhe, "_", recorte)) 

# junta informal + rural o RS e o RSV

base_ajust = base_ajust %>% 
  group_by(municipio) %>% 
  mutate(tem_informal = any(recorte == "Informal")) %>% 
  mutate(recorte = case_when(
    str_detect(categoria_detalhe, "Residencial Social") & recorte == "Rural" & tem_informal ~ "Informal",
    str_detect(categoria_detalhe, "Residencial Social") & recorte == "Rural" ~ "Urbano",
    T ~ recorte)) %>% 
  select(-tem_informal)



# 4. Recorte Não Residencial -------------------------------------------------------------

base_nao_resid = base_ajust %>% 
  filter(categoria != "Residencial")

# Magnitude
calc_magnitude(base_nao_resid,
               grupos =  c("categoria_detalhe", "recorte"))

base_ajust = base_ajust %>% 
  mutate(recorte = ifelse(categoria != "Residencial", "Total", recorte))


# 5. Municipios -------------------------------------------------------------


magnitude_mun = base_ajust %>% 
  calc_magnitude(grupos =  c("municipio"),
                 perc = F,
                 wider = F) %>% 
  filter(mes == max(mes)) %>% 
  arrange(desc(valor)) %>% 
  mutate(perc = valor/sum(valor),
         perc_acum = cumsum(perc)) %>% 
  mutate(classificacao_abc = case_when(perc_acum <= 0.8 ~ "A",
                                       perc_acum <= 0.95 ~ "B",
                                       T ~ "C"))

de_para_mun = magnitude_mun %>% 
  select(municipio, classificacao_abc)

# 6. Grupos inválidos -----------------------------------------------------

estatisticas_grupos = base_ajust  %>% 
  group_by(across(c(cd_regiao:categoria_detalhe, recorte))) %>% 
  summarise(n_periodos = n_distinct(periodo),
            ultimo_periodo = max(periodo),
            media_economias = mean(n_economias_agua),
            media_vol = mean(vol_medido_reg_agua)) %>% 
  arrange(n_periodos)


grupos_drop = estatisticas_grupos %>% 
  ungroup() %>% 
  filter(ultimo_periodo != max(ultimo_periodo) | media_economias < 10 | media_vol < 100)

# 7. Agrega informações -------------------------------------------------------------


list_var = c("vol_med_agua", "vol_med_esg",
             "vol_fat_agua", "vol_fat_esg",
             "n_economias_agua", "n_economias_esg")

glimpse(base_ajust)

base_agg = base_ajust %>% 
  anti_join(grupos_drop, by = join_by(cd_atc, categoria, categoria_detalhe, recorte)) %>% 
  left_join(de_para_mun, by = "municipio") %>%
  group_by(across(c(cd_regiao:categoria_detalhe, recorte, classificacao_abc, periodo))) %>% 
  summarise(across(any_of(list_var), sum),
            across(prec_tot:irt_real, first)) %>% 
  mutate(chave = paste0(cd_regiao, "_", municipio, "_", cd_atc, "_", categoria_detalhe, "_", recorte),
         .before = 1) 



# 8. Ajuste Informações Março/Abril 2026 -------------------------------------------------------------

## Share histórico de Março/Abril ----------------------------------------------------
share_hist <- base_agg |>
  mutate(ano = year(periodo),
         mes = month(periodo),
         vol = vol_med_agua) %>% 
  filter(ano %in% 2022:2025, mes %in% 3:4) |>
  group_by(chave, ano) |>
  summarise(s = sum(vol[mes == 3], na.rm = T) / sum(vol, na.rm = T), .groups = "drop") |>
  group_by(chave) |>
  summarise(s = median(s, na.rm = TRUE)) %>% 
  mutate(s = if_else(between(s, 0.40, 0.60), s, 0.505))

## Total acumulado nos meses março/abril 2026 por chave ----------------------------------------------------
total_2026_0304 = base_agg |>
  filter(periodo %in% as.Date(c("2026-03-01","2026-04-01"))) %>% 
  group_by(chave) %>% 
  summarise(across(any_of(list_var), sum)) %>% 
  left_join(share_hist, by = "chave") 

## Rateio pelo share histórico ----------------------------------------------------
## 2026/03 
base_2026_03 = total_2026_0304 %>% 
  mutate(periodo = as.Date("2026-03-01"),
         across(any_of(list_var), ~ s * .))

## 2026/04
base_2026_04 = total_2026_0304 %>% 
  mutate(periodo = as.Date("2026-04-01"),
         across(any_of(list_var), ~ (1 - s) * .))


## Valor de março/abril 2026 ajustado ----------------------------------------------------

# Demais colunas
demais_colunas_2026_03_04 = base_agg %>% 
  select(-any_of(list_var))

# Valor ajustado
base_2026_03_04 = bind_rows(base_2026_03, base_2026_04) %>%
  mutate(periodo = as.IDate(periodo)) %>% 
  select(-s) %>% 
  left_join(demais_colunas_2026_03_04, by = c('periodo', 'chave'))


## Junta na base final ----------------------------------------------------


base_agg_ajust <- base_agg |>
  filter_out(periodo %in% as.Date(c("2026-03-01","2026-04-01"))) %>% 
  bind_rows(base_2026_03_04) %>% 
  arrange(chave, periodo)

base_agg_ajust %>% 
  tail(10)


# Exportação --------------------------------------------------------------


base_agg_ajust %>% 
  fwrite("05_FRAMEWORK_5/01_BASES/02_Base Analítica Ajustada_202201-202608.csv")  


set.seed(123) # garante reprodutibilidade

base_amostra <- base_agg_ajust %>%
  ungroup() %>%
  slice_sample(prop = 0.5)

base_amostra %>%
  fwrite("05_FRAMEWORK_5/01_BASES/02_Base Analítica Ajustada_202201-202608_amostra.csv")


  

