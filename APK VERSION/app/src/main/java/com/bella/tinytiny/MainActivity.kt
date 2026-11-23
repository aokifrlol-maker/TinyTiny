package com.bella.tinytiny

import android.content.Intent
import android.os.Bundle
import android.view.WindowManager
import android.widget.FrameLayout
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowLeft
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.fragment.app.FragmentActivity
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

enum class GoonedDockTab { HOME, LIKES, BROWSE, PROFILE }

enum class HomeChannel {
    FOLLOWING, FOR_YOU,
    X_FOR_YOU, X_FOLLOWING, X_BOOKMARKS, X_LIKES,
    RULE34,
    IG_REELS, IG_FOLLOWING, IG_SAVED,
    OF_FOR_YOU, OF_TRENDING, OF_LATEST, OF_DMS,
    LONG_ALL, LONG_EROME,
    CUSTOM
}

class MainActivity : FragmentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        window.setFlags(WindowManager.LayoutParams.FLAG_SECURE, WindowManager.LayoutParams.FLAG_SECURE)
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
    }

    override fun onStop() {
        super.onStop()
        RootDeepLinkState.isAppForeground.value = false
        AppState.lock()
        UserStore.shared.saveNow()
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
    val requirePasscodeOnOpen by AppState.requirePasscodeOnOpen.collectAsState()
    val remoteConfig by LicenseManager.remoteConfig.collectAsState()
    val dismissedAnn by LicenseManager.dismissedAnnouncementId.collectAsState()
    val userData by UserStore.shared.data.collectAsState()

    val directIGId by RootDeepLinkState.pendingDirectIGDropId.collectAsState()
    val shareUri by RootDeepLinkState.pendingShareUri.collectAsState()
    var directIGPayload by remember { mutableStateOf<DirectIGDropPayload?>(null) }

    LaunchedEffect(Unit) {
        if (LicenseManager.status.value.isActivated) {
            LicenseManager.verifySilently()
            AppState.markLicenseActivated(LicenseManager.isValidAccess)
        }
    }

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
                if (ann != null) {
                    Row(
                        modifier = Modifier
                            .align(Alignment.TopCenter)
                            .statusBarsPadding()
                            .padding(horizontal = 14.dp, vertical = 10.dp)
                            .fillMaxWidth()
                            .liquidGlassCard(18.dp, userData.settings.tintedGlass)
                            .padding(horizontal = 14.dp, vertical = 10.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Icon(Icons.Default.Campaign, contentDescription = null, tint = Theme.accentBright, modifier = Modifier.size(18.dp))
                        Spacer(Modifier.width(8.dp))
                        Text(ann.second, color = Color.White, fontSize = 12.5.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
                        IconButton(onClick = { LicenseManager.dismissAnnouncement(ann.first) }, modifier = Modifier.size(24.dp)) {
                            Icon(Icons.Default.Close, contentDescription = "Dismiss", tint = Color.White, modifier = Modifier.size(14.dp))
                        }
                    }
                }
                val maint = remoteConfig?.maintenance?.takeIf { it.isNotEmpty() }
                if (!LicenseManager.isAdmin && maint != null) {
                    RemoteGateOverlay("Maintenance", maint, userData.settings.tintedGlass) { LicenseManager.verifySilently() }
                } else if (!LicenseManager.isAdmin && LicenseManager.isUpdateRequired) {
                    RemoteGateOverlay("Update Required", "Please install TinyTiny v${remoteConfig?.minVersion ?: ""} or newer.", userData.settings.tintedGlass) {
                        LicenseManager.verifySilently()
                    }
                }
                if (isLocked) LockView()
            }
        }
    }

    directIGPayload?.let { payload ->
        IGDirectSendSheet(payload = payload, onDismiss = { directIGPayload = null })
    }
}

@Composable
private fun RemoteGateOverlay(title: String, message: String, tinted: Boolean, onRetry: suspend () -> Unit) {
    val scope = rememberCoroutineScope()
    var checking by remember { mutableStateOf(false) }
    Box(modifier = Modifier.fillMaxSize().liquidGlassBackground(tinted).padding(24.dp), contentAlignment = Alignment.Center) {
        Column(
            modifier = Modifier.fillMaxWidth().liquidGlassCard(24.dp, tinted).padding(24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(14.dp)
        ) {
            Text(title, color = Color.White, fontSize = 22.sp, fontWeight = FontWeight.Bold)
            Text(message, color = Theme.textSecondary, fontSize = 14.sp, textAlign = TextAlign.Center)
            Button(
                onClick = { scope.launch { checking = true; onRetry(); checking = false } },
                enabled = !checking,
                colors = ButtonDefaults.buttonColors(containerColor = Theme.accent)
            ) {
                if (checking) CircularProgressIndicator(color = Color.White, modifier = Modifier.size(18.dp))
                else Text("Check Again", fontWeight = FontWeight.Bold)
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
    val longAllModel = remember { FeedModel(FeedSource.LongVideos(LongVideoSite.ALL)) }
    val longEromeModel = remember { FeedModel(FeedSource.LongVideos(LongVideoSite.EROME)) }
    val customModel = remember { FeedModel(FeedSource.ForYou) }

    var activeChannel by remember { mutableStateOf(HomeChannel.FOR_YOU) }
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
        HomeChannel.LONG_EROME -> longEromeModel
        HomeChannel.CUSTOM -> customModel
    }

    fun pushBack(returnTab: GoonedDockTab = activeTab, gridSrc: FeedSource? = null) {
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

    fun isCreatorProfile(src: FeedSource): Boolean = when (src) {
        is FeedSource.User, is FeedSource.XUser, is FeedSource.IGUser, is FeedSource.OFCreator, is FeedSource.Subreddit -> true
        is FeedSource.Rule34 -> src.tag.trim().isNotEmpty()
        else -> false
    }

    fun selectFeed(src: FeedSource, forceReload: Boolean = false) {
        if (!forceReload && isCreatorProfile(src)) {
            creatorGridSource = src
            return
        }
        when (src) {
            FeedSource.Following -> { backStack.clear(); activeChannel = HomeChannel.FOLLOWING }
            FeedSource.ForYou -> { backStack.clear(); activeChannel = HomeChannel.FOR_YOU }
            FeedSource.XForYou -> { backStack.clear(); activeChannel = HomeChannel.X_FOR_YOU }
            FeedSource.XFollowing -> { backStack.clear(); activeChannel = HomeChannel.X_FOLLOWING }
            FeedSource.XBookmarks -> { backStack.clear(); activeChannel = HomeChannel.X_BOOKMARKS }
            FeedSource.XLikes -> { backStack.clear(); activeChannel = HomeChannel.X_LIKES }
            FeedSource.IGReels -> { backStack.clear(); activeChannel = HomeChannel.IG_REELS }
            FeedSource.IGFollowing -> { backStack.clear(); activeChannel = HomeChannel.IG_FOLLOWING }
            FeedSource.IGSaved -> { backStack.clear(); activeChannel = HomeChannel.IG_SAVED }
            FeedSource.OFForYou -> { backStack.clear(); activeChannel = HomeChannel.OF_FOR_YOU }
            FeedSource.OFTrending -> { backStack.clear(); activeChannel = HomeChannel.OF_TRENDING }
            FeedSource.OFLatest -> { backStack.clear(); activeChannel = HomeChannel.OF_LATEST }
            FeedSource.OFDMs -> { backStack.clear(); activeChannel = HomeChannel.OF_DMS }
            is FeedSource.Rule34 -> if (src.tag.isEmpty()) { backStack.clear(); activeChannel = HomeChannel.RULE34 } else {
                pushBack(activeTab)
                activeChannel = HomeChannel.CUSTOM
                customModel.switchSource(src)
            }
            is FeedSource.LongVideos -> {
                backStack.clear()
                activeChannel = if (src.site == LongVideoSite.EROME) HomeChannel.LONG_EROME else HomeChannel.LONG_ALL
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

    LaunchedEffect(Unit) {
        delay(600)
        if (r34Model.items.value.isEmpty()) scope.launch { r34Model.loadMore() }
        if (ofForYouModel.items.value.isEmpty()) scope.launch { ofForYouModel.loadMore() }
        if (userData.xSession.isConnected) scope.launch { XWebEngine.warmUp() }
        if (userData.igSession.isConnected) scope.launch { InstagramWebEngine.warmUp() }
    }

    Box(modifier = Modifier.fillMaxSize().background(Color.Black)) {
        // Attached invisible WebView host so Android Chromium runs XWebEngine & InstagramWebEngine JS/fetch unthrottled
        AndroidView(
            factory = { ctx ->
                FrameLayout(ctx).apply {
                    XWebEngine.attachHost(this)
                    InstagramWebEngine.attachHost(this)
                }
            },
            modifier = Modifier.size(1.dp).alpha(0.01f)
        )

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
            onConnectX = { pendingFeedAfterLogin = FeedSource.XForYou; showXLogin = true },
            onConnectIG = { pendingFeedAfterLogin = FeedSource.IGReels; showIGLogin = true }
        )

        if (activeTab == GoonedDockTab.HOME && !userData.settings.controlsCollapsed) {
            Column(
                modifier = Modifier
                    .align(Alignment.TopCenter)
                    .statusBarsPadding()
                    .fillMaxWidth()
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
                            horizontalArrangement = Arrangement.spacedBy(12.dp),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            ChannelTextTab("Following", activeChannel == HomeChannel.FOLLOWING) { selectFeed(FeedSource.Following) }
                            ChannelTextTab("For You", activeChannel == HomeChannel.FOR_YOU) { selectFeed(FeedSource.ForYou) }
                            ChannelIconTab(
                                active = activeChannel == HomeChannel.X_FOR_YOU || activeChannel == HomeChannel.X_FOLLOWING || activeChannel == HomeChannel.X_BOOKMARKS || activeChannel == HomeChannel.X_LIKES,
                                showDot = !userData.xSession.isConnected,
                                onClick = { selectXOrLogin(FeedSource.XForYou) }
                            ) {
                                Box(
                                    modifier = Modifier.size(30.dp).liquidGlassCircle(tinted = false),
                                    contentAlignment = Alignment.Center
                                ) { BrandLogoX(16.dp) }
                            }
                            ChannelIconTab(active = activeChannel == HomeChannel.RULE34, onClick = { selectFeed(FeedSource.Rule34("")) }) {
                                BrandLogoRule34(28.dp)
                            }
                            ChannelIconTab(
                                active = activeChannel == HomeChannel.IG_REELS || activeChannel == HomeChannel.IG_FOLLOWING || activeChannel == HomeChannel.IG_SAVED,
                                onClick = { selectIGOrLogin(FeedSource.IGReels) }
                            ) {
                                BrandLogoInstagram(28.dp)
                            }
                            ChannelIconTab(
                                active = activeChannel == HomeChannel.OF_FOR_YOU || activeChannel == HomeChannel.OF_TRENDING || activeChannel == HomeChannel.OF_LATEST || activeChannel == HomeChannel.OF_DMS,
                                onClick = { selectFeed(FeedSource.OFForYou) }
                            ) {
                                BrandLogoOnlyFans(28.dp)
                            }
                            ChannelIconTab(active = activeChannel == HomeChannel.LONG_ALL, onClick = { selectFeed(FeedSource.LongVideos(LongVideoSite.ALL)) }) {
                                BrandLogoLongVideos(28.dp)
                            }
                            ChannelIconTab(active = activeChannel == HomeChannel.LONG_EROME, onClick = { selectFeed(FeedSource.LongVideos(LongVideoSite.EROME)) }) {
                                BrandLogoErome(28.dp)
                            }
                        }
                    }
                    Spacer(Modifier.width(8.dp))
                    IconButton(onClick = { showSettingsModal = true }, modifier = Modifier.size(38.dp).liquidGlassCircle(tinted)) {
                        Icon(Icons.Default.Settings, contentDescription = "Settings", tint = Color.White)
                    }
                }

                // Sub-channel switcher pills for X, IG, OF, and Long Videos (matches iOS)
                val subChannels: List<Triple<String, Boolean, () -> Unit>> = when (activeChannel) {
                    HomeChannel.X_FOR_YOU, HomeChannel.X_FOLLOWING, HomeChannel.X_BOOKMARKS, HomeChannel.X_LIKES -> listOf(
                        Triple("For You", activeChannel == HomeChannel.X_FOR_YOU, { selectXOrLogin(FeedSource.XForYou) }),
                        Triple("Following", activeChannel == HomeChannel.X_FOLLOWING, { selectXOrLogin(FeedSource.XFollowing) }),
                        Triple("Bookmarks", activeChannel == HomeChannel.X_BOOKMARKS, { selectXOrLogin(FeedSource.XBookmarks) }),
                        Triple("Likes", activeChannel == HomeChannel.X_LIKES, { selectXOrLogin(FeedSource.XLikes) })
                    )
                    HomeChannel.IG_REELS, HomeChannel.IG_FOLLOWING, HomeChannel.IG_SAVED -> listOf(
                        Triple("Reels", activeChannel == HomeChannel.IG_REELS, { selectIGOrLogin(FeedSource.IGReels) }),
                        Triple("Following", activeChannel == HomeChannel.IG_FOLLOWING, { selectIGOrLogin(FeedSource.IGFollowing) }),
                        Triple("Saved", activeChannel == HomeChannel.IG_SAVED, { selectIGOrLogin(FeedSource.IGSaved) })
                    )
                    HomeChannel.OF_FOR_YOU, HomeChannel.OF_TRENDING, HomeChannel.OF_LATEST, HomeChannel.OF_DMS -> listOf(
                        Triple("For You", activeChannel == HomeChannel.OF_FOR_YOU, { selectFeed(FeedSource.OFForYou) }),
                        Triple("Trending", activeChannel == HomeChannel.OF_TRENDING, { selectFeed(FeedSource.OFTrending) }),
                        Triple("Latest", activeChannel == HomeChannel.OF_LATEST, { selectFeed(FeedSource.OFLatest) }),
                        Triple("DMs", activeChannel == HomeChannel.OF_DMS, { selectFeed(FeedSource.OFDMs) })
                    )
                    HomeChannel.LONG_ALL -> listOf(
                        Triple("All Sites", longAllModel.source.value == FeedSource.LongVideos(LongVideoSite.ALL), { longAllModel.switchSource(FeedSource.LongVideos(LongVideoSite.ALL)) }),
                        Triple("Eporner", longAllModel.source.value == FeedSource.LongVideos(LongVideoSite.EPORNER), { longAllModel.switchSource(FeedSource.LongVideos(LongVideoSite.EPORNER)) }),
                        Triple("XVideos", longAllModel.source.value == FeedSource.LongVideos(LongVideoSite.XVIDEOS), { longAllModel.switchSource(FeedSource.LongVideos(LongVideoSite.XVIDEOS)) }),
                        Triple("Pornhub", longAllModel.source.value == FeedSource.LongVideos(LongVideoSite.PORNHUB), { longAllModel.switchSource(FeedSource.LongVideos(LongVideoSite.PORNHUB)) }),
                        Triple("xHamster", longAllModel.source.value == FeedSource.LongVideos(LongVideoSite.XHAMSTER), { longAllModel.switchSource(FeedSource.LongVideos(LongVideoSite.XHAMSTER)) }),
                        Triple("SpankBang", longAllModel.source.value == FeedSource.LongVideos(LongVideoSite.SPANKBANG), { longAllModel.switchSource(FeedSource.LongVideos(LongVideoSite.SPANKBANG)) })
                    )
                    else -> emptyList()
                }
                if (subChannels.isNotEmpty()) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .horizontalScroll(rememberScrollState())
                            .padding(horizontal = 14.dp, vertical = 2.dp),
                        horizontalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        subChannels.forEach { (lbl, isAct, act) ->
                            Box(
                                modifier = Modifier
                                    .liquidGlassCapsule(tinted = tinted, active = isAct)
                                    .clickable { act() }
                                    .padding(horizontal = 12.dp, vertical = 5.dp)
                            ) {
                                Text(lbl, color = Color.White, fontSize = 11.5.sp, fontWeight = FontWeight.Bold)
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
            GoonedDockTab.BROWSE -> GoonedBrowseOverlay(
                onClose = { activeTab = GoonedDockTab.HOME },
                onSelectFeed = { src ->
                    when {
                        src.isXFeed -> selectXOrLogin(src)
                        src.isIGFeed -> selectIGOrLogin(src)
                        else -> selectFeed(src)
                    }
                },
                onConnectX = { pendingFeedAfterLogin = FeedSource.XForYou; showXLogin = true },
                onConnectIG = { pendingFeedAfterLogin = FeedSource.IGReels; showIGLogin = true },
                onSetupR34Key = { showR34Key = true }
            )
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

        // Bottom Dock
        if (activeTab != GoonedDockTab.BROWSE && !(activeTab == GoonedDockTab.HOME && userData.settings.controlsCollapsed)) {
            Row(
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .navigationBarsPadding()
                    .padding(bottom = 14.dp)
                    .liquidGlassCapsule(tinted)
                    .padding(horizontal = 10.dp, vertical = 6.dp),
                horizontalArrangement = Arrangement.spacedBy(10.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                DockButton(Icons.Default.Home, activeTab == GoonedDockTab.HOME) { activeTab = GoonedDockTab.HOME }
                DockButton(Icons.Default.Favorite, activeTab == GoonedDockTab.LIKES) { activeTab = GoonedDockTab.LIKES }
                DockButton(Icons.Default.Explore, activeTab == GoonedDockTab.BROWSE) { activeTab = GoonedDockTab.BROWSE }
                DockButton(Icons.Default.Person, activeTab == GoonedDockTab.PROFILE) { activeTab = GoonedDockTab.PROFILE }
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
            fontSize = 15.sp,
            fontWeight = if (active) FontWeight.Bold else FontWeight.Medium
        )
        Spacer(Modifier.height(3.dp))
        Box(
            modifier = Modifier
                .width(if (active) 18.dp else 0.dp)
                .height(2.5.dp)
                .clip(CircleShape)
                .background(if (active) Color.White else Color.Transparent)
        )
    }
}

@Composable
private fun ChannelIconTab(
    active: Boolean,
    showDot: Boolean = false,
    onClick: () -> Unit,
    icon: @Composable () -> Unit
) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier = Modifier
            .clickable { onClick() }
            .padding(horizontal = 2.dp, vertical = 2.dp)
    ) {
        Box {
            Box(modifier = Modifier.alpha(if (active) 1f else 0.72f)) {
                icon()
            }
            if (showDot) {
                Box(
                    modifier = Modifier
                        .size(7.dp)
                        .align(Alignment.TopEnd)
                        .clip(CircleShape)
                        .background(Theme.accentBright)
                )
            }
        }
        Spacer(Modifier.height(3.dp))
        Box(
            modifier = Modifier
                .width(if (active) 14.dp else 0.dp)
                .height(2.5.dp)
                .clip(CircleShape)
                .background(if (active) Color.White else Color.Transparent)
        )
    }
}

@Composable
private fun DockButton(icon: androidx.compose.ui.graphics.vector.ImageVector, active: Boolean, onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .size(44.dp)
            .clip(CircleShape)
            .background(if (active) Color.White.copy(0.22f) else Color.Transparent)
            .clickable { onClick() },
        contentAlignment = Alignment.Center
    ) {
        Icon(icon, contentDescription = null, tint = if (active) Theme.accentBright else Color.White.copy(0.8f))
    }
}
