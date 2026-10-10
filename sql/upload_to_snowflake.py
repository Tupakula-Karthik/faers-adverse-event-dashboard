"""
Upload the FAERS 10-year Parquet export to Snowflake and load it into tables.

Setup (once):   pip install snowflake-connector-python
Run (PowerShell, from your FDA folder):   python upload_to_snowflake.py

You'll be asked for your Snowflake username and password (typed locally, never saved).
Safe to re-run: PUT skips files already uploaded, and tables are reloaded cleanly.
"""
import getpass
from pathlib import Path
import snowflake.connector

ACCOUNT = "YOUR_ORG-YOUR_ACCOUNT"   # your Snowflake account identifier (Snowsight: account menu > copy account identifier)
EXPORT_DIR = Path("faers_export_10y")
TABLES = ["signal_scores", "demo", "reac", "outc", "drug_suspect"]
USE_MFA = True   # set to False if Snowflake never asked you to set up MFA

user = input("Snowflake username: ").strip()
password = getpass.getpass("Snowflake password: ")

kwargs = dict(account=ACCOUNT, user=user, password=password)
if USE_MFA:
    kwargs.update(authenticator="username_password_mfa", client_request_mfa_token=True)

conn = snowflake.connector.connect(**kwargs)
cur = conn.cursor()

def run(sql):
    cur.execute(sql)
    return cur.fetchall()

print("Setting up warehouse, database and stage...")
run("CREATE WAREHOUSE IF NOT EXISTS FAERS_WH WAREHOUSE_SIZE='XSMALL' "
    "AUTO_SUSPEND=60 AUTO_RESUME=TRUE INITIALLY_SUSPENDED=TRUE")
run("USE WAREHOUSE FAERS_WH")
run("CREATE DATABASE IF NOT EXISTS FAERS_10Y")
run("USE SCHEMA FAERS_10Y.PUBLIC")
run("CREATE FILE FORMAT IF NOT EXISTS PARQUET_FF TYPE = PARQUET")
run("CREATE STAGE IF NOT EXISTS FAERS_STAGE FILE_FORMAT = PARQUET_FF")

for t in TABLES:
    folder = (EXPORT_DIR / t).resolve()
    files = sorted(folder.glob("*.parquet"))
    print(f"\n[{t}] uploading {len(files)} files...")
    run(f"PUT 'file://{folder.as_posix()}/*.parquet' @FAERS_STAGE/{t}/ "
        "AUTO_COMPRESS=FALSE PARALLEL=8 OVERWRITE=FALSE")

    print(f"[{t}] creating table...")
    cols = run(f"SELECT COLUMN_NAME, TYPE FROM TABLE(INFER_SCHEMA("
               f"LOCATION=>'@FAERS_STAGE/{t}/', FILE_FORMAT=>'PARQUET_FF'))")
    # unquoted upper-case column names so queries don't need quotes later
    ddl = ", ".join(f"{name.upper()} {typ}" for name, typ in cols)
    run(f"CREATE OR REPLACE TABLE {t.upper()} ({ddl})")

    print(f"[{t}] loading...")
    run(f"COPY INTO {t.upper()} FROM @FAERS_STAGE/{t}/ "
        "FILE_FORMAT=(FORMAT_NAME='PARQUET_FF') "
        "MATCH_BY_COLUMN_NAME=CASE_INSENSITIVE ON_ERROR='ABORT_STATEMENT'")
    n = run(f"SELECT COUNT(*) FROM {t.upper()}")[0][0]
    print(f"[{t}] done: {n:,} rows")

run("ALTER WAREHOUSE FAERS_WH SUSPEND")
print("\nAll tables loaded. Warehouse suspended.")
conn.close()
