"""
Export the 10-year FAERS results from SQL Server (FAERS_10Y) to Parquet files.
Setup (already done):  pip install pandas pyodbc pyarrow sqlalchemy
Run from PowerShell:   python export_to_parquet_10y.py
"""
import os
import pandas as pd
import pyarrow as pa
import pyarrow.parquet as pq
from sqlalchemy import create_engine

SERVER = "localhost"          # same as your first export script
OUT_DIR = "faers_export_10y"
CHUNK = 500_000

engine = create_engine(
    f"mssql+pyodbc://@{SERVER}/FAERS_10Y"
    "?driver=ODBC+Driver+17+for+SQL+Server&trusted_connection=yes"
)

# Only what the dashboard needs. DRUG is limited to suspect drugs and 5 columns
# so the export stays small (full DRUG_clean is ~70M rows).
QUERIES = {
    "signal_scores": "SELECT * FROM SIGNAL_SCORES",
    "demo":          "SELECT * FROM DEMO_clean",
    "reac":          "SELECT * FROM REAC_clean",
    "outc":          "SELECT * FROM OUTC_clean",
    "drug_suspect":  "SELECT primaryid, caseid, drugname, role_cod, quarter "
                     "FROM DRUG_clean WHERE role_cod IN ('PS','SS')",
}

for name, sql in QUERIES.items():
    folder = os.path.join(OUT_DIR, name)
    os.makedirs(folder, exist_ok=True)
    total = 0
    for i, chunk in enumerate(pd.read_sql(sql, engine, chunksize=CHUNK)):
        pq.write_table(pa.Table.from_pandas(chunk), os.path.join(folder, f"part_{i:03d}.parquet"))
        total += len(chunk)
        print(f"{name}: {total:,} rows")
    print(f"Done: {name}\n")
