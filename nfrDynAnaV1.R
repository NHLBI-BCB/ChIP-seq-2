#!/usr/bin/env Rscript
suppressPackageStartupMessages(library("optparse"))

## parse command line arguments
option_list <- list(
	make_option(c("-i", "--sessionFile"), help="input session file saved during previous ngsPlot run (if multiple, seperate them by a comma)"),
    make_option(c("-j", "--sessionFileDes"), help="description of each session file"),
    make_option(c("-k", "--regionCounts"), help="region count corresponding to each session file"),
	make_option(c("-o", "--outPdfFile"), help="output pdf image file"),
    make_option(c("-r", "--plotOrder"), help="order in which sample profile should be plotted"),
    make_option(c("-x", "--yMax"), help="maximum limit to y-axis"),
    make_option(c("-y", "--yMin"), help="minimum limit to y-axis"),
    make_option(c("-t", "--tfProfile"), help="plot profile for transcription factor instead", action="store_true"),
    make_option(c("-l", "--logScale"), help="plot histone profile in log scale", action="store_true")
)

parser <- OptionParser(usage = "%prog [options]", option_list=option_list)
opt <- parse_args(parser)

## check, if all required arguments are given
if(is.null(opt$sessionFile) | is.null(opt$sessionFileDes) | is.null(opt$outPdfFile)) {
	cat("\nProgram: nfrDynAna.R (R script to plot NFR dynamics)\n")
	cat("Author: BRIC, University of Copenhagen, Denmark\n")
	cat("Version: 1.0\n")
	cat("Contact: pundhir@binf.ku.dk\n");
	print_help(parser)
	q()
}

## load libraries
suppressPackageStartupMessages(library(caTools))
suppressPackageStartupMessages(library(session))
suppressPackageStartupMessages(library(ggplot2))

####################
#### plotlib.r ####
# This contains the library for plotting related functions.
#
# Authors: Li Shen, Ningyi Shao
# 
# Created: Feb 19, 2013
# Last updated: May 21, 2013
#

SetupHeatmapDevice <- function(reg.list, uniq.reg, ng.list, pts, 
                               unit.width=4, reduce.ratio=30) {
# Configure parameters for heatmap output device. The output is used by 
# external procedures to setup pdf device ready for heatmap plotting.
# Args:
#   reg.list: region list as in config file.
#   uniq.reg: unique region list.
#   ng.list: number of genes per heatmap in the order as config file.
#   pts: data points (number of columns of heatmaps).
#   unit.width: image width per heatmap.
#   reduce.ratio: how compressed are genes in comparison to data points? This 
#                 controls image height.

    # Number of plots per region.
    reg.np <- sapply(uniq.reg, function(r) sum(reg.list==r))

    # Number of genes per region.
    reg.ng <- sapply(uniq.reg, function(r) {
                    ri <- which(reg.list==r)[1]
                    ng.list[ri]
                })

    # Setup image size.
    hm.width <- unit.width * max(reg.np)
    ipl <- .2 # inches per line. Obtained from par->'mai', 'mar'.
    m.bot <- 2; m.lef <- 1.5; m.top <- 2; m.rig <- 1.5 # margin size in lines.
    key.in <- 1.0  # colorkey in inches.
    # Convert #gene to image height.
    reg.hei <- sapply(reg.ng, function(r) {
                    c(key.in,  # colorkey + margin.
                      r * unit.width / pts / reduce.ratio + 
                      m.bot * ipl + m.top * ipl)  # heatmap + margin.
                })
    reg.hei <- c(reg.hei)
    hm.height <- sum(reg.hei)

    # Setup layout of the heatmaps.
    lay.mat <- matrix(0, ncol=max(reg.np), nrow=length(reg.np) * 2)
    fig.n <- 1  # figure plotting number.
    for(i in 1:length(reg.np)) {
        row.upper <- i * 2 - 1
        row.lower <- i * 2
        for(j in 1:reg.np[i]) {
            lay.mat[row.upper, j] <- fig.n;
            fig.n <- fig.n + 1
            lay.mat[row.lower, j] <- fig.n;
            fig.n <- fig.n + 1
        }
    }

    list(reg.hei=reg.hei, hm.width=hm.width, hm.height=hm.height, 
         lay.mat=lay.mat, heatmap.mar=c(m.bot, m.lef, m.top, m.rig) * ipl)
}

SetPtsSpline <- function(pint, lgint) {
# Set data points for spline function.
# Args:
#   pint: tag for point interval.
# Return: list of data points, middle data points, flanking data points.

    pts <- 100  # data points to plot: 0...pts
    if(pint){  # point interval.
        m.pts <- 1  # middle part points.
        f.pts <- pts / 2  # flanking part points.
    } else {
        if(lgint) {
            m.pts <- pts / 5 * 3 + 1
            f.pts <- pts / 5 + 1
        } else {
            m.pts <- pts / 5 + 1
            f.pts <- pts / 5 * 2 + 1
        }
    }
    list(pts=pts, m.pts=m.pts, f.pts=f.pts)
}

CreatePlotMat <- function(pts, ctg.tbl) {
# Create matrix for avg. profiles.
# Args:
#   pts: data points.
#   ctg.tbl: configuration table.
# Return: avg. profile matrix initialized to zero.

    regcovMat <- matrix(0, nrow=pts + 1, ncol=nrow(ctg.tbl))
    colnames(regcovMat) <- ctg.tbl$title
    regcovMat
}

CreateConfiMat <- function(se, pts, ctg.tbl){
# Create matrix for standard errors.
# Args:
#   se: tag for standard error plotting.
#   pts: data points.
#   ctg.tbl: configuration table.
# Return: standard error matrix initialized to zero or null.

    if(se){
        confiMat <- matrix(0, nrow=pts + 1, ncol=nrow(ctg.tbl))
        colnames(confiMat) <- ctg.tbl$title
    } else {
        confiMat <- NULL
    }
    confiMat
}

col2alpha <- function(col2use, alpha){
# Convert a vector of solid colors to semi-transparent colors.
# Args:
#   col2use: vector of colors.
#   alpha: represents degree of opacity - [0,1]
# Return: vector of transformed colors.

    apply(col2rgb(col2use), 2, function(x){
            rgb(x[1], x[2], x[3], alpha=alpha*255, maxColorValue=255)
        })
}

smoothvec <- function(v, radius, method=c('mean', 'median')){
# Given a vector of coverage, return smoothed version of coverage.
# Args:
#   v: vector of coverage
#   radius: fraction of org. vector size.
#   method: smooth method
# Return: vector of smoothed coverage.

    stopifnot(is.vector(v))
    stopifnot(length(v) > 0)
    stopifnot(radius > 0 && radius < 1)

    halfwin <- ceiling(length(v) * radius)
    s <- rep(NA, length(v))

    for(i in 1:length(v)){
        winpos <- (i - halfwin) : (i + halfwin)
        winpos <- winpos[winpos > 0 & winpos <= length(v)]
        if(method == 'mean'){
            s[i] <- mean(v[winpos])
        }else if(method == 'median'){
            s[i] <- median(v[winpos])
        }
    }
    s
}

smoothplot <- function(m, radius, method=c('mean', 'median')){
# Smooth the entire avg. profile matrix using smoothvec.
# Args:
#   m: avg. profile matrix
#   radius: fraction of org. vector size.
#   method: smooth method.
# Return: smoothed matrix.

    stopifnot(is.matrix(m) || is.vector(m))

    if(is.matrix(m)) {
        for(i in 1:ncol(m)) {
            m[, i] <- smoothvec(m[, i], radius, method)
        }
    } else {
        m <- smoothvec(m, radius, method)
    }
    m
}

genXticks <- function(reg2plot, pint, lgint, pts, flanksize, flankfactor, 
                      Labs) {
# Generate X-ticks for plotting.
# Args:
#   reg2plot: string representation of region.
#   pint: point interval.
#   lgint: tag for large interval.
#   pts: data points.
#   flanksize: flanking region size in bps.
#   flankfactor: flanking region factor.
#   Labs: character vector of labels of the genomic region.
# Return: list of x-tick position and label.

    if(pint){   # point interval.
        mid.lab <- Labs[1]
        tick.pos <- c(0, pts / 4, pts / 2, pts / 4 * 3, pts)
        tick.lab <- as.character(c(-flanksize, -flanksize/2, mid.lab, 
            flanksize/2, flanksize))
    }else{
        left.lab <- Labs[1]
        right.lab <- Labs[2]
        tick.pos <- c(0, pts / 5, pts / 5 * 2, pts / 5 * 3, pts / 5 * 4, pts)
        if(lgint){  # large interval: fla int int int fla
            if(flankfactor > 0){  # show percentage at x-tick.
                tick.lab <- c(sprintf("%d%%", -flankfactor*100), 
                              left.lab, '33%', '66%', right.lab,
                              sprintf("%d%%", flankfactor*100))
            } else{  # show bps at x-tick.
                tick.lab <- c(as.character(-flanksize),
                              left.lab, '33%', '66%', right.lab,
                              as.character(flanksize))
            }
        } else {    # small interval: fla fla int fla fla.
            if(flankfactor > 0){
                tick.lab <- c(sprintf("%d%%", -flankfactor*100), 
                              sprintf("%d%%", -flankfactor*50), 
                              left.lab, right.lab,
                              sprintf("%d%%", flankfactor*50), 
                              sprintf("%d%%", flankfactor*100))
            } else {
                tick.lab <- c(as.character(-flanksize),
                              as.character(-flanksize/2),
                              left.lab, right.lab,
                              as.character(flanksize/2),
                              as.character(flanksize))
            }
        }
    }
    list(pos=tick.pos, lab=tick.lab)
}

plotmat <- function(regcovMat, title2plot, plot.colors, bam.pair, xticks, 
                    pts, m.pts, f.pts, pint, shade.alp=0, confiMat=NULL, mw=1, ymin, ymax, ylab, box_color,
                    misc.options=list(legend=T, box=T, vline=T, xylab=T, 
                                      line.wd=3)) {
# Plot avg. profiles and standard errors around them.
# Args:
#   regcovMat: matrix for avg. profiles.
#   title2plot: profile names, will be shown in figure legend.
#   plot.colors: vector of color specifications for all curves.
#   bam.pair: boolean for bam-pair data.
#   xticks: X-axis ticks.
#   pts: data points
#   m.pts: middle part data points
#   f.pts: flanking part data points
#   pint: tag for point interval
#   shade.alp: shading area alpha
#   confiMat: matrix for standard errors.
#   mw: moving window size for smoothing function.
#   misc.options: list of misc. options - legend, box around plot, 
#       verticle lines, X- and Y-axis labels, line width.

    # Smooth avg. profiles if specified.
    if(mw > 1){
        regcovMat <- as.matrix(runmean(regcovMat, k=mw, alg='C', 
                                       endrule='mean'))
    }

    # Choose colors.
    if(any(is.na(plot.colors))) {
        ncurve <- ncol(regcovMat)
        replicates <- 0
        if(length(which(grepl("Rep1", title2plot, ignore.case=T)==TRUE))>0 & length(which(grepl("Rep2", title2plot, ignore.case=T)==TRUE))>0) {
            replicates <- 1
        }
        cat(class(title2plot))

        if(ncurve <= 8 & replicates==1) {
            #col2use <- brewer.pal(8,'Dark2')
            #col2use <- c(col2use[1], col2use[5], col2use[2], col2use[6], col2use[3], col2use[8])
            col2use <- c("#FF0000", "#FF9900", "#00FF00", "#00ECA3", "#0000FF", "#3399FF", "#404040", "#847C6A");
        } else if(ncurve <= 8) {
            suppressMessages(require(RColorBrewer, warn.conflicts=F))
            col2use <- brewer.pal(ifelse(ncurve >= 3, ncurve, 3), 'Dark2')
            col2use <- col2use[1:ncurve]
        } else {
            col2use <- rainbow(ncurve)
        }
    } else {
        col2use <- plot.colors
    }
    col2use <- col2alpha(col2use, 0.8)

    # Plot profiles.
    ytext <- ifelse(bam.pair, "log2(Fold change vs. control)", sprintf("TPM (%s)", ylab))
    #ytext <- ifelse(bam.pair, "log2(Fold change vs. control)", "TPM")
    xrange <- 0:pts
    if(ymax != 0) {
        matplot(xrange, regcovMat, xaxt='n', type="l", col=col2use, lty="solid", lwd=misc.options$line.wd, frame.plot=F, ann=F, ylim=c(ymin,ymax))
    } else {
        matplot(xrange, regcovMat, xaxt='n', type="l", col=col2use, lty="solid", lwd=misc.options$line.wd, frame.plot=F, ann=F)
    }
    #matplot(xrange, regcovMat, xaxt='n', type="l", col=col2use, lty="solid", lwd=misc.options$line.wd, frame.plot=F, ann=F, ylim=c(0,(max(regcovMat)+0.05)))
    if(misc.options$xylab) {
        #title(xlab="Genomic Region (5' -> 3')", ylab=ytext)
        title(xlab="", ylab=ytext)
    }
    if(misc.options$box) {
        # box around plot.
        box(col=box_color, lwd=2)
        axis(1, at=xticks$pos, labels=xticks$lab, lwd=3, lwd.ticks=3)
    }

    # Add shade area.
    if(shade.alp > 0){
        for(i in 1:ncol(regcovMat)){
            v.x <- c(xrange[1], xrange, xrange[length(xrange)])
            v.y <- regcovMat[, i]
            v.y <- c(0, v.y, 0)
            col.rgb <- col2rgb(col2use[i])
            p.col <- rgb(col.rgb[1, 1], col.rgb[2, 1], col.rgb[3, 1], 
                         alpha=shade.alp * 255, maxColorValue=255)
            polygon(v.x, v.y, density=-1, border=NA, col=p.col)
        }
    }

    # Add standard errors.
    if(!is.null(confiMat)){
        v.x <- c(xrange, rev(xrange))
        for(i in 1:ncol(confiMat)){
            v.y <- c(regcovMat[, i] + confiMat[, i], 
                     rev(regcovMat[, i] - confiMat[, i]))
            col.rgb <- col2rgb(col2use[i])
            p.col <- rgb(col.rgb[1, 1], col.rgb[2, 1], col.rgb[3, 1], 
                         alpha=0.2 * 255, maxColorValue=255)
            polygon(v.x, v.y, density=-1, border=NA, col=p.col)
        }
    }

    if(misc.options$vline) {
        # Add gray lines indicating feature boundaries.
        if(pint) {
            abline(v=f.pts, col="gray", lwd=1, lty=2)
        } else {
            abline(v=f.pts - 1, col="gray", lwd=1, lty=2)
            abline(v=f.pts + m.pts - 2, col="gray", lwd=1, lty=2)
        }
    }

    if(misc.options$legend) {
        # Legend.
        legend("topright", title2plot, text.col=col2use)
    }
}

spline_mat <- function(mat, n=100){
# Calculate splined coverage for a matrix.
# Args:
#   mat: each column represents a profile to be interpolated.
#   n: number of data points to be interpolated.

    foreach(r=iter(mat, by='row'), 
        .combine='rbind', .multicombine=T) %dopar% {
        spline(1:length(r), r, n)$y
    }
}

OrderGenesHeatmap <- function(n, enrichCombined, 
                              method=c('total', 'max', 'prod', 'diff', 'hc', 
                                       'pca', 'none')) {
# Order genes in combined heatmap data.
# Args: 
#   n: number of plots(such as histone marks) in the combined data.
#   enrichCombined: combined heatmap data.
#   method: algorithm used to order genes.
# Return: list of vectors of gene orders. In case of PCA, it may return more 
#   than one vectors of gene orders. Otherwise, the list length is 1.

    npts <- ncol(enrichCombined) / n  # number of data points for each profile.
    
    if(method == 'hc') {  # hierarchical clustering
        # Filter genes with zero sd.
        g.sd <- apply(enrichCombined, 1, sd)
        g.nz <- which(g.sd > 0)
        g.ze <- which(g.sd == 0)
        enrichCombined <- enrichCombined[g.nz, ]
        # Clustering and order genes.
        hc <- hclust(as.dist(1-cor(t(enrichCombined))), method='complete')
        # Notes: do NOT forget hc is applied to non-zero sd genes only.
        # The original gene indices must be recovered before return values.
        list(hc=c(g.nz[hc$order], g.ze))
    } else if(method == 'total' || method == 'diff' && n == 1) {  
        # overall enrichment of the 1st profile.
        list(total=order(rowSums(enrichCombined[, 1:npts])))
    } else if(method == 'max') {  # peak enrichment value of the 1st profile.
        list(max=order(apply(enrichCombined[, 1:npts], 1, max)))
    } else if(method == 'prod') {  # product of all profiles.
        g.prod <- foreach(r=iter(enrichCombined, by='row'), .combine='c', 
                            .multicombine=T, .maxcombine=1000) %dopar% {
            foreach(i=icount(n),  # go through each profile.
                    .combine='prod', .multicombine=T) %do% {
                col.sta <- (i - 1) * npts + 1
                col.end <- i * npts
                sum(r[col.sta:col.end], na.rm=T)
            }
        }
        list(prod=order(g.prod))
    } else if(method == 'diff' && n > 1) {  # difference between 2 profiles.
        list(diff=order(rowSums(enrichCombined[, 1:npts]) - 
                        rowSums(enrichCombined[, (npts + 1):(npts * 2)])))
    } else if(method == 'pca') {  # principal component analysis.
        # Reduce the data to a small number of bins per profile.
        nbin <- 10
        enrich.reduced <- foreach(i=icount(n), .combine='cbind', 
                                .multicombine=T) %do% {
            # Go through each profile.
            col.sta <- (i - 1) * npts + 1
            col.end <- i * npts
            # Column breaks represent bin boundaries.
            col.breaks <- seq(col.sta, col.end, length.out=nbin + 1)
            foreach(j=icount(nbin), .combine='cbind', .multicombine=T) %dopar% {
                # Go through each bin.
                rowSums(enrichCombined[, col.breaks[j]:col.breaks[j + 1]])
            }
        }
        # Pull out all pc's that equal at least 10% variance of the 1st pc.
        enrich.pca <- prcomp(enrich.reduced, center=F, scale=F, tol=sqrt(.1))
        # Order genes according to each pc.
        pc.order <- foreach(i=icount(ncol(enrich.pca$x))) %dopar% {
            order(enrich.pca$x[, i])
        }
        names(pc.order) <- paste('pc', 1:ncol(enrich.pca$x), sep='')
        pc.order
    } else if(method == 'none') {  # according to the order of input gene list.
        # Because the image function draws from bottom to top, the rows are 
        # reversed to give a more natural look.
        list(none=rev(1:nrow(enrichCombined)))
    } else {
        # pass.
    }
}


plotheat <- function(reg.list, uniq.reg, enrichList, go.algo, title2plot, 
                     bam.pair, xticks, rm.zero=1, flood.q=.02, do.plot=T,
                     hm.color="default", color.scale='local') {
# Plot heatmaps with genes ordered according to some algorithm.
# Args:
#   reg.list: factor vector of regions as in configuration.
#   uniq.reg: character vector of unique regions.
#   enrichList: list of heatmap data.
#   go.algo: gene order algorithm.
#   title2plot: title for each heatmap. Same as the legends in avgprof.
#   bam.pair: boolean tag for bam-pair.
#   xticks: info for X-axis ticks.
#   rm.zero: tag for removing all zero profiles.
#   flood.q: flooding percentage.
#   do.plot: boolean tag for plotting heatmaps.
#   hm.color: string for heatmap colors.
#   scale: string for the method to adjust color scale.
# Returns: ordered gene names for each unique region as a list.

    # Setup basic parameters.
    ncolor <- 256
    if(bam.pair) {
        if(hm.color != "default") {
            two.colors <- unlist(strsplit(hm.color, ':'))
            enrich.palette <- colorRampPalette(c(two.colors[1], 'black', 
                                                 two.colors[2]), 
                                               bias=.6, interpolate='spline')
        } else {
            enrich.palette <- colorRampPalette(c('green', 'black', 'red'), 
                                               bias=.6, interpolate='spline')
        }
    } else {
        if(hm.color != "default") {
            enrich.palette <- colorRampPalette(c('snow', hm.color))
        } else {
            enrich.palette <- colorRampPalette(c('snow', 'red2'))    
        }
    }

    hm_cols <- ncol(enrichList[[1]])

    # Adjust X-axis tick position. In a heatmap, X-axis is [0, 1].
    # Assume xticks$pos is from 0 to N(>0).
    xticks$pos <- xticks$pos / tail(xticks$pos, n=1)  # scale to the same size.

    # Define a function to calculate color breaks.
    ColorBreaks <- function(max.e, min.e, bam.pair, ncolor) {
    # Args:
    #   max.e: maximum enrichment value to be mapped to color.
    #   min.e: minimum enrichment value to be mapped to color.
    #   bam.pair: boolean tag for bam-pair.
    #   ncolor: number of colors to use.
    # Returns: vector of color breaks.

        # If bam-pair is used, create breaks for positives and negatives 
        # separately. If log2 ratios are all positive or negative, use only 
        # half of the color space.
        if(bam.pair) {
            max.e <- ifelse(max.e > 0, max.e, 1)
            min.e <- ifelse(min.e < 0, min.e, -1)
            c(seq(min.e, 0, length.out=ncolor / 2 + 1),
              seq(0, max.e, length.out=ncolor / 2 + 1)[-1])
        } else {
            seq(min.e, max.e, length.out=ncolor + 1)
        }
    }

    if(grepl(",", color.scale)) {
        scale.pair <- unlist(strsplit(color.scale, ","))
        scale.min <- as.numeric(scale.pair[1])
        scale.max <- as.numeric(scale.pair[2])
        if(scale.min >= scale.max) {
            warning("Color scale min value is >= max value.\n")
        }
        flood.pts <- c(scale.min, scale.max)
        brk.use <- ColorBreaks(scale.max, scale.min, bam.pair, ncolor)
    }

    # If color scale is global, calculate breaks and quantile here.
    if(color.scale == 'global') {
        flood.pts <- quantile(c(enrichList, recursive=T), c(flood.q, 1-flood.q))
        brk.use <- ColorBreaks(flood.pts[2], flood.pts[1], bam.pair, ncolor)
    }

    # Go through each unique region. 
    # Do NOT use "dopar" in the "foreach" loops here because this will disturb
    # the image order.
    go.list <- vector('list', length=length(uniq.reg))
    names(go.list) <- uniq.reg
    for(i in 1:length(uniq.reg)) {
        ur <- uniq.reg[i]
        plist <- which(reg.list==ur)  # get indices in the config file.

        # Combine all profiles into one.
        enrichCombined <- do.call('cbind', enrichList[plist])

        # Remove profiles that are all zero. They may correspond to unmappable
        # genes.
        if(rm.zero) {
            enrichCombined <- enrichCombined[rowSums(enrichCombined) != 0, ]
        }

        # If color scale is region, calculate breaks and quantile here.
        if(color.scale == 'region') {
            flood.pts <- quantile(c(enrichCombined, recursive=T), 
                                  c(flood.q, 1-flood.q))
            brk.use <- ColorBreaks(flood.pts[2], flood.pts[1], bam.pair, ncolor)
        }

        # Order genes.
        if(nrow(enrichCombined) > 1) {
            g.order <- OrderGenesHeatmap(length(plist), enrichCombined, go.algo)
            enrichCombined <- enrichCombined[g.order[[1]], ]
        }
        # for now, just use the 1st gene order. p.s.: pca will provide more than
        # one orders.
        go.list[[i]] <- rev(rownames(enrichCombined))

        if(!do.plot) {
            next
        }
  
        # Go through each sample and do plot.
        for(j in 1:length(plist)) {
            pj <- plist[j]  # index in the original config.

            # Split combined profiles back into individual heatmaps.
            enrichList[[pj]] <- enrichCombined[, ((j-1)*hm_cols+1) : 
                                                 (j*hm_cols)]

            # If color scale is local, calculate breaks and quantiles here.
            if(color.scale == 'local') {
                flood.pts <- quantile(c(enrichList[[pj]], recursive=T), 
                                      c(flood.q, 1-flood.q))
                brk.use <- ColorBreaks(flood.pts[2], flood.pts[1], bam.pair, 
                                       ncolor)
            }

            # Flooding extreme values.
            enrichList[[pj]][ enrichList[[pj]] < flood.pts[1] ] <- flood.pts[1]
            enrichList[[pj]][ enrichList[[pj]] > flood.pts[2] ] <- flood.pts[2]

            # Draw colorkey.
            image(z=matrix(brk.use, ncol=1), col=enrich.palette(ncolor), 
                  breaks=brk.use, axes=F, useRaster=T, main='Colorkey')
            axis(1, at=seq(0, 1, length.out=5), 
                 labels=format(brk.use[seq(1, ncolor + 1, length.out=5)], 
                               digits=1), 
                 lwd=1, lwd.ticks=1)

            # Draw heatmap.
            image(z=t(enrichList[[pj]]), col=enrich.palette(ncolor), 
                  breaks=brk.use, axes=F, useRaster=T, main=title2plot[pj])

            axis(1, at=xticks$pos, labels=xticks$lab, lwd=1, lwd.ticks=1)
        }
    }
    go.list
}

trim <- function(x, p){
# Trim a numeric vector on both ends.
# Args:
#   x: numeric vector.
#   p: percentage of data to trim.
# Return: trimmed vector.

    low <- quantile(x, p)
    hig <- quantile(x, 1 - p)
    x[x > low & x < hig]
}

CalcSem <- function(x, rb=.05){ 
# Calculate standard error of mean for a numeric vector.
# Args:
#   x: numeric vector
#   rb: fraction of data to trim before calculating sem.
# Return: a scalar of the standard error of mean

    if(rb > 0){
        x <- trim(x, rb)
    }
    sem <- sd(x) / sqrt(length(x))
    ifelse(is.na(sem), 0, sem)
    # NOTE: this should be improved to handle exception that "sd" calculation 
    # emits errors.
}




## Leave for future reference.
#
# Set the antialiasing.
# type <- NULL
# if (capabilities()["aqua"]) {
#   type <- "quartz"
# } else if (capabilities()["cairo"]) {
#   type <- "cairo"
# } else if (capabilities()["X11"]) {
#   type <- "Xlib"
# }
# Set the output type based on capabilities.
# if (is.null(type)){
#   png(plot.name, width, height, pointsize=pointsize)

# } else {
#   png(plot.name, width, height, pointsize=pointsize, type=type)
# }
####################

sessionFile <- unlist(strsplit(opt$sessionFile, ","))
sessionFileDes <- unlist(strsplit(opt$sessionFileDes, ","))
if(!is.null(opt$regionCounts)) {
    regionCounts <- unlist(strsplit(opt$regionCounts, ","))
} else {
    regionCounts <- vector("list", length(sessionFileDes))
}

## determine maximum ylim
if(is.null(opt$yMax)) {
    ymax <- -100
    for(row in 1:length(sessionFile)) {
        load(sessionFile[row])
        if(max(regcovMat) > ymax) {
            if(!is.null(opt$logScale)) {
                ymax <- max(log(regcovMat))
            } else {
                ymax <- max(regcovMat)
            }
        }
    }
} else {
    ymax=as.numeric(opt$yMax)
}

if(is.null(opt$yMin)) {
    ymin <- 100
    for(row in 1:length(sessionFile)) {
        load(sessionFile[row])
        if(min(regcovMat) < ymin) {
            if(!is.null(opt$logScale)) {
                ymin <- min(log(regcovMat))
            } else {
                ymin <- min(regcovMat)
            }
        }
    }
} else {
    ymin=as.numeric(opt$yMin)
}

## plot the dynamics
pdf(opt$outPdfFile, height=length(sessionFile)*2)
for(row in 1:length(sessionFile)) {
    load(sessionFile[row])

    ## comment to set identical ylim for all plots
    if(ymax<=0) {
        ymax <- max(regcovMat)
    }

    if(!is.null(opt$plotOrder)) {
        plotOrder <- unlist(strsplit(opt$plotOrder, ","))
        if(row==1) {
            par(mfrow=c(length(sessionFile), length(plotOrder)))
        }
        for(col in 1:length(plotOrder)) {
            if('TRUE' %in% grepl(plotOrder[col], colnames(regcovMat))) {
                col_order <- grep(plotOrder[col], colnames(regcovMat))
                prof.misc$legend=F
                box_color <- ifelse(grepl(plotOrder[col], sessionFileDes[row]), "black", "white")
                if(!is.null(opt$tfProfile)) {
                    if(length(col_order) <= 4) {
                        color[col_order] <- c("#e7298a", "#1b9e77", "#e6ab02", "#7570b3")
                    } else {
                        color[col_order] <- NA
                    }
                    ## comment to see x-axis and box around the plots
                    prof.misc$box <- "FALSE"
                } else {
                    color[col_order] <- "#762a83"
                }
                if(!is.null(opt$logScale)) {
                    plotmat(log(regcovMat[,col_order]), plotOrder[col], color[col_order], bam.pair, xticks, pts, m.pts, f.pts, pint, shade.alp, as.matrix(confiMat[,col_order]), mw, ymin, ymax, regionCounts[row], box_color, prof.misc)
                } else {
                    plotmat(regcovMat[,col_order], plotOrder[col], color[col_order], bam.pair, xticks, pts, m.pts, f.pts, pint, shade.alp, as.matrix(confiMat[,col_order]), mw, ymin, ymax, regionCounts[row], box_color, prof.misc)
                }
            } else {
                plot.new()
            }
        }
    } else {
        if(row==1) {
            par(mfrow=c(length(sessionFile), ncol(regcovMat)))
        }
        for(col in 1:ncol(regcovMat)) {
            box_color <- "black"
            if(!is.null(opt$tfProfile)) {
                if(length(col_order) <= 4) {
                    color[col_order] <- c("#e7298a", "#1b9e77", "#e6ab02", "#7570b3")
                } else {
                    color[col_order] <- NA
                }
            } else {
                color[col_order] <- "#762a83"
            }

            if(!is.null(opt$logScale)) {
                plotmat(log(regcovMat[,col]), title[col], color[col], bam.pair, xticks, pts, m.pts, f.pts, pint, shade.alp, as.matrix(confiMat[,col]), mw, ymin, ymax, regionCounts[,col_order], box_color, prof.misc)
            } else {
                plotmat(regcovMat[,col], title[col], color[col], bam.pair, xticks, pts, m.pts, f.pts, pint, shade.alp, as.matrix(confiMat[,col]), mw, ymin, ymax, regionCounts[,col_order], box_color, prof.misc)
            }
        }
    }
}
dev.off()
q()
