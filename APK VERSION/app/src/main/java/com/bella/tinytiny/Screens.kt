package com.bella.tinytiny

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowLeft
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil.compose.AsyncImage
import coil.request.ImageRequest
import kotlinx.coroutines.launch

enum class BrowseScope(val label: String) {
    ALL("All"), REDDIT("Reddit"), X("𝕏"), IG("IG"), RULE34("Rule34"), OF("OnlyFans"), EROME("Erome"), LONG("Long")
}

@Composable
fun GoonedBrowseOverlay(
    initialScope: BrowseScope = BrowseScope.ALL,
    onClose: () -> Unit,
    onSelectFeed: (FeedSource) -> Unit,
    onConnectX: () -> Unit,
    onConnectIG: () -> Unit,
    onSetupR34Key: () -> Unit
) {
    val store = UserStore.shared
    val userData by store.data.collectAsState()
    val categories by store.categories.collectAsState()
    val tinted = userData.settings.tintedGlass
    val scope = rememberCoroutineScope()

    var query by remember { mutableStateOf("") }
    var searchScope by remember { mutableStateOf(initialScope) }
    var r34Suggestions by remember { mutableStateOf<List<Rule34TagSuggestion>>(emptyList()) }
    var searchResults by remember { mutableStateOf(GoonedSearchResponse()) }
    var ofCreators by remember { mutableStateOf<List<OFCreator>>(emptyList()) }
    var showReceiveDrop by remember { mutableStateOf(false) }

    LaunchedEffect(query, searchScope) {
        val q = query.trim()
        if (q.length < 2) {
            r34Suggestions = emptyList()
            searchResults = GoonedSearchResponse()
            ofCreators = emptyList()
            return@LaunchedEffect
        }
        if (searchScope == BrowseScope.RULE34 || searchScope == BrowseScope.ALL) {
            r34Suggestions = Rule34API.autocomplete(q)
        }
        if (searchScope == BrowseScope.REDDIT || searchScope == BrowseScope.ALL) {
            searchResults = try { GoonedAPI.search(q) } catch (_: Throwable) { GoonedSearchResponse() }
        }
        if (searchScope == BrowseScope.OF || searchScope == BrowseScope.ALL) {
            ofCreators = OnlyFansAPI.searchCreators(q)
        }
    }

    Box(modifier = Modifier.fillMaxSize().liquidGlassBackground(tinted)) {
        Column(modifier = Modifier.fillMaxSize().statusBarsPadding().padding(horizontal = 16.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(top = 10.dp, bottom = 10.dp)) {
                Text("Explore", color = Color.White, fontSize = 24.sp, fontWeight = FontWeight.Bold)
                Spacer(Modifier.weight(1f))
                TextButton(onClick = { showReceiveDrop = true }) {
                    Text("Open Drop", color = Theme.accentBright, fontWeight = FontWeight.Bold)
                }
                IconButton(onClick = onClose, modifier = Modifier.size(36.dp).liquidGlassCircle(tinted)) {
                    Icon(Icons.Default.Close, contentDescription = "Close", tint = Color.White)
                }
            }

            OutlinedTextField(
                value = query,
                onValueChange = { query = it },
                placeholder = { Text("Search OF, Reddit, 𝕏, IG, R34, Erome...", fontSize = 14.sp) },
                leadingIcon = { Icon(Icons.Default.Search, contentDescription = null) },
                trailingIcon = {
                    if (query.isNotEmpty()) {
                        IconButton(onClick = { query = "" }) { Icon(Icons.Default.Clear, contentDescription = "Clear") }
                    }
                },
                singleLine = true,
                shape = RoundedCornerShape(16.dp),
                modifier = Modifier.fillMaxWidth()
            )

            Spacer(Modifier.height(10.dp))
            Row(modifier = Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                for (sc in BrowseScope.entries) {
                    val active = searchScope == sc
                    Box(
                        modifier = Modifier
                            .liquidGlassCapsule(tinted = tinted, active = active)
                            .clickable { searchScope = sc }
                            .padding(horizontal = 14.dp, vertical = 7.dp)
                    ) {
                        Text(sc.label, color = Color.White, fontSize = 12.5.sp, fontWeight = FontWeight.Bold)
                    }
                }
            }

            Spacer(Modifier.height(12.dp))
            LazyColumn(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(10.dp),
                contentPadding = PaddingValues(bottom = 40.dp)
            ) {
                val q = query.trim()
                if (q.isNotEmpty()) {
                    item {
                        Column(modifier = Modifier.fillMaxWidth().liquidGlassCard(18.dp, tinted).padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            Text("QUICK SEARCH \"$q\"", color = Theme.textSecondary, fontSize = 11.sp, fontWeight = FontWeight.Bold)
                            Row(modifier = Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                BrowsePill("𝕏 Search") { onSelectFeed(FeedSource.XSearch(q)) }
                                BrowsePill("𝕏 @${q.removePrefix("@")}") { onSelectFeed(FeedSource.XUser(q.removePrefix("@"))) }
                                BrowsePill("IG @${q.removePrefix("@")}") { onSelectFeed(FeedSource.IGUser(q.removePrefix("@"))) }
                                BrowsePill("Erome") { onSelectFeed(FeedSource.LongSearch(LongVideoSite.EROME, q)) }
                                BrowsePill("Rule34") { onSelectFeed(FeedSource.Rule34(Rule34API.parseTags(q).joinToString(" "))) }
                                BrowsePill("OF Posts") { onSelectFeed(FeedSource.OFSearch(q)) }
                                BrowsePill("Long Videos") { onSelectFeed(FeedSource.LongSearch(LongVideoSite.ALL, q)) }
                            }
                        }
                    }

                    if (r34Suggestions.isNotEmpty()) {
                        item { Text("RULE34 TAG SUGGESTIONS", color = Theme.textSecondary, fontSize = 11.sp, fontWeight = FontWeight.Bold) }
                        items(r34Suggestions.take(7)) { s ->
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .liquidGlassCard(14.dp, tinted)
                                    .clickable { onSelectFeed(FeedSource.Rule34(s.value)) }
                                    .padding(14.dp),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                BrandLogoRule34(22.dp)
                                Spacer(Modifier.width(10.dp))
                                Text(s.label.ifEmpty { s.value }, color = Color.White, fontWeight = FontWeight.SemiBold)
                            }
                        }
                    }

                    if (ofCreators.isNotEmpty()) {
                        item { Text("ONLYFANS CREATORS", color = Theme.textSecondary, fontSize = 11.sp, fontWeight = FontWeight.Bold) }
                        items(ofCreators.take(6)) { c ->
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .liquidGlassCard(14.dp, tinted)
                                    .clickable { onSelectFeed(FeedSource.OFCreator(c.id, c.cleanHandle, c.displayName)) }
                                    .padding(14.dp),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                BrandLogoOnlyFans(22.dp)
                                Spacer(Modifier.width(10.dp))
                                Text(c.label, color = Color.White, fontWeight = FontWeight.SemiBold)
                            }
                        }
                    }

                    if (searchResults.subreddits.isNotEmpty()) {
                        item { Text("SUBREDDITS", color = Theme.textSecondary, fontSize = 11.sp, fontWeight = FontWeight.Bold) }
                        items(searchResults.subreddits.take(6)) { sub ->
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .liquidGlassCard(14.dp, tinted)
                                    .clickable { onSelectFeed(FeedSource.Subreddit(sub.name)) }
                                    .padding(14.dp)
                            ) {
                                Text("r/${sub.name}", color = Color.White, fontWeight = FontWeight.SemiBold)
                            }
                        }
                    }
                } else {
                    item {
                        Row(modifier = Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            BrowsePill("For You") { onSelectFeed(FeedSource.ForYou) }
                            BrowsePill("Following") { onSelectFeed(FeedSource.Following) }
                            BrowsePill("𝕏 Feed") { onSelectFeed(FeedSource.XForYou) }
                            BrowsePill("IG Reels") { onSelectFeed(FeedSource.IGReels) }
                            BrowsePill("OnlyFans") { onSelectFeed(FeedSource.OFForYou) }
                            BrowsePill("Rule34") { onSelectFeed(FeedSource.Rule34("")) }
                            BrowsePill("Erome") { onSelectFeed(FeedSource.LongVideos(LongVideoSite.EROME)) }
                            BrowsePill("Long Videos") { onSelectFeed(FeedSource.LongVideos(LongVideoSite.ALL)) }
                        }
                    }

                    if (userData.recentFeeds.isNotEmpty()) {
                        item { Text("RECENT", color = Theme.textSecondary, fontSize = 11.sp, fontWeight = FontWeight.Bold) }
                        items(userData.recentFeeds.take(6)) { r ->
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .liquidGlassCard(14.dp, tinted)
                                    .clickable {
                                        val target = when (r.kind) {
                                            "category" -> FeedSource.Category(r.name)
                                            "subreddit" -> FeedSource.Subreddit(r.name)
                                            "user" -> FeedSource.User(r.name)
                                            "xsearch" -> FeedSource.XSearch(r.name)
                                            "xuser" -> FeedSource.XUser(r.name)
                                            "iguser" -> FeedSource.IGUser(r.name)
                                            "rule34" -> FeedSource.Rule34(if (r.name == "all") "" else r.name)
                                            else -> FeedSource.ForYou
                                        }
                                        onSelectFeed(target)
                                    }
                                    .padding(14.dp),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Column(Modifier.weight(1f)) {
                                    Text(r.displayTitle, color = Color.White, fontWeight = FontWeight.Bold)
                                    Text("${r.swipedCount} swiped", color = Theme.textSecondary, fontSize = 12.sp)
                                }
                                Icon(Icons.Default.ChevronRight, contentDescription = null, tint = Theme.textSecondary)
                            }
                        }
                    }

                    item { Text("CATEGORIES", color = Theme.textSecondary, fontSize = 11.sp, fontWeight = FontWeight.Bold) }
                    items(categories) { cat ->
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .liquidGlassCard(16.dp, tinted)
                                .clickable { onSelectFeed(FeedSource.Category(cat.name)) }
                                .padding(14.dp),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Column(Modifier.weight(1f)) {
                                Text(cat.displayName, color = Color.White, fontSize = 16.sp, fontWeight = FontWeight.Bold)
                                Text(cat.subreddits.take(3).joinToString(" · ") { "r/$it" }, color = Theme.textSecondary, fontSize = 12.sp, maxLines = 1)
                            }
                            Icon(Icons.Default.ChevronRight, contentDescription = null, tint = Theme.textSecondary)
                        }
                    }
                }
            }
        }
    }

    if (showReceiveDrop) {
        ReceiveDropSheet(onDismiss = { showReceiveDrop = false })
    }
}

@Composable
private fun BrowsePill(label: String, onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .liquidGlassCapsule()
            .clickable { onClick() }
            .padding(horizontal = 14.dp, vertical = 8.dp)
    ) {
        Text(label, color = Color.White, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
    }
}

@Composable
fun GoonedLikesView(
    onOpenSettings: () -> Unit,
    onStartStash: () -> Unit,
    onPlayLikedPost: (Gif) -> Unit,
    onPlayOfflinePost: (Gif) -> Unit
) {
    val userData by UserStore.shared.data.collectAsState()
    val tinted = userData.settings.tintedGlass
    var section by remember { mutableIntStateOf(0) } // 0 = Likes, 1 = Offline Vault
    var filter by remember { mutableIntStateOf(0) } // 0 = All, 1 = Videos, 2 = Images

    val rawItems = if (section == 0) userData.liked else userData.downloaded
    val filtered = remember(rawItems, filter) {
        when (filter) {
            1 -> rawItems.filter { !it.isImage }
            2 -> rawItems.filter { it.isImage }
            else -> rawItems
        }
    }

    Box(modifier = Modifier.fillMaxSize().liquidGlassBackground(tinted)) {
        Column(modifier = Modifier.fillMaxSize().statusBarsPadding().padding(horizontal = 14.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(top = 10.dp, bottom = 10.dp)) {
                Text(if (section == 0) "Likes" else "Offline Vault", color = Color.White, fontSize = 24.sp, fontWeight = FontWeight.Bold)
                Spacer(Modifier.weight(1f))
                IconButton(onClick = onOpenSettings, modifier = Modifier.size(36.dp).liquidGlassCircle(tinted)) {
                    Icon(Icons.Default.Settings, contentDescription = "Settings", tint = Color.White)
                }
            }

            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Box(
                    modifier = Modifier.liquidGlassCapsule(tinted, active = section == 0).clickable { section = 0 }.padding(horizontal = 16.dp, vertical = 8.dp)
                ) { Text("Likes (${userData.liked.size})", color = Color.White, fontWeight = FontWeight.Bold, fontSize = 13.sp) }
                Box(
                    modifier = Modifier.liquidGlassCapsule(tinted, active = section == 1).clickable { section = 1 }.padding(horizontal = 16.dp, vertical = 8.dp)
                ) { Text("Offline (${userData.downloaded.size})", color = Color.White, fontWeight = FontWeight.Bold, fontSize = 13.sp) }
            }

            Spacer(Modifier.height(10.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                listOf("All", "Videos", "Images").forEachIndexed { idx, label ->
                    Box(
                        modifier = Modifier.liquidGlassCapsule(tinted, active = filter == idx).clickable { filter = idx }.padding(horizontal = 12.dp, vertical = 6.dp)
                    ) { Text(label, color = Color.White, fontSize = 12.sp, fontWeight = FontWeight.SemiBold) }
                }
            }

            Spacer(Modifier.height(12.dp))
            if (filtered.isEmpty()) {
                Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        Icon(if (section == 0) Icons.Default.FavoriteBorder else Icons.Default.DownloadDone, contentDescription = null, tint = Theme.textSecondary, modifier = Modifier.size(48.dp))
                        Text(if (section == 0) "No liked posts yet" else "No offline downloads yet", color = Color.White, fontWeight = FontWeight.Bold)
                        Button(onClick = onStartStash, colors = ButtonDefaults.buttonColors(containerColor = Theme.accent)) {
                            Text("Explore Feed", fontWeight = FontWeight.Bold)
                        }
                    }
                }
            } else {
                LazyVerticalGrid(
                    columns = GridCells.Fixed(3),
                    horizontalArrangement = Arrangement.spacedBy(2.dp),
                    verticalArrangement = Arrangement.spacedBy(2.dp),
                    contentPadding = PaddingValues(bottom = 110.dp),
                    modifier = Modifier.fillMaxSize()
                ) {
                    items(filtered, key = { it.id }) { gif ->
                        GridThumb(gif = gif, isOffline = OfflineManager.isDownloaded(gif)) {
                            if (section == 0) onPlayLikedPost(gif) else onPlayOfflinePost(gif)
                        }
                    }
                }
            }
        }
    }
}

@Composable
fun GridThumb(gif: Gif, isOffline: Boolean, onClick: () -> Unit) {
    val ctx = LocalContext.current
    Box(
        modifier = Modifier
            .aspectRatio(9f / 16f)
            .background(Color.White.copy(0.06f))
            .clickable { onClick() }
    ) {
        AsyncImage(
            model = ImageRequest.Builder(ctx)
                .data(gif.thumbURL ?: gif.posterURL)
                .size(420)
                .crossfade(true)
                .build(),
            contentDescription = null,
            contentScale = ContentScale.Crop,
            modifier = Modifier.fillMaxSize()
        )
        if (isOffline) {
            Icon(
                Icons.Default.CheckCircle,
                contentDescription = null,
                tint = Theme.accentBright,
                modifier = Modifier.align(Alignment.TopEnd).padding(6.dp).size(15.dp)
            )
        }
        Box(
            modifier = Modifier
                .align(Alignment.BottomStart)
                .padding(6.dp)
                .background(Color.Black.copy(0.55f), CircleShape)
                .padding(horizontal = 6.dp, vertical = 2.dp)
        ) {
            Text(
                text = when {
                    gif.isOnlyFansPost -> "OF"
                    gif.isXPost -> "𝕏"
                    gif.isIGPost -> "IG"
                    gif.isRule34Post -> "34"
                    else -> gif.longVideoSiteLabel ?: "r/"
                },
                color = Color.White,
                fontSize = 10.sp,
                fontWeight = FontWeight.Black
            )
        }
    }
}

@Composable
fun GoonedFollowsView(
    onOpenSettings: () -> Unit,
    onSelectFeed: (FeedSource) -> Unit,
    onConnectX: () -> Unit,
    onConnectIG: () -> Unit
) {
    val userData by UserStore.shared.data.collectAsState()
    val tinted = userData.settings.tintedGlass
    var expanded by remember { mutableStateOf("accounts") }

    Box(modifier = Modifier.fillMaxSize().liquidGlassBackground(tinted)) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .statusBarsPadding()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp)
                .padding(bottom = 110.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(top = 10.dp)) {
                Text("Profile", color = Color.White, fontSize = 24.sp, fontWeight = FontWeight.Bold)
                Spacer(Modifier.weight(1f))
                IconButton(onClick = onOpenSettings, modifier = Modifier.size(36.dp).liquidGlassCircle(tinted)) {
                    Icon(Icons.Default.Settings, contentDescription = "Settings", tint = Color.White)
                }
            }

            FollowsDropdown("accounts", expanded == "accounts", "Connected Accounts",
                "${if (userData.xSession.isConnected) "𝕏 On" else "𝕏 Off"} · ${if (userData.igSession.isConnected) "IG On" else "IG Off"}",
                tinted, { expanded = if (expanded == "accounts") "" else "accounts" }
            ) {
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    Button(onClick = onConnectX, colors = ButtonDefaults.buttonColors(containerColor = if (userData.xSession.isConnected) Theme.accent else Theme.surfaceElevated), modifier = Modifier.weight(1f)) {
                        Text(if (userData.xSession.isConnected) "𝕏 Connected" else "Connect 𝕏")
                    }
                    Button(onClick = onConnectIG, colors = ButtonDefaults.buttonColors(containerColor = if (userData.igSession.isConnected) Theme.accent else Theme.surfaceElevated), modifier = Modifier.weight(1f)) {
                        Text(if (userData.igSession.isConnected) "IG Connected" else "Connect IG")
                    }
                }
            }

            FollowsDropdown("x", expanded == "x", "𝕏 Creators", "${userData.followedXUsers.size} followed", tinted, { expanded = if (expanded == "x") "" else "x" }) {
                if (userData.followedXUsers.isEmpty()) Text("No 𝕏 creators followed yet.", color = Theme.textSecondary, fontSize = 13.sp)
                userData.followedXUsers.forEach { h ->
                    Text("@$h", color = Color.White, modifier = Modifier.fillMaxWidth().clickable { onSelectFeed(FeedSource.XUser(h)) }.padding(vertical = 6.dp))
                }
            }

            FollowsDropdown("of", expanded == "of", "OnlyFans Creators", "${userData.followedOFCreators.size} followed", tinted, { expanded = if (expanded == "of") "" else "of" }) {
                if (userData.followedOFCreators.isEmpty()) Text("No OnlyFans creators followed yet.", color = Theme.textSecondary, fontSize = 13.sp)
                userData.followedOFCreators.forEach { c ->
                    Text(c.label, color = Color.White, modifier = Modifier.fillMaxWidth().clickable { onSelectFeed(FeedSource.OFCreator(c.id, c.name, c.displayName)) }.padding(vertical = 6.dp))
                }
            }

            FollowsDropdown("ig", expanded == "ig", "Instagram Creators", "${userData.followedIGUsers.size} followed", tinted, { expanded = if (expanded == "ig") "" else "ig" }) {
                if (userData.followedIGUsers.isEmpty()) Text("No Instagram creators followed yet.", color = Theme.textSecondary, fontSize = 13.sp)
                userData.followedIGUsers.forEach { h ->
                    Text("@$h", color = Color.White, modifier = Modifier.fillMaxWidth().clickable { onSelectFeed(FeedSource.IGUser(h)) }.padding(vertical = 6.dp))
                }
            }

            FollowsDropdown("sub", expanded == "sub", "Subreddits", "${userData.followedSubreddits.size} followed", tinted, { expanded = if (expanded == "sub") "" else "sub" }) {
                if (userData.followedSubreddits.isEmpty()) Text("No subreddits followed yet.", color = Theme.textSecondary, fontSize = 13.sp)
                userData.followedSubreddits.forEach { s ->
                    Text("r/$s", color = Color.White, modifier = Modifier.fillMaxWidth().clickable { onSelectFeed(FeedSource.Subreddit(s)) }.padding(vertical = 6.dp))
                }
            }
        }
    }
}

@Composable
private fun FollowsDropdown(
    id: String,
    isOpen: Boolean,
    title: String,
    summary: String,
    tinted: Boolean,
    onToggle: () -> Unit,
    content: @Composable ColumnScope.() -> Unit
) {
    Column(modifier = Modifier.fillMaxWidth().liquidGlassCard(20.dp, tinted)) {
        Row(
            modifier = Modifier.fillMaxWidth().clickable { onToggle() }.padding(14.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Column(Modifier.weight(1f)) {
                Text(title, color = Color.White, fontSize = 16.sp, fontWeight = FontWeight.Bold)
                Text(summary, color = Theme.textSecondary, fontSize = 12.sp)
            }
            Icon(if (isOpen) Icons.Default.ExpandLess else Icons.Default.ExpandMore, contentDescription = null, tint = Color.White)
        }
        AnimatedVisibility(visible = isOpen) {
            Column(modifier = Modifier.padding(start = 14.dp, end = 14.dp, bottom = 14.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                HorizontalDivider(color = Color.White.copy(0.14f))
                content()
            }
        }
    }
}

@Composable
fun CreatorProfileGridView(
    source: FeedSource,
    onClose: () -> Unit,
    onSelectPost: (post: Gif, loadedItems: List<Gif>, cursor: String?, canLoadMore: Boolean) -> Unit
) {
    val store = UserStore.shared
    val userData by store.data.collectAsState()
    val tinted = userData.settings.tintedGlass
    val model = remember(source.displayTitle) { FeedModel(source) }
    val items by model.items.collectAsState()
    val isLoading by model.isLoading.collectAsState()
    val errorText by model.errorText.collectAsState()
    val scope = rememberCoroutineScope()

    var tagFilterText by remember { mutableStateOf("") }
    var activeRemoteFilter by remember { mutableStateOf("") }
    val isRule34 = source is FeedSource.Rule34

    val displayedItems = remember(items, tagFilterText) {
        val q = tagFilterText.trim().lowercase()
        if (q.isEmpty()) items
        else {
            val terms = q.split(Regex("\\s+"))
            items.filter { g ->
                val hay = ((g.title ?: "") + " " + (g.author ?: "")).lowercase()
                terms.all { hay.contains(it) }
            }
        }
    }

    LaunchedEffect(source) {
        if (items.isEmpty()) model.loadMore()
    }

    Box(modifier = Modifier.fillMaxSize().liquidGlassBackground(tinted)) {
        Column(modifier = Modifier.fillMaxSize().statusBarsPadding()) {
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp)) {
                IconButton(onClick = onClose, modifier = Modifier.size(38.dp).liquidGlassCircle(tinted)) {
                    Icon(Icons.AutoMirrored.Filled.KeyboardArrowLeft, contentDescription = "Back", tint = Color.White)
                }
                Spacer(Modifier.width(10.dp))
                Column(Modifier.weight(1f)) {
                    Text(source.displayTitle, color = Color.White, fontSize = 18.sp, fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text("${displayedItems.size} posts", color = Theme.textSecondary, fontSize = 12.sp)
                }
                when (source) {
                    is FeedSource.XUser -> FollowButton(store.isFollowingXUser(source.handle), tinted) { store.toggleFollowXUser(source.handle) }
                    is FeedSource.IGUser -> FollowButton(store.isFollowingIGUser(source.handle), tinted) { store.toggleFollowIGUser(source.handle) }
                    is FeedSource.OFCreator -> FollowButton(store.isFollowingOFCreator(source.id, source.handle), tinted) { store.toggleFollowOFCreator(source.id, source.handle, source.displayName) }
                    is FeedSource.User -> FollowButton(store.isFollowingUser(source.name), tinted) { store.toggleFollowUser(source.name) }
                    is FeedSource.Subreddit -> FollowButton(store.isFollowingSubreddit(source.name), tinted) { store.toggleFollowSubreddit(source.name) }
                    else -> {}
                }
            }

            if (isRule34) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .padding(horizontal = 16.dp)
                        .padding(bottom = 10.dp)
                        .fillMaxWidth()
                        .liquidGlassCard(14.dp, tinted)
                        .padding(horizontal = 12.dp, vertical = 4.dp)
                ) {
                    Icon(Icons.Default.Search, contentDescription = null, tint = Theme.textSecondary, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(8.dp))
                    OutlinedTextField(
                        value = tagFilterText,
                        onValueChange = { tagFilterText = it },
                        placeholder = { Text("Filter tags (e.g. solo, animated)...", fontSize = 13.sp) },
                        singleLine = true,
                        modifier = Modifier.weight(1f)
                    )
                    if (tagFilterText.isNotEmpty() || activeRemoteFilter.isNotEmpty()) {
                        IconButton(onClick = {
                            tagFilterText = ""
                            if (activeRemoteFilter.isNotEmpty()) {
                                activeRemoteFilter = ""
                                model.switchSource(source)
                            }
                        }) {
                            Icon(Icons.Default.Clear, contentDescription = "Clear", tint = Color.White)
                        }
                    }
                    if (tagFilterText.trim().isNotEmpty()) {
                        TextButton(onClick = {
                            val base = (source as FeedSource.Rule34).tag
                            val clean = tagFilterText.trim()
                            activeRemoteFilter = clean
                            val combined = if (base.isEmpty()) clean else "$base $clean"
                            model.switchSource(FeedSource.Rule34(combined))
                        }) {
                            Text("Search", color = Theme.accentBright, fontWeight = FontWeight.Bold)
                        }
                    }
                }
            }

            if (displayedItems.isEmpty() && isLoading) {
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator(color = Theme.accentBright)
                }
            } else if (displayedItems.isEmpty()) {
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        Text(errorText ?: "No posts found.", color = Theme.textSecondary)
                        Button(onClick = { scope.launch { model.refresh(false) } }, colors = ButtonDefaults.buttonColors(containerColor = Theme.accent)) {
                            Text("Retry")
                        }
                    }
                }
            } else {
                LazyVerticalGrid(
                    columns = GridCells.Fixed(3),
                    horizontalArrangement = Arrangement.spacedBy(2.dp),
                    verticalArrangement = Arrangement.spacedBy(2.dp),
                    contentPadding = PaddingValues(bottom = 110.dp),
                    modifier = Modifier.fillMaxSize()
                ) {
                    items(displayedItems, key = { it.id }) { gif ->
                        GridThumb(gif = gif, isOffline = OfflineManager.isDownloaded(gif)) {
                            onSelectPost(gif, displayedItems, model.currentCursor, model.canLoadMore)
                        }
                        LaunchedEffect(gif.id) { model.onItemAppear(gif) }
                    }
                }
            }
        }
    }
}

@Composable
private fun FollowButton(isFollowed: Boolean, tinted: Boolean, onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .liquidGlassCapsule(tinted = tinted, active = isFollowed)
            .clickable { onClick() }
            .padding(horizontal = 14.dp, vertical = 8.dp)
    ) {
        Text(if (isFollowed) "Following" else "Follow", color = Color.White, fontSize = 13.sp, fontWeight = FontWeight.Bold)
    }
}

@Composable
fun GoonedSettingsModal(
    onDismiss: () -> Unit,
    onConnectX: () -> Unit,
    onConnectIG: () -> Unit,
    onSetupR34Key: () -> Unit
) {
    val store = UserStore.shared
    val userData by store.data.collectAsState()
    val licStatus by LicenseManager.status.collectAsState()
    val diskUsage by OfflineManager.diskUsageText.collectAsState()
    val tinted = userData.settings.tintedGlass
    val scope = rememberCoroutineScope()

    var expanded by remember { mutableStateOf("accounts") }
    var syncStatus by remember { mutableStateOf<String?>(null) }
    var showAlgoEditor by remember { mutableStateOf(false) }
    var showWipeSheet by remember { mutableStateOf(false) }
    var showPasscodeSetup by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) { OfflineManager.refreshDiskUsage() }

    Box(modifier = Modifier.fillMaxSize().liquidGlassBackground(tinted)) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .statusBarsPadding()
                .verticalScroll(rememberScrollState())
                .padding(18.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Settings", color = Color.White, fontSize = 24.sp, fontWeight = FontWeight.Bold)
                Spacer(Modifier.weight(1f))
                IconButton(onClick = onDismiss, modifier = Modifier.size(36.dp).liquidGlassCircle(tinted)) {
                    Icon(Icons.Default.Close, contentDescription = "Close", tint = Color.White)
                }
            }

            FollowsDropdown("accounts", expanded == "accounts", "Accounts & Cloud Sync", LicenseManager.expirySummary, tinted, { expanded = if (expanded == "accounts") "" else "accounts" }) {
                Text("License: ${licStatus.licenseKey.ifEmpty { "None" }} (${LicenseManager.expirySummary})", color = Theme.textSecondary, fontSize = 12.sp)
                Button(onClick = { scope.launch { syncStatus = LicenseManager.syncBidirectionalBackup() } }, colors = ButtonDefaults.buttonColors(containerColor = Theme.accent), modifier = Modifier.fillMaxWidth()) {
                    Text("Sync Encrypted Cloud Backup", fontWeight = FontWeight.Bold)
                }
                syncStatus?.let { Text(it, color = Color(0xFF4ADE80), fontSize = 12.sp) }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedButton(onClick = onConnectX, modifier = Modifier.weight(1f)) { Text(if (userData.xSession.isConnected) "𝕏 Connected" else "Connect 𝕏", color = Color.White, fontSize = 12.sp) }
                    OutlinedButton(onClick = onConnectIG, modifier = Modifier.weight(1f)) { Text(if (userData.igSession.isConnected) "IG Connected" else "Connect IG", color = Color.White, fontSize = 12.sp) }
                }
                OutlinedButton(onClick = onSetupR34Key, modifier = Modifier.fillMaxWidth()) {
                    Text(if (userData.r34Credentials.isConnected) "Rule34 API Key: Custom" else "Set Rule34 DAPI Key", color = Color.White)
                }
            }

            FollowsDropdown("algo", expanded == "algo", "Smart Algorithm & Taste", "${userData.algorithm.boostedTags.size} boosted · ${userData.algorithm.blockedTags.size} blocked", tinted, { expanded = if (expanded == "algo") "" else "algo" }) {
                Button(onClick = { showAlgoEditor = true }, colors = ButtonDefaults.buttonColors(containerColor = Theme.accent), modifier = Modifier.fillMaxWidth()) {
                    Text("Edit #Tags & Taste", fontWeight = FontWeight.Bold)
                }
            }

            FollowsDropdown("playback", expanded == "playback", "Playback & Auto-Scroll", "${if (userData.settings.hd) "HD" else "SD"} · ${if (userData.settings.fillScreen) "Fill" else "Fit"}", tinted, { expanded = if (expanded == "playback") "" else "playback" }) {
                SettingSwitch("HD Video Quality", userData.settings.hd) { v -> store.updateSettings { it.copy(hd = v) } }
                SettingSwitch("Fill Screen", userData.settings.fillScreen) { v -> store.updateSettings { it.copy(fillScreen = v) } }
                SettingSwitch("Auto-Scroll Videos", userData.settings.autoScroll) { v -> store.updateSettings { it.copy(autoScroll = v) } }
                SettingSwitch("Tinted Liquid Glass", userData.settings.tintedGlass) { v -> store.updateSettings { it.copy(tintedGlass = v) } }
            }

            FollowsDropdown("vault", expanded == "vault", "Vault & Security", "Offline: $diskUsage", tinted, { expanded = if (expanded == "vault") "" else "vault" }) {
                val hasPin by AppState.hasPasscode.collectAsState()
                val reqPin by AppState.requirePasscodeOnOpen.collectAsState()
                if (hasPin) {
                    SettingSwitch("Lock on Open", reqPin) { v -> AppState.setRequirePasscodeOnOpen(v) }
                    SettingSwitch("Biometric Unlock", userData.settings.faceID) { v -> store.updateSettings { it.copy(faceID = v) } }
                }
                OutlinedButton(onClick = { showPasscodeSetup = true }, modifier = Modifier.fillMaxWidth()) {
                    Text(if (hasPin) "Change Passcode" else "Set 4-Digit Passcode", color = Color.White)
                }
                Button(onClick = { showWipeSheet = true }, colors = ButtonDefaults.buttonColors(containerColor = Color(0xFFB91C1C)), modifier = Modifier.fillMaxWidth()) {
                    Text("Wipe Data...", fontWeight = FontWeight.Bold)
                }
            }
        }
    }

    if (showAlgoEditor) {
        AlgorithmEditorSheet(onDismiss = { showAlgoEditor = false })
    }
    if (showWipeSheet) {
        WipeDataSheet(onComplete = { showWipeSheet = false; onDismiss() }, onDismiss = { showWipeSheet = false })
    }
    if (showPasscodeSetup) {
        PasscodeSetupView(isOnboarding = false, onDone = { showPasscodeSetup = false })
    }
}

@Composable
private fun SettingSwitch(label: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
        Text(label, color = Color.White, modifier = Modifier.weight(1f), fontSize = 14.sp)
        Switch(checked = checked, onCheckedChange = onChange)
    }
}

@Composable
fun AlgorithmEditorSheet(onDismiss: () -> Unit) {
    val store = UserStore.shared
    val userData by store.data.collectAsState()
    val tinted = userData.settings.tintedGlass
    var boostInput by remember { mutableStateOf("") }
    var blockInput by remember { mutableStateOf("") }

    Box(modifier = Modifier.fillMaxSize().liquidGlassBackground(tinted).padding(20.dp)) {
        Column(modifier = Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Edit #Tags & Taste", color = Color.White, fontSize = 20.sp, fontWeight = FontWeight.Bold)
                Spacer(Modifier.weight(1f))
                IconButton(onClick = onDismiss) { Icon(Icons.Default.Close, contentDescription = "Close", tint = Color.White) }
            }

            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(value = boostInput, onValueChange = { boostInput = it }, placeholder = { Text("Boost #tag...") }, modifier = Modifier.weight(1f), singleLine = true)
                Button(onClick = {
                    val tags = Rule34API.parseTags(boostInput)
                    if (tags.isNotEmpty()) {
                        store.updateAlgorithm { it.copy(boostedTags = (it.boostedTags + tags).distinct()) }
                        boostInput = ""
                    }
                }, colors = ButtonDefaults.buttonColors(containerColor = Theme.accent)) { Text("Boost") }
            }

            @OptIn(ExperimentalLayoutApi::class)
            FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                userData.algorithm.boostedTags.forEach { t ->
                    Box(modifier = Modifier.liquidGlassCapsule(tinted, active = true).clickable {
                        store.updateAlgorithm { it.copy(boostedTags = it.boostedTags.filterNot { x -> x == t }) }
                    }.padding(horizontal = 10.dp, vertical = 5.dp)) {
                        Text("#$t ✕", color = Color.White, fontSize = 12.sp)
                    }
                }
            }

            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(value = blockInput, onValueChange = { blockInput = it }, placeholder = { Text("Block #tag...") }, modifier = Modifier.weight(1f), singleLine = true)
                Button(onClick = {
                    val tags = Rule34API.parseTags(blockInput)
                    if (tags.isNotEmpty()) {
                        store.updateAlgorithm { it.copy(blockedTags = (it.blockedTags + tags).distinct()) }
                        blockInput = ""
                    }
                }) { Text("Block") }
            }

            @OptIn(ExperimentalLayoutApi::class)
            FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                userData.algorithm.blockedTags.forEach { t ->
                    Box(modifier = Modifier.liquidGlassCapsule(tinted).clickable {
                        store.updateAlgorithm { it.copy(blockedTags = it.blockedTags.filterNot { x -> x == t }) }
                    }.padding(horizontal = 10.dp, vertical = 5.dp)) {
                        Text("-$t ✕", color = Color.White, fontSize = 12.sp)
                    }
                }
            }
        }
    }
}

@Composable
fun WipeDataSheet(onComplete: () -> Unit, onDismiss: () -> Unit) {
    val store = UserStore.shared
    val userData by store.data.collectAsState()
    val hasPasscode by AppState.hasPasscode.collectAsState()
    val tinted = userData.settings.tintedGlass
    val scope = rememberCoroutineScope()

    var keepLikes by remember { mutableStateOf(true) }
    var keepFollowing by remember { mutableStateOf(true) }
    var keepOffline by remember { mutableStateOf(true) }
    var keepAccounts by remember { mutableStateOf(true) }
    var keepAlgorithm by remember { mutableStateOf(true) }
    var keepPasscode by remember { mutableStateOf(true) }
    var isWiping by remember { mutableStateOf(false) }
    var confirmDialog by remember { mutableStateOf(false) }

    Box(modifier = Modifier.fillMaxSize().liquidGlassBackground(tinted).padding(20.dp)) {
        Column(modifier = Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text("Wipe App Data", color = Color.White, fontSize = 20.sp, fontWeight = FontWeight.Bold)
                    Text("Your active License Key is always kept safe.", color = Theme.textSecondary, fontSize = 12.sp)
                }
                IconButton(onClick = onDismiss) { Icon(Icons.Default.Close, contentDescription = "Close", tint = Color.White) }
            }

            Column(modifier = Modifier.fillMaxWidth().liquidGlassCard(20.dp, tinted).padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("CHOOSE WHAT TO KEEP", color = Theme.textSecondary, fontSize = 11.sp, fontWeight = FontWeight.Bold)
                SettingSwitch("Keep Likes (${userData.liked.size})", keepLikes) { keepLikes = it }
                SettingSwitch("Keep Following", keepFollowing) { keepFollowing = it }
                SettingSwitch("Keep Offline Vault (${userData.downloaded.size})", keepOffline) { keepOffline = it }
                SettingSwitch("Keep Connected Accounts (𝕏 / IG / R34)", keepAccounts) { keepAccounts = it }
                SettingSwitch("Keep Smart Algorithm & Taste", keepAlgorithm) { keepAlgorithm = it }
                if (hasPasscode) {
                    SettingSwitch("Keep App Passcode", keepPasscode) { keepPasscode = it }
                }
            }

            Button(
                onClick = { confirmDialog = true },
                enabled = !isWiping,
                colors = ButtonDefaults.buttonColors(containerColor = Theme.accent),
                modifier = Modifier.fillMaxWidth().height(48.dp)
            ) {
                if (isWiping) CircularProgressIndicator(color = Color.White, modifier = Modifier.size(18.dp))
                else Text("Wipe Selected Data", fontWeight = FontWeight.Bold)
            }
        }
    }

    if (confirmDialog) {
        AlertDialog(
            onDismissRequest = { confirmDialog = false },
            title = { Text("Wipe unselected app data?") },
            text = { Text("Your License Key will remain active.") },
            confirmButton = {
                TextButton(onClick = {
                    confirmDialog = false
                    scope.launch {
                        isWiping = true
                        store.performSelectiveWipe(
                            UserStore.WipeOptions(keepLikes, keepFollowing, keepOffline, keepAccounts, keepAlgorithm, keepPasscode)
                        )
                        isWiping = false
                        onComplete()
                    }
                }) { Text("Wipe Now", color = Color.Red) }
            },
            dismissButton = { TextButton(onClick = { confirmDialog = false }) { Text("Cancel") } }
        )
    }
}
