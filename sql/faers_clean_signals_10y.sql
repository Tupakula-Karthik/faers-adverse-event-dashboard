/* ============================================================================
   FAERS 10-YEAR PIPELINE, PART 2: DEDUP, CLEAN, SIGNALS (2015 Q1 - 2025 Q4)
   Run AFTER faers_load_multi_year.sql has loaded all 44 quarters into FAERS_10Y.
   Adapted from the 2025 version (faers_pipeline.sql); only the database and quarter range differ.
   ============================================================================ */

USE FAERS_10Y;
GO

/* ============================================================================
   SECTION 3: DEDUPLICATION
   ============================================================================
   FAERS does not treat a case as fixed. If a case is corrected or updated
   (new info added, an error fixed), FDA does not overwrite the original --
   it adds a NEW row with the same caseid but a higher caseversion. Left
   unhandled, this means the same real-world case can be counted multiple
   times across your loaded quarters, inflating every downstream count and
   signal calculation.

   Fix: for every caseid, keep only the row with the highest caseversion.

   ROW_NUMBER() is used here rather than a simple GROUP BY MAX(caseversion)
   JOIN, because a small number of caseids had a genuine TIE on caseversion
   (two rows, same caseid, same caseversion -- likely a data quality quirk
   in the raw files). A plain MAX() join lets both tied rows through; 
   ROW_NUMBER() with a secondary ORDER BY primaryid DESC guarantees exactly
   one row survives even when the primary tiebreaker (caseversion) ties.
   ============================================================================ */

DROP TABLE IF EXISTS DEMO_clean;

WITH ranked AS (
    SELECT *,
           ROW_NUMBER() OVER (
               PARTITION BY caseid
               ORDER BY caseversion DESC, primaryid DESC
           ) AS rn
    FROM DEMO_raw
)
SELECT *
INTO DEMO_clean
FROM ranked
WHERE rn = 1;

ALTER TABLE DEMO_clean DROP COLUMN rn;

-- Filter every other table down to only the primaryids that survived dedup.
DROP TABLE IF EXISTS DRUG_clean;
SELECT r.* INTO DRUG_clean FROM DRUG_raw r WHERE r.primaryid IN (SELECT primaryid FROM DEMO_clean);

DROP TABLE IF EXISTS REAC_clean;
SELECT r.* INTO REAC_clean FROM REAC_raw r WHERE r.primaryid IN (SELECT primaryid FROM DEMO_clean);

DROP TABLE IF EXISTS OUTC_clean;
SELECT r.* INTO OUTC_clean FROM OUTC_raw r WHERE r.primaryid IN (SELECT primaryid FROM DEMO_clean);

DROP TABLE IF EXISTS THER_clean;
SELECT r.* INTO THER_clean FROM THER_raw r WHERE r.primaryid IN (SELECT primaryid FROM DEMO_clean);

DROP TABLE IF EXISTS INDI_clean;
SELECT r.* INTO INDI_clean FROM INDI_raw r WHERE r.primaryid IN (SELECT primaryid FROM DEMO_clean);

DROP TABLE IF EXISTS RPSR_clean;
SELECT r.* INTO RPSR_clean FROM RPSR_raw r WHERE r.primaryid IN (SELECT primaryid FROM DEMO_clean);

-- Verify: DEMO_clean's row count should equal COUNT(DISTINCT caseid) from DEMO_raw.
-- SELECT COUNT(*) AS total_rows, COUNT(DISTINCT caseid) AS unique_cases FROM DEMO_raw;
-- SELECT COUNT(*) FROM DEMO_clean;


/* ============================================================================
   SECTION 4: DATE FIELDS
   ============================================================================
   FAERS stores dates as plain 8-character text ('YYYYMMDD'), not as real
   SQL DATE values, so no time-intelligence functions (trends, filtering by
   month, etc.) work on them directly. This converts the three most useful
   date fields into real DATE columns.

   TRY_CONVERT (not CONVERT) is used deliberately: a blank or malformed
   fda_dt/event_dt/init_fda_dt becomes NULL rather than erroring out the
   whole statement, since FAERS data sometimes has incomplete date fields.

   NOTE: a GO must separate each ALTER TABLE from the UPDATE that references
   the new column. SQL Server compiles an entire batch before running any of
   it, so if the ALTER and the UPDATE are in the same batch, the UPDATE's
   compile step doesn't yet know the new column exists and errors with
   "Invalid column name". GO forces the ALTER to commit first.
   ============================================================================ */

ALTER TABLE DEMO_clean ADD fda_date DATE;
GO
UPDATE DEMO_clean SET fda_date = TRY_CONVERT(DATE, fda_dt, 112);   -- style 112 = YYYYMMDD

ALTER TABLE DEMO_clean ADD event_date DATE;
GO
UPDATE DEMO_clean SET event_date = TRY_CONVERT(DATE, event_dt, 112);

ALTER TABLE DEMO_clean ADD init_fda_date DATE;
GO
UPDATE DEMO_clean SET init_fda_date = TRY_CONVERT(DATE, init_fda_dt, 112);


/* ============================================================================
   SECTION 5: AGE CLEANUP
   ============================================================================
   FAERS stores age as a raw number PLUS a separate unit code (age_cod):
   most records are 'YR' (years), but a meaningful minority are recorded in
   decades, months, weeks, days, or hours. Reading the raw `age` column
   directly without checking age_cod mixes all these units together --
   e.g. an age of 720 could mean 720 years (impossible) or 720 days
   (a baby), depending on age_cod. This converts everything into a single
   consistent age_years value.

   A follow-up cap (age_years > 120 -> NULL) is needed because the raw data
   contains at least one genuine data-entry error (a recorded age of 962
   years) -- this isn't a unit-conversion issue, just bad source data, so
   it's nulled out rather than guessed at.

   age_group buckets age_years into readable ranges for the dashboard,
   with a dedicated 'Unknown' bucket for cases with no usable age data at
   all (a meaningfully large group -- around 40% of cases -- worth showing
   explicitly rather than silently dropping).
   ============================================================================ */

ALTER TABLE DEMO_clean ADD age_years DECIMAL(6,2);
GO
UPDATE DEMO_clean
SET age_years = CASE age_cod
    WHEN 'YR'  THEN age
    WHEN 'DEC' THEN age * 10
    WHEN 'MON' THEN age / 12.0
    WHEN 'WK'  THEN age / 52.0
    WHEN 'DY'  THEN age / 365.0
    WHEN 'HR'  THEN age / 8760.0
    ELSE NULL   -- covers missing age_cod and any unexpected codes
END;

-- Cap implausible ages (known data-entry errors in the raw extract).
UPDATE DEMO_clean
SET age_years = NULL
WHERE age_years > 120;

ALTER TABLE DEMO_clean ADD age_group VARCHAR(10);
GO
UPDATE DEMO_clean
SET age_group = CASE
    WHEN age_years IS NULL THEN 'Unknown'
    WHEN age_years < 18 THEN '0-17'
    WHEN age_years < 41 THEN '18-40'
    WHEN age_years < 66 THEN '41-65'
    ELSE '66+'
END;


/* ============================================================================
   SECTION 6: PRR / ROR SIGNAL CALCULATION
   ============================================================================
   For every drug-reaction pair, a 2x2 contingency table is built:

                        This reaction      All other reactions
   This drug                 a                      b
   All other drugs           c                      d

     PRR (Proportional Reporting Ratio) = (a/(a+b)) / (c/(c+d))
     ROR (Reporting Odds Ratio)         = (a*d) / (b*c)

   A HALDANE-ANSCOMBE CONTINUITY CORRECTION (+0.5 to every cell) is applied.
   This is standard, established practice in pharmacovigilance, not an ad
   hoc fix -- without it, any drug-reaction pair where a cell equals
   exactly zero causes a literal divide-by-zero error in SQL. Those zero
   cells actually represent the STRONGEST possible signals (e.g. every
   report of a reaction happens to involve one specific drug), so the
   correction is what keeps these important rows in the dataset instead of
   crashing the query or silently dropping them.

   Even after that correction, raw PRR/ROR still produces statistically
   meaningless, wildly inflated values (millions) in a few edge cases,
   for three DIFFERENT underlying reasons -- each needed its own targeted
   fix, applied as DELETEs after the initial calculation:

     1) (a + b) < 20  -- the DRUG itself has too few total reports for the
        ratio's denominator to be statistically stable (e.g. a drug with
        only 4 total reports, 3 of which mention one reaction, produces an
        enormous but meaningless PRR).

     2) (a + c_) < 20 -- the REACTION itself is too rare across the WHOLE
        dataset (not just for other drugs) for the ratio to be reliable.

     3) c_ < 5        -- specifically, the "reaction reported for OTHER
        drugs" cell is too close to zero, even when the drug's own totals
        and the reaction's combined totals both look fine. This is a
        narrower case than #1 or #2 and needed its own explicit filter --
        seen in practice with device-specific complication terms that are
        almost never used outside one product (e.g. an IUD-specific
        MedDRA term), where the drug has plenty of reports and the
        reaction isn't globally rare, but almost nobody else reports it.

   Each of these represents a different way the PRR/ROR ratio can become
   statistically unstable, and all three are checked, not just one --
   fixing only #1 (drug volume) still left #2 and #3 producing
   million-scale PRR values in testing.
   ============================================================================ */

DROP TABLE IF EXISTS SIGNAL_SCORES;

WITH drug_reaction_counts AS (
    SELECT dr.drugname, r.pt, COUNT(DISTINCT dr.caseid) AS a
    FROM DRUG_clean dr
    JOIN REAC_clean r ON dr.caseid = r.caseid
    WHERE dr.role_cod IN ('PS','SS')   -- suspect drugs only (primary/secondary), not concomitant
    GROUP BY dr.drugname, r.pt
),
drug_totals AS (
    SELECT drugname, COUNT(DISTINCT caseid) AS drug_total
    FROM DRUG_clean
    WHERE role_cod IN ('PS','SS')
    GROUP BY drugname
),
reaction_totals AS (
    SELECT pt, COUNT(DISTINCT caseid) AS reaction_total
    FROM REAC_clean
    GROUP BY pt
),
grand_total AS (
    SELECT COUNT(DISTINCT caseid) AS total_cases FROM DEMO_clean
),
combined AS (
    SELECT
        c.drugname,
        c.pt,
        c.a AS a,
        (dt.drug_total - c.a) AS b,
        (rt.reaction_total - c.a) AS c_,
        (gt.total_cases - dt.drug_total - rt.reaction_total + c.a) AS d
    FROM drug_reaction_counts c
    JOIN drug_totals dt ON c.drugname = dt.drugname
    JOIN reaction_totals rt ON c.pt = rt.pt
    CROSS JOIN grand_total gt
    WHERE c.a >= 3   -- Evans criteria: minimum case count to consider a pair at all
)
SELECT
    drugname, pt, a, b, c_, d,
    -- PRR with Haldane-Anscombe continuity correction
    ((CAST(a AS FLOAT) + 0.5) / (a + b + 1.0)) /
    ((CAST(c_ AS FLOAT) + 0.5) / (c_ + d + 1.0)) AS PRR,
    -- ROR with the same correction
    ((CAST(a AS FLOAT) + 0.5) * (d + 0.5)) /
    ((CAST(b AS FLOAT) + 0.5) * (c_ + 0.5)) AS ROR
INTO SIGNAL_SCORES
FROM combined;

-- Remove statistically unreliable pairs (see the three reasons explained above).
DELETE FROM SIGNAL_SCORES WHERE (a + b) < 20;
DELETE FROM SIGNAL_SCORES WHERE (a + c_) < 20;
DELETE FROM SIGNAL_SCORES WHERE c_ < 5;

-- SELECT COUNT(*) FROM SIGNAL_SCORES;  -- sanity check row count


/* ============================================================================
   SECTION 7: OUTCOME LABELS
   ============================================================================
   OUTC_clean stores outcomes as 2-3 letter FDA codes (DE, HO, LT, etc),
   which aren't self-explanatory to anyone unfamiliar with FAERS. This adds
   a plain-English label column for use in the dashboard.
   ============================================================================ */

ALTER TABLE OUTC_clean ADD outcome_label VARCHAR(50);
GO
UPDATE OUTC_clean
SET outcome_label = CASE outc_cod
    WHEN 'DE' THEN 'Death'
    WHEN 'HO' THEN 'Hospitalization'
    WHEN 'LT' THEN 'Life-Threatening'
    WHEN 'DS' THEN 'Disability'
    WHEN 'CA' THEN 'Congenital Anomaly'
    WHEN 'RI' THEN 'Required Intervention'
    WHEN 'OT' THEN 'Other Serious'
    ELSE 'Unknown'
END;


/* ============================================================================
   END OF PIPELINE
   ============================================================================
   Tables ready for Power BI (Import mode):
     - SIGNAL_SCORES   : one row per validated drug-reaction pair, with PRR/ROR
     - DEMO_clean      : one row per unique case, with clean dates/age/age_group
     - OUTC_clean       : one row per case-outcome, with outcome_label
     - REAC_clean       : one row per case-reaction (used for drill-down charts)

   Do NOT import the _raw or _load tables -- they are staging artifacts only.
   ============================================================================ */
