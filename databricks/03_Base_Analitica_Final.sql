-- Databricks notebook source
-- MAGIC %md
-- MAGIC # Base analítica final (consumo + covariáveis)
-- MAGIC
-- MAGIC Junta a base de consumo do `01_Base_Analitica_Porte` com as covariáveis do `02_Covariaveis` e aplica
-- MAGIC os ajustes que eram feitos no R (`01_Base_Analitica.R` e `02_Análise_Exploratória_e_Ajustes.R`). A saída
-- MAGIC é o CSV `05_FRAMEWORK_5/01_BASES/02_Base Analítica Ajustada_202201-AAAAMM.csv`, lido pelos backtests e
-- MAGIC pela projeção (`carrega_base()`).
-- MAGIC
-- MAGIC | Etapa | O que faz | Tabela |
-- MAGIC |---|---|---|
-- MAGIC | 0 | Parâmetros | temp views `params*` |
-- MAGIC | 1 | Consumo por série × porte × mês: Santo André, categorias fora, recorte | `gmm_projecao_base_etapa1` |
-- MAGIC | 2 | Classificação ABC dos municípios (volume dos últimos 12 meses) | `gmm_projecao_base_abc` |
-- MAGIC | 3 | Séries inválidas (curtas, encerradas ou pequenas) | `gmm_projecao_base_series` |
-- MAGIC | 4 | Rebalanceamento de mar/abr 2026 | `gmm_projecao_base_etapa4` |
-- MAGIC | 5 | Covariáveis e base final | `gmm_projecao_base_analitica` |
-- MAGIC | 6 | Exportação do CSV (e amostra por chave) para o Volume | — |
-- MAGIC | C1–C5 | Conciliação de volumes, duplicatas, covariáveis, mar/abr e comparação com a base antiga | — |
-- MAGIC | D7 | Padrão do faturamento atrasado de mar/2026 (para trocar o rebalanceamento por uma regra por PDE) | — |
-- MAGIC
-- MAGIC **Correções em relação aos scripts R**
-- MAGIC
-- MAGIC | # | No R | Aqui |
-- MAGIC |---|---|---|
-- MAGIC | 1 | Recorte `null`/`0` excluído antes de o não residencial virar "Total" (perdia volume não residencial) | Não residencial vira "Total" antes; no residencial, recorte nulo vira "Urbano" (C1 mostra o volume) |
-- MAGIC | 2 | Séries inválidas pela média por linha de `catego` (subestimava séries com várias `catego`) | Média do total mensal da série, somando os portes (grandes clientes não caem no corte de 10 economias) |
-- MAGIC | 3 | Série sem o último mês excluída inteira | Tolerância de 2 meses (`grupo_tolerancia_meses`) |
-- MAGIC | 4 | Mar/abr 2026: economias rateadas pela participação do volume | Economias e ligações interpoladas entre fev e mai (são estoque); volumes pela participação histórica |
-- MAGIC | 5 | Chave sem histórico de mar/abr ficava com volume NA | Participação padrão (0,505) |
-- MAGIC | 6 | ABC por um único mês (ago/2026) | Últimos 12 meses (`abc_meses`; 1 = regra antiga) |
-- MAGIC | 7 | `na_locf` do CAGED sem agrupar por município | Último valor dentro de cada município |
-- MAGIC | 8 | IPCA do `deflateBR` (mês sem índice = tarifa NA) | IPCA do BCB; mês sem índice repete o último (notebook 02) |
-- MAGIC | 9 | Amostra por linha (`slice_sample`): séries com meses faltando | Amostra por chave |
-- MAGIC | 10 | Santo André corrigido no código | Tabela de ajuste `params_municipio_ajuste` (o certo é corrigir o `gmm_cod_ibge`) |

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ## Etapa 0 — Parâmetros

-- COMMAND ----------

CREATE OR REPLACE TEMP VIEW params AS
SELECT
  DATE'2022-01-01' AS periodo_ini,             -- início da base
  'Urbano'         AS recorte_padrao,          -- recorte do residencial sem recorte no cadastro
  12               AS abc_meses,               -- meses para a classificação ABC (R antigo: 1)
  0.80             AS abc_corte_a,             -- municípios até 80% do volume acumulado = A
  0.95             AS abc_corte_b,             -- até 95% = B, resto = C
  10               AS grupo_min_economias,     -- série inválida: média < 10 economias/mês
  100              AS grupo_min_volume,        -- ou média < 100 m³/mês
  2                AS grupo_tolerancia_meses,  -- ou mais de 2 meses sem dado no fim (R antigo: 0)
  DATE'2026-03-01' AS bimestre_ini,            -- mar/abr 2026 rebalanceados (NULL desliga)
  0.40             AS share_min,               -- participação de março fora de 0,40 a 0,60
  0.60             AS share_max,
  0.505            AS share_padrao;            -- ... ou sem histórico: usa 0,505

-- Categorias fora da base: sem modelo, precisam de premissa própria se a projeção fechar o total
CREATE OR REPLACE TEMP VIEW params_categorias_excluidas AS
SELECT * FROM VALUES ('Atacado'), ('Outras'), ('Industrial - DF'), ('Comercial - DF') AS t(categoria_detalhe);

-- Ajustes de município fora do de-para (Santo André, igual ao 02 do R)
CREATE OR REPLACE TEMP VIEW params_municipio_ajuste AS
SELECT * FROM VALUES ('354780', 'OC', 'SANTO ANDRE', 72) AS t(cd_ibge, cd_regiao, municipio, cd_atc);

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ## Etapa 1 — Consumo por série × porte × mês
-- MAGIC
-- MAGIC 1. Período, código IBGE de 6 dígitos (o das covariáveis) e Santo André.
-- MAGIC 2. Categorias fora (`params_categorias_excluidas`).
-- MAGIC 3. Recorte, nesta ordem:
-- MAGIC    - não residencial: "Total";
-- MAGIC    - residencial sem recorte (`NULL`, `'null'`, `'0'`): `recorte_padrao`;
-- MAGIC    - Social e Social Vulnerável rurais: "Informal" se o município tem recorte informal, senão "Urbano"
-- MAGIC      (séries rurais sociais são muito pequenas).
-- MAGIC 4. Soma das `catego` de cada série. `SUM` ignora nulos: uma `catego` sem esgoto não anula o esgoto da série
-- MAGIC    (no R, `sum()` sem `na.rm` deixava a série inteira NA).

-- COMMAND ----------

CREATE OR REPLACE TABLE `sdb_sbx_adls`.`regulacao`.`gmm_projecao_base_etapa1` AS
WITH

h AS (
  SELECT
    make_date(CAST(h.ANO AS INT), CAST(h.MES AS INT), 1) AS periodo,
    SUBSTR(CAST(h.cd_ibge AS STRING), 1, 6)               AS cd_ibge,
    h.SG_SUPERINTENDENCIA                                 AS cd_regiao_orig,
    h.MUNICIPIO                                           AS municipio_orig,
    CAST(h.CD_ATC AS INT)                                 AS cd_atc_orig,
    h.CATEGORIA                                           AS categoria,
    h.CATEGORIA_DETALHE                                   AS categoria_detalhe,
    h.porte,
    CASE WHEN h.TP_RECORTE IS NULL OR TRIM(CAST(h.TP_RECORTE AS STRING)) IN ('', 'null', 'NULL', '0')
         THEN NULL ELSE TRIM(CAST(h.TP_RECORTE AS STRING)) END AS recorte_orig,
    h.vol_med_agua, h.vol_med_esg, h.vol_fat_agua, h.vol_fat_esg,
    h.vol_med_agua_bruto, h.vol_fat_agua_bruto,
    h.n_economias_agua, h.n_economias_esg, h.n_ligacoes_agua, h.n_ligacoes_esg,
    h.qtd_registros, h.qt_dias
  FROM `sdb_sbx_adls`.`regulacao`.`gmm_projecao_histograma_por_categoria_atc_recorte` h
  WHERE make_date(CAST(h.ANO AS INT), CAST(h.MES AS INT), 1) >= (SELECT periodo_ini FROM params)
    AND h.CATEGORIA_DETALHE NOT IN (SELECT categoria_detalhe FROM params_categorias_excluidas)
),

ajuste AS (
  SELECT h.*,
         COALESCE(a.cd_regiao, h.cd_regiao_orig) AS cd_regiao,
         COALESCE(a.municipio, h.municipio_orig) AS municipio,
         COALESCE(a.cd_atc,    h.cd_atc_orig)    AS cd_atc
  FROM h
  LEFT JOIN params_municipio_ajuste a ON h.cd_ibge = a.cd_ibge
),

informal AS (
  SELECT municipio, BOOL_OR(recorte_orig = 'Informal') AS tem_informal
  FROM ajuste
  GROUP BY municipio
),

recorte AS (
  SELECT a.*,
    CASE WHEN a.categoria <> 'Residencial'                         THEN 'Total'
         WHEN a.recorte_orig IS NULL                               THEN (SELECT recorte_padrao FROM params)
         WHEN a.categoria_detalhe LIKE 'Residencial Social%' AND a.recorte_orig = 'Rural'
              AND i.tem_informal                                   THEN 'Informal'
         WHEN a.categoria_detalhe LIKE 'Residencial Social%' AND a.recorte_orig = 'Rural'
                                                                   THEN 'Urbano'
         ELSE a.recorte_orig END                                   AS recorte,
    a.categoria = 'Residencial' AND a.recorte_orig IS NULL         AS recorte_imputado
  FROM ajuste a
  JOIN informal i USING (municipio)
)

SELECT
  cd_regiao, municipio, cd_ibge, cd_atc, categoria, categoria_detalhe, recorte, porte, periodo,
  SUM(vol_med_agua)       AS vol_med_agua,
  SUM(vol_med_esg)        AS vol_med_esg,
  SUM(vol_fat_agua)       AS vol_fat_agua,
  SUM(vol_fat_esg)        AS vol_fat_esg,
  SUM(n_economias_agua)   AS n_economias_agua,
  SUM(n_economias_esg)    AS n_economias_esg,
  SUM(n_ligacoes_agua)    AS n_ligacoes_agua,
  SUM(n_ligacoes_esg)     AS n_ligacoes_esg,
  SUM(qtd_registros)      AS qtd_registros,
  SUM(qt_dias)            AS qt_dias,
  SUM(vol_med_agua_bruto) AS vol_med_agua_bruto,
  SUM(vol_fat_agua_bruto) AS vol_fat_agua_bruto,
  SUM(CASE WHEN recorte_imputado THEN vol_med_agua ELSE 0 END) AS vol_med_agua_recorte_imputado
FROM recorte
GROUP BY cd_regiao, municipio, cd_ibge, cd_atc, categoria, categoria_detalhe, recorte, porte, periodo;

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ## Etapa 2 — Classificação ABC dos municípios
-- MAGIC
-- MAGIC Volume medido de água dos últimos `abc_meses` meses, todas as categorias da base. Ordenando do maior para o
-- MAGIC menor: **A** até 80% do volume acumulado, **B** até 95%, **C** o resto. Define o agrupamento
-- MAGIC `G1_municipioA_clusterBC` (municípios A individuais; B e C agrupados por superintendência).

-- COMMAND ----------

CREATE OR REPLACE TABLE `sdb_sbx_adls`.`regulacao`.`gmm_projecao_base_abc` AS
WITH
vol AS (
  SELECT municipio, SUM(vol_med_agua) AS vol
  FROM `sdb_sbx_adls`.`regulacao`.`gmm_projecao_base_etapa1`
  WHERE periodo > add_months((SELECT MAX(periodo) FROM `sdb_sbx_adls`.`regulacao`.`gmm_projecao_base_etapa1`),
                             -(SELECT abc_meses FROM params))
  GROUP BY municipio
),
acum AS (
  SELECT municipio, vol,
         SUM(vol) OVER (ORDER BY vol DESC, municipio ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
           / SUM(vol) OVER () AS perc_acum
  FROM vol
)
SELECT municipio, vol AS vol_abc, perc_acum,
       CASE WHEN perc_acum <= (SELECT abc_corte_a FROM params) THEN 'A'
            WHEN perc_acum <= (SELECT abc_corte_b FROM params) THEN 'B'
            ELSE 'C' END AS classificacao_abc
FROM acum;

-- COMMAND ----------

SELECT classificacao_abc, COUNT(*) AS municipios, ROUND(100 * SUM(vol_abc) / SUM(SUM(vol_abc)) OVER (), 1) AS perc_volume
FROM `sdb_sbx_adls`.`regulacao`.`gmm_projecao_base_abc`
GROUP BY 1 ORDER BY 1;

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ## Etapa 3 — Séries válidas
-- MAGIC
-- MAGIC Série = superintendência × município × ATC × categoria × recorte, **somando os portes**: os grandes clientes
-- MAGIC têm poucas economias por construção e não podem cair no corte de economias. Inválida se:
-- MAGIC - encerrada: mais de `grupo_tolerancia_meses` meses sem dado no fim da base (no R, bastava faltar o último), ou
-- MAGIC - média mensal < `grupo_min_economias` economias de água, ou
-- MAGIC - média mensal < `grupo_min_volume` m³ medidos de água.

-- COMMAND ----------

CREATE OR REPLACE TABLE `sdb_sbx_adls`.`regulacao`.`gmm_projecao_base_series` AS
WITH
mensal AS (
  SELECT cd_regiao, municipio, cd_ibge, cd_atc, categoria, categoria_detalhe, recorte, periodo,
         SUM(n_economias_agua) AS econ, SUM(vol_med_agua) AS vol
  FROM `sdb_sbx_adls`.`regulacao`.`gmm_projecao_base_etapa1`
  GROUP BY ALL
),
estat AS (
  SELECT cd_regiao, municipio, cd_ibge, cd_atc, categoria, categoria_detalhe, recorte,
         COUNT(DISTINCT periodo) AS n_periodos,
         MIN(periodo)            AS primeiro_periodo,
         MAX(periodo)            AS ultimo_periodo,
         AVG(econ)               AS media_economias,
         AVG(vol)                AS media_volume
  FROM mensal
  GROUP BY ALL
)
SELECT e.*,
  CASE WHEN e.ultimo_periodo < add_months(m.fim, -p.grupo_tolerancia_meses) THEN 'encerrada'
       WHEN COALESCE(e.media_economias, 0) < p.grupo_min_economias       THEN 'poucas economias'
       WHEN COALESCE(e.media_volume, 0) < p.grupo_min_volume             THEN 'pouco volume'
  END AS motivo_exclusao
FROM estat e
CROSS JOIN (SELECT MAX(periodo) AS fim FROM mensal) m
CROSS JOIN params p;

-- COMMAND ----------

SELECT COALESCE(motivo_exclusao, 'válida') AS situacao, categoria_detalhe, COUNT(*) AS series,
       ROUND(SUM(media_volume)) AS volume_medio_mensal
FROM `sdb_sbx_adls`.`regulacao`.`gmm_projecao_base_series`
GROUP BY 1, 2 ORDER BY 2, 1;

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ## Etapa 4 — Rebalanceamento de mar/abr 2026
-- MAGIC
-- MAGIC Problema de faturamento: clientes de mar/2026 faturaram em abr/2026. Só o total do bimestre é confiável.
-- MAGIC Mesma lógica do R, com duas correções:
-- MAGIC - **Volumes** (medido e faturado, água e esgoto): março = `s` × total do bimestre; abril = (1 − `s`) × total.
-- MAGIC   `s` = mediana, em 2022-2025, da participação de março no volume medido de água do bimestre, por série × porte;
-- MAGIC   fora de [`share_min`, `share_max`] ou sem histórico, `share_padrao`.
-- MAGIC - **Economias e ligações**: interpolação linear entre fevereiro e maio, por série × porte. São estoque, e o
-- MAGIC   março bruto traz uma reclassificação entre Social e Social Vulnerável (+6% e −6%) que a divisão 50/50 espalhava
-- MAGIC   para abril. Série sem fevereiro ou sem maio: metade da soma do bimestre.
-- MAGIC - **Divisão entre categorias residenciais**: em mar/2026 houve uma reclassificação temporária de Social
-- MAGIC   Vulnerável para Social (volume do bimestre: Social +5,3% e Vulnerável −4,0% sobre 2× fevereiro; somados, +2,1%,
-- MAGIC   igual ao Normal). O volume do bimestre de cada grupo (superintendência, município, ATC, categoria, recorte e
-- MAGIC   porte) é redistribuído entre as `categoria_detalhe` pela divisão de fevereiro + maio. O total do grupo não muda;
-- MAGIC   no não residencial o grupo tem uma categoria só e nada muda. PDEs com duas categorias no mesmo mês são
-- MAGIC   estruturais (~79 mil por mês, ~1,55% do volume, sem pico em março) e não explicam o problema.
-- MAGIC - **Faturas e dias**: metade em cada mês.
-- MAGIC
-- MAGIC O backtest continua avaliando mar+abr como um bimestre (`meses_agrupados`). O D7 mostrou que não faltaram
-- MAGIC clientes em março: o ciclo de leitura encurtou (mediana de 29 dias) e o de abril alongou (32 dias). O volume por dia
-- MAGIC ficou estável, e a participação histórica divide o bimestre de forma equivalente à divisão pelos dias.

-- COMMAND ----------

CREATE OR REPLACE TABLE `sdb_sbx_adls`.`regulacao`.`gmm_projecao_base_etapa4` AS
WITH
p AS (SELECT * FROM params),

validas AS (
  SELECT b.*
  FROM `sdb_sbx_adls`.`regulacao`.`gmm_projecao_base_etapa1` b
  JOIN `sdb_sbx_adls`.`regulacao`.`gmm_projecao_base_series` s
    USING (cd_regiao, municipio, cd_ibge, cd_atc, categoria, categoria_detalhe, recorte)
  WHERE s.motivo_exclusao IS NULL
),

share_ano AS (
  SELECT cd_regiao, municipio, cd_ibge, cd_atc, categoria, categoria_detalhe, recorte, porte, YEAR(periodo) AS ano,
         SUM(CASE WHEN MONTH(periodo) = MONTH(p.bimestre_ini) THEN vol_med_agua END) / NULLIF(SUM(vol_med_agua), 0) AS s
  FROM validas CROSS JOIN p
  WHERE p.bimestre_ini IS NOT NULL
    AND MONTH(periodo) IN (MONTH(p.bimestre_ini), MONTH(add_months(p.bimestre_ini, 1)))
    AND YEAR(periodo) < YEAR(p.bimestre_ini)
  GROUP BY ALL
),

share AS (
  SELECT cd_regiao, municipio, cd_ibge, cd_atc, categoria, categoria_detalhe, recorte, porte,
         PERCENTILE(s, 0.5) AS s
  FROM share_ano
  GROUP BY ALL
),

bimestre_bruto AS (
  SELECT v.cd_regiao, v.municipio, v.cd_ibge, v.cd_atc, v.categoria, v.categoria_detalhe, v.recorte, v.porte,
         CASE WHEN sh.s BETWEEN p.share_min AND p.share_max THEN sh.s ELSE p.share_padrao END AS s,
         p.bimestre_ini,
         SUM(v.vol_med_agua) AS vol_med_agua, SUM(v.vol_med_esg) AS vol_med_esg,
         SUM(v.vol_fat_agua) AS vol_fat_agua, SUM(v.vol_fat_esg) AS vol_fat_esg,
         SUM(v.vol_med_agua_bruto) AS vol_med_agua_bruto, SUM(v.vol_fat_agua_bruto) AS vol_fat_agua_bruto,
         SUM(v.vol_med_agua_recorte_imputado) AS vol_med_agua_recorte_imputado,
         SUM(v.n_economias_agua) AS n_economias_agua, SUM(v.n_economias_esg) AS n_economias_esg,
         SUM(v.n_ligacoes_agua) AS n_ligacoes_agua, SUM(v.n_ligacoes_esg) AS n_ligacoes_esg,
         SUM(v.qtd_registros) AS qtd_registros, SUM(v.qt_dias) AS qt_dias
  FROM validas v
  CROSS JOIN p
  LEFT JOIN share sh USING (cd_regiao, municipio, cd_ibge, cd_atc, categoria, categoria_detalhe, recorte, porte)
  WHERE v.periodo IN (p.bimestre_ini, add_months(p.bimestre_ini, 1))
  GROUP BY ALL
),

-- Volume de cada série em fevereiro + maio (meses vizinhos sem o problema)
vizinhos_vol AS (
  SELECT v.cd_regiao, v.municipio, v.cd_ibge, v.cd_atc, v.categoria, v.categoria_detalhe, v.recorte, v.porte,
         SUM(v.vol_med_agua) AS fm_med_agua, SUM(v.vol_med_esg) AS fm_med_esg,
         SUM(v.vol_fat_agua) AS fm_fat_agua, SUM(v.vol_fat_esg) AS fm_fat_esg
  FROM validas v
  CROSS JOIN p
  WHERE v.periodo IN (add_months(p.bimestre_ini, -1), add_months(p.bimestre_ini, 2))
  GROUP BY v.cd_regiao, v.municipio, v.cd_ibge, v.cd_atc, v.categoria, v.categoria_detalhe, v.recorte, v.porte
),

-- Em mar/2026 houve reclassificação temporária entre categorias residenciais
-- (Social Vulnerável -> Social): o total da série está certo, a divisão não.
-- O volume do bimestre de cada grupo (mesma superintendência, município, ATC,
-- categoria, recorte e porte) é redistribuído entre as categorias_detalhe pela
-- divisão de fev+mai. No não residencial o grupo tem uma categoria só (nada muda).
-- Séries sem fev/mai mantêm o próprio volume. O total do grupo é preservado.
grupo_bim AS (
  SELECT b.*, z.fm_med_agua, z.fm_med_esg, z.fm_fat_agua, z.fm_fat_esg,
    SUM(CASE WHEN z.fm_med_agua > 0 THEN b.vol_med_agua END) OVER w AS g_bim_med_agua,
    SUM(CASE WHEN z.fm_med_agua > 0 THEN z.fm_med_agua END)  OVER w AS g_fm_med_agua,
    SUM(CASE WHEN z.fm_med_esg  > 0 THEN b.vol_med_esg END)  OVER w AS g_bim_med_esg,
    SUM(CASE WHEN z.fm_med_esg  > 0 THEN z.fm_med_esg END)   OVER w AS g_fm_med_esg,
    SUM(CASE WHEN z.fm_fat_agua > 0 THEN b.vol_fat_agua END) OVER w AS g_bim_fat_agua,
    SUM(CASE WHEN z.fm_fat_agua > 0 THEN z.fm_fat_agua END)  OVER w AS g_fm_fat_agua,
    SUM(CASE WHEN z.fm_fat_esg  > 0 THEN b.vol_fat_esg END)  OVER w AS g_bim_fat_esg,
    SUM(CASE WHEN z.fm_fat_esg  > 0 THEN z.fm_fat_esg END)   OVER w AS g_fm_fat_esg
  FROM bimestre_bruto b
  LEFT JOIN vizinhos_vol z USING (cd_regiao, municipio, cd_ibge, cd_atc, categoria, categoria_detalhe, recorte, porte)
  WINDOW w AS (PARTITION BY b.cd_regiao, b.municipio, b.cd_ibge, b.cd_atc, b.categoria, b.recorte, b.porte)
),

bimestre AS (
  SELECT cd_regiao, municipio, cd_ibge, cd_atc, categoria, categoria_detalhe, recorte, porte, s, bimestre_ini,
         med_agua AS vol_med_agua, med_esg AS vol_med_esg, fat_agua AS vol_fat_agua, fat_esg AS vol_fat_esg,
         vol_med_agua_bruto * f_med AS vol_med_agua_bruto, vol_fat_agua_bruto * f_fat AS vol_fat_agua_bruto,
         vol_med_agua_recorte_imputado * f_med AS vol_med_agua_recorte_imputado,
         n_economias_agua, n_economias_esg, n_ligacoes_agua, n_ligacoes_esg, qtd_registros, qt_dias
  FROM (
    SELECT *,
      CASE WHEN fm_med_agua > 0 THEN g_bim_med_agua * fm_med_agua / g_fm_med_agua ELSE vol_med_agua END AS med_agua,
      CASE WHEN fm_med_esg  > 0 THEN g_bim_med_esg  * fm_med_esg  / g_fm_med_esg  ELSE vol_med_esg  END AS med_esg,
      CASE WHEN fm_fat_agua > 0 THEN g_bim_fat_agua * fm_fat_agua / g_fm_fat_agua ELSE vol_fat_agua END AS fat_agua,
      CASE WHEN fm_fat_esg  > 0 THEN g_bim_fat_esg  * fm_fat_esg  / g_fm_fat_esg  ELSE vol_fat_esg  END AS fat_esg,
      COALESCE(CASE WHEN fm_med_agua > 0 THEN g_bim_med_agua * fm_med_agua / g_fm_med_agua END
               / NULLIF(vol_med_agua, 0), 1) AS f_med,
      COALESCE(CASE WHEN fm_fat_agua > 0 THEN g_bim_fat_agua * fm_fat_agua / g_fm_fat_agua END
               / NULLIF(vol_fat_agua, 0), 1) AS f_fat
    FROM grupo_bim
  )
),

-- Estoques (economias, ligações) no mês antes e no mês depois do bimestre
vizinhos AS (
  SELECT v.cd_regiao, v.municipio, v.cd_ibge, v.cd_atc, v.categoria, v.categoria_detalhe, v.recorte, v.porte,
         SUM(CASE WHEN v.periodo = add_months(p.bimestre_ini, -1) THEN v.n_economias_agua END) AS econ_agua_ant,
         SUM(CASE WHEN v.periodo = add_months(p.bimestre_ini, 2)  THEN v.n_economias_agua END) AS econ_agua_dep,
         SUM(CASE WHEN v.periodo = add_months(p.bimestre_ini, -1) THEN v.n_economias_esg END)  AS econ_esg_ant,
         SUM(CASE WHEN v.periodo = add_months(p.bimestre_ini, 2)  THEN v.n_economias_esg END)  AS econ_esg_dep,
         SUM(CASE WHEN v.periodo = add_months(p.bimestre_ini, -1) THEN v.n_ligacoes_agua END)  AS lig_agua_ant,
         SUM(CASE WHEN v.periodo = add_months(p.bimestre_ini, 2)  THEN v.n_ligacoes_agua END)  AS lig_agua_dep,
         SUM(CASE WHEN v.periodo = add_months(p.bimestre_ini, -1) THEN v.n_ligacoes_esg END)   AS lig_esg_ant,
         SUM(CASE WHEN v.periodo = add_months(p.bimestre_ini, 2)  THEN v.n_ligacoes_esg END)   AS lig_esg_dep
  FROM validas v
  CROSS JOIN p
  WHERE v.periodo IN (add_months(p.bimestre_ini, -1), add_months(p.bimestre_ini, 2))
  GROUP BY v.cd_regiao, v.municipio, v.cd_ibge, v.cd_atc, v.categoria, v.categoria_detalhe, v.recorte, v.porte
),

-- Estoques do bimestre: interpolação linear entre o mês anterior e o seguinte
-- (k = 1 em março, 2 em abril, sobre 3 intervalos). Sem um dos vizinhos, metade
-- da soma do bimestre.
bimestre_estoque AS (
  SELECT b.*, m.k,
         COALESCE(z.econ_agua_ant + (z.econ_agua_dep - z.econ_agua_ant) * m.k / 3, b.n_economias_agua / 2) AS econ_agua_i,
         COALESCE(z.econ_esg_ant  + (z.econ_esg_dep  - z.econ_esg_ant)  * m.k / 3, b.n_economias_esg / 2)  AS econ_esg_i,
         COALESCE(z.lig_agua_ant  + (z.lig_agua_dep  - z.lig_agua_ant)  * m.k / 3, b.n_ligacoes_agua / 2)  AS lig_agua_i,
         COALESCE(z.lig_esg_ant   + (z.lig_esg_dep   - z.lig_esg_ant)   * m.k / 3, b.n_ligacoes_esg / 2)   AS lig_esg_i
  FROM bimestre b
  CROSS JOIN (SELECT 1 AS k UNION ALL SELECT 2 AS k) m
  LEFT JOIN vizinhos z USING (cd_regiao, municipio, cd_ibge, cd_atc, categoria, categoria_detalhe, recorte, porte)
),

rebalanceado AS (
  SELECT cd_regiao, municipio, cd_ibge, cd_atc, categoria, categoria_detalhe, recorte, porte,
         bimestre_ini AS periodo,
         vol_med_agua * s, vol_med_esg * s, vol_fat_agua * s, vol_fat_esg * s,
         econ_agua_i, econ_esg_i, lig_agua_i, lig_esg_i,
         qtd_registros / 2, qt_dias / 2,
         vol_med_agua_bruto * s, vol_fat_agua_bruto * s, vol_med_agua_recorte_imputado * s,
         TRUE
  FROM bimestre_estoque
  WHERE k = 1
  UNION ALL
  SELECT cd_regiao, municipio, cd_ibge, cd_atc, categoria, categoria_detalhe, recorte, porte,
         add_months(bimestre_ini, 1),
         vol_med_agua * (1 - s), vol_med_esg * (1 - s), vol_fat_agua * (1 - s), vol_fat_esg * (1 - s),
         econ_agua_i, econ_esg_i, lig_agua_i, lig_esg_i,
         qtd_registros / 2, qt_dias / 2,
         vol_med_agua_bruto * (1 - s), vol_fat_agua_bruto * (1 - s), vol_med_agua_recorte_imputado * (1 - s),
         TRUE
  FROM bimestre_estoque
  WHERE k = 2
)

-- Mesma ordem de colunas da etapa 1 (+ rebalanceado)
SELECT v.*, FALSE AS rebalanceado
FROM validas v
CROSS JOIN p
WHERE p.bimestre_ini IS NULL OR v.periodo NOT IN (p.bimestre_ini, add_months(p.bimestre_ini, 1))
UNION ALL
SELECT * FROM rebalanceado;

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ## Etapa 5 — Covariáveis e base final
-- MAGIC
-- MAGIC | Covariável | Tabela (notebook 02) | Chave | Tratamento |
-- MAGIC |---|---|---|---|
-- MAGIC | `prec_tot` (mm/dia), `temp_med` (°C) | `gmm_projecao_cov_clima` | município × mês | — (o R interpola buracos) |
-- MAGIC | `caged` (estoque de empregos) | `gmm_projecao_cov_caged` | município × mês | último valor do próprio município nos meses ainda não divulgados |
-- MAGIC | `irt_real` (base jan/2022 = 100) | `gmm_projecao_cov_tarifa` | categoria × mês | só para o fator de elasticidade da projeção |
-- MAGIC
-- MAGIC As colunas e os nomes são os da base antiga, mais `porte`, `n_ligacoes_*`, `qtd_registros`, `qt_dias` (para
-- MAGIC dias médios por fatura), `vol_*_bruto` (antes da correção de volumes absurdos) e `rebalanceado`.

-- COMMAND ----------

CREATE OR REPLACE TABLE `sdb_sbx_adls`.`regulacao`.`gmm_projecao_base_analitica` AS
WITH
b AS (SELECT * FROM `sdb_sbx_adls`.`regulacao`.`gmm_projecao_base_etapa4`),
fim AS (SELECT MAX(periodo) AS fim FROM b),

meses AS (
  SELECT explode(sequence(DATE'2020-01-01', (SELECT fim FROM fim), INTERVAL 1 MONTH)) AS periodo
),

caged AS (
  SELECT g.cd_ibge, g.periodo,
         LAST_VALUE(c.estoque, TRUE) OVER (PARTITION BY g.cd_ibge ORDER BY g.periodo
                                           ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS caged
  FROM (SELECT c.cd_ibge, m.periodo FROM (SELECT DISTINCT cd_ibge FROM b) c CROSS JOIN meses m) g
  LEFT JOIN `sdb_sbx_adls`.`regulacao`.`gmm_projecao_cov_caged` c
    ON c.cd_ibge = g.cd_ibge AND c.periodo = g.periodo
)

SELECT
  concat_ws('_', b.cd_regiao, b.municipio, CAST(b.cd_atc AS STRING), b.categoria_detalhe, b.recorte) AS chave,
  b.cd_regiao, b.municipio, b.cd_ibge, b.cd_atc, b.categoria, b.categoria_detalhe, b.recorte, b.porte,
  a.classificacao_abc, b.periodo,
  b.vol_med_agua, b.vol_med_esg, b.vol_fat_agua, b.vol_fat_esg,
  b.n_economias_agua, b.n_economias_esg, b.n_ligacoes_agua, b.n_ligacoes_esg,
  b.qtd_registros, b.qt_dias,
  b.vol_med_agua_bruto, b.vol_fat_agua_bruto, b.vol_med_agua_recorte_imputado, b.rebalanceado,
  cl.prec_tot, cl.temp_med,
  cg.caged,
  t.irt_real
FROM b
LEFT JOIN `sdb_sbx_adls`.`regulacao`.`gmm_projecao_base_abc` a       ON a.municipio = b.municipio
LEFT JOIN `sdb_sbx_adls`.`regulacao`.`gmm_projecao_cov_clima` cl     ON cl.cd_ibge = b.cd_ibge AND cl.periodo = b.periodo
LEFT JOIN caged cg                                                   ON cg.cd_ibge = b.cd_ibge AND cg.periodo = b.periodo
LEFT JOIN `sdb_sbx_adls`.`regulacao`.`gmm_projecao_cov_tarifa` t
  ON t.periodo = b.periodo AND t.categoria_detalhe = b.categoria_detalhe;

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ## Etapa 6 — Exportação
-- MAGIC
-- MAGIC Grava no Volume o CSV que o R lê (`cfg$arq_base`) e uma amostra com metade das **chaves** (séries inteiras),
-- MAGIC para compartilhar ou testar. Para baixar: Catalog Explorer → Volume → arquivo → Download, ou pela CLI:
-- MAGIC
-- MAGIC `databricks fs cp "dbfs:/Volumes/sdb_sbx_adls/regulacao/projecao/05_FRAMEWORK_5/01_BASES/<arquivo>.csv" "05_FRAMEWORK_5/01_BASES/"`

-- COMMAND ----------

-- MAGIC %python
-- MAGIC import os
-- MAGIC
-- MAGIC VOLUME = "/Volumes/sdb_sbx_adls/regulacao/projecao"
-- MAGIC TABELA = "sdb_sbx_adls.regulacao.gmm_projecao_base_analitica"
-- MAGIC
-- MAGIC base = spark.table(TABELA)
-- MAGIC # Decimais viram double: o CSV fica menor e o toPandas, mais rápido
-- MAGIC for c, t in base.dtypes:
-- MAGIC     if t.startswith("decimal"):
-- MAGIC         base = base.withColumn(c, base[c].cast("double"))
-- MAGIC ini, fim = base.selectExpr("date_format(MIN(periodo), 'yyyyMM')", "date_format(MAX(periodo), 'yyyyMM')").first()
-- MAGIC destino = f"{VOLUME}/05_FRAMEWORK_5/01_BASES"
-- MAGIC os.makedirs(destino, exist_ok=True)
-- MAGIC
-- MAGIC pdf = base.orderBy("chave", "porte", "periodo").toPandas()
-- MAGIC arq = f"{destino}/02_Base Analítica Ajustada_{ini}-{fim}.csv"
-- MAGIC pdf.to_csv(arq, index=False, encoding="utf-8")
-- MAGIC
-- MAGIC # Amostra por chave: metade das séries, com todos os meses
-- MAGIC amostra = (base.where("abs(xxhash64(chave)) % 100 < 50")
-- MAGIC            .orderBy("chave", "porte", "periodo").toPandas())
-- MAGIC arq_amostra = arq.replace(".csv", "_amostra.csv")
-- MAGIC amostra.to_csv(arq_amostra, index=False, encoding="utf-8")
-- MAGIC
-- MAGIC for a in (arq, arq_amostra):
-- MAGIC     print(f"{a}  ({os.path.getsize(a) / 1e6:.1f} MB)")
-- MAGIC print(f"{len(pdf):,} linhas, {pdf.chave.nunique():,} chaves; amostra: {amostra.chave.nunique():,} chaves")

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ## Diagnósticos
-- MAGIC
-- MAGIC | # | Pergunta | O que esperar |
-- MAGIC |---|---|---|
-- MAGIC | C1 | Para onde vai o volume da base de consumo, mês a mês? | Categorias excluídas ≈ Atacado + Outras + DF; séries inválidas ≪ 1%; recorte imputado pequeno |
-- MAGIC | C2 | Há chave × porte × mês duplicada? | Nenhuma linha |
-- MAGIC | C3 | Há covariável faltando? | Nenhuma falta (o `caged` do mês ainda não divulgado repete o anterior) |
-- MAGIC | C4 | O rebalanceamento preservou o bimestre? | Mesmo total em mar+abr; economias iguais nos dois meses |
-- MAGIC | C5 | A base nova bate com a antiga do R? | Diferenças só pelas correções (volumes absurdos, recorte, séries inválidas) |
-- MAGIC | D7 | Como os clientes de mar/2026 apareceram em abril? | Define a regra por PDE que substitui o rebalanceamento |

-- COMMAND ----------

-- C1. Conciliação do volume medido de água por mês (m³)
WITH
hist AS (
  SELECT make_date(CAST(ANO AS INT), CAST(MES AS INT), 1) AS periodo,
         SUM(vol_med_agua) AS total,
         SUM(CASE WHEN CATEGORIA_DETALHE IN (SELECT categoria_detalhe FROM params_categorias_excluidas)
                  THEN vol_med_agua ELSE 0 END) AS categorias_excluidas
  FROM `sdb_sbx_adls`.`regulacao`.`gmm_projecao_histograma_por_categoria_atc_recorte`
  GROUP BY 1
),
e1 AS (
  SELECT b.periodo, SUM(b.vol_med_agua) AS etapa1, SUM(b.vol_med_agua_recorte_imputado) AS recorte_imputado,
         SUM(CASE WHEN s.motivo_exclusao IS NOT NULL THEN b.vol_med_agua ELSE 0 END) AS series_invalidas
  FROM `sdb_sbx_adls`.`regulacao`.`gmm_projecao_base_etapa1` b
  JOIN `sdb_sbx_adls`.`regulacao`.`gmm_projecao_base_series` s
    USING (cd_regiao, municipio, cd_ibge, cd_atc, categoria, categoria_detalhe, recorte)
  GROUP BY 1
),
fin AS (
  SELECT periodo, SUM(vol_med_agua) AS final
  FROM `sdb_sbx_adls`.`regulacao`.`gmm_projecao_base_analitica`
  GROUP BY 1
)
SELECT h.periodo, ROUND(h.total) AS total_consumo,
       ROUND(100 * h.categorias_excluidas / h.total, 2) AS perc_categorias_excluidas,
       ROUND(100 * e1.series_invalidas / h.total, 3)     AS perc_series_invalidas,
       ROUND(100 * e1.recorte_imputado / h.total, 3)     AS perc_recorte_imputado,
       ROUND(h.total - h.categorias_excluidas - e1.etapa1) AS dif_etapa1,
       ROUND(f.final) AS final
FROM hist h
JOIN e1 USING (periodo)
LEFT JOIN fin f USING (periodo)
ORDER BY h.periodo;

-- COMMAND ----------

-- C2. Duplicatas (esperado: nenhuma linha)
SELECT chave, porte, periodo, COUNT(*) AS n
FROM `sdb_sbx_adls`.`regulacao`.`gmm_projecao_base_analitica`
GROUP BY ALL
HAVING COUNT(*) > 1;

-- COMMAND ----------

-- C3. Linhas sem covariável, por mês (só meses com alguma falta)
SELECT periodo, COUNT(*) AS linhas,
       COUNT_IF(prec_tot IS NULL)   AS sem_prec,
       COUNT_IF(temp_med IS NULL)   AS sem_temp,
       COUNT_IF(caged IS NULL)      AS sem_caged,
       COUNT_IF(irt_real IS NULL)   AS sem_tarifa,
       COUNT_IF(classificacao_abc IS NULL) AS sem_abc
FROM `sdb_sbx_adls`.`regulacao`.`gmm_projecao_base_analitica`
GROUP BY periodo
HAVING sem_prec + sem_temp + sem_caged + sem_tarifa + sem_abc > 0
ORDER BY periodo;

-- COMMAND ----------

-- C4. Rebalanceamento: fev a mai/2026 por categoria, antes (etapa 1, séries válidas) e depois
WITH
antes AS (
  SELECT b.categoria_detalhe, b.periodo, SUM(b.vol_med_agua) AS vol_antes, SUM(b.n_economias_agua) AS econ_antes
  FROM `sdb_sbx_adls`.`regulacao`.`gmm_projecao_base_etapa1` b
  JOIN `sdb_sbx_adls`.`regulacao`.`gmm_projecao_base_series` s
    USING (cd_regiao, municipio, cd_ibge, cd_atc, categoria, categoria_detalhe, recorte)
  WHERE s.motivo_exclusao IS NULL AND b.periodo BETWEEN DATE'2026-02-01' AND DATE'2026-05-01'
  GROUP BY 1, 2
),
depois AS (
  SELECT categoria_detalhe, periodo, SUM(vol_med_agua) AS vol_depois, SUM(n_economias_agua) AS econ_depois
  FROM `sdb_sbx_adls`.`regulacao`.`gmm_projecao_base_analitica`
  WHERE periodo BETWEEN DATE'2026-02-01' AND DATE'2026-05-01'
  GROUP BY 1, 2
)
SELECT categoria_detalhe, periodo,
       ROUND(vol_antes) AS vol_antes, ROUND(vol_depois) AS vol_depois,
       ROUND(econ_antes) AS econ_antes, ROUND(econ_depois) AS econ_depois,
       ROUND(vol_depois / econ_depois, 2) AS consumo_por_economia
FROM antes JOIN depois USING (categoria_detalhe, periodo)
ORDER BY categoria_detalhe, periodo;

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ### C5 — Comparação com a base antiga do R
-- MAGIC
-- MAGIC Suba a base antiga (`02_Base Analítica Ajustada_202201-202608.csv`) em
-- MAGIC `05_FRAMEWORK_5/01_BASES/antiga/` no Volume. Compara o volume medido e as economias de água por categoria e mês.
-- MAGIC Diferenças esperadas: volumes absurdos retirados (etapa 2b do notebook 01; até −28% em meses de 2022–23 no não
-- MAGIC residencial), recorte nulo mantido, séries com várias `catego` que antes caíam no corte, e mar/abr 2026 (economias).

-- COMMAND ----------

-- MAGIC %python
-- MAGIC import glob
-- MAGIC
-- MAGIC antigas = sorted(glob.glob("/Volumes/sdb_sbx_adls/regulacao/projecao/05_FRAMEWORK_5/01_BASES/antiga/*.csv"))
-- MAGIC if not antigas:
-- MAGIC     print("Sem base antiga no Volume: comparação ignorada")
-- MAGIC else:
-- MAGIC     (spark.read.option("header", True).option("inferSchema", True).csv(antigas[-1])
-- MAGIC      .createOrReplaceTempView("base_antiga"))
-- MAGIC     display(spark.sql("""
-- MAGIC       WITH a AS (SELECT categoria_detalhe, CAST(periodo AS DATE) AS periodo,
-- MAGIC                         SUM(vol_med_agua) AS vol_antiga, SUM(n_economias_agua) AS econ_antiga
-- MAGIC                  FROM base_antiga GROUP BY 1, 2),
-- MAGIC            n AS (SELECT categoria_detalhe, periodo,
-- MAGIC                         SUM(vol_med_agua) AS vol_nova, SUM(n_economias_agua) AS econ_nova
-- MAGIC                  FROM sdb_sbx_adls.regulacao.gmm_projecao_base_analitica GROUP BY 1, 2)
-- MAGIC       SELECT categoria_detalhe, periodo,
-- MAGIC              ROUND(100 * (vol_nova / vol_antiga - 1), 2)   AS var_perc_volume,
-- MAGIC              ROUND(100 * (econ_nova / econ_antiga - 1), 2) AS var_perc_economias
-- MAGIC       FROM a FULL OUTER JOIN n USING (categoria_detalhe, periodo)
-- MAGIC       ORDER BY categoria_detalhe, periodo"""))

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ### D7 — Faturamento atrasado de mar/2026
-- MAGIC
-- MAGIC O `ANO/MES` da fatura é o mês de referência. Se os clientes de março faturaram em abril, devem aparecer como
-- MAGIC "buraco" em março (sem fatura em março, com fatura em fevereiro e em abril) e, em abril, com **uma fatura longa**
-- MAGIC (≈ 60 dias, volume ≈ 2 meses) ou com **duas faturas**. Os meses vizinhos servem de controle.
-- MAGIC
-- MAGIC - Fatura longa → regra por PDE: devolver a março a parte do volume proporcional aos dias anteriores ao mês.
-- MAGIC - Duas faturas → devolver a março a fatura mais antiga.
-- MAGIC - Medido zero com faturado positivo em março → faturado por média; o acerto vem em abril.
-- MAGIC
-- MAGIC Com a regra por PDE, a etapa 4 deixa de ser necessária e o backtest pode avaliar março e abril separados
-- MAGIC (`meses_agrupados = list()`), sem mudar o código do R.

-- COMMAND ----------

-- D7a. Faturas por PDE e dias faturados, por mês de referência
WITH pm AS (
  SELECT ID_PDE, make_date(CAST(ANO AS INT), CAST(MES AS INT), 1) AS periodo,
         SUM(qtd_registros) AS faturas, MAX(qt_dias) AS dias,
         SUM(vol_med_agua) AS vol_med, SUM(vol_fat_agua) AS vol_fat
  FROM `sdb_sbx_adls`.`regulacao`.`gmm_projecao_fato_pde_mes`
  WHERE CAST(ANO AS INT) * 100 + CAST(MES AS INT) BETWEEN 202510 AND 202607
    AND ID_PDE IS NOT NULL AND ID_PDE <> '-1'
  GROUP BY 1, 2
)
SELECT periodo,
       COUNT(*)                                                         AS pdes,
       ROUND(SUM(vol_med))                                              AS vol_med,
       PERCENTILE(dias, 0.5)                                            AS dias_mediana,
       ROUND(100 * AVG(CASE WHEN faturas > 1 THEN 1 ELSE 0 END), 2)     AS perc_pdes_2_faturas,
       ROUND(100 * AVG(CASE WHEN dias > 45 THEN 1 ELSE 0 END), 2)       AS perc_pdes_mais_45_dias,
       ROUND(100 * SUM(CASE WHEN dias > 45 THEN vol_med END) / SUM(vol_med), 2) AS perc_vol_mais_45_dias,
       ROUND(100 * AVG(CASE WHEN vol_med = 0 AND vol_fat > 0 THEN 1 ELSE 0 END), 2) AS perc_pdes_sem_leitura
FROM pm
GROUP BY periodo
ORDER BY periodo;

-- COMMAND ----------

-- D7b. "Buracos": PDE sem fatura no mês, com fatura no mês anterior e no seguinte. Como veio o mês seguinte?
WITH pm AS (
  SELECT ID_PDE, make_date(CAST(ANO AS INT), CAST(MES AS INT), 1) AS periodo,
         SUM(qtd_registros) AS faturas, MAX(qt_dias) AS dias, SUM(vol_med_agua) AS vol_med
  FROM `sdb_sbx_adls`.`regulacao`.`gmm_projecao_fato_pde_mes`
  WHERE CAST(ANO AS INT) * 100 + CAST(MES AS INT) BETWEEN 202510 AND 202607
    AND ID_PDE IS NOT NULL AND ID_PDE <> '-1'
  GROUP BY 1, 2
),
buraco AS (
  SELECT a.ID_PDE, add_months(a.periodo, 1) AS mes_buraco,
         a.vol_med AS vol_antes, c.vol_med AS vol_depois, c.faturas AS faturas_depois, c.dias AS dias_depois
  FROM pm a
  JOIN pm c ON c.ID_PDE = a.ID_PDE AND c.periodo = add_months(a.periodo, 2)
  LEFT ANTI JOIN pm m ON m.ID_PDE = a.ID_PDE AND m.periodo = add_months(a.periodo, 1)
)
SELECT mes_buraco,
       COUNT(*)                                                      AS pdes_sem_fatura,
       ROUND(SUM(vol_antes))                                         AS vol_mes_anterior,
       ROUND(SUM(vol_depois) / NULLIF(SUM(vol_antes), 0), 2)         AS razao_vol_seguinte_anterior,
       ROUND(AVG(faturas_depois), 2)                                 AS faturas_mes_seguinte,
       PERCENTILE(dias_depois, 0.5)                                  AS dias_mes_seguinte_mediana,
       ROUND(100 * AVG(CASE WHEN dias_depois > 45 THEN 1 ELSE 0 END), 1) AS perc_fatura_longa
FROM buraco
GROUP BY mes_buraco
ORDER BY mes_buraco;