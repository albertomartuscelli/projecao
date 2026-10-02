# Scripts antigos (referência)

Scripts R que montavam a base analítica e as covariáveis antes da migração para o Databricks.
Não são mais usados; ficam aqui para rastrear as regras.

| Script antigo | Substituído por |
|---|---|
| `01_Base_Analitica.R` (consumo + covariáveis) | `databricks/03_Base_Analitica_Final.sql`, etapa 5 |
| `02_Analise_Exploratoria_e_Ajustes.R` (categorias, recorte, ABC, séries inválidas, mar/abr 2026) | `databricks/03_Base_Analitica_Final.sql`, etapas 1 a 4 |
| `ETL_CAGED.R` (Google Drive do MTE) | `databricks/02_Covariaveis.py`, seção 6 |
| `ETL_CLIMA.R` (NASA POWER) | `databricks/02_Covariaveis.py`, seção 4 |
| `ETL_MANANCIAIS.R` (site da Sabesp via chromote) | `databricks/02_Covariaveis.py`, seção 5 (API v4) |
| `ETL_TARIFA_v4.R` + IPCA do `deflateBR` | `databricks/02_Covariaveis.py`, seções 2 e 3 |

As correções feitas na migração estão no cabeçalho do `03_Base_Analitica_Final.sql` e no README principal.
