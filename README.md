# Prize-Premium
Publicly available codes for the paper 'The Prize Premium in Publishing Timelines' for the Journal of Informetrics

# Data Curation Pipeline: Scientific Awards and Collaboration Impact Analysis

This document outlines the end-to-end data curation workflow developed to construct the analytical dataset for the project. The process integrates data from **OpenAlex**, **PubMed**, **Nature Index**, and **Journal Citation Reports (JCR)** to analyze the publication trajectories of award-winning scientists and their co-authors.

The workflow is divided into discrete steps implemented via Jupyter Notebooks, ensuring modularity, reproducibility, and rigorous data validation.

---

## Workflow Overview

The curation process follows a sequential pipeline:
1.  **Data Extraction**: Identifying award winners and retrieving raw publication/co-authorship records.
2.  **Bibliometric Matching**: Matching publication records with PubMed timing data (submission-to-acceptance lags).
3.  **Feature Enrichment**: Augmenting records with team size, field of study, journal impact factors, and citation metrics.
4.  **Panel Construction**: Merging winner and co-author datasets into a unified panel structure.
5.  **Final Cleaning**: Filtering for specific time windows (before/after award) and ensuring data consistency.

---

## Step-by-Step Description

### 0. Initial Data Extraction
**Notebook:** `Get winners_coauthor_info csv and winners_first_awards_info_1128_v2 csv.ipynb`

**Function:** This step identifies the cohort of award-winning scientists ("winners") and their collaboration networks. It processes raw prize data to determine the "First Award" year for each winner, which serves as the temporal anchor for the difference-in-differences analysis. It also generates the base network of co-authors.

* **Input Files:**
    * `Prize Data/item_raw.csv` (Raw entity data)
    * `Prize Data/item_reward_with_Year.csv` (Awards with timestamps)
    * `Prize Data/prize_net_cut-10-10-0.3.json` (Network data structure)
* **Output Files:**
    * `winners_first_awards_info_v2.csv`: Unique list of winners with their first major award year.
    * `winners_coauthor_info.csv`: Relational data linking winners to their co-authors.

---

### 1. PubMed Timing Data Preparation
**Notebook:** `Data Curation Step 1.ipynb`

**Function:** This step processes the raw PubMed timing history dataset. It filters the massive raw pickle file to retain only essential publication metadata—specifically the **Submission-to-Acceptance** time interval (`DeltaDays`), which is a primary variable of interest.

* **Input Files:**
    * `pubmed_timinghistory_2024.pkl` (Raw PubMed timing data)
* **Output Files:**
    * `pubmed_timinghistory_filtered.csv`: A lightweight dataset containing only `DOI`, `PubmedID`, `JournalISSN`, `PubYear`, and `DeltaDays`.

---

### 2. Winner Publication Matching
**Notebook:** `Data Curation Step 1.5.ipynb`

**Function:** This step links the work IDs of award winners to the filtered PubMed timing data. It resolves identifiers (DOI/PMID) to attach review times (`DeltaDays`) to the winners' publication records.

* **Input Files:**
    * `winner_author_workid_doi_pubmedid.csv`: A mapping of winners to their OpenAlex Work IDs and DOIs.
    * `pubmed_timinghistory_filtered.csv` (From Step 1)
* **Output Files:**
    * `winner_filtered_with_pubmed_info_120801.csv`: Winners' publications enriched with review time metrics.

---

### 3. Co-author Publication Matching
**Notebook:** `Data Curation Step 2 Helper.ipynb`

**Function:** Parallel to Step 2, this notebook performs the bulk matching for the co-author cohort. It links co-authors' works to the PubMed timing database using DOIs and PubMed IDs, creating a comprehensive repository of review times for the control group.

* **Input Files:**
    * `coauthor_work_pos_doi_pmid.csv`: Raw list of co-author publications.
    * `pubmed_timinghistory_filtered_lowercase.csv`: Pre-processed PubMed data for case-insensitive matching.
* **Output Files:**
    * `coauthor_work_pos_doi_pmid_with_pubinfo.csv`: Co-authors' publications enriched with review time metrics.

---

### 4. Metadata Enrichment (Team Size & Fields)
**Notebook:** `Data Curation Step 2.ipynb`

**Function:** This step enriches the winner dataset with high-level metadata from the OpenAlex database. Specifically, it queries and merges **Field of Study** (e.g., Biology, Physics) and **Team Size** (number of authors per paper) for every publication.

* **Input Files:**
    * `filtered_winner_data.csv` (Cleaned version of Step 1.5 output)
    * Database Connection (OpenAlex SQL)
* **Output Files:**
    * `filtered_winner_data_with_field.csv`: Intermediate file with fields.
    * `filtered_winner_data_with_teamsize_cleaned.csv`: Final file with both field and team size, duplicates removed.

---

### 5. Panel Construction & Group Assignment
**Notebook:** `Data Curation Step 3.ipynb`

**Function:** This is a critical integration step. It merges the enriched winner dataset and the co-author dataset into a single panel. It assigns `group_id`s to winner-coauthor pairs and generates the `if_winner` binary flag.

* **Input Files:**
    * `filtered_winner_data_with_teamsize_cleaned_top5_awardyear.csv` (Winners)
    * `coauthor_work_pos_doi_pmid_with_pubinfo_teamsize.csv` (Co-authors)
    * `winners_coauthor_info.csv`
* **Output Files:**
    * `final_group_pos_doipmid_puby_deltadays_field_tsize_top5_before_after.csv`: The combined panel dataset.

---

### 6. Reference Count Integration
**Notebook:** `Data Curation Step 4.ipynb`

**Function:** This step calculates and integrates the number of references (`ref_num`) for each paper in the combined panel. This serves as a control variable for paper complexity or depth.

* **Input Files:**
    * `final_group_pos_doipmid_puby_deltadays_field_tsize_top5_before_after.csv`
* **Output Files:**
    * `final_group_pos_doipmid_puby_deltadays_field_tsize_top5_before_after.csv` (Overwrites input with added `ref_num` column).

---

### 7. Bibliometric Enrichment (Nature Index & Academic Age)
**Notebook:** `Data Curation Step 3.5.ipynb`

**Function:** This step enriches the panel with prestige metrics and career age. It flags journals included in the **Nature Index** (`is_nature_index`) and queries the database for the author's first publication year to calculate `academic_experience` (Current Year - First Pub Year). It also cleans the data by removing co-author records that erroneously contain winner attribution (`winner_count == 0`).

* **Input Files:**
    * `final_group_pos_doipmid_puby_deltadays_field_tsize_top5_before_after.csv` (Output of Step 4)
    * `JCR_2024_source_NatureIndex-20240808.csv` (Journal metadata)
* **Output Files:**
    * `final_group_pos_doipmid_puby_deltadays_field_tsize_top5_before_after_coauthor_wc0_natindex_fpy_aca_exp.csv`

---

### 8. Impact Factor Integration & Temporal Filtering
**Notebook:** `Data Curation Step 4.5.ipynb`

**Function:** This step merges **Journal Impact Factors (JIF)** and 5-Year Impact Factors from the JCR dataset into the main panel. It performs critical filtering to retain only relevant records (e.g., standardizing `before_or_after` treatment indicators) and calculates the `year_diff` (Publication Year relative to Award Year).

* **Input Files:**
    * `final_group_pos_doipmid_puby_deltadays_field_tsize_top5_before_after_coauthor_wc0_natindex_fpy_aca_exp.csv`
* **Output Files:**
    * `final_group_pos_doipmid_puby_deltadays_field_tsize_top5_before0_after1_coauthor_wc0_natindex_fpy_aca_exp.csv` (Intermediate filtered)
    * `final_group_pos_doipmid_puby_deltadays_field_tsize_top5_before0_after1_coauthor_wc0_natindex_fpy_aca_exp_jif.csv` (Final JIF-enriched dataset)

---

### 9. Final Standardization (EISSN)
**Notebook:** `Data Curation Step 5.ipynb`

**Function:** The final curation step ensures journal identifiers are robust by adding **Electronic ISSNs (EISSN)** to the dataset, facilitating accurate matching across different bibliographic databases.

* **Input Files:**
    * `final_group_pos_doipmid_puby_deltadays_field_tsize_top5_before0_after1_coauthor_wc0_natindex_fpy_aca_exp_jif.csv`
* **Output Files:**
    * [Final Dataset Ready for Statistical Analysis]
