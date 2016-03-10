# layer -> trace conversion
layers2traces <- function(data, prestats_data, layers, layout, scales, labels) {
  # Attach a "geom class" to each layer of data for method dispatch 
  data <- Map(function(x, y) prefix_class(x, class(y$geom)[1]), data, layers)
  # Extract parameters for each layer
  params <- lapply(layers, function(x) {
    c(x$geom_params, x$stat_params, x$aes_params, position = ggtype(x, "position"))
  })
  # we draw legends only for discrete scales
  discreteScales <- list()
  for (sc in scales$non_position_scales()$scales) {
    if (sc$is_discrete()) {
      discreteScales[[sc$aesthetics]] <- sc
    }
  }
  # Convert "high-level" geoms to their "low-level" counterpart
  # This may involve preprocessing the data, for example:
  # 1. geom_line() is really geom_path() with data sorted by x
  # 2. geom_smooth() is really geom_path() + geom_ribbon()
  datz <- list()
  paramz <- list()
  for (i in seq_along(data)) {
    # This has to be done in a loop, since some layers are really two layers, 
    # (and we need to replicate the data/params in those cases)
    d <- to_basic(data[[i]], prestats_data[[i]], layout, params[[i]])
    if (is.data.frame(d)) d <- list(d)
    for (j in seq_along(d)) {
      datz <- c(datz, d[j])
      paramz <- c(paramz, params[j])
    }
  }
  
  # now to the actual layer -> trace conversion
  trace.list <- list()
  for (i in seq_along(datz)) {
    d <- datz[[i]]
    # always split on discrete scales, and other geom specific aesthetics that
    # can't translate to a single trace
    split_by <- c(split_on(d), names(discreteScales))
    # always split on PANEL and domain values (for trace ordering)
    split_by <- c("PANEL", paste0(split_by, "_plotlyDomain"))
    # split "this layers" data into a list of data frames
    idx <- names(d) %in% split_by
    # ensure the factor level orders (which determies traces order)
    # matches the order of the domain values
    lvls <- unique(d[idx])
    lvls <- lvls[do.call(order, lvls), , drop = FALSE]
    fac <- factor(
      apply(d[idx], 1, paste, collapse = "@%&"),
      levels = apply(lvls, 1, paste, collapse = "@%&")
    )
    dl <- split(d, fac, drop = TRUE)
    # list of traces for this layer
    trs <- Map(geom2trace, dl, paramz[i])
    # are we splitting by a discrete scale on this layer?
    # if so, set name/legendgroup/showlegend
    isDiscrete <- names(d) %in% paste0(names(discreteScales), "_plotlyDomain")
    if (length(trs) > 1 && sum(isDiscrete) >= 1) {
      nms <- names(trs)
      # ignore "non-discrete" scales that we've split on
      for (w in seq_len(sum(names(d) %in% c("PANEL", split_on(d))))) {
        nms <- sub("^[^@%&]@%&", "", nms)
      }
      nms <- strsplit(nms, "@%&")
      nms <- vapply(nms, function(x) {
        if (length(x) > 1) paste0("(", paste0(x, collapse = ","), ")") else x
      }, character(1))
      trs <- Map(function(x, y) {
        x$name <- y
        x$legendgroup <- y
        # depending on the geom (e.g. smooth) this may be FALSE already 
        x$showlegend <- x$showlegend %||% TRUE
        x
      }, trs, nms)
    } else {
      trs <- lapply(trs, function(x) { x$showlegend <- FALSE; x })
    }
    
    # each trace is with respect to which axis?
    for (j in seq_along(trs)) {
      panel <- unique(dl[[j]]$PANEL)
      trs[[j]]$xaxis <-  sub("axis", "", layout[panel, "xaxis"])
      trs[[j]]$yaxis <-  sub("axis", "", layout[panel, "yaxis"])
    }
    # also need to set `layout.legend.traceorder='reversed'`
    if (inherits(d, "GeomBar") && paramz[[i]]$position == "identity") {
      trs <- rev(trs)
    }
    trace.list <- c(trace.list, trs)
  }
  trace.list
}


#' Convert a geom to a "basic" geom.
#' 
#' This function makes it possible to convert ggplot2 geoms that
#' are not included with ggplot2 itself. Users shouldn't need to use 
#' this function. It exists purely to allow other package authors to write
#' their own conversion method(s).
#' 
#' @param data the data returned by \code{ggplot2::ggplot_build()}.
#' @param prestats_data the data before statistics are computed.
#' @param layout the panel layout.
#' @param params parameters for the geom, statistic, and 'constant' aesthetics
#' @param ... currently ignored
#' @export
to_basic <- function(data, prestats_data, layout, params, ...) {
  UseMethod("to_basic")
}

#' @export
to_basic.GeomViolin <- function(data, prestats_data, layout, params, ...) {
  n <- nrow(data)
  revData <- data[order(data$y, decreasing = TRUE), ]
  idx <- !names(data) %in% c("x", "xmin", "xmax")
  data <- rbind(
    cbind(x = data$x - data$violinwidth / 2, data[, idx]),
    cbind(x = revData$x + revData$violinwidth / 2, revData[, idx])
  )
  if (!is.null(data$hovertext)) data$hovertext <- paste0(data$hovertext, "<br>")
  data$hovertext <- paste0(data$hovertext, "density: ", round(data$density, 3))
  prefix_class(data, c("GeomPolygon", "GeomViolin"))
}

#' @export
to_basic.GeomBoxplot <- function(data, prestats_data, layout, params, ...) {
  aez <- names(GeomBoxplot$default_aes)
  for (i in aez) {
    prestats_data[[i]] <- NULL
  }
  vars <- c("PANEL", "group", aez, grep("_plotlyDomain$", names(data), value = T))
  prefix_class(
    merge(prestats_data, data[vars], by = c("PANEL", "group"), sort = FALSE), 
    "GeomBoxplot"
  )
}

#' @export
to_basic.GeomSmooth <- function(data, prestats_data, layout, params, ...) {
  dat <- prefix_class(data, "GeomPath")
  dat$alpha <- NULL
  if (!identical(params$se, FALSE)) {
    dat2 <- prefix_class(ribbon_dat(data), c("GeomPolygon", "GeomSmooth"))
    dat2$colour <- NULL
    dat <- list(dat, dat2)
  }
  dat
}

#' @export
to_basic.GeomRibbon <- function(data, prestats_data, layout, params, ...) {
  prefix_class(ribbon_dat(data), "GeomPolygon")
}

#' @export
to_basic.GeomArea <- function(data, prestats_data, layout, params, ...) {
  prefix_class(ribbon_dat(data), "GeomPolygon")
}

#' @export
to_basic.GeomDensity <- function(data, prestats_data, layout, params, ...) {
  prefix_class(ribbon_dat(data), "GeomPolygon")
}

#' @export
to_basic.GeomLine <- function(data, prestats_data, layout, params, ...) {
  data <- data[order(data$x), ]
  prefix_class(data, "GeomPath")
}

#' @export
to_basic.GeomStep <- function(data, prestats_data, layout, params, ...) {
  prefix_class(data, "GeomPath")
}

#' @export
to_basic.GeomSegment <- function(data, prestats_data, layout, params, ...) {
  # Every row is one segment, we convert to a line with several
  # groups which can be efficiently drawn by adding NA rows.
  data$group <- seq_len(nrow(data))
  others <- data[!names(data) %in% c("x", "y", "xend", "yend")]
  data <- with(data, {
    rbind(cbind(x, y, others),
          cbind(x = xend, y = yend, others))
  })
  prefix_class(data, "GeomPath")
}

#' @export
to_basic.GeomRect <- function(data, prestats_data, layout, params, ...) {
  data$group <- seq_len(nrow(data))
  others <- data[!names(data) %in% c("xmin", "ymin", "xmax", "ymax")]
  data <- with(data, {
    rbind(cbind(x = xmin, y = ymin, others),
          cbind(x = xmin, y = ymax, others),
          cbind(x = xmax, y = ymax, others),
          cbind(x = xmax, y = ymin, others))
  })
  prefix_class(data, "GeomPolygon")
}

#' @export
to_basic.GeomRaster <- function(data, prestats_data, layout, params, ...) {
  data <- prefix_class(data, "GeomTile")
  to_basic(data, prestats_data, layout, params)
}

#' @export
to_basic.GeomTile <- function(data, prestats_data, layout, params, ...) {
  # geom2trace.GeomTile is a heatmap, which requires continuous fill and 
  # a complete grid
  g <- expand.grid(unique(data$x), unique(data$y))
  if (nrow(g) != nrow(data) || is.discrete(prestats_data$fill)) {
    data <- prefix_class(data, "GeomRect")
    to_basic(data, prestats_data, layout, params)
  } else {
    data
  }
}

#' @export
to_basic.GeomContour <- function(data, prestats_data, layout, params, ...) {
  if (!"fill" %in% names(data)) data$fill <- NA
  prefix_class(data, "GeomPath")
}

#' @export
to_basic.GeomDensity2d <- function(data, prestats_data, layout, params, ...) {
  if (!"fill" %in% names(data)) data$fill <- NA
  prefix_class(data, "GeomPath")
}

#' @export
to_basic.GeomAbline <- function(data, prestats_data, layout, params, ...) {
  # ugh, we can't trust the group here
  data$group <- interaction(
    data[!grepl("group", names(data)) & !vapply(data, anyNA, logical(1))]
  )
  lay <- tidyr::gather_(layout, "variable", "x", c("x_min", "x_max"))
  data <- merge(lay[c("PANEL", "x")], data, by = "PANEL")
  data$y <- with(data, intercept + slope * x)
  prefix_class(data, "GeomPath")
}

#' @export
to_basic.GeomHline <- function(data, prestats_data, layout, params, ...) {
  # ugh, we can't trust the group here
  data$group <- interaction(
    data[!grepl("group", names(data)) & !vapply(data, anyNA, logical(1))]
  )
  lay <- tidyr::gather_(layout, "variable", "x", c("x_min", "x_max"))
  data <- merge(lay[c("PANEL", "x")], data, by = "PANEL")
  data$y <- data$yintercept
  prefix_class(data, "GeomPath")
}

#' @export
to_basic.GeomVline <- function(data, prestats_data, layout, params, ...) {
  # ugh, we can't trust the group here
  data$group <- interaction(
    data[!grepl("group", names(data)) & !vapply(data, anyNA, logical(1))]
  )
  lay <- tidyr::gather_(layout, "variable", "y", c("y_min", "y_max"))
  data <- merge(lay[c("PANEL", "y")], data, by = "PANEL")
  data$x <- data$xintercept
  prefix_class(data, "GeomPath")
}

#' @export
to_basic.GeomJitter <- function(data, prestats_data, layout, params, ...) {
  prefix_class(data, "GeomPoint")
}

#' @export
to_basic.GeomErrorbar <- function(data, prestats_data, layout, params, ...) {
  # width for ggplot2 means size of the entire bar, on the data scale 
  # (plotly.js wants half, in pixels)
  data <- merge(data, layout, by = "PANEL", sort = FALSE)
  data$width <- (data$xmax - data$x) /(data$x_max - data$x_min)
  data$fill <- NULL
  prefix_class(data, "GeomErrorbar")
}

#' @export
to_basic.GeomErrorbarh <- function(data, prestats_data, layout, params, ...) {
  # height for ggplot2 means size of the entire bar, on the data scale 
  # (plotly.js wants half, in pixels)
  data <- merge(data, layout, by = "PANEL", sort = FALSE)
  data$width <- (data$ymax - data$y) / (data$y_max - data$y_min)
  data$fill <- NULL
  prefix_class(data, "GeomErrorbarh")
}

#' @export
to_basic.GeomLinerange <- function(data, prestats_data, layout, params, ...) {
  data$width <- 0
  prefix_class(data, "GeomErrorbar")
}

#' @export
to_basic.GeomPointrange <- function(data, prestats_data, layout, params, ...) {
  data$width <- 0
  list(
    prefix_class(data, "GeomErrorbar"),
    prefix_class(data, "GeomPoint")
  )
}

#' @export
to_basic.default <- function(data, prestats_data, layout, params, ...) {
  data
}

#' Convert a "basic" geoms to a plotly.js trace.
#' 
#' This function makes it possible to convert ggplot2 geoms that
#' are not included with ggplot2 itself. Users shouldn't need to use 
#' this function. It exists purely to allow other package authors to write
#' their own conversion method(s).
#' 
#' @param data the data returned by \code{plotly::to_basic}.
#' @param params parameters for the geom, statistic, and 'constant' aesthetics
#' @export
geom2trace <- function(data, params) {
  UseMethod("geom2trace")
}

#' @export
geom2trace.GeomBlank <- function(data, params) {
  list()
}

#' @export
geom2trace.GeomPath <- function(data, params) {
  data <- group2NA(data)
  L <- list(
    x = data$x,
    y = data$y,
    text = data$hovertext,
    hoverinfo = "text",
    type = "scatter",
    mode = "lines",
    name = if (inherits(data, "GeomSmooth")) "fitted values",
    line = list(
      # TODO: line width array? -- https://github.com/plotly/plotly.js/issues/147
      width = aes2plotly(data, params, "size")[1],
      color = toRGB(
        aes2plotly(data, params, "colour"),
        aes2plotly(data, params, "alpha")
      ),
      dash = aes2plotly(data, params, "linetype")
    )
  )
  if (inherits(data, "GeomStep")) L$line$shape <- params$direction %||% "hv"
  L
}

#' @export
geom2trace.GeomPoint <- function(data, params) {
  shape <- aes2plotly(data, params, "shape")
  L <- list(
    x = data$x,
    y = data$y,
    text = data$hovertext,
    key = data$key,
    type = "scatter",
    mode = "markers",
    marker = list(
      autocolorscale = FALSE,
      color = aes2plotly(data, params, "fill"),
      opacity = aes2plotly(data, params, "alpha"),
      size = aes2plotly(data, params, "size"),
      symbol = shape,
      line = list(
        width = aes2plotly(data, params, "stroke"),
        color = aes2plotly(data, params, "colour")
      )
    )
  )
  # fill is irrelevant for pch %in% c(1, 15:20)
  pch <- uniq(data$shape) %||% params$shape %||% GeomPoint$default_aes$shape
  if (any(pch %in% c(1, 15:20))) {
    L$marker$color <- L$marker$line$color
  }
  L
}

#' @export
geom2trace.GeomBar <- function(data, params) {
  data$y <- data$ymax - data$ymin
  # TODO: use xmin/xmax once plotly.js allows explicit bar widths
  # https://github.com/plotly/plotly.js/issues/80
  list(
    x = data$x,
    y = data$y,
    text = data$hovertext,
    type = "bar",
    marker = list(
      autocolorscale = FALSE,
      color = toRGB(
        aes2plotly(data, params, "fill"),
        aes2plotly(data, params, "alpha")
      ),
      line = list(
        width = aes2plotly(data, params, "size"),
        color = aes2plotly(data, params, "colour")
      )
    )
  )
}

#' @export
geom2trace.GeomPolygon <- function(data, params) {
  data <- group2NA(data)
  L <- list(
    x = data$x,
    y = data$y,
    text = data$hovertext,
    type = "scatter",
    mode = "lines",
    line = list(
      # NOTE: line attributes must be constant on a polygon
      width = aes2plotly(data, params, "size"),
      color = aes2plotly(data, params, "colour"),
      dash = aes2plotly(data, params, "linetype")
    ),
    fill = "tozerox",
    fillcolor = toRGB(
      aes2plotly(data, params, "fill"),
      aes2plotly(data, params, "alpha")
    )
  )
  if (inherits(data, "GeomSmooth")) {
    L$name <- "standard error"
    L$showlegend <- FALSE
  }
  L
  
}

#' @export
geom2trace.GeomBoxplot <- function(data, params) {
  list(
    x = data$x,
    y = data$y,
    type = "box",
    hoverinfo = "y",
    fillcolor = toRGB(
      aes2plotly(data, params, "fill"),
      aes2plotly(data, params, "alpha")
    ),
    # marker styling must inherit from GeomPoint$default_aes
    # https://github.com/hadley/ggplot2/blob/ab42c2ca81458b0cf78e3ba47ed5db21f4d0fc30/NEWS#L73-L77
    marker = list(
      opacity = GeomPoint$default_aes$alpha,
      outliercolor = toRGB(GeomPoint$default_aes$colour),
      line = list(
        width = mm2pixels(GeomPoint$default_aes$stroke),
        color = toRGB(GeomPoint$default_aes$colour)
      ),
      size = mm2pixels(GeomPoint$default_aes$size)
    ),
    line = list(
      color = aes2plotly(data, params, "colour"),
      width = aes2plotly(data, params, "size")
    )
  )
}


#' @export
geom2trace.GeomText <- function(data, params) {
  list(
    x = data$x,
    y = data$y,
    text = data$label,
    textfont = list(
      # TODO: how to translate fontface/family?
      size = aes2plotly(data, params, "size"),
      color = toRGB(
        aes2plotly(data, params, "colour"),
        aes2plotly(data, params, "alpha")
      )
    ),
    type = "scatter",
    mode = "text"
  )
}

#' @export
geom2trace.GeomTile <- function(data, params) {
  # make sure order of value make sense before throwing z in matrix
  data <- data[order(data$x, order(data$y, decreasing = T)), ]
  x <- sort(unique(data$x))
  y <- sort(unique(data$y))
  fill <- data$fill_plotlyDomain
  colorscale <- cbind(
    c(0, 1),
    data[c(which.min(fill), which.max(fill)), "fill"]
  )
  list(
    x = x,
    y = y,
    z = matrix(
      scales::rescale(fill), 
      nrow = length(y), 
      ncol = length(x)
    ),
    text = matrix(
      data$hovertext, 
      nrow = length(y), 
      ncol = length(x)
    ),
    colorscale = colorscale,
    type = "heatmap",
    showscale = FALSE,
    autocolorscale = FALSE
  )
}

#' @export
geom2trace.GeomErrorbar <- function(data, params) {
  make_error(data, params, "y")
}

#' @export
geom2trace.GeomErrorbarh <- function(data, params) {
  make_error(data, params, "x")
}

#' @export
geom2trace.default <- function(data, params) {
  warning(
    "geom_", class(data)[1], "() has yet to be implemented in plotly.\n",
    "  If you'd like to see this geom implemented,\n",
    "  Please open an issue with your example code at\n",
    "  https://github.com/ropensci/plotly/issues"
  )
  list()
}

# ---------------------------------------------------------------------------
# Utility functions
# --------------------------------------------------------------------------

# Drawing ggplot2 geoms with a group aesthetic is most efficient in
# plotly when we convert groups of things that look the same to
# vectors with NA.
group2NA <- function(data) {
  if (!"group" %in% names(data)) return(data)
  poly.list <- split(data, data$group, drop = TRUE)
  is.group <- names(data) == "group"
  poly.na.list <- list()
  forward.i <- seq_along(poly.list)
  ## When group2NA is called on geom_polygon (or geom_rect, which is
  ## treated as a basic polygon), we need to retrace the first points
  ## of each group, see https://github.com/ropensci/plotly/pull/178
  retrace.first.points <- inherits(data, "GeomPolygon")
  for (i in forward.i) {
    no.group <- poly.list[[i]][, !is.group, drop = FALSE]
    na.row <- no.group[1, ]
    na.row[, c("x", "y")] <- NA
    retrace.first <- if (retrace.first.points) {
      no.group[1,]
    }
    poly.na.list[[paste(i, "forward")]] <-
      rbind(no.group, retrace.first, na.row)
  }
  if (retrace.first.points) {
    backward.i <- rev(forward.i[-1])[-1]
    for (i in backward.i) {
      no.group <- poly.list[[i]][1, !is.group, drop = FALSE]
      na.row <- no.group[1, ]
      na.row[, c("x", "y")] <- NA
      poly.na.list[[paste(i, "backward")]] <- rbind(no.group, na.row)
    }
    if (length(poly.list) > 1) {
      first.group <- poly.list[[1]][1, !is.group, drop = FALSE]
      poly.na.list[["last"]] <- rbind(first.group, first.group)
    }
  }
  data <- do.call(rbind, poly.na.list)
  if (is.na(data$x[nrow(data)])) {
    data <- data[-nrow(data), ]
  }
  data
}

# given a geom, should we split on any continuous variables?
# this is necessary for some geoms, for example, polygons
# since plotly.js can't draw two polygons with different fill in a single trace
split_on <- function(dat) {
  geom <- class(dat)[1]
  lookup <- list(
    GeomPath = c("fill", "colour", "size"),
    GeomPolygon = c("fill", "colour", "size"),
    GeomBar = "fill",
    GeomBoxplot = c("colour", "fill", "size"),
    GeomErrorbar = "colour",
    GeomErrorbarh = "colour",
    GeomText = "colour"
  )
  splits <- lookup[[geom]]
  # make sure the variable is in the data, and is non-constant
  splits <- splits[splits %in% names(dat)]
  # is there more than one unique value for this aes split in the data?
  for (i in splits) {
    if (length(unique(dat[, i])) < 2) {
      splits <- setdiff(splits, i)
    }
  }
  splits
}

# make trace with errorbars 
make_error <- function(data, params, xy = "x") {
  color <- aes2plotly(data, params, "colour")
  e <- list(
    x = data$x,
    y = data$y,
    type = "scatter",
    mode = "lines",
    opacity = 0,
    hoverinfo = "none",
    line = list(color = color)
  )
  e[[paste0("error_", xy)]] <- list(
    array = data[[paste0(xy, "max")]] - data[[xy]],
    arrayminus = data[[xy]] - data[[paste0(xy, "min")]],
    type = "data",
    width = data$width[1] / 2,
    symmetric = FALSE,
    color = color
  )
  e
}

# function to transform geom_ribbon data into format plotly likes
# (note this function is also used for geom_smooth)
ribbon_dat <- function(dat) {
  n <- nrow(dat)
  o <- order(dat$x)
  o2 <- order(dat$x, decreasing = TRUE)
  used <- c("x", "ymin", "ymax")
  not_used <- setdiff(names(dat), used)
  # top-half of ribbon
  tmp <- dat[o, ]
  others <- tmp[not_used]
  dat1 <- cbind(x = tmp$x, y = tmp$ymax, others)
  dat1[n+1, ] <- cbind(x = tmp$x[n], y = tmp$ymin[n], others[n, ])
  # bottom-half of ribbon
  tmp2 <- dat[o2, ]
  others2 <- tmp2[not_used]
  dat2 <- cbind(x = tmp2$x, y = tmp2$ymin, others2)
  rbind(dat1, dat2)
}

aes2plotly <- function(data, params, aes = "size") {
  geom <- class(data)[1]
  vals <- uniq(data[[aes]]) %||% params[[aes]] %||%
    ggfun(geom)$default_aes[[aes]] %||% NA
  converter <- switch(
    aes, 
    size = mm2pixels, 
    stroke = mm2pixels, 
    colour = toRGB, 
    fill = toRGB, 
    linetype = lty2dash,
    shape = pch2symbol,
    alpha = function(x) { x[is.na(x)] <- 1; x },
    width = function(x) { x / 2},
    height = function(x) { x / 2}
  )
  if (is.null(converter)) {
    warning("A converter for ", aes, " wasn't found. \n", 
            "Please report this issue to: \n",
            "https://github.com/ropensci/plotly/issues/new", call. = FALSE)
    converter <- identity
  }
  converter(vals)
}

# Convert R pch point codes to plotly "symbol" codes.
pch2symbol <- function(x) {
  lookup <- list(
    "0" = "square-open",
    "1" = "circle-open",
    "2" = "triangle-up-open",
    "3" = "cross-thin-open",
    "4" = "x-thin-open",
    "5" = "diamond-open",
    "6" = "triangle-down-open",
    "7" = "square-x-open",
    "8" = "asterisk-open",
    "9" = "diamond-x-open",
    "10" = "circle-cross-open",
    "11" = "hexagram-open",
    "12" = "square-cross-open",
    "13" = "circle-x-open",
    "14" = "square-open-dot",
    "15" = "square",
    "16" = "circle",
    "17" = "triangle-up",
    "18" = "diamond",
    "19" = "circle",
    "20" = "circle",
    "21" = "circle",
    "22" = "square",
    "23" = "diamond",
    "24" = "triangle-up",
    "25" = "triangle-down",
    "32" = "circle",
    "35" = "hash-open",
    "42" = "asterisk-open",
    "43" = "cross-thin-open",
    "45" = "line-ew-open",
    "47" = "line-ne-open",
    "48" = "circle-open",
    "79" = "circle-open",
    "88" = "x-thin-open",
    "92" = "line-nw-open",
    "95" = "line-ew-open",
    "111" = "circle-open",
    "o" = "circle-open",
    "O" = "circle-open",
    "+" = "cross-thin-open"
  )
  as.character(lookup[as.character(x)])
}

# Convert R lty line type codes to plotly "dash" codes.
lty2dash <- function(x) {
  lookup <- list(
    "0" = "none",
    "1" = "solid",
    "2" = "dash",
    "3" = "dot",
    "4" = "dashdot",
    "5" = "longdash",
    "6" = "longdashdot",
    "blank" = "none",
    "solid" = "solid",
    "dashed" = "dash",
    "dotted" = "dot",
    "dotdash" = "dashdot",
    "longdash" = "longdash",
    "twodash" = "longdashdot",
    "22" = "dash",
    "42" = "dot",
    "44" = "dashdot",
    "13" = "longdash",
    "1343" = "longdashdot",
    "73" = "dash",
    "2262" = "dotdash",
    "12223242" = "dotdash",
    "F282" = "dash",
    "F4448444" = "dash",
    "224282F2" = "dash",
    "F1" = "dash"
  )
  as.character(lookup[as.character(x)])
}