package com.bella.tinytiny

import android.annotation.SuppressLint
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.webkit.CookieManager
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.DeleteForever
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Share
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
import androidx.compose.ui.viewinterop.AndroidView
import coil.compose.AsyncImage
import kotlinx.coroutines.launch

@Composable
fun LikesScreen(
    onOpenList: (String, List<Gif>) -> Unit
) {
    val userData by UserStore.data.collectAsState()
    val likes = userData.likes
    var isSelecting by remember { mutableStateOf(false) }
    var selectedIds by remember { mutableStateOf<Set<String>>(emptySet()) }
    var sharePosts by remember { mutableStateOf<List<Gif>?>(null) }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(AppTheme.bg)
            .padding(top = 56.dp, start = 14.dp, end = 14.dp, bottom = 84.dp)
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
            Text("Liked (${likes.size})", fontSize = 22.sp, fontWeight = FontWeight.Black, color = Color.White)
            Spacer(Modifier.weight(1f))
            if (likes.isNotEmpty()) {
                Text(
                    if (isSelecting) "Cancel" else "Select",
                    color = AppTheme.accentBright,
                    fontWeight = FontWeight.Bold,
                    modifier = Modifier
                        .liquidGlassCapsule()
                        .clickable {
                            isSelecting = !isSelecting
                            if (!isSelecting) selectedIds = emptySet()
                        }
                        .padding(horizontal = 14.dp, vertical = 7.dp)
                )
            }
        }

        if (isSelecting && selectedIds.isNotEmpty()) {
            Spacer(Modifier.height(10.dp))
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .background(AppTheme.brandGradient, RoundedCornerShape(14.dp))
                    .clickable {
                        sharePosts = likes.filter { selectedIds.contains(it.id) }
                    }
                    .padding(vertical = 12.dp),
                horizontalArrangement = Arrangement.Center,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Icon(Icons.Default.Share, contentDescription = null, tint = Color.White, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(8.dp))
                Text("Share Selected (${selectedIds.size})", color = Color.White, fontWeight = FontWeight.Bold)
            }
        }

        Spacer(Modifier.height(12.dp))
        if (likes.isEmpty()) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Text("Double-tap any video to save it here.", color = Color.White.copy(alpha = 0.55f))
            }
        } else {
            LazyVerticalGrid(
                columns = GridCells.Fixed(3),
                verticalArrangement = Arrangement.spacedBy(6.dp),
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                modifier = Modifier.fillMaxSize()
            ) {
                items(likes, key = { it.id }) { gif ->
                    val chosen = selectedIds.contains(gif.id)
                    Box(
                        modifier = Modifier
                            .aspectRatio(0.75f)
                            .clip(RoundedCornerShape(12.dp))
                            .background(AppTheme.surface)
                            .border(
                                if (chosen) 2.dp else 0.dp,
                                if (chosen) AppTheme.accent else Color.Transparent,
                                RoundedCornerShape(12.dp)
                            )
                            .clickable {
                                if (isSelecting) {
                                    selectedIds = if (chosen) selectedIds - gif.id else selectedIds + gif.id
                                } else {
                                    val idx = likes.indexOfFirst { it.id == gif.id }.coerceAtLeast(0)
                                    val rotated = likes.drop(idx) + likes.take(idx)
                                    onOpenList("Liked", rotated)
                                }
                            }
                    ) {
                        AsyncImage(
                            model = gif.posterOrThumb ?: gif.imageURL,
                            contentDescription = gif.title,
                            contentScale = ContentScale.Crop,
                            modifier = Modifier.fillMaxSize()
                        )
                        if (isSelecting) {
                            Icon(
                                Icons.Default.CheckCircle,
                                contentDescription = null,
                                tint = if (chosen) AppTheme.accentBright else Color.White.copy(alpha = 0.4f),
                                modifier = Modifier
                                    .align(Alignment.TopEnd)
                                    .padding(6.dp)
                                    .size(20.dp)
                            )
                        }
                    }
                }
            }
        }
    }

    if (sharePosts != null) {
        ShareDropDialog(
            posts = sharePosts!!,
            onDismiss = {
                sharePosts = null
                isSelecting = false
                selectedIds = emptySet()
            }
        )
    }
}

@Composable
fun BrowseScreen(
    onSelectSource: (FeedSource) -> Unit
) {
    var query by remember { mutableStateOf("") }
    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(AppTheme.bg)
            .verticalScroll(rememberScrollState())
            .padding(top = 56.dp, start = 16.dp, end = 16.dp, bottom = 96.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp)
    ) {
        Text("Browse & Search", fontSize = 24.sp, fontWeight = FontWeight.Black, color = Color.White)

        OutlinedTextField(
            value = query,
            onValueChange = { query = it },
            placeholder = { Text("Search across All channels...", color = Color.White.copy(alpha = 0.45f)) },
            trailingIcon = {
                IconButton(onClick = {
                    val q = query.trim()
                    if (q.isNotEmpty()) onSelectSource(FeedSource.MultiSearch(q))
                }) {
                    Icon(Icons.Default.Search, contentDescription = "Search", tint = AppTheme.accentBright)
                }
            },
            singleLine = true,
            modifier = Modifier.fillMaxWidth(),
            shape = RoundedCornerShape(16.dp),
            colors = OutlinedTextFieldDefaults.colors(
                focusedTextColor = Color.White,
                unfocusedTextColor = Color.White,
                focusedBorderColor = AppTheme.accent,
                unfocusedBorderColor = Color.White.copy(alpha = 0.2f)
            )
        )

        val quickSources = listOf(
            "For You (Balanced)" to FeedSource.ForYou,
            "OnlyFans · For You" to FeedSource.OFForYou,
            "OnlyFans · Trending" to FeedSource.OFTrending,
            "OnlyFans · Latest" to FeedSource.OFLatest,
            "OnlyFans · DMs" to FeedSource.OFDMs,
            "Rule34 Feed" to FeedSource.Rule34(""),
            "Long Videos · All" to FeedSource.LongVideos(LongVideoSite.ALL),
            "Long Videos · Eporner" to FeedSource.LongVideos(LongVideoSite.EPORNER),
            "Long Videos · XVideos" to FeedSource.LongVideos(LongVideoSite.XVIDEOS),
            "Long Videos · Pornhub" to FeedSource.LongVideos(LongVideoSite.PORNHUB)
        )

        quickSources.forEach { (label, src) ->
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .liquidGlassCard(14.dp)
                    .clickable { onSelectSource(src) }
                    .padding(horizontal = 16.dp, vertical = 14.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(label, color = Color.White, fontWeight = FontWeight.SemiBold, fontSize = 15.sp)
            }
        }
    }
}

@Composable
fun SettingsModal(
    onDismiss: () -> Unit,
    onOpenReceiveDrop: () -> Unit
) {
    val userData by UserStore.data.collectAsState()
    val tasteState by SmartTasteEngine.state.collectAsState()
    var showXLogin by remember { mutableStateOf(false) }
    var showIGLogin by remember { mutableStateOf(false) }
    var boostedInput by remember { mutableStateOf("") }
    var blockedInput by remember { mutableStateOf("") }
    var confirmReset by remember { mutableStateOf(false) }
    var requireLock by remember { mutableStateOf(AppState.requirePasscodeOnOpen.value) }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(AppTheme.bg.copy(alpha = 0.96f))
            .padding(top = 42.dp, start = 18.dp, end = 18.dp, bottom = 24.dp)
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(14.dp)
        ) {
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                Text("Settings", fontSize = 24.sp, fontWeight = FontWeight.Black, color = Color.White)
                Spacer(Modifier.weight(1f))
                IconButton(onClick = onDismiss) {
                    Icon(Icons.Default.Close, contentDescription = "Close", tint = Color.White)
                }
            }

            // Playback
            Column(modifier = Modifier.fillMaxWidth().liquidGlassCard(18.dp).padding(14.dp)) {
                Text("Playback", fontWeight = FontWeight.Bold, color = AppTheme.accentBright, fontSize = 13.sp)
                SettingSwitch("HD Video", userData.settings.hd) { v -> UserStore.updateSettings { it.copy(hd = v) } }
                SettingSwitch("Mute Audio", userData.settings.muted) { v -> UserStore.updateSettings { it.copy(muted = v) } }
                SettingSwitch("Auto-Scroll Reels", userData.settings.autoScroll) { v -> UserStore.updateSettings { it.copy(autoScroll = v) } }
                SettingSwitch("Smart Algorithm", userData.settings.algorithmEnabled) { v -> UserStore.updateSettings { it.copy(algorithmEnabled = v) } }
                if (AppState.hasPasscode) {
                    SettingSwitch("Lock on Open", requireLock) { v ->
                        requireLock = v
                        AppState.setRequirePasscodeOnOpen(v)
                    }
                }
            }

            // Smart Archetype Guardrails
            Column(modifier = Modifier.fillMaxWidth().liquidGlassCard(18.dp).padding(14.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("Smart Archetype Guardrails", fontWeight = FontWeight.Bold, color = AppTheme.accentBright, fontSize = 13.sp)
                Text("Block masc M/M without touching femboy/trans/futa, or vice versa.", fontSize = 12.sp, color = Color.White.copy(alpha = 0.65f))
                val guardrails = listOf("gay", "yaoi", "femboy", "trans_woman", "futanari")
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
                    guardrails.take(3).forEach { g ->
                        val isBlocked = tasteState.suppressedTags.contains(g)
                        Text(
                            if (isBlocked) "Blocked #$g" else "#$g",
                            fontSize = 11.5.sp,
                            fontWeight = FontWeight.Bold,
                            color = Color.White,
                            modifier = Modifier
                                .liquidGlassCapsule(active = isBlocked)
                                .clickable { SmartTasteEngine.toggleArchetypeGuardrail(g, !isBlocked) }
                                .padding(horizontal = 10.dp, vertical = 6.dp)
                        )
                    }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    guardrails.drop(3).forEach { g ->
                        val isBlocked = tasteState.suppressedTags.contains(g)
                        Text(
                            if (isBlocked) "Blocked #$g" else "#$g",
                            fontSize = 11.5.sp,
                            fontWeight = FontWeight.Bold,
                            color = Color.White,
                            modifier = Modifier
                                .liquidGlassCapsule(active = isBlocked)
                                .clickable { SmartTasteEngine.toggleArchetypeGuardrail(g, !isBlocked) }
                                .padding(horizontal = 10.dp, vertical = 6.dp)
                        )
                    }
                }

                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedTextField(
                        value = boostedInput,
                        onValueChange = { boostedInput = it },
                        placeholder = { Text("Boost tag (e.g. goth)", fontSize = 12.sp) },
                        singleLine = true,
                        modifier = Modifier.weight(1f)
                    )
                    Button(onClick = {
                        val t = boostedInput.trim().lowercase()
                        if (t.isNotEmpty()) {
                            UserStore.updateAlgorithm { it.copy(boostedTags = (it.boostedTags + t).distinct()) }
                            boostedInput = ""
                        }
                    }) { Text("Boost") }
                }

                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedTextField(
                        value = blockedInput,
                        onValueChange = { blockedInput = it },
                        placeholder = { Text("Block tag", fontSize = 12.sp) },
                        singleLine = true,
                        modifier = Modifier.weight(1f)
                    )
                    Button(onClick = {
                        val t = blockedInput.trim().lowercase()
                        if (t.isNotEmpty()) {
                            UserStore.updateAlgorithm { it.copy(blockedTags = (it.blockedTags + t).distinct()) }
                            blockedInput = ""
                        }
                    }) { Text("Block") }
                }
            }

            // Accounts & Drops
            Column(modifier = Modifier.fillMaxWidth().liquidGlassCard(18.dp).padding(14.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text("Accounts & Drops", fontWeight = FontWeight.Bold, color = AppTheme.accentBright, fontSize = 13.sp)
                Button(onClick = { showXLogin = true }, modifier = Modifier.fillMaxWidth()) {
                    Text(if (userData.xSession.isConnected) "𝕏 Connected (Tap to Reconnect)" else "Connect 𝕏 Account")
                }
                Button(onClick = { showIGLogin = true }, modifier = Modifier.fillMaxWidth()) {
                    Text(if (userData.igSession.isConnected) "Instagram Connected (Tap to Reconnect)" else "Connect Instagram Account")
                }
                Button(onClick = onOpenReceiveDrop, modifier = Modifier.fillMaxWidth()) {
                    Text("Open tinytiny://drop/ Link or Code")
                }
            }

            // Danger Zone
            Button(
                onClick = { confirmReset = true },
                colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF8B1E2B)),
                modifier = Modifier.fillMaxWidth()
            ) {
                Icon(Icons.Default.DeleteForever, contentDescription = null)
                Spacer(Modifier.width(8.dp))
                Text("Reset App & Log Out License", fontWeight = FontWeight.Bold)
            }
        }
    }

    if (confirmReset) {
        AlertDialog(
            onDismissRequest = { confirmReset = false },
            confirmButton = {
                TextButton(onClick = {
                    confirmReset = false
                    AppState.eraseEverything()
                    onDismiss()
                }) { Text("Erase & Reset", color = Color.Red) }
            },
            dismissButton = { TextButton(onClick = { confirmReset = false }) { Text("Cancel") } },
            title = { Text("Reset Everything?") },
            text = { Text("Clears likes, history, sessions, passcode, and logs out your license key.") }
        )
    }

    if (showXLogin) {
        WebCookieLoginDialog(
            title = "Sign in to 𝕏",
            startUrl = "https://x.com/i/flow/login",
            cookieDomain = "https://x.com",
            onDismiss = { showXLogin = false },
            onCookiesCaptured = { map ->
                val auth = map["auth_token"]
                val ct0 = map["ct0"]
                if (!auth.isNullOrBlank() && !ct0.isNullOrBlank()) {
                    UserStore.setXSession(XSession(authToken = auth, ct0 = ct0))
                    showXLogin = false
                }
            }
        )
    }

    if (showIGLogin) {
        WebCookieLoginDialog(
            title = "Sign in to Instagram",
            startUrl = "https://www.instagram.com/accounts/login/",
            cookieDomain = "https://www.instagram.com",
            onDismiss = { showIGLogin = false },
            onCookiesCaptured = { map ->
                val sid = map["sessionid"]
                val uid = map["ds_user_id"]
                val csrf = map["csrftoken"].orEmpty()
                if (!sid.isNullOrBlank() && !uid.isNullOrBlank()) {
                    UserStore.setIGSession(IGSession(sessionId = sid, csrfToken = csrf, dsUserId = uid))
                    showIGLogin = false
                }
            }
        )
    }
}

@Composable
private fun SettingSwitch(label: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
        Text(label, color = Color.White, modifier = Modifier.weight(1f))
        Switch(checked = checked, onCheckedChange = onChange)
    }
}

@SuppressLint("SetJavaScriptEnabled")
@Composable
fun WebCookieLoginDialog(
    title: String,
    startUrl: String,
    cookieDomain: String,
    onDismiss: () -> Unit,
    onCookiesCaptured: (Map<String, String>) -> Unit
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        confirmButton = { TextButton(onClick = onDismiss) { Text("Close") } },
        title = { Text(title) },
        text = {
            Box(modifier = Modifier.fillMaxWidth().height(420.dp)) {
                AndroidView(
                    factory = { ctx ->
                        WebView(ctx).apply {
                            settings.javaScriptEnabled = true
                            settings.domStorageEnabled = true
                            CookieManager.getInstance().setAcceptCookie(true)
                            webViewClient = object : WebViewClient() {
                                override fun onPageFinished(view: WebView?, url: String?) {
                                    val raw = CookieManager.getInstance().getCookie(cookieDomain).orEmpty()
                                    val map = raw.split(";").mapNotNull { part ->
                                        val kv = part.trim().split("=", limit = 2)
                                        if (kv.size == 2) kv[0] to kv[1] else null
                                    }.toMap()
                                    onCookiesCaptured(map)
                                }
                            }
                            loadUrl(startUrl)
                        }
                    },
                    modifier = Modifier.fillMaxSize()
                )
            }
        }
    )
}

@Composable
fun ShareDropDialog(
    posts: List<Gif>,
    onDismiss: () -> Unit
) {
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    var link by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }

    LaunchedEffect(posts) {
        busy = true
        val res = if (posts.size == 1) {
            ShareService.createEncryptedShareLink(posts.first())
        } else {
            ShareService.createEncryptedCollectionShareLink(posts)
        }
        link = res?.first
        busy = false
    }

    AlertDialog(
        onDismissRequest = onDismiss,
        confirmButton = { TextButton(onClick = onDismiss) { Text("Done") } },
        title = { Text(if (posts.size == 1) "Encrypted Drop" else "Share ${posts.size} Videos") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                if (busy) {
                    CircularProgressIndicator()
                } else if (link != null) {
                    Text(link!!, fontSize = 12.sp, maxLines = 3, overflow = TextOverflow.Ellipsis)
                    Button(onClick = {
                        val cm = ctx.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                        cm.setPrimaryClip(ClipData.newPlainText("tinytiny drop", link))
                    }) {
                        Icon(Icons.Default.ContentCopy, contentDescription = null)
                        Spacer(Modifier.width(6.dp))
                        Text("Copy tinytiny://drop/ Link")
                    }
                } else {
                    Text("Could not create drop link.")
                }
            }
        }
    )
}

@Composable
fun ReceiveDropDialog(
    onDismiss: () -> Unit
) {
    var input by remember { mutableStateOf("") }
    var err by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()

    AlertDialog(
        onDismissRequest = onDismiss,
        confirmButton = {
            TextButton(
                enabled = !busy && input.isNotBlank(),
                onClick = {
                    scope.launch {
                        busy = true
                        err = ShareService.handleIncomingShare(input)
                        busy = false
                        if (err == null) onDismiss()
                    }
                }
            ) { Text("Decrypt & Open") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
        title = { Text("Open tinytiny://drop/") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(
                    value = input,
                    onValueChange = { input = it },
                    placeholder = { Text("Paste tinytiny://drop/... or TTDROP:...") },
                    maxLines = 3
                )
                if (!err.isNullOrBlank()) {
                    Text(err!!, color = Color.Red, fontSize = 12.sp)
                }
            }
        }
    )
}
