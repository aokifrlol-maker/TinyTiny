package com.bella.tinytiny

import android.app.Activity
import android.content.Intent
import android.content.pm.ActivityInfo
import android.content.res.Configuration
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.view.TextureView
import android.view.ViewGroup
import android.webkit.CookieManager
import androidx.annotation.OptIn
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGesturesAfterLongPress
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.VerticalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowLeft
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.automirrored.filled.VolumeOff
import androidx.compose.material.icons.automirrored.filled.VolumeUp
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.VideoSize
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.cache.CacheDataSource
import androidx.media3.datasource.okhttp.OkHttpDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.ui.AspectRatioFrameLayout
import coil.compose.AsyncImage
import coil.request.ImageRequest
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.io.File

@OptIn(ExperimentalFoundationApi::class)
@Composable
fun FeedView(
    model: FeedModel,
    isVisible: Boolean,
    targetPostId: String? = null,
    onCurrentPostChanged: (String?) -> Unit = {},
    onOpenCategories: () -> Unit,
    onSelectSubreddit: (String) -> Unit,
    onSelectUser: (String) -> Unit,
    onSelectXUser: (String) -> Unit,
    onSelectIGUser: (String) -> Unit,
    onSelectRule34Tag: (String) -> Unit,
    onSelectOFCreator: (String, String) -> Unit,
    onConnectX: () -> Unit,
    onConnectIG: () -> Unit,
    onConnectReddit: () -> Unit = {}
) {
    val items by model.items.collectAsState()
    val isLoading by model.isLoading.collectAsState()
    val sort by model.sort.collectAsState()
    val src by model.source.collectAsState()
    val userData by UserStore.shared.data.collectAsState()
    val scope = rememberCoroutineScope()
    val haptic = LocalHapticFeedback.current

    var shareTarget by remember { mutableStateOf<Gif?>(null) }
    var dislikeToastMsg by remember { mutableStateOf<String?>(null) }
    var dislikeToastTag by remember { mutableStateOf<String?>(null) }
    var dislikeToastJob by remember { mutableStateOf<Job?>(null) }

    LaunchedEffect(src, items.isEmpty()) {
        if (items.isEmpty() && model.canLoadMore && !isLoading) {
            model.loadMore()
        }
    }

    if (items.isEmpty()) {
        FeedStateView(
            model = model,
            onOpenCategories = onOpenCategories,
            onConnectX = onConnectX,
            onConnectIG = onConnectIG,
            onConnectReddit = onConnectReddit
        )
        return
    }

    val showEndPage = !model.canLoadMore && !isLoading && !src.isList
    val totalPages = items.size + if (showEndPage) 1 else 0
    val initialPage = remember(src) {
        if (targetPostId != null) items.indexOfFirst { it.id == targetPostId }.coerceAtLeast(0) else 0
    }
    val pagerState = rememberPagerState(initialPage = initialPage.coerceAtMost((totalPages - 1).coerceAtLeast(0)), pageCount = { totalPages })
    var lastReportedPostId by remember(src) { mutableStateOf<String?>(null) }
    var activePostRef by remember(src) { mutableStateOf<Pair<Gif, Long>?>(null) }

    LaunchedEffect(targetPostId) {
        if (targetPostId != null && targetPostId != lastReportedPostId) {
            val idx = model.items.value.indexOfFirst { it.id == targetPostId }
            if (idx >= 0 && idx != pagerState.currentPage) {
                pagerState.scrollToPage(idx)
            }
        }
    }

    LaunchedEffect(pagerState, src) {
        snapshotFlow { pagerState.settledPage }.collect { page ->
            // Record dwell signal for the post we just scrolled away from
            activePostRef?.let { (prevGif, startedAt) ->
                val elapsedSec = (System.currentTimeMillis() - startedAt) / 1000.0
                if (elapsedSec > 0.25) {
                    UserStore.shared.recordDwellSignal(prevGif, elapsedSec)
                }
            }
            val current = model.items.value.getOrNull(page)
            if (current != null) {
                activePostRef = current to System.currentTimeMillis()
                lastReportedPostId = current.id
                onCurrentPostChanged(current.id)
                UserStore.shared.markSeen(current)
                val key = src.swipeKey
                UserStore.shared.recordSwipe(key.first, key.second, src.displayTitle, current.id)
                model.onItemAppear(current)
            } else {
                activePostRef = null
            }
        }
    }

    fun showToast(msg: String, tag: String? = null) {
        dislikeToastJob?.cancel()
        dislikeToastMsg = msg
        dislikeToastTag = tag
        dislikeToastJob = scope.launch {
            delay(3600)
            dislikeToastMsg = null
            dislikeToastTag = null
        }
    }

    Box(modifier = Modifier.fillMaxSize().background(Color.Black)) {
        VerticalPager(
            state = pagerState,
            key = { items.getOrNull(it)?.id ?: "end_of_feed" },
            beyondViewportPageCount = 1,
            modifier = Modifier.fillMaxSize()
        ) { pageIdx ->
            if (pageIdx >= items.size) {
                FeedStateView(
                    model = model,
                    isEndOfFeed = true,
                    onOpenCategories = onOpenCategories,
                    onConnectX = onConnectX,
                    onConnectIG = onConnectIG,
                    onConnectReddit = onConnectReddit
                )
            } else {
                val gif = items[pageIdx]
                val isCurrentPage = pagerState.currentPage == pageIdx
                val isActive = isVisible && isCurrentPage && shareTarget == null
                GoonedReelCell(
                    gif = gif,
                    isActive = isActive,
                    isCurrentPage = isCurrentPage,
                    sort = sort,
                    tinted = userData.settings.tintedGlass,
                    onSelectSort = { model.setSort(it) },
                    onShuffle = {
                        haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                        model.shuffleItems()
                        scope.launch { pagerState.scrollToPage(0) }
                    },
                    onOpenCategories = onOpenCategories,
                    onSelectSubreddit = onSelectSubreddit,
                    onSelectUser = onSelectUser,
                    onSelectXUser = onSelectXUser,
                    onSelectIGUser = onSelectIGUser,
                    onSelectRule34Tag = onSelectRule34Tag,
                    onSelectOFCreator = onSelectOFCreator,
                    onDislike = {
                        haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                        val outcome = UserStore.shared.dislike(gif)
                        model.removeDisliked(gif, purgeUpcomingOF = outcome.newlyHiddenGenders.isNotEmpty())
                        if (outcome.newlyHiddenGenders.isNotEmpty()) {
                            showToast("Blocked Men / Gay from feeds")
                        } else if (outcome.autoSuppressedTag != null) {
                            showToast("Hidden #${outcome.autoSuppressedTag} from discovery")
                        } else {
                            showToast("Not interested · Showing less like this", outcome.primaryTag)
                        }
                        // Live OnlyFans creator gender resolution if OF post
                        if (gif.isOnlyFansPost) {
                            scope.launch {
                                val creator = OnlyFansAPI.lookupCreator(gif.onlyFansCreatorId, gif.author)
                                if (creator != null) {
                                    val hidden = SmartTasteEngine.shared.applyCreatorDislikeResolution(creator)
                                    if (hidden.isNotEmpty()) {
                                        model.purgeSuppressedItems(afterCurrentID = gif.id, purgeUpcomingOF = true)
                                        showToast("Blocked Men / Gay from feeds")
                                    }
                                }
                            }
                        }
                        if (model.items.value.size - pageIdx < 10 && model.canLoadMore) {
                            scope.launch { model.loadMore() }
                        }
                    },
                    onShare = { shareTarget = gif },
                    onAutoScrollNext = {
                        val next = pageIdx + 1
                        if (next < items.size) {
                            scope.launch { pagerState.animateScrollToPage(next) }
                        }
                    }
                )
            }
        }

        // Animated Top Dislike Toast with quick "Hide #tag" button (exact iOS parity)
        AnimatedVisibility(
            visible = dislikeToastMsg != null,
            enter = fadeIn(),
            exit = fadeOut(),
            modifier = Modifier
                .align(Alignment.TopCenter)
                .statusBarsPadding()
                .padding(top = 98.dp, start = 16.dp, end = 16.dp)
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp),
                modifier = Modifier
                    .liquidGlassCapsule(tinted = true)
                    .padding(horizontal = 14.dp, vertical = 9.dp)
            ) {
                Text(
                    text = dislikeToastMsg ?: "",
                    color = Color.White,
                    fontSize = 12.sp,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f, fill = false)
                )
                dislikeToastTag?.let { tag ->
                    Box(
                        modifier = Modifier
                            .liquidGlassCapsule(tinted = false, active = true)
                            .clickable {
                                UserStore.shared.addBlockedTags(tag)
                                model.purgeSuppressedItems()
                                showToast("Blocked #$tag")
                            }
                            .padding(horizontal = 10.dp, vertical = 4.dp)
                    ) {
                        Text("Hide #$tag", color = Color.White, fontSize = 11.sp, fontWeight = FontWeight.Bold)
                    }
                }
            }
        }
    }

    shareTarget?.let { target ->
        ShareItemSheet(gif = target, onDismiss = { shareTarget = null })
    }
}

@OptIn(ExperimentalFoundationApi::class, UnstableApi::class)
@Composable
fun GoonedReelCell(
    gif: Gif,
    isActive: Boolean,
    isCurrentPage: Boolean = isActive,
    sort: FeedSort,
    tinted: Boolean,
    onSelectSort: (FeedSort) -> Unit,
    onShuffle: () -> Unit,
    onOpenCategories: () -> Unit,
    onSelectSubreddit: (String) -> Unit,
    onSelectUser: (String) -> Unit,
    onSelectXUser: (String) -> Unit,
    onSelectIGUser: (String) -> Unit,
    onSelectRule34Tag: (String) -> Unit,
    onSelectOFCreator: (String, String) -> Unit,
    onDislike: () -> Unit,
    onShare: () -> Unit,
    onAutoScrollNext: () -> Unit = {}
) {
    val ctx = LocalContext.current
    val activity = ctx as? Activity
    val config = LocalConfiguration.current
    val isLandscape = config.orientation == Configuration.ORIENTATION_LANDSCAPE
    val haptic = LocalHapticFeedback.current
    val scope = rememberCoroutineScope()
    val userData by UserStore.shared.data.collectAsState()
    val activeDownloads by OfflineManager.activeDownloads.collectAsState()
    val downloadProgressMap by OfflineManager.downloadProgress.collectAsState()
    val collapsed = userData.settings.controlsCollapsed || isLandscape

    var userPaused by remember(gif.id) { mutableStateOf(false) }
    var showHeart by remember(gif.id) { mutableStateOf(false) }
    var skipIndicator by remember(gif.id) { mutableStateOf<Int?>(null) }
    var isHolding by remember(gif.id) { mutableStateOf(false) }
    var speedLocked2x by remember(gif.id) { mutableStateOf(false) }
    var isScrubbing by remember(gif.id) { mutableStateOf(false) }
    var scrubStartSec by remember(gif.id) { mutableDoubleStateOf(0.0) }
    var scrubTargetSec by remember(gif.id) { mutableDoubleStateOf(0.0) }
    var scrubDurationSec by remember(gif.id) { mutableDoubleStateOf(1.0) }
    var scrubPreview by remember(gif.id) { mutableStateOf<Bitmap?>(null) }
    var showMoreSheet by remember(gif.id) { mutableStateOf(false) }
    var showSortMenu by remember(gif.id) { mutableStateOf(false) }

    var albumItems by remember(gif.id) { mutableStateOf(MediaMetaRegistry.albumItems(gif.id)) }
    var albumIndex by remember(gif.id) { mutableIntStateOf(0) }
    var resolvedUrls by remember(gif.id, userData.settings.hd) { mutableStateOf(gif.allVideoURLs(userData.settings.hd)) }
    var resolvingLongVideo by remember(gif.id) { mutableStateOf(false) }
    var urlIndex by remember(gif.id, albumIndex) { mutableIntStateOf(0) }
    var useReferer by remember(gif.id, albumIndex, urlIndex) { mutableStateOf(true) }
    var retryToken by remember(gif.id, albumIndex) { mutableIntStateOf(0) }
    var isBuffering by remember(gif.id, albumIndex) { mutableStateOf(false) }
    var isFirstFrameRendered by remember(gif.id, albumIndex, urlIndex, retryToken) { mutableStateOf(false) }
    var playbackFailed by remember(gif.id, albumIndex) { mutableStateOf(false) }
    var localFitOverride by remember(gif.id) { mutableStateOf<Boolean?>(null) }

    // Smart Fill Screen: only fill portrait videos (aspect < 0.68) by default so landscape videos aren't cropped
    val defaultFill = (userData.settings.fillScreen || !userData.settings.videoFitScreen) && (gif.knownAspect?.let { it < 0.68 } ?: true)
    val effectiveFill = localFitOverride ?: defaultFill

    val autoScrollState = rememberUpdatedState(userData.settings.autoScroll)
    val playToEndState = rememberUpdatedState(userData.settings.playVideosToEnd)
    val onAutoScrollNextState = rememberUpdatedState(onAutoScrollNext)

    LaunchedEffect(gif.id) {
        if (gif.isLongVideoPost && resolvedUrls.isEmpty()) {
            resolvingLongVideo = true
            val urls = LongVideoAPI.resolvePlayableURLs(gif)
            if (urls.isNotEmpty()) resolvedUrls = urls
            val album = MediaMetaRegistry.albumItems(gif.id)
            if (album.isNotEmpty()) albumItems = album
            resolvingLongVideo = false
        }
    }

    val currentAlbumItem = albumItems.getOrNull(albumIndex)
    val isShowingImage = currentAlbumItem?.let { !it.isVideo } ?: gif.isImage

    LaunchedEffect(isActive, gif.id, isShowingImage, userData.settings.autoScroll, userData.settings.autoScrollDelay, userData.settings.playVideosToEnd) {
        if (!isActive || !userData.settings.autoScroll) return@LaunchedEffect
        if (isShowingImage || !userData.settings.playVideosToEnd) {
            delay(maxOf(3, userData.settings.autoScrollDelay) * 1000L)
            if (isActive && !userPaused && !isScrubbing) onAutoScrollNextState.value()
        }
    }

    val activeDownloadGif = remember(gif.id, albumIndex, albumItems) {
        if (albumItems.size > 1 && currentAlbumItem != null) {
            gif.copy(
                id = "${gif.id}_slide_$albumIndex",
                mediaType = if (currentAlbumItem.isVideo) "video" else "image",
                mediaUrl = currentAlbumItem.url,
                muxedUrl = if (currentAlbumItem.isVideo) currentAlbumItem.url else null,
                muxedUrlHd = if (currentAlbumItem.isVideo) currentAlbumItem.url else null
            )
        } else gif
    }

    val activeVideoUrl = currentAlbumItem?.takeIf { it.isVideo }?.url ?: resolvedUrls.getOrNull(urlIndex)

    fun advanceOrFail() {
        if (useReferer && activeVideoUrl != null && !activeVideoUrl.startsWith("file://")) {
            // Pass 2: retry same URL without Referer header (fixes CDNs that reject Referer)
            useReferer = false
        } else if (urlIndex + 1 < resolvedUrls.size) {
            urlIndex += 1
            useReferer = true
        } else {
            playbackFailed = true
        }
    }

    // Build ExoPlayer keyed on isCurrentPage so Share/Settings/Tab switches pause instead of destroying & resetting to 0:00!
    val exoPlayer = remember(gif.id, activeVideoUrl, isCurrentPage, useReferer, retryToken) {
        if (!isCurrentPage || activeVideoUrl == null || isShowingImage) null
        else {
            playbackFailed = false
            isFirstFrameRendered = false
            val isLocal = activeVideoUrl.startsWith("file://")
            val dynamicClient = if (useReferer) SharedExoClients.withReferer else SharedExoClients.noReferer
            val okFactory = OkHttpDataSource.Factory(dynamicClient)
            val baseFactory = DefaultDataSource.Factory(ctx, okFactory)
            val dataSourceFactory = if (isLocal || activeVideoUrl.contains(".m3u8", ignoreCase = true)) {
                baseFactory
            } else {
                CacheDataSource.Factory()
                    .setCache(TinyTinyApplication.mediaSimpleCache)
                    .setUpstreamDataSourceFactory(baseFactory)
                    .setFlags(CacheDataSource.FLAG_IGNORE_CACHE_ON_ERROR)
            }

            val uri = Uri.parse(activeVideoUrl)
            val isHls = activeVideoUrl.lowercase().substringBefore('?').endsWith(".m3u8") ||
                activeVideoUrl.lowercase().contains("hlsplaylist.m3u8") ||
                activeVideoUrl.lowercase().contains("master.m3u8")
            val mediaItem = MediaItem.Builder()
                .setUri(uri)
                .apply { if (isHls) setMimeType(MimeTypes.APPLICATION_M3U8) }
                .build()

            val loadControl = androidx.media3.exoplayer.DefaultLoadControl.Builder()
                .setBufferDurationsMs(2_500, 15_000, 450, 1_000)
                .build()
            val audioAttrs = androidx.media3.common.AudioAttributes.Builder()
                .setUsage(androidx.media3.common.C.USAGE_MEDIA)
                .setContentType(androidx.media3.common.C.AUDIO_CONTENT_TYPE_MOVIE)
                .build()

            ExoPlayer.Builder(ctx)
                .setMediaSourceFactory(DefaultMediaSourceFactory(dataSourceFactory))
                .setLoadControl(loadControl)
                .setAudioAttributes(audioAttrs, true)
                .setHandleAudioBecomingNoisy(true)
                .build().apply {
                    repeatMode = if (autoScrollState.value && playToEndState.value) Player.REPEAT_MODE_OFF else Player.REPEAT_MODE_ONE
                    setMediaItem(mediaItem)
                    prepare()
                }
        }
    }

    // Decoupled DisposableEffect — ONLY keyed on exoPlayer so settings toggles NEVER release active player!
    DisposableEffect(exoPlayer) {
        val listener = if (exoPlayer != null) {
            object : Player.Listener {
                override fun onRenderedFirstFrame() {
                    isFirstFrameRendered = true
                    isBuffering = false
                    playbackFailed = false
                }

                override fun onVideoSizeChanged(videoSize: VideoSize) {
                    if (videoSize.width > 0 && videoSize.height > 0) {
                        playbackFailed = false
                    }
                }

                override fun onPlaybackStateChanged(playbackState: Int) {
                    isBuffering = playbackState == Player.STATE_BUFFERING
                    if (playbackState == Player.STATE_READY) playbackFailed = false
                    if (playbackState == Player.STATE_ENDED) {
                        UserStore.shared.recordLoopSignal(gif)
                        if (isActive && autoScrollState.value && playToEndState.value) {
                            onAutoScrollNextState.value()
                        }
                    }
                }

                override fun onPositionDiscontinuity(oldPosition: Player.PositionInfo, newPosition: Player.PositionInfo, reason: Int) {
                    if (reason == Player.DISCONTINUITY_REASON_AUTO_TRANSITION) {
                        UserStore.shared.recordLoopSignal(gif)
                    }
                }

                override fun onPlayerError(error: PlaybackException) {
                    isBuffering = false
                    advanceOrFail()
                }
            }.also { exoPlayer.addListener(it) }
        } else null
        onDispose {
            if (listener != null) exoPlayer?.removeListener(listener)
            exoPlayer?.release()
        }
    }

    // 4.8-second stall watchdog (exact iOS parity — prevents permanent blackscreen on hung streams)
    LaunchedEffect(exoPlayer, isActive, isFirstFrameRendered, userPaused, playbackFailed) {
        if (exoPlayer != null && isActive && !isFirstFrameRendered && !userPaused && !playbackFailed) {
            delay(4800)
            if (isActive && !isFirstFrameRendered && !userPaused && !playbackFailed) {
                advanceOrFail()
            }
        }
    }

    LaunchedEffect(exoPlayer, isActive, userPaused, isScrubbing, showMoreSheet, userData.settings.autoScroll, userData.settings.playVideosToEnd) {
        if (exoPlayer != null) {
            exoPlayer.repeatMode = if (userData.settings.autoScroll && userData.settings.playVideosToEnd) Player.REPEAT_MODE_OFF else Player.REPEAT_MODE_ONE
            exoPlayer.volume = if (userData.settings.muted) 0f else 1f
            exoPlayer.playWhenReady = isActive && !userPaused && !isScrubbing && !showMoreSheet
            exoPlayer.setPlaybackSpeed(if (isHolding || speedLocked2x) 2.0f else 1.0f)
        }
    }

    LaunchedEffect(exoPlayer, userData.settings.muted, isHolding, speedLocked2x) {
        if (exoPlayer != null) {
            exoPlayer.volume = if (userData.settings.muted) 0f else 1f
            exoPlayer.setPlaybackSpeed(if (isHolding || speedLocked2x) 2.0f else 1.0f)
        }
    }

    val durationSec = remember(gif.id, exoPlayer) { gif.duration ?: 1.0 }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black)
            .pointerInput(gif.id, isShowingImage, exoPlayer) {
                detectTapGestures(
                    onTap = {
                        if (speedLocked2x) {
                            speedLocked2x = false
                        } else if (!isShowingImage) {
                            userPaused = !userPaused
                        }
                    },
                    onDoubleTap = { offset ->
                        val w = size.width.toFloat().coerceAtLeast(1f)
                        when {
                            !isShowingImage && offset.x < w * 0.30f -> {
                                val step = if (gif.isLongVideoPost) 10 else 5
                                exoPlayer?.let { p -> p.seekTo((p.currentPosition - step * 1000L).coerceAtLeast(0L)) }
                                haptic.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                                skipIndicator = -step
                                scope.launch { delay(650); skipIndicator = null }
                            }
                            !isShowingImage && offset.x > w * 0.70f -> {
                                val step = if (gif.isLongVideoPost) 10 else 5
                                exoPlayer?.let { p -> p.seekTo((p.currentPosition + step * 1000L).coerceAtMost(p.duration.coerceAtLeast(0L))) }
                                haptic.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                                skipIndicator = step
                                scope.launch { delay(650); skipIndicator = null }
                            }
                            else -> {
                                haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                                UserStore.shared.like(gif)
                                showHeart = true
                                scope.launch { delay(750); showHeart = false }
                            }
                        }
                    }
                )
            }
            // CRITICAL FIX: include exoPlayer in pointerInput keys so pre-composed pages bind gestures once active!
            .pointerInput(gif.id, isShowingImage, activeVideoUrl, exoPlayer) {
                var totalDx = 0f
                var totalDy = 0f
                var scrubbing = false
                var lastPreviewAt = 0L
                var scrubPreviewJob: Job? = null
                detectDragGesturesAfterLongPress(
                    onDragStart = {
                        totalDx = 0f
                        totalDy = 0f
                        scrubbing = false
                        isHolding = true
                        haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                    },
                    onDrag = { change, dragAmount ->
                        change.consume()
                        totalDx += dragAmount.x
                        totalDy += dragAmount.y
                        if (!isShowingImage && exoPlayer != null) {
                            if (!scrubbing && kotlin.math.abs(totalDx) > 14f && kotlin.math.abs(totalDx) > kotlin.math.abs(totalDy)) {
                                scrubbing = true
                                isHolding = false
                                isScrubbing = true
                                val dur = (exoPlayer.duration.takeIf { it > 0 }?.div(1000.0) ?: durationSec).coerceAtLeast(1.0)
                                val cur = (exoPlayer.currentPosition / 1000.0).coerceIn(0.0, dur)
                                scrubDurationSec = dur
                                scrubStartSec = cur
                                scrubTargetSec = cur
                            } else if (!scrubbing && totalDy > 28f) {
                                speedLocked2x = true
                            }
                            if (scrubbing) {
                                val span = minOf(scrubDurationSec, 90.0)
                                val delta = (totalDx / size.width.toFloat().coerceAtLeast(1f)) * span
                                val target = (scrubStartSec + delta).coerceIn(0.0, scrubDurationSec)
                                scrubTargetSec = target
                                val now = System.currentTimeMillis()
                                if (now - lastPreviewAt > 140L && activeVideoUrl != null) {
                                    lastPreviewAt = now
                                    scrubPreviewJob?.cancel()
                                    scrubPreviewJob = scope.launch(Dispatchers.IO) {
                                        val bmp = fetchFramePreview(activeVideoUrl, target)
                                        if (bmp != null) scrubPreview = bmp
                                    }
                                }
                            }
                        }
                    },
                    onDragEnd = {
                        if (scrubbing && exoPlayer != null) {
                            exoPlayer.seekTo((scrubTargetSec * 1000.0).toLong())
                            isScrubbing = false
                            scrubPreview = null
                        }
                        isHolding = false
                    },
                    onDragCancel = {
                        isScrubbing = false
                        scrubPreview = null
                        isHolding = false
                    }
                )
            }
    ) {
        // Media Layer: Multi-slide Erome Album, Tall/Normal Image, or Poster + TextureView ExoPlayer
        if (albumItems.size > 1) {
            val hPager = rememberPagerState(pageCount = { albumItems.size })
            LaunchedEffect(hPager.currentPage) { albumIndex = hPager.currentPage }
            HorizontalPager(state = hPager, modifier = Modifier.fillMaxSize()) { idx ->
                val item = albumItems[idx]
                if (!item.isVideo) {
                    TallOrNormalImage(urls = listOfNotNull(item.url, item.posterUrl), fill = effectiveFill)
                } else if (exoPlayer != null && idx == albumIndex) {
                    Box(Modifier.fillMaxSize()) {
                        AsyncImage(
                            model = item.posterUrl ?: gif.posterURL,
                            contentDescription = null,
                            contentScale = if (effectiveFill) ContentScale.Crop else ContentScale.Fit,
                            modifier = Modifier.fillMaxSize()
                        )
                        ExoTextureSurface(
                            player = exoPlayer,
                            fill = effectiveFill,
                            visible = isFirstFrameRendered
                        )
                    }
                } else {
                    AsyncImage(
                        model = item.posterUrl ?: gif.posterURL,
                        contentDescription = null,
                        contentScale = if (effectiveFill) ContentScale.Crop else ContentScale.Fit,
                        modifier = Modifier.fillMaxSize()
                    )
                }
            }
            if (!collapsed) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    modifier = Modifier
                        .align(Alignment.TopCenter)
                        .statusBarsPadding()
                        .padding(top = 92.dp)
                        .liquidGlassCapsule(tinted = tinted)
                        .padding(horizontal = 8.dp, vertical = 4.dp)
                ) {
                    Icon(
                        Icons.AutoMirrored.Filled.KeyboardArrowLeft,
                        contentDescription = "Prev",
                        tint = if (albumIndex > 0) Color.White else Color.White.copy(0.3f),
                        modifier = Modifier.size(18.dp).clickable(enabled = albumIndex > 0) {
                            scope.launch { hPager.animateScrollToPage((albumIndex - 1).coerceAtLeast(0)) }
                        }
                    )
                    Text(
                        text = "${albumIndex + 1} / ${albumItems.size}",
                        color = Color.White,
                        fontSize = 11.5.sp,
                        fontWeight = FontWeight.Bold,
                        fontFamily = FontFamily.Monospace
                    )
                    Icon(
                        Icons.AutoMirrored.Filled.KeyboardArrowRight,
                        contentDescription = "Next",
                        tint = if (albumIndex < albumItems.lastIndex) Color.White else Color.White.copy(0.3f),
                        modifier = Modifier.size(18.dp).clickable(enabled = albumIndex < albumItems.lastIndex) {
                            scope.launch { hPager.animateScrollToPage((albumIndex + 1).coerceAtMost(albumItems.lastIndex)) }
                        }
                    )
                }
            }
        } else if (isShowingImage) {
            TallOrNormalImage(
                urls = currentAlbumItem?.let { listOf(it.url) } ?: gif.imageFallbackURLs,
                fill = effectiveFill,
                knownAspect = gif.knownAspect
            )
        } else {
            // Keep poster visible behind TextureView until onRenderedFirstFrame (ZERO black flash!)
            Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                AsyncImage(
                    model = gif.posterURL,
                    contentDescription = null,
                    contentScale = if (effectiveFill) ContentScale.Crop else ContentScale.Fit,
                    modifier = Modifier.fillMaxSize()
                )
                if (exoPlayer != null) {
                    ExoTextureSurface(
                        player = exoPlayer,
                        fill = effectiveFill,
                        visible = isFirstFrameRendered
                    )
                }
                if (resolvingLongVideo) {
                    CircularProgressIndicator(color = Theme.accentBright, modifier = Modifier.size(30.dp), strokeWidth = 2.5.dp)
                }
            }
        }

        // Buffering / Pause / Error Overlays
        if (!isShowingImage && isBuffering && !userPaused && !playbackFailed && !resolvingLongVideo) {
            CircularProgressIndicator(
                color = Theme.accentBright,
                strokeWidth = 2.5.dp,
                modifier = Modifier.align(Alignment.Center).size(34.dp)
            )
        } else if (!isShowingImage && userPaused && !isScrubbing) {
            Box(
                modifier = Modifier
                    .align(Alignment.Center)
                    .size(64.dp)
                    .liquidGlassCircle(tinted = true),
                contentAlignment = Alignment.Center
            ) {
                Icon(Icons.Default.PlayArrow, contentDescription = "Paused", tint = Color.White, modifier = Modifier.size(36.dp))
            }
        } else if (!isShowingImage && playbackFailed) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                modifier = Modifier
                    .align(Alignment.Center)
                    .liquidGlassCapsule(tinted = true)
                    .clickable {
                        playbackFailed = false
                        urlIndex = 0
                        useReferer = true
                        retryToken += 1
                    }
                    .padding(horizontal = 16.dp, vertical = 10.dp)
            ) {
                Icon(Icons.Default.Refresh, contentDescription = "Retry", tint = Theme.accentBright, modifier = Modifier.size(18.dp))
                Text("Tap to Retry Video", color = Color.White, fontSize = 13.sp, fontWeight = FontWeight.Bold)
            }
        }

        // Double-tap Heart animation (104dp spring scale+fade matching iOS)
        AnimatedVisibility(
            visible = showHeart,
            enter = scaleIn() + fadeIn(),
            exit = scaleOut() + fadeOut(),
            modifier = Modifier.align(Alignment.Center)
        ) {
            Icon(Icons.Default.Favorite, contentDescription = null, tint = Theme.accent, modifier = Modifier.size(104.dp))
        }

        // Skip indicator (±5s / ±10s with icon & animation)
        AnimatedVisibility(
            visible = skipIndicator != null,
            enter = scaleIn() + fadeIn(),
            exit = scaleOut() + fadeOut(),
            modifier = Modifier
                .align(if ((skipIndicator ?: 0) < 0) Alignment.CenterStart else Alignment.CenterEnd)
                .padding(horizontal = 36.dp)
        ) {
            val s = skipIndicator ?: 0
            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                modifier = Modifier
                    .clip(CircleShape)
                    .background(Color.Black.copy(0.60f))
                    .padding(16.dp)
            ) {
                Icon(
                    if (s < 0) Icons.Default.Replay10 else Icons.Default.Forward10,
                    contentDescription = null,
                    tint = Color.White,
                    modifier = Modifier.size(26.dp)
                )
                Text("${if (s > 0) "+" else ""}${s}s", color = Color.White, fontWeight = FontWeight.Bold, fontSize = 14.sp)
            }
        }

        // Top 2x Speed Pill
        if ((isHolding || speedLocked2x) && !isShowingImage && !isScrubbing) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(5.dp),
                modifier = Modifier
                    .align(Alignment.TopCenter)
                    .statusBarsPadding()
                    .padding(top = 64.dp)
                    .liquidGlassCapsule(tinted = true, active = speedLocked2x)
                    .padding(horizontal = 14.dp, vertical = 7.dp)
            ) {
                Icon(
                    if (speedLocked2x) Icons.Default.Lock else Icons.Default.FastForward,
                    contentDescription = null,
                    tint = Color.White,
                    modifier = Modifier.size(14.dp)
                )
                Text(
                    if (speedLocked2x) "2x Locked · Tap to Unlock" else "2x Speed · Pull down to lock",
                    color = Color.White,
                    fontSize = 12.sp,
                    fontWeight = FontWeight.Bold
                )
            }
        }

        // Scrub Preview HUD, Hold Details HUD, Expanded Controls, or Rich Collapsed Mode
        if (isScrubbing && !isShowingImage) {
            Column(
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .navigationBarsPadding()
                    .padding(bottom = 96.dp, start = 22.dp, end = 22.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                Column(
                    modifier = Modifier
                        .liquidGlassCard(cornerRadius = 18.dp, tinted = tinted)
                        .padding(10.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(6.dp)
                ) {
                    Box(
                        modifier = Modifier
                            .size(width = 112.dp, height = 156.dp)
                            .clip(RoundedCornerShape(12.dp))
                            .background(Color.Black.copy(0.65f))
                            .border(1.dp, Color.White.copy(0.35f), RoundedCornerShape(12.dp)),
                        contentAlignment = Alignment.Center
                    ) {
                        val bmp = scrubPreview
                        if (bmp != null) {
                            Image(bitmap = bmp.asImageBitmap(), contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
                        } else {
                            AsyncImage(model = gif.posterURL, contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
                        }
                    }
                    val delta = (scrubTargetSec - scrubStartSec).toInt()
                    val deltaStr = if (delta == 0) "" else if (delta > 0) "  +${delta}s" else "  ${delta}s"
                    Text(
                        text = "${formatTime(scrubTargetSec)} / ${formatTime(scrubDurationSec)}$deltaStr",
                        color = Color.White,
                        fontSize = 12.sp,
                        fontWeight = FontWeight.Bold,
                        fontFamily = FontFamily.Monospace
                    )
                }
                LinearProgressIndicator(
                    progress = { (scrubTargetSec / scrubDurationSec.coerceAtLeast(0.1)).toFloat().coerceIn(0f, 1f) },
                    color = Theme.accentBright,
                    trackColor = Color.White.copy(0.28f),
                    modifier = Modifier.fillMaxWidth().height(6.dp).clip(CircleShape)
                )
            }
        } else if (isHolding) {
            // Exact iOS Hold Details HUD (works on videos AND images!)
            Column(
                modifier = Modifier
                    .align(Alignment.BottomStart)
                    .fillMaxWidth()
                    .navigationBarsPadding()
                    .padding(horizontal = 18.dp, vertical = 96.dp)
                    .liquidGlassCard(20.dp, tinted)
                    .padding(14.dp),
                verticalArrangement = Arrangement.spacedBy(6.dp)
            ) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    gif.author?.let { author ->
                        Text(
                            text = "@$author",
                            color = Color.White,
                            fontSize = 15.sp,
                            fontWeight = FontWeight.Bold,
                            modifier = Modifier.clickable {
                                when {
                                    gif.isOnlyFansPost -> gif.onlyFansCreatorId?.let { onSelectOFCreator(it, author) }
                                    gif.isXPost -> onSelectXUser(author)
                                    gif.isIGPost -> onSelectIGUser(author)
                                    gif.isRule34Post -> onSelectRule34Tag(if (!author.equals("rule34", true)) "user:$author" else "")
                                    !gif.isLongVideoPost -> onSelectUser(author)
                                }
                            }
                        )
                    }
                    val srcName = gif.longVideoSiteLabel ?: when {
                        gif.isOnlyFansPost -> "OnlyFans"
                        gif.isXPost -> "𝕏"
                        gif.isIGPost -> "Instagram"
                        gif.isRule34Post -> "Rule34"
                        else -> gif.subreddit?.let { "r/$it" }
                    }
                    if (!srcName.isNullOrEmpty()) {
                        Text(srcName, color = Theme.accentBright, fontSize = 12.sp, fontWeight = FontWeight.Bold)
                    }
                    val rel = gif.relativeTime
                    if (rel.isNotEmpty()) Text("· $rel", color = Theme.textSecondary, fontSize = 12.sp)
                    if (OfflineManager.isDownloaded(activeDownloadGif)) {
                        Text("· Offline", color = Color(0xFF4ADE80), fontSize = 11.5.sp, fontWeight = FontWeight.Bold)
                    }
                }
                gif.title?.takeIf { it.isNotEmpty() }?.let {
                    Text(it, color = Color.White.copy(0.92f), fontSize = 13.sp)
                }
                val metaParts = listOfNotNull(
                    gif.upvotes?.takeIf { it > 0 }?.let { "${Gif.shortCount(it)} likes" },
                    if (!isShowingImage && (gif.duration ?: 0.0) > 1.0) formatTime(gif.duration!!) else null,
                    if ((gif.width ?: 0) > 0 && (gif.height ?: 0) > 0) "${gif.width}×${gif.height}" else null
                )
                if (metaParts.isNotEmpty()) {
                    Text(metaParts.joinToString(" · "), color = Theme.textSecondary, fontSize = 11.5.sp)
                }
            }
        } else if (!collapsed) {
            // Clean iOS Reel Overlay (no cluttered permanent bottom gradient/caption — clean controls + right rail + full-width scrubber)
            Column(
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .fillMaxWidth()
                    .navigationBarsPadding()
                    .padding(bottom = 82.dp)
            ) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(start = 16.dp, end = 12.dp, bottom = 8.dp),
                    verticalAlignment = Alignment.Bottom
                ) {
                    Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        // Long Video site + duration badge & Full Wide button
                        if (gif.isLongVideoPost) {
                            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                                val siteLbl = (gif.longVideoSiteLabel ?: "VIDEO").uppercase()
                                val durLbl = gif.duration?.takeIf { it > 1.0 }?.let { " · ${formatTime(it)}" } ?: ""
                                Text(
                                    text = "$siteLbl$durLbl",
                                    color = Color.White,
                                    fontSize = 11.sp,
                                    fontWeight = FontWeight.ExtraBold,
                                    modifier = Modifier
                                        .liquidGlassCapsule(tinted = true)
                                        .padding(horizontal = 10.dp, vertical = 5.dp)
                                )
                                Row(
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.spacedBy(4.dp),
                                    modifier = Modifier
                                        .liquidGlassCapsule(tinted = tinted)
                                        .clickable {
                                            activity?.requestedOrientation = if (isLandscape) {
                                                ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
                                            } else {
                                                ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
                                            }
                                        }
                                        .padding(horizontal = 10.dp, vertical = 5.dp)
                                ) {
                                    Icon(Icons.Default.ScreenRotation, contentDescription = null, tint = Color.White, modifier = Modifier.size(13.dp))
                                    Text(if (isLandscape) "Portrait" else "Full Wide", color = Color.White, fontSize = 11.sp, fontWeight = FontWeight.Bold)
                                }
                            }
                        }

                        // Row 1: [Sort Dropdown] [Fit/Fill] [Collapse] (sleek iOS sizing)
                        Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
                            Box {
                                Row(
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.spacedBy(4.dp),
                                    modifier = Modifier
                                        .liquidGlassCapsule(tinted)
                                        .clickable { showSortMenu = true }
                                        .padding(horizontal = 10.dp, vertical = 5.dp)
                                ) {
                                    Icon(
                                        imageVector = when (sort) {
                                            FeedSort.HOT -> Icons.Default.LocalFireDepartment
                                            FeedSort.NEW -> Icons.Default.AutoAwesome
                                            FeedSort.TOP -> Icons.Default.EmojiEvents
                                        },
                                        contentDescription = null,
                                        tint = Color.White,
                                        modifier = Modifier.size(13.dp)
                                    )
                                    Text(sort.label, color = Color.White, fontSize = 11.5.sp, fontWeight = FontWeight.Bold)
                                }
                                DropdownMenu(expanded = showSortMenu, onDismissRequest = { showSortMenu = false }) {
                                    FeedSort.entries.forEach { opt ->
                                        DropdownMenuItem(
                                            text = { Text(opt.label) },
                                            onClick = { showSortMenu = false; onSelectSort(opt) }
                                        )
                                    }
                                }
                            }
                            IconButton(
                                onClick = { localFitOverride = !effectiveFill },
                                modifier = Modifier.size(32.dp).liquidGlassCircle(tinted, active = effectiveFill)
                            ) {
                                Icon(
                                    if (effectiveFill) Icons.Default.FullscreenExit else Icons.Default.Fullscreen,
                                    contentDescription = "Fit/Fill",
                                    tint = Color.White,
                                    modifier = Modifier.size(15.dp)
                                )
                            }
                            IconButton(
                                onClick = { UserStore.shared.updateSettings { it.copy(controlsCollapsed = true) } },
                                modifier = Modifier.size(32.dp).liquidGlassCircle(tinted)
                            ) {
                                Icon(Icons.Default.KeyboardArrowDown, contentDescription = "Collapse", tint = Color.White, modifier = Modifier.size(16.dp))
                            }
                        }

                        // Row 2: [Browse] [Shuffle] [Auto-Scroll] [Quick Follow +] (compact 34dp iOS circles)
                        Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
                            IconButton(onClick = onOpenCategories, modifier = Modifier.size(34.dp).liquidGlassCircle(tinted)) {
                                Icon(Icons.Default.GridView, contentDescription = "Browse", tint = Color.White, modifier = Modifier.size(16.dp))
                            }
                            IconButton(onClick = onShuffle, modifier = Modifier.size(34.dp).liquidGlassCircle(tinted)) {
                                Icon(Icons.Default.Shuffle, contentDescription = "Shuffle", tint = Color.White, modifier = Modifier.size(16.dp))
                            }
                            IconButton(
                                onClick = { UserStore.shared.updateSettings { it.copy(autoScroll = !it.autoScroll) } },
                                modifier = Modifier.size(34.dp).liquidGlassCircle(tinted, active = userData.settings.autoScroll)
                            ) {
                                Icon(Icons.Default.KeyboardDoubleArrowDown, contentDescription = "Auto-Scroll", tint = Color.White, modifier = Modifier.size(16.dp))
                            }
                            val canFollow = !gif.author.isNullOrEmpty() || !gif.subreddit.isNullOrEmpty() || !gif.onlyFansCreatorId.isNullOrEmpty()
                            if (canFollow) {
                                val ofKey = gif.onlyFansCreatorId ?: gif.author
                                val isFollowed = when {
                                    gif.isOnlyFansPost -> ofKey?.let { UserStore.shared.isFollowingOFCreator(it, gif.author ?: it) } == true
                                    gif.isXPost -> gif.author?.let { UserStore.shared.isFollowingXUser(it) } == true
                                    gif.isIGPost -> gif.author?.let { UserStore.shared.isFollowingIGUser(it) } == true
                                    !gif.subreddit.isNullOrEmpty() -> UserStore.shared.isFollowingSubreddit(gif.subreddit!!)
                                    else -> gif.author?.let { UserStore.shared.isFollowingUser(it) } == true
                                }
                                IconButton(
                                    onClick = {
                                        haptic.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                                        when {
                                            gif.isOnlyFansPost -> ofKey?.let { UserStore.shared.toggleFollowOFCreator(it, gif.author ?: it, null) }
                                            gif.isXPost -> gif.author?.let { UserStore.shared.toggleFollowXUser(it) }
                                            gif.isIGPost -> gif.author?.let { UserStore.shared.toggleFollowIGUser(it) }
                                            !gif.subreddit.isNullOrEmpty() -> UserStore.shared.toggleFollowSubreddit(gif.subreddit!!)
                                            else -> gif.author?.let { UserStore.shared.toggleFollowUser(it) }
                                        }
                                    },
                                    modifier = Modifier.size(34.dp).liquidGlassCircle(tinted, active = isFollowed)
                                ) {
                                    Icon(if (isFollowed) Icons.Default.Check else Icons.Default.Add, contentDescription = "Follow", tint = Color.White, modifier = Modifier.size(16.dp))
                                }
                            }
                        }
                    }

                    Spacer(Modifier.width(10.dp))

                    // Right Action Rail (compact iOS proportions: 36dp avatar, 38dp buttons, 18dp icons)
                    Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(7.dp)) {
                        Box(
                            modifier = Modifier.clickable {
                                when {
                                    gif.isOnlyFansPost -> (gif.onlyFansCreatorId ?: gif.author)?.let { onSelectOFCreator(it, gif.author ?: it) }
                                    gif.isXPost -> gif.author?.let { onSelectXUser(it) }
                                    gif.isIGPost -> gif.author?.let { onSelectIGUser(it) }
                                    gif.isRule34Post -> {
                                        val u = gif.author
                                        onSelectRule34Tag(if (!u.isNullOrEmpty() && !u.equals("rule34", true)) "user:$u" else "")
                                    }
                                    gif.isLongVideoPost -> showMoreSheet = true
                                    gif.subreddit != null -> onSelectSubreddit(gif.subreddit!!)
                                    gif.author != null -> onSelectUser(gif.author!!)
                                }
                            }
                        ) {
                            when {
                                gif.isRule34Post -> BrandLogoRule34(36.dp)
                                gif.isXPost -> BrandLogoX(36.dp)
                                gif.isIGPost -> BrandLogoInstagram(36.dp)
                                gif.isOnlyFansPost -> BrandLogoOnlyFans(36.dp)
                                gif.isLongVideoPost -> BrandLogoLongVideos(36.dp)
                                else -> Box(Modifier.size(36.dp).clip(CircleShape).background(Color(0xFFF078A0)), contentAlignment = Alignment.Center) {
                                    Text("r/", color = Color.Black, fontWeight = FontWeight.Black, fontSize = 13.sp)
                                }
                            }
                        }

                        val liked = UserStore.shared.isLiked(gif)
                        Column(horizontalAlignment = Alignment.CenterHorizontally) {
                            IconButton(
                                onClick = {
                                    haptic.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                                    UserStore.shared.toggleLike(gif)
                                },
                                modifier = Modifier.size(38.dp).liquidGlassCircle(tinted)
                            ) {
                                Icon(Icons.Default.Favorite, contentDescription = "Like", tint = if (liked) Theme.accent else Color.White, modifier = Modifier.size(19.dp))
                            }
                            val baseUp = gif.upvotes ?: 0
                            val displayUp = baseUp + if (liked) 1 else 0
                            if (displayUp > 0) {
                                Text(Gif.shortCount(displayUp), color = Color.White, fontSize = 10.sp, fontWeight = FontWeight.Bold)
                            }
                        }
                        IconButton(onClick = onDislike, modifier = Modifier.size(38.dp).liquidGlassCircle(tinted)) {
                            Icon(Icons.Default.ThumbDown, contentDescription = "Dislike", tint = Color.White, modifier = Modifier.size(18.dp))
                        }
                        Column(horizontalAlignment = Alignment.CenterHorizontally) {
                            IconButton(
                                onClick = { UserStore.shared.updateSettings { it.copy(muted = !it.muted) } },
                                modifier = Modifier.size(38.dp).liquidGlassCircle(tinted)
                            ) {
                                Icon(
                                    if (userData.settings.muted) Icons.AutoMirrored.Filled.VolumeOff else Icons.AutoMirrored.Filled.VolumeUp,
                                    contentDescription = "Sound",
                                    tint = Color.White,
                                    modifier = Modifier.size(18.dp)
                                )
                            }
                            Text(
                                if (userData.settings.muted) "Muted" else "Sound",
                                color = Color.White,
                                fontSize = 9.5.sp,
                                fontWeight = FontWeight.SemiBold
                            )
                        }
                        val downloaded = OfflineManager.isDownloaded(activeDownloadGif)
                        val downloading = activeDownloadGif.id in activeDownloads
                        val dlFrac = downloadProgressMap[activeDownloadGif.id]?.toFloat()
                        IconButton(
                            onClick = { OfflineManager.toggleDownload(activeDownloadGif) },
                            modifier = Modifier.size(38.dp).liquidGlassCircle(tinted, active = downloaded)
                        ) {
                            if (downloading) {
                                if (dlFrac != null) {
                                    CircularProgressIndicator(
                                        progress = { dlFrac },
                                        color = Theme.accentBright,
                                        trackColor = Color.White.copy(0.25f),
                                        modifier = Modifier.size(20.dp),
                                        strokeWidth = 2.dp
                                    )
                                } else {
                                    CircularProgressIndicator(color = Theme.accentBright, modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
                                }
                            } else {
                                Icon(
                                    if (downloaded) Icons.Default.CheckCircle else Icons.Default.Download,
                                    contentDescription = "Download",
                                    tint = Color.White,
                                    modifier = Modifier.size(18.dp)
                                )
                            }
                        }
                        IconButton(onClick = onShare, modifier = Modifier.size(38.dp).liquidGlassCircle(tinted)) {
                            Icon(Icons.Default.Send, contentDescription = "Share", tint = Color.White, modifier = Modifier.size(18.dp))
                        }
                        IconButton(onClick = { showMoreSheet = true }, modifier = Modifier.size(38.dp).liquidGlassCircle(tinted)) {
                            Icon(Icons.Default.MoreHoriz, contentDescription = "More", tint = Color.White, modifier = Modifier.size(19.dp))
                        }
                    }
                }

                // Isolated full-width PlayerScrubberBar (ZERO 4Hz full-cell recomposition!)
                if (!isShowingImage && exoPlayer != null) {
                    PlayerScrubberBar(player = exoPlayer, isActive = isActive)
                }
            }
        } else {
            // Rich Collapsed / Zen Mode (exact iOS parity: ^ Controls + Full Wide + Quick Download/Like/Mute + Scrubber)
            Column(
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .fillMaxWidth()
                    .navigationBarsPadding()
                    .padding(horizontal = 16.dp, vertical = 14.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(4.dp),
                        modifier = Modifier
                            .liquidGlassCapsule(tinted)
                            .clickable {
                                if (isLandscape) {
                                    activity?.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
                                }
                                UserStore.shared.updateSettings { it.copy(controlsCollapsed = false) }
                            }
                            .padding(horizontal = 12.dp, vertical = 7.dp)
                    ) {
                        Icon(Icons.Default.KeyboardArrowUp, contentDescription = null, tint = Color.White, modifier = Modifier.size(16.dp))
                        Text("Controls", color = Color.White, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
                    }
                    if (gif.isLongVideoPost || isLandscape) {
                        Spacer(Modifier.width(8.dp))
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(4.dp),
                            modifier = Modifier
                                .liquidGlassCapsule(tinted)
                                .clickable {
                                    activity?.requestedOrientation = if (isLandscape) {
                                        ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
                                    } else {
                                        ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
                                    }
                                }
                                .padding(horizontal = 10.dp, vertical = 7.dp)
                        ) {
                            Icon(Icons.Default.ScreenRotation, contentDescription = null, tint = Color.White, modifier = Modifier.size(14.dp))
                            Text(if (isLandscape) "Portrait" else "Full Wide", color = Color.White, fontSize = 11.5.sp, fontWeight = FontWeight.Bold)
                        }
                    }
                    Spacer(Modifier.weight(1f))
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        val downloaded = OfflineManager.isDownloaded(activeDownloadGif)
                        IconButton(
                            onClick = { OfflineManager.toggleDownload(activeDownloadGif) },
                            modifier = Modifier.size(36.dp).liquidGlassCircle(tinted, active = downloaded)
                        ) {
                            Icon(if (downloaded) Icons.Default.CheckCircle else Icons.Default.Download, contentDescription = "Download", tint = Color.White, modifier = Modifier.size(17.dp))
                        }
                        val liked = UserStore.shared.isLiked(gif)
                        IconButton(
                            onClick = { UserStore.shared.toggleLike(gif) },
                            modifier = Modifier.size(36.dp).liquidGlassCircle(tinted)
                        ) {
                            Icon(Icons.Default.Favorite, contentDescription = "Like", tint = if (liked) Theme.accent else Color.White, modifier = Modifier.size(17.dp))
                        }
                        IconButton(
                            onClick = { UserStore.shared.updateSettings { it.copy(muted = !it.muted) } },
                            modifier = Modifier.size(36.dp).liquidGlassCircle(tinted)
                        ) {
                            Icon(
                                if (userData.settings.muted) Icons.AutoMirrored.Filled.VolumeOff else Icons.AutoMirrored.Filled.VolumeUp,
                                contentDescription = "Sound",
                                tint = Color.White,
                                modifier = Modifier.size(17.dp)
                            )
                        }
                    }
                }
                if (!isShowingImage && exoPlayer != null) {
                    PlayerScrubberBar(player = exoPlayer, isActive = isActive)
                }
            }
        }
    }

    if (showMoreSheet) {
        PostMoreSheet(
            gif = gif,
            activeDownloadGif = activeDownloadGif,
            onSelectRule34Tag = { tag -> showMoreSheet = false; onSelectRule34Tag(tag) },
            onSelectSubreddit = { s -> showMoreSheet = false; onSelectSubreddit(s) },
            onSelectUser = { u -> showMoreSheet = false; onSelectUser(u) },
            onSelectXUser = { u -> showMoreSheet = false; onSelectXUser(u) },
            onSelectIGUser = { u -> showMoreSheet = false; onSelectIGUser(u) },
            onSelectOFCreator = { id, h -> showMoreSheet = false; onSelectOFCreator(id, h) },
            onDislike = { showMoreSheet = false; onDislike() },
            onShare = { showMoreSheet = false; onShare() },
            onDismiss = { showMoreSheet = false }
        )
    }
}

/**
 * Isolated full-width video scrubber bar so 4Hz position polling NEVER recomposes GoonedReelCell!
 */
@Composable
private fun PlayerScrubberBar(player: ExoPlayer, isActive: Boolean) {
    var currentSec by remember(player) { mutableDoubleStateOf(0.0) }
    var durationSec by remember(player) { mutableDoubleStateOf(1.0) }
    var isDragging by remember(player) { mutableStateOf(false) }

    LaunchedEffect(player, isActive) {
        while (isActive) {
            if (!isDragging) {
                val dur = player.duration
                if (dur > 0) durationSec = dur / 1000.0
                currentSec = (player.currentPosition / 1000.0).coerceIn(0.0, durationSec)
            }
            delay(250)
        }
    }

    if (durationSec <= 0.5) return

    Column(modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp)) {
        if (isDragging) {
            Text(
                text = "${formatTime(currentSec)} / ${formatTime(durationSec)}",
                color = Color.White,
                fontSize = 11.5.sp,
                fontWeight = FontWeight.Bold,
                fontFamily = FontFamily.Monospace,
                modifier = Modifier
                    .align(Alignment.CenterHorizontally)
                    .liquidGlassCapsule(tinted = true)
                    .padding(horizontal = 10.dp, vertical = 4.dp)
            )
            Spacer(Modifier.height(4.dp))
        }
        Slider(
            value = (currentSec / durationSec).toFloat().coerceIn(0f, 1f),
            onValueChange = { frac ->
                isDragging = true
                currentSec = frac * durationSec
            },
            onValueChangeFinished = {
                player.seekTo((currentSec * 1000.0).toLong())
                isDragging = false
            },
            colors = SliderDefaults.colors(
                thumbColor = Color.White,
                activeTrackColor = Theme.accentBright,
                inactiveTrackColor = Color.White.copy(0.25f)
            ),
            modifier = Modifier.fillMaxWidth().height(20.dp)
        )
    }
}

/**
 * TextureView-backed ExoPlayer surface inside AspectRatioFrameLayout.
 * Eliminates SurfaceView black-frame & detached-surface glitches inside Compose VerticalPager!
 */
private object SharedExoClients {
    val withReferer: okhttp3.OkHttpClient by lazy { buildClient(true) }
    val noReferer: okhttp3.OkHttpClient by lazy { buildClient(false) }

    private fun buildClient(includeReferer: Boolean): okhttp3.OkHttpClient =
        TinyTinyApplication.sharedHttpClient.newBuilder()
            .addInterceptor { chain ->
                val req = chain.request()
                val uStr = req.url.toString()
                val rb = req.newBuilder()
                for ((k, v) in MediaHeaders.headers(uStr, includeReferer = includeReferer)) {
                    rb.header(k, v)
                }
                try {
                    val cookies = CookieManager.getInstance().getCookie(uStr)
                    if (!cookies.isNullOrEmpty()) rb.header("Cookie", cookies)
                } catch (_: Throwable) {}
                chain.proceed(rb.build())
            }
            .build()
}

@OptIn(UnstableApi::class)
@Composable
private fun ExoTextureSurface(player: ExoPlayer, fill: Boolean, visible: Boolean) {
    key(player) {
        AndroidView(
            factory = { ctx ->
                val container = AspectRatioFrameLayout(ctx).apply {
                    layoutParams = ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
                    resizeMode = if (fill) AspectRatioFrameLayout.RESIZE_MODE_ZOOM else AspectRatioFrameLayout.RESIZE_MODE_FIT
                }
                val tv = TextureView(ctx).apply {
                    layoutParams = ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
                }
                container.addView(tv)
                player.setVideoTextureView(tv)
                val listener = object : Player.Listener {
                    override fun onVideoSizeChanged(videoSize: VideoSize) {
                        if (videoSize.width > 0 && videoSize.height > 0) {
                            container.setAspectRatio((videoSize.width.toFloat() * videoSize.pixelWidthHeightRatio) / videoSize.height.toFloat())
                        }
                    }
                }
                player.addListener(listener)
                container.tag = tv to listener
                container
            },
            update = { container ->
                container.resizeMode = if (fill) AspectRatioFrameLayout.RESIZE_MODE_ZOOM else AspectRatioFrameLayout.RESIZE_MODE_FIT
            },
            onRelease = { container ->
                @Suppress("UNCHECKED_CAST")
                val pair = container.tag as? Pair<TextureView, Player.Listener>
                if (pair != null) {
                    player.removeListener(pair.second)
                    player.clearVideoTextureView(pair.first)
                }
            },
            modifier = Modifier
                .fillMaxSize()
                .alpha(if (visible) 1f else 0f)
        )
    }
}

@Composable
private fun TallOrNormalImage(urls: List<String>, fill: Boolean, knownAspect: Double? = null) {
    val ctx = LocalContext.current
    var idx by remember(urls) { mutableIntStateOf(0) }
    var failed by remember(urls) { mutableStateOf(false) }
    val activeUrl = urls.getOrNull(idx)
    val isTall = knownAspect != null && knownAspect > 0.0 && (1.0 / knownAspect) > 1.35

    if (failed || activeUrl == null) {
        Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                modifier = Modifier
                    .liquidGlassCapsule(tinted = true)
                    .clickable { idx = 0; failed = false }
                    .padding(horizontal = 16.dp, vertical = 10.dp)
            ) {
                Icon(Icons.Default.BrokenImage, contentDescription = null, tint = Theme.accentBright, modifier = Modifier.size(18.dp))
                Text("Tap to retry", color = Color.White, fontSize = 13.sp, fontWeight = FontWeight.Bold)
            }
        }
        return
    }

    val request = remember(activeUrl) {
        val rb = ImageRequest.Builder(ctx).data(activeUrl).crossfade(true)
        for ((k, v) in MediaHeaders.headers(activeUrl)) rb.addHeader(k, v)
        rb.build()
    }

    if (isTall && !fill) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState()),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            AsyncImage(
                model = request,
                contentDescription = null,
                contentScale = ContentScale.FillWidth,
                onError = {
                    if (idx + 1 < urls.size) idx += 1 else failed = true
                },
                modifier = Modifier.fillMaxWidth()
            )
        }
    } else {
        Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            AsyncImage(
                model = request,
                contentDescription = null,
                contentScale = if (fill) ContentScale.Crop else ContentScale.Fit,
                onError = {
                    if (idx + 1 < urls.size) idx += 1 else failed = true
                },
                modifier = Modifier.fillMaxSize()
            )
        }
    }
}

@Composable
fun FeedStateView(
    model: FeedModel,
    isEndOfFeed: Boolean = false,
    onOpenCategories: () -> Unit,
    onConnectX: () -> Unit,
    onConnectIG: () -> Unit,
    onConnectReddit: () -> Unit = {}
) {
    val isLoading by model.isLoading.collectAsState()
    val errorText by model.errorText.collectAsState()
    val src by model.source.collectAsState()
    val scope = rememberCoroutineScope()

    LaunchedEffect(isEndOfFeed) {
        if (isEndOfFeed && model.canLoadMore && !isLoading) model.loadMore()
    }

    Box(modifier = Modifier.fillMaxSize().background(Color.Black), contentAlignment = Alignment.Center) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(14.dp),
            modifier = Modifier.padding(28.dp)
        ) {
            if (isLoading) {
                CircularProgressIndicator(color = Theme.accentBright)
                Text("Loading ${src.displayTitle}...", color = Theme.textSecondary, fontSize = 13.sp)
            } else if (isEndOfFeed) {
                Icon(Icons.Default.Autorenew, contentDescription = null, tint = Theme.accentBright, modifier = Modifier.size(40.dp))
                Text("Rotate More Videos", color = Color.White, fontSize = 19.sp, fontWeight = FontWeight.Bold)
                Text("You've reached the end of this batch.", color = Theme.textSecondary, fontSize = 13.sp)
                Button(
                    onClick = { scope.launch { model.refresh(rotateCursor = true) } },
                    colors = ButtonDefaults.buttonColors(containerColor = Theme.accent),
                    shape = RoundedCornerShape(999.dp)
                ) {
                    Text("Load Fresh Batch", fontWeight = FontWeight.Bold)
                }
            } else if (src.isXFeed && !UserStore.shared.data.value.xSession.isConnected) {
                BrandLogoX(42.dp)
                Text("Connect Personal 𝕏", color = Color.White, fontSize = 20.sp, fontWeight = FontWeight.Bold)
                Text("Sign in once to stream your 𝕏 For You, Following, and Bookmarks.", color = Theme.textSecondary, fontSize = 13.sp, textAlign = TextAlign.Center)
                Button(onClick = onConnectX, colors = ButtonDefaults.buttonColors(containerColor = Theme.accent), shape = RoundedCornerShape(999.dp)) {
                    Text("Sign in with 𝕏", fontWeight = FontWeight.Bold)
                }
            } else if (src.isIGFeed && !UserStore.shared.data.value.igSession.isConnected) {
                BrandLogoInstagram(44.dp)
                Text("Connect Personal Instagram", color = Color.White, fontSize = 20.sp, fontWeight = FontWeight.Bold)
                Text("Sign in once to stream IG Reels, Following, and Saved clips.", color = Theme.textSecondary, fontSize = 13.sp, textAlign = TextAlign.Center)
                Button(onClick = onConnectIG, colors = ButtonDefaults.buttonColors(containerColor = Theme.accent), shape = RoundedCornerShape(999.dp)) {
                    Text("Sign in with Instagram", fontWeight = FontWeight.Bold)
                }
            } else if (src.isRedditPersonalFeed && !UserStore.shared.data.value.redditSession.isConnected) {
                BrandLogoReddit(44.dp)
                Text("Connect Personal Reddit", color = Color.White, fontSize = 20.sp, fontWeight = FontWeight.Bold)
                Text("Sign in once to browse your personal Reddit Home, Popular, Saved & Upvoted feeds without affecting your regular For You.", color = Theme.textSecondary, fontSize = 13.sp, textAlign = TextAlign.Center)
                Button(onClick = onConnectReddit, colors = ButtonDefaults.buttonColors(containerColor = Theme.accent), shape = RoundedCornerShape(999.dp)) {
                    Text("Sign in with Reddit", fontWeight = FontWeight.Bold)
                }
            } else {
                Icon(Icons.Default.WifiOff, contentDescription = null, tint = Theme.textSecondary, modifier = Modifier.size(36.dp))
                Text(errorText ?: "No videos loaded.", color = Color.White, fontSize = 15.sp, textAlign = TextAlign.Center)
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    Button(
                        onClick = { scope.launch { model.refresh(rotateCursor = true) } },
                        colors = ButtonDefaults.buttonColors(containerColor = Theme.accent),
                        shape = RoundedCornerShape(999.dp)
                    ) {
                        Text("Retry", fontWeight = FontWeight.Bold)
                    }
                    OutlinedButton(onClick = onOpenCategories, shape = RoundedCornerShape(999.dp)) {
                        Text("Browse", color = Color.White)
                    }
                }
            }
        }
    }
}

@kotlin.OptIn(ExperimentalLayoutApi::class)
@Composable
fun PostMoreSheet(
    gif: Gif,
    activeDownloadGif: Gif = gif,
    onSelectRule34Tag: (String) -> Unit,
    onSelectSubreddit: (String) -> Unit,
    onSelectUser: (String) -> Unit,
    onSelectXUser: (String) -> Unit,
    onSelectIGUser: (String) -> Unit,
    onSelectOFCreator: (String, String) -> Unit,
    onDislike: () -> Unit = {},
    onShare: () -> Unit,
    onDismiss: () -> Unit
) {
    val ctx = LocalContext.current
    val settings by UserStore.shared.data.collectAsState()
    val tinted = settings.settings.tintedGlass
    val r34Tags = remember(gif.id) {
        if (!gif.isRule34Post) emptyList()
        else (gif.title ?: "").split(" ").map { it.removePrefix("#").trim() }.filter { it.isNotEmpty() }
    }
    val downloaded = OfflineManager.isDownloaded(activeDownloadGif)
    val localFile = remember(activeDownloadGif.id, downloaded) {
        OfflineManager.localMediaURL(activeDownloadGif.id)?.removePrefix("file://")?.let { File(it) }?.takeIf { it.exists() }
    }

    androidx.compose.ui.window.Dialog(
        onDismissRequest = onDismiss,
        properties = androidx.compose.ui.window.DialogProperties(usePlatformDefaultWidth = false)
    ) {
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(Color.Black.copy(alpha = 0.65f))
                .clickable(onClick = onDismiss),
            contentAlignment = Alignment.BottomCenter
        ) {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .fillMaxHeight(0.76f)
                    .clip(RoundedCornerShape(topStart = 24.dp, topEnd = 24.dp))
                    .background(if (tinted) Color(0xFF1F0812) else Color(0xFF12080E))
                    .border(1.dp, Color.White.copy(0.14f), RoundedCornerShape(topStart = 24.dp, topEnd = 24.dp))
                    .clickable(enabled = false) {}
                    .navigationBarsPadding()
                    .padding(20.dp)
            ) {
                Column(modifier = Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Post Info & Offline", color = Color.White, fontSize = 19.sp, fontWeight = FontWeight.Bold)
                Spacer(Modifier.weight(1f))
                IconButton(onClick = onDismiss) { Icon(Icons.Default.Close, contentDescription = "Close", tint = Color.White) }
            }

            gif.title?.takeIf { it.isNotBlank() }?.let { t ->
                Text(t, color = Color.White.copy(0.9f), fontSize = 13.5.sp)
            }

            // Author Card + Follow Toggle
            gif.author?.takeIf { it.isNotBlank() }?.let { u ->
                val isFollowed = when {
                    gif.isOnlyFansPost -> UserStore.shared.isFollowingOFCreator(gif.onlyFansCreatorId, u)
                    gif.isXPost -> UserStore.shared.isFollowingXUser(u)
                    gif.isIGPost -> UserStore.shared.isFollowingIGUser(u)
                    else -> UserStore.shared.isFollowingUser(u)
                }
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .fillMaxWidth()
                        .liquidGlassCard(16.dp, tinted)
                        .clickable {
                            when {
                                gif.isOnlyFansPost -> (gif.onlyFansCreatorId ?: u).let { onSelectOFCreator(it, u) }
                                gif.isXPost -> onSelectXUser(u)
                                gif.isIGPost -> onSelectIGUser(u)
                                gif.isRule34Post -> onSelectRule34Tag(if (!u.equals("rule34", true)) "user:$u" else "")
                                !gif.isLongVideoPost -> onSelectUser(u)
                                else -> {}
                            }
                        }
                        .padding(14.dp)
                ) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text(if (gif.isRule34Post) "Artist @$u" else "@$u", color = Color.White, fontWeight = FontWeight.Bold, fontSize = 14.5.sp)
                        Text("Tap to open profile", color = Theme.textSecondary, fontSize = 11.5.sp)
                    }
                    Box(
                        modifier = Modifier
                            .liquidGlassCapsule(tinted, active = isFollowed)
                            .clickable {
                                when {
                                    gif.isOnlyFansPost -> (gif.onlyFansCreatorId ?: u).let { UserStore.shared.toggleFollowOFCreator(it, u, null) }
                                    gif.isXPost -> UserStore.shared.toggleFollowXUser(u)
                                    gif.isIGPost -> UserStore.shared.toggleFollowIGUser(u)
                                    else -> UserStore.shared.toggleFollowUser(u)
                                }
                            }
                            .padding(horizontal = 12.dp, vertical = 6.dp)
                    ) {
                        Text(if (isFollowed) "Following" else "Follow", color = Color.White, fontSize = 12.sp, fontWeight = FontWeight.Bold)
                    }
                }
            }

            // Subreddit Card + Join/Joined Toggle
            gif.subreddit?.takeIf { it.isNotBlank() && !gif.isLongVideoPost && !gif.isRule34Post }?.let { sub ->
                val joined = UserStore.shared.isFollowingSubreddit(sub)
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .fillMaxWidth()
                        .liquidGlassCard(16.dp, tinted)
                        .clickable { onSelectSubreddit(sub) }
                        .padding(14.dp)
                ) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text("r/$sub", color = Color.White, fontWeight = FontWeight.Bold, fontSize = 14.5.sp)
                        Text("Open subreddit feed", color = Theme.textSecondary, fontSize = 11.5.sp)
                    }
                    Box(
                        modifier = Modifier
                            .liquidGlassCapsule(tinted, active = joined)
                            .clickable { UserStore.shared.toggleFollowSubreddit(sub) }
                            .padding(horizontal = 12.dp, vertical = 6.dp)
                    ) {
                        Text(if (joined) "Joined" else "Join", color = Color.White, fontSize = 12.sp, fontWeight = FontWeight.Bold)
                    }
                }
            }

            // Offline Vault Download / Export Card
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .fillMaxWidth()
                    .liquidGlassCard(16.dp, tinted)
                    .clickable { OfflineManager.toggleDownload(activeDownloadGif) }
                    .padding(14.dp)
            ) {
                Icon(if (downloaded) Icons.Default.CheckCircle else Icons.Default.Download, contentDescription = null, tint = if (downloaded) Color(0xFF4ADE80) else Color.White)
                Spacer(Modifier.width(10.dp))
                Column(modifier = Modifier.weight(1f)) {
                    Text(if (downloaded) "Saved in Offline Vault" else "Download to Offline Vault", color = Color.White, fontWeight = FontWeight.Bold, fontSize = 14.sp)
                    Text(if (downloaded) "Tap to remove offline copy" else "Watch anytime without internet", color = Theme.textSecondary, fontSize = 11.5.sp)
                }
            }

            if (localFile != null) {
                OutlinedButton(
                    onClick = { ShareService.shareLocalFileWithChooser(ctx, localFile) },
                    shape = RoundedCornerShape(14.dp),
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Icon(Icons.Default.Share, contentDescription = null, tint = Color.White, modifier = Modifier.size(16.dp))
                    Spacer(Modifier.width(8.dp))
                    Text("Export Downloaded File", color = Color.White, fontWeight = FontWeight.Bold)
                }
            }

            if (r34Tags.isNotEmpty()) {
                Text("RULE34 TAGS", color = Theme.textSecondary, fontSize = 11.sp, fontWeight = FontWeight.Bold)
                FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    for (t in r34Tags) {
                        Box(
                            modifier = Modifier
                                .liquidGlassCapsule(tinted = tinted)
                                .clickable { onSelectRule34Tag(t) }
                                .padding(horizontal = 12.dp, vertical = 6.dp)
                        ) {
                            Text("#$t", color = Color.White, fontSize = 12.sp)
                        }
                    }
                }
            }

            Button(onClick = onShare, colors = ButtonDefaults.buttonColors(containerColor = Theme.accent), shape = RoundedCornerShape(14.dp), modifier = Modifier.fillMaxWidth()) {
                Text("Share Encrypted Drop", fontWeight = FontWeight.Bold)
            }

            OutlinedButton(
                onClick = {
                    val send = Intent(Intent.ACTION_SEND).apply {
                        type = "text/plain"
                        putExtra(Intent.EXTRA_TEXT, gif.webURL)
                    }
                    ctx.startActivity(Intent.createChooser(send, "Share Original Link"))
                },
                shape = RoundedCornerShape(14.dp),
                modifier = Modifier.fillMaxWidth()
            ) {
                Text("Share Original Post Link", color = Color.White)
            }

            OutlinedButton(
                onClick = onDislike,
                shape = RoundedCornerShape(14.dp),
                modifier = Modifier.fillMaxWidth()
            ) {
                Icon(Icons.Default.ThumbDown, contentDescription = null, tint = Color(0xFFFF6B6B), modifier = Modifier.size(16.dp))
                Spacer(Modifier.width(8.dp))
                Text("Not Interested · Show Less Like This", color = Color(0xFFFF6B6B), fontWeight = FontWeight.Bold)
            }
                }
            }
        }
    }
}

private fun formatTime(sec: Double): String {
    val s = sec.toInt().coerceAtLeast(0)
    return "${s / 60}:${(s % 60).toString().padStart(2, '0')}"
}

private val framePreviewLock = Any()

private fun fetchFramePreview(url: String, seconds: Double): Bitmap? {
    if (url.contains(".m3u8", ignoreCase = true)) return null
    return synchronized(framePreviewLock) {
        val mmr = MediaMetadataRetriever()
        try {
            if (url.startsWith("file://")) mmr.setDataSource(url.removePrefix("file://"))
            else mmr.setDataSource(url, MediaHeaders.headers(url))
            val timeUs = (seconds * 1_000_000).toLong()
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O_MR1) {
                mmr.getScaledFrameAtTime(timeUs, MediaMetadataRetriever.OPTION_CLOSEST_SYNC, 224, 312)
            } else {
                mmr.getFrameAtTime(timeUs, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
            }
        } catch (_: Throwable) {
            null
        } finally {
            try { mmr.release() } catch (_: Throwable) {}
        }
    }
}
