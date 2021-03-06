
#' Create materialize statement.
#'
#' @param db DBI connecton.
#' @param sql character single SQL statement.
#' @param table_name character, name of table to create.
#' @param ... force later arguments to bind by name.
#' @param temporary logical if TRUE try to create a temporary table.
#' @return modified SQL
#'
#' @examples
#'
#' if(requireNamespace("RSQLite", quietly = TRUE)) {
#'   my_db <- DBI::dbConnect(RSQLite::SQLite(), ":memory:")
#'   print(materialize_sql_statement(my_db,
#'                                   "SELECT x+1 FROM z",
#'                                   "restable"))
#'   DBI::dbDisconnect(my_db)
#' }
#'
#' @export
#'
materialize_sql_statement <- function(db, sql, table_name,
                                      ...,
                                      temporary = FALSE) {
  # TODO: put in more per-connection options here (including partion controls)
  if(isTRUE(temporary)) {
    create_temp <- getDBOption(db, "create_temporary", NULL)
    if(is.null(create_temp)) {
      create_temp <- !connection_is_spark(db)
    }
    if(!create_temp) {
      if(getOption("rquery.verbose")) {
        warning("setting rquery:::materialize_sql_statement setting temporary=FALSE")
      }
      temporary <- FALSE
    }
  } else {
    temporary <- FALSE
  }
  storage_control <- getDBOption(db, "create_options", "")
  sqlc <- paste("CREATE",
                ifelse(temporary, "TEMPORARY ", ""),
                "TABLE",
                quote_identifier(db, table_name),
                storage_control,
                "AS",
                sql)
  sqlc
}

#' Materialize an optree as a table.
#'
#' Run the data query as a CREATE TABLE AS . Think of as a function
#' that can be applied to relop trees, not as a component to place
#' in pipelines.
#'
#' @param db DBI connecton.
#' @param optree relop operation tree.
#' @param table_name character, name of table to create.
#' @param ... force later arguments to bind by name.
#' @param limit numeric if not NULL result limit (to use this, last statment must not have a limit).
#' @param source_limit numeric if not NULL limit sources to this many rows.
#' @param overwrite logical if TRUE drop an previous table.
#' @param temporary logical if TRUE try to create a temporary table.
#' @return table handle
#'
#' @seealso \code{\link{execute}}
#'
#' @examples
#'
#' if (requireNamespace("RSQLite", quietly = TRUE)) {
#'   my_db <- DBI::dbConnect(RSQLite::SQLite(), ":memory:")
#'   d <- dbi_copy_to(my_db, 'd',
#'                    data.frame(AUC = 0.6, R2 = 0.2))
#'   optree <- extend_se(d, c("v" := "AUC + R2", "x" := "pmax(AUC,v)"))
#'   cat(format(optree))
#'   res <- materialize(my_db, optree, "example")
#'   cat(format(res))
#'   sql <- to_sql(res, my_db)
#'   cat(sql)
#'   print(DBI::dbGetQuery(my_db, sql))
#'   DBI::dbDisconnect(my_db)
#' }
#'
#' @export
#'
materialize <- function(db,
                        optree,
                        table_name = mk_tmp_name_source('rquery_mat')(),
                        ...,
                        limit = NULL,
                        source_limit = NULL,
                        overwrite = TRUE,
                        temporary = FALSE) {
  wrapr::stop_if_dot_args(substitute(list(...)), "rquery::materialize")
  if(!("relop" %in% class(optree))) {
    stop("rquery::materialize expect optree to be of class relop")
  }
  qlimit = limit
  if(!getDBOption(db, "use_pass_limit", TRUE)) {
    qlimit = NULL
  }
  sql_list <- to_sql(optree, db,
                     limit = qlimit,
                     source_limit = source_limit)
  # establish some safe invarients
  if(length(sql_list)<1) {
    return(NULL)
  }
  if(!is.character(sql_list[[1]])) {
    stop("rquery::materialize first step must be SQL")
  }
  if(!is.character(sql_list[[length(sql_list)]])) {
    stop("rquery::materialize last step must be SQL")
  }
  if(length(sql_list)>=2) {
    for(ii in seq_len(length(sql_list)-1)) {
      if((!is.character(sql_list[[ii]]))&&
         (!is.character(sql_list[[ii+1]]))) {
        stop("rquery::materialize can not have two non-SQL sub-steps in a row")
      }
    }
  }
  # check/clear final result
  if(dbi_table_exists(db, table_name)) {
    if(overwrite) {
      dbi_remove_table(db, table_name)
    } else {
      stop(paste("rquery::materialize result table",
                 table_name,
                 "exists, but do not have overwrite=TRUE"))
    }
  }
  # clear intermediates
  if(length(sql_list)>=3) {
    for(ii in seq(2,length(sql_list)-1)) {
      sqli <- sql_list[[ii]]
      if(!is.character(sqli)) {
        dbi_remove_table(db, sqli$incoming_table_name)
        dbi_remove_table(db, sqli$outgoing_table_name)
      }
    }
  }
  # work on all but last node of chain
  to_clear <- NULL
  if(length(sql_list)>=2) {
    # do the work on all but the last node
    for(ii in seq_len(length(sql_list)-1)) {
      sqli <- sql_list[[ii]]
      if(is.character(sqli)) {
        dbi_execute(db, sqli)
        if(!is.null(to_clear)) {
          dbi_remove_table(db, to_clear)
          to_clear <- NULL
        }
      } else {
        if(!is.null(sqli$f)) {
          sqli$f(db,
                 sqli$incoming_table_name,
                 sqli$outgoing_table_name)
          dbi_remove_table(db, sqli$incoming_table_name)
          if((!is.null(to_clear)) &&
             (to_clear!=sqli$outgoing_table_name)) {
            dbi_remove_table(db, to_clear)
          }
          to_clear <- sqli$outgoing_table_name
        } else {
          if((!is.null(to_clear)) &&
              (to_clear!=sqli$outgoing_table_name)) {
            dbi_remove_table(db, to_clear)
          }
          to_clear <- sqli$outgoing_table_name
        }
      }
    }
  }
  # work on the last node (must be SQL)
  sql <- sql_list[[length(sql_list)]]
  if(!is.null(limit)) {
    # look for limit
    haslimit <- grep("^.*[[:space:]]LIMIT[[:space:]]+[0-9]+[[:space:]]*$",
                     sql,
                     ignore.case = TRUE)
    if(length(haslimit)<1) {
      sql <- paste(sql, "LIMIT",
                    format(ceiling(limit), scientific = FALSE))
    }
  }
  sqlc <- materialize_sql_statement(db, sql, table_name,
                                    temporary = temporary)
  dbi_execute(db, sqlc)
  if(!is.null(to_clear)) {
    dbi_remove_table(db, to_clear)
    to_clear <- NULL
  }
  dbi_table(db, table_name)
}



#' Execute a operator tree, either bringing back the result or landing it as a table.
#'
#' Run the data query.  If table_name is not set results
#' (up to limit rows) are brought back to R. If
#' table_name is set full results are materailized as a remote
#' table.
#'
#' @param source data.frame or DBI connection.
#' @param optree relop operation tree.
#' @param ... force later arguments to bind by name.
#' @param table_name character, name of table to create.
#' @param limit numeric, if set limit to this many rows during data bring back (not used when landing a table).
#' @param source_limit numeric if not NULL limit sources to this many rows.
#' @param overwrite logical if TRUE drop an previous table.
#' @param temporary logical if TRUE try to create a temporary table.
#' @return data.frame or table handle.
#'
#' @seealso \code{\link{materialize}}, \code{\link{to_sql}}
#'
#' @examples
#'
#' if (requireNamespace("RSQLite", quietly = TRUE)) {
#'   my_db <- DBI::dbConnect(RSQLite::SQLite(), ":memory:")
#'   d <- dbi_copy_to(my_db, 'd',
#'                    data.frame(AUC = 0.6, R2 = 0.2))
#'   optree <- extend_se(d, c("v" := "AUC + R2", "x" := "pmax(AUC,v)"))
#'
#'   print(optree)
#'
#'   cat(format(optree))
#'
#'   execute(my_db, optree) %.>%
#'      print(.)
#'
#'   execute(data.frame(AUC = 1, R2 = 2), optree) %.>%
#'      print(.)
#'
#'   # land result in database
#'   res_hdl <- execute(my_db, optree, table_name = "res")
#'   print(res_hdl)
#'   print(DBI::dbGetQuery(my_db, to_sql(res_hdl, my_db)))
#'   print(DBI::dbReadTable(my_db, res_hdl$table_name))
#'   DBI::dbRemoveTable(my_db, res_hdl$table_name)
#'
#'   DBI::dbDisconnect(my_db)
#' }
#'
#' @export
#'
execute <- function(source,
                    optree,
                    ...,
                    table_name = NULL,
                    limit = NULL,
                    source_limit = NULL,
                    overwrite = TRUE,
                    temporary = FALSE) {
  wrapr::stop_if_dot_args(substitute(list(...)), "rquery::execute")
  if(!("relop" %in% class(optree))) {
    stop("rquery::execute expect optree to be of class relop")
  }
  if(is.data.frame(source)) {
    res <- rquery_apply_to_data_frame(source,
                                      optree,
                                      env = parent.frame(),
                                      limit = limit)
    return(res)
  }
  db <- source # assume it is a DBI connection (they do not share a base class)
  table_name_set <- !is.null(table_name)
  if(!table_name_set) {
    table_name <-  mk_tmp_name_source('rquery_ex')()
  }
  ref <- materialize(db, optree,
                     table_name = table_name,
                     limit = limit,
                     source_limit = source_limit,
                     overwrite = overwrite,
                     temporary = temporary)
  res <- ref
  if(!table_name_set) {
    sql <- to_sql(ref, db, limit = limit)
    res <- DBI::dbGetQuery(db, sql)
    dbi_remove_table(db, ref$table_name)
  }
  res
}


# Hyderdrive (science fiction show) version.

#' @rdname execute
#' @export
commencify <- execute

