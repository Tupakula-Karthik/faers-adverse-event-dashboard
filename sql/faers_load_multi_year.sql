/* ============================================================================
   FAERS MULTI-YEAR LOAD (2015 Q1 - 2025 Q4)
   Runs in a NEW database (FAERS_10Y) so your existing FAERS project is untouched.
   Based on faers_pipeline.sql: same schema and load logic, but file names now
   include the year (e.g. DEMO15Q1.txt) and the quarter list covers 44 quarters.
   After loading, run faers_clean_signals_10y.sql (dedup, cleaning, PRR/ROR).
   ============================================================================ */

IF DB_ID('FAERS_10Y') IS NULL CREATE DATABASE FAERS_10Y;
GO
USE FAERS_10Y;
GO

/* ============================================================================
   SECTION 1: SCHEMA -- STAGING (_load) AND FINAL (_raw) TABLES
   ============================================================================
   Each FAERS file gets TWO tables:
     - <name>_load : column-for-column identical to the raw file. BULK INSERT
                     targets this table, because BULK INSERT maps fields to
                     columns strictly by position -- if the table has even one
                     extra column beyond what the file provides, every field
                     after that point gets misaligned and truncation errors
                     occur. Keeping _load's shape IDENTICAL to the file avoids
                     this entirely.
     - <name>_raw  : the same columns, plus a `quarter` tag (e.g. '2025Q1').
                      Data is pushed here from _load via INSERT...SELECT,
                      which is a normal SQL statement and has no positional
                      mapping restriction, so adding the extra `quarter`
                      column here is safe.
   Run this section once, or any time you want to reset everything.
   ============================================================================ */

DROP TABLE IF EXISTS DEMO_load; DROP TABLE IF EXISTS DEMO_raw;
DROP TABLE IF EXISTS DRUG_load; DROP TABLE IF EXISTS DRUG_raw;
DROP TABLE IF EXISTS REAC_load; DROP TABLE IF EXISTS REAC_raw;
DROP TABLE IF EXISTS OUTC_load; DROP TABLE IF EXISTS OUTC_raw;
DROP TABLE IF EXISTS THER_load; DROP TABLE IF EXISTS THER_raw;
DROP TABLE IF EXISTS INDI_load; DROP TABLE IF EXISTS INDI_raw;
DROP TABLE IF EXISTS RPSR_load; DROP TABLE IF EXISTS RPSR_raw;
GO

-- DEMO: case demographics. 25 columns, matching the file's header exactly.
CREATE TABLE DEMO_load (
    primaryid BIGINT, caseid BIGINT, caseversion INT, i_f_code VARCHAR(50),
    event_dt VARCHAR(50), mfr_dt VARCHAR(50), init_fda_dt VARCHAR(50), fda_dt VARCHAR(50),
    rept_cod VARCHAR(50), auth_num VARCHAR(200), mfr_num VARCHAR(200), mfr_sndr VARCHAR(200),
    lit_ref VARCHAR(MAX),   -- literature citations can be long free text
    age DECIMAL(14,2), age_cod VARCHAR(50), age_grp VARCHAR(50),
    sex VARCHAR(50), e_sub VARCHAR(50), wt DECIMAL(14,2), wt_cod VARCHAR(50),
    rept_dt VARCHAR(50), to_mfr VARCHAR(50), occp_cod VARCHAR(50),
    reporter_country VARCHAR(50), occr_country VARCHAR(50)
);
SELECT *, CAST(NULL AS VARCHAR(6)) AS quarter INTO DEMO_raw FROM DEMO_load WHERE 1=0;

-- DRUG: every drug listed per case (multiple rows per case). 20 columns.
-- NOTE: line endings vary by quarter (mostly CRLF, some LF); the loader reads LF and strips any CR.
CREATE TABLE DRUG_load (
    primaryid BIGINT, caseid BIGINT, drug_seq INT, role_cod VARCHAR(50),
    drugname VARCHAR(500), prod_ai VARCHAR(500), val_vbm INT, route VARCHAR(100),
    dose_vbm VARCHAR(200), cum_dose_chr VARCHAR(50), cum_dose_unit VARCHAR(50),
    dechal VARCHAR(50), rechal VARCHAR(50), lot_num VARCHAR(200), exp_dt VARCHAR(50),
    nda_num VARCHAR(50), dose_amt VARCHAR(50), dose_unit VARCHAR(50),
    dose_form VARCHAR(100), dose_freq VARCHAR(50)
);
SELECT *, CAST(NULL AS VARCHAR(6)) AS quarter INTO DRUG_raw FROM DRUG_load WHERE 1=0;

-- REAC: adverse reactions reported (MedDRA Preferred Terms). 4 columns.
CREATE TABLE REAC_load (primaryid BIGINT, caseid BIGINT, pt VARCHAR(500), drug_rec_act VARCHAR(500));
SELECT *, CAST(NULL AS VARCHAR(6)) AS quarter INTO REAC_raw FROM REAC_load WHERE 1=0;

-- OUTC: case outcomes (death, hospitalization, etc). 3 columns.
CREATE TABLE OUTC_load (primaryid BIGINT, caseid BIGINT, outc_cod VARCHAR(50));
SELECT *, CAST(NULL AS VARCHAR(6)) AS quarter INTO OUTC_raw FROM OUTC_load WHERE 1=0;

-- THER: drug therapy start/end dates. 7 columns.
CREATE TABLE THER_load (primaryid BIGINT, caseid BIGINT, dsg_drug_seq INT, start_dt VARCHAR(50), end_dt VARCHAR(50), dur VARCHAR(50), dur_cod VARCHAR(50));
SELECT *, CAST(NULL AS VARCHAR(6)) AS quarter INTO THER_raw FROM THER_load WHERE 1=0;

-- INDI: indications (why the drug was prescribed). 4 columns.
CREATE TABLE INDI_load (primaryid BIGINT, caseid BIGINT, indi_drug_seq INT, indi_pt VARCHAR(500));
SELECT *, CAST(NULL AS VARCHAR(6)) AS quarter INTO INDI_raw FROM INDI_load WHERE 1=0;

-- RPSR: report source (physician, consumer, etc). 3 columns.
CREATE TABLE RPSR_load (primaryid BIGINT, caseid BIGINT, rpsr_cod VARCHAR(50));
SELECT *, CAST(NULL AS VARCHAR(6)) AS quarter INTO RPSR_raw FROM RPSR_load WHERE 1=0;
GO


DECLARE @quarters TABLE (qtr VARCHAR(6), folder VARCHAR(500));
INSERT INTO @quarters (qtr, folder) VALUES
    ('2015Q1', 'C:\Users\user\Desktop\FDA\years\2015q1\ASCII\'),
    ('2015Q2', 'C:\Users\user\Desktop\FDA\years\2015q2\ASCII\'),
    ('2015Q3', 'C:\Users\user\Desktop\FDA\years\2015q3\ASCII\'),
    ('2015Q4', 'C:\Users\user\Desktop\FDA\years\2015q4\ASCII\'),
    ('2016Q1', 'C:\Users\user\Desktop\FDA\years\2016q1\ASCII\'),
    ('2016Q2', 'C:\Users\user\Desktop\FDA\years\2016q2\ASCII\'),
    ('2016Q3', 'C:\Users\user\Desktop\FDA\years\2016q3\ASCII\'),
    ('2016Q4', 'C:\Users\user\Desktop\FDA\years\2016q4\ASCII\'),
    ('2017Q1', 'C:\Users\user\Desktop\FDA\years\2017q1\ASCII\'),
    ('2017Q2', 'C:\Users\user\Desktop\FDA\years\2017q2\ASCII\'),
    ('2017Q3', 'C:\Users\user\Desktop\FDA\years\2017q3\ASCII\'),
    ('2017Q4', 'C:\Users\user\Desktop\FDA\years\2017q4\ASCII\'),
    ('2018Q1', 'C:\Users\user\Desktop\FDA\years\2018q1\ASCII\'),
    ('2018Q2', 'C:\Users\user\Desktop\FDA\years\2018q2\ASCII\'),
    ('2018Q3', 'C:\Users\user\Desktop\FDA\years\2018q3\ASCII\'),
    ('2018Q4', 'C:\Users\user\Desktop\FDA\years\2018q4\ASCII\'),
    ('2019Q1', 'C:\Users\user\Desktop\FDA\years\2019q1\ASCII\'),
    ('2019Q2', 'C:\Users\user\Desktop\FDA\years\2019q2\ASCII\'),
    ('2019Q3', 'C:\Users\user\Desktop\FDA\years\2019q3\ASCII\'),
    ('2019Q4', 'C:\Users\user\Desktop\FDA\years\2019q4\ASCII\'),
    ('2020Q1', 'C:\Users\user\Desktop\FDA\years\2020q1\ASCII\'),
    ('2020Q2', 'C:\Users\user\Desktop\FDA\years\2020q2\ASCII\'),
    ('2020Q3', 'C:\Users\user\Desktop\FDA\years\2020q3\ASCII\'),
    ('2020Q4', 'C:\Users\user\Desktop\FDA\years\2020q4\ASCII\'),
    ('2021Q1', 'C:\Users\user\Desktop\FDA\years\2021q1\ASCII\'),
    ('2021Q2', 'C:\Users\user\Desktop\FDA\years\2021q2\ASCII\'),
    ('2021Q3', 'C:\Users\user\Desktop\FDA\years\2021q3\ASCII\'),
    ('2021Q4', 'C:\Users\user\Desktop\FDA\years\2021q4\ASCII\'),
    ('2022Q1', 'C:\Users\user\Desktop\FDA\years\2022q1\ASCII\'),
    ('2022Q2', 'C:\Users\user\Desktop\FDA\years\2022q2\ASCII\'),
    ('2022Q3', 'C:\Users\user\Desktop\FDA\years\2022q3\ASCII\'),
    ('2022Q4', 'C:\Users\user\Desktop\FDA\years\2022q4\ASCII\'),
    ('2023Q1', 'C:\Users\user\Desktop\FDA\years\2023q1\ASCII\'),
    ('2023Q2', 'C:\Users\user\Desktop\FDA\years\2023q2\ASCII\'),
    ('2023Q3', 'C:\Users\user\Desktop\FDA\years\2023q3\ASCII\'),
    ('2023Q4', 'C:\Users\user\Desktop\FDA\years\2023q4\ASCII\'),
    ('2024Q1', 'C:\Users\user\Desktop\FDA\years\2024q1\ASCII\'),
    ('2024Q2', 'C:\Users\user\Desktop\FDA\years\2024q2\ASCII\'),
    ('2024Q3', 'C:\Users\user\Desktop\FDA\years\2024q3\ASCII\'),
    ('2024Q4', 'C:\Users\user\Desktop\FDA\years\2024q4\ASCII\'),
    ('2025Q1', 'C:\Users\user\Desktop\FDA\Q1\ASCII\'),
    ('2025Q2', 'C:\Users\user\Desktop\FDA\Q2\ASCII\'),
    ('2025Q3', 'C:\Users\user\Desktop\FDA\Q3\ASCII\'),
    ('2025Q4', 'C:\Users\user\Desktop\FDA\Q4\ASCII\');

DECLARE @qtr VARCHAR(6), @folder VARCHAR(500), @sql NVARCHAR(MAX);

WHILE EXISTS (SELECT 1 FROM @quarters)
BEGIN
    SELECT TOP 1 @qtr = qtr, @folder = folder FROM @quarters;

    -- DEMO
    SET @sql = 'BULK INSERT DEMO_load FROM ''' + @folder + 'DEMO' + SUBSTRING(@qtr,3,2) + RIGHT(@qtr,2) + '.txt''
    WITH (FIRSTROW = 2, FIELDTERMINATOR = ''$'', ROWTERMINATOR = ''0x0a'', CODEPAGE = ''ACP'', MAXERRORS = 5000, TABLOCK);';
    EXEC(@sql);
    UPDATE DEMO_load SET occr_country = REPLACE(occr_country, CHAR(13), '') WHERE occr_country LIKE '%' + CHAR(13) + '%';
    INSERT INTO DEMO_raw SELECT *, @qtr FROM DEMO_load;
    TRUNCATE TABLE DEMO_load;

    -- DRUG (line endings vary by quarter; read as LF and strip any CR below)
    SET @sql = 'BULK INSERT DRUG_load FROM ''' + @folder + 'DRUG' + SUBSTRING(@qtr,3,2) + RIGHT(@qtr,2) + '.txt''
    WITH (FIRSTROW = 2, FIELDTERMINATOR = ''$'', ROWTERMINATOR = ''0x0a'', CODEPAGE = ''ACP'', MAXERRORS = 5000, TABLOCK);';
    EXEC(@sql);
    UPDATE DRUG_load SET dose_freq = REPLACE(dose_freq, CHAR(13), '') WHERE dose_freq LIKE '%' + CHAR(13) + '%';
    INSERT INTO DRUG_raw SELECT *, @qtr FROM DRUG_load;
    TRUNCATE TABLE DRUG_load;

    -- REAC
    SET @sql = 'BULK INSERT REAC_load FROM ''' + @folder + 'REAC' + SUBSTRING(@qtr,3,2) + RIGHT(@qtr,2) + '.txt''
    WITH (FIRSTROW = 2, FIELDTERMINATOR = ''$'', ROWTERMINATOR = ''0x0a'', CODEPAGE = ''ACP'', MAXERRORS = 5000, TABLOCK);';
    EXEC(@sql);
    UPDATE REAC_load SET drug_rec_act = REPLACE(drug_rec_act, CHAR(13), '') WHERE drug_rec_act LIKE '%' + CHAR(13) + '%';
    INSERT INTO REAC_raw SELECT *, @qtr FROM REAC_load;
    TRUNCATE TABLE REAC_load;

    -- OUTC
    SET @sql = 'BULK INSERT OUTC_load FROM ''' + @folder + 'OUTC' + SUBSTRING(@qtr,3,2) + RIGHT(@qtr,2) + '.txt''
    WITH (FIRSTROW = 2, FIELDTERMINATOR = ''$'', ROWTERMINATOR = ''0x0a'', CODEPAGE = ''ACP'', MAXERRORS = 5000, TABLOCK);';
    EXEC(@sql);
    UPDATE OUTC_load SET outc_cod = REPLACE(outc_cod, CHAR(13), '') WHERE outc_cod LIKE '%' + CHAR(13) + '%';
    INSERT INTO OUTC_raw SELECT *, @qtr FROM OUTC_load;
    TRUNCATE TABLE OUTC_load;

    -- THER
    SET @sql = 'BULK INSERT THER_load FROM ''' + @folder + 'THER' + SUBSTRING(@qtr,3,2) + RIGHT(@qtr,2) + '.txt''
    WITH (FIRSTROW = 2, FIELDTERMINATOR = ''$'', ROWTERMINATOR = ''0x0a'', CODEPAGE = ''ACP'', MAXERRORS = 5000, TABLOCK);';
    EXEC(@sql);
    UPDATE THER_load SET dur_cod = REPLACE(dur_cod, CHAR(13), '') WHERE dur_cod LIKE '%' + CHAR(13) + '%';
    INSERT INTO THER_raw SELECT *, @qtr FROM THER_load;
    TRUNCATE TABLE THER_load;

    -- INDI
    SET @sql = 'BULK INSERT INDI_load FROM ''' + @folder + 'INDI' + SUBSTRING(@qtr,3,2) + RIGHT(@qtr,2) + '.txt''
    WITH (FIRSTROW = 2, FIELDTERMINATOR = ''$'', ROWTERMINATOR = ''0x0a'', CODEPAGE = ''ACP'', MAXERRORS = 5000, TABLOCK);';
    EXEC(@sql);
    UPDATE INDI_load SET indi_pt = REPLACE(indi_pt, CHAR(13), '') WHERE indi_pt LIKE '%' + CHAR(13) + '%';
    INSERT INTO INDI_raw SELECT *, @qtr FROM INDI_load;
    TRUNCATE TABLE INDI_load;

    -- RPSR
    SET @sql = 'BULK INSERT RPSR_load FROM ''' + @folder + 'RPSR' + SUBSTRING(@qtr,3,2) + RIGHT(@qtr,2) + '.txt''
    WITH (FIRSTROW = 2, FIELDTERMINATOR = ''$'', ROWTERMINATOR = ''0x0a'', CODEPAGE = ''ACP'', MAXERRORS = 5000, TABLOCK);';
    EXEC(@sql);
    UPDATE RPSR_load SET rpsr_cod = REPLACE(rpsr_cod, CHAR(13), '') WHERE rpsr_cod LIKE '%' + CHAR(13) + '%';
    INSERT INTO RPSR_raw SELECT *, @qtr FROM RPSR_load;
    TRUNCATE TABLE RPSR_load;

    PRINT 'Loaded ' + @qtr;

    DELETE FROM @quarters WHERE qtr = @qtr;   -- remove this quarter, loop moves to the next
END
GO

-- Sanity check after loading: rows per quarter (each quarter should be ~250-400k DEMO rows)
-- SELECT quarter, COUNT(*) FROM DEMO_raw GROUP BY quarter ORDER BY quarter;
