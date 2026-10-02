

# Preambulo --------------------------------------------------------------

pacman::p_load(tidyverse, tictoc, chromote, data.table, readxl, writexl,
               glue, chromote, janitor)



# Parâmetros ------------------------------------------------------------------

# URL
local = 75
freq = "mensal"
dt_inicio = "2016-12-01"
dt_fim = today()

url <- glue("https://mananciais.sabesp.com.br/base-dados?locais={local}&parametros=684&passoTemporal={freq}&periodo=outro&inicio={dt_inicio}&fim={dt_fim}")

# dir
dir = "02_COVARIADAS/02_TRAT"
dir_completo <- normalizePath(dir, mustWork = FALSE)

# label
label_mes = dt_fim %m-% 
  months(1) %>% 
  format("%Y%m")

# Exclui dados atuais ------------------------------------------------------------------


list_excluir = list.files(dir, pattern = "dados-grafico", full.names = T)

list_excluir %>% 
  map(~file.remove(.x))


# Baixa dados dos mananciais ----------------------------------------------



b <- ChromoteSession$new()

# Permite download automático
b$Browser$setDownloadBehavior(
  behavior = "allow",
  downloadPath = dir_completo
)

# Abre página
b$Page$navigate(url)
b$Page$loadEventFired(wait_ = TRUE)
Sys.sleep(2)

# Função de clique por texto visível
click_text <- function(session, texto) {
  js <- sprintf("
    (function() {
      const alvo = '%s';
      const norm = s => (s || '')
        .toLowerCase()
        .normalize('NFD')
        .replace(/[\\u0300-\\u036f]/g,'')
        .trim();

      const t = norm(alvo);

      // elementos clicáveis comuns
      const candidatos = Array.from(document.querySelectorAll(
        'button, a, [role=\"button\"], input[type=\"button\"], input[type=\"submit\"], .btn'
      ));

      let el = candidatos.find(e => {
        const txt = norm(e.innerText || e.textContent || e.value);
        return txt.includes(t);
      });

      if (!el) return 'nao_encontrado';

      el.scrollIntoView({block:'center'});
      el.click();
      return 'ok';
    })();
  ", gsub("'", "\\\\'", texto))
  
  out <- session$Runtime$evaluate(js)$result$value
  if (!identical(out, "ok")) {
    stop(sprintf("Não consegui clicar em '%s' (retorno: %s)", texto, out))
  }
}

# 1) Gerar gráfico
click_text(b, "gerar gráfico")
Sys.sleep(1)

# 2) Baixar planilha
click_text(b, "baixar planilha")
Sys.sleep(1)  # espera o download finalizar

b$close()


# Tratamento --------------------------------------------------------------

file_path = file.path(dir, "dados-grafico.xlsx")

# Importa os dados e faz ajustes
mananciais = read_xlsx(file_path) %>% 
  clean_names() %>% 
  rename(periodo = data, nv_sim = sistema_integrado_metropolitano_volume_util_percent) %>% 
  mutate(periodo = dmy(periodo)) %>% 
  filter(periodo != max(periodo))


ultimo_periodo = mananciais %>% 
  filter(periodo == max(periodo)) %>% 
  pull(periodo) %>% 
  format("%Y%m")

file_output = file.path(dir, glue("MANANCIAIS_{ultimo_periodo}.csv"))

file.remove(file_path)

## Exportação
fwrite(mananciais, file_output)
print(file_output)

