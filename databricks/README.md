# Base de dados no Databricks

Três notebooks, rodados nesta ordem, geram o CSV lido pelo framework em R
(`05_FRAMEWORK_5/01_BASES/02_Base Analítica Ajustada_202201-AAAAMM.csv`).

| Notebook | Linguagem | O que faz | Tabelas principais (`sdb_sbx_adls.regulacao`) |
|---|---|---|---|
| `01_Base_Analitica_Porte.sql` | SQL | Faturas → PDE × mês; porte dos clientes; correção de volumes absurdos; base por categoria × ATC × recorte × porte | `gmm_projecao_fato_pde_mes`, `gmm_projecao_porte_pde`, `gmm_projecao_correcao_pde_mes`, `gmm_projecao_histograma_por_categoria_atc_recorte`, `gmm_projecao_grandes_clientes_pde` |
| `02_Covariaveis.py` | Python | Covariáveis direto das APIs | `gmm_projecao_cov_ipca`, `_focus_ipca`, `_reajustes`, `_tarifa`, `_clima`, `_caged`, `_municipios` |
| `03_Base_Analitica_Final.sql` | SQL (+ Python na exportação) | Ajustes de categoria, recorte, ABC, séries inválidas e mar/abr 2026; junta as covariáveis; exporta o CSV | `gmm_projecao_base_analitica` |

Os notebooks estão no formato "source" do Databricks: importe pelo workspace (*Import → File*).

## Rotina mensal

1. `02_Covariaveis` (modo `incremental`). Pode rodar a qualquer momento depois que o IPCA e o CAGED do mês
   saírem.
2. `01_Base_Analitica_Porte` (todas as células). A etapa 1 é a mais pesada.
3. `03_Base_Analitica_Final` (todas as células). Confira C1 a C4.
4. Baixe o CSV do Volume para `05_FRAMEWORK_5/01_BASES/` e rode os scripts R.

Para automatizar: um *Job* (Workflows) com as três tarefas em sequência (02 → 01 → 03), agendado no início
do mês. O Job também pode ser disparado pela API/CLI do Databricks (`databricks jobs run-now <id>`).

Download pela CLI:

```
databricks fs cp "dbfs:/Volumes/sdb_sbx_adls/regulacao/projecao/05_FRAMEWORK_5/01_BASES/02_Base Analítica Ajustada_202201-202608.csv" "05_FRAMEWORK_5/01_BASES/"
```

## Arquivos no Volume (`/Volumes/sdb_sbx_adls/regulacao/projecao`)

| Caminho | Uso | Obrigatório |
|---|---|---|
| `02_COVARIADAS/02_TRAT/CLIMA_*.csv`, `CAGED_*.csv` | Validação da migração (seção 6 do 02) | Não |
| `02_COVARIADAS/01_RAW/caged/*.xlsx` | Plano B do CAGED, se o Google Drive falhar | Não |
| `05_FRAMEWORK_5/01_BASES/antiga/*.csv` | Base antiga do R, para a comparação C5 do 03 | Não |
| `05_FRAMEWORK_5/01_BASES/*.csv` | Saída do 03 (base e amostra por chave) | — |

## Fontes das covariáveis (`02_Covariaveis.py`)

| Covariável | Fonte | Observações |
|---|---|---|
| IPCA | BCB, SGS 433 | Consultas em blocos de até 10 anos (limite da API) |
| Focus | BCB, Olinda (expectativas anuais) | Para atualizar `ipca_aa` da projeção |
| Tarifa | Tabela de reajustes no próprio notebook (deliberações da Arsesp) + IPCA | IRT real por categoria, base jan/2022 = 100; só para o fator de elasticidade da projeção. Reajuste novo = uma linha |
| Clima | NASA POWER, diário, comunidade AG | Ponto interno do polígono do município (malha do IBGE); média dos dias; `prec_tot` em **mm/dia** |
| CAGED | Google Drive do MTE (Tabela 8.1) | API do Drive com chave (secret) ou página pública da pasta; validação estoque(t) − estoque(t−1) = saldo(t) |

Pontos para validar na 1ª execução:

- **Clima**: a seção 6 compara com o CSV antigo. Diferenças pequenas são esperadas (malha municipal do IBGE
  em vez do `geobr` 2020); diferenças grandes indicam coordenada errada.
- **CAGED**: sem a API key, a leitura depende do HTML da pasta pública do Drive. Se falhar, crie a chave
  (Google Cloud → Drive API → credencial "API key"), guarde num secret scope e informe `escopo/chave` no
  widget `drive_api_key`.

## Regras da base final (`03_Base_Analitica_Final.sql`)

| Regra | Parâmetro | Padrão |
|---|---|---|
| Categorias fora | `params_categorias_excluidas` | Atacado, Outras, Industrial - DF, Comercial - DF |
| Recorte do residencial sem cadastro | `recorte_padrao` | Urbano |
| Social e Social Vulnerável rurais | — | Informal se o município tem recorte informal, senão Urbano |
| Não residencial | — | Recorte "Total" |
| ABC dos municípios | `abc_meses`, `abc_corte_a`, `abc_corte_b` | 12 meses; 80% / 95% |
| Série inválida | `grupo_min_economias`, `grupo_min_volume`, `grupo_tolerancia_meses` | 10 economias; 100 m³; 2 meses |
| Mar/abr 2026 | `bimestre_ini`, `share_*` | Volumes pela participação histórica de março; economias 50/50 |
| Santo André | `params_municipio_ajuste` | OC, ATC 72 |

O diagnóstico **D7** mostra como os clientes de mar/2026 aparecem em abril (uma fatura longa, duas faturas
ou faturamento por média). Com isso, o rebalanceamento da etapa 4 pode virar uma regra por PDE na etapa 1 do
notebook 01, e o backtest volta a avaliar março e abril separados (`meses_agrupados = list()`), sem mudar
o código do R.
