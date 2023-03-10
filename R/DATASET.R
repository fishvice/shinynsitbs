library(tidyverse)

# datadownload and tidy --------------------------------------------------------


fs::dir_create("data-raw")
library(icesDatras)
years <- 2000:2022
qs <- 3
surveys <- "NS-IBTS"

res <- list()
for(y in 1:length(years)) {
  print(years[y])
  res[[y]] <-
    getCPUELength(surveys, year = years[y], quarter = qs) |>
    as_tibble() |>
    rename_all(tolower) |>
    unite("id", survey, year, quarter, ship, gear, haulno, subarea, remove = FALSE) |>
    select(id, year, lon = shootlon, lat = shootlat, latin = species,
           length = lngtclas, n = cpue_number_per_hour) |>
    mutate(length = as.integer(floor(length / 10))) |>
    group_by(id, year, lon, lat, latin, length) |>
    summarise(n = sum(n),
              .groups = "drop")
}
# res |> write_rds("tmp.rds")
# res <- read_rds("tmp.rds")



# Split the data into station data and length measurement data -----------------
st <-
  res |>
  bind_rows() |>
  select(id, year, lon, lat) |>
  distinct() |>
  group_by(year) |>
  mutate(n.tows = n_distinct(id)) |>
  ungroup()

year.min <- min(st$year)
year.max <- max(st$year)

# Check if we get a unique id:
if(!st |> nrow() == st |> distinct(id, .keep_all = TRUE) |> nrow()) {
  warning("This is unexpected, check the code")
}
st |>
  group_by(id) |>
  mutate(n.id = n()) |>
  filter(n.id > 1) |>
  glimpse()
# This should really be reported to somebody
# remedy for now: drop one of the dual
st <-
  st |>
  group_by(id) |>
  slice(1) |>
  ungroup()

le <-
  res |>
  bind_rows() |>
  select(id, year, lon, lat, latin, length, n) |>
  filter(length > 0) |>
  # get rid of species where cpue is always zero
  group_by(latin) |>
  mutate(n.sum = sum(n)) |>
  ungroup() |>
  filter(n.sum > 0) |>
  select(-n.sum)

# Species to process -----------------------------------------------------------
# Only species that are reported in at least 15 of the 23 years in question
species_table <-
  le |>
  filter(length > 0,
         n > 0) |>
  group_by(latin) |>
  summarise(n.year.pos = sum(n_distinct(year))) |>
  filter(n.year.pos >= 15) |>
  # only proper species, not genus
  filter(str_detect(latin, " ")) |>
  left_join(tidydatras::asfis) |>
  mutate(english_name = case_when(species == "PLA" ~ "Long rough dab",
                                  species == "MON" ~ "Monkfish",
                                  species == "WHB" ~ "Blue whiting",
                                  species == "PIL" ~ "Sardine",
                                  species == "LUM" ~ "Lumpfish",
                                  species == "BIB" ~ "Pouting",
                                  species == "POK" ~ "Saithe",
                                  species == "USK" ~ "Tusk",
                                  .default = english_name)) |>
  arrange(english_name)
# testing:
species_table |> count(english_name) |> filter(n > 1)
LATIN <- species_table$latin
names(LATIN) <- species_table$english_name

# (rbyl) results by year and length --------------------------------------------

## A. First the total caught in each length class each year --------------------
rbyl <-
  le |>
  filter(latin %in% LATIN) |>
  group_by(year, latin, length) |>
  # the new kid on the block, here summarise returns a warning
  reframe(N = sum(n),                      # total number    by length caught in the year (per 60 minute haul)
          B = sum(n * 0.00001 * length^3)) #       mass [kg]

## trim length of species, make as a "plus group" -------------------------------
length.trim <-
  rbyl |>
  group_by(latin, length) |>
  reframe(B = sum(B)) |>
  arrange(latin, length) |>
  group_by(latin) |>
  mutate(cB = cumsum(B),
         cB.trim = 0.999 * max(cB),
         length.trim = ifelse(length > 30 & cB > cB.trim, NA, length),
         length.trim = ifelse(!is.na(length.trim), length.trim, max(length.trim, na.rm = TRUE))) |>
  select(latin, length, length.trim) |>
  ungroup()
rbyl <-
  rbyl |>
  left_join(length.trim) |>
  mutate(length = length.trim) |>
  # fill in full cm lengths from min to max witin each species
  select(year, latin, length) |> # step not really needed, just added for clarity
  group_by(latin) |>
  expand(year = full_seq(c(year.min, year.max), 1),
         length = full_seq(length, 1)) |>
  # join back to get the N and B
  left_join(rbyl) |>
  mutate(N = replace_na(N, 0),
         B = replace_na(B, 0))

## B. Now the calculation of the mean per length per year ----------------------
rbyl <-
  rbyl |>
  left_join(st |> count(year, name = "n.tows")) |>
  mutate(n = N / n.tows,
         b = B / n.tows) |>
  select(-n.tows)

# average over the whole survey time period
# results by length, used in the length frequency plot -------------------------
rbl <-
  rbyl |>
  group_by(latin, length) |>
  reframe(N = mean(N),
          B = mean(B),
          n = mean(n),
          b = mean(b))

# Throw out variables that are not used downstream to speed up the shiny loading
rbyl <-
  rbyl |>
  select(latin, year, length, n, b)
rbl <-
  rbl |>
  select(latin, length, n, b)

# rbsy --------------------------------------------------------------------------
rbys <-
  le |>
  filter(latin %in% LATIN) |>
  group_by(id, year, lon, lat, latin) |>
  reframe(N = sum(n),
          B = sum(n * 0.00001 * length^3))
# add zero station
rbys <-
  rbys |>
  expand(nesting(id, year, lon, lat), latin) |>
  # get back N and B
  left_join(rbys) |>
  mutate(N = replace_na(N, 0),
         B = replace_na(B, 0))

my_boot = function(x, times = 100) {

  # Get column name from input object
  var = deparse(substitute(x))
  var = gsub("^\\.\\$","", var)

  # Bootstrap 95% CI
  cis = stats::quantile(replicate(times, mean(sample(x, replace=TRUE))), probs=c(0.025,0.975))

  # Return data frame of results
  data.frame(var, n=length(x), mean=mean(x), lower.ci=cis[1], upper.ci=cis[2])
}

print("Bootstrapping abundance:")

boot.N <-
  rbys |>
  dplyr::group_by(latin, year) %>%
  dplyr::do(my_boot(.$N)) %>%
  dplyr::mutate(variable = "N",
                var = as.character(variable))

print("Bootstrapping biomass:")

boot.B <-
  rbys %>%
  dplyr::group_by(latin, year) %>%
  dplyr::do(my_boot(.$B)) %>%
  dplyr::mutate(variable = "B",
                var = as.character(var))

boot <-
  bind_rows(boot.N,
            boot.B)

# Throw out variables that are not used downstream to speed up the shiny loading
boot <-
  boot |>
  select(-n)

# gplyph plot ------------------------------------------------------------------
# need to create a dummy year before and after for the glyph-plot
glyph <-
  rbys |>
  mutate(sq = geo::d2ir(lat, lon)) |>
  group_by(year, sq, latin) |>
  summarise(N = mean(N),
            B = mean(B),
            .groups = "drop")
glyph <-
  expand_grid(year = (year.min - 1):(year.max + 1),
              sq = unique(glyph$sq),
              latin = unique(glyph$latin)) |>
  left_join(glyph) |>
  mutate(N = replace_na(N, 0),
         B = replace_na(B, 0)) |>
  mutate(lon = geo::ir2d(sq)$lon,
         lat = geo::ir2d(sq)$lat) |>
  group_by(year, latin) |>
  mutate(N = ifelse(N > quantile(N, 0.975), quantile(N, 0.975), N),
         B = ifelse(B > quantile(B, 0.975), quantile(B, 0.975), B)) |>
  ungroup()
# Throw out variables that are not used downstream to speed up the shiny loading
glyph <-
  glyph |>
  select(-sq)


# Probability plot -------------------------------------------------------------

prob <-
  rbys |>
  mutate(lon = gisland::grade(lon, 1),
         lat = gisland::grade(lat, 0.5)) |>
  group_by(latin, lon, lat) |>
  summarise(n = n(),
            n.pos = sum(N > 0),
            p = n.pos / n * 100,
            .groups = "drop") |>
  mutate(p = cut(p, breaks = c(0, 1, seq(10, 100, by = 10)),
                 include.lowest = FALSE)) |>
  filter(!is.na(p))



# Shoreline stuff for background on maps ---------------------------------------
library(rnaturalearth)
library(sf)
bb <- st_bbox(c(xmin = -40, ymin = 27, xmax = 40, ymax = 70),
              crs = 4326)
cl <-
  rnaturalearth::ne_countries(scale = 50, continent = "europe", returnclass = "sf") |>
  st_make_valid() |>
  st_crop(bb) |>
  st_coordinates() |>
  as_tibble() |>
  mutate(group = paste(L1, L2, L3)) |>
  select(lon = X, lat = Y, group)

list(rbyl = rbyl, rbl = rbl, rbys = rbys, boot = boot, glyph = glyph, prob = prob, species = LATIN, cl = cl) |>
  write_rds("data-raw/NS-IBTS_3.rds")

list(rbyl = rbyl, rbl = rbl, rbys = rbys, boot = boot,  glyph = glyph, prob = prob, species = LATIN, cl = cl) |>
  write_rds("/home/ftp/pub/data/rds/NS-IBTS_3.rds")
system("chmod a+rX /home/ftp/pub/data/rds/NS-IBTS_3.rds")

