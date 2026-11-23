package com.bella.tinytiny

import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.view.ViewGroup
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
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
import androidx.compose.material.icons.automirrored.filled.VolumeOff
import androidx.compose.material.icons.automirrored.filled.VolumeUp
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.datasource.okhttp.OkHttpDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.PlayerView
import coil.compose.AsyncImage
import coil.request.ImageRequest
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

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
    onConnectIG: () -> Unit
) {
    val items by model.items.collectAsState()
    val isLoading by model.isLoading.collectAsState()
    val sort by model.sort.collectAsState()
    val src by model.source.collectAsState()
    val userData by UserStore.shared.data.collectAsState()
    val scope = rememberCoroutineScope()

    var shareTarget by remember { mutableStateOf<Gif?>(null) }

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
            onConnectIG = onConnectIG
        )
        return
    }

    val initialPage = remember(src) {
        if (targetPostId != null) items.indexOfFirst { it.id == targetPostId }.coerceAtLeast(0) else 0
    }
    val pagerState = rememberPagerState(initialPage = initialPage, pageCount = { items.size })
    var lastReportedPostId by remember(src) { mutableStateOf<String?>(null) }

    LaunchedEffect(targetPostId) {
        if (targetPostId != null && targetPostId != lastReportedPostId) {
            val idx = items.indexOfFirst { it.id == targetPostId }
            if (idx >= 0 && idx != pagerState.currentPage) {
                pagerState.scrollToPage(idx)
            }
        }
    }

    LaunchedEffect(pagerState, src) {
        snapshotFlow { pagerState.settledPage }.collect { page ->
            val current = items.getOrNull(page)
            if (current != null) {
                lastReportedPostId = current.id
                onCurrentPostChanged(current.id)
                UserStore.shared.markSeen(current)
                val key = src.swipeKey
                UserStore.shared.recordSwipe(key.first, key.second, src.displayTitle, current.id)
                model.onItemAppear(current)
            }
        }
    }

    Box(modifier = Modifier.fillMaxSize().background(Color.Black)) {
        VerticalPager(
            state = pagerState,
            beyondViewportPageCount = 1,
            modifier = Modifier.fillMaxSize()
        ) { pageIdx ->
            val gif = items[pageIdx]
            val isActive = isVisible && pagerState.currentPage == pageIdx && shareTarget == null
            GoonedReelCell(
                gif = gif,
                isActive = isActive,
                sort = sort,
                tinted = userData.settings.tintedGlass,
                onSelectSort = { model.setSort(it) },
                onShuffle = { model.shuffleItems() },
                onOpenCategories = onOpenCategories,
                onSelectSubreddit = onSelectSubreddit,
                onSelectUser = onSelectUser,
                onSelectXUser = onSelectXUser,
                onSelectIGUser = onSelectIGUser,
                onSelectRule34Tag = onSelectRule34Tag,
                onSelectOFCreator = onSelectOFCreator,
                onDislike = {
                    UserStore.shared.dislike(gif)
                    model.removeDisliked(gif)
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

    shareTarget?.let { target ->
        ShareItemSheet(gif = target, onDismiss = { shareTarget = null })
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
fun GoonedReelCell(
    gif: Gif,
    isActive: Boolean,
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
    val scope = rememberCoroutineScope()
    val userData by UserStore.shared.data.collectAsState()
    val activeDownloads by OfflineManager.activeDownloads.collectAsState()
    val collapsed = userData.settings.controlsCollapsed

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
    var albumItems by remember(gif.id) { mutableStateOf(MediaMetaRegistry.albumItems(gif.id)) }
    var albumIndex by remember(gif.id) { mutableIntStateOf(0) }
    var resolvedUrls by remember(gif.id) { mutableStateOf(gif.allVideoURLs(userData.settings.hd)) }
    var resolvingLongVideo by remember(gif.id) { mutableStateOf(false) }
    var urlIndex by remember(gif.id, albumIndex) { mutableIntStateOf(0) }
    var isBuffering by remember(gif.id, albumIndex) { mutableStateOf(false) }
    var playbackFailed by remember(gif.id, albumIndex) { mutableStateOf(false) }
    var localFitOverride by remember(gif.id) { mutableStateOf<Boolean?>(null) }
    val effectiveFill = localFitOverride ?: (userData.settings.fillScreen || !userData.settings.videoFitScreen)

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

    // Auto-scroll timer for images or when playVideosToEnd is off (matches iOS)
    LaunchedEffect(isActive, gif.id, isShowingImage, userData.settings.autoScroll, userData.settings.autoScrollDelay, userData.settings.playVideosToEnd) {
        if (!isActive || !userData.settings.autoScroll) return@LaunchedEffect
        if (isShowingImage || !userData.settings.playVideosToEnd) {
            delay(maxOf(3, userData.settings.autoScrollDelay) * 1000L)
            if (isActive && !userPaused && !isScrubbing) onAutoScrollNext()
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
    val exoPlayer = remember(gif.id, activeVideoUrl, isActive) {
        if (!isActive || activeVideoUrl == null || isShowingImage) null
        else {
            playbackFailed = false
            val dsFactory = OkHttpDataSource.Factory(TinyTinyApplication.sharedHttpClient)
                .setDefaultRequestProperties(MediaHeaders.headers(activeVideoUrl))
            ExoPlayer.Builder(ctx)
                .setMediaSourceFactory(DefaultMediaSourceFactory(dsFactory))
                .build().apply {
                    repeatMode = if (userData.settings.autoScroll && userData.settings.playVideosToEnd) Player.REPEAT_MODE_OFF else Player.REPEAT_MODE_ONE
                    setMediaItem(MediaItem.fromUri(Uri.parse(activeVideoUrl)))
                    prepare()
                }
        }
    }

    DisposableEffect(exoPlayer, userData.settings.autoScroll, userData.settings.playVideosToEnd) {
        val listener = if (exoPlayer != null) {
            object : Player.Listener {
                override fun onPlaybackStateChanged(playbackState: Int) {
                    isBuffering = playbackState == Player.STATE_BUFFERING
                    if (playbackState == Player.STATE_READY) playbackFailed = false
                    if (playbackState == Player.STATE_ENDED && isActive && userData.settings.autoScroll && userData.settings.playVideosToEnd) {
                        onAutoScrollNext()
                    }
                }

                override fun onPlayerError(error: PlaybackException) {
                    isBuffering = false
                    if (urlIndex + 1 < resolvedUrls.size) {
                        urlIndex += 1
                    } else {
                        playbackFailed = true
                    }
                }
            }.also { exoPlayer.addListener(it) }
        } else null
        onDispose {
            if (listener != null) exoPlayer?.removeListener(listener)
            exoPlayer?.release()
        }
    }

    var currentSec by remember(gif.id) { mutableDoubleStateOf(0.0) }
    var durationSec by remember(gif.id) { mutableDoubleStateOf(gif.duration ?: 1.0) }

    LaunchedEffect(exoPlayer, isActive, userPaused, isScrubbing, userData.settings.autoScroll, userData.settings.playVideosToEnd) {
        if (exoPlayer != null) {
            exoPlayer.repeatMode = if (userData.settings.autoScroll && userData.settings.playVideosToEnd) Player.REPEAT_MODE_OFF else Player.REPEAT_MODE_ONE
            exoPlayer.volume = if (userData.settings.muted) 0f else 1f
            exoPlayer.playWhenReady = isActive && !userPaused && !isScrubbing
            exoPlayer.setPlaybackSpeed(if (isHolding || speedLocked2x) 2.0f else 1.0f)
        }
    }

    LaunchedEffect(exoPlayer, userData.settings.muted, isHolding, speedLocked2x) {
        if (exoPlayer != null) {
            exoPlayer.volume = if (userData.settings.muted) 0f else 1f
            exoPlayer.setPlaybackSpeed(if (isHolding || speedLocked2x) 2.0f else 1.0f)
        }
    }

    LaunchedEffect(exoPlayer, isActive) {
        while (exoPlayer != null && isActive) {
            val dur = exoPlayer.duration
            if (dur > 0) durationSec = dur / 1000.0
            currentSec = exoPlayer.currentPosition / 1000.0
            delay(250)
        }
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black)
            .pointerInput(gif.id, isShowingImage) {
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
                                exoPlayer?.let { p ->
                                    p.seekTo((p.currentPosition - step * 1000L).coerceAtLeast(0L))
                                }
                                skipIndicator = -step
                                scope.launch { delay(650); skipIndicator = null }
                            }
                            !isShowingImage && offset.x > w * 0.70f -> {
                                val step = if (gif.isLongVideoPost) 10 else 5
                                exoPlayer?.let { p ->
                                    p.seekTo((p.currentPosition + step * 1000L).coerceAtMost(p.duration.coerceAtLeast(0L)))
                                }
                                skipIndicator = step
                                scope.launch { delay(650); skipIndicator = null }
                            }
                            else -> {
                                if (!UserStore.shared.isLiked(gif)) UserStore.shared.toggleLike(gif)
                                showHeart = true
                                scope.launch { delay(750); showHeart = false }
                            }
                        }
                    }
                )
            }
            .pointerInput(gif.id, isShowingImage, activeVideoUrl) {
                if (!isShowingImage && exoPlayer != null) {
                    var startX = 0f
                    var totalDx = 0f
                    var totalDy = 0f
                    var scrubbing = false
                    var lastPreviewAt = 0L
                    var scrubPreviewJob: Job? = null
                    detectDragGesturesAfterLongPress(
                        onDragStart = { offset ->
                            startX = offset.x
                            totalDx = 0f
                            totalDy = 0f
                            scrubbing = false
                            isHolding = true
                        },
                        onDrag = { change, dragAmount ->
                            change.consume()
                            totalDx += dragAmount.x
                            totalDy += dragAmount.y
                            if (!scrubbing && kotlin.math.abs(totalDx) > 22f && kotlin.math.abs(totalDx) > kotlin.math.abs(totalDy)) {
                                scrubbing = true
                                isHolding = false
                                isScrubbing = true
                                val dur = durationSec.coerceAtLeast(1.0)
                                scrubDurationSec = dur
                                scrubStartSec = currentSec
                                scrubTargetSec = currentSec
                            } else if (!scrubbing && totalDy > 56f) {
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
                        },
                        onDragEnd = {
                            if (scrubbing) {
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
            }
    ) {
        // Media Content (Multi-slide Erome Pager, Tall Rule34 Scroll, or ExoPlayer Video)
        if (albumItems.size > 1) {
            val hPager = rememberPagerState(pageCount = { albumItems.size })
            LaunchedEffect(hPager.currentPage) { albumIndex = hPager.currentPage }
            HorizontalPager(state = hPager, modifier = Modifier.fillMaxSize()) { idx ->
                val item = albumItems[idx]
                if (!item.isVideo) {
                    TallOrNormalImage(url = item.url, fill = effectiveFill)
                } else if (exoPlayer != null && idx == albumIndex) {
                    ExoPlayerSurface(player = exoPlayer, fill = effectiveFill)
                } else {
                    AsyncImage(model = item.posterUrl ?: gif.posterURL, contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
                }
            }
            if (!collapsed) {
                Text(
                    text = "${albumIndex + 1} / ${albumItems.size}",
                    color = Color.White,
                    fontSize = 11.5.sp,
                    fontWeight = FontWeight.Bold,
                    fontFamily = FontFamily.Monospace,
                    modifier = Modifier
                        .align(Alignment.TopCenter)
                        .padding(top = 96.dp)
                        .liquidGlassCapsule(tinted = tinted)
                        .padding(horizontal = 12.dp, vertical = 6.dp)
                )
            }
        } else if (isShowingImage) {
            TallOrNormalImage(url = currentAlbumItem?.url ?: gif.imageURL, fill = effectiveFill)
        } else if (exoPlayer != null) {
            ExoPlayerSurface(player = exoPlayer, fill = effectiveFill)
        } else {
            Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                AsyncImage(
                    model = gif.posterURL,
                    contentDescription = null,
                    contentScale = if (effectiveFill) ContentScale.Crop else ContentScale.Fit,
                    modifier = Modifier.fillMaxSize()
                )
                if (resolvingLongVideo) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                        modifier = Modifier
                            .liquidGlassCapsule(tinted = tinted)
                            .padding(horizontal = 14.dp, vertical = 8.dp)
                    ) {
                        CircularProgressIndicator(color = Theme.accentBright, modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
                        Text("Loading video...", color = Color.White, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
                    }
                }
            }
        }

        // Buffering / Pause / Playback Error Overlays
        if (!isShowingImage && isBuffering && !userPaused && !playbackFailed) {
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
                    }
                    .padding(horizontal = 16.dp, vertical = 10.dp)
            ) {
                Icon(Icons.Default.Refresh, contentDescription = "Retry", tint = Theme.accentBright, modifier = Modifier.size(18.dp))
                Text("Tap to Retry Video", color = Color.White, fontSize = 13.sp, fontWeight = FontWeight.Bold)
            }
        }

        // Bottom Gradient
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(220.dp)
                .align(Alignment.BottomCenter)
                .background(Brush.verticalGradient(listOf(Color.Transparent, Color.Black.copy(0.75f))))
        )

        // Heart animation
        AnimatedVisibility(visible = showHeart, enter = fadeIn(), exit = fadeOut(), modifier = Modifier.align(Alignment.Center)) {
            Icon(Icons.Default.Favorite, contentDescription = null, tint = Theme.accent, modifier = Modifier.size(96.dp))
        }

        // Skip indicator
        skipIndicator?.let { s ->
            Box(
                modifier = Modifier
                    .align(if (s < 0) Alignment.CenterStart else Alignment.CenterEnd)
                    .padding(horizontal = 36.dp)
                    .clip(CircleShape)
                    .background(Color.Black.copy(0.55f))
                    .padding(18.dp)
            ) {
                Text("${if (s > 0) "+" else ""}${s}s", color = Color.White, fontWeight = FontWeight.Bold, fontSize = 18.sp)
            }
        }

        // 2x Speed Active / Locked pill (matches iOS)
        if ((isHolding || speedLocked2x) && !isShowingImage && !isScrubbing) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(5.dp),
                modifier = Modifier
                    .align(Alignment.TopCenter)
                    .padding(top = 110.dp)
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

        // Instagram-style Scrub Preview Card
        if (isScrubbing && !isShowingImage) {
            Column(
                modifier = Modifier
                    .align(Alignment.BottomCenter)
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
        } else if (!collapsed) {
            // Left Author/Title + Right Action Stack
            Row(
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .fillMaxWidth()
                    .padding(start = 16.dp, end = 12.dp, bottom = 92.dp),
                verticalAlignment = Alignment.Bottom
            ) {
                Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    gif.author?.let { author ->
                        Text(
                            text = if (gif.isXPost || gif.isIGPost || gif.isOnlyFansPost) "@$author" else author,
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
                    gif.title?.takeIf { it.isNotEmpty() }?.let { t ->
                        Text(t, color = Color.White.copy(0.88f), fontSize = 13.sp, maxLines = 2, overflow = TextOverflow.Ellipsis)
                    }

                    // iOS Bottom-Left Control Bar Row 1: [Hot/Top/New] [Fit/Fill] [Collapse]
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(4.dp),
                            modifier = Modifier
                                .liquidGlassCapsule(tinted)
                                .clickable {
                                    val nextSort = when (sort) {
                                        FeedSort.HOT -> FeedSort.TOP
                                        FeedSort.TOP -> FeedSort.NEW
                                        FeedSort.NEW -> FeedSort.HOT
                                    }
                                    onSelectSort(nextSort)
                                }
                                .padding(horizontal = 12.dp, vertical = 7.dp)
                        ) {
                            Icon(Icons.Default.LocalFireDepartment, contentDescription = null, tint = Color.White, modifier = Modifier.size(14.dp))
                            Text(sort.label, color = Color.White, fontSize = 12.5.sp, fontWeight = FontWeight.Bold)
                        }
                        IconButton(
                            onClick = { localFitOverride = !effectiveFill },
                            modifier = Modifier.size(34.dp).liquidGlassCircle(tinted, active = effectiveFill)
                        ) {
                            Icon(
                                if (effectiveFill) Icons.Default.FullscreenExit else Icons.Default.Fullscreen,
                                contentDescription = "Fit/Fill",
                                tint = Color.White,
                                modifier = Modifier.size(17.dp)
                            )
                        }
                        IconButton(
                            onClick = { UserStore.shared.updateSettings { it.copy(controlsCollapsed = true) } },
                            modifier = Modifier.size(34.dp).liquidGlassCircle(tinted)
                        ) {
                            Icon(Icons.Default.KeyboardArrowDown, contentDescription = "Collapse", tint = Color.White, modifier = Modifier.size(18.dp))
                        }
                    }

                    // iOS Bottom-Left Control Bar Row 2: [Browse] [Shuffle] [Auto-Scroll] [Quick Follow +]
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                        IconButton(onClick = onOpenCategories, modifier = Modifier.size(38.dp).liquidGlassCircle(tinted)) {
                            Icon(Icons.Default.GridView, contentDescription = "Browse", tint = Color.White, modifier = Modifier.size(18.dp))
                        }
                        IconButton(onClick = onShuffle, modifier = Modifier.size(38.dp).liquidGlassCircle(tinted)) {
                            Icon(Icons.Default.Shuffle, contentDescription = "Shuffle", tint = Color.White, modifier = Modifier.size(18.dp))
                        }
                        IconButton(
                            onClick = { UserStore.shared.updateSettings { it.copy(autoScroll = !it.autoScroll) } },
                            modifier = Modifier.size(38.dp).liquidGlassCircle(tinted, active = userData.settings.autoScroll)
                        ) {
                            Icon(Icons.Default.KeyboardDoubleArrowDown, contentDescription = "Auto-Scroll", tint = Color.White, modifier = Modifier.size(18.dp))
                        }
                        val canFollow = !gif.author.isNullOrEmpty() || !gif.subreddit.isNullOrEmpty()
                        if (canFollow) {
                            val isFollowed = when {
                                gif.isOnlyFansPost -> gif.onlyFansCreatorId?.let { UserStore.shared.isFollowingOFCreator(it, gif.author ?: "") } == true
                                gif.isXPost -> gif.author?.let { UserStore.shared.isFollowingXUser(it) } == true
                                gif.isIGPost -> gif.author?.let { UserStore.shared.isFollowingIGUser(it) } == true
                                !gif.subreddit.isNullOrEmpty() -> UserStore.shared.isFollowingSubreddit(gif.subreddit!!)
                                else -> gif.author?.let { UserStore.shared.isFollowingUser(it) } == true
                            }
                            IconButton(
                                onClick = {
                                    when {
                                        gif.isOnlyFansPost -> gif.onlyFansCreatorId?.let { UserStore.shared.toggleFollowOFCreator(it, gif.author ?: it, null) }
                                        gif.isXPost -> gif.author?.let { UserStore.shared.toggleFollowXUser(it) }
                                        gif.isIGPost -> gif.author?.let { UserStore.shared.toggleFollowIGUser(it) }
                                        !gif.subreddit.isNullOrEmpty() -> UserStore.shared.toggleFollowSubreddit(gif.subreddit!!)
                                        else -> gif.author?.let { UserStore.shared.toggleFollowUser(it) }
                                    }
                                },
                                modifier = Modifier.size(38.dp).liquidGlassCircle(tinted, active = isFollowed)
                            ) {
                                Icon(if (isFollowed) Icons.Default.Check else Icons.Default.Add, contentDescription = "Follow", tint = Color.White, modifier = Modifier.size(18.dp))
                            }
                        }
                    }

                    // Interactive bottom video scrubber bar (matches iOS PlayerScrubberBar)
                    if (!isShowingImage && exoPlayer != null && durationSec > 0.5) {
                        Slider(
                            value = (currentSec / durationSec).toFloat().coerceIn(0f, 1f),
                            onValueChange = { frac ->
                                val targetMs = (frac * durationSec * 1000.0).toLong()
                                currentSec = targetMs / 1000.0
                                exoPlayer.seekTo(targetMs)
                            },
                            colors = SliderDefaults.colors(
                                thumbColor = Color.White,
                                activeTrackColor = Theme.accentBright,
                                inactiveTrackColor = Color.White.copy(0.25f)
                            ),
                            modifier = Modifier.fillMaxWidth().height(18.dp)
                        )
                    }
                }

                Spacer(Modifier.width(12.dp))

                Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    // Source badge (matches iOS pink r/ badge & brand icons)
                    Box(
                        modifier = Modifier.clickable {
                            when {
                                gif.isOnlyFansPost -> gif.onlyFansCreatorId?.let { onSelectOFCreator(it, gif.author ?: it) }
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
                            gif.isRule34Post -> BrandLogoRule34(40.dp)
                            gif.isXPost -> Box(Modifier.size(40.dp).liquidGlassCircle(tinted), contentAlignment = Alignment.Center) { BrandLogoX(20.dp) }
                            gif.isIGPost -> BrandLogoInstagram(40.dp)
                            gif.isOnlyFansPost -> BrandLogoOnlyFans(40.dp)
                            gif.isLongVideoPost -> BrandLogoLongVideos(40.dp)
                            else -> Box(Modifier.size(40.dp).clip(CircleShape).background(Color(0xFFF078A0)), contentAlignment = Alignment.Center) {
                                Text("r/", color = Color.Black, fontWeight = FontWeight.Black, fontSize = 14.sp)
                            }
                        }
                    }

                    val liked = UserStore.shared.isLiked(gif)
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        IconButton(onClick = { UserStore.shared.toggleLike(gif) }, modifier = Modifier.size(40.dp).liquidGlassCircle(tinted)) {
                            Icon(Icons.Default.Favorite, contentDescription = "Like", tint = if (liked) Theme.accent else Color.White)
                        }
                        val upText = Gif.shortCount(gif.upvotes)
                        if (upText.isNotEmpty()) {
                            Text(upText, color = Color.White, fontSize = 11.sp, fontWeight = FontWeight.Bold)
                        }
                    }
                    IconButton(onClick = onDislike, modifier = Modifier.size(40.dp).liquidGlassCircle(tinted)) {
                        Icon(Icons.Default.ThumbDown, contentDescription = "Dislike", tint = Color.White)
                    }
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        IconButton(
                            onClick = { UserStore.shared.updateSettings { it.copy(muted = !it.muted) } },
                            modifier = Modifier.size(40.dp).liquidGlassCircle(tinted)
                        ) {
                            Icon(
                                if (userData.settings.muted) Icons.AutoMirrored.Filled.VolumeOff else Icons.AutoMirrored.Filled.VolumeUp,
                                contentDescription = "Sound",
                                tint = Color.White
                            )
                        }
                        Text("Sound", color = Color.White, fontSize = 10.5.sp, fontWeight = FontWeight.SemiBold)
                    }
                    val downloaded = OfflineManager.isDownloaded(activeDownloadGif)
                    val downloading = activeDownloadGif.id in activeDownloads
                    IconButton(
                        onClick = { OfflineManager.toggleDownload(activeDownloadGif) },
                        modifier = Modifier.size(40.dp).liquidGlassCircle(tinted)
                    ) {
                        if (downloading) {
                            CircularProgressIndicator(color = Theme.accentBright, modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
                        } else {
                            Icon(
                                if (downloaded) Icons.Default.CheckCircle else Icons.Default.Download,
                                contentDescription = "Download",
                                tint = if (downloaded) Theme.accentBright else Color.White
                            )
                        }
                    }
                    IconButton(onClick = onShare, modifier = Modifier.size(40.dp).liquidGlassCircle(tinted)) {
                        Icon(Icons.Default.Send, contentDescription = "Share", tint = Color.White)
                    }
                    IconButton(onClick = { showMoreSheet = true }, modifier = Modifier.size(40.dp).liquidGlassCircle(tinted)) {
                        Icon(Icons.Default.MoreHoriz, contentDescription = "More", tint = Color.White)
                    }
                }
            }
        } else {
            Box(
                modifier = Modifier
                    .align(Alignment.BottomStart)
                    .padding(start = 16.dp, bottom = 22.dp)
                    .liquidGlassCapsule(tinted)
                    .clickable { UserStore.shared.updateSettings { it.copy(controlsCollapsed = false) } }
                    .padding(horizontal = 12.dp, vertical = 7.dp)
            ) {
                Text("Controls", color = Color.White, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
            }
        }
    }

    if (showMoreSheet) {
        PostMoreSheet(
            gif = gif,
            onSelectRule34Tag = { tag -> showMoreSheet = false; onSelectRule34Tag(tag) },
            onSelectSubreddit = { s -> showMoreSheet = false; onSelectSubreddit(s) },
            onSelectUser = { u -> showMoreSheet = false; onSelectUser(u) },
            onSelectXUser = { u -> showMoreSheet = false; onSelectXUser(u) },
            onSelectIGUser = { u -> showMoreSheet = false; onSelectIGUser(u) },
            onSelectOFCreator = { id, h -> showMoreSheet = false; onSelectOFCreator(id, h) },
            onShare = { showMoreSheet = false; onShare() },
            onDismiss = { showMoreSheet = false }
        )
    }
}

@Composable
private fun ExoPlayerSurface(player: ExoPlayer, fill: Boolean) {
    AndroidView(
        factory = { ctx ->
            PlayerView(ctx).apply {
                useController = false
                resizeMode = if (fill) AspectRatioFrameLayout.RESIZE_MODE_ZOOM else AspectRatioFrameLayout.RESIZE_MODE_FIT
                layoutParams = ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
                this.player = player
            }
        },
        update = { pv ->
            pv.player = player
            pv.resizeMode = if (fill) AspectRatioFrameLayout.RESIZE_MODE_ZOOM else AspectRatioFrameLayout.RESIZE_MODE_FIT
        },
        modifier = Modifier.fillMaxSize()
    )
}

@Composable
private fun TallOrNormalImage(url: String?, fill: Boolean) {
    val ctx = LocalContext.current
    val request = remember(url) {
        val rb = ImageRequest.Builder(ctx).data(url).crossfade(true)
        if (!url.isNullOrEmpty()) {
            for ((k, v) in MediaHeaders.headers(url)) rb.addHeader(k, v)
        }
        rb.build()
    }
    Box(
        modifier = Modifier.fillMaxSize(),
        contentAlignment = Alignment.Center
    ) {
        AsyncImage(
            model = request,
            contentDescription = null,
            contentScale = if (fill) ContentScale.Crop else ContentScale.Fit,
            modifier = Modifier.fillMaxSize()
        )
    }
}

@Composable
fun FeedStateView(
    model: FeedModel,
    onOpenCategories: () -> Unit,
    onConnectX: () -> Unit,
    onConnectIG: () -> Unit
) {
    val isLoading by model.isLoading.collectAsState()
    val errorText by model.errorText.collectAsState()
    val src by model.source.collectAsState()
    val scope = rememberCoroutineScope()

    Box(modifier = Modifier.fillMaxSize().background(Color.Black), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(14.dp), modifier = Modifier.padding(28.dp)) {
            if (isLoading) {
                CircularProgressIndicator(color = Theme.accentBright)
                Text("Loading ${src.displayTitle}...", color = Theme.textSecondary, fontSize = 13.sp)
            } else if (src.isXFeed && !UserStore.shared.data.value.xSession.isConnected) {
                BrandLogoX(36.dp)
                Text("Connect Personal 𝕏", color = Color.White, fontSize = 20.sp, fontWeight = FontWeight.Bold)
                Button(onClick = onConnectX, colors = ButtonDefaults.buttonColors(containerColor = Theme.accent)) {
                    Text("Sign in with 𝕏", fontWeight = FontWeight.Bold)
                }
            } else if (src.isIGFeed && !UserStore.shared.data.value.igSession.isConnected) {
                BrandLogoInstagram(44.dp)
                Text("Connect Personal Instagram", color = Color.White, fontSize = 20.sp, fontWeight = FontWeight.Bold)
                Button(onClick = onConnectIG, colors = ButtonDefaults.buttonColors(containerColor = Theme.accent)) {
                    Text("Sign in with Instagram", fontWeight = FontWeight.Bold)
                }
            } else {
                Text(errorText ?: "No videos loaded.", color = Color.White, fontSize = 15.sp)
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    Button(onClick = { scope.launch { model.refresh(rotateCursor = true) } }, colors = ButtonDefaults.buttonColors(containerColor = Theme.accent)) {
                        Text("Retry", fontWeight = FontWeight.Bold)
                    }
                    OutlinedButton(onClick = onOpenCategories) {
                        Text("Browse", color = Color.White)
                    }
                }
            }
        }
    }
}

@Composable
fun PostMoreSheet(
    gif: Gif,
    onSelectRule34Tag: (String) -> Unit,
    onSelectSubreddit: (String) -> Unit,
    onSelectUser: (String) -> Unit,
    onSelectXUser: (String) -> Unit,
    onSelectIGUser: (String) -> Unit,
    onSelectOFCreator: (String, String) -> Unit,
    onShare: () -> Unit,
    onDismiss: () -> Unit
) {
    val settings by UserStore.shared.data.collectAsState()
    val r34Tags = remember(gif.id) {
        if (!gif.isRule34Post) emptyList()
        else (gif.title ?: "").split(" ").map { it.removePrefix("#").trim() }.filter { it.isNotEmpty() }
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .liquidGlassBackground(tinted = settings.settings.tintedGlass)
            .padding(20.dp)
    ) {
        Column(modifier = Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Post Info & Actions", color = Color.White, fontSize = 19.sp, fontWeight = FontWeight.Bold)
                Spacer(Modifier.weight(1f))
                IconButton(onClick = onDismiss) { Icon(Icons.Default.Close, contentDescription = "Close", tint = Color.White) }
            }

            gif.author?.let { u ->
                Button(
                    onClick = {
                        when {
                            gif.isOnlyFansPost -> gif.onlyFansCreatorId?.let { onSelectOFCreator(it, u) }
                            gif.isXPost -> onSelectXUser(u)
                            gif.isIGPost -> onSelectIGUser(u)
                            gif.isRule34Post -> onSelectRule34Tag(if (!u.equals("rule34", true)) "user:$u" else "")
                            else -> onSelectUser(u)
                        }
                    },
                    colors = ButtonDefaults.buttonColors(containerColor = Theme.surfaceElevated),
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Text(if (gif.isRule34Post) "View Artist @$u" else "Open @$u", color = Color.White, fontWeight = FontWeight.Bold)
                }
            }

            if (r34Tags.isNotEmpty()) {
                Text("RULE34 TAGS", color = Theme.textSecondary, fontSize = 11.sp, fontWeight = FontWeight.Bold)
                @OptIn(ExperimentalLayoutApi::class)
                FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    for (t in r34Tags) {
                        Box(
                            modifier = Modifier
                                .liquidGlassCapsule(tinted = settings.settings.tintedGlass)
                                .clickable { onSelectRule34Tag(t) }
                                .padding(horizontal = 12.dp, vertical = 6.dp)
                        ) {
                            Text("#$t", color = Color.White, fontSize = 12.sp)
                        }
                    }
                }
            }

            Button(onClick = onShare, colors = ButtonDefaults.buttonColors(containerColor = Theme.accent), modifier = Modifier.fillMaxWidth()) {
                Text("Share Encrypted Drop", fontWeight = FontWeight.Bold)
            }
        }
    }
}

private fun formatTime(sec: Double): String {
    val s = sec.toInt().coerceAtLeast(0)
    return "${s / 60}:${(s % 60).toString().padStart(2, '0')}"
}

private fun fetchFramePreview(url: String, seconds: Double): Bitmap? {
    val mmr = MediaMetadataRetriever()
    return try {
        if (url.startsWith("file://")) mmr.setDataSource(url.removePrefix("file://"))
        else mmr.setDataSource(url, MediaHeaders.headers(url))
        mmr.getFrameAtTime((seconds * 1_000_000).toLong(), MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
    } catch (_: Throwable) {
        null
    } finally {
        try { mmr.release() } catch (_: Throwable) {}
    }
}
