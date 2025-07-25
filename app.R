library(shiny)
library(shinyjs)
library(DT)
library(zip)
library(ncdf4)
library(fields)    
library(viridisLite)
library(lubridate)
library(progress)

# Source the aggregator function
source("https://raw.githubusercontent.com/rarabzad/RDRS/refs/heads/main/scripts/rdrs_ncdf_aggregator.R")
options(shiny.maxRequestSize = 500 * 1024^2)  # 500 MB limit
ui <- fluidPage(
  useShinyjs(),
  tags$head(
    tags$style(HTML("
      .selectize-control.single .selectize-input {
        overflow: hidden !important;
        text-overflow: ellipsis;
        white-space: nowrap;
      }
      .selectize-dropdown {
        position: absolute !important;
        width: auto !important;
        min-width: 100% !important;
        max-width: 600px !important;
        z-index: 2000 !important;
      }
      .shiny-input-container { overflow: visible !important; }

      /* make our matrix-input scrollable inside sidebar */
      .matrix-wrapper {
        overflow-x: auto;
        padding-bottom: 5px;
      }
      table.matrix-input {
        width: auto;
        min-width: 100%;
        border-collapse: collapse;
      }
      table.matrix-input th, table.matrix-input td {
        padding: 4px 8px;
        border: 1px solid #ddd;
        white-space: nowrap;
      }
      table.matrix-input th {
        background: #f8f8f8;
        text-align: left;
      }
    ")),
    tags$script(HTML('
      $(function () {
        $("[data-toggle=\'popover\']").popover();
      });
    '))
  ),
  
  tags$div(
    style = "display: flex; align-items: center; gap: 15px; margin-bottom: 20px;",
    tags$img(src = "logo.png", width = "100px", style = "border-radius: 20px;"),
    tags$h2("NetCDF Temporal Aggregator", style = "margin: 0;"),
    tags$p(
  "This tool processes gridded climate data from two sources: (1) a ZIP archive of hourly RDRS v2.1 NetCDF files, or (2) a single CaSR v3.1 NetCDF file. After selecting variables, aggregation functions (sum, mean, min, max), output units, scaling factors, time shift, and aggregation period, it produces an aggregated NetCDF “RavenInput.nc,” a CSV index of the aggregation procedure, and a draft Raven “.rvt” file—packaged together in a downloadable ZIP.",
  style = "font-size: 1.2em; color: #555;"
)
  ),
  
  sidebarLayout(
    sidebarPanel(
            tags$p(
        "For more information and sample data ",
        tags$a(href = "https://github.com/rarabzad/NETCDF_TEMPORAL_AGGRIGATOR/tree/main",
               "click here", target = "_blank")
      ),
      # Add radio buttons to select data type
      radioButtons(
        inputId = "data_type",
        label = "Select Data Source:",
        choices = c("RDRS v2.1 (ZIP)" = "rdrs", "CaSR v3.1 (NetCDF)" = "casr"),
        selected = "rdrs",
        inline = TRUE
      ),
      
      # Dynamic file input will show depending on selection
      uiOutput("dynamic_file_input"),
      numericInput("n_vars",
                   label = tagList(
                     "Number of Variables to Aggregate",
                     tags$span(
                       icon("question-circle"),
                       style = "color: #007bff; cursor: pointer;",
                       `data-toggle` = "popover",
                       `data-trigger` = "hover",
                       `data-placement` = "right",
                       `data-content` = "Specify how many different variables you want to aggregate (can include repeats)."
                     )
                   ),
                   value = 1, min = 1
      ),
      
      tags$div(
        style = "margin-bottom: 5px;",
        tagList(
          tags$label("Variables to Aggregate"),
          tags$span(
            icon("question-circle"),
            style = "color: #007bff; cursor: pointer;",
            `data-toggle` = "popover",
            `data-trigger` = "hover",
            `data-placement` = "right",
            `data-content` = "Configure each variable to aggregate: select the variable, aggregation function, output unit, and a post-aggregation multiplication factor (i.e. use 1000 to convert 'm' to 'mm')."
          )
        )
      ),
      div(class = "matrix-wrapper", uiOutput("var_matrix")),
      
      numericInput("time_shift",
                   label = tagList(
                     "Time Shift (hours)",
                     tags$span(
                       icon("question-circle"),
                       style = "color: #007bff; cursor: pointer;",
                       `data-toggle` = "popover",
                       `data-trigger` = "hover",
                       `data-placement` = "right",
                       `data-content` = "Shift input data time series by this many hours (for timezone correction from UTC to local time)."
                     )
                   ),
                   value = 0
      ),
      
      numericInput("agg_length",
                   label = tagList(
                     "Aggregation Length (hours)",
                     tags$span(
                       icon("question-circle"),
                       style = "color: #007bff; cursor: pointer;",
                       `data-toggle` = "popover",
                       `data-trigger` = "hover",
                       `data-placement` = "right",
                       `data-content` = "Number of hours in each aggregation block (e.g.,6 for quarter a day, 24 for daily, 168 for weekly)."
                     )
                   ),
                   value = 24, min = 1
      ),
      
      checkboxInput("agg_gph",
                    label = tagList(
                      "Aggregate Geopotential",
                      tags$span(
                        icon("question-circle"),
                        style = "color: #007bff; cursor: pointer;",
                        `data-toggle` = "popover",
                        `data-trigger` = "hover",
                        `data-placement` = "right",
                        `data-content` = "If checked, aggregates the Geopotential Height variable across time and converts it to Geopotential elevation (MASL)."
                      )
                    ),
                    value = FALSE
      ),
      
      actionButton("run", "Run Aggregation", icon = icon("play")),
      br(), br(),
      downloadButton("download_results", "Download Results ZIP")
    ),
    
    mainPanel(
      verbatimTextOutput("log"),
      hr(),
      uiOutput("results_tabs")
    )
  )
)

server <- function(input, output, session) {
  log_txt        <- reactiveVal("")
  temp_dir       <- reactiveVal(NULL)
  result_dir     <- reactiveVal(NULL)
  result_zip     <- reactiveVal(NULL)
  available_vars <- reactiveVal(NULL)
  available_units<- reactiveVal(list())
  index_df       <- reactiveVal(NULL)
  busy           <- reactiveVal(FALSE)
  observe({
    input$data_type
    shinyjs::runjs("$(function(){ $('[data-toggle=\"popover\"]').popover(); });")
  })
  
  output$dynamic_file_input <- renderUI({
    # build the correct fileInput widget
    ui <- if (is.null(input$data_type) || input$data_type == "rdrs") {
      fileInput("nc_zip",
                label = tagList(
                  "Upload NetCDF ZIP Archive",
                  tags$span(
                    icon("question-circle", style="color: #007bff; cursor: pointer;"),
                    title = "",               # must have a title attr
                    `data-toggle`  = "popover",
                    `data-trigger` = "hover",
                    `data-placement`= "right",
                    `data-content`  = "Upload a ZIP archive containing RDRS NetCDF (.nc) files. Files must end with YYYYMMDD12.nc."
                  )
                ),
                accept = c(".zip")
      )
    } else {
      fileInput("nc_file",
                label = tagList(
                  "Upload Single CaSR NetCDF File",
                  tags$span(
                    icon("question-circle"),
                    title = "",               # must have a title attr
                    `data-toggle`  = "popover",
                    `data-trigger` = "hover",
                    `data-placement`= "right",
                    `data-content`  = "Upload a single NetCDF file for CaSR v3.1 data."
                  )
                ),
                accept = c(".nc")
      )
    }
    
    # wrap in tagList() and include a script snippet that re‐binds popovers
    tagList(
      ui,
      tags$script(HTML('
  $(function(){
    $("[data-toggle=\\"popover\\"]").popover();
  });
'))
    )
  })
  
  
  append_log <- function(msg) {
    isolate(log_txt(paste0(log_txt(), format(Sys.time(), "%Y-%m-%d %H:%M:%S"), " – ", msg, "\n")))
  }
  
  # 1) Unzip + discover
  observeEvent({
    input$nc_zip
    input$nc_file
    input$data_type
  }, {
    if (input$data_type == "rdrs") {
      req(input$nc_zip)
      append_log("Unzipping RDRS archive…")
      td <- tempfile("ncdir_"); dir.create(td)
      unzip(input$nc_zip$datapath, exdir = td)
      temp_dir(td)
      
      ncs <- list.files(td, "\\.nc$", full.names = TRUE, recursive = TRUE)
      if (!length(ncs)) {
        append_log("No NetCDF files found in ZIP.")
        return()
      }
      
      nc <- nc_open(ncs[[1]])
      all_vars <- names(nc$var)
      vars <- all_vars[!(grepl("lat", all_vars) | grepl("lon", all_vars) | grepl("rotated_pole", all_vars))]
      available_vars(vars)
      available_units(as.list(sapply(vars, function(v) {
        att <- ncatt_get(nc, v, "units")$value
        if (is.null(att)) "" else att
      }, USE.NAMES = TRUE)))
      
      if ("lon" %in% all_vars) {
        lon_vals <- ncvar_get(nc, "lon")
        if (!is.null(lon_vals)) {
          mean_lon <- mean(lon_vals, na.rm = TRUE)
          tz_offset <- round(mean_lon / 15)
          tz_offset <- ifelse(tz_offset < 0, -tz_offset, -tz_offset)
          updateNumericInput(session, "time_shift", value = tz_offset)
          append_log(sprintf("Set default time shift to UTC %+d based on mean longitude %.2f.", tz_offset, mean_lon))
        }
      }
      nc_close(nc)
      
      append_log(sprintf("Found %d files, %d variables.", length(ncs), length(vars)))
    }
    else if (input$data_type == "casr") {
      req(input$nc_file)
      append_log("Loading CaSR single NetCDF file…")
      td <- tempfile("ncdir_"); dir.create(td)
      file.copy(input$nc_file$datapath, file.path(td, basename(input$nc_file$name)))
      temp_dir(td)
      
      nc <- nc_open(input$nc_file$datapath)
      all_vars <- names(nc$var)
      vars <- all_vars[!(grepl("lat", all_vars) | grepl("lon", all_vars) | grepl("rotated_pole", all_vars))]
      available_vars(vars)
      available_units(as.list(sapply(vars, function(v) {
        att <- ncatt_get(nc, v, "units")$value
        if (is.null(att)) "" else att
      }, USE.NAMES = TRUE)))
      
      if ("lon" %in% all_vars) {
        lon_vals <- ncvar_get(nc, "lon")
        if (!is.null(lon_vals)) {
          mean_lon <- mean(lon_vals, na.rm = TRUE)
          tz_offset <- round(mean_lon / 15)
          tz_offset <- ifelse(tz_offset < 0, -tz_offset, -tz_offset)
          updateNumericInput(session, "time_shift", value = tz_offset)
          append_log(sprintf("Set default time shift to UTC %+d based on mean longitude %.2f.", tz_offset, mean_lon))
        }
      }
      nc_close(nc)
      
      append_log(sprintf("Loaded single NetCDF with %d variables.", length(vars)))
    }
  })
  
  # 2) Input matrix
  output$var_matrix <- renderUI({
    req(available_vars(), available_units())
    n <- input$n_vars; vars <- available_vars()
    
    # header row
    hdr <- tags$tr(
      tags$th(""), lapply(seq_len(n), function(i) tags$th(sprintf("Var #%d", i)))
    )
    # each input row
    var_row <- tags$tr(tags$th("Variable"), lapply(seq_len(n), function(i)
      tags$td(selectizeInput(sprintf("var_%d",i), NULL, choices=vars, selected=vars[1]))
    ))
    fun_row <- tags$tr(tags$th("Function"), lapply(seq_len(n), function(i)
      tags$td(selectInput(sprintf("fun_%d",i), NULL, c("sum","mean","min","max"), "mean"))
    ))
    unit_row <- tags$tr(tags$th("Unit"), lapply(seq_len(n), function(i)
      tags$td(textInput(sprintf("unit_%d",i), NULL, value=available_units()[[vars[1]]]))
    ))
    fac_row  <- tags$tr(tags$th("Factor"), lapply(seq_len(n), function(i)
      tags$td(numericInput(sprintf("factor_%d",i), NULL, value=1, min=0, step=0.01))
    ))
    
    tags$table(class="matrix-input",
               tags$thead(hdr),
               tags$tbody(var_row, fun_row, unit_row, fac_row))
  })
  
  # sync units
  observe({
    req(available_units())
    lapply(seq_len(input$n_vars), function(i) {
      observeEvent(input[[paste0("var_",i)]], {
        u <- available_units()[[ input[[paste0("var_",i)]] ]]
        updateTextInput(session, paste0("unit_",i), value = u)
      }, ignoreInit=TRUE)
    })
  })
  
  # 3) Run, zip, load index
  observeEvent(input$run, {
    req(temp_dir(), available_vars())
    
    outdir <- file.path(temp_dir(), "output")
    dir.create(outdir, recursive=TRUE, showWarnings=FALSE)
    
    n    <- input$n_vars
    vars <- vapply(seq_len(n), function(i) input[[sprintf("var_%d",i)]], "")
    fns  <- vapply(seq_len(n), function(i) input[[sprintf("fun_%d",i)]], "")
    us   <- vapply(seq_len(n), function(i) input[[sprintf("unit_%d",i)]], "")
    fs   <- vapply(seq_len(n), function(i) input[[sprintf("factor_%d",i)]], 1)
    
    withProgress(message = "Please wait, aggregation running…", {
      incProgress(0.1)
      if (input$data_type == "rdrs") {
        rdrs_ncdf_aggregator(
          ncdir             = temp_dir(),
          time_shift        = input$time_shift,
          aggregationLength = input$agg_length,
          var               = vars,
          var_units         = us,
          fun               = fns,
          aggregationFactor = fs,
          aggregate_gph     = input$agg_gph
        )
      } else if (input$data_type == "casr") {
        # Assuming you have casr_aggregator function sourced or defined
        casr_aggregator(
          ncfile            = file.path(temp_dir(), basename(input$nc_file$name)),
          time_shift        = input$time_shift,
          aggregationLength = input$agg_length,
          var               = vars,
          var_units         = us,
          fun               = fns,
          aggregationFactor = fs
        )
      }
      incProgress(0.8)
      
      idxf <- file.path(outdir,"aggregation_procedure.csv")
      if (file.exists(idxf)) index_df(read.csv(idxf))
      zipf <- file.path(temp_dir(),"output.zip")
      zip::zip(zipfile=zipf, files=list.files(outdir, full.names=TRUE, recursive=TRUE),
               mode="cherry-pick", root=outdir)
      result_zip(zipf); result_dir(outdir)
      incProgress(0.1)
    })
    
    append_log("Aggregation & zip complete.")
  })
  
  
  # 4) Average‐over‐time matrices
  avg_matrices <- reactive({
    req(result_dir())
    ncfile <- file.path(result_dir(), "RavenInput.nc")
    nc     <- nc_open(ncfile)
    vns    <- setdiff(names(nc$var), c("lon","lat"))
    mats   <- lapply(vns, function(vn) apply(ncvar_get(nc, vn), 1:2, mean, na.rm=TRUE))
    nc_close(nc)
    list(names=vns, mats=mats)
  })
  
  # render dynamic tabs
  output$results_tabs <- renderUI({
    am <- avg_matrices()
    req(am)
    
    # generate one tabPanel per variable
    plot_tabs <- lapply(seq_along(am$names), function(i) {
      tabPanel(am$names[i],
               plotOutput(paste0("plot_",i), height="500px")
      )
    })
    # the final “Index” tab
    plot_tabs[[length(plot_tabs)+1]] <- tabPanel("Index", DTOutput("index_table"))
    
    do.call(tabsetPanel, c(id="results_tabs", plot_tabs))
  })
  
  # hook up each plotOutput
  observe({
    am <- avg_matrices()
    req(am)
    for (i in seq_along(am$mats)) {
      local({
        ii <- i
        nm <- am$names[ii]
        output[[paste0("plot_",ii)]] <- renderPlot({
          # draw the field with a color‐key legend
          fields::image.plot(
            am$mats[[ii]],
            col        = magma(100),          # warm, high‑contrast
            main       = nm,
            legend.lab = "Mean value",
            axes       = FALSE
          )
          box()
        })
      })
    }
  })
  
  # final outputs
  output$log         <- renderText(log_txt())
  output$index_table <- renderDT({ req(index_df()); datatable(index_df(), rownames=TRUE, options=list(pageLength=5)) })
  
  output$download_results <- downloadHandler(
    filename    = function() paste0("rdrs_output_", format(Sys.time(), "%Y%m%d_%H%M%S"), ".zip"),
    contentType = "application/zip",
    content     = function(file) {
      req(result_zip())
      file.copy(result_zip(), file, overwrite=TRUE)
    }
  )
}

shinyApp(ui, server)
