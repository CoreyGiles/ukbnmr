#' Remove technical variation from NMR biomarker data in UK Biobank.
#'
#' @param x \code{data.frame} containing a dataset extracted by
#' \href{https://biobank.ctsu.ox.ac.uk/crystal/exinfo.cgi?src=accessing_data_guide}{ukbconv}
#' with \href{https://biobank.ndph.ox.ac.uk/showcase/label.cgi?id=220}{UK Biobank fields}
#' containing the \href{https://nightingalehealth.com/biomarkers}{Nightingale Health NMR metabolomics biomarker} data.
#' @param remove.outlier.plates logical, when set to \code{FALSE} biomarker
#' concentrations on outlier shipment plates (see details) are not set to
#' missing but simply flagged in the \code{biomarker_qc_flags} \code{data.frame}
#' in the returned \code{list}.
#'
#' @details
#' A multi-step procedure is applied to the raw biomarker data to remove the
#' effects of technical variation:
#' \enumerate{
#'   \item{First biomarker data is filtered to the 107 biomarkers that
#'   cannot be derived from any combination of other biomarkers.}
#'   \item{Absolute concentrations are log transformed, with a small offset
#'   applied to biomarkers with concentrations of 0.}
#'   \item{Each biomarker is adjusted for the time between sample preparation
#'   and sample measurement (hours).}
#'   \item{Each biomarker is adjusted for systematic differences between rows
#'   (A-H) on the 96-well shipment plates.}
#'   \item{Each biomarker is adjusted for remaining systematic differences
#'   between columns (1-12) on the 96-well shipment plates.}
#'   \item{Each biomarker is adjusted for drift over time within each of the six
#'   spectrometers. To do so, samples are grouped into 10 bins, within each
#'   spectrometer, by the date the majority of samples on their respective
#'   96-well plates were measured.}
#'   \item{Regression residuals after the sequential adjustments are
#'   transformed back to absolute concentrations.}
#'   \item{Samples belonging to shipment plates that are outliers of
#'   non-biological origin are identified and set to missing.}
#'   \item{The 61 composite biomarkers and 81 biomarker ratios are recomputed
#'   from their adjusted parts.}
#'   \item{An additional 76 biomarker ratios of potential biological
#'   significance are computed.}
#' }
#'
#' At each step, adjustment for technical covariates is performed using
#' \link[MASS:rlm]{robust linear regression}. Plate row, plate column, and
#' sample measurement date bin are treated as factors, using the group with the
#' largest sample size as reference in the regression.
#'
#' Further details can be found in the preprint: Ritchie S. C. \emph{et al.},
#' Quality control and removal of technical variation of NMR metabolic biomarker
#' data in ~120,000 UK Biobank participants, \strong{medRxiv} (2021). doi:
#' \href{https://www.medrxiv.org/content/early/2021/09/27/2021.09.24.21264079}{10.1101/2021.09.24.21264079}
#'
#' This function takes 10-15 minutes to run and requires at least 14 GB of RAM.
#'
#' @return a \code{list} containing three \code{data.frames}: \describe{
#'   \item{biomarkers}{A \code{data.frame} with column names "eid",
#'        and "visit_index", containing project-specific sample identifier and
#'        UK Biobank visit index (0 for baseline assessment, 1 for first repeat
#'        assessment), followed by columns for each biomarker containing their
#'        absolute concentrations (or ratios thereof) adjusted for technical
#'        variation. See \code{\link{nmr_info}} for information on each biomarker.}
#'   \item{biomarker_qc_flags}{A \code{data.frame} with the same format as
#'         \code{biomarkers} with entries corresponding to the
#'         \href{https://biobank.ndph.ox.ac.uk/showcase/label.cgi?id=221}{quality
#'         control indicators} for each sample. "High plate outlier" and "Low
#'         plate outlier" indicate the value was set to missing due to systematic
#'         abnormalities in the biomarker's concentration on the sample's shipment
#'         plate compared to all other shipment plates (see Details). For
#'         composite and derived biomarkers, quality control flags are aggregates
#'         of any quality control flags for the underlying biomarkers from which
#'         the composite biomarker or ratio is derived.}
#'   \item{sample_processing}{A \code{data.frame} containing the
#'         \href{https://biobank.ndph.ox.ac.uk/showcase/label.cgi?id=222}{processing
#'         information and quality control indicators} for each sample, including
#'         those derived for removal of unwanted technical variation by this
#'         function. See \code{\link{sample_qc_info}} for details.}
#'   \item{log_offset}{A \code{data.frame} containing diagnostic information on
#'         the offset applied so that biomarkers with concentrations of 0 could
#'         be log transformed, and any right shift applied to prevent negative
#'         concentrations after rescaling adjusted residuals back to absolute
#'         concentrations. Should contain only biomarkers with minimum
#'         concentrations of 0 (in the "Minimum" column). "Minimum.Non.Zero"
#'         gives the smallest non-zero concentration for the biomarker.
#'         "Log.Offset" the small offset added to all samples prior to
#'         log transformation: half the mininum non-zero concentration.
#'         "Right.Shift" gives the small offset added to prevent negative
#'         concentrations that arise after rescaling residuals to log
#'         concentrations: this should be at least one order of magnitude
#'         smaller than the smallest non-zero value (i.e. the offset added
#'         should amount to noise in numeric precision for all samples). See
#'         preprint for more details.}
#'   \item{outlier_plate_detection}{A \code{data.frame} containing diagnostic
#'         information and details of outlier plate detection. For each of the
#'         107 non-derived biomarkers, the median concentration on each of the
#'         1,352 plates was calculated, then plates were flagged as outliers if
#'         their median value deviated more than expected from the mean of plate
#'         medians. "Mean.Plate.Medians" gives the mean of the plate medians for
#'         each biomarker. "Lower.Limit" and "Upper.Limit" give the values below
#'         and above which plates are flagged as outliers based on their plate
#'         median. See preprint for more details.}
#' }
#'
#' @importFrom stats coef
#' @importFrom stats sd
#' @importFrom stats median
#' @importFrom stats qnorm
#' @importFrom stats ppoints
#' @importFrom MASS rlm
#' @export
remove_technical_variation <- function(x, remove.outlier.plates=TRUE) {
  # Silence CRAN NOTES about undefined global variables (columns in data.tables)
  Well.Position.Within.Plate <- Well.Row <- Well.Column <- Sample.Measured.Date.and.Time <-
    Sample.Prepared.Date.and.Time <- Sample.Measured.Date <- Sample.Measured.Time <-
    Sample.Prepared.Date <- Sample.Prepared.Time <- Prep.to.Measure.Duration <-
    Spectrometer.Date.Bin <- Spectrometer <- Type <- Biomarker <- eid <- visit_index <-
    Shipment.Plate <- value <- Log.Offset <- Minimum <- Minimum.Non.Zero <-
    log_value <- adj <- Right.Shift <- outlier <- Lower.Limit <- Upper.Limit <-
    Name <- UKB.Field.ID <- N <- Plate.Measured.Date <- i.Sample.Measured.Date <-
    NULL

  # Check relevant fields exist
  f1 <- detect_format(x, type="biomarkers")
  f2 <- detect_format(x, type="biomarker_qc_flags")
  f3 <- detect_format(x, type="sample_qc_flags")

  # Make sure its not a "processed" dataset returned by extract_biomarkers() and
  # related functions.
  if (f1 == "processed" || f2 == "processed" || f3 == "processed") {
    stop("'x' should be a 'data.frame' containg UK Biobank field ID columns, not one extracted by extract_biomarkers() or related functions'")
  }

  # Extract biomarkers, biomarker QC flags, and sample processing information
  bio <- process_data(x, type="biomarkers")
  bio_qc <- process_data(x, type="biomarker_qc_flags")
  sinfo <- process_data(x, type="sample_qc_flags")

  # Check required sample processing fields exist
  req <- c("Well.Position.Within.Plate", "Sample.Measured.Date.and.Time",
           "Sample.Prepared.Date.and.Time", "Spectrometer", "Shipment.Plate")
  miss_req <- setdiff(req, names(sinfo))
  if (length(miss_req) > 0) {
    err_txt <- ukbnmr::sample_qc_info[Name %in% miss_req]
    err_txt <- err_txt[, sprintf("%s (Field: %s)", Name, UKB.Field.ID)]
    err_txt <- paste(err_txt, collapse=", ")
    stop("Missing required sample processing fields: ", err_txt, ".")
  }

  # Split out row and column information from 96-well plate information
  sinfo[, Well.Row := gsub("[0-9]", "", Well.Position.Within.Plate)]
  sinfo[, Well.Column := as.integer(gsub("[A-Z]", "", Well.Position.Within.Plate))]

  # Split out date and time for sample measurement and sample prep
  sinfo[, Sample.Measured.Date := as.IDate(gsub(" .*$", "", Sample.Measured.Date.and.Time))]
  sinfo[, Sample.Measured.Time := as.ITime(gsub("^.* ", "", Sample.Measured.Date.and.Time))]
  sinfo[, Sample.Prepared.Date := as.IDate(gsub(" .*$", "", Sample.Prepared.Date.and.Time))]
  sinfo[, Sample.Prepared.Time := as.ITime(gsub("^.* ", "", Sample.Prepared.Date.and.Time))]

  # Compute hours between sample prep and sample measurement
  sinfo[, Prep.to.Measure.Duration := duration_hours(
    Sample.Prepared.Date, Sample.Prepared.Time,
    Sample.Measured.Date, Sample.Measured.Time
  )]

  # Get majority date of sample measurement per shipment plate
  plate_measure_dates <- sinfo[,.N,by=list(Shipment.Plate, Sample.Measured.Date)]
  plate_measure_dates <- plate_measure_dates[,.SD[which.max(N)],by=Shipment.Plate]
  sinfo[plate_measure_dates, on = list(Shipment.Plate), Plate.Measured.Date := i.Sample.Measured.Date]

  # Split sample measurement date into 10 equal size bins per spectrometer
  sinfo[, Spectrometer.Date.Bin := bin_dates(Plate.Measured.Date), by=Spectrometer]

  # Offset date bin by spectrometer number to reduce potential confusion by users
  # in output
  sinfo[, Spectrometer.Date.Bin := Spectrometer.Date.Bin + 10 * as.integer(gsub(".* ", "", Spectrometer)) - 1]

  # Melt to long, filtering to non-derived biomarkers and dropping missing values
  bio <- melt(bio, id.vars=c("eid", "visit_index"), variable.name="Biomarker", na.rm=TRUE,
    measure.vars=intersect(names(bio), ukbnmr::nmr_info[Type == "Non-derived", Biomarker]))

  # add in relevant sample processing information
  bio <- sinfo[, list(eid, visit_index, Prep.to.Measure.Duration, Well.Row,
    Well.Column, Spectrometer.Date.Bin, Spectrometer, Shipment.Plate)][
      bio, on = list(eid, visit_index), nomatch=0]

  # Determine offset for log transformation (required for variables with measurements == 0):
  # Acetate, Acetoacetate, Albumin, bOHbutyrate, Clinical_LDL_C, Gly, Ile, L_LDL_CE, L_LDL_FC, M_LDL_CE
  log_offset <- bio[!is.na(value), list(Minimum=min(value), Minimum.Non.Zero=min(value[value != 0])),by=Biomarker]
  log_offset[, Log.Offset := ifelse(Minimum == 0, Minimum.Non.Zero / 2, 0)]

  # Get log transformed raw value
  bio[log_offset, on = list(Biomarker), log_value := log(value + Log.Offset)]

  # Adjust for time between sample prep and sample measurement
  bio[, adj := MASS::rlm(log_value ~ Prep.to.Measure.Duration)$residuals, by=Biomarker]

  # Adjust for within plate structure across 96-well plate rows A-H
  bio[, adj := MASS::rlm(adj ~ factor_by_size(Well.Row))$residuals, by=Biomarker]

  # Adjust for within plate structure across 96-well plate columns 1-12
  bio[, adj := MASS::rlm(adj ~ factor_by_size(Well.Column))$residuals, by=Biomarker]

  # Adjust for drift over time within spectrometer
  bio[, adj := MASS::rlm(adj ~ factor_by_size(Spectrometer.Date.Bin))$residuals, by=list(Biomarker, Spectrometer)]

  # Rescale to absolute units. First, shift the residuals to have the same central
  # parameter estimate (e.g. mean, estimated via robust linear regression) as the
  # log concentrations
  bio[, adj := adj + as.vector(coef(MASS::rlm(log_value ~ 1)))[1], by=Biomarker]

  # Undo the log transform
  bio[, adj := exp(adj)]

  # Remove the log offset
  bio[log_offset, on = list(Biomarker), adj := adj - Log.Offset]

  # Some values that were 0 are now < 0, apply small right shift
  # for these biomarkers (shift is very small, i.e. the impact on
  # the distribution's median is essentially numeric error)
  shift <- bio[, list(Right.Shift=-pmin(0, min(adj))), by=Biomarker]
  log_offset <- log_offset[shift, on = list(Biomarker)]
  bio[log_offset, on = list(Biomarker), adj := adj + Right.Shift]

  # Identify and remove outlier plates.
  # Model plate medians as a normal distribution (across all 1,352 plates), then
  # we can flag outlier plates as those > 3.374446 standard deviations from the
  # mean where 3.374446 is derived from the range of the theoretical normal
  # distribution for 1,352 samples
  n_plates <- sinfo[, length(unique(Shipment.Plate))] # 1,352
  sdlim <- max(qnorm(ppoints(n_plates))) # 3.374446
  plate_medians <- bio[, list(value = median(adj)), by=list(Biomarker, Shipment.Plate)]

  outlier_lim <- plate_medians[, list(
    Lower.Limit = mean(value) - sd(value) * sdlim,
    Mean.Plate.Medians = mean(value),
    Upper.Limit = mean(value) + sd(value) * sdlim
  ), by=Biomarker]

  plate_medians[, outlier := "no"]
  plate_medians[outlier_lim, on = list(Biomarker, value < Lower.Limit), outlier := "low"]
  plate_medians[outlier_lim, on = list(Biomarker, value > Upper.Limit), outlier := "high"]

  # Add outlier plate tags to biomarker qc tags
  bio_qc <- melt(bio_qc, id.vars=c("eid", "visit_index"), variable.name="Biomarker", na.rm=TRUE,
              measure.vars=intersect(names(bio_qc), ukbnmr::nmr_info[Type == "Non-derived", Biomarker]))

  outlier_flags <- bio[plate_medians[outlier != "no"], on = list(Shipment.Plate, Biomarker),
    list(eid, visit_index, Biomarker, value=ifelse(outlier == "high", "High outlier plate", "Low outlier plate"))]

  bio_qc <- rbind(bio_qc, outlier_flags)
  bio_qc <- bio_qc[, list(value = paste(value, collapse="; ")), by=list(eid, visit_index, Biomarker)]

  # Remove outlier plates from biomarker data
  if (remove.outlier.plates) {
    bio <- bio[!plate_medians[outlier != "no"], on = list(Biomarker, Shipment.Plate)]
  }

  # Convert back to wide format
  bio <- dcast(bio, eid + visit_index ~ Biomarker, value.var="adj")
  bio_qc <- dcast(bio_qc, eid + visit_index ~ Biomarker, value.var="value")

  # Compute derived biomarkers and ratios
  bio <- nightingale_composite_biomarker_compute(bio)
  bio <- nightingale_ratio_compute(bio)
  bio <- extended_ratios_compute(bio)

  bio_qc <- nightingale_composite_biomarker_flags(bio_qc)
  bio_qc <- nightingale_ratio_flags(bio_qc)
  bio_qc <- extended_ratios_flags(bio_qc)

  # Add back in samples with no QC flags for any biomarkers
  bio_qc <- bio_qc[bio[, list(eid, visit_index)], on = list(eid, visit_index)]

  # Return list
  return(list(
    biomarkers=returnDT(bio),
    biomarker_qc_flags=returnDT(bio_qc),
    sample_processing=returnDT(sinfo),
    log_offset=returnDT(log_offset[Log.Offset != 0 | Right.Shift != 0]),
    outlier_plate_detection=returnDT(outlier_lim)
  ))
}
