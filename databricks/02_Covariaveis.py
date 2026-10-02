# Databricks notebook source
# MAGIC %md
# MAGIC # Covariáveis do framework de projeção (direto das APIs)
# MAGIC
# MAGIC Substitui os scripts locais `ETL_CAGED.R`, `ETL_CLIMA.R`, `ETL_MANANCIAIS.R`, `ETL_TARIFA_v4.R` e o
# MAGIC IPCA do `deflateBR`. Cada seção baixa os dados da fonte e grava uma tabela Delta, lida pelo
# MAGIC notebook `03_Base_Analitica_Final`.
# MAGIC
# MAGIC | Seção | Fonte | Tabela (`sdb_sbx_adls.regulacao`) | Atualização |
# MAGIC |---|---|---|---|
# MAGIC | 1 | `gmm_cod_ibge` + malhas do IBGE | `gmm_projecao_cov_municipios` | coordenadas só na 1ª execução |
# MAGIC | 2 | BCB: SGS 433 (IPCA) e Focus | `gmm_projecao_cov_ipca`, `gmm_projecao_cov_focus_ipca` | completa |
# MAGIC | 3 | `Tarifa_final.csv` no Volume | `gmm_projecao_cov_tarifa`, `gmm_projecao_cov_tarifa_tabela` | completa |
# MAGIC | 4 | NASA POWER (diário → mensal) | `gmm_projecao_cov_clima` | incremental (refaz os últimos 3 meses) |
# MAGIC | 5 | Sabesp Mananciais (API v4) | `gmm_projecao_cov_mananciais_diario`, `gmm_projecao_cov_mananciais` | incremental |
# MAGIC | 6 | Novo CAGED (Google Drive do MTE) | `gmm_projecao_cov_caged` | completa (arquivo mais recente) |
# MAGIC | 7 | CSVs antigos de `02_COVARIADAS/02_TRAT` | — | validação da migração |
# MAGIC
# MAGIC As seções são independentes: se uma fonte falhar, as outras rodam e a tabela anterior continua valendo.
# MAGIC
# MAGIC **Arquivos no Volume** (`/Volumes/sdb_sbx_adls/regulacao/projecao`):
# MAGIC - `02_COVARIADAS/01_RAW/Tarifa_final.csv` (obrigatório para a seção 3; é a tabela tarifária montada à mão)
# MAGIC - `02_COVARIADAS/02_TRAT/*.csv` (opcional): os CSVs gerados pelos scripts antigos. Servem para validar a
# MAGIC   migração (seção 7) e para o histórico do nível dos reservatórios antes do alcance da API (seção 5).

# COMMAND ----------

# MAGIC %pip install shapely openpyxl

# COMMAND ----------

dbutils.library.restartPython()

# COMMAND ----------

# MAGIC %md
# MAGIC ## 0. Parâmetros e funções auxiliares

# COMMAND ----------

dbutils.widgets.text("schema", "sdb_sbx_adls.regulacao", "Schema das tabelas")
dbutils.widgets.text("volume", "/Volumes/sdb_sbx_adls/regulacao/projecao", "Volume dos arquivos")
dbutils.widgets.dropdown("modo", "incremental", ["incremental", "completo"], "Modo")
dbutils.widgets.text("drive_api_key", "", "API key do Google Drive (escopo/chave do secret; vazio = sem chave)")
dbutils.widgets.dropdown("nv_sim_agregacao", "auto", ["auto", "media", "fim_mes", "inicio_mes"],
                         "Nível mensal dos reservatórios")

SCHEMA = dbutils.widgets.get("schema")
VOLUME = dbutils.widgets.get("volume").rstrip("/")
MODO = dbutils.widgets.get("modo")
DRIVE_SECRET = dbutils.widgets.get("drive_api_key").strip()
NV_AGREGACAO = dbutils.widgets.get("nv_sim_agregacao")

# Volume: /Volumes/<catálogo>/<schema>/<volume>
_, _, v_cat, v_sch, v_nome = VOLUME.split("/")[:5]
spark.sql(f"CREATE VOLUME IF NOT EXISTS {v_cat}.{v_sch}.{v_nome}")

INICIO_CLIMA = "2010-01-01"       # início da série de clima (igual ao ETL_CLIMA.R)
INICIO_MANANCIAIS = "2016-12-01"  # início da série de mananciais (igual ao ETL_MANANCIAIS.R)
INICIO_CAGED = "2020-01-01"       # 1º mês da Tabela 8.1 do Novo CAGED
INICIO_IPCA = "2000-01-01"
BASE_IRT = "2022-01-01"           # mês base do IRT real (= 100)

print(SCHEMA, VOLUME, MODO, NV_AGREGACAO)

# COMMAND ----------

import html
import io
import os
import re
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import date

import numpy as np
import pandas as pd
import requests
from pyspark.sql import functions as F, types as T

SESSAO = requests.Session()
SESSAO.headers.update({"User-Agent": "Mozilla/5.0 (projecao-consumo; Databricks)"})


class _Repetir(Exception):
    pass


def http_get(url, params=None, headers=None, tentativas=5, timeout=120):
    """GET com novas tentativas (backoff exponencial) em erro de rede, 429 e 5xx."""
    for i in range(tentativas):
        try:
            r = SESSAO.get(url, params=params, headers=headers, timeout=timeout)
            if r.status_code == 429 or r.status_code >= 500:
                raise _Repetir(f"HTTP {r.status_code}")
            r.raise_for_status()
            return r
        except (requests.ConnectionError, requests.Timeout, _Repetir):
            if i == tentativas - 1:
                raise
            time.sleep(2 ** (i + 1))


def tabela(nome):
    return f"{SCHEMA}.{nome}"


def existe(nome):
    return spark.catalog.tableExists(tabela(nome))


def para_spark(pdf):
    """pandas -> Spark com NaN virando NULL (o Spark mantém NaN em double)."""
    sdf = spark.createDataFrame(pdf)
    for f in sdf.schema.fields:
        if isinstance(f.dataType, (T.DoubleType, T.FloatType)):
            sdf = sdf.withColumn(f.name, F.when(F.isnan(F.col(f.name)), None).otherwise(F.col(f.name)))
    return sdf


def grava(pdf, nome):
    """Substitui a tabela inteira."""
    (para_spark(pdf).write.format("delta").mode("overwrite")
     .option("overwriteSchema", "true").saveAsTable(tabela(nome)))
    print(f"{tabela(nome)}: {len(pdf):,} linhas")


def grava_merge(pdf, nome, chaves):
    """Atualiza/insere pelas chaves (incremental)."""
    if not existe(nome):
        return grava(pdf, nome)
    para_spark(pdf).createOrReplaceTempView("_novos")
    cond = " AND ".join(f"t.{c} = s.{c}" for c in chaves)
    spark.sql(f"""MERGE INTO {tabela(nome)} t USING _novos s ON {cond}
                  WHEN MATCHED THEN UPDATE SET * WHEN NOT MATCHED THEN INSERT *""")
    print(f"{tabela(nome)}: {len(pdf):,} linhas atualizadas/inseridas")


def mes(d):
    """Primeiro dia do mês."""
    d = pd.Timestamp(d)
    return date(d.year, d.month, 1)


def soma_meses(d, n):
    d = pd.Timestamp(d) + pd.DateOffset(months=n)
    return date(d.year, d.month, 1)


HOJE = date.today()
MES_ATUAL = mes(HOJE)

# COMMAND ----------

# MAGIC %md
# MAGIC ## 1. Municípios atendidos e coordenadas
# MAGIC
# MAGIC Os municípios vêm do de-para `gmm_cod_ibge` (o mesmo da base de consumo), no lugar do
# MAGIC `HIERARQUIA COMERCIAL AJUSTADA.csv`. As coordenadas seguem o `ETL_CLIMA.R`: ponto interno ao polígono
# MAGIC do município (`st_point_on_surface` no R, `representative_point` no shapely), arredondado a 0,01°.
# MAGIC A malha vem da API de malhas do IBGE (no R vinha do `geobr`, malha 2020).

# COMMAND ----------

def coordenadas_ibge(uf=35):
    from shapely.geometry import shape
    r = http_get(f"https://servicodados.ibge.gov.br/api/v3/malhas/estados/{uf}",
                 params={"formato": "application/vnd.geo+json", "intrarregiao": "municipio",
                         "qualidade": "intermediaria"})
    linhas = []
    for f in r.json()["features"]:
        geo = shape(f["geometry"])
        if not geo.is_valid:
            geo = geo.buffer(0)
        p = geo.representative_point()
        linhas.append({"cd_ibge": str(f["properties"]["codarea"])[:6],
                       "longitude": round(p.x, 2), "latitude": round(p.y, 2)})
    return pd.DataFrame(linhas)


municipios = (spark.sql(f"""
    SELECT DISTINCT SUBSTR(CAST(cd_ibge AS STRING), 1, 6) AS cd_ibge, MUNICIPIO AS municipio
    FROM {tabela('gmm_cod_ibge')}
    WHERE cd_ibge IS NOT NULL""")
    .toPandas()
    .drop_duplicates("cd_ibge"))

coord_ok = existe("gmm_projecao_cov_municipios") and MODO == "incremental"
if coord_ok:
    coord = spark.table(tabela("gmm_projecao_cov_municipios")).toPandas()
    coord_ok = set(municipios.cd_ibge) <= set(coord.dropna(subset=["latitude"]).cd_ibge)

if not coord_ok:
    coord = municipios.merge(coordenadas_ibge(), on="cd_ibge", how="left")
    sem = coord[coord.latitude.isna()]
    if len(sem):
        print("Municípios sem coordenada (ficam sem clima):", sem.to_dict("records"))
    grava(coord, "gmm_projecao_cov_municipios")

coord = coord[coord.cd_ibge.isin(municipios.cd_ibge)].dropna(subset=["latitude"])
print(f"{len(municipios)} municípios no de-para; {len(coord)} com coordenadas")

# COMMAND ----------

# MAGIC %md
# MAGIC ## 2. IPCA (BCB) e expectativas do Focus
# MAGIC
# MAGIC - **SGS 433**: IPCA, variação mensal (%). O índice é o acumulado desde jan/2000. A API do SGS aceita
# MAGIC   no máximo 10 anos por consulta; a série é baixada em blocos.
# MAGIC - **Focus**: mediana das expectativas anuais de IPCA, para a premissa `ipca_aa` da projeção
# MAGIC   (hoje digitada à mão no `03_Projecao.R`).

# COMMAND ----------

def serie_sgs(codigo, inicio, fim=None):
    inicio = pd.Timestamp(inicio).date()
    fim = fim or HOJE
    partes, ano = [], inicio.year
    while ano <= fim.year:
        d0, d1 = max(inicio, date(ano, 1, 1)), min(fim, date(ano + 9, 12, 31))
        r = http_get(f"https://api.bcb.gov.br/dados/serie/bcdata.sgs.{codigo}/dados",
                     params={"formato": "json", "dataInicial": d0.strftime("%d/%m/%Y"),
                             "dataFinal": d1.strftime("%d/%m/%Y")})
        partes.extend(r.json())
        ano += 10
    df = pd.DataFrame(partes)
    df["periodo"] = pd.to_datetime(df["data"], format="%d/%m/%Y").dt.date
    df["valor"] = pd.to_numeric(df["valor"])
    return df[["periodo", "valor"]].drop_duplicates("periodo").sort_values("periodo").reset_index(drop=True)


def ipca_indice(sgs):
    out = sgs.rename(columns={"valor": "ipca_mensal"})
    out["ipca_indice"] = 100 * np.cumprod(1 + out["ipca_mensal"] / 100)
    return out


ipca = ipca_indice(serie_sgs(433, INICIO_IPCA))
grava(ipca, "gmm_projecao_cov_ipca")
print("IPCA até", ipca.periodo.max())

try:
    filtro = requests.utils.quote("Indicador eq 'IPCA' and baseCalculo eq 0")
    url = ("https://olinda.bcb.gov.br/olinda/servico/Expectativas/versao/v1/odata/ExpectativasMercadoAnuais"
           f"?$filter={filtro}&$orderby=Data%20desc&$top=300&$format=json"
           "&$select=Indicador,Data,DataReferencia,Media,Mediana,baseCalculo")
    focus = pd.DataFrame(http_get(url).json()["value"])
    focus = (focus.sort_values("Data", ascending=False)
             .drop_duplicates("DataReferencia")
             .rename(columns={"Data": "data_focus", "DataReferencia": "ano_referencia",
                              "Mediana": "ipca_mediana", "Media": "ipca_media"})
             [["data_focus", "ano_referencia", "ipca_mediana", "ipca_media"]])
    focus["data_focus"] = pd.to_datetime(focus["data_focus"]).dt.date
    grava(focus, "gmm_projecao_cov_focus_ipca")
    display(focus.sort_values("ano_referencia"))
except Exception as e:
    print("Focus indisponível (a projeção segue com a premissa manual):", e)

# COMMAND ----------

# MAGIC %md
# MAGIC ## 3. Tarifa (IRT real)
# MAGIC
# MAGIC Mesma regra do `ETL_TARIFA_v4.R` + `01_Base_Analitica.R`: tarifa de água da faixa 1 do Residencial
# MAGIC Normal da regional OC, deflacionada pelo IPCA e normalizada em `BASE_IRT` = 100:
# MAGIC
# MAGIC `irt_real(t) = 100 × [p(t) / p(base)] × [IPCA(base) / IPCA(t)]`
# MAGIC
# MAGIC Se o IPCA do último mês ainda não saiu, o índice repete o último disponível (`ipca_estimado = true`);
# MAGIC no R, o `deflateBR` deixava o mês sem tarifa.
# MAGIC
# MAGIC A tabela completa (todas as regionais, categorias e faixas) fica em `gmm_projecao_cov_tarifa_tabela`,
# MAGIC para uma tarifa por categoria no futuro.

# COMMAND ----------

arq_tarifa = f"{VOLUME}/02_COVARIADAS/01_RAW/Tarifa_final.csv"

if not os.path.exists(arq_tarifa):
    print(f"Sem {arq_tarifa}: suba o arquivo no Volume. A tabela anterior continua valendo.")
else:
    tab = pd.read_csv(arq_tarifa)
    tab.columns = [c.strip().lower() for c in tab.columns]
    tab["periodo"] = pd.to_datetime(tab["periodo"]).dt.date
    grava(tab, "gmm_projecao_cov_tarifa_tabela")

    ref = (tab[(tab.cd_regiao == "OC") & (tab.cd_faixa == 1) & (tab.categoria_detalhe == "Residencial Normal")]
           [["periodo", "tarifa_agua"]].rename(columns={"tarifa_agua": "p_agua"})
           .sort_values("periodo").reset_index(drop=True))
    assert not ref.periodo.duplicated().any(), "Tarifa duplicada por período (OC, faixa 1, Residencial Normal)"

    tarifa = ref.merge(ipca[["periodo", "ipca_indice"]], on="periodo", how="left")
    tarifa["ipca_estimado"] = tarifa["ipca_indice"].isna()
    tarifa["ipca_indice"] = tarifa["ipca_indice"].ffill()
    tarifa["delta"] = tarifa["p_agua"] / tarifa["p_agua"].shift() - 1
    base = tarifa[tarifa.periodo >= pd.Timestamp(BASE_IRT).date()].iloc[0]
    tarifa["irt_real"] = 100 * (tarifa["p_agua"] / base.p_agua) * (base.ipca_indice / tarifa["ipca_indice"])
    grava(tarifa, "gmm_projecao_cov_tarifa")
    display(tarifa[tarifa.delta.fillna(0) != 0])

# COMMAND ----------

# MAGIC %md
# MAGIC ## 4. Clima (NASA POWER)
# MAGIC
# MAGIC Mesmas variáveis do `ETL_CLIMA.R` (comunidade AG, dados diários), com média mensal dos dias:
# MAGIC
# MAGIC | POWER | Coluna | Unidade |
# MAGIC |---|---|---|
# MAGIC | `T2M`, `T2M_MIN`, `T2M_MAX` | `temp_med`, `temp_min`, `temp_max` | °C |
# MAGIC | `PRECTOTCORR` | `prec_tot` | **mm/dia** (média diária do mês, não o total) |
# MAGIC | `RH2M` | `umi_rel` | % |
# MAGIC | `T2MDEW` | `temp_orv` | °C |
# MAGIC | `WS2M` | `vel_vento` | m/s |
# MAGIC
# MAGIC Diferenças em relação ao R:
# MAGIC - Incremental: baixa só a partir de 3 meses antes do último mês gravado (o POWER revisa os dados
# MAGIC   recentes). Município novo baixa o histórico todo.
# MAGIC - O valor ausente do POWER (−999) vira NULL antes da média.
# MAGIC - Mês só entra com ao menos 90% dos dias com dado (`dias_validos`); o mês corrente nunca entra.
# MAGIC - Só os municípios do de-para (o R baixava os 645 de SP e filtrava depois).

# COMMAND ----------

POWER_VARS = {"T2M": "temp_med", "T2M_MAX": "temp_max", "T2M_MIN": "temp_min", "PRECTOTCORR": "prec_tot",
              "RH2M": "umi_rel", "T2MDEW": "temp_orv", "WS2M": "vel_vento"}


def power_diario(lon, lat, inicio, fim):
    r = http_get("https://power.larc.nasa.gov/api/temporal/daily/point",
                 params={"parameters": ",".join(POWER_VARS), "community": "AG",
                         "longitude": lon, "latitude": lat,
                         "start": pd.Timestamp(inicio).strftime("%Y%m%d"),
                         "end": pd.Timestamp(fim).strftime("%Y%m%d"), "format": "JSON"},
                 timeout=300)
    js = r.json()
    fill = js.get("header", {}).get("fill_value", -999)
    df = pd.DataFrame(js["properties"]["parameter"])
    df.index = pd.to_datetime(df.index, format="%Y%m%d")
    df = df.apply(pd.to_numeric, errors="coerce")
    return df.mask((df == fill) | (df <= -990))


def clima_mensal(diario, mes_limite):
    d = diario.copy()
    d["periodo"] = d.index.to_period("M").to_timestamp()
    g = d.groupby("periodo")
    m = g[list(POWER_VARS)].mean()
    m["dias_validos"] = g[list(POWER_VARS)].count().min(axis=1)
    m["dias_mes"] = m.index.days_in_month
    m = m[(m["dias_validos"] >= np.ceil(0.9 * m["dias_mes"])) & (m.index < pd.Timestamp(mes_limite))]
    m = m.rename(columns=POWER_VARS).drop(columns="dias_mes").reset_index()
    m["periodo"] = m["periodo"].dt.date
    return m


inicio_inc = None
if MODO == "incremental" and existe("gmm_projecao_cov_clima"):
    ult = spark.sql(f"SELECT MAX(periodo) FROM {tabela('gmm_projecao_cov_clima')}").first()[0]
    ja_tem = set(r.cd_ibge for r in spark.sql(
        f"SELECT DISTINCT cd_ibge FROM {tabela('gmm_projecao_cov_clima')}").collect())
    inicio_inc = soma_meses(ult, -3) if ult else None
else:
    ja_tem = set()

tarefas = []
for m in coord.itertuples():
    ini = inicio_inc if (inicio_inc and m.cd_ibge in ja_tem) else pd.Timestamp(INICIO_CLIMA).date()
    tarefas.append((m.cd_ibge, m.municipio, m.longitude, m.latitude, ini))


def baixa_municipio(t):
    cd_ibge, municipio, lon, lat, ini = t
    m = clima_mensal(power_diario(lon, lat, ini, HOJE), MES_ATUAL)
    m.insert(0, "municipio", municipio)
    m.insert(0, "cd_ibge", cd_ibge)
    return m


resultados, falhas = [], []
with ThreadPoolExecutor(max_workers=4) as ex:   # POWER: poucos pedidos simultâneos
    futuros = {ex.submit(baixa_municipio, t): t for t in tarefas}
    for f in as_completed(futuros):
        try:
            resultados.append(f.result())
        except Exception as e:
            falhas.append((futuros[f][0], futuros[f][1], str(e)[:200]))

print(f"Clima: {len(resultados)} municípios baixados, {len(falhas)} falhas")
if falhas:
    print(falhas[:20])
assert len(falhas) <= 0.05 * max(len(tarefas), 1), "Muitas falhas no POWER: tabela não atualizada"

clima = pd.concat(resultados, ignore_index=True)
grava_merge(clima, "gmm_projecao_cov_clima", ["cd_ibge", "periodo"])

# COMMAND ----------

# MAGIC %md
# MAGIC ## 5. Nível dos reservatórios (Sabesp Mananciais, API v4)
# MAGIC
# MAGIC O `ETL_MANANCIAIS.R` abria o site num navegador (chromote) e clicava em "baixar planilha". Aqui a
# MAGIC leitura é direto na API que o site usa:
# MAGIC
# MAGIC - `GET https://mananciais.sabesp.com.br/api/v4/dados/ultima-data`
# MAGIC - `GET https://mananciais.sabesp.com.br/api/v4/sistemas/dados/resumo-diario/{AAAA-MM-DD}`
# MAGIC   (todos os sistemas no dia; `idSistema = 75` é o Sistema Integrado Metropolitano, o mesmo
# MAGIC   `locais=75` do script antigo; campo `volumeUtilArmazenadoPorcentagem`)
# MAGIC
# MAGIC Pontos de atenção:
# MAGIC 1. **Histórico**: há relato de que a API devolve só cerca de 1 ano para trás. Os meses que a API não
# MAGIC    cobre vêm do CSV antigo (`02_COVARIADAS/02_TRAT/MANANCIAIS_*.csv`, se estiver no Volume).
# MAGIC 2. **Agregação mensal**: o site entregava o valor mensal pronto (`passoTemporal=mensal`), sem dizer se
# MAGIC    é média, primeiro ou último dia. Com `nv_sim_agregacao = auto`, o notebook compara as três
# MAGIC    opções com o CSV antigo nos meses em comum e usa a que bate.
# MAGIC 3. `nv_sim` fica em % (0-100), como no CSV; o `03_Base_Analitica_Final` divide por 100 e cria a defasagem.

# COMMAND ----------

SABESP_API = "https://mananciais.sabesp.com.br/api/v4"
SABESP_HEAD = {"Referer": "https://mananciais.sabesp.com.br/", "Accept": "application/json"}
ID_SIM = 75


def sabesp_ultima_data():
    return pd.Timestamp(http_get(f"{SABESP_API}/dados/ultima-data", headers=SABESP_HEAD).json()["data"]).date()


FALHAS_SABESP = []


def sabesp_dia(d):
    try:
        r = http_get(f"{SABESP_API}/sistemas/dados/resumo-diario/{d.isoformat()}", headers=SABESP_HEAD, timeout=60)
    except requests.HTTPError:
        return []                       # dia sem dado
    except Exception as e:
        FALHAS_SABESP.append((d, str(e)[:100]))
        return []
    return [{"data": d, "id_sistema": int(i["idSistema"]),
             "volume_util_pct": float(i["volumeUtilArmazenadoPorcentagem"])}
            for i in r.json().get("data", []) if i.get("volumeUtilArmazenadoPorcentagem") is not None]


def nivel_mensal(diario_sim, ultima):
    """Média, primeiro e último dia de cada mês completo (ao menos 90% dos dias e mês já encerrado)."""
    d = diario_sim.copy()
    d["periodo"] = pd.to_datetime(d["data"]).dt.to_period("M").dt.to_timestamp()
    d = d.sort_values("data")
    g = d.groupby("periodo")["volume_util_pct"]
    m = pd.DataFrame({"media": g.mean(), "inicio_mes": g.first(), "fim_mes": g.last(), "dias": g.count()})
    m["dias_mes"] = m.index.days_in_month
    fim_mes = m.index + pd.offsets.MonthEnd(0)
    m = m[(m["dias"] >= np.ceil(0.9 * m["dias_mes"])) & (fim_mes <= pd.Timestamp(ultima))]
    m = m.drop(columns="dias_mes").reset_index()
    m["periodo"] = m["periodo"].dt.date
    return m


ultima = sabesp_ultima_data()
if MODO == "incremental" and existe("gmm_projecao_cov_mananciais_diario"):
    ult = spark.sql(f"SELECT MAX(data) FROM {tabela('gmm_projecao_cov_mananciais_diario')}").first()[0]
    inicio = (pd.Timestamp(ult) - pd.Timedelta(days=7)).date()
else:
    inicio = pd.Timestamp(INICIO_MANANCIAIS).date()

dias = list(pd.date_range(inicio, ultima, freq="D").date)
linhas = []
with ThreadPoolExecutor(max_workers=4) as ex:
    for res in ex.map(sabesp_dia, dias):
        linhas.extend(res)

if linhas:
    grava_merge(pd.DataFrame(linhas), "gmm_projecao_cov_mananciais_diario", ["data", "id_sistema"])
print(f"Mananciais: {len(dias)} dias pedidos ({inicio} a {ultima}), {len(linhas)} registros, "
      f"{len(FALHAS_SABESP)} falhas de conexão")
assert len(FALHAS_SABESP) <= 0.05 * max(len(dias), 1), "Muitas falhas na API de mananciais"

diario_sim = spark.sql(f"""SELECT data, volume_util_pct FROM {tabela('gmm_projecao_cov_mananciais_diario')}
                           WHERE id_sistema = {ID_SIM}""").toPandas()
mensal_api = nivel_mensal(diario_sim, ultima)

# CSV antigo: histórico e referência para a agregação
legado = sorted(f for f in os.listdir(f"{VOLUME}/02_COVARIADAS/02_TRAT")
                if f.startswith("MANANCIAIS_") and f.endswith(".csv")) \
    if os.path.isdir(f"{VOLUME}/02_COVARIADAS/02_TRAT") else []
if legado:
    ant = pd.read_csv(f"{VOLUME}/02_COVARIADAS/02_TRAT/{legado[-1]}")
    ant["periodo"] = pd.to_datetime(ant["periodo"]).dt.to_period("M").dt.to_timestamp().dt.date
    ant = ant[["periodo", "nv_sim"]].drop_duplicates("periodo")
else:
    ant = pd.DataFrame(columns=["periodo", "nv_sim"])

agreg = NV_AGREGACAO
comum = mensal_api.merge(ant, on="periodo")
if agreg == "auto":
    if len(comum) >= 3:
        erros = {a: (comum[a] - comum["nv_sim"]).abs().mean() for a in ["media", "inicio_mes", "fim_mes"]}
        agreg = min(erros, key=erros.get)
        print("Erro médio absoluto contra o CSV antigo (p.p.):", {k: round(v, 3) for k, v in erros.items()})
    else:
        agreg = "media"
        print("Sem meses em comum com o CSV antigo: usando a média do mês")
print("Agregação mensal usada:", agreg)

mananciais = mensal_api[["periodo", agreg, "dias"]].rename(columns={agreg: "nv_sim"})
mananciais["fonte"] = "api"
hist = ant[~ant.periodo.isin(mananciais.periodo)].assign(dias=np.nan, fonte="csv_antigo")
mananciais = pd.concat([hist, mananciais], ignore_index=True).sort_values("periodo").reset_index(drop=True)
mananciais["agregacao"] = agreg
grava(mananciais, "gmm_projecao_cov_mananciais")

lacunas = pd.date_range(mananciais.periodo.min(), mananciais.periodo.max(), freq="MS").date
lacunas = sorted(set(lacunas) - set(mananciais.periodo))
if lacunas:
    print("Meses sem nível (o 03 interpola):", lacunas)

# COMMAND ----------

# MAGIC %md
# MAGIC ## 6. Novo CAGED: estoque de empregos por município
# MAGIC
# MAGIC Mesma fonte do `ETL_CAGED.R`: a pasta pública do MTE no Google Drive, com uma subpasta por mês
# MAGIC (`AAAA-MM`). Do arquivo mais recente, lê a "Tabela 8.1" (estoque, admissões, desligamentos e saldo por
# MAGIC município e mês, desde jan/2020). O arquivo mais recente traz o histórico revisado, então a tabela é
# MAGIC substituída inteira.
# MAGIC
# MAGIC **Acesso à pasta**: com `drive_api_key` (secret `escopo/chave` com uma API key do Google Cloud com a
# MAGIC Drive API habilitada), usa a API oficial. Sem chave, lê a página pública de visualização da pasta,
# MAGIC que funciona para pastas compartilhadas com "qualquer pessoa com o link", mas é menos estável. Se o Drive
# MAGIC falhar, usa o `.xlsx` mais recente em `02_COVARIADAS/01_RAW/caged/` no Volume (baixado à mão).
# MAGIC
# MAGIC **Leitura da tabela**: o R dava nome às colunas pela posição (3 colunas de identificação; 4 no 1º mês;
# MAGIC 5 nos seguintes; 8 no fim), sem checar nada. Aqui a posição é a mesma, mas o número de meses é
# MAGIC deduzido do número de colunas e conferido com o nome da pasta, e o alinhamento é validado:
# MAGIC estoque(t) − estoque(t−1) deve ser igual ao saldo(t).

# COMMAND ----------

PASTA_CAGED = "1DSI-ylLcZc_ELKb1M50MgDDi3CLo_iaY"
DRIVE_KEY = dbutils.secrets.get(*DRIVE_SECRET.split("/", 1)) if DRIVE_SECRET else None


def drive_lista(pasta_id):
    """Itens de uma pasta pública: [{id, nome, pasta}]."""
    if DRIVE_KEY:
        itens, token = [], None
        while True:
            p = {"q": f"'{pasta_id}' in parents and trashed = false", "key": DRIVE_KEY,
                 "fields": "nextPageToken, files(id, name, mimeType)", "pageSize": 1000,
                 "supportsAllDrives": "true", "includeItemsFromAllDrives": "true"}
            if token:
                p["pageToken"] = token
            js = http_get("https://www.googleapis.com/drive/v3/files", params=p).json()
            itens += js.get("files", [])
            token = js.get("nextPageToken")
            if not token:
                break
        return [{"id": i["id"], "nome": i["name"],
                 "pasta": i["mimeType"] == "application/vnd.google-apps.folder"} for i in itens]
    pagina = http_get("https://drive.google.com/embeddedfolderview", params={"id": pasta_id}).text
    itens = []
    for bloco in pagina.split('class="flip-entry"')[1:]:
        fid = re.search(r'id="entry-([^"]+)"', bloco)
        href = re.search(r'href="([^"]+)"', bloco)
        nome = re.search(r'class="flip-entry-title">([^<]+)<', bloco)
        if fid and nome:
            itens.append({"id": fid.group(1), "nome": html.unescape(nome.group(1)).strip(),
                          "pasta": bool(href and "/folders/" in href.group(1))})
    if not itens:
        raise RuntimeError("Não consegui listar a pasta do Drive sem chave: configure drive_api_key")
    return itens


def drive_baixa(fid):
    if DRIVE_KEY:
        return http_get(f"https://www.googleapis.com/drive/v3/files/{fid}",
                        params={"alt": "media", "key": DRIVE_KEY, "supportsAllDrives": "true"}).content
    return http_get("https://drive.usercontent.google.com/download",
                    params={"id": fid, "export": "download", "confirm": "t"}).content


def periodo_pasta(nome):
    m = re.search(r"(20\d{2})\D?(0[1-9]|1[0-2])(?!\d)", nome)
    return date(int(m.group(1)), int(m.group(2)), 1) if m else None


def caged_estoque(conteudo, inicio=INICIO_CAGED, periodo_esperado=None):
    """Estoque por município x mês da Tabela 8.1 (posições iguais às do ETL_CAGED.R)."""
    df = pd.read_excel(io.BytesIO(conteudo), sheet_name="Tabela 8.1", header=None, dtype=object)
    while df.shape[1] and df.iloc[:, -1].isna().all():      # colunas vazias à direita
        df = df.iloc[:, :-1]
    n_col = df.shape[1]
    if (n_col - 10) % 5:
        raise ValueError(f"Tabela 8.1 com {n_col} colunas: layout diferente do esperado (5 x meses + 10)")
    n_meses = (n_col - 10) // 5
    meses = [soma_meses(inicio, k) for k in range(n_meses)]
    if periodo_esperado and meses[-1] != periodo_esperado:
        print(f"Atenção: a tabela vai até {meses[-1]}, a pasta é de {periodo_esperado}")

    uf = df[0].astype(str).str.strip()
    cod = pd.to_numeric(df[1], errors="coerce")
    linha_mun = uf.str.fullmatch(r"[A-Z]{2}") & cod.between(110000, 539999)
    dados = df[linha_mun].reset_index(drop=True)

    col_est = [3] + [7 + 5 * (k - 1) for k in range(1, n_meses)]
    col_saldo = [6] + [10 + 5 * (k - 1) for k in range(1, n_meses)]
    est = dados[col_est].apply(pd.to_numeric, errors="coerce").to_numpy(dtype=float)
    saldo = dados[col_saldo].apply(pd.to_numeric, errors="coerce").to_numpy(dtype=float)

    # Validação do alinhamento: estoque(t) - estoque(t-1) = saldo(t)
    dif = np.abs(np.diff(est, axis=1) - saldo[:, 1:])
    ok = np.nanmean(dif <= 1)
    print(f"CAGED: {len(dados)} municípios, {n_meses} meses ({meses[0]} a {meses[-1]}); "
          f"estoque(t) - estoque(t-1) = saldo(t) em {ok:.1%} das células")
    if ok < 0.8:
        raise ValueError("Colunas desalinhadas: a variação do estoque não bate com o saldo")

    out = pd.DataFrame(est, columns=meses)
    out.insert(0, "cd_ibge", cod[linha_mun].astype(int).astype(str).to_numpy())
    out.insert(0, "uf", uf[linha_mun].to_numpy())
    out = out.melt(id_vars=["uf", "cd_ibge"], var_name="periodo", value_name="estoque")
    return out


def arquivos_drive():
    """(nome, conteúdo, período da pasta) dos .xlsx da subpasta mais recente."""
    subpastas = [dict(i, periodo=periodo_pasta(i["nome"])) for i in drive_lista(PASTA_CAGED) if i["pasta"]]
    recente = max((p for p in subpastas if p["periodo"]), key=lambda p: p["periodo"])
    arquivos = sorted((i for i in drive_lista(recente["id"]) if i["nome"].lower().endswith(".xlsx")),
                      key=lambda i: i["nome"])
    print("Pasta mais recente:", recente["nome"], "| arquivos:", [a["nome"] for a in arquivos])
    for a in arquivos:
        yield a["nome"], drive_baixa(a["id"]), recente["periodo"]


def arquivos_volume():
    """Plano B: .xlsx baixados à mão para o Volume (o mais recente primeiro)."""
    pasta = f"{VOLUME}/02_COVARIADAS/01_RAW/caged"
    nomes = sorted((f for f in os.listdir(pasta) if f.lower().endswith(".xlsx")), reverse=True) \
        if os.path.isdir(pasta) else []
    for n in nomes:
        with open(f"{pasta}/{n}", "rb") as f:
            yield n, f.read(), None


def le_caged(fonte):
    for nome, conteudo, periodo in fonte:
        if "Tabela 8.1" in pd.ExcelFile(io.BytesIO(conteudo)).sheet_names:
            print("Lido de", nome)
            return caged_estoque(conteudo, periodo_esperado=periodo)
    return None


try:
    caged = le_caged(arquivos_drive())
except Exception as e:
    print("Drive indisponível:", str(e)[:300])
    caged = None
if caged is None:
    caged = le_caged(arquivos_volume())

if caged is None:
    raise RuntimeError("CAGED não lido: o Drive falhou (ver mensagem acima) e não há .xlsx com a Tabela 8.1 "
                       "em 02_COVARIADAS/01_RAW/caged/ no Volume. A tabela anterior continua valendo.")

caged = (caged[caged.uf == "SP"]
         .merge(municipios, on="cd_ibge", how="inner")
         [["cd_ibge", "municipio", "periodo", "estoque"]]
         .sort_values(["cd_ibge", "periodo"]).reset_index(drop=True))
grava(caged, "gmm_projecao_cov_caged")
print(f"{caged.cd_ibge.nunique()} municípios; sem estoque: {caged.estoque.isna().sum()} células")

# COMMAND ----------

# MAGIC %md
# MAGIC ## 7. Validação contra os CSVs antigos
# MAGIC
# MAGIC Com os CSVs dos scripts antigos em `02_COVARIADAS/02_TRAT/`, compara as novas tabelas nas chaves em comum.
# MAGIC Diferenças esperadas:
# MAGIC - **Clima**: pequenas, porque a malha municipal e o ponto interno vêm de outra fonte. Valores iguais na
# MAGIC   maioria dos municípios, já que a grade do POWER (0,5° × 0,625°) é bem maior que o arredondamento.
# MAGIC - **CAGED**: revisões do MTE entre a versão antiga e a nova.
# MAGIC - **Tarifa**: o `irt_real` antigo era calculado no `01_Base_Analitica.R`, e o CSV só tem `p_agua`; a
# MAGIC   comparação é do `p_agua`.

# COMMAND ----------

def compara(nome, arquivo, chaves, colunas, prep=None):
    caminho = f"{VOLUME}/02_COVARIADAS/02_TRAT/{arquivo}"
    ant = pd.read_csv(caminho)
    if prep:
        ant = prep(ant)
    novo = spark.table(tabela(nome)).toPandas()
    for c in chaves:
        ant[c] = ant[c].astype(str)
        novo[c] = novo[c].astype(str)
    j = ant.merge(novo, on=chaves, suffixes=("_ant", "_novo"))
    linhas = []
    for c in colunas:
        d = (j[f"{c}_novo"] - j[f"{c}_ant"]).abs()
        linhas.append({"tabela": nome, "variavel": c, "chaves_comuns": len(j),
                       "dif_media": d.mean(), "dif_max": d.max(),
                       "corr": j[[f"{c}_novo", f"{c}_ant"]].corr().iloc[0, 1]})
    return linhas


def mes_txt(df):
    df["periodo"] = pd.to_datetime(df["periodo"]).dt.strftime("%Y-%m-%d")
    return df


dir_ant = f"{VOLUME}/02_COVARIADAS/02_TRAT"
if os.path.isdir(dir_ant):
    arqs = sorted(os.listdir(dir_ant))
    ult = lambda p: [a for a in arqs if a.startswith(p) and a.endswith(".csv")][-1:]
    res = []
    for a in ult("CLIMA_"):
        res += compara("gmm_projecao_cov_clima", a, ["cd_ibge", "periodo"], ["temp_med", "prec_tot"], mes_txt)
    for a in ult("CAGED_"):
        res += compara("gmm_projecao_cov_caged", a, ["cd_ibge", "periodo"], ["estoque"], mes_txt)
    for a in ult("TARIFA_"):
        res += compara("gmm_projecao_cov_tarifa", a, ["periodo"], ["p_agua"], mes_txt)
    display(pd.DataFrame(res))
else:
    print(f"Sem {dir_ant}: validação ignorada")

# COMMAND ----------

# Resumo das tabelas
for nome in ["gmm_projecao_cov_ipca", "gmm_projecao_cov_tarifa", "gmm_projecao_cov_clima",
             "gmm_projecao_cov_mananciais", "gmm_projecao_cov_caged"]:
    if existe(nome):
        r = spark.sql(f"SELECT MIN(periodo) ini, MAX(periodo) fim, COUNT(*) n FROM {tabela(nome)}").first()
        print(f"{nome:35s} {r.ini} a {r.fim} ({r.n:,} linhas)")
    else:
        print(f"{nome:35s} não existe")
