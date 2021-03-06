#' Interface to mallet topicmodelling.
#' 
#' Functionality to support the following workflow (see examples): (a) Turn
#' \code{partition_bundle}-object into mallet instance list, (b) store the
#' resulting \code{jobjRef}-object, (c) run mallet topic modelling and (d)
#' turn ParallelTopicModel Java object into \code{LDA_Gibbs} object from
#' package \code{topicmodels}.
#' 
#' @param x A \code{partition_bundle} object.
#' @param terms_to_drop stopwords
#' @param ... further parameters
#' @param p_attribute The p_attribute to use, typically "word" or "lemma".
#' @param phrases A \code{phrases} object (S4 class from polmineR) that will be
#'   used to concatenate phrases.
#' @param mc A \code{logical} value, whether to use multicore.
#' @param verbose A \code{logical} value, whether to be verbose.
#' @param filename Where to store the Java-object.
#' @importFrom utils read.csv read.table
#' @importFrom stats setNames
#' @importFrom slam simple_triplet_matrix
#' @importFrom parallel mclapply
#' @importFrom polmineR get_token_stream
#' @examples  
#' # Preparations: Create instance list
#' 
#' polmineR::use("polmineR")
#' speeches <- polmineR::as.speeches("GERMAPARLMINI", s_attribute_name = "speaker")
#' 
#' if (requireNamespace("rJava")){
#'   # options(java.parameters = "-Xmx4g")
#'   library(rJava)
#'   .jinit()
#'   # We need to put the jars from mallet 2.0 on the classpath because
#'   # only the newer mallet version (not the one included in mallet R package)
#'   # has method ParallelTopicModel$getDocumentTopics() needed by as_LDA
#'   .jaddClassPath("/opt/mallet-2.0.8/class") # after .jinit()
#'   .jaddClassPath("/opt/mallet-2.0.8/lib/mallet-deps.jar")
#'   instance_list <- topicanalysis::mallet_make_instance_list(speeches)
#'   instancefile <- mallet_instance_list_store(instance_list)
#' }
#' 
#' # Option 1: Run mallet from R using mallet package
#' 
#' if (requireNamespace("mallet")){
#'   lda <- mallet::MalletLDA(num.topics = 20)
#'   lda$loadDocuments(instance_list)
#'   lda$setAlphaOptimization(20, 50)
#'   lda$train(100)
#' }
#' 
#' # Option 2: Use ParallelTopicModel class - has write()-method
#' 
#' if (requireNamespace("mallet")){
#'   destfile <- tempfile()
#'   lda <- rJava::.jnew("cc/mallet/topics/ParallelTopicModel", 25L, 5.1, 0.1)
#'   lda$addInstances(instance_list)
#'   lda$setNumThreads(1L)
#'   lda$setTopicDisplay(50L, 10L)
#'   lda$setNumIterations(150L)
#'   lda$estimate()
#'   lda$write(rJava::.jnew("java/io/File", destfile))
#' }
#' 
#' # Load topicmodel and turn it into LDA_Gibbs
#' 
#' mallet_lda <- mallet_load_topicmodel(destfile)
#' \dontrun{
#' topicmodels_lda <- as_LDA(mallet_lda)
#' }
#' 
#' @rdname mallet
#' @importFrom polmineR get_token_stream
#' @export mallet_make_instance_list
mallet_make_instance_list <- function(x, p_attribute = "word", phrases = NULL, terms_to_drop = tm::stopwords("de"), mc = TRUE, verbose = TRUE){
  if (!requireNamespace(package = "rJava", quietly = TRUE)) stop("rJava package not available")
  if (!requireNamespace(package = "mallet", quietly = TRUE)) stop("mallet package not available")
  
  token_stream_list <- get_token_stream(x, p_attribute = p_attribute, phrases = phrases, collapse = "\n")
  token_stream_vec <- unlist(token_stream_list)
  rm(token_stream_list)
  
  tmp_dir <- tempdir()
  stoplist_file <- file.path(tmp_dir, "stoplists.txt")
  cat(paste(terms_to_drop, collapse = "\n"), file = stoplist_file)
  
  if (verbose) message("... preparing mallet object")
  mallet::mallet.import(
    id.array = names(x), text.array = token_stream_vec,
    stoplist.file = stoplist_file, preserve.case = TRUE
  )
}


#' @param beta The beta matrix for a topic model.
#' @param gamma The gamma matrix for a topic model.
#' @details The \code{as_LDA()}-function will turn an estimated topic model
#'   prepared using 'mallet' into a \code{LDA_Gibbs} object as defined in the
#'   \code{topicmodels} package. This may be useful for using topic model
#'   evaluation tools available for the \code{LDA_Gibbs} class, but not for the
#'   immediate output of malled topicmodelling. Note that the gamma matrix is
#'   normalized and smoothed, the beta matrix is the logarithmized matrix of
#'   normalized and smoothed values obtained from the input mallet topic model.
#' @export as_LDA
#' @importFrom pbapply pblapply
#' @rdname mallet
as_LDA <- function(x, verbose = TRUE, beta = NULL, gamma = NULL){

  if (!grepl("ParallelTopicModel", x$getClass()$toString()))
    stop("incoming object needs to be class ParallelTopicModel")
  
  if (verbose) message("... getting number of documents and number of terms")
  dimensions <- c(
    x$data$size(), # Number of documents
    x$getAlphabet()$size() # Number of terms
  )
  
  if (verbose) message("... getting alphabet")
  alphabet <- strsplit(x$getAlphabet()$toString(), "\n")[[1]]
  
  if (verbose) message("... getting document names")
  docs <- pblapply(0L:(x$data$size() - 1L), function(i) x$data$get(i)$instance$getName())

  if (is.null(gamma)){
    if (verbose) message("... getting topic probabilities (gamma matrix)")
    gamma <- rJava::.jevalArray(x$getDocumentTopics(TRUE, TRUE), simplify = TRUE)
  }

  if (is.null(beta)){
    message("... getting topic word weights (beta matrix)")
    beta <- rJava::.jevalArray(x$getTopicWords(TRUE, TRUE), simplify = TRUE) 
    beta <- log(beta)
  }

  new(
    "LDA_Gibbs",
    Dim = dimensions,
    k = x$getNumTopics(),
    terms = alphabet,
    documents = docs, # Vector containing the document names
    beta = beta, # A matrix; logarithmized parameters of the word distribution for each topic
    gamma = gamma, # matrix, parameters of the posterior topic distribution for each document
    iter = x$numIterations
  )
}


#' @rdname mallet
#' @export mallet_instance_list_store
mallet_instance_list_store <- function(x, filename = tempfile()){
  # This snippet is inspired an unexported function save.mallet.instances in 
  # v1.2.0 of the R mallet package which has not yet been released at CRAN.
  # See: https://github.com/mimno/RMallet/blob/master/mallet/R/mallet.R
  x$save(rJava::.jnew("java/io/File", filename))
  filename
}


#' @details The function \code{mallet_instance_list_load} will load a Java
#'   InstanceList object that has been saved to disk (e.g. by using the
#'   \code{mallet_instance_list_store} function). The return value is a
#'   \code{jobjRef} object. Internally, the function reuses code of the function
#'   \code{load.mallet.instances} from the R package \code{mallet}.
#' @rdname mallet
#' @export mallet_instance_list_load
mallet_instance_list_load <- function(filename){
  rJava::J("cc.mallet.types.InstanceList")$load(rJava::.jnew("java/io/File", filename))
}

#' @details The function \code{mallet_load_topicmodel} will load a topic model
#'   created using mallet into memory.
#' @rdname mallet
#' @export mallet_load_topicmodel
mallet_load_topicmodel <- function(filename){
  rJava::J("cc/mallet/topics/ParallelTopicModel")$read(rJava::.jnew("java/io/File", filename))
}

.mallet_cmd <- function(mallet_bin_dir, sourcefile, destfile, topwords = 50, topics = 50, iterations = 2000, threads = NULL){
  stopifnot(
    is.numeric(topics), topics > 2,
    is.numeric(iterations), iterations > 1,
    is.numeric(topwords), topwords > 2
    #    , is.numeric(threads), threads > 0
  )
  
  cmd <- c(
    file.path(mallet_bin_dir, "mallet"), "train-topics",
    "--input", sourcefile,
    "--num-topics", topics,
    "--num-iterations", iterations,
    "--output-model", destfile,
    if (is.null(threads)) c() else c("--num-threads", threads)
  )
  paste(cmd, collapse = " ")
}



#' Process large topic word weights matrices
#' 
#' The word weights matrix (weights of words for topics) can get big dataish when 
#' there is a large number of topics and a substantially sized vocabulary. The 
#' \code{mallet_save_word_weights} and the \code{mallet_load_word_weights} are 
#' tools to handle this scenario by writing out the data to disk as a sparse matrix, 
#' and loading this into the R session. In order to be able to use the function,
#' the \code{ParallelTopicModel} class needs to be used, the \code{RTopicModel} will
#' not do it.
#' 
#' @param filename A file with word weights.
#' @export mallet_load_word_weights
#' @importFrom slam simple_triplet_matrix
#' @rdname word_weights
#' @examples
#' \dontrun{
#' polmineR::use("polmineR")
#' speeches <- polmineR::as.speeches("GERMAPARLMINI", s_attribute_name = "speaker")
#' 
#' library(rJava)
#' .jinit()
#' .jaddClassPath("/opt/mallet-2.0.8/class") # after .jinit(), not before
#' .jaddClassPath("/opt/mallet-2.0.8/lib/mallet-deps.jar")
#' instance_list <- topicanalysis::mallet_make_instance_list(speeches)
#' instancefile <- mallet_instance_list_store(instance_list)
#' 
#' lda <- mallet::MalletLDA(num.topics = 20)
#' lda$loadDocuments(instance_list)
#' lda$setAlphaOptimization(20, 50)
#' lda$train(100)
#' 
#' # This is the call used internally by 'as_LDA()'. The difference
#' # is that the arguments of the $getTopicWords()-method are FALSE 
#' # (argument 'normalized') and TRUE (argument 'smoothed')
#' beta_1 <- rJava::.jevalArray(lda$getTopicWords(FALSE, TRUE), simplify = TRUE) 
#' alphabet <- strsplit(lda$getAlphabet()$toString(), "\n")[[1]]
#' colnames(beta_1) <- alphabet
#' beta_1 <- beta_1[, alphabet[order(alphabet)] ]
#' rownames(beta_1) <- as.character(1:nrow(beta_1))
#' 
#' # This is an approach that uses a (temporary) file written
#' # to disk. The advantage is that it is a sparse matrix that is
#' # passed
#' fname <- mallet_save_word_weights(lda)
#' word_weights <- mallet_load_word_weights(fname)
#' beta_2 <- t(as.matrix(word_weights))
#' 
#' # Demonstrate the equivalence of the two approaches
#' identical(rownames(beta_1), rownames(beta_2))
#' identical(colnames(beta_1), colnames(beta_2))
#' identical(apply(beta_1, 1, order), apply(beta_2, 1, order))
#' identical(beta_1, beta_2)
#' }
mallet_load_word_weights <- function(filename){
  word_weights_raw <- read.table(filename, sep = "\t")
  simple_triplet_matrix(
    i = as.integer(word_weights_raw[,2]),
    j = word_weights_raw[,1] + 1L,
    v = word_weights_raw[,3],
    dimnames = list(
      levels(word_weights_raw[,2]),
      as.character(1L:(max(word_weights_raw[,1]) + 1L))
    )
  )
}

#' @details The function \code{mallet_save_word_weights} will write a file that
#'   can be handled as a sparse matrix to a file (argument \code{destfile}).
#'   Internally, it uses the method \code{printTopicWordWeights} of the
#'   \code{ParallelTopicModel} class. The (parsed) content of the file is
#'   equivalent to matrix that can be obtained directly the class using the
#'   \code{getTopicWords(FALSE, TRUE)} method. Thus, values are not normalised,
#'   but smoothed (= coefficient beta is added to values).
#' @param model A topic model (class \code{jobjRef}).
#' @param destfile Length-one \code{character} vector, the filename of the
#'   output file.
#' @rdname word_weights
#' @export mallet_save_word_weights
mallet_save_word_weights <- function(model, destfile = tempfile()){
  if (!requireNamespace("rJava", quietly = TRUE))
    stop("Package 'rJava' required, but not available.")
  file <- rJava::.jnew("java/io/File", destfile)
  file_writer <- rJava::.jnew("java/io/FileWriter", file)
  print_writer <- rJava::new(rJava::J("java/io/PrintWriter"), file_writer)
  model$printTopicWordWeights(print_writer)
  print_writer$close()
  destfile 
}


#' Get sparse beta matrix
#' 
#' The beta matrix reporting word weights for topics can grow extremely large. The
#' straight-forward ways to get the matrix can be slow and utterly memory inefficient.
#' This function uses the \code{topicXMLReport()}-method of the \code{ParallelTopicModel}
#' that is the most memory efficient solution we now at this stage. The trick is that
#' weights are only reported for the top N words. Thus you can process the data as
#' as sparse matrix, which is the memory efficient solution. See the examples as a proof
#' that the result is equivalent indeed to the \code{getTopicWords()}-method. Note 
#' however that the matrix is neither normalized nor smoothed nor algorithmized.
#' 
#' @param x A \code{ParallelTopicModel} class object
#' @param n_topics A length-one \code{integer} vector, the number of topics.
#' @param destfile Length-one \code{character} vector, the filename of the
#'   output file.
#' @export mallet_get_sparse_word_weights_matrix
#' @examples 
#' \dontrun{
#' # x is assumed to be any ParallelTopicModel class object
#' m <- mallet_get_sparse_word_weights_matrix(x)
#' beta_sparse <- as.matrix(m)
#' beta_dense <- rJava::.jevalArray(x$getTopicWords(FALSE, FALSE), simplify = TRUE) 
#' rownames(beta_dense) <- as.character(1:nrow(beta_dense))
#' 
#' 
#' identical(max(beta_sparse[1,]), as.integer(max(beta_dense[1,])))
#' identical(
#'   unname(head(beta_sparse[1,][order(beta_sparse[1,], decreasing = TRUE)], 5)),
#'   as.integer(head(beta_dense[1,][order(beta_dense[1,], decreasing = TRUE)], 5))
#' )
#' .fn <- function(x) as.integer(unname(head(x[order(x, decreasing = TRUE)], 50)))
#' identical(apply(beta_sparse, 1, .fn), apply(beta_dense, 1, .fn))
#' }
#' @importFrom xml2 read_xml xml_find_all xml_text
mallet_get_sparse_word_weights_matrix <- function(x, n_topics = 50L, destfile = tempfile()){
  if (!requireNamespace("rJava", quietly = TRUE))
    stop("Package 'rJava' required, but not available.")
  
  file <- rJava::.jnew("java/io/File", destfile)
  file_writer <- rJava::.jnew("java/io/FileWriter", file)
  print_writer <- rJava::new(rJava::J("java/io/PrintWriter"), file_writer)
  x$topicXMLReport(print_writer, n_topics)
  print_writer$close()
  
  topic_xml_report <- xml2::read_xml(destfile)
  df <- do.call(
    rbind,
    lapply(
      xml2::xml_find_all(x = topic_xml_report, xpath = "/topicModel/topic"),
      function(topic_node){
        topic_id <- as.integer(xml2::xml_attr(x = topic_node, attr = "id"))
        do.call(
          rbind,
          lapply(
            xml2::xml_find_all(x = topic_node, xpath = "./word"),
            function(word_node){
              data.frame(
                topic_id = topic_id,
                token = xml2::xml_text(x = word_node),
                # rank = as.integer(xml2::xml_attr(x = word_node, attr = "rank")),
                count = as.integer(xml2::xml_attr(x = word_node, attr = "count")),
                stringsAsFactors = FALSE
              )
            }
          )
        )
      }
    )
  )
  
  alphabet <- strsplit(x$getAlphabet()$toString(), "\n")[[1]]
  df[["token_id"]] <- pmatch(df[["token"]], alphabet, duplicates.ok = TRUE)
  dt <- as.data.table(df)
  setorderv(dt, cols = c("topic_id", "token_id"))
  y <- slam::simple_triplet_matrix(
    i = dt[["topic_id"]] + 1L,
    j = dt[["token_id"]],
    v = dt[["count"]],
    nrow = x$getNumTopics(),
    ncol = x$getAlphabet()$size(),
    dimnames = list(as.character(1L:x$getNumTopics()), alphabet)
  )
}

