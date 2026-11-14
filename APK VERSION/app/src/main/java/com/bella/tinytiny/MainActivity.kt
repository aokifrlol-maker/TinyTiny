package com.bella.tinytiny

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Explore
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        LicenseManager.init(this)
        UserStore.init(this)
        SmartTasteEngine.init(this)
        AppState.init(this)

        handleIntent(intent)

        setContent {
            RootView()
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleIntent(intent)
    }

    private fun handleIntent(intent: Intent?) {
        val data = intent?.dataString ?: return
        if (data.startsWith("tinytiny://")) {
            kotlinx.coroutines.MainScope().launch {
                ShareService.handleIncomingShare(data)
            }
        }
    }
}

@Composable
fun RootView() {
    val ageConfirmed by AppState.ageConfirmed.collectAsState()
    val onboardingCompleted by AppState.onboardingCompleted.collectAsState()
    val licenseActivated by AppState.licenseActivated.collectAsState()
    val passcodeDone by AppState.passcodeChoiceCompleted.collectAsState()
    val isLocked by AppState.isLocked.collectAsState()

    LaunchedEffect(licenseActivated) {
        if (licenseActivated) LicenseManager.verifySilently()
    }

    Box(modifier = Modifier.fillMaxSize().background(AppTheme.bg)) {
        val gateKey = when {
            !ageConfirmed -> "age"
            !onboardingCompleted -> "onboard"
            !licenseActivated -> "license"
            !passcodeDone -> "passcode"
            isLocked -> "locked"
            else -> "main"
        }

        AnimatedContent(
            targetState = gateKey,
            transitionSpec = { fadeIn() togetherWith fadeOut() },
            label = "root_gate"
        ) { state ->
            when (state) {
                "age" -> AgeGateScreen { AppState.confirmAge() }
                "onboard" -> WelcomeOnboardingScreen { AppState.completeOnboarding() }
                "license" -> LicenseGateScreen { AppState.setLicenseActivated(true) }
                "passcode" -> PasscodeScreen(isSetup = true) {}
                "locked" -> PasscodeScreen(isSetup = false) {}
                else -> MainShell()
            }
        }
    }
}

private enum class BottomTab { HOME, LIKES, BROWSE, PROFILE }
private enum class TopChannel(val label: String) {
    FOLLOWING("Following"),
    FOR_YOU("For You"),
    X("𝕏"),
    RULE34("34"),
    IG("IG"),
    OF("OF"),
    LONG("▶")
}

@Composable
fun MainShell() {
    var bottomTab by remember { mutableStateOf(BottomTab.HOME) }
    var topChannel by remember { mutableStateOf(TopChannel.FOR_YOU) }
    var activeSubSource by remember { mutableStateOf<FeedSource>(FeedSource.ForYou) }

    val feedModel = remember { FeedModel(FeedSource.ForYou) }
    var showSettings by remember { mutableStateOf(false) }
    var showReceiveDrop by remember { mutableStateOf(false) }
    var shareTarget by remember { mutableStateOf<Gif?>(null) }

    val pendingPost by ShareService.pendingPost.collectAsState()
    val pendingPosts by ShareService.pendingPosts.collectAsState()
    val pendingTitle by ShareService.pendingTitle.collectAsState()

    LaunchedEffect(pendingPost, pendingPosts) {
        if (!pendingPosts.isNullOrEmpty()) {
            feedModel.switchSource(FeedSource.CustomList(pendingTitle ?: "Shared Drop", pendingPosts!!))
            bottomTab = BottomTab.HOME
            ShareService.consumePending()
        } else if (pendingPost != null) {
            feedModel.switchSource(FeedSource.CustomList(pendingTitle ?: "Shared Drop", listOf(pendingPost!!)))
            bottomTab = BottomTab.HOME
            ShareService.consumePending()
        }
    }

    fun selectChannel(ch: TopChannel, src: FeedSource) {
        topChannel = ch
        activeSubSource = src
        feedModel.switchSource(src)
        bottomTab = BottomTab.HOME
    }

    Box(modifier = Modifier.fillMaxSize().background(Color.Black)) {
        when (bottomTab) {
            BottomTab.HOME -> FeedScreen(
                model = feedModel,
                isVisible = !showSettings,
                onSelectShare = { shareTarget = it }
            )
            BottomTab.LIKES -> LikesScreen { title, list ->
                feedModel.switchSource(FeedSource.CustomList(title, list))
                bottomTab = BottomTab.HOME
            }
            BottomTab.BROWSE -> BrowseScreen { src ->
                feedModel.switchSource(src)
                bottomTab = BottomTab.HOME
            }
            BottomTab.PROFILE -> {
                LaunchedEffect(Unit) {
                    showSettings = true
                    bottomTab = BottomTab.HOME
                }
            }
        }

        // Top Bar + Centered Sub-Tab Pill
        if (bottomTab == BottomTab.HOME && !showSettings) {
            Column(
                modifier = Modifier
                    .align(Alignment.TopCenter)
                    .fillMaxWidth()
                    .statusBarsPadding()
                    .padding(top = 6.dp),
                horizontalAlignment = Alignment.CenterHorizontally
            ) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 12.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Box(
                        modifier = Modifier
                            .size(36.dp)
                            .liquidGlassCircle(tinted = true)
                            .clickable { bottomTab = BottomTab.BROWSE },
                        contentAlignment = Alignment.Center
                    ) {
                        Icon(Icons.Default.Search, contentDescription = "Search", tint = Color.White, modifier = Modifier.size(18.dp))
                    }

                    Row(
                        modifier = Modifier
                            .weight(1f)
                            .horizontalScroll(rememberScrollState())
                            .padding(horizontal = 8.dp),
                        horizontalArrangement = Arrangement.spacedBy(10.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        TopChannel.entries.forEach { ch ->
                            val active = topChannel == ch
                            Text(
                                ch.label,
                                color = if (active) Color.White else Color.White.copy(alpha = 0.55f),
                                fontSize = if (active) 14.sp else 12.5.sp,
                                fontWeight = if (active) FontWeight.Bold else FontWeight.Medium,
                                modifier = Modifier
                                    .liquidGlassCapsule(active = active)
                                    .clickable {
                                        val target = when (ch) {
                                            TopChannel.FOLLOWING -> FeedSource.Following
                                            TopChannel.FOR_YOU -> FeedSource.ForYou
                                            TopChannel.X -> FeedSource.XForYou
                                            TopChannel.RULE34 -> FeedSource.Rule34("")
                                            TopChannel.IG -> FeedSource.IGReels
                                            TopChannel.OF -> FeedSource.OFForYou
                                            TopChannel.LONG -> FeedSource.LongVideos(LongVideoSite.ALL)
                                        }
                                        selectChannel(ch, target)
                                    }
                                    .padding(horizontal = 11.dp, vertical = 6.dp)
                            )
                        }
                    }

                    Box(
                        modifier = Modifier
                            .size(36.dp)
                            .liquidGlassCircle(tinted = true)
                            .clickable { showSettings = true },
                        contentAlignment = Alignment.Center
                    ) {
                        Icon(Icons.Default.Settings, contentDescription = "Settings", tint = Color.White, modifier = Modifier.size(18.dp))
                    }
                }

                // Centered Compact Sub-Tab Pill (matches Instagram / OnlyFans centered look)
                val subTabs: List<Pair<String, FeedSource>>? = when (topChannel) {
                    TopChannel.X -> listOf(
                        "For You" to FeedSource.XForYou,
                        "Following" to FeedSource.XFollowing,
                        "Bookmarks" to FeedSource.XBookmarks
                    )
                    TopChannel.IG -> listOf(
                        "Reels" to FeedSource.IGReels,
                        "Following" to FeedSource.IGFollowing,
                        "Saved" to FeedSource.IGSaved
                    )
                    TopChannel.OF -> listOf(
                        "For You" to FeedSource.OFForYou,
                        "Trending" to FeedSource.OFTrending,
                        "Latest" to FeedSource.OFLatest,
                        "DMs" to FeedSource.OFDMs
                    )
                    TopChannel.LONG -> listOf(
                        "All" to FeedSource.LongVideos(LongVideoSite.ALL),
                        "Eporner" to FeedSource.LongVideos(LongVideoSite.EPORNER),
                        "XVideos" to FeedSource.LongVideos(LongVideoSite.XVIDEOS),
                        "Pornhub" to FeedSource.LongVideos(LongVideoSite.PORNHUB)
                    )
                    else -> null
                }

                if (subTabs != null) {
                    Spacer(Modifier.height(6.dp))
                    Row(
                        modifier = Modifier
                            .liquidGlassCapsule(tinted = true)
                            .padding(horizontal = 14.dp, vertical = 6.dp),
                        horizontalArrangement = Arrangement.spacedBy(14.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        subTabs.forEach { (label, src) ->
                            val active = activeSubSource == src
                            Text(
                                label,
                                color = if (active) Color.White else Color.White.copy(alpha = 0.60f),
                                fontSize = 12.sp,
                                fontWeight = if (active) FontWeight.Bold else FontWeight.Medium,
                                modifier = Modifier.clickable { selectChannel(topChannel, src) }
                            )
                        }
                    }
                }
            }
        }

        // Floating Bottom Dock
        if (!showSettings) {
            Row(
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .navigationBarsPadding()
                    .padding(bottom = 14.dp)
                    .liquidGlassCapsule(tinted = true)
                    .padding(horizontal = 10.dp, vertical = 6.dp),
                horizontalArrangement = Arrangement.spacedBy(14.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                DockItem(Icons.Default.Home, bottomTab == BottomTab.HOME) { bottomTab = BottomTab.HOME }
                DockItem(Icons.Default.Favorite, bottomTab == BottomTab.LIKES) { bottomTab = BottomTab.LIKES }
                DockItem(Icons.Default.Explore, bottomTab == BottomTab.BROWSE) { bottomTab = BottomTab.BROWSE }
                DockItem(Icons.Default.Person, showSettings) { showSettings = true }
            }
        }

        if (showSettings) {
            SettingsModal(
                onDismiss = { showSettings = false },
                onOpenReceiveDrop = { showReceiveDrop = true }
            )
        }
    }

    if (shareTarget != null) {
        ShareDropDialog(posts = listOf(shareTarget!!), onDismiss = { shareTarget = null })
    }
    if (showReceiveDrop) {
        ReceiveDropDialog { showReceiveDrop = false }
    }
}

@Composable
private fun DockItem(icon: androidx.compose.ui.graphics.vector.ImageVector, active: Boolean, onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .size(44.dp)
            .liquidGlassCircle(active = active)
            .clickable { onClick() },
        contentAlignment = Alignment.Center
    ) {
        Icon(icon, contentDescription = null, tint = if (active) Color.White else Color.White.copy(alpha = 0.65f), modifier = Modifier.size(21.dp))
    }
}
