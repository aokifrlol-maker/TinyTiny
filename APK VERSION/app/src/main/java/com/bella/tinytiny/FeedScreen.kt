package com.bella.tinytiny

import android.app.Activity
import android.content.pm.ActivityInfo
import android.view.ViewGroup
import android.widget.FrameLayout
import androidx.annotation.OptIn
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGesturesAfterLongPress
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.pager.VerticalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.VolumeOff
import androidx.compose.material.icons.automirrored.filled.VolumeUp
import androidx.compose.material.icons.filled.FastForward
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.Fullscreen
import androidx.compose.material.icons.filled.FullscreenExit
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Share
import androidx.compose.material.icons.filled.Shuffle
import androidx.compose.material.icons.filled.ThumbDown
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.okhttp.OkHttpDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.PlayerView
import okhttp3.OkHttpClient
import coil.compose.AsyncImage
import kotlinx.coroutines.delay

@Composable
fun FeedScreen(
    model: FeedModel,
    isVisible: Boolean,
    onSelectShare: (Gif) -> Unit
) {
    val items by model.items.collectAsState()
    val isLoading by model.isLoading.collectAsState()
    val userData by UserStore.data.collectAsState()
    val pagerState = rememberPagerState(pageCount = { items.size })

    var dislikeToast by remember { mutableStateOf<DislikeOutcome?>(null) }

    LaunchedEffect(Unit) {
        if (items.isEmpty()) model.loadMore()
    }

    LaunchedEffect(pagerState.currentPage, items.size) {
        val current = items.getOrNull(pagerState.currentPage)
        if (current != null) {
            model.prefetchIfNeeded(current.id)
            delay(60)
            UserStore.markSeen(current)
        }
    }

    // Auto-scroll timer
    LaunchedEffect(pagerState.currentPage, userData.settings.autoScroll, userData.settings.autoScrollDelay, items.size) {
        if (userData.settings.autoScroll && items.isNotEmpty()) {
            delay((userData.settings.autoScrollDelay * 1000).toLong().coerceAtLeast(2500L))
            if (pagerState.currentPage + 1 < items.size) {
                pagerState.animateScrollToPage(pagerState.currentPage + 1)
            }
        }
    }

    Box(modifier = Modifier.fillMaxSize().background(Color.Black)) {
        if (items.isEmpty() && isLoading) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(color = AppTheme.accent)
            }
        } else if (items.isEmpty()) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Text("No posts found", color = Color.White, fontWeight = FontWeight.Bold)
                    Spacer(Modifier.height(10.dp))
                    Text(
                        "Tap to Retry",
                        color = AppTheme.accentBright,
                        modifier = Modifier
                            .liquidGlassCapsule()
                            .clickable { model.refresh() }
                            .padding(horizontal = 16.dp, vertical = 8.dp)
                    )
                }
            }
        } else {
            VerticalPager(
                state = pagerState,
                beyondViewportPageCount = 1,
                modifier = Modifier.fillMaxSize()
            ) { page ->
                val gif = items[page]
                val isActive = isVisible && pagerState.currentPage == page
                ReelCell(
                    gif = gif,
                    isActive = isActive,
                    hd = userData.settings.hd,
                    muted = userData.settings.muted,
                    collapsed = userData.settings.controlsCollapsed,
                    onToggleMute = { UserStore.updateSettings { it.copy(muted = !it.muted) } },
                    onToggleCollapse = { UserStore.updateSettings { it.copy(controlsCollapsed = !it.controlsCollapsed) } },
                    onShuffle = { model.shuffleItems() },
                    onDislike = {
                        val outcome = SmartTasteEngine.recordDislike(gif)
                        model.purgeSuppressed(gif.id)
                        dislikeToast = outcome
                    },
                    onShare = { onSelectShare(gif) }
                )
            }
        }

        AnimatedVisibility(
            visible = dislikeToast != null,
            enter = fadeIn(),
            exit = fadeOut(),
            modifier = Modifier
                .align(Alignment.TopCenter)
                .padding(top = 112.dp)
        ) {
            LaunchedEffect(dislikeToast) {
                delay(2400)
                dislikeToast = null
            }
            val msg = dislikeToast?.suppressedTag?.let { "Showing less of #$it" } ?: "Disliked · Tuned feed"
            Text(
                msg,
                color = Color.White,
                fontSize = 12.5.sp,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier
                    .liquidGlassCapsule(tinted = true)
                    .padding(horizontal = 14.dp, vertical = 8.dp)
            )
        }
    }
}

@OptIn(UnstableApi::class)
@Composable
private fun ReelCell(
    gif: Gif,
    isActive: Boolean,
    hd: Boolean,
    muted: Boolean,
    collapsed: Boolean,
    onToggleMute: () -> Unit,
    onToggleCollapse: () -> Unit,
    onShuffle: () -> Unit,
    onDislike: () -> Unit,
    onShare: () -> Unit
) {
    val context = LocalContext.current
    val activity = context as? Activity
    val config = LocalConfiguration.current
    val isLandscape = config.screenWidthDp > config.screenHeightDp

    var userPaused by remember(gif.id) { mutableStateOf(false) }
    var isHolding by remember(gif.id) { mutableStateOf(false) }
    var speedLocked2x by remember(gif.id) { mutableStateOf(false) }
    var pullAccum by remember(gif.id) { mutableFloatStateOf(0f) }
    val liked = UserStore.isLiked(gif.id)

    val videoUrl = remember(gif.id, hd) { gif.videoURL(hd) }

    val player = remember(gif.id) {
        if (videoUrl != null) {
            val mediaOkHttp = OkHttpClient.Builder()
                .addInterceptor { chain ->
                    val req = chain.request()
                    val host = req.url.host.lowercase()
                    val referer = when {
                        host.contains("cum.st") -> "https://cum.st/"
                        host.contains("twimg.com") || host.contains("x.com") -> "https://x.com/"
                        host.contains("xvideos") -> "https://www.xvideos.com/"
                        else -> "https://gooned.app/"
                    }
                    chain.proceed(
                        req.newBuilder()
                            .header("Referer", referer)
                            .header("User-Agent", "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36")
                            .build()
                    )
                }
                .build()
            val factory = DefaultMediaSourceFactory(OkHttpDataSource.Factory(mediaOkHttp))
            ExoPlayer.Builder(context)
                .setMediaSourceFactory(factory)
                .build()
                .apply {
                    repeatMode = Player.REPEAT_MODE_ONE
                    setMediaItem(MediaItem.fromUri(videoUrl))
                    prepare()
                }
        } else null
    }

    DisposableEffect(player) {
        onDispose {
            player?.release()
        }
    }

    LaunchedEffect(player, isActive, userPaused, muted, speedLocked2x, isHolding) {
        if (player != null) {
            player.volume = if (muted) 0f else 1f
            player.setPlaybackSpeed(if (isHolding || speedLocked2x) 2.0f else 1.0f)
            if (isActive && !userPaused) player.play() else player.pause()
        }
        if (!isActive) {
            speedLocked2x = false
            isHolding = false
        }
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black)
            .pointerInput(gif.id) {
                detectTapGestures(
                    onDoubleTap = { UserStore.toggleLike(gif) },
                    onTap = {
                        if (speedLocked2x) {
                            speedLocked2x = false
                        } else {
                            userPaused = !userPaused
                        }
                    }
                )
            }
            .pointerInput(gif.id) {
                detectDragGesturesAfterLongPress(
                    onDragStart = {
                        isHolding = true
                        pullAccum = 0f
                        userPaused = false
                    },
                    onDragEnd = {
                        isHolding = false
                    },
                    onDragCancel = {
                        isHolding = false
                    },
                    onDrag = { _, dragAmount ->
                        pullAccum += dragAmount.y
                        if (pullAccum > 60f && !gif.isImage && !speedLocked2x) {
                            speedLocked2x = true
                        }
                    }
                )
            }
    ) {
        if (player != null) {
            AndroidView(
                factory = { ctx ->
                    PlayerView(ctx).apply {
                        this.player = player
                        useController = false
                        resizeMode = AspectRatioFrameLayout.RESIZE_MODE_FIT
                        layoutParams = FrameLayout.LayoutParams(
                            ViewGroup.LayoutParams.MATCH_PARENT,
                            ViewGroup.LayoutParams.MATCH_PARENT
                        )
                    }
                },
                modifier = Modifier.fillMaxSize()
            )
        } else {
            AsyncImage(
                model = gif.imageURL ?: gif.posterOrThumb,
                contentDescription = gif.title,
                contentScale = ContentScale.Fit,
                modifier = Modifier.fillMaxSize()
            )
        }

        if (userPaused && !isHolding) {
            Box(
                modifier = Modifier
                    .size(64.dp)
                    .align(Alignment.Center)
                    .liquidGlassCircle(tinted = true),
                contentAlignment = Alignment.Center
            ) {
                Icon(Icons.Default.PlayArrow, contentDescription = "Paused", tint = Color.White, modifier = Modifier.size(34.dp))
            }
        }

        if ((isHolding || speedLocked2x) && !gif.isImage) {
            Row(
                modifier = Modifier
                    .align(Alignment.TopCenter)
                    .padding(top = 112.dp)
                    .liquidGlassCapsule(tinted = true, active = true)
                    .padding(horizontal = 14.dp, vertical = 7.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Icon(
                    if (speedLocked2x) Icons.Default.Lock else Icons.Default.FastForward,
                    contentDescription = null,
                    tint = Color.White,
                    modifier = Modifier.size(14.dp)
                )
                Spacer(Modifier.width(6.dp))
                Text(
                    if (speedLocked2x) "2x Locked · Tap to Unlock" else "2x Speed · Pull down to lock",
                    color = Color.White,
                    fontSize = 12.5.sp,
                    fontWeight = FontWeight.Bold
                )
            }
        }

        if (!collapsed && !isHolding) {
            // Right Action Stack
            Column(
                modifier = Modifier
                    .align(Alignment.BottomEnd)
                    .padding(end = 14.dp, bottom = if (isLandscape) 24.dp else 94.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
                horizontalAlignment = Alignment.CenterHorizontally
            ) {
                ActionCircle(
                    icon = Icons.Default.Favorite,
                    tint = if (liked) AppTheme.accent else Color.White,
                    onClick = { UserStore.toggleLike(gif) }
                )
                ActionCircle(
                    icon = Icons.Default.ThumbDown,
                    tint = Color.White,
                    onClick = onDislike
                )
                ActionCircle(
                    icon = Icons.Default.Share,
                    tint = Color.White,
                    onClick = onShare
                )
                ActionCircle(
                    icon = if (muted) Icons.AutoMirrored.Filled.VolumeOff else Icons.AutoMirrored.Filled.VolumeUp,
                    tint = Color.White,
                    onClick = onToggleMute
                )
                ActionCircle(
                    icon = Icons.Default.Shuffle,
                    tint = Color.White,
                    onClick = onShuffle
                )
            }

            // Bottom-Left Info + Full Wide
            Column(
                modifier = Modifier
                    .align(Alignment.BottomStart)
                    .padding(start = 16.dp, end = 84.dp, bottom = if (isLandscape) 20.dp else 94.dp)
            ) {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                    Row(
                        modifier = Modifier
                            .liquidGlassCapsule(tinted = true)
                            .clickable {
                                if (isLandscape) {
                                    UserStore.updateSettings { it.copy(controlsCollapsed = false) }
                                    activity?.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
                                } else {
                                    UserStore.updateSettings { it.copy(controlsCollapsed = true) }
                                    activity?.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
                                }
                            }
                            .padding(horizontal = 10.dp, vertical = 6.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Icon(
                            if (isLandscape) Icons.Default.FullscreenExit else Icons.Default.Fullscreen,
                            contentDescription = null,
                            tint = Color.White,
                            modifier = Modifier.size(14.dp)
                        )
                        Spacer(Modifier.width(4.dp))
                        Text(
                            if (isLandscape) "Portrait" else "Full Wide",
                            color = Color.White,
                            fontSize = 11.5.sp,
                            fontWeight = FontWeight.Bold
                        )
                    }
                    if (!gif.longVideoSiteLabel.isNullOrBlank()) {
                        Text(
                            gif.longVideoSiteLabel!!,
                            color = AppTheme.accentBright,
                            fontSize = 11.sp,
                            fontWeight = FontWeight.Black,
                            modifier = Modifier
                                .liquidGlassCapsule(tinted = true)
                                .padding(horizontal = 10.dp, vertical = 5.dp)
                        )
                    }
                }
                Spacer(Modifier.height(8.dp))
                val handle = gif.author?.takeIf { it.isNotBlank() } ?: gif.subreddit.orEmpty()
                if (handle.isNotBlank()) {
                    Text(
                        if (gif.isXPost || gif.isIGPost || gif.isOnlyFansPost) "@$handle" else handle,
                        color = Color.White,
                        fontSize = 14.5.sp,
                        fontWeight = FontWeight.Bold
                    )
                }
                if (!gif.title.isNullOrBlank()) {
                    Spacer(Modifier.height(3.dp))
                    Text(
                        gif.title!!,
                        color = Color.White.copy(alpha = 0.88f),
                        fontSize = 13.sp,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis
                    )
                }
            }
        } else if (isLandscape || collapsed) {
            Row(
                modifier = Modifier
                    .align(Alignment.BottomStart)
                    .padding(16.dp)
                    .liquidGlassCapsule(tinted = true)
                    .clickable {
                        onToggleCollapse()
                        if (isLandscape) activity?.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
                    }
                    .padding(horizontal = 12.dp, vertical = 7.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Icon(Icons.Default.FullscreenExit, contentDescription = null, tint = Color.White, modifier = Modifier.size(14.dp))
                Spacer(Modifier.width(5.dp))
                Text(if (isLandscape) "Portrait" else "Show UI", color = Color.White, fontSize = 12.sp, fontWeight = FontWeight.Bold)
            }
        }
    }
}

@Composable
private fun ActionCircle(icon: androidx.compose.ui.graphics.vector.ImageVector, tint: Color, onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .size(44.dp)
            .liquidGlassCircle(tinted = true)
            .clickable { onClick() },
        contentAlignment = Alignment.Center
    ) {
        Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(21.dp))
    }
}
