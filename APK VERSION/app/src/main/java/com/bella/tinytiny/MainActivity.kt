package com.bella.tinytiny

import android.app.Activity
import android.content.Intent
import android.content.pm.ActivityInfo
import android.os.Bundle
import android.view.WindowManager
import android.widget.FrameLayout
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowLeft
import androidx.compose.material.icons.filled.*
import androidx.compose.material.icons.outlined.Explore
import androidx.compose.material.icons.outlined.FavoriteBorder
import androidx.compose.material.icons.outlined.Home
import androidx.compose.material.icons.outlined.Person
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.fragment.app.FragmentActivity
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

enum class GoonedDockTab { HOME, LIKES, BROWSE, PROFILE }

enum class HomeChannel {
    FOLLOWING, FOR_YOU,
    X_FOR_YOU, X_FOLLOWING, X_BOOKMARKS, X_LIKES,
    RULE34,
    IG_REELS, IG_FOLLOWING, IG_SAVED,
    OF_FOR_YOU, OF_TRENDING, OF_LATEST, OF_DMS,
    LONG_ALL, LONG_EPORNER, LONG_XVIDEOS, LONG_PORNHUB, LONG_XHAMSTER, LONG_SPANKBANG, LONG_EROME,
    CUSTOM
}

class MainActivity : FragmentActivity() {
    private val bgScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        syncFlagSecure()
        handleIntent(intent)
        setContent { RootView() }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleIntent(intent)
    }

    override fun onStart() {
        super.onStart()
        RootDeepLinkState.isAppForeground.value = true
        syncFlagSecure()
        bgScope.launch {
            if (LicenseManager.status.value.isActivated) {
                LicenseManager.verifySilently()
                AppState.markLicenseActivated(LicenseManager.isValidAccess)
            }
        }
    }

    override fun onStop() {
        super.onStop()
        RootDeepLinkState.isAppForeground.value = false
        AppState.lock()
        UserStore.shared.saveNow()
        SmartTasteEngine.shared.saveNow()
        bgScope.launch { LicenseManager.syncEncryptedBackupNow() }
    }

    private fun syncFlagSecure() {
        if (AppState.hasPasscode.value && AppState.requirePasscodeOnOpen.value) {
            window.setFlags(WindowManager.LayoutParams.FLAG_SECURE, WindowManager.LayoutParams.FLAG_SECURE)
        } else {
            window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
        }
    }

    private fun handleIntent(intent: Intent?) {
        val data = intent?.data ?: return
        if (data.scheme?.lowercase() == "tinytiny") {
            val host = data.host?.lowercase()
            if (host == "directig") {
                val dropId = data.lastPathSegment
                if (!dropId.isNullOrEmpty() && LicenseManager.isAdmin) {
                    RootDeepLinkState.pendingDirectIGDropId.value = dropId
                    return
                }
            }
            RootDeepLinkState.pendingShareUri.value = data.toString()
        }
    }
}

object RootDeepLinkState {
    val pendingDirectIGDropId = kotlinx.coroutines.flow.MutableStateFlow<String?>(null)
    val pendingShareUri = kotlinx.coroutines.flow.MutableStateFlow<String?>(null)
    val isAppForeground = kotlinx.coroutines.flow.MutableStateFlow(true)
}

@Composable
fun RootView() {
    val ageConfirmed by AppState.ageConfirmed.collectAsState()
    val onboardingCompleted by AppState.onboardingCompleted.collectAsState()
    val licenseActivated by AppState.licenseActivated.collectAsState()
    val passcodeChoiceCompleted by AppState.passcodeChoiceCompleted.collectAsState()
    val isLocked by AppState.isLocked.collectAsState()
    val hasUnlockedOnce by AppState.hasUnlockedOnce.collectAsState()
    val hasPasscode by AppState.hasPasscode.collectAsState()
    val requirePasscodeOnOpen by AppState.requirePasscodeOnOpen.collectAsState()
    val remoteConfig by LicenseManager.remoteConfig.collectAsState()
    val dismissedAnn by LicenseManager.dismissedAnnouncementId.collectAsState()
    val userData by UserStore.shared.data.collectAsState()
    val isAppForeground by RootDeepLinkState.isAppForeground.collectAsState()

    val directIGId by RootDeepLinkState.pendingDirectIGDropId.collectAsState()
    val shareUri by RootDeepLinkState.pendingShareUri.collectAsState()
    var directIGPayload by remember { mutableStateOf<DirectIGDropPayload?>(null) }

    LaunchedEffect(directIGId) {
        val id = directIGId ?: return@LaunchedEffect
        RootDeepLinkState.pendingDirectIGDropId.value = null
        directIGPayload = ShareService.fetchDirectIGDrop(id)
    }

    LaunchedEffect(shareUri) {
        val uri = shareUri ?: return@LaunchedEffect
        RootDeepLinkState.pendingShareUri.value = null
        ShareService.handleIncomingShare(uri)
    }

    Box(modifier = Modifier.fillMaxSize().background(Theme.bg)) {
        when {
            !ageConfirmed -> AgeGateView()
            !onboardingCompleted -> WelcomeOnboardingView { AppState.completeOnboarding() }
            !licenseActivated -> LicenseGateView { AppState.markLicenseActivated(true) }
            !passcodeChoiceCompleted -> PasscodeSetupView(isOnboarding = true) {}
            else -> {
                if (hasUnlockedOnce || !requirePasscodeOnOpen) {
                    GoonedMainShell()
                }
                val ann = remember(remoteConfig, dismissedAnn) { LicenseManager.activeAnnouncement }
                AnimatedVisibility(
                    visible = ann != null,
                    enter = fadeIn(),
                    exit = fadeOut(),
                    modifier = Modifier.align(Alignment.TopCenter)
                ) {
                    if (ann != null) {
                        Row(
                            modifier = Modifier
                                .statusBarsPadding()
                                .padding(horizontal = 14.dp, vertical = 10.dp)
                                .fillMaxWidth()
                                .liquidGlassCard(18.dp, userData.settings.tintedGlass)
                                .padding(horizontal = 14.dp, vertical = 10.dp),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Icon(Icons.Default.Campaign, contentDescription = null, tint = Theme.accentBright, modifier = Modifier.size(18.dp))
                            Spacer(Modifier.width(8.dp))
                            Text(ann.second, color = Color.White, fontSize = 12.5.sp, fontWeight = FontWeight.SemiBold, maxLines = 3, modifier = Modifier.weight(1f))
                            IconButton(
                                onClick = { LicenseManager.dismissAnnouncement(ann.first) },
                                modifier = Modifier.size(28.dp).liquidGlassCircle(userData.settings.tintedGlass)
                            ) {
                                Icon(Icons.Default.Close, contentDescription = "Dismiss", tint = Color.White, modifier = Modifier.size(14.dp))
                            }
                        }
                    }
                }
                val maint = remoteConfig?.maintenance?.takeIf { it.isNotEmpty() }
                if (!LicenseManager.isAdmin && maint != null) {
                    RemoteGateOverlay("Maintenance", maint, Icons.Default.Build, userData.settings.tintedGlass) { LicenseManager.verifySilently() }
                } else if (!LicenseManager.isAdmin && LicenseManager.isUpdateRequired) {
                    RemoteGateOverlay("Update Required", "Please install TinyTiny v${remoteConfig?.minVersion ?: ""} or newer.", Icons.Default.SystemUpdate, userData.settings.tintedGlass) {
                        LicenseManager.verifySilently()
                    }
                }
                if (isLocked) LockView()
                // PrivacyCover ONLY when passcode lock is enabled (exact iOS parity)
                if (!isAppForeground && hasPasscode && requirePasscodeOnOpen) {
                    Box(
                        modifier = Modifier.fillMaxSize().background(Theme.bg),
                        contentAlignment = Alignment.Center
                    ) {
                        Icon(Icons.Default.Lock, contentDescription = null, tint = Theme.accentBright, modifier = Modifier.size(48.dp))
                    }
                }
            }
        }
    }

    directIGPayload?.let { payload ->
        IGDirectSendSheet(payload = payload, onDismiss = { directIGPayload = null })
    }
}

@Composable
private fun RemoteGateOverlay(title: String, message: String, icon: ImageVector, tinted: Boolean, onRetry: suspend () -> Unit) {
    val scope = rememberCoroutineScope()
    var checking by remember { mutableStateOf(false) }
    Box(modifier = Modifier.fillMaxSize().liquidGlassBackground(tinted).padding(24.dp), contentAlignment = Alignment.Center) {
        Column(
            modifier = Modifier.fillMaxWidth().liquidGlassCard(24.dp, tinted).padding(24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(14.dp)
        ) {
            Box(modifier = Modifier.size(68.dp).liquidGlassCircle(tinted), contentAlignment = Alignment.Center) {
                Icon(icon, contentDescription = null, tint = Theme.accentBright, modifier = Modifier.size(30.dp))
            }
            Text(title, color = Color.White, fontSize = 22.sp, fontWeight = FontWeight.Bold)
            Text(message, color = Theme.textSecondary, fontSize = 14.sp, textAlign = TextAlign.Center)
            Box(
                modifier = Modifier
                    .liquidGlassCapsule(tinted, active = true)
                    .clickable(enabled = !checking) { scope.launch { checking = true; onRetry(); checking = false } }
                    .padding(horizontal = 24.dp, vertical = 12.dp)
            ) {
                if (checking) CircularProgressIndicator(color = Color.White, modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
                else Text("Check Again", color = Color.White, fontWeight = FontWeight.Bold)
            }
        }
    }
}

private data class CustomBackHistoryItem(
    val channel: HomeChannel,
    val customSource: FeedSource?,
    val customItems: List<Gif>,
    val customCursor: String?,
    val customHasMore: Boolean,
    val postID: String?,
    val returnTab: GoonedDockTab,
    val creatorGridSource: FeedSource?
)

@Composable
fun GoonedMainShell() {
    val ctx = LocalContext.current
    val activity = ctx as? Activity
    val haptic = LocalHapticFeedback.current
    val userData by UserStore.shared.data.collectAsState()
    val tinted = userData.settings.tintedGlass
    val scope = rememberCoroutineScope()

    val followingModel = remember { FeedModel(FeedSource.Following) }
    val forYouModel = remember { FeedModel(FeedSource.ForYou) }
    val xForYouModel = remember { FeedModel(FeedSource.XForYou) }
    val xFollowingModel = remember { FeedModel(FeedSource.XFollowing) }
    val xBookmarksModel = remember { FeedModel(FeedSource.XBookmarks) }
    val xLikesModel = remember { FeedModel(FeedSource.XLikes) }
    val r34Model = remember { FeedModel(FeedSource.Rule34("")) }
    val igReelsModel = remember { FeedModel(FeedSource.IGReels) }
    val igFollowingModel = remember { FeedModel(FeedSource.IGFollowing) }
    val igSavedModel = remember { FeedModel(FeedSource.IGSaved) }
    val ofForYouModel = remember { FeedModel(FeedSource.OFForYou) }
    val ofTrendingModel = remember { FeedModel(FeedSource.OFTrending) }
    val ofLatestModel = remember { FeedModel(FeedSource.OFLatest) }
    val ofDMsModel = remember { FeedModel(FeedSource.OFDMs) }
    // 7 persistent LongVideo FeedModels matching iOS (preserves scroll position per site!)
    val longAllModel = remember { FeedModel(FeedSource.LongVideos(LongVideoSite.ALL)) }
    val longEpornerModel = remember { FeedModel(FeedSource.LongVideos(LongVideoSite.EPORNER)) }
    val longXVideosModel = remember { FeedModel(FeedSource.LongVideos(LongVideoSite.XVIDEOS)) }
    val longPornhubModel = remember { FeedModel(FeedSource.LongVideos(LongVideoSite.PORNHUB)) }
    val longXHamsterModel = remember { FeedModel(FeedSource.LongVideos(LongVideoSite.XHAMSTER)) }
    val longSpankBangModel = remember { FeedModel(FeedSource.LongVideos(LongVideoSite.SPANKBANG)) }
    val longEromeModel = remember { FeedModel(FeedSource.LongVideos(LongVideoSite.EROME)) }
    val customModel = remember { FeedModel(FeedSource.ForYou) }

    var activeChannel by remember { mutableStateOf(HomeChannel.FOR_YOU) }
    var lastXChannel by remember { mutableStateOf(HomeChannel.X_FOR_YOU) }
    var lastIGChannel by remember { mutableStateOf(HomeChannel.IG_REELS) }
    var lastOFChannel by remember { mutableStateOf(HomeChannel.OF_FOR_YOU) }
    var lastLongChannel by remember { mutableStateOf(HomeChannel.LONG_ALL) }

    var activeTab by remember { mutableStateOf(GoonedDockTab.HOME) }
    val slotPostIDs = remember { mutableStateMapOf<HomeChannel, String?>() }
    val backStack = remember { mutableStateListOf<CustomBackHistoryItem>() }
    var creatorGridSource by remember { mutableStateOf<FeedSource?>(null) }
    var showSettingsModal by remember { mutableStateOf(false) }
    var showXLogin by remember { mutableStateOf(false) }
    var showIGLogin by remember { mutableStateOf(false) }
    var showR34Key by remember { mutableStateOf(false) }
    var pendingFeedAfterLogin by remember { mutableStateOf<FeedSource?>(null) }

    val receivedPost by ShareService.pendingReceivedPost.collectAsState()
    val receivedPosts by ShareService.pendingReceivedPosts.collectAsState()
    val receivedTitle by ShareService.pendingReceivedTitle.collectAsState()
    val isAppForeground by RootDeepLinkState.isAppForeground.collectAsState()

    // Dynamic orientation lock: allow landscape on Home feed, force portrait on Likes/Browse/Profile
    LaunchedEffect(activeTab) {
        activity?.requestedOrientation = if (activeTab == GoonedDockTab.HOME) {
            ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
        } else {
            ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
        }
    }

    // Live taste-change observers: immediately re-rank & purge suppressed items across main feeds
    LaunchedEffect(userData.algorithm.boostedTags, userData.algorithm.blockedTags) {
        for (m in listOf(forYouModel, xForYouModel, r34Model, igReelsModel, ofForYouModel, longAllModel)) {
            m.purgeSuppressedItems()
            m.refreshTailForUpdatedTaste()
        }
    }

    val activeModel = when (activeChannel) {
        HomeChannel.FOLLOWING -> followingModel
        HomeChannel.FOR_YOU -> forYouModel
        HomeChannel.X_FOR_YOU -> xForYouModel
        HomeChannel.X_FOLLOWING -> xFollowingModel
        HomeChannel.X_BOOKMARKS -> xBookmarksModel
        HomeChannel.X_LIKES -> xLikesModel
        HomeChannel.RULE34 -> r34Model
        HomeChannel.IG_REELS -> igReelsModel
        HomeChannel.IG_FOLLOWING -> igFollowingModel
        HomeChannel.IG_SAVED -> igSavedModel
        HomeChannel.OF_FOR_YOU -> ofForYouModel
        HomeChannel.OF_TRENDING -> ofTrendingModel
        HomeChannel.OF_LATEST -> ofLatestModel
        HomeChannel.OF_DMS -> ofDMsModel
        HomeChannel.LONG_ALL -> longAllModel
        HomeChannel.LONG_EPORNER -> longEpornerModel
        HomeChannel.LONG_XVIDEOS -> longXVideosModel
        HomeChannel.LONG_PORNHUB -> longPornhubModel
        HomeChannel.LONG_XHAMSTER -> longXHamsterModel
        HomeChannel.LONG_SPANKBANG -> longSpankBangModel
        HomeChannel.LONG_EROME -> longEromeModel
        HomeChannel.CUSTOM -> customModel
    }

    fun pushBack(returnTab: GoonedDockTab = activeTab, gridSrc: FeedSource? = null) {
        if (backStack.size >= 16) backStack.removeAt(0)
        backStack.add(
            CustomBackHistoryItem(
                channel = activeChannel,
                customSource = if (activeChannel == HomeChannel.CUSTOM) customModel.source.value else null,
                customItems = if (activeChannel == HomeChannel.CUSTOM) customModel.items.value else emptyList(),
                customCursor = if (activeChannel == HomeChannel.CUSTOM) customModel.currentCursor else null,
                customHasMore = if (activeChannel == HomeChannel.CUSTOM) customModel.canLoadMore else true,
                postID = slotPostIDs[activeChannel],
                returnTab = returnTab,
                creatorGridSource = gridSrc
            )
        )
    }

    fun popBack() {
        val prev = backStack.removeLastOrNull()
        if (prev != null) {
            if (prev.channel == HomeChannel.CUSTOM) {
                customModel.switchSource(
                    prev.customSource ?: FeedSource.ForYou,
                    initialItems = prev.customItems,
                    cursor = prev.customCursor,
                    allowLoadMore = prev.customHasMore
                )
                slotPostIDs[HomeChannel.CUSTOM] = prev.postID
                activeChannel = HomeChannel.CUSTOM
            } else {
                activeChannel = prev.channel
                prev.postID?.let { slotPostIDs[prev.channel] = it }
            }
            activeTab = prev.returnTab
            if (prev.creatorGridSource != null) creatorGridSource = prev.creatorGridSource
        } else {
            activeChannel = HomeChannel.FOR_YOU
            activeTab = GoonedDockTab.HOME
        }
    }

    val hasAnyOverlayOrBack = showSettingsModal || showXLogin || showIGLogin || showR34Key ||
        creatorGridSource != null || activeTab != GoonedDockTab.HOME || activeChannel == HomeChannel.CUSTOM

    BackHandler(enabled = hasAnyOverlayOrBack) {
        when {
            showXLogin -> showXLogin = false
            showIGLogin -> showIGLogin = false
            showR34Key -> showR34Key = false
            showSettingsModal -> showSettingsModal = false
            creatorGridSource != null -> creatorGridSource = null
            activeTab != GoonedDockTab.HOME -> activeTab = GoonedDockTab.HOME
            activeChannel == HomeChannel.CUSTOM -> popBack()
        }
    }

    fun isCreatorProfile(src: FeedSource): Boolean = when (src) {
        is FeedSource.User, is FeedSource.XUser, is FeedSource.IGUser, is FeedSource.OFCreator, is FeedSource.Subreddit -> true
        is FeedSource.Rule34 -> src.tag.trim().isNotEmpty()
        else -> false
    }

    fun switchToChannel(target: HomeChannel, model: FeedModel, forceReload: Boolean) {
        val alreadyHere = activeChannel == target && activeTab == GoonedDockTab.HOME
        backStack.clear()
        activeChannel = target
        when (target) {
            HomeChannel.X_FOR_YOU, HomeChannel.X_FOLLOWING, HomeChannel.X_BOOKMARKS, HomeChannel.X_LIKES -> lastXChannel = target
            HomeChannel.IG_REELS, HomeChannel.IG_FOLLOWING, HomeChannel.IG_SAVED -> lastIGChannel = target
            HomeChannel.OF_FOR_YOU, HomeChannel.OF_TRENDING, HomeChannel.OF_LATEST, HomeChannel.OF_DMS -> lastOFChannel = target
            HomeChannel.LONG_ALL, HomeChannel.LONG_EPORNER, HomeChannel.LONG_XVIDEOS, HomeChannel.LONG_PORNHUB, HomeChannel.LONG_XHAMSTER, HomeChannel.LONG_SPANKBANG -> lastLongChannel = target
            else -> {}
        }
        if (forceReload || alreadyHere) {
            slotPostIDs[target] = null
            scope.launch { model.refresh(rotateCursor = true) }
        }
    }

    fun selectFeed(src: FeedSource, forceReload: Boolean = false) {
        if (!forceReload && isCreatorProfile(src)) {
            creatorGridSource = src
            return
        }
        when (src) {
            FeedSource.Following -> switchToChannel(HomeChannel.FOLLOWING, followingModel, forceReload)
            FeedSource.ForYou -> switchToChannel(HomeChannel.FOR_YOU, forYouModel, forceReload)
            FeedSource.XForYou -> switchToChannel(HomeChannel.X_FOR_YOU, xForYouModel, forceReload)
            FeedSource.XFollowing -> switchToChannel(HomeChannel.X_FOLLOWING, xFollowingModel, forceReload)
            FeedSource.XBookmarks -> switchToChannel(HomeChannel.X_BOOKMARKS, xBookmarksModel, forceReload)
            FeedSource.XLikes -> switchToChannel(HomeChannel.X_LIKES, xLikesModel, forceReload)
            FeedSource.IGReels -> switchToChannel(HomeChannel.IG_REELS, igReelsModel, forceReload)
            FeedSource.IGFollowing -> switchToChannel(HomeChannel.IG_FOLLOWING, igFollowingModel, forceReload)
            FeedSource.IGSaved -> switchToChannel(HomeChannel.IG_SAVED, igSavedModel, forceReload)
            FeedSource.OFForYou -> switchToChannel(HomeChannel.OF_FOR_YOU, ofForYouModel, forceReload)
            FeedSource.OFTrending -> switchToChannel(HomeChannel.OF_TRENDING, ofTrendingModel, forceReload)
            FeedSource.OFLatest -> switchToChannel(HomeChannel.OF_LATEST, ofLatestModel, forceReload)
            FeedSource.OFDMs -> switchToChannel(HomeChannel.OF_DMS, ofDMsModel, forceReload)
            is FeedSource.Rule34 -> if (src.tag.isEmpty()) {
                switchToChannel(HomeChannel.RULE34, r34Model, forceReload)
            } else {
                pushBack(activeTab)
                activeChannel = HomeChannel.CUSTOM
                customModel.switchSource(src)
            }
            is FeedSource.LongVideos -> when (src.site) {
                LongVideoSite.ALL -> switchToChannel(HomeChannel.LONG_ALL, longAllModel, forceReload)
                LongVideoSite.EPORNER -> switchToChannel(HomeChannel.LONG_EPORNER, longEpornerModel, forceReload)
                LongVideoSite.XVIDEOS -> switchToChannel(HomeChannel.LONG_XVIDEOS, longXVideosModel, forceReload)
                LongVideoSite.PORNHUB -> switchToChannel(HomeChannel.LONG_PORNHUB, longPornhubModel, forceReload)
                LongVideoSite.XHAMSTER -> switchToChannel(HomeChannel.LONG_XHAMSTER, longXHamsterModel, forceReload)
                LongVideoSite.SPANKBANG -> switchToChannel(HomeChannel.LONG_SPANKBANG, longSpankBangModel, forceReload)
                LongVideoSite.EROME -> switchToChannel(HomeChannel.LONG_EROME, longEromeModel, forceReload)
            }
            else -> {
                if (activeChannel != HomeChannel.CUSTOM || customModel.source.value != src || activeTab != GoonedDockTab.HOME) {
                    pushBack(activeTab)
                }
                activeChannel = HomeChannel.CUSTOM
                if (customModel.source.value != src || forceReload) {
                    slotPostIDs[HomeChannel.CUSTOM] = null
                    customModel.switchSource(src)
                }
            }
        }
        activeTab = GoonedDockTab.HOME
    }

    fun selectXOrLogin(src: FeedSource) {
        if (userData.xSession.isConnected) selectFeed(src)
        else { pendingFeedAfterLogin = src; showXLogin = true }
    }

    fun selectIGOrLogin(src: FeedSource) {
        if (userData.igSession.isConnected) selectFeed(src)
        else { pendingFeedAfterLogin = src; showIGLogin = true }
    }

    LaunchedEffect(receivedPost) {
        receivedPost?.let { p ->
            pushBack(activeTab)
            customModel.switchSource(FeedSource.CustomList("Shared Drop"), initialItems = listOf(p))
            slotPostIDs[HomeChannel.CUSTOM] = p.id
            activeChannel = HomeChannel.CUSTOM
            activeTab = GoonedDockTab.HOME
            ShareService.pendingReceivedPost.value = null
        }
    }

    LaunchedEffect(receivedPosts) {
        receivedPosts?.takeIf { it.isNotEmpty() }?.let { list ->
            pushBack(activeTab)
            customModel.switchSource(FeedSource.CustomList(receivedTitle ?: "Shared Collection"), initialItems = list)
            slotPostIDs[HomeChannel.CUSTOM] = list.first().id
            activeChannel = HomeChannel.CUSTOM
            activeTab = GoonedDockTab.HOME
            ShareService.pendingReceivedPosts.value = null
            ShareService.pendingReceivedTitle.value = null
        }
    }

    // Staggered cold-launch prewarming matching iOS
    LaunchedEffect(Unit) {
        delay(700)
        if (r34Model.items.value.isEmpty()) scope.launch { r34Model.loadMore() }
        delay(400)
        if (ofForYouModel.items.value.isEmpty()) scope.launch { ofForYouModel.loadMore() }
        delay(400)
        if (userData.xSession.isConnected) {
            scope.launch { XWebEngine.warmUp(); if (xForYouModel.items.value.isEmpty()) xForYouModel.loadMore() }
        }
        delay(400)
        if (userData.igSession.isConnected) {
            scope.launch { InstagramWebEngine.warmUp(); if (igReelsModel.items.value.isEmpty()) igReelsModel.loadMore() }
        }
    }

    val isXGroup = activeChannel in setOf(HomeChannel.X_FOR_YOU, HomeChannel.X_FOLLOWING, HomeChannel.X_BOOKMARKS, HomeChannel.X_LIKES)
    val isIGGroup = activeChannel in setOf(HomeChannel.IG_REELS, HomeChannel.IG_FOLLOWING, HomeChannel.IG_SAVED)
    val isOFGroup = activeChannel in setOf(HomeChannel.OF_FOR_YOU, HomeChannel.OF_TRENDING, HomeChannel.OF_LATEST, HomeChannel.OF_DMS)
    val isLongGroup = activeChannel in setOf(HomeChannel.LONG_ALL, HomeChannel.LONG_EPORNER, HomeChannel.LONG_XVIDEOS, HomeChannel.LONG_PORNHUB, HomeChannel.LONG_XHAMSTER, HomeChannel.LONG_SPANKBANG)

    Box(modifier = Modifier.fillMaxSize().background(Color.Black)) {
        // Attached invisible WebView host so Android Chromium runs XWebEngine & InstagramWebEngine unthrottled
        AndroidView(
            factory = { ctx2 ->
                FrameLayout(ctx2).apply {
                    XWebEngine.attachHost(this)
                    InstagramWebEngine.attachHost(this)
                }
            },
            modifier = Modifier.size(1.dp).alpha(0.01f)
        )

        val primaryChannels = listOf(
            HomeChannel.FOLLOWING,
            HomeChannel.FOR_YOU,
            HomeChannel.X_FOR_YOU,
            HomeChannel.RULE34,
            HomeChannel.IG_REELS,
            HomeChannel.OF_FOR_YOU,
            HomeChannel.LONG_ALL,
            HomeChannel.LONG_EROME
        )

        Box(
            modifier = Modifier
                .fillMaxSize()
                .pointerInput(activeChannel, activeTab) {
                    if (activeTab == GoonedDockTab.HOME) {
                        var accumDx = 0f
                        detectHorizontalDragGestures(
                            onDragStart = { accumDx = 0f },
                            onHorizontalDrag = { _, dragAmount -> accumDx += dragAmount },
                            onDragEnd = {
                                // Skip channel swipe if current post is a multi-slide Erome album!
                                val curPostId = slotPostIDs[activeChannel]
                                if (curPostId != null && MediaMetaRegistry.albumItems(curPostId).size > 1) {
                                    accumDx = 0f
                                    return@detectHorizontalDragGestures
                                }
                                if (activeChannel == HomeChannel.CUSTOM && accumDx > 120f) {
                                    popBack()
                                    accumDx = 0f
                                    return@detectHorizontalDragGestures
                                }
                                val curBase = when {
                                    isXGroup -> HomeChannel.X_FOR_YOU
                                    isIGGroup -> HomeChannel.IG_REELS
                                    isOFGroup -> HomeChannel.OF_FOR_YOU
                                    isLongGroup -> HomeChannel.LONG_ALL
                                    else -> activeChannel
                                }
                                val curIdx = primaryChannels.indexOf(curBase)
                                if (curIdx >= 0 && kotlin.math.abs(accumDx) > 120f) {
                                    val nextIdx = (curIdx + if (accumDx < 0) 1 else -1).coerceIn(0, primaryChannels.lastIndex)
                                    if (nextIdx != curIdx) {
                                        when (primaryChannels[nextIdx]) {
                                            HomeChannel.FOLLOWING -> selectFeed(FeedSource.Following)
                                            HomeChannel.FOR_YOU -> selectFeed(FeedSource.ForYou)
                                            HomeChannel.X_FOR_YOU -> selectXOrLogin(FeedSource.XForYou)
                                            HomeChannel.RULE34 -> selectFeed(FeedSource.Rule34(""))
                                            HomeChannel.IG_REELS -> selectIGOrLogin(FeedSource.IGReels)
                                            HomeChannel.OF_FOR_YOU -> selectFeed(FeedSource.OFForYou)
                                            HomeChannel.LONG_ALL -> selectFeed(FeedSource.LongVideos(LongVideoSite.ALL))
                                            HomeChannel.LONG_EROME -> selectFeed(FeedSource.LongVideos(LongVideoSite.EROME))
                                            else -> {}
                                        }
                                    }
                                }
                                accumDx = 0f
                            }
                        )
                    }
                }
        ) {
            // CRITICAL FIX: key(activeChannel) so switching channels NEVER inherits a stale pagerState.currentPage!
            key(activeChannel) {
                FeedView(
                    model = activeModel,
                    isVisible = isAppForeground && activeTab == GoonedDockTab.HOME && !showSettingsModal && !showXLogin && !showIGLogin && !showR34Key && creatorGridSource == null,
                    targetPostId = slotPostIDs[activeChannel],
                    onCurrentPostChanged = { slotPostIDs[activeChannel] = it },
                    onOpenCategories = { activeTab = GoonedDockTab.BROWSE },
                    onSelectSubreddit = { selectFeed(FeedSource.Subreddit(it)) },
                    onSelectUser = { selectFeed(FeedSource.User(it)) },
                    onSelectXUser = { selectXOrLogin(FeedSource.XUser(it)) },
                    onSelectIGUser = { selectIGOrLogin(FeedSource.IGUser(it)) },
                    onSelectRule34Tag = { selectFeed(FeedSource.Rule34(it)) },
                    onSelectOFCreator = { id, h -> selectFeed(FeedSource.OFCreator(id, h, null)) },
                    onConnectX = { pendingFeedAfterLogin = if (activeModel.source.value.isXFeed) activeModel.source.value else FeedSource.XForYou; showXLogin = true },
                    onConnectIG = { pendingFeedAfterLogin = if (activeModel.source.value.isIGFeed) activeModel.source.value else FeedSource.IGReels; showIGLogin = true }
                )
            }
        }

        // Top Channel Rail & Single Centered Glass Sub-Channel Pill
        if (activeTab == GoonedDockTab.HOME && !userData.settings.controlsCollapsed) {
            Column(
                modifier = Modifier
                    .align(Alignment.TopCenter)
                    .statusBarsPadding()
                    .fillMaxWidth(),
                horizontalAlignment = Alignment.CenterHorizontally
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .padding(horizontal = 12.dp, vertical = 8.dp)
                        .fillMaxWidth()
                ) {
                    IconButton(onClick = { activeTab = GoonedDockTab.BROWSE }, modifier = Modifier.size(38.dp).liquidGlassCircle(tinted)) {
                        Icon(Icons.Default.Search, contentDescription = "Explore", tint = Color.White)
                    }
                    Spacer(Modifier.width(8.dp))
                    if (activeChannel == HomeChannel.CUSTOM) {
                        Spacer(Modifier.weight(1f))
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier
                                .liquidGlassCapsule(tinted)
                                .clickable { popBack() }
                                .padding(horizontal = 14.dp, vertical = 8.dp)
                        ) {
                            Icon(Icons.AutoMirrored.Filled.KeyboardArrowLeft, contentDescription = "Back", tint = Color.White, modifier = Modifier.size(18.dp))
                            Text(customModel.source.value.displayTitle, color = Color.White, fontSize = 13.sp, fontWeight = FontWeight.Bold, maxLines = 1)
                        }
                        Spacer(Modifier.weight(1f))
                    } else {
                        Row(
                            modifier = Modifier.weight(1f).horizontalScroll(rememberScrollState()),
                            horizontalArrangement = Arrangement.spacedBy(14.dp),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            ChannelTextTab("Following", activeChannel == HomeChannel.FOLLOWING) { selectFeed(FeedSource.Following) }
                            ChannelTextTab("For You", activeChannel == HomeChannel.FOR_YOU) { selectFeed(FeedSource.ForYou) }
                            ChannelIconTab(active = isXGroup, onClick = {
                                val target = when (lastXChannel) {
                                    HomeChannel.X_FOLLOWING -> FeedSource.XFollowing
                                    HomeChannel.X_BOOKMARKS -> FeedSource.XBookmarks
                                    HomeChannel.X_LIKES -> FeedSource.XLikes
                                    else -> FeedSource.XForYou
                                }
                                selectXOrLogin(target)
                            }) {
                                BrandLogoX(26.dp, active = isXGroup, connected = userData.xSession.isConnected)
                            }
                            ChannelIconTab(active = activeChannel == HomeChannel.RULE34, onClick = { selectFeed(FeedSource.Rule34("")) }) {
                                BrandLogoRule34(26.dp, active = activeChannel == HomeChannel.RULE34)
                            }
                            ChannelIconTab(active = isIGGroup, onClick = {
                                val target = when (lastIGChannel) {
                                    HomeChannel.IG_FOLLOWING -> FeedSource.IGFollowing
                                    HomeChannel.IG_SAVED -> FeedSource.IGSaved
                                    else -> FeedSource.IGReels
                                }
                                selectIGOrLogin(target)
                            }) {
                                BrandLogoInstagram(26.dp, active = isIGGroup, connected = userData.igSession.isConnected)
                            }
                            ChannelIconTab(active = isOFGroup, onClick = {
                                val target = when (lastOFChannel) {
                                    HomeChannel.OF_TRENDING -> FeedSource.OFTrending
                                    HomeChannel.OF_LATEST -> FeedSource.OFLatest
                                    HomeChannel.OF_DMS -> FeedSource.OFDMs
                                    else -> FeedSource.OFForYou
                                }
                                selectFeed(target)
                            }) {
                                BrandLogoOnlyFans(26.dp, active = isOFGroup)
                            }
                            ChannelIconTab(active = isLongGroup, onClick = {
                                val site = when (lastLongChannel) {
                                    HomeChannel.LONG_EPORNER -> LongVideoSite.EPORNER
                                    HomeChannel.LONG_XVIDEOS -> LongVideoSite.XVIDEOS
                                    HomeChannel.LONG_PORNHUB -> LongVideoSite.PORNHUB
                                    HomeChannel.LONG_XHAMSTER -> LongVideoSite.XHAMSTER
                                    HomeChannel.LONG_SPANKBANG -> LongVideoSite.SPANKBANG
                                    else -> LongVideoSite.ALL
                                }
                                selectFeed(FeedSource.LongVideos(site))
                            }) {
                                BrandLogoLongVideos(26.dp, active = isLongGroup)
                            }
                            ChannelIconTab(active = activeChannel == HomeChannel.LONG_EROME, onClick = { selectFeed(FeedSource.LongVideos(LongVideoSite.EROME)) }) {
                                BrandLogoErome(26.dp, active = activeChannel == HomeChannel.LONG_EROME)
                            }
                        }
                    }
                    Spacer(Modifier.width(8.dp))
                    IconButton(onClick = { showSettingsModal = true }, modifier = Modifier.size(38.dp).liquidGlassCircle(tinted)) {
                        Icon(Icons.Default.Settings, contentDescription = "Settings", tint = Color.White)
                    }
                }

                // Single centered liquidGlassCapsule sub-channel switcher (exact iOS parity!)
                val subChannels: List<Triple<String, Boolean, () -> Unit>> = when {
                    isXGroup -> listOf(
                        Triple("For You", activeChannel == HomeChannel.X_FOR_YOU, { selectXOrLogin(FeedSource.XForYou) }),
                        Triple("Following", activeChannel == HomeChannel.X_FOLLOWING, { selectXOrLogin(FeedSource.XFollowing) }),
                        Triple("Bookmarks", activeChannel == HomeChannel.X_BOOKMARKS, { selectXOrLogin(FeedSource.XBookmarks) }),
                        Triple("Likes", activeChannel == HomeChannel.X_LIKES, { selectXOrLogin(FeedSource.XLikes) })
                    )
                    isIGGroup -> listOf(
                        Triple("Reels", activeChannel == HomeChannel.IG_REELS, { selectIGOrLogin(FeedSource.IGReels) }),
                        Triple("Following", activeChannel == HomeChannel.IG_FOLLOWING, { selectIGOrLogin(FeedSource.IGFollowing) }),
                        Triple("Saved", activeChannel == HomeChannel.IG_SAVED, { selectIGOrLogin(FeedSource.IGSaved) })
                    )
                    isOFGroup -> listOf(
                        Triple("For You", activeChannel == HomeChannel.OF_FOR_YOU, { selectFeed(FeedSource.OFForYou) }),
                        Triple("Trending", activeChannel == HomeChannel.OF_TRENDING, { selectFeed(FeedSource.OFTrending) }),
                        Triple("Latest", activeChannel == HomeChannel.OF_LATEST, { selectFeed(FeedSource.OFLatest) }),
                        Triple("DMs", activeChannel == HomeChannel.OF_DMS, { selectFeed(FeedSource.OFDMs) })
                    )
                    isLongGroup -> listOf(
                        Triple("All", activeChannel == HomeChannel.LONG_ALL, { selectFeed(FeedSource.LongVideos(LongVideoSite.ALL)) }),
                        Triple("Eporner", activeChannel == HomeChannel.LONG_EPORNER, { selectFeed(FeedSource.LongVideos(LongVideoSite.EPORNER)) }),
                        Triple("XVideos", activeChannel == HomeChannel.LONG_XVIDEOS, { selectFeed(FeedSource.LongVideos(LongVideoSite.XVIDEOS)) }),
                        Triple("Pornhub", activeChannel == HomeChannel.LONG_PORNHUB, { selectFeed(FeedSource.LongVideos(LongVideoSite.PORNHUB)) }),
                        Triple("xHamster", activeChannel == HomeChannel.LONG_XHAMSTER, { selectFeed(FeedSource.LongVideos(LongVideoSite.XHAMSTER)) }),
                        Triple("SpankBang", activeChannel == HomeChannel.LONG_SPANKBANG, { selectFeed(FeedSource.LongVideos(LongVideoSite.SPANKBANG)) })
                    )
                    else -> emptyList()
                }
                if (subChannels.isNotEmpty()) {
                    Row(
                        modifier = Modifier
                            .padding(horizontal = 14.dp, vertical = 2.dp)
                            .liquidGlassCapsule(tinted = tinted)
                            .horizontalScroll(rememberScrollState())
                            .padding(horizontal = 6.dp, vertical = 4.dp),
                        horizontalArrangement = Arrangement.spacedBy(4.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        subChannels.forEach { (lbl, isAct, act) ->
                            Box(
                                modifier = Modifier
                                    .clip(CircleShape)
                                    .background(if (isAct) Color.White.copy(0.22f) else Color.Transparent)
                                    .clickable { act() }
                                    .padding(horizontal = 11.dp, vertical = 4.dp)
                            ) {
                                Text(
                                    lbl,
                                    color = if (isAct) Color.White else Color.White.copy(0.68f),
                                    fontSize = 11.5.sp,
                                    fontWeight = if (isAct) FontWeight.Bold else FontWeight.Medium
                                )
                            }
                        }
                    }
                }
            }
        }

        when (activeTab) {
            GoonedDockTab.LIKES -> GoonedLikesView(
                onOpenSettings = { showSettingsModal = true },
                onStartStash = { activeTab = GoonedDockTab.HOME },
                onPlayLikedPost = { post ->
                    pushBack(GoonedDockTab.LIKES)
                    customModel.switchSource(FeedSource.CustomList("Liked"), initialItems = userData.liked)
                    slotPostIDs[HomeChannel.CUSTOM] = post.id
                    activeChannel = HomeChannel.CUSTOM
                    activeTab = GoonedDockTab.HOME
                },
                onPlayOfflinePost = { post ->
                    pushBack(GoonedDockTab.LIKES)
                    customModel.switchSource(FeedSource.CustomList("Offline Vault"), initialItems = userData.downloaded)
                    slotPostIDs[HomeChannel.CUSTOM] = post.id
                    activeChannel = HomeChannel.CUSTOM
                    activeTab = GoonedDockTab.HOME
                }
            )
            GoonedDockTab.BROWSE -> {
                val defaultScope = when {
                    isOFGroup -> BrowseScope.ONLYFANS
                    activeChannel == HomeChannel.RULE34 -> BrowseScope.RULE34
                    isXGroup -> BrowseScope.X
                    isIGGroup -> BrowseScope.IG
                    activeChannel == HomeChannel.LONG_EROME -> BrowseScope.EROME
                    isLongGroup -> BrowseScope.LONG_VIDEOS
                    else -> BrowseScope.ALL
                }
                GoonedBrowseOverlay(
                    initialScope = defaultScope,
                    onClose = { activeTab = GoonedDockTab.HOME },
                    onSelectFeed = { src ->
                        when {
                            src.isXFeed -> selectXOrLogin(src)
                            src.isIGFeed -> selectIGOrLogin(src)
                            else -> selectFeed(src)
                        }
                    },
                    onOpenPost = { post ->
                        pushBack(GoonedDockTab.BROWSE)
                        customModel.switchSource(FeedSource.CustomList("Shared Drop"), initialItems = listOf(post))
                        slotPostIDs[HomeChannel.CUSTOM] = post.id
                        activeChannel = HomeChannel.CUSTOM
                        activeTab = GoonedDockTab.HOME
                    },
                    onConnectX = { pendingFeedAfterLogin = FeedSource.XForYou; showXLogin = true },
                    onConnectIG = { pendingFeedAfterLogin = FeedSource.IGReels; showIGLogin = true },
                    onSetupR34Key = { showR34Key = true }
                )
            }
            GoonedDockTab.PROFILE -> GoonedFollowsView(
                onOpenSettings = { showSettingsModal = true },
                onSelectFeed = { src ->
                    when {
                        src.isXFeed -> selectXOrLogin(src)
                        src.isIGFeed -> selectIGOrLogin(src)
                        else -> selectFeed(src)
                    }
                },
                onConnectX = { pendingFeedAfterLogin = FeedSource.XForYou; showXLogin = true },
                onConnectIG = { pendingFeedAfterLogin = FeedSource.IGReels; showIGLogin = true }
            )
            else -> {}
        }

        // Full-Width Liquid Glass Bottom Dock with Swipe-Down-to-Collapse & Haptics (exact iOS parity)
        if (activeTab != GoonedDockTab.BROWSE && !(activeTab == GoonedDockTab.HOME && userData.settings.controlsCollapsed)) {
            Row(
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .navigationBarsPadding()
                    .padding(horizontal = 24.dp, vertical = 10.dp)
                    .fillMaxWidth()
                    .height(58.dp)
                    .liquidGlassCapsule(tinted)
                    .pointerInput(activeTab) {
                        var accumDy = 0f
                        detectVerticalDragGestures(
                            onDragStart = { accumDy = 0f },
                            onVerticalDrag = { _, dy -> accumDy += dy },
                            onDragEnd = {
                                if (activeTab == GoonedDockTab.HOME && accumDy > 18f) {
                                    UserStore.shared.updateSettings { it.copy(controlsCollapsed = true) }
                                }
                                accumDy = 0f
                            }
                        )
                    }
                    .padding(horizontal = 12.dp),
                horizontalArrangement = Arrangement.SpaceEvenly,
                verticalAlignment = Alignment.CenterVertically
            ) {
                DockButton(Icons.Default.Home, Icons.Outlined.Home, activeTab == GoonedDockTab.HOME) {
                    haptic.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                    if (activeTab == GoonedDockTab.HOME) {
                        selectFeed(FeedSource.ForYou, forceReload = activeChannel == HomeChannel.FOR_YOU)
                    } else {
                        activeTab = GoonedDockTab.HOME
                    }
                }
                DockButton(Icons.Default.Favorite, Icons.Outlined.FavoriteBorder, activeTab == GoonedDockTab.LIKES) {
                    haptic.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                    activeTab = GoonedDockTab.LIKES
                }
                DockButton(Icons.Default.Explore, Icons.Outlined.Explore, activeTab == GoonedDockTab.BROWSE) {
                    haptic.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                    activeTab = GoonedDockTab.BROWSE
                }
                DockButton(Icons.Default.Person, Icons.Outlined.Person, activeTab == GoonedDockTab.PROFILE) {
                    haptic.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                    activeTab = GoonedDockTab.PROFILE
                }
            }
        }

        creatorGridSource?.let { gridSrc ->
            CreatorProfileGridView(
                source = gridSrc,
                onClose = { creatorGridSource = null },
                onSelectPost = { post, loadedItems, cursor, canLoadMore ->
                    pushBack(activeTab, gridSrc)
                    customModel.switchSource(gridSrc, loadedItems, cursor, canLoadMore)
                    slotPostIDs[HomeChannel.CUSTOM] = post.id
                    activeChannel = HomeChannel.CUSTOM
                    creatorGridSource = null
                    activeTab = GoonedDockTab.HOME
                }
            )
        }

        if (showSettingsModal) {
            GoonedSettingsModal(
                onDismiss = { showSettingsModal = false },
                onConnectX = { showSettingsModal = false; showXLogin = true },
                onConnectIG = { showSettingsModal = false; showIGLogin = true },
                onSetupR34Key = { showSettingsModal = false; showR34Key = true }
            )
        }
        if (showXLogin) {
            XLoginSheet(
                onConnected = {
                    showXLogin = false
                    selectFeed(pendingFeedAfterLogin ?: FeedSource.XForYou, forceReload = true)
                    pendingFeedAfterLogin = null
                },
                onDismiss = { showXLogin = false }
            )
        }
        if (showIGLogin) {
            InstagramLoginSheet(
                onConnected = {
                    showIGLogin = false
                    selectFeed(pendingFeedAfterLogin ?: FeedSource.IGReels, forceReload = true)
                    pendingFeedAfterLogin = null
                },
                onDismiss = { showIGLogin = false }
            )
        }
        if (showR34Key) {
            Rule34KeySheet(onDismiss = { showR34Key = false })
        }
    }
}

@Composable
private fun ChannelTextTab(label: String, active: Boolean, onClick: () -> Unit) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier = Modifier
            .clickable { onClick() }
            .padding(horizontal = 4.dp, vertical = 4.dp)
    ) {
        Text(
            text = label,
            color = if (active) Color.White else Color.White.copy(alpha = 0.62f),
            fontSize = if (active) 15.sp else 13.5.sp,
            fontWeight = if (active) FontWeight.Bold else FontWeight.Medium
        )
        Spacer(Modifier.height(3.dp))
        Box(
            modifier = Modifier
                .width(16.dp)
                .height(2.5.dp)
                .clip(CircleShape)
                .background(if (active) Color.White else Color.Transparent)
        )
    }
}

@Composable
private fun ChannelIconTab(
    active: Boolean,
    onClick: () -> Unit,
    icon: @Composable () -> Unit
) {
    Box(
        modifier = Modifier
            .clickable { onClick() }
            .scale(if (active) 1.08f else 0.90f)
            .alpha(if (active) 1f else 0.72f)
            .padding(horizontal = 2.dp, vertical = 2.dp),
        contentAlignment = Alignment.Center
    ) {
        icon()
    }
}

@Composable
private fun DockButton(
    filledIcon: ImageVector,
    outlinedIcon: ImageVector,
    active: Boolean,
    onClick: () -> Unit
) {
    Box(
        modifier = Modifier
            .size(46.dp)
            .clip(CircleShape)
            .background(if (active) Color.White.copy(alpha = 0.16f) else Color.Transparent)
            .then(if (active) Modifier.border(0.9.dp, Color.White.copy(0.28f), CircleShape) else Modifier)
            .clickable { onClick() },
        contentAlignment = Alignment.Center
    ) {
        Icon(
            imageVector = if (active) filledIcon else outlinedIcon,
            contentDescription = null,
            tint = if (active) Color.White else Color.White.copy(alpha = 0.65f),
            modifier = Modifier.size(23.dp)
        )
    }
}
