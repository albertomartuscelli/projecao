

# Importação
pacman::p_load(data.table, 
               tidyverse, 
               lubridate, 
               janitor,
               glue, 
               tictoc, 
               broom,
               fable,
               fable.prophet,
               fabletools, 
               readxl,
               writexl,
               forecast)


conflicted::conflicts_prefer(dplyr::first)


# Tarifa ------------------------------------------------------------------


limites <- tribble(
  ~cd_faixa, ~lim_inf, ~lim_sup,
  1,          0,        10,
  2,         10,        20,
  3,         20,        30,
  4,         30,        50,
  5,         50,        Inf
)

tabela <- "02_COVARIADAS/01_RAW/Tarifa_final.csv" %>% 
  fread() %>%
  mutate(periodo = as_date(periodo)) %>%
  left_join(limites, by = "cd_faixa") %>%
  # preço TOTAL da conta: água + esgoto (ajuste o share se tiver por ATC)
  mutate(p_tot = tarifa_agua) %>%
  select(cd_regiao, categoria_detalhe, periodo, cd_faixa, lim_inf, lim_sup,
         p_agua = tarifa_agua, p_tot)



# Avalia tabela de mudança de tarifa --------------------------------------

mudanca_tarifa = tabela %>% 
  filter(cd_regiao == "OC") %>% 
  group_by(cd_regiao, categoria_detalhe, cd_faixa) %>% 
  mutate(delta = p_agua/lag(p_agua) - 1,
         mudanca = p_agua != lag(p_agua)) %>% 
  filter(mudanca) %>% 
  select(categoria_detalhe, cd_faixa, periodo, delta) %>% 
  pivot_wider(names_from = categoria_detalhe, values_from = delta)


# Reajuste tarifário --------------------------------------


reajuste = tabela %>% 
  filter(cd_regiao == "OC", cd_faixa == 1,
         categoria_detalhe == "Residencial Normal") %>% 
  select(periodo, p_agua) %>% 
  mutate(delta = p_agua/lag(p_agua) - 1,
         p_indice = p_agua/first(p_agua))



fwrite(reajuste, "02_COVARIADAS/02_TRAT/TARIFA_202608.csv")
