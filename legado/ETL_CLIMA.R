
# Preambulo ---------------------------------------------------------------

pacman::p_load(tidyverse, data.table, nasapower, geobr, sf,furrr, arrow, fs, tictoc, janitor, glue)
tic()

# Links 

# https://power.larc.nasa.gov/
# https://cran.r-project.org/web/packages/nasapower/index.html

# 1. Tabela com Latitude e Longitude dos municípios de SP -------------------------------

mun_sp <- geobr::read_municipality(code_muni = "SP", year = 2020) |>
  mutate(
    longitude = round(sf::st_coordinates(
      sf::st_point_on_surface(sf::st_zm(geometry))
    )[, "X"], 2),
    latitude = round(sf::st_coordinates(
      sf::st_point_on_surface(sf::st_zm(geometry))
    )[, "Y"], 2)
  ) |>
  sf::st_drop_geometry() |>
  select(code_muni, longitude, latitude)

glimpse(mun_sp)

cod_mun = "00_UTILITARIOS/HIERARQUIA COMERCIAL AJUSTADA.csv" %>% 
  fread() %>% 
  mutate(cd_ibge = str_sub(cd_ibge, 1, 6)) %>% 
  distinct(cd_ibge, municipio)

# 2. Extrai variáveis do NasaPower ------------------------------------------------------------------

## Parâmetros ------------------------------------------------------------

# Paper com uso de variáveis climáticas: https://pmc.ncbi.nlm.nih.gov/articles/PMC11473751/

vars <- c(
  "T2M", # Temperatura Média
  "T2M_MAX", # Temperatura Máxima 
  "T2M_MIN", # Temperatura Mínima
  "PRECTOTCORR", # Precipitação Corrigida
  "RH2M", #Umidade Relativa
  "T2MDEW", #Ponto de orvalho
  "WS2M" #Velocidade do Vento
)


## Função ------------------------------------------------------------------

get_clima <- function(code_muni, longitude, latitude) {
  
  dt_fim = as.character(today())
  
  out = nasapower::get_power(
    community    = "AG",
    lonlat       = c(longitude, latitude),
    pars         = vars,
    dates        = c("2010-01-01", dt_fim),
    temporal_api = "daily"
  ) |>
    mutate(code_muni = code_muni)
  
  out
}

## Baixa os dados ----------------------------------------------

handle <- curl::new_handle(timeout = 60)

future::plan(multisession, workers = parallel::detectCores() - 1)

mun_sp_clima_diario = mun_sp |>
  mutate(data = furrr::future_pmap(
    list(code_muni, longitude, latitude),
    get_clima,
    .progress = TRUE,
    .options = furrr_options(seed = TRUE)
  )) %>% 
  pull(data) %>% 
  bind_rows()

# Agrupado
mun_sp_clima_mensal = mun_sp_clima_diario %>% 
  group_by(code_muni, LON, LAT, YEAR, MM) %>% 
  summarise(across(any_of(c("PRECTOTCORR", "RH2M", "T2MDEW", "WS2M", "ALLSKY_SFC_SW_DWN", "T2M")), ~mean(., na.rm = T)),
            across(any_of(c("T2M_MIN")), ~mean(., na.rm = T)),
            across(any_of(c("T2M_MAX")), ~mean(., na.rm = T))) %>% 
  ungroup() %>% 
  mutate(code_muni = str_sub(code_muni, 1, 6),
         periodo = ym(paste0(YEAR, str_pad(MM, width = 2, pad = "0")))) %>% 
  rename(CD_IBGE = code_muni, 
         UMI_REL = RH2M,
         VEL_VENTO = WS2M,
         PREC_TOT = PRECTOTCORR,
         TEMP_ORV = T2MDEW,
         TEMP_MED = T2M,
         TEMP_MIN = T2M_MIN,
         TEMP_MAX = T2M_MAX) %>% 
  clean_names() %>% 
  inner_join(cod_mun, by = "cd_ibge") %>% 
  select(cd_ibge, municipio, periodo, prec_tot:temp_max) %>% 
  arrange(cd_ibge, periodo) %>% 
  filter(periodo != max(periodo)) %>% # Retira o último mês (período incompleto)   
  clean_names() 



# Exporta

ultimo_periodo = mun_sp_clima_mensal %>%
  ungroup() %>% 
  distinct(periodo) %>% 
  filter(periodo == max(periodo)) %>% 
  pull() %>% 
  format("%Y%m")

dir_output = "02_COVARIADAS/02_TRAT"
file_output = glue("02_COVARIADAS/02_TRAT/CLIMA_{ultimo_periodo}.csv")

## Exportação
fwrite(mun_sp_clima_mensal, file_output)
print(file_output)
