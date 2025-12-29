# ==============================================================================
# 0. Setup and Packages
# ==============================================================================
# Install packages if missing
if(!require("did")) install.packages("did")
if(!require("data.table")) install.packages("data.table")
if(!require("ggplot2")) install.packages("ggplot2")
if(!require("dplyr")) install.packages("dplyr")
if(!require("zoo")) install.packages("zoo") # For Moving Average

library(did)
library(data.table)
library(ggplot2)
library(dplyr)
library(zoo)

# ==============================================================================
# 1. Data Loading and Cleaning
# ==============================================================================
load_and_clean_data <- function(filepath) {
  message(">>> Loading data: ", filepath)
  df <- fread(filepath)
  
  # 1. Handle Missing Values / Defaults
  df[is.na(is_nature_index), is_nature_index := 2]
  
  # 2. Create Numeric IDs
  # 'id_numeric' tracks individual authors
  # 'group_id_numeric' tracks winner-coauthor groups
  df[, id_numeric := as.numeric(as.factor(author_id))]
  df[, group_id_numeric := as.numeric(as.factor(group_id))]
  
  # 3. Create 'gname' (First Treatment Time)
  # CS-DID requirement: gname = 0 for never treated, Year for treated
  df[, awardYear := as.numeric(awardYear)]
  df[is.na(awardYear), awardYear := 0]
  
  df[, gname := 0]
  df[if_winner == 1 & awardYear > 0, gname := awardYear]
  
  # 4. Create Dummy Variables for Author Position (For Model 2)
  # CS-DID formulas work best with numeric/dummies rather than factors
  df[, is_first := ifelse(author_position == "first", 1, 0)]
  df[, is_last  := ifelse(author_position == "last", 1, 0)]
  # 'middle' is the reference category
  
  # 5. Ensure Covariates are Numeric
  cols_to_numeric <- c("teamsize", "JIF", "academic_experience", 
                       "ref_num", "PubYear", "is_top5")
  df[, (cols_to_numeric) := lapply(.SD, as.numeric), .SDcols = cols_to_numeric]
  
  # 6. Remove NA values
  # We must remove NAs for any variable used in ANY model to ensure consistency
  req_cols <- c("DeltaDays", "PubYear", "id_numeric", "gname", 
                "group_id_numeric", "teamsize", "JIF", 
                "academic_experience", "ref_num", "is_first", "is_last")
  
  nrow_before <- nrow(df)
  df <- na.omit(df, cols = req_cols)
  message(">>> Rows removed due to NA: ", nrow_before - nrow(df))
  
  # 7. FILTER SMALL COHORTS (Crucial for Singular Matrix Error)
  # We remove award cohorts with very few observations.
  cohort_sizes <- df[gname > 0, .(n_obs = .N), by = gname]
  small_cohorts <- cohort_sizes[n_obs < 100, gname] # Increased threshold to 100 for safety
  
  if(length(small_cohorts) > 0) {
    message(">>> Dropping small cohorts (N<100) to prevent Singular Matrix error: ", 
            paste(small_cohorts, collapse=", "))
    df <- df[!gname %in% small_cohorts]
  }
  
  message(">>> Final row count: ", nrow(df))
  return(df)
}

# ==============================================================================
# 2. Run CS-DID Estimator (Annual, No bins)
# ==============================================================================
run_cs_did <- function(data, formula_controls, cluster_variable) {
  
  message("\n>>> Running Callaway & Sant'Anna Estimator...")
  message(">>> Clustering SE by: ", cluster_variable)
  message(">>> Controls: ", paste(as.character(formula_controls)[2], collapse = " "))
  
  # Note: is_top5 is often time-invariant for a person/group. 
  # If it causes singularity, 'did' package usually drops it with a warning.
  
  tryCatch({
    out <- att_gt(
      yname = "DeltaDays",
      tname = "PubYear",
      idname = "id_numeric",
      gname = "gname",
      xformla = formula_controls,
      data = data,
      control_group = "notyettreated",
      
      # Cluster Variable (Model 1 vs Model 2 logic)
      clustervar = cluster_variable,
      
      # Settings for stability
      allow_unbalanced_panel = TRUE,
      est_method = "reg",
      base_period = "universal",
      bstrap = TRUE,
      biters = 2000, 
      print_details = FALSE,
      cband = TRUE
    )
    
    # Aggregate to Dynamic Event Study (Annual)
    message(">>> Aggregating to annual event study effects...")
    agg_res <- aggte(out, type = "dynamic", na.rm = TRUE)
    return(agg_res)
    
  }, error = function(e) {
    message("!!! Error in run_cs_did: ", e$message)
    return(NULL)
  })
}

# ==============================================================================
# 3. Export Results Table (Requirement #2)
# ==============================================================================
save_event_study_results <- function(agg_obj, filename) {
  if (is.null(agg_obj)) return()
  
  res_df <- data.frame(
    Event_Time = agg_obj$egt,
    Estimate = agg_obj$att.egt,
    Std_Error = agg_obj$se.egt,
    Crit_Val_95 = agg_obj$crit.val.egt
  )
  
  res_df$Lower_CI <- res_df$Estimate - res_df$Crit_Val_95 * res_df$Std_Error
  res_df$Upper_CI <- res_df$Estimate + res_df$Crit_Val_95 * res_df$Std_Error
  
  # Add significance flag
  res_df$Significant <- (res_df$Lower_CI > 0) | (res_df$Upper_CI < 0)
  
  write.csv(res_df, filename, row.names = FALSE)
  message(">>> Coefficients saved to: ", filename)
}

# ==============================================================================
# 4. Plotting Function (Strict Python Replication)
# ==============================================================================
plot_cs_custom <- function(agg_obj, title_text, model_desc, output_filename) {
  if (is.null(agg_obj)) {
    message("!!! Skipping plot generation (NULL object).")
    return()
  }
  
  # 1. Extract Data
  res_df <- data.frame(
    year_mid = agg_obj$egt,
    coef = agg_obj$att.egt,
    se = agg_obj$se.egt,
    crit_val = agg_obj$crit.val.egt
  )
  
  # 2. Extract Overall ATT BEFORE using it
  overall_att <- agg_obj$overall.att
  overall_se <- agg_obj$overall.se
  overall_crit_val <- agg_obj$overall.crit.val
  overall_lower_ci <- overall_att - overall_crit_val * overall_se
  overall_upper_ci <- overall_att + overall_crit_val * overall_se
  
  # Calculate CIs
  res_df$lower_ci <- res_df$coef - res_df$crit_val * res_df$se
  res_df$upper_ci <- res_df$coef + res_df$crit_val * res_df$se
  res_df$is_reference <- FALSE
  
  # 3. MANUALLY INSERT REFERENCE POINT (The Pinch)
  # t = -1, Coef = 0, CI = 0
  ref_row <- data.frame(
    year_mid = -1,
    coef = 0,
    se = 0,
    crit_val = 0,
    lower_ci = 0,
    upper_ci = 0,
    is_reference = TRUE
  )
  
  # Remove existing -1 if present (usually aggte drops it, but just in case)
  res_df <- res_df[res_df$year_mid != -1, ]
  plot_df <- rbind(res_df, ref_row)
  plot_df <- plot_df[order(plot_df$year_mid), ]
  
  # 4. FILTER RANGE (Remove wild outliers)
  # Keeping x-axis between -15 and +15 as per your Python preference
  plot_df <- plot_df %>% filter(year_mid >= -10 & year_mid <= 15)
  
  # 5. CALCULATE MOVING AVERAGE (MA3)
  # We use zoo::rollmean. 
  # Note: The reference point (0) will pull the MA line toward 0, which is desired.
  plot_df$ma <- rollmean(plot_df$coef, k = 3, fill = NA, align = "center")
  
  # 6. GENERATE PLOT (Strict Formatting)
  
  # Full text description for the box - NOW using the extracted overall_att
  full_desc <- paste0(model_desc, "\nReference period: -1", "\nOverall ATT: ", round(overall_att, 2))
  
  p <- ggplot(plot_df, aes(x = year_mid)) +
    
    # 95% Confidence Interval (Light Blue #B0E0E6)
    geom_ribbon(aes(ymin = lower_ci, ymax = upper_ci, fill = "95% CI"), 
                alpha = 0.3) +
    
    # 3-Period Moving Average (Red, Bold)
    geom_line(aes(y = ma, color = "3-Period Moving Average"), linewidth = 1.5) +
    
    # Point Estimates (Navy Blue, White Edge, Size 5ish to match s=120)
    geom_point(aes(y = coef, fill = "Point Estimates"), 
               shape = 21, size = 5, color = "navy", stroke = 1.2, show.legend = TRUE) +
    
    # Reference Point (Red Diamond)
    geom_point(data = subset(plot_df, is_reference == TRUE),
               aes(y = coef, shape = "Reference Point (CI=0)"),
               fill = "red", size = 5, color = "black", stroke = 1) +
    
    # Reference Lines
    geom_hline(yintercept = 0, linetype = "dashed", color = "gray50", linewidth = 0.8) +
    geom_vline(xintercept = -1, linetype = "dashed", color = "gray50", linewidth = 0.8) +
    
    # Manual Scales for Colors/Fills/Shapes to create a unified legend
    scale_fill_manual(name = "", 
                      values = c("95% CI" = "#B0E0E6", "Point Estimates" = "navy"),
                      guide = guide_legend(override.aes = list(linetype = c(0, 0), shape = c(NA, 21), alpha = c(0.3, 1)))) +
    
    scale_color_manual(name = "", 
                       values = c("3-Period Moving Average" = "#DC143C"),  # 深红色
                       guide = guide_legend(override.aes = list(linetype = 1, shape = NA))) +
    
    scale_shape_manual(name = "",
                       values = c("Reference Point (CI=0)" = 23), # Diamond shape
                       guide = guide_legend(override.aes = list(fill = "red"))) +
    
    # Labels
    labs(title = title_text,
         x = "Years Relative to Award",
         y = "Estimated Effect (Days)") +
    
    # Scales
    scale_x_continuous(breaks = seq(-15, 20, 2)) + # Tick every 2 years
    
    # THEME (Strict Replication of Python Parameters)
    theme_bw() +
    theme(
      # Fonts
      plot.title = element_text(size = 24, face = "bold"),
      axis.title = element_text(size = 20),
      axis.text.x = element_text(size = 18, angle = 45, hjust = 1),
      axis.text.y = element_text(size = 18),
      
      # Legend
      legend.position = c(0.98, 0.98), # Upper Right inside plot
      legend.justification = c("right", "top"),
      legend.text = element_text(size = 18),
      legend.title = element_blank(), # Remove legend title
      legend.background = element_rect(fill = "transparent"),
      legend.spacing.y = unit(0.2, "cm"),
      
      # Grid/Panel
      panel.grid.minor = element_blank(),
      panel.border = element_rect(colour = "black", fill = NA, linewidth = 1)
    ) +
    
    # Annotation Box
    annotate("label", x = Inf, y = -Inf, label = full_desc, 
             hjust = 1, vjust = -0.2, 
             size = 7, # Approx size 20 in pts
             color = "gray30", 
             fill = alpha("white", 0.6), 
             label.padding = unit(0.5, "lines"))
  
  # Save
  ggsave(output_filename, plot = p, width = 14, height = 10, dpi = 1000)
  message(">>> Plot saved to: ", output_filename)
}

# ==============================================================================
# 5. Main Execution
# ==============================================================================

# --- CONFIGURATION ---
# CHANGE THIS PATH TO YOUR FILE LOCATION
csv_path <- "final_group_pos_doipmid_puby_deltadays_field_tsize_top5_before0_after1_coauthor_wc0_natindex_fpy_aca_exp_jif_EISSN.csv"

# 1. Load Data
df <- load_and_clean_data(csv_path)

# 2. Define Covariate Formulas (As requested in Point 3)
# Note: 'is_top5' is included, but may be dropped by 'did' if time-invariant.
# Note: FE (Journal, Field, Group) are REMOVED.
# Note: 'Winner Status' and 'After Award' are structural to CS-DID (gname/tname).

# Model 1 Controls: Basic Paper Attributes
controls_m1 <- ~ is_top5


issn <- c('0028-0836', '1476-4687', '0036-8075', '1095-9203', 
          '0027-8424', '1091-6490','0028-0836', '1476-4687', 
          '0098-7484', '1538-3598', '0028-4793', '1533-4406', 
          '0959-8138', '1756-1833')

df_nspbiomed <- df[JournalISSN %in% issn]



if (nrow(df_nspbiomed) > 0) {
  
  # --- Model 1: Cluster by Author ID ---
  message("\n--- Running Callaway/Sant' Anna Corrected DID Model (Cluster: Author ID) ---")
  res_ni_m1 <- run_cs_did(df_nspbiomed, controls_m1, cluster_variable = "id_numeric")
  
  if(!is.null(res_ni_m1)) {
    save_event_study_results(res_ni_m1, "NSPBM_Model_Coefficients.csv")
    plot_cs_custom(res_ni_m1, 
                   "CS-DID (Nature, Science, PNAS, Lancet, JAMA, NEJM, and BMJ)",
                   "Cluster: Author ID | Controls: Top 5 Prizes",
                   "Figure3_NSPBM_Model_CS.png")
  }
  
  
} else {
  message("Skipping Nature Index: No data found.")
}


res_ni_m1


save.image("CS-DID.RData")

