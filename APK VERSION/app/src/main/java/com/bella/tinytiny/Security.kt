package com.bella.tinytiny

import android.content.Context
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.scaleIn
import androidx.compose.animation.slideInVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.automirrored.filled.Backspace
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Key
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Psychology
import androidx.compose.material.icons.filled.Share
import androidx.compose.material.icons.filled.TouchApp
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import java.security.MessageDigest

object AppState {
    private const val PREFS = "tinytiny_app_state"
    private lateinit var ctx: Context

    private val _ageConfirmed = MutableStateFlow(false)
    val ageConfirmed = _ageConfirmed.asStateFlow()

    private val _onboardingCompleted = MutableStateFlow(false)
    val onboardingCompleted = _onboardingCompleted.asStateFlow()

    private val _licenseActivated = MutableStateFlow(false)
    val licenseActivated = _licenseActivated.asStateFlow()

    private val _passcodeChoiceCompleted = MutableStateFlow(false)
    val passcodeChoiceCompleted = _passcodeChoiceCompleted.asStateFlow()

    private val _requirePasscodeOnOpen = MutableStateFlow(false)
    val requirePasscodeOnOpen = _requirePasscodeOnOpen.asStateFlow()

    private val _isLocked = MutableStateFlow(false)
    val isLocked = _isLocked.asStateFlow()

    private var passcodeHash: String? = null

    fun init(context: Context) {
        ctx = context.applicationContext
        val p = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        passcodeHash = p.getString("passcode_hash", null)
        _ageConfirmed.value = p.getBoolean("ageConfirmed", false)
        _licenseActivated.value = LicenseManager.isValidAccess
        _onboardingCompleted.value = p.getBoolean("onboardingCompleted", false) || _licenseActivated.value
        _passcodeChoiceCompleted.value = p.getBoolean("passcodeChoiceCompleted", false) || passcodeHash != null
        _requirePasscodeOnOpen.value = p.getBoolean("requirePasscodeOnOpen", false)
        _isLocked.value = passcodeHash != null && _requirePasscodeOnOpen.value
    }

    private fun saveBool(k: String, v: Boolean) {
        if (::ctx.isInitialized) ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putBoolean(k, v).apply()
    }

    fun confirmAge() {
        _ageConfirmed.value = true
        saveBool("ageConfirmed", true)
    }

    fun completeOnboarding() {
        _onboardingCompleted.value = true
        saveBool("onboardingCompleted", true)
    }

    fun setLicenseActivated(active: Boolean) {
        _licenseActivated.value = active
    }

    fun setPasscode(pin: String) {
        val hash = sha256("tt.v1.$pin")
        passcodeHash = hash
        if (::ctx.isInitialized) {
            ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
                .putString("passcode_hash", hash)
                .putBoolean("passcodeChoiceCompleted", true)
                .apply()
        }
        _passcodeChoiceCompleted.value = true
        _isLocked.value = false
    }

    fun skipPasscode() {
        passcodeHash = null
        if (::ctx.isInitialized) {
            ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
                .remove("passcode_hash")
                .putBoolean("passcodeChoiceCompleted", true)
                .apply()
        }
        _passcodeChoiceCompleted.value = true
        _isLocked.value = false
    }

    fun verifyPasscode(pin: String): Boolean = passcodeHash == sha256("tt.v1.$pin")

    fun unlock() { _isLocked.value = false }

    fun setRequirePasscodeOnOpen(req: Boolean) {
        _requirePasscodeOnOpen.value = req
        saveBool("requirePasscodeOnOpen", req)
    }

    val hasPasscode: Boolean get() = passcodeHash != null

    fun eraseEverything() {
        passcodeHash = null
        UserStore.eraseAll()
        LicenseManager.clearLicense()
        if (::ctx.isInitialized) ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().clear().apply()
        _licenseActivated.value = false
        _ageConfirmed.value = false
        _onboardingCompleted.value = false
        _passcodeChoiceCompleted.value = false
        _requirePasscodeOnOpen.value = false
        _isLocked.value = false
    }

    private fun sha256(input: String): String {
        val bytes = MessageDigest.getInstance("SHA-256").digest(input.toByteArray())
        return bytes.joinToString("") { "%02x".format(it) }
    }
}

@Composable
fun AgeGateScreen(onConfirm: () -> Unit) {
    var showUnder by remember { mutableStateOf(false) }
    var visible by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { visible = true }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(AppTheme.bg)
    ) {
        Box(
            modifier = Modifier
                .size(300.dp)
                .align(Alignment.Center)
                .offset(y = (-80).dp)
                .blur(70.dp)
                .background(
                    Brush.radialGradient(
                        listOf(AppTheme.accent.copy(alpha = 0.25f), Color.Transparent)
                    ),
                    CircleShape
                )
        )

        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(horizontal = 24.dp, vertical = 20.dp),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            Spacer(Modifier.weight(1f))

            AnimatedVisibility(
                visible = visible,
                enter = fadeIn(tween(450)) + scaleIn(spring(dampingRatio = 0.78f), initialScale = 0.78f)
            ) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Box(
                        modifier = Modifier
                            .size(92.dp)
                            .clip(CircleShape)
                            .background(Color.White.copy(alpha = 0.08f))
                            .border(1.2.dp, AppTheme.ringGradient, CircleShape),
                        contentAlignment = Alignment.Center
                    ) {
                        Text(
                            "18+",
                            fontSize = 32.sp,
                            fontWeight = FontWeight.Black,
                            color = Color.White
                        )
                    }
                    Spacer(Modifier.height(22.dp))
                    Text(
                        "18+ Only",
                        fontSize = 30.sp,
                        fontWeight = FontWeight.Black,
                        color = Color.White
                    )
                    Spacer(Modifier.height(10.dp))
                    Text(
                        "Everything inside is explicit.\nConfirm you're of legal age to enter.",
                        fontSize = 15.sp,
                        color = Color.White.copy(alpha = 0.65f),
                        textAlign = TextAlign.Center,
                        lineHeight = 21.sp
                    )
                }
            }

            Spacer(Modifier.weight(1f))

            Button(
                onClick = onConfirm,
                modifier = Modifier
                    .fillMaxWidth()
                    .height(54.dp),
                shape = CircleShape,
                colors = ButtonDefaults.buttonColors(containerColor = Color.Transparent),
                contentPadding = PaddingValues()
            ) {
                Box(
                    modifier = Modifier
                        .fillMaxSize()
                        .background(AppTheme.brandGradient, CircleShape)
                        .border(0.8.dp, Color.White.copy(alpha = 0.28f), CircleShape),
                    contentAlignment = Alignment.Center
                ) {
                    Text("I'm 18 or older", fontSize = 16.sp, fontWeight = FontWeight.Bold, color = Color.White)
                }
            }

            Spacer(Modifier.height(12.dp))
            TextButton(onClick = { showUnder = true }) {
                Text("I'm under 18", fontSize = 14.sp, color = Color.White.copy(alpha = 0.42f))
            }
            Text(
                "by bella",
                fontSize = 12.sp,
                fontStyle = FontStyle.Italic,
                fontFamily = FontFamily.Serif,
                color = Color.White.copy(alpha = 0.24f)
            )
            Spacer(Modifier.height(8.dp))
        }
    }

    if (showUnder) {
        AlertDialog(
            onDismissRequest = { showUnder = false },
            confirmButton = { TextButton(onClick = { showUnder = false }) { Text("OK") } },
            title = { Text("Access Restricted") },
            text = { Text("You must be at least 18 years old to use Gooned.") }
        )
    }
}

@Composable
fun WelcomeOnboardingScreen(onContinue: () -> Unit) {
    val pagerState = rememberPagerState(pageCount = { 4 })
    val scope = rememberCoroutineScope()
    val inf = rememberInfiniteTransition(label = "aura")
    val pulse by inf.animateFloat(
        initialValue = 0.94f,
        targetValue = 1.08f,
        animationSpec = infiniteRepeatable(tween(1800, easing = FastOutSlowInEasing), RepeatMode.Reverse),
        label = "pulse"
    )

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(AppTheme.bg)
    ) {
        Box(
            modifier = Modifier
                .size(340.dp)
                .offset(x = (-40).dp, y = (-120).dp)
                .scale(pulse)
                .blur(80.dp)
                .background(AppTheme.accent.copy(alpha = 0.24f), CircleShape)
        )
        Box(
            modifier = Modifier
                .size(300.dp)
                .align(Alignment.BottomEnd)
                .offset(x = 50.dp, y = 100.dp)
                .scale(pulse)
                .blur(75.dp)
                .background(AppTheme.purple.copy(alpha = 0.22f), CircleShape)
        )

        Column(modifier = Modifier.fillMaxSize()) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 24.dp, vertical = 18.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    repeat(4) { idx ->
                        val active = pagerState.currentPage == idx
                        Box(
                            modifier = Modifier
                                .width(if (active) 24.dp else 7.dp)
                                .height(7.dp)
                                .clip(CircleShape)
                                .background(if (active) Color.White else Color.White.copy(alpha = 0.24f))
                        )
                    }
                }
                Spacer(Modifier.weight(1f))
                if (pagerState.currentPage < 3) {
                    Text(
                        "Skip",
                        fontSize = 14.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = Color.White.copy(alpha = 0.65f),
                        modifier = Modifier.clickable { onContinue() }
                    )
                }
            }

            HorizontalPager(
                state = pagerState,
                modifier = Modifier.weight(1f)
            ) { page ->
                when (page) {
                    0 -> OnboardingHeroPage(pulse) { scope.launch { pagerState.animateScrollToPage(1) } }
                    1 -> OnboardingCardsPage(
                        title = "All you need",
                        subtitle = "to goon your brains out",
                        cards = listOf(
                            Triple(Icons.Default.AutoAwesome, "6 Sites, 1 Spot", "X, Instagram, OnlyFans, Reddit, Rule34, and Long Videos — all right here."),
                            Triple(Icons.Default.Psychology, "Learns Your Type", "Picks up on what you actually like, even on untagged videos, without mixing up your niches."),
                            Triple(Icons.Default.Share, "Send Drops Privately", "Select a bunch of liked vids and send an encrypted tinytiny://drop/ link.")
                        ),
                        cta = "How it works",
                        onNext = { scope.launch { pagerState.animateScrollToPage(2) } }
                    )
                    2 -> OnboardingCardsPage(
                        title = "Quick rundown",
                        subtitle = "Everything lives in the Gear menu",
                        cards = listOf(
                            Triple(Icons.Default.TouchApp, "Tap & Hold", "Double-tap to like, hold + pull down to lock 2x speed, or hit Full Wide to flip sideways."),
                            Triple(Icons.Default.Tune, "Tune Your Feed", "Open Gear -> Smart Algorithm to boost tags, block stuff you hate, or lock guardrails."),
                            Triple(Icons.Default.Lock, "Accounts & Lock", "Sign into X/IG, turn on Auto-Scroll, or set a 4-digit passcode whenever you want.")
                        ),
                        cta = "Almost done",
                        onNext = { scope.launch { pagerState.animateScrollToPage(3) } }
                    )
                    else -> OnboardingReadyPage(onContinue)
                }
            }
        }
    }
}

@Composable
private fun OnboardingHeroPage(pulse: Float, onNext: () -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(horizontal = 24.dp),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Spacer(Modifier.weight(1f))
        Box(
            modifier = Modifier
                .size(116.dp)
                .scale(pulse)
                .border(2.dp, AppTheme.ringGradient, CircleShape),
            contentAlignment = Alignment.Center
        ) {
            Box(
                modifier = Modifier
                    .size(92.dp)
                    .clip(CircleShape)
                    .background(Color.White.copy(alpha = 0.08f)),
                contentAlignment = Alignment.Center
            ) {
                Icon(Icons.Default.AutoAwesome, contentDescription = null, tint = AppTheme.accentBright, modifier = Modifier.size(36.dp))
            }
        }
        Spacer(Modifier.height(24.dp))
        Text("Welcome to Gooned", fontSize = 33.sp, fontWeight = FontWeight.Black, color = Color.White, textAlign = TextAlign.Center)
        Spacer(Modifier.height(8.dp))
        Text(
            "by bella",
            fontSize = 15.sp,
            fontStyle = FontStyle.Italic,
            fontFamily = FontFamily.Serif,
            color = Color.White.copy(alpha = 0.36f)
        )
        Spacer(Modifier.height(14.dp))
        Text(
            "Every feed you actually want, all in one fast private app.",
            fontSize = 15.sp,
            color = Color.White.copy(alpha = 0.68f),
            textAlign = TextAlign.Center
        )
        Spacer(Modifier.weight(1f))
        Row(
            modifier = Modifier
                .liquidGlassCapsule()
                .clickable { onNext() }
                .padding(horizontal = 22.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text("Swipe to see what's inside", fontSize = 15.sp, fontWeight = FontWeight.Bold, color = Color.White)
            Spacer(Modifier.width(8.dp))
            Icon(Icons.AutoMirrored.Filled.ArrowForward, contentDescription = null, tint = Color.White, modifier = Modifier.size(16.dp))
        }
        Spacer(Modifier.height(34.dp))
    }
}

@Composable
private fun OnboardingCardsPage(
    title: String,
    subtitle: String,
    cards: List<Triple<ImageVector, String, String>>,
    cta: String,
    onNext: () -> Unit
) {
    var revealed by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) {
        delay(60)
        revealed = true
    }
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(horizontal = 22.dp),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Spacer(Modifier.weight(1f))
        Text(title, fontSize = 28.sp, fontWeight = FontWeight.ExtraBold, color = Color.White)
        Spacer(Modifier.height(4.dp))
        Text(subtitle, fontSize = 15.sp, color = Color.White.copy(alpha = 0.68f))
        Spacer(Modifier.height(20.dp))

        cards.forEachIndexed { idx, (icon, cardTitle, detail) ->
            AnimatedVisibility(
                visible = revealed,
                enter = fadeIn(tween(350, delayMillis = idx * 90)) + slideInVertically(tween(380, delayMillis = idx * 90)) { it / 2 }
            ) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(vertical = 6.dp)
                        .liquidGlassCard(18.dp)
                        .padding(14.dp),
                    verticalAlignment = Alignment.Top
                ) {
                    Box(
                        modifier = Modifier
                            .size(40.dp)
                            .clip(RoundedCornerShape(12.dp))
                            .background(AppTheme.accent.copy(alpha = 0.2f)),
                        contentAlignment = Alignment.Center
                    ) {
                        Icon(icon, contentDescription = null, tint = AppTheme.accentBright, modifier = Modifier.size(20.dp))
                    }
                    Spacer(Modifier.width(12.dp))
                    Column {
                        Text(cardTitle, fontSize = 15.5.sp, fontWeight = FontWeight.Bold, color = Color.White)
                        Spacer(Modifier.height(2.dp))
                        Text(detail, fontSize = 13.sp, color = Color.White.copy(alpha = 0.70f), lineHeight = 18.sp)
                    }
                }
            }
        }

        Spacer(Modifier.weight(1f))
        Button(
            onClick = onNext,
            modifier = Modifier
                .fillMaxWidth()
                .height(52.dp),
            shape = RoundedCornerShape(16.dp),
            colors = ButtonDefaults.buttonColors(containerColor = Color.Transparent),
            contentPadding = PaddingValues()
        ) {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(AppTheme.brandGradient, RoundedCornerShape(16.dp)),
                contentAlignment = Alignment.Center
            ) {
                Text(cta, fontSize = 15.5.sp, fontWeight = FontWeight.Bold, color = Color.White)
            }
        }
        Spacer(Modifier.height(28.dp))
    }
}

@Composable
private fun OnboardingReadyPage(onContinue: () -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(horizontal = 24.dp),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Spacer(Modifier.weight(1f))
        Box(
            modifier = Modifier
                .size(84.dp)
                .clip(CircleShape)
                .background(Color.White.copy(alpha = 0.08f))
                .border(1.dp, Color.White.copy(alpha = 0.28f), CircleShape),
            contentAlignment = Alignment.Center
        ) {
            Icon(Icons.Default.CheckCircle, contentDescription = null, tint = AppTheme.accentBright, modifier = Modifier.size(36.dp))
        }
        Spacer(Modifier.height(22.dp))
        Text("One last thing", fontSize = 30.sp, fontWeight = FontWeight.Black, color = Color.White)
        Spacer(Modifier.height(8.dp))
        Text(
            "Drop in your license key, set a passcode if you want one, and you're in.",
            fontSize = 15.sp,
            color = Color.White.copy(alpha = 0.75f),
            textAlign = TextAlign.Center
        )
        Spacer(Modifier.weight(1f))
        Button(
            onClick = onContinue,
            modifier = Modifier
                .fillMaxWidth()
                .height(54.dp),
            shape = RoundedCornerShape(16.dp),
            colors = ButtonDefaults.buttonColors(containerColor = Color.Transparent),
            contentPadding = PaddingValues()
        ) {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(AppTheme.brandGradient, RoundedCornerShape(16.dp)),
                contentAlignment = Alignment.Center
            ) {
                Text("Enter License Key", fontSize = 16.5.sp, fontWeight = FontWeight.Bold, color = Color.White)
            }
        }
        Spacer(Modifier.height(30.dp))
    }
}

@Composable
fun LicenseGateScreen(onActivated: () -> Unit) {
    var keyInput by remember { mutableStateOf("") }
    val isChecking by LicenseManager.isChecking.collectAsState()
    val errorMsg by LicenseManager.errorMessage.collectAsState()
    val scope = rememberCoroutineScope()

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(AppTheme.bg)
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(24.dp),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            Spacer(Modifier.weight(1f))
            Box(
                modifier = Modifier
                    .size(72.dp)
                    .clip(CircleShape)
                    .background(Color.White.copy(alpha = 0.08f))
                    .border(1.dp, Color.White.copy(alpha = 0.3f), CircleShape),
                contentAlignment = Alignment.Center
            ) {
                Icon(Icons.Default.Key, contentDescription = null, tint = Color.White, modifier = Modifier.size(28.dp))
            }
            Spacer(Modifier.height(18.dp))
            Text("Activate Access", fontSize = 24.sp, fontWeight = FontWeight.Bold, color = Color.White)
            Spacer(Modifier.height(6.dp))
            Text(
                "Enter your license key to unlock & sync your vault.",
                fontSize = 14.sp,
                color = Color.White.copy(alpha = 0.68f),
                textAlign = TextAlign.Center
            )
            Spacer(Modifier.height(22.dp))

            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .liquidGlassCard(22.dp)
                    .padding(18.dp),
                horizontalAlignment = Alignment.CenterHorizontally
            ) {
                OutlinedTextField(
                    value = keyInput,
                    onValueChange = { keyInput = it.uppercase() },
                    placeholder = { Text("TT-XXXX-XXXX-XXXX", color = Color.White.copy(alpha = 0.35f)) },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Characters),
                    modifier = Modifier.fillMaxWidth(),
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedTextColor = Color.White,
                        unfocusedTextColor = Color.White,
                        focusedBorderColor = Color.White.copy(alpha = 0.45f),
                        unfocusedBorderColor = Color.White.copy(alpha = 0.2f)
                    ),
                    shape = RoundedCornerShape(14.dp)
                )

                if (!errorMsg.isNullOrBlank()) {
                    Spacer(Modifier.height(8.dp))
                    Text(errorMsg!!, fontSize = 12.5.sp, color = Color(0xFFFF6B6B), fontWeight = FontWeight.SemiBold)
                }

                Spacer(Modifier.height(14.dp))
                Button(
                    onClick = {
                        scope.launch {
                            if (LicenseManager.activate(keyInput)) {
                                onActivated()
                            }
                        }
                    },
                    enabled = !isChecking && keyInput.isNotBlank(),
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(48.dp),
                    shape = CircleShape,
                    colors = ButtonDefaults.buttonColors(containerColor = Color.Transparent),
                    contentPadding = PaddingValues()
                ) {
                    Box(
                        modifier = Modifier
                            .fillMaxSize()
                            .liquidGlassCapsule(active = keyInput.isNotBlank()),
                        contentAlignment = Alignment.Center
                    ) {
                        if (isChecking) {
                            CircularProgressIndicator(modifier = Modifier.size(20.dp), color = Color.White, strokeWidth = 2.dp)
                        } else {
                            Text("Activate License Key", fontSize = 15.5.sp, fontWeight = FontWeight.Bold, color = Color.White)
                        }
                    }
                }
            }
            Spacer(Modifier.weight(1f))
        }
    }
}

@Composable
fun PasscodeScreen(
    isSetup: Boolean,
    onDone: () -> Unit
) {
    var first by remember { mutableStateOf("") }
    var code by remember { mutableStateOf("") }
    var confirming by remember { mutableStateOf(false) }
    var message by remember { mutableStateOf<String?>(null) }

    val title = when {
        !isSetup -> "Enter Passcode"
        confirming -> "Confirm Passcode"
        else -> "Create 4-Digit Passcode"
    }
    val subtitle = message ?: if (isSetup && !confirming) "Optional — skip below to stay unlocked" else null

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(AppTheme.bg)
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(horizontal = 24.dp),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            Spacer(Modifier.weight(1f))
            if (isSetup) {
                Text(
                    if (confirming) "CONFIRM LOCK" else "OPTIONAL LOCK",
                    fontSize = 11.sp,
                    fontWeight = FontWeight.Bold,
                    letterSpacing = 1.5.sp,
                    color = Color.White.copy(alpha = 0.7f),
                    modifier = Modifier
                        .liquidGlassCapsule()
                        .padding(horizontal = 12.dp, vertical = 5.dp)
                )
                Spacer(Modifier.height(14.dp))
            }

            Box(
                modifier = Modifier
                    .size(56.dp)
                    .liquidGlassCircle(),
                contentAlignment = Alignment.Center
            ) {
                Icon(Icons.Default.Lock, contentDescription = null, tint = AppTheme.accentBright)
            }
            Spacer(Modifier.height(14.dp))
            Text(title, fontSize = 23.sp, fontWeight = FontWeight.Bold, color = Color.White)
            if (subtitle != null) {
                Spacer(Modifier.height(4.dp))
                Text(subtitle, fontSize = 13.sp, color = Color.White.copy(alpha = 0.65f))
            }
            Spacer(Modifier.height(18.dp))

            Row(
                modifier = Modifier
                    .liquidGlassCapsule()
                    .padding(horizontal = 22.dp, vertical = 12.dp),
                horizontalArrangement = Arrangement.spacedBy(16.dp)
            ) {
                repeat(4) { i ->
                    Box(
                        modifier = Modifier
                            .size(13.dp)
                            .clip(CircleShape)
                            .background(if (i < code.length) Color.White else Color.White.copy(alpha = 0.24f))
                    )
                }
            }

            Spacer(Modifier.weight(1f))

            val rows = listOf(
                listOf("1", "2", "3"),
                listOf("4", "5", "6"),
                listOf("7", "8", "9"),
                listOf("", "0", "del")
            )
            Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
                rows.forEach { row ->
                    Row(horizontalArrangement = Arrangement.spacedBy(24.dp)) {
                        row.forEach { key ->
                            when (key) {
                                "" -> Spacer(Modifier.size(72.dp))
                                "del" -> Box(
                                    modifier = Modifier
                                        .size(72.dp)
                                        .clip(CircleShape)
                                        .clickable { if (code.isNotEmpty()) code = code.dropLast(1) },
                                    contentAlignment = Alignment.Center
                                ) {
                                    Icon(Icons.AutoMirrored.Filled.Backspace, contentDescription = "Delete", tint = Color.White.copy(alpha = 0.8f))
                                }
                                else -> Box(
                                    modifier = Modifier
                                        .size(72.dp)
                                        .liquidGlassCircle()
                                        .clickable {
                                            if (code.length < 4) {
                                                code += key
                                                if (code.length == 4) {
                                                    val entered = code
                                                    code = ""
                                                    if (!isSetup) {
                                                        if (AppState.verifyPasscode(entered)) {
                                                            AppState.unlock()
                                                            onDone()
                                                        } else {
                                                            message = "Incorrect passcode"
                                                        }
                                                    } else if (!confirming) {
                                                        first = entered
                                                        confirming = true
                                                        message = null
                                                    } else if (entered == first) {
                                                        AppState.setPasscode(entered)
                                                        onDone()
                                                    } else {
                                                        confirming = false
                                                        message = "Passcodes didn't match. Try again."
                                                    }
                                                }
                                            }
                                        },
                                    contentAlignment = Alignment.Center
                                ) {
                                    Text(key, fontSize = 26.sp, fontWeight = FontWeight.Medium, color = Color.White)
                                }
                            }
                        }
                    }
                }
            }

            Spacer(Modifier.height(18.dp))
            if (isSetup) {
                TextButton(onClick = {
                    AppState.skipPasscode()
                    onDone()
                }) {
                    Text("Skip Passcode", fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = Color.White.copy(alpha = 0.65f))
                }
            }
            Box(modifier = Modifier.fillMaxWidth(), contentAlignment = Alignment.CenterEnd) {
                Text(
                    "by bella",
                    fontSize = 12.sp,
                    fontStyle = FontStyle.Italic,
                    fontFamily = FontFamily.Serif,
                    color = Color.White.copy(alpha = 0.24f)
                )
            }
            Spacer(Modifier.height(14.dp))
        }
    }
}
