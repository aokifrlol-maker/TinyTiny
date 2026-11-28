package com.bella.tinytiny

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowLeft
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.fragment.app.FragmentActivity
import coil.compose.AsyncImage
import coil.request.ImageRequest
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.io.File

enum class BrowseScope(val label: String) {
    ALL("All"),
    ONLYFANS("OnlyFans"),
    REDDIT("Reddit"),
    RULE34("Rule34"),
    X("𝕏"),
    IG("IG"),
    EROME("Erome"),
    LONG_VIDEOS("Long Videos")
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun GoonedBrowseOverlay(
    initialScope: BrowseScope = BrowseScope.ALL,
    onClose: () -> Unit,
    onSelectFeed: (FeedSource) -> Unit,
    onOpenPost: (Gif) -> Unit = {},
    onConnectX: () -> Unit,
    onConnectIG: () -> Unit,
    onSetupR34Key: () -> Unit
) {
    val userData by UserStore.shared.data.collectAsState()
    val categories by UserStore.shared.categories.collectAsState()
    val tinted = userData.settings.tintedGlass
    val scope = rememberCoroutineScope()

    var query by remember { mutableStateOf("") }
    var searchScope by remember { mutableStateOf(initialScope) }
    var isSearching by remember { mutableStateOf(false) }
    var topCreators by remember { mutableStateOf<List<OFCreator>>(emptyList()) }
    var creatorResults by remember { mutableStateOf<List<OFCreator>>(emptyList()) }
    var subredditResults by remember { mutableStateOf<List<GoonedSearchItem>>(emptyList()) }
    var userResults by remember { mutableStateOf<List<GoonedSearchItem>>(emptyList()) }
    var r34Suggestions by remember { mutableStateOf<List<Rule34TagSuggestion>>(emptyList()) }
    var eromePreview by remember { mutableStateOf<List<Gif>>(emptyList()) }
    var showReceiveDrop by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) {
        topCreators = OnlyFansAPI.fetchTopCreators(18)
    }

    // 180ms debounced parallel search across all sources (matches iOS!)
    LaunchedEffect(query, searchScope) {
        val q = query.trim()
        if (q.isEmpty()) {
            creatorResults = emptyList()
            subredditResults = emptyList()
            userResults = emptyList()
            r34Suggestions = emptyList()
            eromePreview = emptyList()
            isSearching = false
            return@LaunchedEffect
        }
        delay(180)
        isSearching = true
        coroutineScope {
            val ofDef = if (searchScope == BrowseScope.ALL || searchScope == BrowseScope.ONLYFANS) {
                async { OnlyFansAPI.searchCreators(q, 10) }
            } else null
            val redDef = if (searchScope == BrowseScope.ALL || searchScope == BrowseScope.REDDIT) {
                async { try { GoonedAPI.search(q) } catch (_: Throwable) { GoonedSearchResponse() } }
            } else null
            val r34Def = if (searchScope == BrowseScope.ALL || searchScope == BrowseScope.RULE34) {
                async { Rule34API.autocomplete(q) }
            } else null
            val erDef = if (searchScope == BrowseScope.ALL || searchScope == BrowseScope.EROME) {
                async { LongVideoAPI.searchEromePreview(q, 6) }
            } else null

            creatorResults = ofDef?.await() ?: emptyList()
            val red = redDef?.await()
            subredditResults = red?.subreddits ?: emptyList()
            userResults = red?.users ?: emptyList()
            r34Suggestions = r34Def?.await() ?: emptyList()
            eromePreview = erDef?.await() ?: emptyList()
        }
        isSearching = false
    }

    fun submitSearch() {
        val q = query.trim()
        if (q.isEmpty()) return
        UserStore.shared.recordSearchSignal(q)
        val lower = q.lowercase()
        when {
            lower.startsWith("of:") -> onSelectFeed(FeedSource.OFSearch(q.drop(3).trim()))
            lower.startsWith("r34:") -> onSelectFeed(FeedSource.Rule34(q.drop(4).trim()))
            lower.startsWith("#") -> onSelectFeed(FeedSource.Rule34(q.drop(1).trim()))
            lower.startsWith("r/") -> onSelectFeed(FeedSource.Subreddit(q.drop(2).trim()))
            lower.startsWith("u/") -> onSelectFeed(FeedSource.User(q.drop(2).trim()))
            lower.startsWith("ig:") -> onSelectFeed(FeedSource.IGUser(q.drop(3).trim()))
            lower.startsWith("@") -> onSelectFeed(FeedSource.XUser(q.drop(1).trim()))
            searchScope == BrowseScope.ONLYFANS -> onSelectFeed(FeedSource.OFSearch(q))
            searchScope == BrowseScope.REDDIT -> onSelectFeed(FeedSource.Subreddit(q))
            searchScope == BrowseScope.RULE34 -> onSelectFeed(FeedSource.Rule34(Rule34API.parseTags(q).joinToString(" ")))
            searchScope == BrowseScope.X -> onSelectFeed(FeedSource.XSearch(q))
            searchScope == BrowseScope.IG -> onSelectFeed(FeedSource.IGUser(q))
            searchScope == BrowseScope.EROME -> onSelectFeed(FeedSource.LongSearch(LongVideoSite.EROME, q))
            searchScope == BrowseScope.LONG_VIDEOS -> onSelectFeed(FeedSource.LongSearch(LongVideoSite.ALL, q))
            else -> onSelectFeed(FeedSource.MultiSearch(q))
        }
    }

    fun appendRule34Tag(tagValue: String) {
        val parts = query.trim().split(Regex("\\s+")).filter { it.isNotEmpty() }.toMutableList()
        if (parts.isEmpty()) {
            query = "$tagValue "
        } else {
            parts[parts.lastIndex] = tagValue
            query = parts.joinToString(" ") + " "
        }
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .liquidGlassBackground(tinted)
            .statusBarsPadding()
            .navigationBarsPadding()
    ) {
        Column(modifier = Modifier.fillMaxSize()) {
            // Search Bar Header (matches iOS)
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 14.dp, vertical = 10.dp)
            ) {
                OutlinedTextField(
                    value = query,
                    onValueChange = { query = it },
                    placeholder = { Text("Search creators, tags, r/subs, @handles...", fontSize = 13.5.sp, color = Theme.textMuted) },
                    leadingIcon = { Icon(Icons.Default.Search, contentDescription = null, tint = Theme.textSecondary) },
                    trailingIcon = {
                        if (query.isNotEmpty()) {
                            IconButton(onClick = { query = "" }) {
                                Icon(Icons.Default.Cancel, contentDescription = "Clear", tint = Theme.textSecondary, modifier = Modifier.size(18.dp))
                            }
                        }
                    },
                    singleLine = true,
                    shape = RoundedCornerShape(999.dp),
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                    keyboardActions = KeyboardActions(onSearch = { submitSearch() }),
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedTextColor = Color.White,
                        unfocusedTextColor = Color.White,
                        focusedBorderColor = Theme.accentBright,
                        unfocusedBorderColor = Theme.borderSubtle,
                        focusedContainerColor = Color.White.copy(0.06f),
                        unfocusedContainerColor = Color.White.copy(0.06f)
                    ),
                    modifier = Modifier.weight(1f)
                )
                Spacer(Modifier.width(8.dp))
                IconButton(onClick = onClose, modifier = Modifier.size(42.dp).liquidGlassCircle(tinted)) {
                    Icon(Icons.Default.Close, contentDescription = "Close", tint = Color.White)
                }
            }

            // BrowseScope Pill Bar (exact iOS parity: All, OnlyFans, Reddit, Rule34, 𝕏, IG, Erome, Long Videos)
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .horizontalScroll(rememberScrollState())
                    .padding(horizontal = 14.dp, vertical = 4.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                BrowseScope.entries.forEach { sc ->
                    val active = searchScope == sc
                    Box(
                        modifier = Modifier
                            .liquidGlassCapsule(tinted = true, active = active)
                            .clickable { searchScope = sc }
                            .padding(horizontal = 14.dp, vertical = 7.dp)
                    ) {
                        Text(
                            sc.label,
                            color = Color.White,
                            fontSize = 12.5.sp,
                            fontWeight = if (active) FontWeight.Bold else FontWeight.Medium
                        )
                    }
                }
            }

            // Live Rule34 multi-tag preview pills
            val parsedR34Tags = remember(query) { Rule34API.parseTags(query) }
            if (query.isNotBlank() && (searchScope == BrowseScope.RULE34 || parsedR34Tags.size > 1)) {
                Column(modifier = Modifier.padding(horizontal = 14.dp, vertical = 4.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        parsedR34Tags.forEach { t ->
                            Box(
                                modifier = Modifier
                                    .clip(CircleShape)
                                    .background(Color(0xFF478042).copy(0.55f))
                                    .border(0.8.dp, Color(0xFF9EE493).copy(0.5f), CircleShape)
                                    .padding(horizontal = 10.dp, vertical = 4.dp)
                            ) {
                                Text("#$t", color = Color(0xFFB0EBA6), fontSize = 11.5.sp, fontWeight = FontWeight.Bold)
                            }
                        }
                    }
                    Text("Space = new tag · _ = combine", color = Theme.textMuted, fontSize = 11.sp)
                }
            }

            LazyColumn(
                contentPadding = PaddingValues(horizontal = 14.dp, vertical = 10.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
                modifier = Modifier.weight(1f)
            ) {
                if (query.trim().isNotEmpty()) {
                    val q = query.trim()
                    val subClean = q.replace(Regex("[^A-Za-z0-9_]"), "")
                    val handleClean = q.replace("@", "").replace(" ", "")

                    if (isSearching) {
                        item {
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(8.dp),
                                modifier = Modifier.padding(vertical = 2.dp)
                            ) {
                                CircularProgressIndicator(color = Theme.accentBright, modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
                                Text("Searching...", color = Theme.textSecondary, fontSize = 12.sp)
                            }
                        }
                    }

                    // 1. Hero "Search Across All Sources" card (matches iOS screenshot)
                    if (searchScope == BrowseScope.ALL && q.length >= 2) {
                        item {
                            SearchHeroCard(
                                title = "Search \"$q\" Across All Sources",
                                subtitle = "𝕏, OnlyFans, Rule34, Reddit & Long Videos combined",
                                tinted = tinted,
                                leading = {
                                    Box(
                                        modifier = Modifier.size(38.dp).clip(CircleShape).background(Theme.accent),
                                        contentAlignment = Alignment.Center
                                    ) {
                                        Icon(Icons.Default.AutoAwesome, contentDescription = null, tint = Color.White, modifier = Modifier.size(20.dp))
                                    }
                                },
                                onClick = {
                                    UserStore.shared.recordSearchSignal(q)
                                    onSelectFeed(FeedSource.MultiSearch(q))
                                }
                            )
                        }
                    }

                    // 2. ONLYFANS CREATORS section with avatar, @handle · N videos, #tags & inline Follow button!
                    if (creatorResults.isNotEmpty() && (searchScope == BrowseScope.ALL || searchScope == BrowseScope.ONLYFANS)) {
                        item {
                            Text("ONLYFANS CREATORS", color = Color(0xFF00B8F5), fontSize = 11.5.sp, fontWeight = FontWeight.ExtraBold)
                        }
                        items(creatorResults.take(6), key = { "of_${it.id}" }) { c ->
                            val isFollowed = UserStore.shared.isFollowingOFCreator(c.id, c.cleanHandle)
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .liquidGlassCard(18.dp, tinted)
                                    .clickable { onSelectFeed(FeedSource.OFCreator(c.id, c.cleanHandle, c.displayName)) }
                                    .padding(12.dp)
                            ) {
                                Box(
                                    modifier = Modifier
                                        .size(44.dp)
                                        .clip(CircleShape)
                                        .background(Brush.linearGradient(listOf(Color(0xFF00B8F5), Color(0xFF0085D6)))),
                                    contentAlignment = Alignment.Center
                                ) {
                                    Text("OF", color = Color.White, fontWeight = FontWeight.Black, fontSize = 13.sp)
                                    AsyncImage(
                                        model = c.avatarURL,
                                        contentDescription = c.label,
                                        contentScale = ContentScale.Crop,
                                        modifier = Modifier.fillMaxSize().clip(CircleShape)
                                    )
                                }
                                Spacer(Modifier.width(12.dp))
                                Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                                    Text(c.label, color = Color.White, fontWeight = FontWeight.Bold, fontSize = 14.5.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                    val vidText = c.videoCount?.takeIf { it > 0 }?.let { " · $it videos" } ?: ""
                                    Text("@${c.cleanHandle}$vidText", color = Theme.textSecondary, fontSize = 12.sp, maxLines = 1)
                                    val cTags = (c.creatorTags ?: emptyList()).take(3)
                                    if (cTags.isNotEmpty()) {
                                        Text(
                                            cTags.joinToString(" ") { "#$it" },
                                            color = Color(0xFF38BDF8),
                                            fontSize = 11.5.sp,
                                            maxLines = 1,
                                            overflow = TextOverflow.Ellipsis
                                        )
                                    }
                                }
                                Spacer(Modifier.width(8.dp))
                                Box(
                                    modifier = Modifier
                                        .liquidGlassCapsule(tinted = tinted, active = isFollowed)
                                        .clickable { UserStore.shared.toggleFollowOFCreator(c.id, c.cleanHandle, c.displayName, c.avatarURL) }
                                        .padding(horizontal = 14.dp, vertical = 7.dp)
                                ) {
                                    Text(if (isFollowed) "Following" else "Follow", color = Color.White, fontSize = 12.sp, fontWeight = FontWeight.Bold)
                                }
                            }
                        }
                    }

                    // 3. Direct Source Action Cards (Rule34, r/sub, Search on X, Search on Erome)
                    if (searchScope == BrowseScope.ALL || searchScope == BrowseScope.RULE34) {
                        item {
                            SearchHeroCard(
                                title = "Rule34: #${parsedR34Tags.joinToString(" #")}",
                                subtitle = "Videos, GIFs & artwork",
                                tinted = tinted,
                                leading = { BrandLogoRule34(34.dp) },
                                onClick = {
                                    UserStore.shared.recordSearchSignal(q)
                                    onSelectFeed(FeedSource.Rule34(parsedR34Tags.joinToString(" ")))
                                }
                            )
                        }
                    }
                    if ((searchScope == BrowseScope.ALL || searchScope == BrowseScope.REDDIT) && subClean.isNotEmpty()) {
                        item {
                            SearchHeroCard(
                                title = "r/$subClean",
                                subtitle = "Open subreddit feed",
                                tinted = tinted,
                                leading = {
                                    Box(
                                        modifier = Modifier.size(34.dp).clip(CircleShape).background(Theme.accent),
                                        contentAlignment = Alignment.Center
                                    ) {
                                        Icon(Icons.Default.NorthEast, contentDescription = null, tint = Color.White, modifier = Modifier.size(18.dp))
                                    }
                                },
                                onClick = { onSelectFeed(FeedSource.Subreddit(subClean)) }
                            )
                        }
                    }
                    if (searchScope == BrowseScope.ALL || searchScope == BrowseScope.X) {
                        item {
                            SearchHeroCard(
                                title = "Search \"$q\" on 𝕏",
                                subtitle = "18+ video posts",
                                tinted = tinted,
                                leading = { BrandLogoX(34.dp, connected = userData.xSession.isConnected) },
                                onClick = {
                                    UserStore.shared.recordSearchSignal(q)
                                    onSelectFeed(FeedSource.XSearch(q))
                                }
                            )
                        }
                    }
                    if (searchScope == BrowseScope.ALL || searchScope == BrowseScope.EROME) {
                        item {
                            SearchHeroCard(
                                title = "Search \"$q\" on Erome",
                                subtitle = "Open full Erome video/album scroller for \"$q\"",
                                tinted = tinted,
                                leading = { BrandLogoErome(34.dp) },
                                onClick = {
                                    UserStore.shared.recordSearchSignal(q)
                                    onSelectFeed(FeedSource.LongSearch(LongVideoSite.EROME, q))
                                }
                            )
                        }
                    }

                    // 4. EROME ALBUMS 2-column thumbnail grid (matches iOS screenshot!)
                    if (eromePreview.isNotEmpty() && (searchScope == BrowseScope.ALL || searchScope == BrowseScope.EROME)) {
                        item {
                            Text("EROME ALBUMS", color = Color(0xFFF03D8F), fontSize = 11.5.sp, fontWeight = FontWeight.ExtraBold)
                        }
                        items(eromePreview.take(6).chunked(2)) { pair ->
                            Row(horizontalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.fillMaxWidth()) {
                                pair.forEach { album ->
                                    Row(
                                        verticalAlignment = Alignment.CenterVertically,
                                        modifier = Modifier
                                            .weight(1f)
                                            .liquidGlassCard(16.dp, tinted)
                                            .clickable { onOpenPost(album) }
                                            .padding(8.dp)
                                    ) {
                                        AsyncImage(
                                            model = album.thumbURL,
                                            contentDescription = album.title,
                                            contentScale = ContentScale.Crop,
                                            modifier = Modifier.size(width = 44.dp, height = 58.dp).clip(RoundedCornerShape(10.dp))
                                        )
                                        Spacer(Modifier.width(8.dp))
                                        Text(
                                            album.title ?: "Erome Album",
                                            color = Color.White,
                                            fontSize = 12.5.sp,
                                            fontWeight = FontWeight.Bold,
                                            maxLines = 2,
                                            overflow = TextOverflow.Ellipsis
                                        )
                                    }
                                }
                                if (pair.size == 1) Spacer(Modifier.weight(1f))
                            }
                        }
                    }

                    // 5. Search in Long Videos card
                    if (searchScope == BrowseScope.ALL || searchScope == BrowseScope.LONG_VIDEOS) {
                        item {
                            SearchHeroCard(
                                title = "Search \"$q\" in Long Videos",
                                subtitle = "Erome, Eporner, Pornhub, xHamster & SpankBang",
                                tinted = tinted,
                                leading = { BrandLogoLongVideos(34.dp) },
                                onClick = {
                                    UserStore.shared.recordSearchSignal(q)
                                    onSelectFeed(FeedSource.LongSearch(LongVideoSite.ALL, q))
                                }
                            )
                        }
                    }

                    // 6. Side-by-side X @handle and IG @handle cards (matches iOS screenshot!)
                    if (handleClean.isNotEmpty() && (searchScope == BrowseScope.ALL || searchScope == BrowseScope.X || searchScope == BrowseScope.IG)) {
                        item {
                            Row(horizontalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.fillMaxWidth()) {
                                Row(
                                    verticalAlignment = Alignment.CenterVertically,
                                    modifier = Modifier
                                        .weight(1f)
                                        .liquidGlassCard(16.dp, tinted)
                                        .clickable { onSelectFeed(FeedSource.XUser(handleClean)) }
                                        .padding(12.dp)
                                ) {
                                    BrandLogoX(28.dp)
                                    Spacer(Modifier.width(8.dp))
                                    Text("@$handleClean", color = Color.White, fontWeight = FontWeight.Bold, fontSize = 13.5.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                }
                                Row(
                                    verticalAlignment = Alignment.CenterVertically,
                                    modifier = Modifier
                                        .weight(1f)
                                        .liquidGlassCard(16.dp, tinted)
                                        .clickable { onSelectFeed(FeedSource.IGUser(handleClean)) }
                                        .padding(12.dp)
                                ) {
                                    BrandLogoInstagram(28.dp)
                                    Spacer(Modifier.width(8.dp))
                                    Text("@$handleClean", color = Color.White, fontWeight = FontWeight.Bold, fontSize = 13.5.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                }
                            }
                        }
                    }

                    // 7. RULE34 TAG SUGGESTIONS with green "+" multi-tag composer button (matches iOS screenshot!)
                    if (r34Suggestions.isNotEmpty() && (searchScope == BrowseScope.ALL || searchScope == BrowseScope.RULE34)) {
                        item {
                            Text("RULE34 TAG SUGGESTIONS", color = Color(0xFF9EE493), fontSize = 11.5.sp, fontWeight = FontWeight.ExtraBold)
                        }
                        items(r34Suggestions.take(8), key = { "r34_${it.value}" }) { sug ->
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .liquidGlassCard(16.dp, tinted)
                                    .clickable { onSelectFeed(FeedSource.Rule34(sug.value)) }
                                    .padding(horizontal = 14.dp, vertical = 11.dp)
                            ) {
                                Text(
                                    text = "#${sug.label.ifEmpty { sug.value }}",
                                    color = Color.White,
                                    fontWeight = FontWeight.Bold,
                                    fontSize = 14.sp,
                                    modifier = Modifier.weight(1f)
                                )
                                Box(
                                    modifier = Modifier
                                        .size(28.dp)
                                        .clip(CircleShape)
                                        .background(Color(0xFF9EE493))
                                        .clickable { appendRule34Tag(sug.value) },
                                    contentAlignment = Alignment.Center
                                ) {
                                    Icon(Icons.Default.Add, contentDescription = "Add Tag", tint = Color(0xFF0F380F), modifier = Modifier.size(18.dp))
                                }
                            }
                        }
                    }

                    // 8. Matching CATEGORIES
                    val matchingCats = categories.filter { it.displayName.contains(q, ignoreCase = true) }
                    if (matchingCats.isNotEmpty() && (searchScope == BrowseScope.ALL || searchScope == BrowseScope.REDDIT)) {
                        item { Text("CATEGORIES", color = Theme.textSecondary, fontSize = 11.5.sp, fontWeight = FontWeight.ExtraBold) }
                        items(matchingCats.take(6), key = { "cat_${it.name}" }) { cat ->
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .liquidGlassCard(16.dp, tinted)
                                    .clickable {
                                        if (cat.name.equals("Rule34", ignoreCase = true)) onSelectFeed(FeedSource.Rule34(""))
                                        else onSelectFeed(FeedSource.Category(cat.name))
                                    }
                                    .padding(14.dp)
                            ) {
                                Text(cat.displayName, color = Color.White, fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f))
                                Text(Gif.shortCount(cat.subscribers), color = Theme.textSecondary, fontSize = 12.sp)
                            }
                        }
                    }

                    // 9. SUBREDDITS (with iconUrl + subscriber count!)
                    if (subredditResults.isNotEmpty() && (searchScope == BrowseScope.ALL || searchScope == BrowseScope.REDDIT)) {
                        item { Text("SUBREDDITS", color = Theme.textSecondary, fontSize = 11.5.sp, fontWeight = FontWeight.ExtraBold) }
                        items(subredditResults.take(8), key = { "sub_${it.id}" }) { sub ->
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .liquidGlassCard(16.dp, tinted)
                                    .clickable { onSelectFeed(FeedSource.Subreddit(sub.name)) }
                                    .padding(12.dp)
                            ) {
                                Box(
                                    modifier = Modifier.size(34.dp).clip(CircleShape).background(Color(0xFFF078A0)),
                                    contentAlignment = Alignment.Center
                                ) {
                                    Text("r/", color = Color.Black, fontWeight = FontWeight.Black, fontSize = 12.sp)
                                    if (!sub.iconUrl.isNullOrEmpty()) {
                                        AsyncImage(model = sub.iconUrl, contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize().clip(CircleShape))
                                    }
                                }
                                Spacer(Modifier.width(10.dp))
                                Text("r/${sub.name}", color = Color.White, fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f))
                                sub.subscribers?.takeIf { it > 0 }?.let {
                                    Text(Gif.shortCount(it), color = Theme.textSecondary, fontSize = 12.sp)
                                }
                            }
                        }
                    }

                    // 10. REDDIT USERS
                    if (userResults.isNotEmpty() && (searchScope == BrowseScope.ALL || searchScope == BrowseScope.REDDIT)) {
                        item { Text("REDDIT USERS", color = Theme.textSecondary, fontSize = 11.5.sp, fontWeight = FontWeight.ExtraBold) }
                        items(userResults.take(6), key = { "usr_${it.id}" }) { u ->
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .liquidGlassCard(16.dp, tinted)
                                    .clickable { onSelectFeed(FeedSource.User(u.name)) }
                                    .padding(12.dp)
                            ) {
                                Box(
                                    modifier = Modifier.size(34.dp).clip(CircleShape).background(Theme.surfaceElevated),
                                    contentAlignment = Alignment.Center
                                ) {
                                    Text("u/", color = Color.White, fontWeight = FontWeight.Bold, fontSize = 12.sp)
                                }
                                Spacer(Modifier.width(10.dp))
                                Text("u/${u.name}", color = Color.White, fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f))
                            }
                        }
                    }
                } else {
                    // Default Browse View (hidden while searching)
                    item {
                        Row(
                            modifier = Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
                            horizontalArrangement = Arrangement.spacedBy(8.dp)
                        ) {
                            QuickPlatformPill("𝕏", { BrandLogoX(18.dp, connected = userData.xSession.isConnected) }, tinted) {
                                if (userData.xSession.isConnected) onSelectFeed(FeedSource.XForYou) else onConnectX()
                            }
                            QuickPlatformPill("Rule34", { BrandLogoRule34(18.dp) }, tinted) { onSelectFeed(FeedSource.Rule34("")) }
                            QuickPlatformPill("IG", { BrandLogoInstagram(18.dp, connected = userData.igSession.isConnected) }, tinted) {
                                if (userData.igSession.isConnected) onSelectFeed(FeedSource.IGReels) else onConnectIG()
                            }
                            QuickPlatformPill("OnlyFans", { BrandLogoOnlyFans(18.dp) }, tinted) { onSelectFeed(FeedSource.OFForYou) }
                            QuickPlatformPill("Long", { BrandLogoLongVideos(18.dp) }, tinted) { onSelectFeed(FeedSource.LongVideos(LongVideoSite.ALL)) }
                            QuickPlatformPill("Erome", { BrandLogoErome(18.dp) }, tinted) { onSelectFeed(FeedSource.LongVideos(LongVideoSite.EROME)) }
                            QuickPlatformPill("Share Drop", { Icon(Icons.Default.Lock, null, tint = Theme.accentBright, modifier = Modifier.size(16.dp)) }, tinted) {
                                showReceiveDrop = true
                            }
                        }
                    }

                    // Continue Watching Card — handles ALL 20+ recent.kind values (fallback: For You)
                    val recent = userData.recentFeeds.firstOrNull()
                    item {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier
                                .fillMaxWidth()
                                .liquidGlassCard(20.dp, tinted)
                                .clickable {
                                    val target: FeedSource = when (recent?.kind) {
                                        "foryou" -> FeedSource.ForYou
                                        "following" -> FeedSource.Following
                                        "category" -> FeedSource.Category(recent.name)
                                        "subreddit" -> FeedSource.Subreddit(recent.name)
                                        "user" -> FeedSource.User(recent.name)
                                        "xforyou" -> FeedSource.XForYou
                                        "xfollowing" -> FeedSource.XFollowing
                                        "xbookmarks" -> FeedSource.XBookmarks
                                        "xlikes" -> FeedSource.XLikes
                                        "ximages" -> FeedSource.XImages
                                        "xsearch" -> FeedSource.XSearch(recent.name)
                                        "xuser" -> FeedSource.XUser(recent.name)
                                        "igreels" -> FeedSource.IGReels
                                        "igfollowing" -> FeedSource.IGFollowing
                                        "igsaved" -> FeedSource.IGSaved
                                        "iguser" -> FeedSource.IGUser(recent.name)
                                        "rule34" -> FeedSource.Rule34(if (recent.name == "all") "" else recent.name)
                                        "offoryou" -> FeedSource.OFForYou
                                        "oftrending" -> FeedSource.OFTrending
                                        "oflatest" -> FeedSource.OFLatest
                                        "ofdms" -> FeedSource.OFDMs
                                        "ofcreator" -> {
                                            val parts = recent.name.split("|")
                                            FeedSource.OFCreator(parts.first(), parts.getOrElse(1) { parts.first() }, null)
                                        }
                                        "ofsearch" -> FeedSource.OFSearch(recent.name)
                                        "longvideos", "long" -> {
                                            val site = LongVideoSite.entries.firstOrNull { it.rawValue == recent.name } ?: LongVideoSite.ALL
                                            FeedSource.LongVideos(site)
                                        }
                                        "multisearch" -> FeedSource.MultiSearch(recent.name)
                                        "reddithome" -> FeedSource.RedditHome
                                        "redditpopular" -> FeedSource.RedditPopular
                                        "redditsaved" -> FeedSource.RedditSaved
                                        "redditupvoted" -> FeedSource.RedditUpvoted
                                        "longsearch" -> {
                                            val parts = recent.name.split("|", limit = 2)
                                            val site = LongVideoSite.entries.firstOrNull { it.rawValue == parts.first() } ?: LongVideoSite.ALL
                                            FeedSource.LongSearch(site, parts.getOrElse(1) { recent.name })
                                        }
                                        else -> FeedSource.ForYou
                                    }
                                    onSelectFeed(target)
                                }
                                .padding(14.dp)
                        ) {
                            Icon(Icons.Default.PlayCircle, contentDescription = null, tint = Theme.accentBright, modifier = Modifier.size(34.dp))
                            Spacer(Modifier.width(12.dp))
                            Column(modifier = Modifier.weight(1f)) {
                                Text("CONTINUE WATCHING", color = Theme.accentBright, fontSize = 10.sp, fontWeight = FontWeight.ExtraBold)
                                Text(recent?.displayTitle ?: "Continue: For You", color = Color.White, fontWeight = FontWeight.Bold, fontSize = 15.sp)
                                if (recent != null) {
                                    Text("${recent.swipedCount} videos watched", color = Theme.textSecondary, fontSize = 11.5.sp)
                                }
                            }
                            Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null, tint = Theme.textSecondary)
                        }
                    }

                    // Trending OnlyFans Creators with "OF" gradient fallback avatar
                    if (topCreators.isNotEmpty()) {
                        item { Text("TRENDING CREATORS", color = Theme.textSecondary, fontSize = 11.5.sp, fontWeight = FontWeight.ExtraBold) }
                        item {
                            Row(
                                modifier = Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
                                horizontalArrangement = Arrangement.spacedBy(12.dp)
                            ) {
                                topCreators.forEach { c ->
                                    Column(
                                        horizontalAlignment = Alignment.CenterHorizontally,
                                        modifier = Modifier.width(74.dp).clickable { onSelectFeed(FeedSource.OFCreator(c.id, c.cleanHandle, c.displayName)) }
                                    ) {
                                        Box(
                                            modifier = Modifier
                                                .size(62.dp)
                                                .clip(CircleShape)
                                                .background(Brush.linearGradient(listOf(Color(0xFF00B8F5), Color(0xFF0085D6))))
                                                .border(1.5.dp, Theme.accentBright, CircleShape),
                                            contentAlignment = Alignment.Center
                                        ) {
                                            Text("OF", color = Color.White, fontWeight = FontWeight.Black, fontSize = 16.sp)
                                            AsyncImage(
                                                model = c.avatarURL,
                                                contentDescription = c.label,
                                                contentScale = ContentScale.Crop,
                                                modifier = Modifier.fillMaxSize().clip(CircleShape)
                                            )
                                        }
                                        Spacer(Modifier.height(4.dp))
                                        Text(c.label, color = Color.White, fontSize = 11.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                    }
                                }
                            }
                        }
                    }

                    // Featured Categories
                    item { Text("FEATURED", color = Theme.textSecondary, fontSize = 11.5.sp, fontWeight = FontWeight.ExtraBold) }
                    item {
                        val featured = categories.filter { it.name in GoonedCategory.featuredNames }
                        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            featured.forEach { cat ->
                                Box(
                                    modifier = Modifier
                                        .liquidGlassCapsule(tinted = true)
                                        .clickable { onSelectFeed(FeedSource.Category(cat.name)) }
                                        .padding(horizontal = 14.dp, vertical = 9.dp)
                                ) {
                                    Text(cat.displayName, color = Color.White, fontWeight = FontWeight.Bold, fontSize = 13.sp)
                                }
                            }
                        }
                    }

                    // All Categories (A–Z) pill grid excluding featured, routing "Rule34" -> FeedSource.Rule34("")
                    item { Text("ALL CATEGORIES (A–Z)", color = Theme.textSecondary, fontSize = 11.5.sp, fontWeight = FontWeight.ExtraBold) }
                    item {
                        val rest = categories.filterNot { it.name in GoonedCategory.featuredNames }.sortedBy { it.displayName }
                        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            rest.forEach { cat ->
                                Box(
                                    modifier = Modifier
                                        .liquidGlassCapsule(tinted = tinted)
                                        .clickable {
                                            if (cat.name.equals("Rule34", ignoreCase = true)) onSelectFeed(FeedSource.Rule34(""))
                                            else onSelectFeed(FeedSource.Category(cat.name))
                                        }
                                        .padding(horizontal = 13.dp, vertical = 8.dp)
                                ) {
                                    Text(cat.displayName, color = Color.White, fontSize = 12.5.sp, fontWeight = FontWeight.SemiBold)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    if (showReceiveDrop) {
        ReceiveDropSheet(
            onDismiss = { showReceiveDrop = false },
            onOpenPost = { post -> showReceiveDrop = false; onOpenPost(post) }
        )
    }
}

@Composable
private fun SearchHeroCard(
    title: String,
    subtitle: String,
    tinted: Boolean,
    leading: @Composable () -> Unit,
    onClick: () -> Unit
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .liquidGlassCard(18.dp, tinted)
            .clickable { onClick() }
            .padding(horizontal = 14.dp, vertical = 13.dp)
    ) {
        leading()
        Spacer(Modifier.width(12.dp))
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(title, color = Color.White, fontWeight = FontWeight.Bold, fontSize = 14.5.sp)
            Text(subtitle, color = Theme.textSecondary, fontSize = 12.sp)
        }
        Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null, tint = Theme.textMuted, modifier = Modifier.size(18.dp))
    }
}

@Composable
private fun QuickPlatformPill(label: String, icon: @Composable () -> Unit, tinted: Boolean, onClick: () -> Unit) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        modifier = Modifier
            .liquidGlassCapsule(tinted)
            .clickable { onClick() }
            .padding(horizontal = 12.dp, vertical = 7.dp)
    ) {
        icon()
        Text(label, color = Color.White, fontSize = 12.5.sp, fontWeight = FontWeight.Bold)
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
fun GoonedLikesView(
    onOpenSettings: () -> Unit,
    onStartStash: () -> Unit,
    onPlayLikedPost: (Gif) -> Unit,
    onPlayOfflinePost: (Gif) -> Unit
) {
    val ctx = LocalContext.current
    val userData by UserStore.shared.data.collectAsState()
    val diskUsage by OfflineManager.diskUsageText.collectAsState()
    val tinted = userData.settings.tintedGlass
    val scope = rememberCoroutineScope()

    var tab by remember { mutableIntStateOf(0) } // 0 = Liked, 1 = Offline
    var selectMode by remember { mutableStateOf(false) }
    var selectedIds by remember { mutableStateOf<Set<String>>(emptySet()) }
    var shareCollection by remember { mutableStateOf<List<Gif>?>(null) }
    var shareSingle by remember { mutableStateOf<Gif?>(null) }
    var contextTarget by remember { mutableStateOf<Gif?>(null) }
    var bulkToast by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(Unit) { OfflineManager.refreshDiskUsage() }

    val list = remember(tab, userData.liked, userData.downloaded) {
        (if (tab == 0) userData.liked else userData.downloaded).distinctBy { it.id }
    }

    fun showBulkToast(msg: String) {
        bulkToast = msg
        scope.launch { delay(2400); bulkToast = null }
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .liquidGlassBackground(tinted)
            .statusBarsPadding()
            .navigationBarsPadding()
            .padding(bottom = 68.dp)
    ) {
        Column(modifier = Modifier.fillMaxSize()) {
            // Header with Liked / Offline pills directly in top bar (matches iOS)
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 10.dp)
            ) {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.weight(1f)) {
                    Box(
                        modifier = Modifier
                            .liquidGlassCapsule(tinted, active = tab == 0)
                            .clickable { tab = 0; selectedIds = emptySet() }
                            .padding(horizontal = 14.dp, vertical = 8.dp)
                    ) { Text("Liked (${userData.liked.size})", color = Color.White, fontWeight = FontWeight.Bold, fontSize = 13.sp) }
                    Box(
                        modifier = Modifier
                            .liquidGlassCapsule(tinted, active = tab == 1)
                            .clickable { tab = 1; selectedIds = emptySet() }
                            .padding(horizontal = 14.dp, vertical = 8.dp)
                    ) { Text("Offline (${userData.downloaded.size})", color = Color.White, fontWeight = FontWeight.Bold, fontSize = 13.sp) }
                }
                if (list.isNotEmpty()) {
                    TextButton(onClick = { selectMode = !selectMode; selectedIds = emptySet() }) {
                        Text(if (selectMode) "Done" else "Select", color = Theme.accentBright, fontWeight = FontWeight.Bold)
                    }
                }
                IconButton(
                    onClick = {
                        scope.launch {
                            showBulkToast("Syncing cloud backup...")
                            val res = LicenseManager.syncBidirectionalBackup()
                            showBulkToast(res)
                        }
                    },
                    modifier = Modifier.size(36.dp).liquidGlassCircle(tinted)
                ) {
                    Icon(Icons.Default.Sync, contentDescription = "Sync", tint = Color.White, modifier = Modifier.size(18.dp))
                }
                Spacer(Modifier.width(6.dp))
                IconButton(onClick = onOpenSettings, modifier = Modifier.size(36.dp).liquidGlassCircle(tinted)) {
                    Icon(Icons.Default.Settings, contentDescription = "Settings", tint = Color.White, modifier = Modifier.size(18.dp))
                }
            }

            // "Play Offline (X MB)" button on Offline tab (exact iOS parity)
            if (tab == 1 && list.isNotEmpty()) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.Center,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 14.dp, vertical = 4.dp)
                        .liquidGlassCapsule(tinted = true, active = true)
                        .clickable { onPlayOfflinePost(list.first()) }
                        .padding(vertical = 10.dp)
                ) {
                    Icon(Icons.Default.PlayArrow, contentDescription = null, tint = Color.White, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(6.dp))
                    Text("Play Offline ($diskUsage)", color = Color.White, fontWeight = FontWeight.Bold, fontSize = 13.5.sp)
                }
            }

            if (list.isEmpty()) {
                Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    Column(
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(10.dp),
                        modifier = Modifier.padding(28.dp)
                    ) {
                        Icon(if (tab == 0) Icons.Default.FavoriteBorder else Icons.Default.Download, contentDescription = null, tint = Theme.textMuted, modifier = Modifier.size(44.dp))
                        Text(if (tab == 0) "No Liked Videos Yet" else "Offline Vault Empty", color = Color.White, fontSize = 17.sp, fontWeight = FontWeight.Bold)
                        Text(
                            if (tab == 0) "Double-tap any clip or hit the heart icon to save it here."
                            else "Download videos to watch offline anytime without internet.",
                            color = Theme.textSecondary,
                            fontSize = 13.sp
                        )
                        Box(
                            modifier = Modifier
                                .liquidGlassCapsule(tinted = true, active = true)
                                .clickable { onStartStash() }
                                .padding(horizontal = 20.dp, vertical = 10.dp)
                        ) {
                            Text(if (tab == 0) "Start your stash" else "Browse videos to download", color = Color.White, fontWeight = FontWeight.Bold, fontSize = 13.5.sp)
                        }
                    }
                }
            } else {
                LazyVerticalGrid(
                    columns = GridCells.Fixed(3),
                    contentPadding = PaddingValues(horizontal = 2.dp, vertical = 4.dp),
                    horizontalArrangement = Arrangement.spacedBy(2.dp),
                    verticalArrangement = Arrangement.spacedBy(2.dp),
                    modifier = Modifier.weight(1f)
                ) {
                    items(list, key = { it.id }) { gif ->
                        val isSel = gif.id in selectedIds
                        Box(
                            modifier = Modifier
                                .aspectRatio(0.68f)
                                .combinedClickable(
                                    onClick = {
                                        if (selectMode) {
                                            selectedIds = if (isSel) selectedIds - gif.id else selectedIds + gif.id
                                        } else {
                                            if (tab == 0) onPlayLikedPost(gif) else onPlayOfflinePost(gif)
                                        }
                                    },
                                    onLongClick = { contextTarget = gif }
                                )
                        ) {
                            GridThumb(gif = gif, showUpvotes = true)
                            if (selectMode) {
                                if (isSel) {
                                    Box(modifier = Modifier.fillMaxSize().background(Color.Black.copy(0.45f)))
                                }
                                Box(
                                    modifier = Modifier
                                        .align(Alignment.BottomEnd)
                                        .padding(6.dp)
                                        .size(24.dp)
                                        .clip(CircleShape)
                                        .background(if (isSel) Theme.accent else Color.Black.copy(0.55f))
                                        .border(1.5.dp, Color.White, CircleShape),
                                    contentAlignment = Alignment.Center
                                ) {
                                    if (isSel) Icon(Icons.Default.Check, contentDescription = null, tint = Color.White, modifier = Modifier.size(14.dp))
                                }
                            }
                        }
                    }
                }
            }

            // 2-Row Bulk Selection Bar (matches iOS: Select All, Delete, Save File, Save to Photos, Share)
            if (selectMode && selectedIds.isNotEmpty()) {
                val chosen = list.filter { it.id in selectedIds }
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 12.dp, vertical = 6.dp)
                        .liquidGlassCard(20.dp, tinted = true)
                        .padding(horizontal = 14.dp, vertical = 10.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("${chosen.size} selected", color = Color.White, fontWeight = FontWeight.Bold, fontSize = 13.5.sp)
                        Spacer(Modifier.weight(1f))
                        TextButton(onClick = {
                            selectedIds = if (selectedIds.size == list.size) emptySet() else list.map { it.id }.toSet()
                        }) {
                            Text(if (selectedIds.size == list.size) "Deselect All" else "Select All", color = Theme.accentBright, fontSize = 12.sp)
                        }
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
                        OutlinedButton(
                            onClick = {
                                chosen.forEach { g ->
                                    if (tab == 0) UserStore.shared.toggleLike(g) else OfflineManager.removeDownload(g)
                                }
                                selectedIds = emptySet()
                                selectMode = false
                                showBulkToast("Removed ${chosen.size} items")
                            },
                            modifier = Modifier.weight(1f),
                            contentPadding = PaddingValues(horizontal = 6.dp, vertical = 6.dp)
                        ) { Text("Delete", color = Color(0xFFFF6B6B), fontSize = 11.5.sp, fontWeight = FontWeight.Bold) }

                        OutlinedButton(
                            onClick = {
                                scope.launch {
                                    var saved = 0
                                    for (g in chosen) {
                                        if (!OfflineManager.isDownloaded(g)) OfflineManager.download(g)
                                        val path = OfflineManager.localMediaURL(g.id)?.removePrefix("file://") ?: continue
                                        val ok = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
                                            OfflineManager.saveToMediaStoreGallery(File(path))
                                        }
                                        if (ok) saved++
                                    }
                                    showBulkToast("Saved $saved to Gallery")
                                }
                            },
                            modifier = Modifier.weight(1f),
                            contentPadding = PaddingValues(horizontal = 6.dp, vertical = 6.dp)
                        ) { Text("Photos", color = Color.White, fontSize = 11.5.sp, fontWeight = FontWeight.Bold) }

                        Button(
                            onClick = { shareCollection = chosen },
                            colors = ButtonDefaults.buttonColors(containerColor = Theme.accent),
                            modifier = Modifier.weight(1f),
                            contentPadding = PaddingValues(horizontal = 6.dp, vertical = 6.dp)
                        ) { Text("Share", fontSize = 11.5.sp, fontWeight = FontWeight.Bold) }
                    }
                }
            }
        }

        AnimatedVisibility(
            visible = bulkToast != null,
            modifier = Modifier.align(Alignment.TopCenter).padding(top = 60.dp)
        ) {
            Text(
                bulkToast ?: "",
                color = Color.White,
                fontSize = 12.5.sp,
                fontWeight = FontWeight.Bold,
                modifier = Modifier.liquidGlassCapsule(tinted = true, active = true).padding(horizontal = 16.dp, vertical = 8.dp)
            )
        }
    }

    // Long-press Context Menu Dialog
    contextTarget?.let { target ->
        val isDl = OfflineManager.isDownloaded(target)
        AlertDialog(
            onDismissRequest = { contextTarget = null },
            title = { Text(target.title?.take(40)?.ifEmpty { "Clip Actions" } ?: "Clip Actions") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    TextButton(onClick = { contextTarget = null; shareSingle = target }, modifier = Modifier.fillMaxWidth()) {
                        Text("Share Encrypted Drop")
                    }
                    if (isDl) {
                        TextButton(onClick = {
                            contextTarget = null
                            OfflineManager.localMediaURL(target.id)?.removePrefix("file://")?.let { path ->
                                ShareService.shareLocalFileWithChooser(ctx, File(path))
                            }
                        }, modifier = Modifier.fillMaxWidth()) {
                            Text("Export / Share File")
                        }
                        TextButton(onClick = {
                            contextTarget = null
                            OfflineManager.localMediaURL(target.id)?.removePrefix("file://")?.let { path ->
                                scope.launch {
                                    val ok = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
                                        OfflineManager.saveToMediaStoreGallery(File(path))
                                    }
                                    showBulkToast(if (ok) "Saved to Photos" else "Save failed")
                                }
                            }
                        }, modifier = Modifier.fillMaxWidth()) {
                            Text("Save to Photos")
                        }
                    }
                    TextButton(onClick = {
                        contextTarget = null
                        OfflineManager.toggleDownload(target)
                        showBulkToast(if (isDl) "Deleted offline copy" else "Downloading...")
                    }, modifier = Modifier.fillMaxWidth()) {
                        Text(if (isDl) "Delete Offline Copy" else "Download for Offline")
                    }
                    if (tab == 0) {
                        TextButton(onClick = {
                            contextTarget = null
                            UserStore.shared.toggleLike(target)
                        }, modifier = Modifier.fillMaxWidth()) {
                            Text("Remove from Likes", color = Color(0xFFFF6B6B))
                        }
                    }
                }
            },
            confirmButton = { TextButton(onClick = { contextTarget = null }) { Text("Close") } }
        )
    }

    shareSingle?.let { g -> ShareItemSheet(gif = g, onDismiss = { shareSingle = null }) }
    shareCollection?.let { itemsToShare ->
        ShareCollectionSheet(posts = itemsToShare, onDismiss = { shareCollection = null; selectMode = false; selectedIds = emptySet() })
    }
}

@Composable
fun GridThumb(gif: Gif, showUpvotes: Boolean = false) {
    val ctx = LocalContext.current
    val urls = remember(gif.id, gif.posterUrl, gif.thumbnailUrl, gif.mediaUrl) { gif.posterFallbackURLs }
    var urlIdx by remember(gif.id) { mutableIntStateOf(0) }
    var useReferer by remember(gif.id, urlIdx) { mutableStateOf(true) }
    var loaded by remember(gif.id) { mutableStateOf(false) }
    var exhausted by remember(gif.id) { mutableStateOf(false) }
    val activeUrl = urls.getOrNull(urlIdx)

    Box(modifier = Modifier.fillMaxSize().background(Color(0xFF1A0B12))) {
        if (!loaded && !exhausted && activeUrl != null) {
            ShimmerPlaceholder(modifier = Modifier.fillMaxSize())
        }
        if (activeUrl != null && !exhausted) {
            val req = remember(activeUrl, useReferer) {
                ImageRequest.Builder(ctx).data(activeUrl).crossfade(true).apply {
                    for ((k, v) in MediaHeaders.headers(activeUrl, includeReferer = useReferer)) addHeader(k, v)
                }.build()
            }
            AsyncImage(
                model = req,
                contentDescription = gif.title,
                contentScale = ContentScale.Crop,
                onSuccess = { loaded = true },
                onError = {
                    if (useReferer && !activeUrl.startsWith("file://")) {
                        useReferer = false
                    } else if (urlIdx + 1 < urls.size) {
                        urlIdx += 1
                    } else {
                        exhausted = true
                    }
                },
                modifier = Modifier.fillMaxSize()
            )
        }
        if (activeUrl == null || exhausted) {
            Column(
                modifier = Modifier.fillMaxSize().padding(8.dp),
                verticalArrangement = Arrangement.Center,
                horizontalAlignment = Alignment.CenterHorizontally
            ) {
                Icon(
                    Icons.Default.PlayCircleOutline,
                    contentDescription = null,
                    tint = Color.White.copy(0.55f),
                    modifier = Modifier.size(28.dp)
                )
                val fallbackLabel = gif.author?.takeIf { it.isNotBlank() }?.let { "@$it" }
                    ?: gif.title?.takeIf { it.isNotBlank() }
                    ?: gif.subreddit?.takeIf { it.isNotBlank() }
                if (!fallbackLabel.isNullOrBlank()) {
                    Spacer(Modifier.height(4.dp))
                    Text(
                        fallbackLabel,
                        color = Color.White.copy(0.65f),
                        fontSize = 10.sp,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                        textAlign = androidx.compose.ui.text.style.TextAlign.Center
                    )
                }
            }
        }
        // Bottom-left source badge + optional upvote count
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(4.dp),
            modifier = Modifier
                .align(Alignment.BottomStart)
                .padding(5.dp)
                .clip(CircleShape)
                .background(Color.Black.copy(0.65f))
                .padding(horizontal = 6.dp, vertical = 2.dp)
        ) {
            val badge = when {
                gif.isOnlyFansPost -> "OF"
                gif.isXPost -> "𝕏"
                gif.isIGPost -> "IG"
                gif.isRule34Post -> "34"
                gif.isLongVideoPost -> gif.longVideoSiteLabel?.take(2)?.uppercase() ?: "LV"
                else -> "r/"
            }
            Text(badge, color = Color.White, fontSize = 9.5.sp, fontWeight = FontWeight.ExtraBold)
            if (showUpvotes && (gif.upvotes ?: 0) > 0) {
                Text(Gif.shortCount(gif.upvotes), color = Color.White.copy(0.85f), fontSize = 9.sp, fontWeight = FontWeight.SemiBold)
            }
        }
        if (OfflineManager.isDownloaded(gif)) {
            Icon(
                Icons.Default.OfflinePin,
                contentDescription = "Offline",
                tint = Theme.accentBright,
                modifier = Modifier.align(Alignment.TopEnd).padding(5.dp).size(16.dp)
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
    var openOF by remember { mutableStateOf(true) }
    var openX by remember { mutableStateOf(true) }
    var openIG by remember { mutableStateOf(true) }
    var openSubs by remember { mutableStateOf(true) }
    var openRedditUsers by remember { mutableStateOf(true) }

    val hasAnyFollow = userData.followedOFCreators.isNotEmpty() || userData.followedXUsers.isNotEmpty() ||
        userData.followedIGUsers.isNotEmpty() || userData.followedSubreddits.isNotEmpty() || userData.followedUsers.isNotEmpty()

    Box(
        modifier = Modifier
            .fillMaxSize()
            .liquidGlassBackground(tinted)
            .statusBarsPadding()
            .navigationBarsPadding()
            .padding(bottom = 68.dp)
    ) {
        LazyColumn(
            contentPadding = PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            item {
                Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                    Text("Following", color = Color.White, fontSize = 24.sp, fontWeight = FontWeight.Bold)
                    Spacer(Modifier.weight(1f))
                    IconButton(onClick = { AppState.lock() }, modifier = Modifier.size(38.dp).liquidGlassCircle(tinted)) {
                        Icon(Icons.Default.Lock, contentDescription = "Lock", tint = Color.White, modifier = Modifier.size(18.dp))
                    }
                    Spacer(Modifier.width(8.dp))
                    IconButton(onClick = onOpenSettings, modifier = Modifier.size(38.dp).liquidGlassCircle(tinted)) {
                        Icon(Icons.Default.Settings, contentDescription = "Settings", tint = Color.White, modifier = Modifier.size(18.dp))
                    }
                }
            }

            // Connected X Card
            item {
                Column(modifier = Modifier.fillMaxWidth().liquidGlassCard(20.dp, tinted).padding(14.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        BrandLogoX(26.dp, connected = userData.xSession.isConnected)
                        Spacer(Modifier.width(10.dp))
                        Column(modifier = Modifier.weight(1f)) {
                            Text(if (userData.xSession.isConnected) "@${userData.xSession.displayHandle}" else "Connect Personal 𝕏", color = Color.White, fontWeight = FontWeight.Bold)
                            Text(if (userData.xSession.isConnected) "Connected · 18+ video feeds ready" else "Sign in to stream 𝕏 For You, Following & Bookmarks", color = Theme.textSecondary, fontSize = 11.5.sp)
                        }
                        if (!userData.xSession.isConnected) {
                            Button(onClick = onConnectX, colors = ButtonDefaults.buttonColors(containerColor = Theme.accent)) { Text("Connect") }
                        }
                    }
                    if (userData.xSession.isConnected) {
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            SmallGlassPill("𝕏 For You", tinted) { onSelectFeed(FeedSource.XForYou) }
                            SmallGlassPill("Following", tinted) { onSelectFeed(FeedSource.XFollowing) }
                            SmallGlassPill("Bookmarks", tinted) { onSelectFeed(FeedSource.XBookmarks) }
                        }
                    }
                }
            }

            // Connected IG Card with 3 Quick Feed Buttons (exact iOS parity!)
            item {
                Column(modifier = Modifier.fillMaxWidth().liquidGlassCard(20.dp, tinted).padding(14.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        BrandLogoInstagram(26.dp, connected = userData.igSession.isConnected)
                        Spacer(Modifier.width(10.dp))
                        Column(modifier = Modifier.weight(1f)) {
                            Text(if (userData.igSession.isConnected) "@${userData.igSession.username}" else "Connect Personal Instagram", color = Color.White, fontWeight = FontWeight.Bold)
                            Text(if (userData.igSession.isConnected) "Connected · IG Reels & Saved ready" else "Sign in to stream IG Reels & Saved", color = Theme.textSecondary, fontSize = 11.5.sp)
                        }
                        if (!userData.igSession.isConnected) {
                            Button(onClick = onConnectIG, colors = ButtonDefaults.buttonColors(containerColor = Theme.accent)) { Text("Connect") }
                        }
                    }
                    if (userData.igSession.isConnected) {
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            SmallGlassPill("IG Reels", tinted) { onSelectFeed(FeedSource.IGReels) }
                            SmallGlassPill("IG Following", tinted) { onSelectFeed(FeedSource.IGFollowing) }
                            SmallGlassPill("IG Saved", tinted) { onSelectFeed(FeedSource.IGSaved) }
                        }
                    }
                }
            }

            if (!hasAnyFollow) {
                item {
                    Column(
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(8.dp),
                        modifier = Modifier.fillMaxWidth().padding(vertical = 36.dp)
                    ) {
                        Icon(Icons.Default.PersonAdd, contentDescription = null, tint = Theme.textMuted, modifier = Modifier.size(40.dp))
                        Text("No follows yet", color = Color.White, fontSize = 16.sp, fontWeight = FontWeight.Bold)
                        Text("Tap + on any video or search creators to follow them here.", color = Theme.textSecondary, fontSize = 12.5.sp)
                    }
                }
            } else {
                if (userData.followedOFCreators.isNotEmpty()) {
                    item {
                        FollowDropdownSection("OnlyFans Creators (${userData.followedOFCreators.size})", openOF, { openOF = !openOF }, tinted, leading = { BrandLogoOnlyFans(20.dp) }) {
                            userData.followedOFCreators.forEach { c ->
                                FollowListRow(
                                    title = c.label,
                                    subtitle = "@${c.handle}",
                                    avatarUrl = c.avatarURL,
                                    badgeText = "OF",
                                    badgeColor = Color(0xFF00B8F5),
                                    onClick = { onSelectFeed(FeedSource.OFCreator(c.id, c.handle, c.displayName)) },
                                    onUnfollow = { UserStore.shared.toggleFollowOFCreator(c.id, c.handle, c.displayName) }
                                )
                            }
                        }
                    }
                }
                if (userData.followedXUsers.isNotEmpty()) {
                    item {
                        FollowDropdownSection("𝕏 Creators (${userData.followedXUsers.size})", openX, { openX = !openX }, tinted, leading = { BrandLogoX(20.dp) }) {
                            userData.followedXUsers.forEach { u ->
                                FollowListRow(
                                    title = "@$u",
                                    subtitle = "𝕏 Account",
                                    badgeText = "𝕏",
                                    badgeColor = Color.Black,
                                    onClick = { onSelectFeed(FeedSource.XUser(u)) },
                                    onUnfollow = { UserStore.shared.toggleFollowXUser(u) }
                                )
                            }
                        }
                    }
                }
                if (userData.followedIGUsers.isNotEmpty()) {
                    item {
                        FollowDropdownSection("Instagram Creators (${userData.followedIGUsers.size})", openIG, { openIG = !openIG }, tinted, leading = { BrandLogoInstagram(20.dp) }) {
                            userData.followedIGUsers.forEach { u ->
                                FollowListRow(
                                    title = "@$u",
                                    subtitle = "Instagram",
                                    badgeText = "IG",
                                    badgeColor = Color(0xFFC229A6),
                                    onClick = { onSelectFeed(FeedSource.IGUser(u)) },
                                    onUnfollow = { UserStore.shared.toggleFollowIGUser(u) }
                                )
                            }
                        }
                    }
                }
                if (userData.followedSubreddits.isNotEmpty()) {
                    item {
                        FollowDropdownSection("Subreddits (${userData.followedSubreddits.size})", openSubs, { openSubs = !openSubs }, tinted) {
                            userData.followedSubreddits.forEach { s ->
                                FollowListRow(
                                    title = "r/$s",
                                    subtitle = "Subreddit",
                                    badgeText = "r/",
                                    badgeColor = Color(0xFFF078A0),
                                    onClick = { onSelectFeed(FeedSource.Subreddit(s)) },
                                    onUnfollow = { UserStore.shared.toggleFollowSubreddit(s) }
                                )
                            }
                        }
                    }
                }
                if (userData.followedUsers.isNotEmpty()) {
                    item {
                        FollowDropdownSection("Reddit Creators (${userData.followedUsers.size})", openRedditUsers, { openRedditUsers = !openRedditUsers }, tinted) {
                            userData.followedUsers.forEach { u ->
                                FollowListRow(
                                    title = "u/$u",
                                    subtitle = "Reddit Creator",
                                    badgeText = "u/",
                                    badgeColor = Theme.accent,
                                    onClick = { onSelectFeed(FeedSource.User(u)) },
                                    onUnfollow = { UserStore.shared.toggleFollowUser(u) }
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun FollowListRow(
    title: String,
    subtitle: String,
    avatarUrl: String? = null,
    badgeText: String,
    badgeColor: Color,
    onClick: () -> Unit,
    onUnfollow: () -> Unit
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .clickable { onClick() }
            .padding(vertical = 6.dp)
    ) {
        Box(
            modifier = Modifier.size(34.dp).clip(CircleShape).background(badgeColor),
            contentAlignment = Alignment.Center
        ) {
            Text(badgeText, color = Color.White, fontWeight = FontWeight.Black, fontSize = 11.sp)
            if (!avatarUrl.isNullOrEmpty()) {
                AsyncImage(model = avatarUrl, contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize().clip(CircleShape))
            }
        }
        Spacer(Modifier.width(10.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(title, color = Color.White, fontWeight = FontWeight.Bold, fontSize = 14.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(subtitle, color = Theme.textSecondary, fontSize = 11.5.sp)
        }
        TextButton(onClick = onUnfollow, contentPadding = PaddingValues(horizontal = 10.dp, vertical = 2.dp)) {
            Text("Unfollow", color = Color(0xFFFF6B6B), fontSize = 12.sp, fontWeight = FontWeight.Bold)
        }
    }
}

@Composable
private fun SmallGlassPill(label: String, tinted: Boolean, onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .liquidGlassCapsule(tinted)
            .clickable { onClick() }
            .padding(horizontal = 12.dp, vertical = 6.dp)
    ) {
        Text(label, color = Color.White, fontSize = 12.sp, fontWeight = FontWeight.Bold)
    }
}

@Composable
private fun FollowDropdownSection(
    title: String,
    expanded: Boolean,
    onToggle: () -> Unit,
    tinted: Boolean,
    leading: (@Composable () -> Unit)? = null,
    content: @Composable ColumnScope.() -> Unit
) {
    Column(modifier = Modifier.fillMaxWidth().liquidGlassCard(18.dp, tinted).padding(14.dp)) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.fillMaxWidth().clickable { onToggle() }
        ) {
            if (leading != null) { leading(); Spacer(Modifier.width(8.dp)) }
            Text(title, color = Color.White, fontWeight = FontWeight.Bold, fontSize = 14.5.sp, modifier = Modifier.weight(1f))
            Icon(if (expanded) Icons.Default.ExpandLess else Icons.Default.ExpandMore, contentDescription = null, tint = Theme.textSecondary)
        }
        AnimatedVisibility(visible = expanded) {
            Column(modifier = Modifier.padding(top = 8.dp), content = content)
        }
    }
}

@Composable
fun CreatorProfileGridView(
    source: FeedSource,
    onClose: () -> Unit,
    onSelectPost: (Gif, List<Gif>, String?, Boolean) -> Unit
) {
    val userData by UserStore.shared.data.collectAsState()
    val tinted = userData.settings.tintedGlass
    val scope = rememberCoroutineScope()
    val model = remember(source) { FeedModel(source) }
    DisposableEffect(model) {
        onDispose { model.close() }
    }
    val items by model.items.collectAsState()
    val isLoading by model.isLoading.collectAsState()
    var r34Filter by remember(source) { mutableStateOf("") }

    LaunchedEffect(source) {
        if (model.items.value.isEmpty()) model.loadMore()
    }

    val displayedItems = remember(items, r34Filter) {
        if (r34Filter.isBlank()) items
        else {
            val tokens = Rule34API.parseTags(r34Filter)
            items.filter { g ->
                val hay = "${g.title ?: ""} ${MediaMetaRegistry.tags(g.id, g.author).joinToString(" ")}".lowercase()
                tokens.all { hay.contains(it) }
            }
        }
    }

    val isFollowed = when (source) {
        is FeedSource.Subreddit -> UserStore.shared.isFollowingSubreddit(source.name)
        is FeedSource.User -> UserStore.shared.isFollowingUser(source.name)
        is FeedSource.XUser -> UserStore.shared.isFollowingXUser(source.handle)
        is FeedSource.IGUser -> UserStore.shared.isFollowingIGUser(source.handle)
        is FeedSource.OFCreator -> UserStore.shared.isFollowingOFCreator(source.id, source.handle)
        else -> false
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .liquidGlassBackground(tinted)
            .statusBarsPadding()
            .navigationBarsPadding()
    ) {
        Column(modifier = Modifier.fillMaxSize()) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 10.dp)
            ) {
                IconButton(onClick = onClose, modifier = Modifier.size(38.dp).liquidGlassCircle(tinted)) {
                    Icon(Icons.AutoMirrored.Filled.KeyboardArrowLeft, contentDescription = "Back", tint = Color.White)
                }
                Spacer(Modifier.width(10.dp))
                Column(modifier = Modifier.weight(1f)) {
                    Text(source.displayTitle, color = Color.White, fontWeight = FontWeight.Bold, fontSize = 17.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text("${items.size} posts", color = Theme.textSecondary, fontSize = 11.5.sp)
                }
                if (source !is FeedSource.Rule34) {
                    Box(
                        modifier = Modifier
                            .liquidGlassCapsule(tinted, active = isFollowed)
                            .clickable {
                                when (source) {
                                    is FeedSource.Subreddit -> UserStore.shared.toggleFollowSubreddit(source.name)
                                    is FeedSource.User -> UserStore.shared.toggleFollowUser(source.name)
                                    is FeedSource.XUser -> UserStore.shared.toggleFollowXUser(source.handle)
                                    is FeedSource.IGUser -> UserStore.shared.toggleFollowIGUser(source.handle)
                                    is FeedSource.OFCreator -> UserStore.shared.toggleFollowOFCreator(source.id, source.handle, source.displayName)
                                    else -> {}
                                }
                            }
                            .padding(horizontal = 14.dp, vertical = 7.dp)
                    ) {
                        Text(if (isFollowed) "Following" else "Follow", color = Color.White, fontSize = 12.5.sp, fontWeight = FontWeight.Bold)
                    }
                }
            }

            if (source is FeedSource.Rule34) {
                OutlinedTextField(
                    value = r34Filter,
                    onValueChange = { r34Filter = it },
                    placeholder = { Text("Filter #tags in this gallery...", fontSize = 13.sp, color = Theme.textMuted) },
                    singleLine = true,
                    shape = RoundedCornerShape(999.dp),
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 4.dp)
                )
            }

            if (isLoading && items.isEmpty()) {
                Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        CircularProgressIndicator(color = Theme.accentBright)
                        Text("Loading ${source.displayTitle}...", color = Theme.textSecondary, fontSize = 13.sp)
                    }
                }
            } else if (displayedItems.isEmpty()) {
                Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        Icon(Icons.Default.VideoLibrary, contentDescription = null, tint = Theme.textMuted, modifier = Modifier.size(40.dp))
                        Text("No posts found for ${source.displayTitle}", color = Theme.textSecondary, fontSize = 14.sp)
                        Button(onClick = { scope.launch { model.refresh() } }, colors = ButtonDefaults.buttonColors(containerColor = Theme.accent)) {
                            Text("Retry")
                        }
                    }
                }
            } else {
                LazyVerticalGrid(
                    columns = GridCells.Fixed(3),
                    horizontalArrangement = Arrangement.spacedBy(2.dp),
                    verticalArrangement = Arrangement.spacedBy(2.dp),
                    modifier = Modifier.weight(1f)
                ) {
                    items(displayedItems, key = { it.id }) { gif ->
                        Box(
                            modifier = Modifier
                                .aspectRatio(0.68f)
                                .clickable { onSelectPost(gif, displayedItems, model.currentCursor, model.canLoadMore) }
                        ) {
                            GridThumb(gif)
                            LaunchedEffect(gif.id) { model.onItemAppear(gif) }
                        }
                    }
                    // Bottom pagination spinner + manual "Load More" button (exact iOS parity)
                    if (model.canLoadMore) {
                        item(span = { GridItemSpan(3) }) {
                            Box(
                                modifier = Modifier.fillMaxWidth().padding(vertical = 18.dp),
                                contentAlignment = Alignment.Center
                            ) {
                                if (isLoading) {
                                    CircularProgressIndicator(color = Theme.accentBright, modifier = Modifier.size(24.dp), strokeWidth = 2.dp)
                                } else {
                                    Box(
                                        modifier = Modifier
                                            .liquidGlassCapsule(tinted)
                                            .clickable { scope.launch { model.loadMore() } }
                                            .padding(horizontal = 20.dp, vertical = 9.dp)
                                    ) {
                                        Text("Load More", color = Color.White, fontWeight = FontWeight.Bold, fontSize = 13.sp)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun GoonedSettingsModal(
    onDismiss: () -> Unit,
    onConnectX: () -> Unit,
    onConnectIG: () -> Unit,
    onConnectReddit: () -> Unit = {},
    onSetupR34Key: () -> Unit
) {
    val ctx = LocalContext.current
    val activity = ctx as? FragmentActivity
    val userData by UserStore.shared.data.collectAsState()
    val tasteState by SmartTasteEngine.shared.state.collectAsState()
    val licStatus by LicenseManager.status.collectAsState()
    val diskUsage by OfflineManager.diskUsageText.collectAsState()
    val hasPasscode by AppState.hasPasscode.collectAsState()
    val requireOnOpen by AppState.requirePasscodeOnOpen.collectAsState()
    val tinted = userData.settings.tintedGlass
    val scope = rememberCoroutineScope()

    var syncMsg by remember { mutableStateOf<String?>(null) }
    var copiedKey by remember { mutableStateOf(false) }
    var showAlgoEditor by remember { mutableStateOf(false) }
    var showWipeSheet by remember { mutableStateOf(false) }
    var showPasscodeSetup by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) {
        OfflineManager.refreshDiskUsage()
        LicenseManager.verifySilently()
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black.copy(0.65f))
            .clickable { onDismiss() }
            .statusBarsPadding()
            .navigationBarsPadding()
            .padding(14.dp),
        contentAlignment = Alignment.Center
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .liquidGlassCard(28.dp, tinted = true)
                .clickable(interactionSource = remember { androidx.compose.foundation.interaction.MutableInteractionSource() }, indication = null) {}
                .padding(18.dp)
                .verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(14.dp)
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Settings", color = Color.White, fontSize = 22.sp, fontWeight = FontWeight.Bold)
                Spacer(Modifier.weight(1f))
                IconButton(onClick = onDismiss, modifier = Modifier.size(34.dp).liquidGlassCircle(tinted)) {
                    Icon(Icons.Default.Close, contentDescription = "Close", tint = Color.White, modifier = Modifier.size(18.dp))
                }
            }

            // Connected Accounts
            SettingsCard("Connected Accounts", tinted) {
                Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                    BrandLogoX(24.dp, connected = userData.xSession.isConnected)
                    Spacer(Modifier.width(10.dp))
                    Column(modifier = Modifier.weight(1f)) {
                        Text(if (userData.xSession.isConnected) "𝕏 (@${userData.xSession.displayHandle})" else "𝕏 Account", color = Color.White, fontWeight = FontWeight.Bold)
                        Text(if (userData.xSession.isConnected) "Connected" else "Not connected", color = Theme.textSecondary, fontSize = 11.5.sp)
                    }
                    if (userData.xSession.isConnected) {
                        TextButton(onClick = { UserStore.shared.disconnectX() }) { Text("Disconnect", color = Color(0xFFFF6B6B)) }
                    } else {
                        TextButton(onClick = onConnectX) { Text("Connect", color = Theme.accentBright) }
                    }
                }
                if (userData.xSession.isConnected) {
                    SettingSwitch("Mix 𝕏 into For You", userData.xSession.mixIntoForYou) { v ->
                        UserStore.shared.updateXSession(userData.xSession.copy(mixIntoForYou = v))
                    }
                }
                HorizontalDivider(color = Theme.borderSubtle)
                Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                    BrandLogoInstagram(24.dp, connected = userData.igSession.isConnected)
                    Spacer(Modifier.width(10.dp))
                    Column(modifier = Modifier.weight(1f)) {
                        Text(if (userData.igSession.isConnected) "Instagram (@${userData.igSession.username})" else "Instagram Account", color = Color.White, fontWeight = FontWeight.Bold)
                        Text(if (userData.igSession.isConnected) "Connected" else "Not connected", color = Theme.textSecondary, fontSize = 11.5.sp)
                    }
                    if (userData.igSession.isConnected) {
                        TextButton(onClick = { UserStore.shared.disconnectIG() }) { Text("Disconnect", color = Color(0xFFFF6B6B)) }
                    } else {
                        TextButton(onClick = onConnectIG) { Text("Connect", color = Theme.accentBright) }
                    }
                }
                if (userData.igSession.isConnected) {
                    SettingSwitch("Mix IG Reels into For You", userData.igSession.mixIntoForYou) { v ->
                        UserStore.shared.updateIGSession(userData.igSession.copy(mixIntoForYou = v))
                    }
                }
                HorizontalDivider(color = Theme.borderSubtle)
                Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                    BrandLogoReddit(24.dp, connected = userData.redditSession.isConnected)
                    Spacer(Modifier.width(10.dp))
                    Column(modifier = Modifier.weight(1f)) {
                        Text(if (userData.redditSession.isConnected) "Reddit (u/${userData.redditSession.username})" else "Personal Reddit", color = Color.White, fontWeight = FontWeight.Bold)
                        Text(if (userData.redditSession.isConnected) "Connected · Dedicated tab" else "Not connected", color = Theme.textSecondary, fontSize = 11.5.sp)
                    }
                    if (userData.redditSession.isConnected) {
                        TextButton(onClick = { UserStore.shared.disconnectReddit() }) { Text("Disconnect", color = Color(0xFFFF6B6B)) }
                    } else {
                        TextButton(onClick = onConnectReddit) { Text("Connect", color = Theme.accentBright) }
                    }
                }
                if (userData.redditSession.isConnected) {
                    SettingSwitch("Mix Personal Reddit into For You", userData.redditSession.mixIntoForYou) { v ->
                        UserStore.shared.updateRedditSession(userData.redditSession.copy(mixIntoForYou = v))
                    }
                }
                HorizontalDivider(color = Theme.borderSubtle)
                Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                    BrandLogoRule34(24.dp)
                    Spacer(Modifier.width(10.dp))
                    Column(modifier = Modifier.weight(1f)) {
                        Text("Rule34.xxx API", color = Color.White, fontWeight = FontWeight.Bold)
                        Text(
                            if (userData.r34Credentials.hasCustomCredentials) "Custom key active" else "Built-in default active",
                            color = Theme.textSecondary,
                            fontSize = 11.5.sp
                        )
                    }
                    TextButton(onClick = onSetupR34Key) { Text("Manage", color = Theme.accentBright) }
                }
            }

            // Algorithm & For You Sources
            SettingsCard("Algorithm & For You", tinted) {
                SettingSwitch("Smart Taste Algorithm", userData.settings.algorithmEnabled) { v ->
                    UserStore.shared.updateSettings { it.copy(algorithmEnabled = v) }
                }
                Text(UserStore.shared.topTasteSummary, color = Theme.textSecondary, fontSize = 12.sp)
                if (userData.algorithm.boostedTags.isNotEmpty()) {
                    FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        userData.algorithm.boostedTags.forEach { t ->
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                modifier = Modifier
                                    .liquidGlassCapsule(tinted = true, active = true)
                                    .clickable { UserStore.shared.removeBoostedTag(t) }
                                    .padding(horizontal = 10.dp, vertical = 4.dp)
                            ) {
                                Text("#$t ×", color = Color.White, fontSize = 11.5.sp, fontWeight = FontWeight.Bold)
                            }
                        }
                    }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
                    Button(
                        onClick = { showAlgoEditor = true },
                        colors = ButtonDefaults.buttonColors(containerColor = Theme.accent),
                        modifier = Modifier.weight(1f)
                    ) { Text("Tune Algorithm & Tags", fontSize = 12.5.sp, fontWeight = FontWeight.Bold) }
                    OutlinedButton(onClick = { UserStore.shared.resetAlgorithm() }) {
                        Text("Reset Taste", color = Color.White, fontSize = 12.sp)
                    }
                }
                val fy = tasteState.sourceSettings
                SettingSwitch("Reddit in For You", fy.includeReddit) { v -> SmartTasteEngine.shared.updateForYouSources { it.copy(includeReddit = v) } }
                SettingSwitch("OnlyFans in For You", fy.includeOnlyFans) { v -> SmartTasteEngine.shared.updateForYouSources { it.copy(includeOnlyFans = v) } }
                SettingSwitch("𝕏 in For You", fy.includeX) { v -> SmartTasteEngine.shared.updateForYouSources { it.copy(includeX = v) } }
                SettingSwitch("Instagram Reels in For You", fy.includeInstagram) { v -> SmartTasteEngine.shared.updateForYouSources { it.copy(includeInstagram = v) } }
                SettingSwitch("Rule34 in For You", fy.includeRule34) { v -> SmartTasteEngine.shared.updateForYouSources { it.copy(includeRule34 = v) } }
            }

            // Playback & Appearance
            SettingsCard("Playback & Appearance", tinted) {
                SettingSwitch("HD Video Quality", userData.settings.hd) { v -> UserStore.shared.updateSettings { it.copy(hd = v) } }
                SettingSwitch("Start Videos Muted", userData.settings.muted) { v -> UserStore.shared.updateSettings { it.copy(muted = v) } }
                SettingSwitch("Auto-Scroll Videos", userData.settings.autoScroll) { v -> UserStore.shared.updateSettings { it.copy(autoScroll = v) } }
                SettingSwitch("Play Videos to End (Auto-Scroll)", userData.settings.playVideosToEnd) { v -> UserStore.shared.updateSettings { it.copy(playVideosToEnd = v) } }
                SettingSwitch("Fill Screen (Portrait)", userData.settings.fillScreen) { v -> UserStore.shared.updateSettings { it.copy(fillScreen = v) } }
                SettingSwitch("Tinted Crimson Glass", userData.settings.tintedGlass) { v -> UserStore.shared.updateSettings { it.copy(tintedGlass = v) } }
            }

            // Vault, Cloud Sync, License & Security
            SettingsCard("Vault, License & Security", tinted) {
                Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text("Offline Vault Storage", color = Color.White, fontWeight = FontWeight.SemiBold)
                        Text(diskUsage, color = Theme.textSecondary, fontSize = 12.sp)
                    }
                    TextButton(onClick = { OfflineManager.clearAllDownloads() }) { Text("Clear Vault", color = Color(0xFFFF6B6B)) }
                }
                Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text("Feed Rotation History", color = Color.White, fontWeight = FontWeight.SemiBold)
                        Text("${userData.swipedTotal} swipes tracked", color = Theme.textSecondary, fontSize = 12.sp)
                    }
                    TextButton(onClick = { UserStore.shared.clearSeenHistory() }) { Text("Reset Seen", color = Theme.accentBright) }
                }
                HorizontalDivider(color = Theme.borderSubtle)
                Text("License: ${licStatus.licenseKey.ifEmpty { "Not activated" }} · ${LicenseManager.expirySummary}", color = Theme.textSecondary, fontSize = 12.sp)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
                    OutlinedButton(
                        onClick = {
                            val cm = ctx.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                            cm.setPrimaryClip(ClipData.newPlainText("License Key", licStatus.licenseKey))
                            copiedKey = true
                            scope.launch { delay(2000); copiedKey = false }
                        },
                        modifier = Modifier.weight(1f)
                    ) { Text(if (copiedKey) "Copied!" else "Copy Key", color = Color.White, fontSize = 12.sp) }
                    OutlinedButton(
                        onClick = { scope.launch { LicenseManager.verifySilently() } },
                        modifier = Modifier.weight(1f)
                    ) { Text("Refresh", color = Color.White, fontSize = 12.sp) }
                }
                Button(
                    onClick = { scope.launch { syncMsg = "Syncing..."; syncMsg = LicenseManager.syncBidirectionalBackup() } },
                    colors = ButtonDefaults.buttonColors(containerColor = Theme.accent),
                    modifier = Modifier.fillMaxWidth()
                ) { Text("Sync Encrypted Cloud Backup", fontWeight = FontWeight.Bold) }
                syncMsg?.let { Text(it, color = Theme.accentBright, fontSize = 12.sp) }

                HorizontalDivider(color = Theme.borderSubtle)
                SettingSwitch("Require Passcode on Open", requireOnOpen) { v -> AppState.setRequirePasscodeOnOpen(v) }
                if (Biometrics.available(ctx)) {
                    SettingSwitch("Biometric Unlock", userData.settings.faceID) { v ->
                        if (v) {
                            Biometrics.authenticate(activity) { ok ->
                                if (ok) UserStore.shared.updateSettings { it.copy(faceID = true) }
                            }
                        } else {
                            UserStore.shared.updateSettings { it.copy(faceID = false) }
                        }
                    }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
                    OutlinedButton(onClick = { showPasscodeSetup = true }, modifier = Modifier.weight(1f)) {
                        Text(if (hasPasscode) "Change Passcode" else "Set Passcode", color = Color.White, fontSize = 12.sp)
                    }
                    if (hasPasscode) {
                        OutlinedButton(onClick = { AppState.removePasscodeKeepingData() }) {
                            Text("Remove PIN", color = Color(0xFFFF6B6B), fontSize = 12.sp)
                        }
                    }
                }
                Button(
                    onClick = { showWipeSheet = true },
                    colors = ButtonDefaults.buttonColors(containerColor = Color(0xFFB91C1C)),
                    modifier = Modifier.fillMaxWidth()
                ) { Text("Selective Data Wipe", fontWeight = FontWeight.Bold) }
            }
        }
    }

    if (showAlgoEditor) AlgorithmEditorSheet(onDismiss = { showAlgoEditor = false })
    if (showWipeSheet) WipeDataSheet(onDismiss = { showWipeSheet = false })
    if (showPasscodeSetup) PasscodeSetupView(isOnboarding = false, isChanging = hasPasscode, onDone = { showPasscodeSetup = false })
}

@Composable
private fun SettingsCard(title: String, tinted: Boolean, content: @Composable ColumnScope.() -> Unit) {
    Column(
        modifier = Modifier.fillMaxWidth().liquidGlassCard(20.dp, tinted).padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp)
    ) {
        Text(title.uppercase(), color = Theme.accentBright, fontSize = 11.sp, fontWeight = FontWeight.ExtraBold)
        content()
    }
}

@Composable
private fun SettingSwitch(label: String, checked: Boolean, onCheckedChange: (Boolean) -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
        Text(label, color = Color.White, fontSize = 14.sp, modifier = Modifier.weight(1f))
        Switch(
            checked = checked,
            onCheckedChange = onCheckedChange,
            colors = SwitchDefaults.colors(checkedThumbColor = Color.White, checkedTrackColor = Theme.accent)
        )
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun AlgorithmEditorSheet(onDismiss: () -> Unit) {
    val userData by UserStore.shared.data.collectAsState()
    val tasteState by SmartTasteEngine.shared.state.collectAsState()
    val tinted = userData.settings.tintedGlass
    var boostInput by remember { mutableStateOf("") }
    var blockInput by remember { mutableStateOf("") }
    var r34Sug by remember { mutableStateOf<List<Rule34TagSuggestion>>(emptyList()) }

    LaunchedEffect(boostInput) {
        val q = boostInput.trim()
        if (q.length < 2) { r34Sug = emptyList(); return@LaunchedEffect }
        delay(200)
        r34Sug = Rule34API.autocomplete(q).take(5)
    }

    val boosted = userData.algorithm.boostedTags
    val blocked = userData.algorithm.blockedTags
    val learnedTags = UserStore.shared.topAlgorithmTags(10)
    val learnedSubs = UserStore.shared.topAlgorithmSubredditEntries(6)

    Box(
        modifier = Modifier
            .fillMaxSize()
            .liquidGlassBackground(tinted)
            .statusBarsPadding()
            .navigationBarsPadding()
            .padding(18.dp)
    ) {
        Column(modifier = Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(modifier = Modifier.weight(1f)) {
                    Text("Tune Your Algorithm", color = Color.White, fontSize = 20.sp, fontWeight = FontWeight.Bold)
                    Text("Spaces create new #tags · Underscores combine words", color = Theme.textSecondary, fontSize = 11.5.sp)
                }
                IconButton(onClick = onDismiss) { Icon(Icons.Default.Close, contentDescription = "Close", tint = Color.White) }
            }

            // Smart Archetype Guardrails (exact iOS 5 chips!)
            SettingsCard("Smart Archetype Guardrails", tinted) {
                val hideGay = "gay" in blocked || "man" in tasteState.hiddenOFGenders
                val hideYaoi = "yaoi" in blocked
                val boostFemboy = "femboy" in boosted
                val boostTrans = "trans_woman" in boosted
                val boostFuta = "futanari" in boosted
                FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    GuardrailChip("Hide Gay (M/M)", hideGay) {
                        if (hideGay) {
                            UserStore.shared.removeBlockedTag("gay")
                            SmartTasteEngine.shared.unhideOFGender("man")
                        } else {
                            UserStore.shared.addBlockedTags("gay")
                            SmartTasteEngine.shared.hideOFGender("man")
                        }
                    }
                    GuardrailChip("Hide Yaoi / Bara", hideYaoi) {
                        if (hideYaoi) {
                            UserStore.shared.removeBlockedTag("yaoi")
                            UserStore.shared.removeBlockedTag("bara")
                        } else {
                            UserStore.shared.addBlockedTags("yaoi bara")
                        }
                    }
                    GuardrailChip("Boost Femboy", boostFemboy) {
                        if (boostFemboy) UserStore.shared.removeBoostedTag("femboy") else UserStore.shared.addBoostedTags("femboy")
                    }
                    GuardrailChip("Boost Trans Women", boostTrans) {
                        if (boostTrans) UserStore.shared.removeBoostedTag("trans_woman") else UserStore.shared.addBoostedTags("trans_woman")
                    }
                    GuardrailChip("Boost Futanari", boostFuta) {
                        if (boostFuta) UserStore.shared.removeBoostedTag("futanari") else UserStore.shared.addBoostedTags("futanari")
                    }
                }
            }

            // Boosted Tags + Debounced Rule34 Autocomplete
            SettingsCard("Boosted Tags", tinted) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedTextField(
                        value = boostInput,
                        onValueChange = { boostInput = it },
                        placeholder = { Text("Add tags to boost...") },
                        singleLine = true,
                        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                        keyboardActions = KeyboardActions(onDone = { UserStore.shared.addBoostedTags(boostInput); boostInput = "" }),
                        modifier = Modifier.weight(1f)
                    )
                    Button(
                        onClick = { UserStore.shared.addBoostedTags(boostInput); boostInput = "" },
                        colors = ButtonDefaults.buttonColors(containerColor = Theme.accent)
                    ) { Text("Add") }
                }
                if (r34Sug.isNotEmpty()) {
                    FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        r34Sug.forEach { s ->
                            Box(
                                modifier = Modifier
                                    .liquidGlassCapsule(tinted)
                                    .clickable { UserStore.shared.addBoostedTags(s.value); boostInput = "" }
                                    .padding(horizontal = 10.dp, vertical = 5.dp)
                            ) { Text("+ #${s.value}", color = Color(0xFFB0EBA6), fontSize = 11.5.sp) }
                        }
                    }
                }
                FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    boosted.forEach { t ->
                        Box(
                            modifier = Modifier
                                .liquidGlassCapsule(tinted, active = true)
                                .clickable { UserStore.shared.removeBoostedTag(t) }
                                .padding(horizontal = 10.dp, vertical = 5.dp)
                        ) { Text("#$t ×", color = Color.White, fontSize = 12.sp, fontWeight = FontWeight.Bold) }
                    }
                }
            }

            // Blocked Tags & Auto-Suppressed OF Genders
            SettingsCard("Blocked Tags", tinted) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedTextField(
                        value = blockInput,
                        onValueChange = { blockInput = it },
                        placeholder = { Text("Add tags to hide...") },
                        singleLine = true,
                        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                        keyboardActions = KeyboardActions(onDone = { UserStore.shared.addBlockedTags(blockInput); blockInput = "" }),
                        modifier = Modifier.weight(1f)
                    )
                    Button(
                        onClick = { UserStore.shared.addBlockedTags(blockInput); blockInput = "" },
                        colors = ButtonDefaults.buttonColors(containerColor = Color(0xFFB91C1C))
                    ) { Text("Block") }
                }
                val allBlocked = (blocked + tasteState.suppressedTags).distinct()
                FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    allBlocked.forEach { t ->
                        Box(
                            modifier = Modifier
                                .clip(CircleShape)
                                .background(Color(0xFFB91C1C).copy(0.65f))
                                .clickable { UserStore.shared.removeBlockedTag(t) }
                                .padding(horizontal = 10.dp, vertical = 5.dp)
                        ) { Text("#$t ×", color = Color.White, fontSize = 12.sp, fontWeight = FontWeight.Bold) }
                    }
                }
                if (tasteState.hiddenOFGenders.isNotEmpty()) {
                    Text("Hidden OnlyFans Genders (tap to unhide)", color = Theme.textSecondary, fontSize = 11.5.sp)
                    FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        tasteState.hiddenOFGenders.forEach { g ->
                            Box(
                                modifier = Modifier
                                    .liquidGlassCapsule(tinted)
                                    .clickable { SmartTasteEngine.shared.unhideOFGender(g) }
                                    .padding(horizontal = 10.dp, vertical = 5.dp)
                            ) { Text("Hidden: $g ×", color = Color(0xFFFF6B6B), fontSize = 11.5.sp, fontWeight = FontWeight.Bold) }
                        }
                    }
                }
            }

            // Learned Taste Signals (- / + / x controls matching iOS!)
            if (learnedTags.isNotEmpty() || learnedSubs.isNotEmpty()) {
                SettingsCard("Learned Taste Signals", tinted) {
                    learnedTags.forEach { (tag, score) ->
                        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                            Text("#$tag", color = Color.White, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
                            Text(String.format("+%.1f", score), color = Theme.accentBright, fontSize = 12.sp)
                            IconButton(onClick = { UserStore.shared.adjustLearnedTag(tag, -2.0) }, modifier = Modifier.size(30.dp)) {
                                Icon(Icons.Default.Remove, contentDescription = "Less", tint = Color.White, modifier = Modifier.size(16.dp))
                            }
                            IconButton(onClick = { UserStore.shared.adjustLearnedTag(tag, 2.0) }, modifier = Modifier.size(30.dp)) {
                                Icon(Icons.Default.Add, contentDescription = "More", tint = Color.White, modifier = Modifier.size(16.dp))
                            }
                            IconButton(onClick = { UserStore.shared.removeLearnedTag(tag) }, modifier = Modifier.size(30.dp)) {
                                Icon(Icons.Default.Close, contentDescription = "Remove", tint = Theme.textMuted, modifier = Modifier.size(16.dp))
                            }
                        }
                    }
                    if (learnedSubs.isNotEmpty()) {
                        FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                            learnedSubs.forEach { (sub, _) ->
                                Box(
                                    modifier = Modifier
                                        .liquidGlassCapsule(tinted)
                                        .clickable { UserStore.shared.removeLearnedSubreddit(sub) }
                                        .padding(horizontal = 10.dp, vertical = 4.dp)
                                ) { Text("r/$sub ×", color = Theme.textSecondary, fontSize = 11.5.sp) }
                            }
                        }
                    }
                }
            }

            // Quick Picker Tags
            SettingsCard("Quick Picker", tinted) {
                PornTagCatalog.quickPickerCategories.forEach { (catTitle, tags) ->
                    Text(catTitle, color = Theme.textSecondary, fontSize = 11.5.sp, fontWeight = FontWeight.Bold)
                    FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        tags.forEach { t ->
                            val active = t in boosted
                            Box(
                                modifier = Modifier
                                    .liquidGlassCapsule(tinted, active = active)
                                    .clickable {
                                        if (active) UserStore.shared.removeBoostedTag(t)
                                        else UserStore.shared.addBoostedTags(t)
                                    }
                                    .padding(horizontal = 10.dp, vertical = 5.dp)
                            ) { Text("${if (active) "✓" else "+"} #$t", color = Color.White, fontSize = 12.sp) }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun GuardrailChip(label: String, active: Boolean, onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .liquidGlassCapsule(tinted = true, active = active)
            .clickable { onClick() }
            .padding(horizontal = 12.dp, vertical = 7.dp)
    ) {
        Text(label, color = Color.White, fontSize = 12.sp, fontWeight = FontWeight.Bold)
    }
}

@Composable
fun WipeDataSheet(onDismiss: () -> Unit) {
    val userData by UserStore.shared.data.collectAsState()
    val tinted = userData.settings.tintedGlass
    val scope = rememberCoroutineScope()

    var keepLikes by remember { mutableStateOf(true) }
    var keepFollowing by remember { mutableStateOf(true) }
    var keepVault by remember { mutableStateOf(true) }
    var keepAccounts by remember { mutableStateOf(true) }
    var keepAlgo by remember { mutableStateOf(true) }
    var keepPasscode by remember { mutableStateOf(true) }
    var confirmDialog by remember { mutableStateOf(false) }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .liquidGlassBackground(tinted)
            .statusBarsPadding()
            .navigationBarsPadding()
            .padding(20.dp)
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Selective Data Wipe", color = Color.White, fontSize = 20.sp, fontWeight = FontWeight.Bold)
                Spacer(Modifier.weight(1f))
                IconButton(onClick = onDismiss) { Icon(Icons.Default.Close, contentDescription = "Close", tint = Color.White) }
            }
            Text("Toggle OFF anything you want to erase. Items left ON will be kept safe.", color = Theme.textSecondary, fontSize = 12.5.sp)

            Column(modifier = Modifier.fillMaxWidth().liquidGlassCard(20.dp, tinted).padding(14.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                SettingSwitch("Keep Liked Videos (${userData.liked.size})", keepLikes) { keepLikes = it }
                SettingSwitch("Keep Following", keepFollowing) { keepFollowing = it }
                SettingSwitch("Keep Offline Vault (${userData.downloaded.size})", keepVault) { keepVault = it }
                SettingSwitch("Keep Connected Accounts (𝕏 / IG / R34)", keepAccounts) { keepAccounts = it }
                SettingSwitch("Keep Algorithm & Taste", keepAlgo) { keepAlgo = it }
                SettingSwitch("Keep Vault Passcode", keepPasscode) { keepPasscode = it }
            }

            Text(
                "Always clears seen history, feed caches, and temporary media.",
                color = Theme.textMuted,
                fontSize = 11.5.sp
            )

            Button(
                onClick = { confirmDialog = true },
                colors = ButtonDefaults.buttonColors(containerColor = Color(0xFFB91C1C)),
                modifier = Modifier.fillMaxWidth().height(48.dp)
            ) {
                Icon(Icons.Default.DeleteForever, contentDescription = null, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(8.dp))
                Text("Wipe Selected Data", fontWeight = FontWeight.Bold)
            }
        }
    }

    if (confirmDialog) {
        AlertDialog(
            onDismissRequest = { confirmDialog = false },
            title = { Text("Confirm Data Wipe") },
            text = { Text("This cannot be undone for any unchecked items.") },
            confirmButton = {
                TextButton(onClick = {
                    confirmDialog = false
                    scope.launch {
                        UserStore.shared.performSelectiveWipe(
                            UserStore.WipeOptions(
                                keepLikes = keepLikes,
                                keepFollowing = keepFollowing,
                                keepOfflineVault = keepVault,
                                keepAccounts = keepAccounts,
                                keepAlgorithm = keepAlgo,
                                keepPasscode = keepPasscode
                            )
                        )
                        onDismiss()
                    }
                }) { Text("Wipe Now", color = Color(0xFFFF6B6B)) }
            },
            dismissButton = { TextButton(onClick = { confirmDialog = false }) { Text("Cancel") } }
        )
    }
}
