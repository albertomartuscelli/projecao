pacman::p_load(tidyverse, data.table, janitor, readxl, writexl, glue, 
               broom, zoo,  stringi, tsibble,
               fable,
               fabletools,
               feasts, imputeTS)


# 1. Consumo  --------------------------------------------------------------

hist_catego = "01_CONSUMO/01_Histograma_agregado_por_categoria.csv" %>% 
  fread() %>% 
  clean_names() %>% 
  mutate(periodo = ym(paste0(ano, mes)),
         cd_ibge = str_sub(cd_ibge, 1, 6), .after = mes) %>% 
  select(-ano, -mes) %>% 
  arrange(cd_atc, catego, periodo)
         
list_periodo = hist_catego %>% distinct(periodo) %>% pull() 

# 2. Covariadas -----------------------------------------------------------

## Caged  ------------------------------------------------------


caged = "02_COVARIADAS/02_TRAT/CAGED_202607.csv" %>% 
  fread() %>%
  mutate(periodo = as.Date(periodo),
         cd_ibge = as.character(cd_ibge)) %>% 
  select(cd_ibge, periodo, caged = estoque) %>% 
  complete(cd_ibge, periodo = list_periodo) %>% 
  arrange(cd_ibge, periodo) %>% 
  mutate(caged = na_locf(caged))

## Clima  ------------------------------------------------------

clima = "02_COVARIADAS/02_TRAT/CLIMA_202608.csv" %>% 
  fread() %>% 
  mutate(periodo = as.Date(periodo),
         cd_ibge = as.character(cd_ibge)) %>% 
  select(cd_ibge, periodo, prec_tot, temp_med) 

## Nv reservatórios  ------------------------------------------------------

mananciais = "02_COVARIADAS/02_TRAT/MANANCIAIS_202608.csv" %>% 
  fread() %>% 
  mutate(periodo = as.Date(periodo)) %>% 
  distinct(periodo, nv_sim) %>% 
  mutate(nv_sim = nv_sim/100,
         lag_nv_sim = lag(nv_sim)) 

## Volume produzido  ------------------------------------------------------

# vol_prod = "02_COVARIADAS/02_TRAT/VOLUME PRODUZIDO_202607.csv" %>% 
#   fread() %>% 
#   mutate(periodo = as.Date(periodo)) %>% 
#   select(-municipio) 


## Tarifa ------------------------------------------------------------------

reais <- rep(100, 5)

base_100 = rep(100, length(list_periodo))

ipca = tibble(periodo = list_periodo,
              ipca = deflateBR::ipca(base_100, list_periodo, "12/2021"))



tarifa = "02_COVARIADAS/02_TRAT/TARIFA_202608.csv" %>% 
  fread() %>% 
  mutate(periodo = as.Date(periodo)) %>% 
  left_join(ipca, by = "periodo") %>% 
  mutate(p_agua_real = p_agua * ipca/100) %>% 
  mutate(p_indice_real = 100*p_agua_real/first(p_agua_real)) %>% 
  select(periodo, irt_real = p_indice_real)

# tarifa_w = tarifa %>% 
#   pivot_wider(names_from = categoria_detalhe, values_from = delta_tarifa)

# 2. Base consolidada ------------------------------------------------------

## Por ATC -----------------------------------------------------------

base_analitica = hist_catego %>% 
  ungroup() %>% 
  left_join(clima, by = c("cd_ibge", "periodo")) %>% 
  left_join(caged, by = c("cd_ibge", "periodo")) %>% 
  left_join(mananciais, by = c("periodo")) %>% 
  left_join(tarifa, by = c("periodo"))


# 4. Exportação --------------------------------------------------------------

ultimo_periodo = base_analitica %>%
  ungroup() %>% 
  distinct(periodo) %>% 
  filter(periodo == max(periodo)) %>% 
  pull() %>% 
  format("%Y%m")


file_output = glue("05_FRAMEWORK_4/01_BASES/01_Base Analítica_202201-{ultimo_periodo}.csv")

# Município
fwrite(base_analitica, file_output)
print(file_output)


