# This script includes utility functions used throughout analyses for this project.

# Print rounded number ----
rprint <- function(x, d = 2) sprintf( paste0("%.",d,"f"), round(x, d) )

# Delete leading zero ----
zerolead <- function(x, d = 3) ifelse( x < .001, "< .001", sub("0.", ".", rprint(x, 3), fixed = T) )

# Calculate and print mean and SD ----
msd <- function(x, d = 2) paste0( rprint( mean(x, na.rm = T), d ), " ± ", rprint( sd(x, na.rm = T), d ) )

# Get frequency and proportion of binary variables ----
freqprop <- function(x, d = 0) paste0( table(x)[2], " (", rprint( 100*prop.table( table(x) )[2], d = d ), "%)" )

# Extract t/z values and p values ----
statextract <- function(coeffs, y, stat = "t") coeffs %>%
  
  as.data.frame() %>%
  mutate(y = y, .before = 1) %>%
  rownames_to_column("coefficient") %>%
  
  mutate(
    out = paste0(
      stat," = ", rprint( get( paste0(stat," value") ), 2 ),
      ", p ",
      if_else(
        get( paste0("Pr(>|",stat,"|)") ) < .001,
        zerolead( get( paste0("Pr(>|",stat,"|)") ) ),
        paste0("= ", zerolead( get( paste0("Pr(>|",stat,"|)") ) ) )
      )
    )
  ) %>%
  select( -paste0(stat," value"), -paste0("Pr(>|",stat,"|)") ) %>%
  pivot_wider(
    names_from = coefficient,
    values_from = out
  ) %>%
  select(-`(Intercept)`)

# Fit regressions ----
fit_reg <- function(d, outcomes, X = "SUBJ * AHI.F + AGE + GENDER + SBTIV", w = F) {
  
  lapply(
    
    setNames(outcomes, outcomes),
    function(y) {
      
      if (w == T) lm(formula = as.formula( paste0(y," ~ ",X) ), data = d, weights = weights)
      else lm(formula = as.formula( paste0(y," ~ ",X) ), data = d, weights = NULL)
      
    }
  )
  
}

# Extract linear regressions model diagnostics ----
lm_dia <- function(fit) sapply(
  
  names(fit),
  function(y)
    data.frame(
      X = sub( paste0(y," ~ "), "", c( formula( fit[[y]] ) ) ),
      p_breusch_pagan = c( check_heteroscedasticity(fit[[y]]) ),
      n_cook = sum( check_outliers(fit[[y]]), na.rm = T ),
      p_shapiro_wilk = c( check_normality(fit[[y]]) )
    )
  
) %>%
  
  t() %>%
  as.data.frame() %>%
  mutate( across( everything(), ~ unlist(.x, use.names = F) ) ) %>%
  mutate( heteroscedasticity = ifelse( p_breusch_pagan < .05, "!", ""), .after = p_breusch_pagan ) %>%
  mutate( nonnormality = ifelse( p_shapiro_wilk < .05, "!", ""), .after = p_shapiro_wilk ) %>%
  rownames_to_column("y")


# Benjamini-Hochberg adjustment for 5% FDR ----
bh_adjust <- function(p) {
  
  # extract threshold
  bh_thres <- data.frame(
    p = sort(p), # sort p values from smallest to largest
    thres = .05 * ( 1:length(p) ) / length(p) # prepare BH thresholds for each p value
  ) %>%
    mutate( sig = if_else( p <= thres, T, F ) ) %>%
    filter( sig == T ) %>%
    select(thres) %>%
    max()
  
  # return stars based on this threshold
  return( if_else(p < bh_thres, "*", "") )
}


# Extract coefficients ----
# for interactions and with them associated p-values (frequentist) (equivalent to ANOVAs with type 3 sum of squares which are appropriate for interactions)
# or posterior summaries (Bayesian)
lm_coeff <- function(fit, term = "SUBJ1:AHI.F1", type = "frequentist") {
  
  if (type == "frequentist") {
    
    sapply(
      
      names(fit),
      function(y)
        
        summary(fit[[y]])$coefficients[term, ] %>%
        t() %>%
        as.data.frame() %>%
        rename("p value" = "Pr(>|t|)") %>%
        cbind( t( confint(fit[[y]])[term, ] ) ) %>%
        relocate(`2.5 %`, .before = `t value`) %>%
        relocate(`97.5 %`, .before = `t value`) %>%
        mutate( X = sub( paste0(y," ~ "), "", c( formula( fit[[y]] ) ) ), .before = 1)
      
    ) %>%
      
      t() %>%
      as.data.frame() %>%
      mutate(coefficient = term, .after = X) %>%
      mutate_if(is.list, unlist) %>%
      rownames_to_column("y") %>%
      mutate(
        `q value` = p.adjust(`p value`, method = "BH"),
        `s value` = -log(`p value`, base = 2),
        sig_PCER = if_else(`p value` < .05, "*", ""),
        sig_FDR = bh_adjust(`p value`),
        sig_FWER = if_else(`p value` < .05/nrow(.), "*", "")
      )
    
  } else if (type == "Bayesian") sapply(
    
    names(fit),
    function(y)
      
      fixef(fit[[y]])[term, ] %>%
      t() %>%
      as.data.frame() %>%
      mutate(
        X = sub( ".* ~ ", "", as.character( formula(fit[[y]]) )[1] ),
        sigma = if_else( grepl( "sigma", formula(fit[[y]])[2] ), sub( ")", "", sub( ".* ~ ", "", as.character( formula(fit[[y]]) )[2] ) ), "1" ),
        .before = 1            
      )
    
  ) %>%
    
    t() %>%
    as.data.frame() %>%
    mutate(coefficient = term, .after = sigma) %>%
    mutate_if(is.list, unlist) %>%
    rownames_to_column("y")
  
}


# Extract simple effects and esimates via emmeans ----
mass <- function(fit, type = "moderation") {
  
  lapply(
    
    names(fit),
    function(y) {
      
      if (type == "moderation") {
        
        full_join(
          
          emmeans(fit[[y]], specs = pairwise ~ AHI.F | SUBJ) %>%
            contrast(interaction = "consec") %>%
            as_tibble() %>%
            mutate( X = sub( paste0(y," ~ "), "", c( formula( fit[[y]] ) ) ), term = "AHI.F", .before = 1 ),
          
          emmeans(fit[[y]], specs = pairwise ~ AHI.F * SUBJ) %>%
            contrast(interaction = "consec") %>%
            as_tibble() %>%
            mutate( X = sub( paste0(y," ~ "), "", c( formula( fit[[y]] ) ) ), .before = 1 ) %>%
            rename("term" = "SUBJ_consec")
          
        ) %>%
          
          as.data.frame() %>%
          rename("contrast" = "AHI.F_consec") %>%
          mutate( contrast = if_else(term == "PD - CON", NA, contrast) ) %>% # for compatibility with previous versions of the script
          mutate(y = y, .before = 1)
        
      } else if (type == "full") {
        
        reduce(
          
          list(
            
            # 'main effects'
            emmeans(fit[[y]], specs = pairwise ~ SUBJ) %>% contrast("consec") %>% as_tibble() %>% mutate( X = sub( paste0(y," ~ "), "", c( formula( fit[[y]] ) ) ), term = "SUBJ", .before = 1 ),
            emmeans(fit[[y]], specs = pairwise ~ AHI.F) %>% contrast("consec") %>% as_tibble() %>% mutate( X = sub( paste0(y," ~ "), "", c( formula( fit[[y]] ) ) ), term = "AHI.F", .before = 1 ),
            
            # 'simple main effects'
            emmeans(fit[[y]], specs = pairwise ~ AHI.F | SUBJ) %>% contrast("consec") %>% as_tibble() %>% mutate( X = sub( paste0(y," ~ "), "", c( formula( fit[[y]] ) ) ), term = "AHI.F", .before = 1 ),
            emmeans(fit[[y]], specs = pairwise ~ SUBJ | AHI.F) %>% contrast("consec") %>% as_tibble() %>% mutate( X = sub( paste0(y," ~ "), "", c( formula( fit[[y]] ) ) ), term = "SUBJ", .before = 1 ),
            
            # interactions
            emmeans(fit[[y]], specs = pairwise ~ AHI.F * SUBJ) %>% contrast(interaction = "consec") %>% as_tibble() %>% mutate( X = sub( paste0(y," ~ "), "", c( formula( fit[[y]] ) ) ), .before = 1 ) %>% rename("term" = "SUBJ_consec"),
            emmeans(fit[[y]], specs = pairwise ~ SUBJ * AHI.F) %>% contrast(interaction = "consec") %>% as_tibble() %>% mutate( X = sub( paste0(y," ~ "), "", c( formula( fit[[y]] ) ) ), .before = 1 ) %>% rename("term" = "AHI.F_consec")
            
          ), full_join

        ) %>%
          
          mutate(y = y, .before = 1) %>%
          select( -ends_with("consec") )
        
      }
    }
    
  ) %>% do.call( rbind.data.frame, . )
  
}
