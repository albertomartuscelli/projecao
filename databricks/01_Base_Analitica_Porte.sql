-- Databricks notebook source
-- MAGIC %md
-- MAGIC # Base analítica de consumo com classificação de porte (grandes clientes)
-- MAGIC
-- MAGIC Gera a base mensal por **categoria × ATC × recorte × porte** usada no backtesting e na projeção
-- MAGIC (`05_FRAMEWORK_5`), separando os **grandes clientes** para que sejam projetados à parte.
-- MAGIC
-- MAGIC | Etapa | Tabela gerada | Conteúdo |
-- MAGIC |---|---|---|
-- MAGIC | 0 | `params` (temp view) | Parâmetros da classificação de porte |
-- MAGIC | 1 | `gmm_projecao_fato_pde_mes` | Faturas agregadas por PDE × catego × ATC × recorte × mês |
-- MAGIC | 2 | `gmm_projecao_porte_pde` | Classificação fixa de porte por PDE (Grande / Demais) |
-- MAGIC | 3 | `gmm_projecao_histograma_por_categoria_atc_recorte` | Base agregada (a mesma de antes + `porte` e `qt_dias`) |
-- MAGIC | 4 | `gmm_projecao_grandes_clientes_pde` | Detalhe mensal dos grandes clientes |
-- MAGIC | D1–D5 | — | Diagnósticos de qualidade e calibração |
-- MAGIC
-- MAGIC **Fontes**
-- MAGIC - `prd_raw_adls.bicom_ora_dm_regulatoria.mov_histograma_origem`: fato de faturamento regulatório (uma linha por fatura)
-- MAGIC - `prd_raw_adls.bicom_ora_dw.cad_tracer`: recorte geográfico do PDE
-- MAGIC - `sdb_sbx_adls.regulacao.gmm_de_para_catego`: hierarquia de categorias
-- MAGIC - `sdb_sbx_adls.regulacao.gmm_cod_ibge`: superintendência, município e código IBGE por ATC
-- MAGIC
-- MAGIC **Mudanças em relação à query anterior**
-- MAGIC 1. Saíram os joins temporais com `cad_pde` e `cad_tracer`: nenhuma coluna deles era usada, e a
-- MAGIC    deduplicação seguinte (`ROW_NUMBER` sem os volumes faturados na partição) podia descartar faturas
-- MAGIC    que diferiam só no faturado (ex.: original × refaturamento). Duplicatas exatas saem por `SELECT DISTINCT`.
-- MAGIC 2. Caminhão e Embarcação passam a casar com o de-para (`CAM` / `EMB`); antes eram descartados.
-- MAGIC 3. Item de esgoto nulo vira `'-1'`, para o volume não sumir da divisão real × disponibilidade.
-- MAGIC 4. Regra de demanda firme (`DF`) duplicada e colunas de saída redundantes removidas.
-- MAGIC 5. Novas colunas: `porte` (Grande / Demais) e `qt_dias` (dias de consumo faturados).
-- MAGIC
-- MAGIC > Antes da primeira execução, salve uma cópia da tabela atual para a conferência D5:
-- MAGIC > `CREATE TABLE sdb_sbx_adls.regulacao.gmm_projecao_histograma_por_categoria_atc_recorte_bkp DEEP CLONE sdb_sbx_adls.regulacao.gmm_projecao_histograma_por_categoria_atc_recorte`

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ## Etapa 0 — Parâmetros da classificação de porte
-- MAGIC
-- MAGIC Um PDE é **Grande** quando o seu comportamento individual mexe na série que modelamos
-- MAGIC (superintendência × categoria_detalhe, nível do agrupamento G2):
-- MAGIC
-- MAGIC - **`share_min`**: a mediana do volume medido mensal do PDE é ao menos 0,5% da série. Se o cliente
-- MAGIC   sair ou mudar de fonte, a série inteira se move ≥ 0,5%; algumas saídas desse porte explicam o viés
-- MAGIC   de nível (~3%) visto no não residencial em 2026.
-- MAGIC - **`v_min`**: piso absoluto de 500 m³/mês, para que séries pequenas não tornem "grandes" PDEs pequenos.
-- MAGIC - **`min_meses_ref`**: ao menos 6 meses com fatura na janela (evita classificar PDEs recém-criados).
-- MAGIC - **Janela jan–dez/2025**: a mesma classificação vale para o backtest (teste jan–ago/2026, sem
-- MAGIC   sobreposição) e para a projeção. Usa a **mediana**, robusta a picos de faturamento (ex.: PDEs com
-- MAGIC   ~1 milhão de m³ num único mês de 2025).
-- MAGIC
-- MAGIC Calibre `share_min` e `v_min` com o diagnóstico **D4** antes de fixá-los.

-- COMMAND ----------

CREATE OR REPLACE TEMP VIEW params AS
SELECT
  202501 AS ref_ini,        -- início da janela de referência (AAAAMM)
  202512 AS ref_fim,        -- fim da janela de referência (AAAAMM)
  0.005  AS share_min,      -- mediana do PDE >= 0,5% da série superintendência x categoria
  500    AS v_min,          -- e >= 500 m³/mês
  6      AS min_meses_ref;  -- meses mínimos com fatura na janela

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ## Etapa 1 — Fato no nível PDE × catego × ATC × recorte × mês
-- MAGIC
-- MAGIC 1. **`ho`**: faturas processadas (`ST_PROCESSAM = 'S'`), sem duplicatas exatas. Itens faturáveis nulos
-- MAGIC    viram `'-1'` (sem o serviço).
-- MAGIC 2. **`recorte`**: recorte mais recente de cada PDE no `cad_tracer`, aplicado a todo o histórico
-- MAGIC    (uma reclassificação de recorte se propaga para trás).
-- MAGIC 3. **`fato`**: deriva `cod_ITEM_FAT` (código do item faturável sem prefixo) e as flags de serviço
-- MAGIC    (`tem_agua`, `tem_esg`, `esg_disp` = esgoto por disponibilidade, item terminado em `_D`).
-- MAGIC 4. **`categorizado`**: classifica `catego` pela regra de negócio. **A ordem das regras importa**:
-- MAGIC    produto e benefício social vêm primeiro; depois o item faturável; por fim, a categoria de uso.
-- MAGIC    Linhas sem regra ficam com `catego` NULL e serão descartadas no join com o de-para (ver D2).
-- MAGIC 5. Agregação por PDE-mês. `qtd_registros > 1` indica mais de uma fatura no mês (ver D1).

-- COMMAND ----------

CREATE OR REPLACE TABLE `sdb_sbx_adls`.`regulacao`.`gmm_projecao_fato_pde_mes`
CLUSTER BY (ANO, MES)
AS
WITH

-- 1. Faturas processadas, sem duplicatas exatas
ho AS (
  SELECT DISTINCT
    ID_PDE, ID_FORNECIMENTO, DT_EMISSAO_FATURA, ANO, MES, CD_ATC,
    TP_BENEFICIO, CD_PRODUTO, CD_CLASSE_FORNECIMENTO, CD_CATEGORIA_USO,
    COALESCE(CD_ITEM_FATURAVEL_AGUA, '-1') AS CD_ITEM_FATURAVEL_AGUA,
    COALESCE(CD_ITEM_FATURAVEL_ESG,  '-1') AS CD_ITEM_FATURAVEL_ESG,
    NR_ECONOMIAS, QT_DIAS,
    QT_CONS_MED_REG_AGUA, QT_CONS_MED_REG_ESG, QT_CONS_MED_REG_END,
    QT_CONS_FAT_AGUA_POS, QT_CONS_FAT_AGUA_NEG,
    QT_CONS_FAT_ESG_POS,  QT_CONS_FAT_ESG_NEG,
    QT_CONS_FAT_END_POS,  QT_CONS_FAT_END_NEG
  FROM `prd_raw_adls`.`bicom_ora_dm_regulatoria`.`mov_histograma_origem`
  WHERE ST_PROCESSAM = 'S'
),

-- 2. Recorte mais recente por PDE
recorte AS (
  SELECT ID_PDE, TP_RECORTE
  FROM (
    SELECT ID_PDE, TP_RECORTE,
           ROW_NUMBER() OVER (PARTITION BY ID_PDE ORDER BY DT_FIM DESC NULLS LAST) AS rn
    FROM `prd_raw_adls`.`bicom_ora_dw`.`cad_tracer`
  )
  WHERE rn = 1
),

-- 3. Item faturável e flags de serviço
fato AS (
  SELECT
    h.*,
    r.TP_RECORTE,
    CASE
      WHEN h.CD_ITEM_FATURAVEL_AGUA = 'SB_REUSO' THEN 'SB_REUSO'
      WHEN h.CD_ITEM_FATURAVEL_AGUA != '-1'
        THEN REPLACE(h.CD_ITEM_FATURAVEL_AGUA, 'SB_AGUA_', '')
      WHEN h.CD_ITEM_FATURAVEL_ESG LIKE 'SB\_ESGOTO\_%'
        THEN REPLACE(h.CD_ITEM_FATURAVEL_ESG, 'SB_ESGOTO_', '')
      WHEN h.CD_ITEM_FATURAVEL_ESG != '-1' THEN h.CD_ITEM_FATURAVEL_ESG
    END AS cod_ITEM_FAT,
    h.CD_ITEM_FATURAVEL_AGUA != '-1'                                         AS tem_agua,
    h.CD_ITEM_FATURAVEL_ESG  != '-1'                                         AS tem_esg,
    h.CD_ITEM_FATURAVEL_ESG  != '-1' AND h.CD_ITEM_FATURAVEL_ESG LIKE '%\_D' AS esg_disp
  FROM ho h
  LEFT JOIN recorte r ON h.ID_PDE = r.ID_PDE
),

-- 4. Classificação catego (ordem das regras importa)
categorizado AS (
  SELECT
    CASE
      -- Produtos específicos
      WHEN CD_PRODUTO = 'SB_PUBLICA_MUN_O'                                                  THEN 'PO'
      WHEN CD_PRODUTO = 'SB_PREDIO'                                                         THEN 'SA'
      -- Residencial social por produto/benefício
      WHEN CD_PRODUTO = 'SB_SOCIAL_2_SR'
        OR (TP_BENEFICIO = '19' AND CD_CLASSE_FORNECIMENTO = 'SB_SOC_50_4')                 THEN 'RS2'
      WHEN (CD_PRODUTO LIKE 'SB\_SOCIAL%' AND TP_BENEFICIO = '16')
        OR (TP_BENEFICIO = '-1' AND CD_CLASSE_FORNECIMENTO = 'SB_SOC_50_1')                 THEN 'RST1'
      WHEN CD_PRODUTO LIKE 'SB\_SOCIAL%' AND TP_BENEFICIO = '17'                            THEN 'RST2'
      WHEN cod_ITEM_FAT = 'FAV' AND CD_PRODUTO = 'SB_FAVELAS_N'                             THEN 'RF'
      -- Atacado
      WHEN cod_ITEM_FAT = 'PER'                                                             THEN 'AT'
      -- Comercial
      WHEN cod_ITEM_FAT IN ('COM','COM_D') AND CD_CLASSE_FORNECIMENTO LIKE '%\_AS%'         THEN 'CA'
      WHEN cod_ITEM_FAT IN ('COM','COM_D') AND CD_CLASSE_FORNECIMENTO LIKE '%\_ESPECIAL%'   THEN 'CE'
      WHEN cod_ITEM_FAT IN ('COM','COM_D')                                                  THEN 'C'
      -- Comercial/industrial/público (CIP) pela classe ou categoria de uso
      WHEN cod_ITEM_FAT = 'CIP' AND CD_CLASSE_FORNECIMENTO LIKE '%\_INDUS%'                 THEN 'I'
      WHEN cod_ITEM_FAT = 'CIP' AND CD_CLASSE_FORNECIMENTO LIKE '%\_COMER%'                 THEN 'C'
      WHEN cod_ITEM_FAT = 'CIP' AND CD_CATEGORIA_USO = '2'                                  THEN 'C'
      WHEN cod_ITEM_FAT = 'CIP' AND CD_CATEGORIA_USO = '3'                                  THEN 'I'
      WHEN cod_ITEM_FAT = 'CIP'                                                             THEN '_NA'
      -- Demanda firme
      WHEN cod_ITEM_FAT IN ('DF','DFN','PERS_M') AND CD_CATEGORIA_USO = '2'                 THEN 'CD'
      WHEN cod_ITEM_FAT IN ('DF','DFN','PERS_M') AND CD_CATEGORIA_USO = '3'                 THEN 'ID'
      WHEN cod_ITEM_FAT IN ('DF','DFN','PERS_M')                                            THEN '_NA'
      -- Reúso
      WHEN cod_ITEM_FAT IN ('MIN','SB_REUSO')                                               THEN 'REUSO'
      -- Residencial social por item faturável
      WHEN cod_ITEM_FAT IN ('SOC','SOC_2') AND CD_CLASSE_FORNECIMENTO LIKE '%SOC\_50%'      THEN 'RST1'
      WHEN cod_ITEM_FAT IN ('SOC','SOC_2') AND CD_CLASSE_FORNECIMENTO LIKE '%SOC\_75%'      THEN 'RST2'
      WHEN cod_ITEM_FAT IN ('SOC','SOC_2')                                                  THEN 'RS'
      -- Outras (códigos iguais aos do de-para)
      WHEN cod_ITEM_FAT = 'CAM'                                                             THEN 'CAM'
      WHEN cod_ITEM_FAT = 'EMB'                                                             THEN 'EMB'
      -- Residencial vulnerável
      WHEN cod_ITEM_FAT = 'FAV'                                                             THEN 'RV'
      -- Pública (contrato de programa antes de com contrato: os padrões se sobrepõem)
      WHEN cod_ITEM_FAT IN ('PUB','PUB_M')
        AND CD_CLASSE_FORNECIMENTO RLIKE '(_PRO|_PUBPROG|CON_PR|PUB_PR|PUB_CON_PR)'          THEN 'PP'
      WHEN cod_ITEM_FAT IN ('PUB','PUB_M')
        AND CD_CLASSE_FORNECIMENTO RLIKE '(PURA|PUBCONPUR|PUB_CON_P|PUB_PU|PUB_CPUR)'        THEN 'PC'
      WHEN cod_ITEM_FAT IN ('PUB','PUB_M')                                                  THEN 'P'
      -- Residencial normal
      WHEN cod_ITEM_FAT IN ('RES','V_RES','RES_D')
        AND CD_CLASSE_FORNECIMENTO IN ('SB_LINS_ESPECIAL','SB_R_ESPECIAL')                  THEN 'RE'
      WHEN cod_ITEM_FAT IN ('RES','V_RES','RES_D')                                          THEN 'R'
      -- Industrial
      WHEN cod_ITEM_FAT = 'IND'                                                             THEN 'I'
      -- Sem item faturável: categoria de uso
      WHEN cod_ITEM_FAT IS NULL
        OR cod_ITEM_FAT IN ('NOR_1F','NOR_5F','SB_ESG_ND_ESP_4F') THEN
        CASE CD_CATEGORIA_USO WHEN '1' THEN 'R' WHEN '2' THEN 'C' WHEN '3' THEN 'I' WHEN '4' THEN 'P' END
    END AS catego,
    fato.*
  FROM fato
)

-- 5. Agregação por PDE-mês
SELECT
  ID_PDE, catego, cod_ITEM_FAT, CD_ATC, TP_RECORTE, ANO, MES,
  COUNT(*)                                                             AS qtd_registros,
  SUM(QT_DIAS)                                                         AS qt_dias,
  -- economias
  SUM(NR_ECONOMIAS)                                                    AS n_economias,
  SUM(CASE WHEN tem_agua THEN NR_ECONOMIAS ELSE 0 END)                 AS n_economias_agua,
  SUM(CASE WHEN tem_esg  THEN NR_ECONOMIAS ELSE 0 END)                 AS n_economias_esg,
  SUM(CASE WHEN tem_esg AND NOT esg_disp THEN NR_ECONOMIAS ELSE 0 END) AS n_economias_esg_real,
  SUM(CASE WHEN esg_disp THEN NR_ECONOMIAS ELSE 0 END)                 AS n_economias_esg_disp,
  -- flags para contar ligações na etapa 3
  MAX(CAST(tem_agua AS INT))                                           AS tem_agua,
  MAX(CAST(tem_esg  AS INT))                                           AS tem_esg,
  MAX(CAST(tem_esg AND NOT esg_disp AS INT))                           AS tem_esg_real,
  MAX(CAST(esg_disp AS INT))                                           AS tem_esg_disp,
  -- volume medido
  SUM(QT_CONS_MED_REG_AGUA)                                            AS vol_med_agua,
  SUM(QT_CONS_MED_REG_ESG + QT_CONS_MED_REG_END)                       AS vol_med_esg,
  SUM(CASE WHEN NOT esg_disp THEN QT_CONS_MED_REG_ESG + QT_CONS_MED_REG_END ELSE 0 END) AS vol_med_esg_real,
  SUM(CASE WHEN esg_disp     THEN QT_CONS_MED_REG_ESG + QT_CONS_MED_REG_END ELSE 0 END) AS vol_med_esg_disp,
  -- volume faturado (lançamentos positivos e negativos)
  SUM(QT_CONS_FAT_AGUA_POS + QT_CONS_FAT_AGUA_NEG)                     AS vol_fat_agua,
  SUM(QT_CONS_FAT_ESG_POS + QT_CONS_FAT_ESG_NEG
      + QT_CONS_FAT_END_POS + QT_CONS_FAT_END_NEG)                     AS vol_fat_esg,
  SUM(CASE WHEN NOT esg_disp THEN QT_CONS_FAT_ESG_POS + QT_CONS_FAT_ESG_NEG
                                + QT_CONS_FAT_END_POS + QT_CONS_FAT_END_NEG ELSE 0 END) AS vol_fat_esg_real,
  SUM(CASE WHEN esg_disp     THEN QT_CONS_FAT_ESG_POS + QT_CONS_FAT_ESG_NEG
                                + QT_CONS_FAT_END_POS + QT_CONS_FAT_END_NEG ELSE 0 END) AS vol_fat_esg_disp
FROM categorizado
GROUP BY ID_PDE, catego, cod_ITEM_FAT, CD_ATC, TP_RECORTE, ANO, MES;

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ## Etapa 2 — Classificação de porte por PDE
-- MAGIC
-- MAGIC 1. **`vol_mes`**: volume medido de água por PDE e mês na janela de referência, só para
-- MAGIC    Residencial, Comercial, Industrial e Pública. Demanda firme (contratos) e "Outras" ficam fora.
-- MAGIC 2. **`ref`**: mediana, máximo e número de meses de cada PDE.
-- MAGIC 3. **`serie`**: volume da série de referência (superintendência × categoria_detalhe) = soma das medianas.
-- MAGIC 4. **`classif`**: aplica os três critérios da etapa 0.
-- MAGIC 5. PDE que mudou de categoria na janela: vale a categoria de maior volume. A classificação é **fixa**
-- MAGIC    por PDE e vale para todo o histórico, para a composição dos segmentos não mudar mês a mês.
-- MAGIC
-- MAGIC PDEs sem fatura na janela (novos em 2026) ficam como "Demais" na etapa 3.

-- COMMAND ----------

CREATE OR REPLACE TABLE `sdb_sbx_adls`.`regulacao`.`gmm_projecao_porte_pde` AS
WITH

-- 1. Volume mensal por PDE na janela
vol_mes AS (
  SELECT f.ID_PDE, dp.CATEGORIA_DETALHE, ibge.SG_SUPERINTENDENCIA,
         f.ANO * 100 + f.MES AS anomes, SUM(f.vol_med_agua) AS vol
  FROM `sdb_sbx_adls`.`regulacao`.`gmm_projecao_fato_pde_mes` f
  INNER JOIN `sdb_sbx_adls`.`regulacao`.`gmm_de_para_catego` dp ON f.catego = dp.catego
  LEFT JOIN  `sdb_sbx_adls`.`regulacao`.`gmm_cod_ibge` ibge      ON f.CD_ATC = ibge.CD_ATC
  CROSS JOIN params p
  WHERE dp.CATEGORIA IN ('Residencial', 'Comercial', 'Industrial', 'Pública')
    AND dp.CATEGORIA_DETALHE NOT LIKE '%DF%'
    AND f.ANO * 100 + f.MES BETWEEN p.ref_ini AND p.ref_fim
  GROUP BY 1, 2, 3, 4
),

-- 2. Estatísticas do PDE na janela
ref AS (
  SELECT ID_PDE, CATEGORIA_DETALHE, SG_SUPERINTENDENCIA,
         PERCENTILE(vol, 0.5) AS vol_mediana_ref,
         MAX(vol)             AS vol_max_ref,
         COUNT(*)             AS meses_ref
  FROM vol_mes
  GROUP BY 1, 2, 3
),

-- 3. Volume da série de referência
serie AS (
  SELECT CATEGORIA_DETALHE, SG_SUPERINTENDENCIA, SUM(vol_mediana_ref) AS vol_serie_ref
  FROM ref
  GROUP BY 1, 2
),

-- 4. Critérios
classif AS (
  SELECT r.*, s.vol_serie_ref,
         r.vol_mediana_ref / s.vol_serie_ref AS share_serie,
         CASE WHEN r.vol_mediana_ref / s.vol_serie_ref >= p.share_min
               AND r.vol_mediana_ref >= p.v_min
               AND r.meses_ref >= p.min_meses_ref
              THEN 'Grande' ELSE 'Demais' END AS porte
  FROM ref r
  JOIN serie s USING (CATEGORIA_DETALHE, SG_SUPERINTENDENCIA)
  CROSS JOIN params p
)

-- 5. Uma linha por PDE (categoria de maior volume)
SELECT * EXCEPT (rn)
FROM (SELECT c.*, ROW_NUMBER() OVER (PARTITION BY ID_PDE ORDER BY vol_mediana_ref DESC) AS rn
      FROM classif c)
WHERE rn = 1;

-- COMMAND ----------

-- Resumo da classificação: quantos grandes e quanto do volume eles têm
SELECT CATEGORIA_DETALHE,
       COUNT_IF(porte = 'Grande')                                                         AS n_grandes,
       COUNT(*)                                                                           AS n_pdes,
       ROUND(100 * SUM(CASE WHEN porte = 'Grande' THEN vol_mediana_ref END) / SUM(vol_mediana_ref), 1) AS perc_volume_grandes
FROM `sdb_sbx_adls`.`regulacao`.`gmm_projecao_porte_pde`
GROUP BY 1
ORDER BY 1;

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ## Etapa 3 — Base agregada (categoria × ATC × recorte × porte × mês)
-- MAGIC
-- MAGIC Mesma tabela usada hoje no ETL da base analítica, com duas colunas novas:
-- MAGIC - **`porte`**: `Grande` ou `Demais` (PDE sem classificação = `Demais`). Somando os dois portes,
-- MAGIC   obtêm-se os totais de antes.
-- MAGIC - **`qt_dias`**: soma dos dias de consumo faturados, para normalizar o volume pelo ciclo de leitura.
-- MAGIC
-- MAGIC Colunas removidas por redundância: `vol_medido_reg_agua` (= `vol_med_agua`),
-- MAGIC `vol_faturado_agua` (= `vol_fat_agua`), `vol_medido_reg_esgoto`, `vol_medido_reg_end`,
-- MAGIC `vol_faturado_esgoto` e `vol_faturado_end` (parcelas de `vol_med_esg` e `vol_fat_esg`).
-- MAGIC Readicione se o ETL usar alguma delas.
-- MAGIC
-- MAGIC O `INNER JOIN` com o de-para descarta `catego` NULL e `_NA` (ver D2).

-- COMMAND ----------

CREATE OR REPLACE TABLE `sdb_sbx_adls`.`regulacao`.`gmm_projecao_histograma_por_categoria_atc_recorte`
CLUSTER BY (ANO, MES)
AS
SELECT
  dp.catego, dp.ds_catego, dp.CATEGORIA_DETALHE, dp.CATEGORIA,
  COALESCE(pt.porte, 'Demais') AS porte,
  ibge.SG_SUPERINTENDENCIA, ibge.MUNICIPIO, ibge.cd_ibge,
  f.CD_ATC, f.TP_RECORTE, f.ANO, f.MES,
  -- ligações
  COUNT(DISTINCT f.ID_PDE)                                       AS n_ligacoes,
  COUNT(DISTINCT CASE WHEN f.tem_agua = 1     THEN f.ID_PDE END) AS n_ligacoes_agua,
  COUNT(DISTINCT CASE WHEN f.tem_esg = 1      THEN f.ID_PDE END) AS n_ligacoes_esg,
  COUNT(DISTINCT CASE WHEN f.tem_esg_real = 1 THEN f.ID_PDE END) AS n_ligacoes_esg_real,
  COUNT(DISTINCT CASE WHEN f.tem_esg_disp = 1 THEN f.ID_PDE END) AS n_ligacoes_esg_disp,
  SUM(f.qtd_registros)        AS qtd_registros,
  SUM(f.qt_dias)              AS qt_dias,
  -- economias
  SUM(f.n_economias)          AS n_economias,
  SUM(f.n_economias_agua)     AS n_economias_agua,
  SUM(f.n_economias_esg)      AS n_economias_esg,
  SUM(f.n_economias_esg_real) AS n_economias_esg_real,
  SUM(f.n_economias_esg_disp) AS n_economias_esg_disp,
  -- volume medido
  SUM(f.vol_med_agua)         AS vol_med_agua,
  SUM(f.vol_med_esg)          AS vol_med_esg,
  SUM(f.vol_med_esg_real)     AS vol_med_esg_real,
  SUM(f.vol_med_esg_disp)     AS vol_med_esg_disp,
  -- volume faturado
  SUM(f.vol_fat_agua)         AS vol_fat_agua,
  SUM(f.vol_fat_esg)          AS vol_fat_esg,
  SUM(f.vol_fat_esg_real)     AS vol_fat_esg_real,
  SUM(f.vol_fat_esg_disp)     AS vol_fat_esg_disp
FROM `sdb_sbx_adls`.`regulacao`.`gmm_projecao_fato_pde_mes` f
INNER JOIN `sdb_sbx_adls`.`regulacao`.`gmm_de_para_catego` dp    ON f.catego = dp.catego
LEFT JOIN  `sdb_sbx_adls`.`regulacao`.`gmm_cod_ibge` ibge         ON f.CD_ATC = ibge.CD_ATC
LEFT JOIN  `sdb_sbx_adls`.`regulacao`.`gmm_projecao_porte_pde` pt ON f.ID_PDE = pt.ID_PDE
GROUP BY
  dp.catego, dp.ds_catego, dp.CATEGORIA_DETALHE, dp.CATEGORIA,
  COALESCE(pt.porte, 'Demais'),
  ibge.SG_SUPERINTENDENCIA, ibge.MUNICIPIO, ibge.cd_ibge,
  f.CD_ATC, f.TP_RECORTE, f.ANO, f.MES;

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ## Etapa 4 — Detalhe dos grandes clientes (PDE × mês)
-- MAGIC
-- MAGIC Base para projetar os grandes clientes à parte e para a área comercial validar a lista.
-- MAGIC Para trazer o nome do cliente, inclua o join `cad_fornecimento → cad_sujeito`
-- MAGIC (`NM_FANTASIA` / `NM_RAZAOSOCIAL`), o mesmo usado na análise do Genie.

-- COMMAND ----------

CREATE OR REPLACE TABLE `sdb_sbx_adls`.`regulacao`.`gmm_projecao_grandes_clientes_pde`
CLUSTER BY (ANO, MES)
AS
SELECT
  f.ID_PDE, dp.catego, dp.CATEGORIA_DETALHE, dp.CATEGORIA,
  ibge.SG_SUPERINTENDENCIA, ibge.MUNICIPIO, ibge.cd_ibge, f.CD_ATC, f.TP_RECORTE,
  f.ANO, f.MES,
  pt.vol_mediana_ref, pt.vol_max_ref, pt.meses_ref, pt.share_serie,
  f.qt_dias, f.n_economias_agua, f.n_economias_esg,
  f.vol_med_agua, f.vol_med_esg, f.vol_fat_agua, f.vol_fat_esg
FROM `sdb_sbx_adls`.`regulacao`.`gmm_projecao_fato_pde_mes` f
INNER JOIN `sdb_sbx_adls`.`regulacao`.`gmm_projecao_porte_pde` pt
  ON f.ID_PDE = pt.ID_PDE AND pt.porte = 'Grande'
INNER JOIN `sdb_sbx_adls`.`regulacao`.`gmm_de_para_catego` dp ON f.catego = dp.catego
LEFT JOIN  `sdb_sbx_adls`.`regulacao`.`gmm_cod_ibge` ibge      ON f.CD_ATC = ibge.CD_ATC;

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ## Diagnósticos
-- MAGIC
-- MAGIC | # | Pergunta | O que fazer com o resultado |
-- MAGIC |---|---|---|
-- MAGIC | D1 | Quantos PDE-mês têm mais de uma fatura (refaturamento)? | Se o % de volume for relevante, o volume medido e as economias estão duplicados nesses meses: falta uma regra de "fatura mais recente" |
-- MAGIC | D2 | Quanto volume é descartado por `catego` NULL ou fora do de-para? | Códigos com volume relevante precisam de regra no `CASE` |
-- MAGIC | D3 | Há ATC sem correspondência ou duplicada em `gmm_cod_ibge`? | Sem correspondência = superintendência NULL; duplicada = volume em dobro |
-- MAGIC | D4 | Calibração do critério de porte | Escolher `share_min` e `v_min` |
-- MAGIC | D5 | Conferência com a tabela anterior | Diferenças esperadas: + Caminhão/Embarcação e + faturas antes descartadas |

-- COMMAND ----------

-- D1. Refaturamento: PDE-mês com mais de uma fatura e o volume medido envolvido
SELECT ANO, MES,
       COUNT_IF(qtd_registros > 1)                                                         AS pde_mes_multiplos,
       ROUND(100 * COUNT_IF(qtd_registros > 1) / COUNT(*), 2)                              AS perc_pde_mes,
       ROUND(100 * SUM(CASE WHEN qtd_registros > 1 THEN vol_med_agua END) / SUM(vol_med_agua), 2) AS perc_vol_med
FROM `sdb_sbx_adls`.`regulacao`.`gmm_projecao_fato_pde_mes`
GROUP BY ANO, MES
ORDER BY ANO, MES;

-- COMMAND ----------

-- D2. Volume descartado: catego NULL ou fora do de-para (por item faturável)
SELECT f.catego, f.cod_ITEM_FAT, COUNT(*) AS linhas, SUM(f.vol_med_agua) AS vol_med_agua
FROM `sdb_sbx_adls`.`regulacao`.`gmm_projecao_fato_pde_mes` f
LEFT ANTI JOIN `sdb_sbx_adls`.`regulacao`.`gmm_de_para_catego` dp ON f.catego = dp.catego
GROUP BY 1, 2
ORDER BY vol_med_agua DESC;

-- COMMAND ----------

-- D3. ATCs sem correspondência ou duplicadas em gmm_cod_ibge
SELECT 'sem_ibge' AS problema, f.CD_ATC, SUM(f.vol_med_agua) AS valor
FROM `sdb_sbx_adls`.`regulacao`.`gmm_projecao_fato_pde_mes` f
LEFT ANTI JOIN `sdb_sbx_adls`.`regulacao`.`gmm_cod_ibge` i ON f.CD_ATC = i.CD_ATC
GROUP BY f.CD_ATC
UNION ALL
SELECT 'duplicada' AS problema, CD_ATC, COUNT(*) AS valor
FROM `sdb_sbx_adls`.`regulacao`.`gmm_cod_ibge`
GROUP BY CD_ATC
HAVING COUNT(*) > 1;

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ### D4 — Calibração do critério de porte
-- MAGIC
-- MAGIC Testa uma grade de `share_min` × `v_min`. Os PDEs são classificados com 2025 e avaliados pela
-- MAGIC variação de jan–ago/2026 sobre jan–ago/2025, ou seja, **fora da amostra**: o critério consegue
-- MAGIC identificar com antecedência quem vai mexer na série?
-- MAGIC
-- MAGIC - `perc_volume`: participação dos grandes no volume da categoria.
-- MAGIC - `perc_variacao_abs`: participação dos grandes na soma das variações absolutas por PDE.
-- MAGIC - `indice_concentracao` = `perc_variacao_abs / perc_volume`.
-- MAGIC
-- MAGIC **Como escolher:** por categoria, a combinação com poucos PDEs (dezenas a poucas centenas) e
-- MAGIC `indice_concentracao` acima de 2. Perto de 1, o critério está pegando clientes comuns, que o modelo
-- MAGIC já trata bem.

-- COMMAND ----------

WITH base AS (
  SELECT f.ID_PDE, dp.CATEGORIA_DETALHE, ibge.SG_SUPERINTENDENCIA,
         f.ANO * 100 + f.MES AS anomes, SUM(f.vol_med_agua) AS vol
  FROM `sdb_sbx_adls`.`regulacao`.`gmm_projecao_fato_pde_mes` f
  INNER JOIN `sdb_sbx_adls`.`regulacao`.`gmm_de_para_catego` dp ON f.catego = dp.catego
  LEFT JOIN  `sdb_sbx_adls`.`regulacao`.`gmm_cod_ibge` ibge      ON f.CD_ATC = ibge.CD_ATC
  WHERE dp.CATEGORIA IN ('Residencial', 'Comercial', 'Industrial', 'Pública')
    AND dp.CATEGORIA_DETALHE NOT LIKE '%DF%'
  GROUP BY 1, 2, 3, 4
),
ref AS (
  SELECT ID_PDE, CATEGORIA_DETALHE, SG_SUPERINTENDENCIA,
         PERCENTILE(vol, 0.5) AS v, COUNT(*) AS meses
  FROM base
  WHERE anomes BETWEEN 202501 AND 202512
  GROUP BY 1, 2, 3
),
serie AS (
  SELECT CATEGORIA_DETALHE, SG_SUPERINTENDENCIA, SUM(v) AS V
  FROM ref
  GROUP BY 1, 2
),
yoy AS (
  SELECT ID_PDE, CATEGORIA_DETALHE,
         SUM(CASE WHEN anomes BETWEEN 202601 AND 202608 THEN vol ELSE 0 END)
       - SUM(CASE WHEN anomes BETWEEN 202501 AND 202508 THEN vol ELSE 0 END) AS delta
  FROM base
  GROUP BY 1, 2
),
pde AS (
  SELECT r.*, r.v / s.V AS share, COALESCE(y.delta, 0) AS delta
  FROM ref r
  JOIN serie s USING (CATEGORIA_DETALHE, SG_SUPERINTENDENCIA)
  LEFT JOIN yoy y USING (ID_PDE, CATEGORIA_DETALHE)
),
grade AS (
  SELECT * FROM VALUES (0.0010), (0.0025), (0.0050), (0.0100), (0.0200) AS s(share_min)
  CROSS JOIN (SELECT * FROM VALUES (100), (500), (1000), (5000) AS m(v_min))
),
marcado AS (
  SELECT p.*, g.share_min, g.v_min,
         (p.share >= g.share_min AND p.v >= g.v_min AND p.meses >= 6) AS grande
  FROM pde p CROSS JOIN grade g
)
SELECT
  CATEGORIA_DETALHE, share_min, v_min,
  COUNT_IF(grande)                                                                  AS n_grandes,
  ROUND(100 * COUNT_IF(grande) / COUNT(*), 3)                                       AS perc_pdes,
  ROUND(100 * SUM(CASE WHEN grande THEN v ELSE 0 END) / SUM(v), 1)                  AS perc_volume,
  ROUND(100 * SUM(CASE WHEN grande THEN ABS(delta) ELSE 0 END) / SUM(ABS(delta)), 1) AS perc_variacao_abs,
  ROUND((SUM(CASE WHEN grande THEN ABS(delta) ELSE 0 END) / SUM(ABS(delta)))
        / NULLIF(SUM(CASE WHEN grande THEN v ELSE 0 END) / SUM(v), 0), 2)           AS indice_concentracao
FROM marcado
GROUP BY 1, 2, 3
ORDER BY 1, 2, 3;

-- COMMAND ----------

-- D5. Conferência com a tabela anterior (requer o backup _bkp criado antes da etapa 3)
SELECT
  COALESCE(n.ANO, o.ANO) AS ANO, COALESCE(n.MES, o.MES) AS MES, COALESCE(n.CATEGORIA, o.CATEGORIA) AS CATEGORIA,
  o.vol_med_agua AS vol_med_agua_antes, n.vol_med_agua AS vol_med_agua_novo,
  ROUND(100 * (n.vol_med_agua / o.vol_med_agua - 1), 3) AS var_perc_vol_med,
  o.vol_fat_agua AS vol_fat_agua_antes, n.vol_fat_agua AS vol_fat_agua_novo,
  ROUND(100 * (n.vol_fat_agua / o.vol_fat_agua - 1), 3) AS var_perc_vol_fat,
  o.n_economias_agua AS econ_antes, n.n_economias_agua AS econ_novo
FROM (SELECT ANO, MES, CATEGORIA, SUM(vol_med_agua) AS vol_med_agua, SUM(vol_fat_agua) AS vol_fat_agua,
             SUM(n_economias_agua) AS n_economias_agua
      FROM `sdb_sbx_adls`.`regulacao`.`gmm_projecao_histograma_por_categoria_atc_recorte`
      GROUP BY 1, 2, 3) n
FULL OUTER JOIN
     (SELECT ANO, MES, CATEGORIA, SUM(vol_med_agua) AS vol_med_agua, SUM(vol_fat_agua) AS vol_fat_agua,
             SUM(n_economias_agua) AS n_economias_agua
      FROM `sdb_sbx_adls`.`regulacao`.`gmm_projecao_histograma_por_categoria_atc_recorte_bkp`
      GROUP BY 1, 2, 3) o
  ON n.ANO = o.ANO AND n.MES = o.MES AND n.CATEGORIA = o.CATEGORIA
ORDER BY 1, 2, 3;
