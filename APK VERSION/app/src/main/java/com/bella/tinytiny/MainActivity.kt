package com.bella.tinytiny

import android.content.Intent
import android.os.Bundle
import android.view.WindowManager
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
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
    X_FOR_YOU, X_FOLLOWING, X_BOOKMARKS,
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

    override fun onStop() {
        super.onStop()
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

    val activeModel = when (activeChannel) {
        HomeChannel.FOLLOWING -> followingModel
        HomeChannel.FOR_YOU -> forYouModel
        HomeChannel.X_FOR_YOU -> xForYouModel
        HomeChannel.X_FOLLOWING -> xFollowingModel
        HomeChannel.X_BOOKMARKS -> xBookmarksModel
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
        FeedView(
            model = activeModel,
            isVisible = activeTab == GoonedDockTab.HOME && !showSettingsModal && !showXLogin && !showIGLogin && !showR34Key && creatorGridSource == null,
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
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .align(Alignment.TopCenter)
                    .statusBarsPadding()
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
                        horizontalArrangement = Arrangement.spacedBy(6.dp)
                    ) {
                        ChannelChip("Following", activeChannel == HomeChannel.FOLLOWING, tinted) { selectFeed(FeedSource.Following) }
                        ChannelChip("For You", activeChannel == HomeChannel.FOR_YOU, tinted) { selectFeed(FeedSource.ForYou) }
                        ChannelChip("𝕏", activeChannel == HomeChannel.X_FOR_YOU, tinted) { selectXOrLogin(FeedSource.XForYou) }
                        ChannelChip("34", activeChannel == HomeChannel.RULE34, tinted) { selectFeed(FeedSource.Rule34("")) }
                        ChannelChip("IG", activeChannel == HomeChannel.IG_REELS, tinted) { selectIGOrLogin(FeedSource.IGReels) }
                        ChannelChip("OF", activeChannel == HomeChannel.OF_FOR_YOU, tinted) { selectFeed(FeedSource.OFForYou) }
                        ChannelChip("Erome", activeChannel == HomeChannel.LONG_EROME, tinted) { selectFeed(FeedSource.LongVideos(LongVideoSite.EROME)) }
                        ChannelChip("Long", activeChannel == HomeChannel.LONG_ALL, tinted) { selectFeed(FeedSource.LongVideos(LongVideoSite.ALL)) }
                    }
                }
                Spacer(Modifier.width(8.dp))
                IconButton(onClick = { showSettingsModal = true }, modifier = Modifier.size(38.dp).liquidGlassCircle(tinted)) {
                    Icon(Icons.Default.Settings, contentDescription = "Settings", tint = Color.White)
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
private fun ChannelChip(label: String, active: Boolean, tinted: Boolean, onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .liquidGlassCapsule(tinted = tinted, active = active)
            .clickable { onClick() }
            .padding(horizontal = 13.dp, vertical = 7.dp)
    ) {
        Text(label, color = Color.White, fontSize = 12.5.sp, fontWeight = FontWeight.Bold)
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
