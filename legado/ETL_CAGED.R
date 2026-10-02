
# Preambulo ---------------------------------------------------------------

pacman::p_load("googledrive", "tidyverse", "data.table", "glue", "readxl", "janitor")


# De-para Municípios
cod_mun = "01_CONSUMO/00_RAW/HIERARQUIA COMERCIAL AJUSTADA.csv" %>% 
  fread() %>% 
  mutate(cd_ibge = str_sub(cd_ibge, 1, 6)) %>% 
  distinct(cd_ibge, municipio) %>% 
  filter(!is.na(cd_ibge))

# 1. Informações do google drive --------------------------------------------

# Caminho do drive: https://drive.google.com/drive/folders/1DSI-ylLcZc_ELKb1M50MgDDi3CLo_iaY
folder_id <- as_id("1DSI-ylLcZc_ELKb1M50MgDDi3CLo_iaY")

# Lista as pastas no drive
pastas <- drive_ls(
  path = folder_id,
  type = "folder")

pastas = pastas %>% 
  mutate(periodo = ym(name))

# Período mais recente divulgado
ultimo_periodo = pastas %>% 
  filter(periodo == max(periodo)) %>% 
  pull(periodo)

# Id
ultimo_id = pastas %>% 
  filter(periodo == ultimo_periodo) %>% 
  pull(id)

# Nome do arquivo
arquivo_xlsx <- drive_ls(ultimo_id) %>%
  filter(grepl("\\.xlsx$", name, ignore.case = TRUE)) %>% 
  slice(1)

# Baixa os aquivos num diretório temporário
tmp <- tempfile(fileext = ".xlsx")
drive_download(file = arquivo_xlsx, path = tmp, overwrite = TRUE)


# 2. ETL da base ------------------------------------------------------

## Parâmetros ------------------------------------------------------

# Período Inicial da base
primeiro_periodo = ymd("2020-01-01")

# Último mês
label_ultimo_mes = format(ultimo_periodo, "%Y%m")

# Lista de meses
meses <- seq(from = primeiro_periodo, to = ultimo_periodo, by = "month")
label_meses = paste0("_", format(meses, "%Y%m"))

# N° de meses
delta_meses = length(meses)

# Caminho dos output
dir_output = "02_COVARIADAS/02_TRAT"
file_output_mun = file.path(dir_output, glue("CAGED por município_{label_ultimo_mes}.csv"))
#file_output_reg = file.path(dir_output, glue("VAR_CAGED_UO_{label_ultimo_mes}.csv"))

## Ajuste de nomes ------------------------------------------------------

# Variáveis
vars = c(
  "estoque", # estoque
  "adm", # admissões
  "deslig", # desligamentos
  "saldo", # saldos
  "vr" # variação relativa
)

seq_var = c("uf", "cod_ibge", "municipio",
            vars[-5],
            rep(vars, delta_meses-1),
            rep("drop", 8))

# Período
seq_periodo = c(rep("", 3),
                rep(label_meses[1], 4),
                rep(label_meses[-1], each = 5),
                1:8)

# Df de ajuste
ajust_nome = tibble(var = seq_var,
                 periodo = seq_periodo) %>% 
  mutate(new_names = paste0(var, periodo))

## De-para municípios ------------------------------------------------------

## Importação e Tratamento ------------------------------------------------------

# Importação
caged <- read_excel(tmp, sheet = "Tabela 8.1",
                    col_names = TRUE, 
                    skip = 5) 

# Ajuste dos nomes
colnames(caged) = ajust_nome$new_names

# Filtra só SP
caged = caged %>% 
  filter(uf == "SP")

# Retira as variaveis não utilizadas
caged = caged %>% 
  select(!starts_with("drop")) %>% 
  select(!starts_with("vr"))

# Pivota no nível dos municípios
caged_mun = caged %>% 
  mutate(across(!uf:municipio, as.integer)) %>% 
  pivot_longer(!uf:municipio, names_to = "var", values_to = "valor") %>%
  separate(var, into = c("var", "periodo")) %>% 
  mutate(periodo = ym(periodo)) %>% 
  pivot_wider(names_from = var, values_from = valor)

# estoque de emprego municipal
est_emprego_caged = caged_mun %>% 
  select(cd_ibge = cod_ibge, periodo, estoque) %>% 
  mutate(cd_ibge = as.character(cd_ibge))

# 3. Dados LCA (Pré 2020) ----------------------------------------------------

# 4. Estoque de emprego municipal -----------------------------------------

# base final
est_emprego_mun_final = est_emprego_caged %>% 
  inner_join(cod_mun, by = "cd_ibge") %>% 
  relocate(cd_ibge, municipio,  periodo, estoque)

# Visualiza wider
est_emprego_mun_final_wider = est_emprego_mun_final %>% 
  pivot_wider(names_from = periodo, values_from = estoque)

ultimo_periodo = est_emprego_mun_final %>%
  ungroup() %>% 
  distinct(periodo) %>% 
  filter(periodo == max(periodo)) %>% 
  pull() %>% 
  format("%Y%m")

dir_output = "02_COVARIADAS/02_TRAT"
file_output_mun = glue("02_COVARIADAS/02_TRAT/CAGED_{ultimo_periodo}.csv")

## Exportação
fwrite(est_emprego_mun_final, file_output_mun)
print(file_output_mun)

