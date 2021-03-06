#' Live preview a site
#'
#' The function \code{serve_site()} executes the server command of a static site
#' generator (e.g., \command{hugo server} or \command{jekyll server}) to start a
#' local web server, which watches for changes in the site, rebuilds the site if
#' necessary, and refreshes the web page automatically; \code{stop_server()}
#' stops the web server.
#'
#' By default, the server also watches for changes in R Markdown files, and
#' recompile them automatically if they are modified. This means they will be
#' automatically recompiled once you save them. If you do not like this
#' behavior, you may set \code{options(blogdown.knit.on_save = FALSE)} (ideally
#' in your \file{.Rprofile}). When this feature is disabled, you will have to
#' manually compile Rmd documents, e.g., by clicking the Knit button in RStudio.
#'
#' The site generator is defined by the global R option
#' \code{blogdown.generator}, with the default being \code{'hugo'}. You may use
#' other site generators including \code{jekyll} and \code{hexo}, e.g.,
#' \code{options(blogdown.generator = 'jekyll')}. You can define command-line
#' arguments to be passed to the server of the site generator via the global R
#' option \code{blogdown.X.server}, where \code{X} is \code{hugo},
#' \code{jekyll}, or \code{hexo}. The default for Hugo is
#' \code{options(blogdown.hugo.server = c('-D', '-F', '--navigateToChanged'))}
#' (see the documentation of Hugo server at
#' \url{https://gohugo.io/commands/hugo_server/} for the meaning of these
#' arguments).
#' @param ... Arguments passed to \code{servr::\link{server_config}()} (only
#'   arguments \code{host}, \code{port}, \code{browser}, \code{daemon}, and
#'   \code{interval} are supported).
#' @note For the Hugo server, the argument \command{--navigateToChanged} is used
#'   by default, which means when you edit and save a source file, Hugo will
#'   automatically navigate the web browser to the page corresponding to this
#'   source file (if the page exists). However, due to a Hugo bug
#'   (\url{https://github.com/gohugoio/hugo/issues/3811}), this automatic
#'   navigation may not always work for R Markdown posts, and you may have to
#'   manually refresh your browser. It should work reliably for pure Markdown
#'   posts, though.
#' @export
serve_site = function(...) {
  serve = switch(
    generator(), hugo = serve_it(),
    jekyll = serve_it(
      baseurl = get_config2('baseurl', ''),
      pdir = get_config2('destination', '_site')
    ),
    hexo = serve_it(
      baseurl = get_config2('root', ''),
      pdir = get_config2('public_dir', 'public')
    ),
    stop("Cannot recognize the site (only Hugo, Jekyll, and Hexo are supported)")
  )
  serve(...)
}

server_ready = function(url) {
  !inherits(
    xfun::try_silent(suppressWarnings(readLines(url))), 'try-error'
  )
}

# this function is primarily for users who click the Knit button in RStudio (the
# main purposes are to suppress a message that is not useful to Knit button
# users, and avoid rebuilding Rmd files because Knit button has done the job);
# normally you wouldn't need to call it by yourself
preview_site = function(..., startup = FALSE) {
  # when startup = FALSE, set knitting = TRUE permanently for this R session, so
  # that build_site() in serve_site() no longer automatically rebuilds Rmds on
  # save by default, and an Rmd has to be manually knitted
  if (startup) {
    opts$set(preview = TRUE)
    on.exit(opts$set(preview = NULL), add = TRUE)
    # open some files initially if specified
    init_files = getOption('blogdown.initial_files')
    if (is.function(init_files)) init_files = init_files()
    for (f in init_files) if (file_exists(f)) open_file(f)
  } else {
    opts$set(knitting = TRUE)
    on.exit(refresh_viewer(), add = TRUE)
  }
  invisible(serve_site(...))
}

preview_mode = function() {
  isTRUE(opts$get('preview')) || isTRUE(opts$get('knitting'))
}

serve_it = function(pdir = publish_dir(), baseurl = site_base_dir()) {
  g = generator(); config = config_files(g)
  function(...) {
    root = site_root(config)
    if (root %in% opts$get('served_dirs')) {
      if (preview_mode()) return()
      servr::browse_last()
      return(message(
        'The site has been served under the directory "', root, '". I have tried ',
        'to reopen it for you with servr::browse_last(). If you do want to ',
        'start a new server, you may stop existing servers with ',
        'blogdown::stop_server(), or restart R. Normally you should not need to ',
        'serve the same site multiple times in the same R session',
        if (servr:::is_rstudio()) c(
          ', otherwise you may run into issues like ',
          'https://github.com/rstudio/blogdown/issues/404'
        ), '.'
      ))
    }

    owd = setwd(root); on.exit(setwd(owd), add = TRUE)

    server = servr::server_config(..., baseurl = baseurl)

    # launch the hugo/jekyll/hexo server
    cmd = if (g == 'hugo') find_hugo() else g
    host = server$host; port = server$port; intv = server$interval
    if (!servr:::port_available(port, host)) stop(
      'The port ', port, ' at ', host, ' is unavailable', call. = FALSE
    )
    args_fun = match.fun(paste0(g, '_server_args'))
    cmd_args = args_fun(host, port)
    if (g == 'hugo') tweak_hugo_env()
    # if requested not to demonize the server, run it in the foreground process,
    # which will block the R session
    if (!server$daemon) return(system2(cmd, cmd_args))

    pid = if (getOption('blogdown.use.processx', xfun::loadable('processx'))) {
      proc = processx::process$new(cmd, cmd_args, stderr = '|', cleanup_tree = TRUE)
      I(proc$get_pid())
    } else {
      xfun::bg_process(cmd, cmd_args)
    }
    opts$append(pids = list(pid))

    message(
      'Launching the server via the command:\n  ',
      paste(c(cmd, cmd_args), collapse = ' ')
    )
    i = 0
    repeat {
      Sys.sleep(1)
      if (server_ready(server$url)) break
      if (i >= getOption('blogdown.server.timeout', 30)) {
        s = proc_kill(pid)  # if s == 0, the server must have been started successfully
        stop(if (s == 0) c(
          'Failed to launch the preview of the site. This may be a bug of blogdown. ',
          'You may file a report to https://github.com/rstudio/blogdown/issues with ',
          'a reproducible example. Thanks!'
        ) else c(
          'It took more than ', i, ' seconds to launch the server. An error might ',
          'have occurred with ', g, '. You may run blogdown::build_site() and see ',
          'if it gives more info. If the site is very large and needs more time to ',
          'be built, set options(blogdown.server.timeout) to a larger value.'
        ), call. = FALSE)
      }
      i = i + 1
    }
    server$browse()
    # server is correctly started so we record the directory served
    opts$append(served_dirs = root)
    message(
      'Launched the ', g, ' server in the background (process ID: ', pid, '). ',
      'To stop it, call blogdown::stop_server() or restart the R session.'
    )

    # delete the resources/ dir if it is empty
    if (g == 'hugo') del_empty_dir('resources')

    # whether to watch for changes in Rmd files?
    if (!getOption('blogdown.knit.on_save', TRUE)) return(invisible())

    # rebuild specific or changed Rmd files
    rebuild = function(files) {
      if (is.null(b <- getOption('blogdown.knit.on_save'))) {
        b = !isTRUE(opts$get('knitting'))
        if (!b) {
          options(blogdown.knit.on_save = b)
          message(
            'It seems you have clicked the Knit button in RStudio. If you prefer ',
            'knitting a document manually over letting blogdown automatically ',
            'knit it on save, you may set options(blogdown.knit.on_save = FALSE) ',
            'in your .Rprofile so blogdown will not knit documents automatically ',
            'again (I have just set this option for you for this R session). If ',
            'you prefer knitting on save, set this option to TRUE instead.'
          )
          files = b  # just ignore changed Rmd files, i.e., don't build them
        }
      }
      xfun::in_dir(root, build_site(TRUE, run_hugo = FALSE, build_rmd = files))
    }

    # build Rmd files that are new and don't have corresponding output files
    rmd_files = newfile_filter(list_rmds(content_file()))
    rebuild(rmd_files)

    watch = servr:::watch_dir('.', rmd_pattern, handler = function(files) {
      rmd_files <<- files
    })
    watch_build = function() {
      # stop watching if stop_server() has cleared served_dirs
      if (is.null(opts$get('served_dirs'))) return(invisible())
      if (watch()) try({rebuild(rmd_files); refresh_viewer()})
      if (getOption('blogdown.knit.on_save', TRUE)) later::later(watch_build, intv)
    }
    watch_build()

    return(invisible())
  }
}

jekyll_server_args = function(host, port) {
  c('serve', '--port', port, '--host', host, getOption(
    'blogdown.jekyll.server', c('--watch', '--incremental', '--livereload')
  ))
}

hexo_server_args = function(host, port) {
  c('server', '-p', port, '-i', host, getOption('blogdown.hexo.server'))
}

#' @export
#' @rdname serve_site
stop_server = function() {
  ids = NULL  # collect pids that we failed to kill
  quitting = isTRUE(opts$get('quitting'))
  for (i in opts$get('pids')) {
    # no need to kill a process started by processx when R is quitting
    if (quitting && inherits(i, 'AsIs')) next
    if (proc_kill(i, stdout = FALSE, stderr = FALSE) != 0) ids = c(ids, i)
  }
  if (length(ids)) warning(
    'Failed to kill the process(es): ', paste(i, collapse = ' '),
    '. You may need to kill them manually.'
  ) else if (!quitting) message('The web server has been stopped.')
  opts$set(pids = NULL, served_dirs = NULL)
}

# TODO: remove the following two functions and import xfun::proc_kill() after
# xfun 0.20 is released because 0.19 contains a bug
proc_kill = function(pid, recursive = TRUE, ...) {
  if (is_windows()) {
    xfun::proc_kill(pid, recursive, ...)
  } else {
    system2('kill', c(pid, if (recursive) child_pids(pid)), ...)
  }
}
child_pids = function(id) {
  x = system2('sh', shQuote(c(
    system.file('scripts', 'child_pids.sh', package = 'xfun'), id
  )), stdout = TRUE)
  grep('^[0-9]+$', x, value = TRUE)
}

get_config2 = function(key, default) {
  res = yaml_load_file('_config.yml')
  res[[key]] %n% default
}

# refresh the viewer because hugo's livereload doesn't work on RStudio
# Server: https://github.com/rstudio/rstudio/issues/8096 (TODO: check if
# it's fixed in the future: https://github.com/gohugoio/hugo/pull/6698)
refresh_viewer = function() {
  if (!is_rstudio_server()) return()
  server_wait()
  rstudioapi::executeCommand('viewerRefresh')
}

server_wait = function() {
  Sys.sleep(getOption('blogdown.server.wait', 2))
}
