package com.bella.tinytiny

import android.content.Context
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Backspace
import androidx.compose.material.icons.filled.Fingerprint
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.VerifiedUser
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import java.security.MessageDigest
import kotlin.math.roundToInt

object Passcode {
    private const val PREFS_NAME = "tinytiny_passcode_v1"
    private const val HASH_KEY = "tinytiny.passcode.hash"

    private val prefs by lazy {
        val ctx = TinyTinyApplication.instance
        try {
            val mk = MasterKey.Builder(ctx).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build()
            EncryptedSharedPreferences.create(
                ctx, PREFS_NAME, mk,
                EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
            )
        } catch (_: Throwable) {
            ctx.getSharedPreferences(PREFS_NAME + "_fb", Context.MODE_PRIVATE)
        }
    }

    private fun hash(code: String): String {
        val bytes = MessageDigest.getInstance("SHA-256").digest(("tt.v1.$code").toByteArray(Charsets.UTF_8))
        return bytes.joinToString("") { "%02x".format(it) }
    }

    val exists: Boolean get() = !prefs.getString(HASH_KEY, null).isNullOrEmpty()

    fun set(code: String) {
        prefs.edit().putString(HASH_KEY, hash(code)).apply()
    }

    fun verify(code: String): Boolean = prefs.getString(HASH_KEY, null) == hash(code)

    fun delete() {
        prefs.edit().remove(HASH_KEY).apply()
    }
}

object Biometrics {
    fun available(context: Context = TinyTinyApplication.instance): Boolean {
        val bm = BiometricManager.from(context)
        return bm.canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_WEAK or BiometricManager.Authenticators.BIOMETRIC_STRONG) ==
            BiometricManager.BIOMETRIC_SUCCESS
    }

    fun authenticate(activity: FragmentActivity?, onResult: (Boolean) -> Unit) {
        if (activity == null) {
            onResult(false)
            return
        }
        val executor = ContextCompat.getMainExecutor(activity)
        val prompt = BiometricPrompt(activity, executor, object : BiometricPrompt.AuthenticationCallback() {
            override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                onResult(true)
            }

            override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                onResult(false)
            }
        })
        val info = BiometricPrompt.PromptInfo.Builder()
            .setTitle("Unlock TinyTiny Vault")
            .setNegativeButtonText("Enter Passcode")
            .setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_WEAK or BiometricManager.Authenticators.BIOMETRIC_STRONG)
            .build()
        prompt.authenticate(info)
    }
}

object AppState {
    private val prefs by lazy {
        TinyTinyApplication.instance.getSharedPreferences("tt_app_state", Context.MODE_PRIVATE)
    }

    val ageConfirmed = MutableStateFlow(prefs.getBoolean("ageConfirmed", false))
    val onboardingCompleted = MutableStateFlow(
        prefs.getBoolean("tt.onboardingCompleted", false) || LicenseManager.isValidAccess
    )
    val licenseActivated = MutableStateFlow(LicenseManager.isValidAccess)
    val passcodeChoiceCompleted = MutableStateFlow(
        prefs.getBoolean("tt.passcodeChoiceCompleted", false) || Passcode.exists
    )
    val hasPasscode = MutableStateFlow(Passcode.exists)
    val requirePasscodeOnOpen = MutableStateFlow(prefs.getBoolean("tt.requirePasscodeOnOpen", false))
    val isLocked = MutableStateFlow(Passcode.exists && prefs.getBoolean("tt.requirePasscodeOnOpen", false))
    val hasUnlockedOnce = MutableStateFlow(!(Passcode.exists && prefs.getBoolean("tt.requirePasscodeOnOpen", false)))

    fun confirmAge() {
        ageConfirmed.value = true
        prefs.edit().putBoolean("ageConfirmed", true).apply()
    }

    fun completeOnboarding() {
        onboardingCompleted.value = true
        prefs.edit().putBoolean("tt.onboardingCompleted", true).apply()
    }

    fun markLicenseActivated(valid: Boolean) {
        licenseActivated.value = valid
    }

    fun setRequirePasscodeOnOpen(req: Boolean) {
        requirePasscodeOnOpen.value = req
        prefs.edit().putBoolean("tt.requirePasscodeOnOpen", req).apply()
    }

    fun unlock() {
        isLocked.value = false
        hasUnlockedOnce.value = true
    }

    fun lock() {
        if (hasPasscode.value && requirePasscodeOnOpen.value) {
            isLocked.value = true
        }
    }

    fun skipPasscodeOnOnboarding() {
        Passcode.delete()
        hasPasscode.value = false
        passcodeChoiceCompleted.value = true
        prefs.edit().putBoolean("tt.passcodeChoiceCompleted", true).apply()
        isLocked.value = false
        hasUnlockedOnce.value = true
    }

    fun finishPasscodeSetup() {
        hasPasscode.value = true
        passcodeChoiceCompleted.value = true
        prefs.edit().putBoolean("tt.passcodeChoiceCompleted", true).apply()
        unlock()
    }

    fun removePasscodeKeepingData() {
        Passcode.delete()
        hasPasscode.value = false
        isLocked.value = false
        hasUnlockedOnce.value = true
    }

    fun eraseEverything() {
        OfflineManager.clearAllDownloads()
        kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.IO).launch {
            UserStore.shared.performSelectiveWipe(
                UserStore.WipeOptions(
                    keepLikes = false,
                    keepFollowing = false,
                    keepOfflineVault = false,
                    keepAccounts = false,
                    keepAlgorithm = false,
                    keepPasscode = false
                )
            )
        }
        Passcode.delete()
        hasPasscode.value = false
        isLocked.value = false
        hasUnlockedOnce.value = true
    }
}

@Composable
fun AgeGateView() {
    var showUnder18Alert by remember { mutableStateOf(false) }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Theme.bg)
            .padding(24.dp),
        contentAlignment = Alignment.Center
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .liquidGlassCard(cornerRadius = 26.dp)
                .padding(24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            Box(
                modifier = Modifier
                    .size(64.dp)
                    .clip(CircleShape)
                    .liquidGlassCircle(active = true),
                contentAlignment = Alignment.Center
            ) {
                Text("18+", color = Color.White, fontSize = 20.sp, fontWeight = FontWeight.ExtraBold)
            }
            Text("18+ Only", color = Color.White, fontSize = 24.sp, fontWeight = FontWeight.Bold)
            Text(
                "TinyTiny contains adult 18+ content. By continuing, you confirm that you are at least 18 years old.",
                color = Theme.textSecondary,
                fontSize = 14.sp,
                textAlign = TextAlign.Center
            )
            Button(
                onClick = { AppState.confirmAge() },
                colors = ButtonDefaults.buttonColors(containerColor = Theme.accent),
                shape = RoundedCornerShape(999.dp),
                modifier = Modifier.fillMaxWidth().height(48.dp)
            ) {
                Text("I am 18 or Older — Enter", fontWeight = FontWeight.Bold)
            }
            TextButton(onClick = { showUnder18Alert = true }) {
                Text("I'm under 18", color = Theme.textMuted, fontSize = 13.sp)
            }
            Text("by bella", color = Theme.textMuted, fontSize = 11.sp)
        }
    }

    if (showUnder18Alert) {
        AlertDialog(
            onDismissRequest = { showUnder18Alert = false },
            title = { Text("Access Restricted") },
            text = { Text("You must be at least 18 years old to use TinyTiny. Please close this app.") },
            confirmButton = {
                TextButton(onClick = { showUnder18Alert = false }) { Text("OK") }
            }
        )
    }
}

@Composable
fun WelcomeOnboardingView(onContinue: () -> Unit) {
    val steps = listOf(
        Triple("Welcome to TinyTiny", "One Encrypted Vault", "Stream Reddit, 𝕏, Instagram, Rule34, OnlyFans, Erome, and Long Videos in a fast Liquid Glass feed."),
        Triple("Smart Taste Engine", "Learns What You Love", "Like, loop, or hide any tag. Your personal algorithm adapts across every platform in real time."),
        Triple("Precision Gestures", "Control Every Frame", "Hold & drag left/right to scrub with live preview. Hold still for 2x speed, pull down to lock 2x, double-tap center to Like or edges to Skip."),
        Triple("Private & Synced", "AES-256-GCM Encrypted", "Your likes, follows, accounts, and offline vault are encrypted on-device and synced seamlessly between iOS and Android.")
    )
    val pagerState = rememberPagerState(pageCount = { steps.size })
    val scope = rememberCoroutineScope()

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Theme.bg)
            .statusBarsPadding()
            .navigationBarsPadding()
            .padding(24.dp)
    ) {
        if (pagerState.currentPage < steps.lastIndex) {
            TextButton(
                onClick = onContinue,
                modifier = Modifier.align(Alignment.TopEnd)
            ) {
                Text("Skip", color = Theme.textSecondary, fontWeight = FontWeight.SemiBold)
            }
        }

        Column(
            modifier = Modifier.align(Alignment.Center).fillMaxWidth(),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(20.dp)
        ) {
            HorizontalPager(
                state = pagerState,
                modifier = Modifier.fillMaxWidth()
            ) { page ->
                val (title, subtitle, body) = steps[page]
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .liquidGlassCard(cornerRadius = 26.dp)
                        .padding(24.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(14.dp)
                ) {
                    Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
                        BrandLogoX(24.dp)
                        BrandLogoRule34(24.dp)
                        BrandLogoInstagram(24.dp)
                        BrandLogoOnlyFans(24.dp)
                        BrandLogoErome(24.dp)
                    }
                    Text(title, color = Color.White, fontSize = 24.sp, fontWeight = FontWeight.Bold, textAlign = TextAlign.Center)
                    Text(subtitle, color = Theme.accentBright, fontSize = 13.sp, fontWeight = FontWeight.Bold)
                    Text(body, color = Theme.textSecondary, fontSize = 14.sp, textAlign = TextAlign.Center)
                }
            }

            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                steps.indices.forEach { idx ->
                    Box(
                        modifier = Modifier
                            .size(width = if (idx == pagerState.currentPage) 22.dp else 8.dp, height = 8.dp)
                            .clip(CircleShape)
                            .background(if (idx == pagerState.currentPage) Theme.accentBright else Color.White.copy(0.25f))
                    )
                }
            }

            Button(
                onClick = {
                    if (pagerState.currentPage < steps.lastIndex) {
                        scope.launch { pagerState.animateScrollToPage(pagerState.currentPage + 1) }
                    } else {
                        onContinue()
                    }
                },
                colors = ButtonDefaults.buttonColors(containerColor = Theme.accent),
                shape = RoundedCornerShape(999.dp),
                modifier = Modifier.fillMaxWidth().height(48.dp)
            ) {
                Text(if (pagerState.currentPage < steps.lastIndex) "Next" else "Get Started", fontWeight = FontWeight.Bold)
            }
            Text("by bella", color = Theme.textMuted, fontSize = 11.sp)
        }
    }
}

@Composable
fun PasscodeSetupView(
    isOnboarding: Boolean = true,
    isChanging: Boolean = (!isOnboarding && Passcode.exists),
    onDone: () -> Unit
) {
    val ctx = LocalContext.current
    val haptic = LocalHapticFeedback.current
    val scope = rememberCoroutineScope()
    // step: -1 = verify current (when isChanging), 0 = enter new, 1 = confirm new
    var step by remember { mutableIntStateOf(if (isChanging) -1 else 0) }
    var firstCode by remember { mutableStateOf("") }
    var code by remember { mutableStateOf("") }
    var errorMsg by remember { mutableStateOf<String?>(null) }
    var showBiometricAsk by remember { mutableStateOf(false) }
    val shakeOffset = remember { Animatable(0f) }

    fun triggerShake() {
        haptic.performHapticFeedback(HapticFeedbackType.LongPress)
        scope.launch {
            for (dx in listOf(-14f, 14f, -10f, 10f, -5f, 0f)) {
                shakeOffset.animateTo(dx, tween(40))
            }
        }
    }

    PasscodePadScreen(
        title = when (step) {
            -1 -> "Current Passcode"
            0 -> if (isChanging) "New 4-Digit Passcode" else "Create 4-Digit Passcode"
            else -> "Confirm Passcode"
        },
        subtitle = errorMsg ?: when (step) {
            -1 -> "Verify your current vault PIN first"
            0 -> if (isOnboarding) "Optional — skip below to stay unlocked" else "Enter a 4-digit vault PIN"
            else -> "Re-enter your 4-digit PIN to confirm"
        },
        code = code,
        shakeOffsetPx = shakeOffset.value,
        showSkip = true,
        skipLabel = if (isOnboarding) "Skip Passcode" else "Cancel",
        onSkip = {
            if (isOnboarding) AppState.skipPasscodeOnOnboarding()
            onDone()
        },
        onDigit = { d ->
            if (code.length < 4) {
                code += d
                if (code.length == 4) {
                    val entered = code
                    scope.launch {
                        delay(110)
                        when (step) {
                            -1 -> {
                                if (Passcode.verify(entered)) {
                                    code = ""
                                    step = 0
                                    errorMsg = null
                                } else {
                                    errorMsg = "Incorrect current passcode."
                                    code = ""
                                    triggerShake()
                                }
                            }
                            0 -> {
                                firstCode = entered
                                code = ""
                                step = 1
                                errorMsg = null
                            }
                            else -> {
                                if (entered == firstCode) {
                                    Passcode.set(entered)
                                    AppState.finishPasscodeSetup()
                                    if (Biometrics.available(ctx) && !UserStore.shared.data.value.settings.faceID) {
                                        showBiometricAsk = true
                                    } else {
                                        onDone()
                                    }
                                } else {
                                    errorMsg = "Passcodes didn't match. Try again."
                                    code = ""
                                    step = 0
                                    triggerShake()
                                }
                            }
                        }
                    }
                }
            }
        },
        onBackspace = { if (code.isNotEmpty()) code = code.dropLast(1) }
    )

    if (showBiometricAsk) {
        AlertDialog(
            onDismissRequest = { showBiometricAsk = false; onDone() },
            title = { Text("Enable Biometric Unlock?") },
            text = { Text("Use fingerprint or face unlock to open your TinyTiny Vault faster.") },
            confirmButton = {
                TextButton(onClick = {
                    UserStore.shared.updateSettings { it.copy(faceID = true) }
                    showBiometricAsk = false
                    onDone()
                }) { Text("Enable") }
            },
            dismissButton = {
                TextButton(onClick = { showBiometricAsk = false; onDone() }) { Text("Not Now") }
            }
        )
    }
}

@Composable
fun LockView() {
    val ctx = LocalContext.current
    val activity = ctx as? FragmentActivity
    val haptic = LocalHapticFeedback.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val prefs = remember { ctx.getSharedPreferences("tt_passcode_lock", Context.MODE_PRIVATE) }
    val settings by UserStore.shared.data.collectAsState()
    val scope = rememberCoroutineScope()

    var code by remember { mutableStateOf("") }
    var failures by remember { mutableIntStateOf(0) }
    var lockedUntilMs by remember { mutableLongStateOf(prefs.getLong("lockedUntilMs", 0L)) }
    var message by remember { mutableStateOf<String?>(null) }
    var showRecovery by remember { mutableStateOf(false) }
    var recoveryKey by remember { mutableStateOf("") }
    var isRecovering by remember { mutableStateOf(false) }
    val shakeOffset = remember { Animatable(0f) }

    fun tryBiometric() {
        if (settings.settings.faceID && Biometrics.available(ctx)) {
            Biometrics.authenticate(activity) { ok -> if (ok) AppState.unlock() }
        }
    }

    LaunchedEffect(Unit) { tryBiometric() }

    DisposableEffect(lifecycleOwner) {
        val obs = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) {
                tryBiometric()
            }
        }
        lifecycleOwner.lifecycle.addObserver(obs)
        onDispose { lifecycleOwner.lifecycle.removeObserver(obs) }
    }

    Box(modifier = Modifier.fillMaxSize()) {
        PasscodePadScreen(
            title = "Unlock Vault",
            subtitle = message,
            code = code,
            shakeOffsetPx = shakeOffset.value,
            showBiometric = settings.settings.faceID && Biometrics.available(ctx),
            onBiometric = { tryBiometric() },
            onDigit = { d ->
                val now = System.currentTimeMillis()
                if (lockedUntilMs > now) {
                    val rem = ((lockedUntilMs - now) / 1000L) + 1
                    message = "Too many attempts. Try again in ${rem}s."
                    return@PasscodePadScreen
                }
                if (code.length < 4) {
                    code += d
                    if (code.length == 4) {
                        val entered = code
                        scope.launch {
                            delay(90)
                            if (Passcode.verify(entered)) {
                                failures = 0
                                prefs.edit().remove("lockedUntilMs").apply()
                                AppState.unlock()
                            } else {
                                code = ""
                                failures += 1
                                haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                                for (dx in listOf(-14f, 14f, -10f, 10f, -5f, 0f)) {
                                    shakeOffset.animateTo(dx, tween(40))
                                }
                                if (failures >= 5) {
                                    failures = 0
                                    lockedUntilMs = System.currentTimeMillis() + 30_000L
                                    prefs.edit().putLong("lockedUntilMs", lockedUntilMs).apply()
                                    message = "Too many attempts. Wait 30 seconds."
                                } else {
                                    message = "Incorrect passcode"
                                }
                            }
                        }
                    }
                }
            },
            onBackspace = { if (code.isNotEmpty()) code = code.dropLast(1) }
        )

        TextButton(
            onClick = { showRecovery = true },
            modifier = Modifier.align(Alignment.BottomCenter).navigationBarsPadding().padding(bottom = 22.dp)
        ) {
            Text("Forgot Passcode? Recover with License Key", color = Theme.textSecondary, fontSize = 13.sp)
        }
    }

    if (showRecovery) {
        AlertDialog(
            onDismissRequest = { if (!isRecovering) showRecovery = false },
            title = { Text("Reset Passcode") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("Enter your active License Key to remove your passcode without losing likes or follows.")
                    OutlinedTextField(
                        value = recoveryKey,
                        onValueChange = { recoveryKey = it.uppercase() },
                        placeholder = { Text("TT-XXXX-XXXX-XXXX") },
                        enabled = !isRecovering
                    )
                    if (isRecovering) {
                        LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
                    }
                }
            },
            confirmButton = {
                TextButton(
                    enabled = !isRecovering,
                    onClick = {
                        scope.launch {
                            isRecovering = true
                            val ok = LicenseManager.verifyPasscodeRecovery(recoveryKey)
                            isRecovering = false
                            if (ok) {
                                AppState.removePasscodeKeepingData()
                                showRecovery = false
                            } else {
                                message = "License key did not match."
                                showRecovery = false
                            }
                        }
                    }
                ) { Text("Remove Passcode") }
            },
            dismissButton = {
                TextButton(enabled = !isRecovering, onClick = { showRecovery = false }) { Text("Cancel") }
            }
        )
    }
}

@Composable
private fun PasscodePadScreen(
    title: String,
    subtitle: String? = null,
    code: String,
    shakeOffsetPx: Float = 0f,
    showSkip: Boolean = false,
    skipLabel: String = "Skip Passcode",
    onSkip: () -> Unit = {},
    showBiometric: Boolean = false,
    onBiometric: () -> Unit = {},
    onDigit: (String) -> Unit,
    onBackspace: () -> Unit
) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(Theme.bg)
            .padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center
    ) {
        Icon(Icons.Default.Lock, contentDescription = null, tint = Theme.accentBright, modifier = Modifier.size(36.dp))
        Spacer(Modifier.height(12.dp))
        Text(title, color = Color.White, fontSize = 22.sp, fontWeight = FontWeight.Bold)
        if (!subtitle.isNullOrEmpty()) {
            Spacer(Modifier.height(6.dp))
            Text(subtitle, color = Theme.textSecondary, fontSize = 13.sp, textAlign = TextAlign.Center)
        }
        Spacer(Modifier.height(22.dp))
        Row(
            horizontalArrangement = Arrangement.spacedBy(16.dp),
            modifier = Modifier.offset { IntOffset(shakeOffsetPx.roundToInt(), 0) }
        ) {
            repeat(4) { idx ->
                Box(
                    modifier = Modifier
                        .size(16.dp)
                        .clip(CircleShape)
                        .background(if (idx < code.length) Theme.accentBright else Color.White.copy(0.22f))
                )
            }
        }
        Spacer(Modifier.height(32.dp))
        val rows = listOf(listOf("1", "2", "3"), listOf("4", "5", "6"), listOf("7", "8", "9"))
        Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
            for (row in rows) {
                Row(horizontalArrangement = Arrangement.spacedBy(20.dp)) {
                    for (d in row) {
                        PadButton(label = d) { onDigit(d) }
                    }
                }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(20.dp), verticalAlignment = Alignment.CenterVertically) {
                if (showBiometric) {
                    Box(
                        modifier = Modifier.size(72.dp).clip(CircleShape).liquidGlassCircle().clickable { onBiometric() },
                        contentAlignment = Alignment.Center
                    ) { Icon(Icons.Default.Fingerprint, contentDescription = "Biometrics", tint = Color.White) }
                } else {
                    Spacer(Modifier.size(72.dp))
                }
                PadButton(label = "0") { onDigit("0") }
                Box(
                    modifier = Modifier.size(72.dp).clip(CircleShape).liquidGlassCircle().clickable { onBackspace() },
                    contentAlignment = Alignment.Center
                ) { Icon(Icons.AutoMirrored.Filled.Backspace, contentDescription = "Delete", tint = Color.White) }
            }
        }
        if (showSkip) {
            Spacer(Modifier.height(22.dp))
            TextButton(onClick = onSkip) {
                Text(skipLabel, color = Theme.textSecondary)
            }
        }
    }
}

@Composable
private fun PadButton(label: String, onClick: () -> Unit) {
    val haptic = LocalHapticFeedback.current
    Box(
        modifier = Modifier
            .size(72.dp)
            .clip(CircleShape)
            .liquidGlassCircle()
            .clickable {
                haptic.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                onClick()
            },
        contentAlignment = Alignment.Center
    ) {
        Text(label, color = Color.White, fontSize = 24.sp, fontWeight = FontWeight.SemiBold)
    }
}
