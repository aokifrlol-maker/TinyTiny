package com.bella.tinytiny

import android.content.Context
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import java.security.MessageDigest

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
        return bm.canEvaluate(BiometricManager.Authenticators.BIOMETRIC_WEAK or BiometricManager.Authenticators.BIOMETRIC_STRONG) ==
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
            .build()
        prompt.authenticate(info)
    }
}

object AppState {
    private val prefs by lazy {
        TinyTinyApplication.instance.getSharedPreferences("tt_app_state", Context.MODE_PRIVATE)
    }

    val ageConfirmed = MutableStateFlow(prefs.getBoolean("ageConfirmed", false))
    val onboardingCompleted = MutableStateFlow(prefs.getBoolean("tt.onboardingCompleted", false))
    val licenseActivated = MutableStateFlow(LicenseManager.isValidAccess)
    val passcodeChoiceCompleted = MutableStateFlow(prefs.getBoolean("tt.passcodeChoiceCompleted", false))
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
}

@Composable
fun AgeGateView() {
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
            Icon(Icons.Default.VerifiedUser, contentDescription = null, tint = Theme.accentBright, modifier = Modifier.size(44.dp))
            Text("18+ Adults Only", color = Color.White, fontSize = 24.sp, fontWeight = FontWeight.Bold)
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
        }
    }
}

@Composable
fun WelcomeOnboardingView(onContinue: () -> Unit) {
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
            Text("Welcome to TinyTiny", color = Color.White, fontSize = 26.sp, fontWeight = FontWeight.Bold)
            Text(
                "Stream Reddit, 𝕏, Instagram, Rule34, OnlyFans, Erome, and Long Videos in one encrypted Liquid Glass vault.",
                color = Theme.textSecondary,
                fontSize = 14.sp,
                textAlign = TextAlign.Center
            )
            Column(verticalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
                Text("• Hold & drag left/right on videos to scrub with live preview", color = Color.White.copy(0.85f), fontSize = 13.sp)
                Text("• Hold still for 2x speed · Pull down to lock 2x", color = Color.White.copy(0.85f), fontSize = 13.sp)
                Text("• Double-tap center to Like, left/right to Skip", color = Color.White.copy(0.85f), fontSize = 13.sp)
                Text("• Everything is encrypted locally with AES-256-GCM", color = Color.White.copy(0.85f), fontSize = 13.sp)
            }
            Button(
                onClick = onContinue,
                colors = ButtonDefaults.buttonColors(containerColor = Theme.accent),
                shape = RoundedCornerShape(999.dp),
                modifier = Modifier.fillMaxWidth().height(48.dp)
            ) {
                Text("Continue", fontWeight = FontWeight.Bold)
            }
        }
    }
}

@Composable
fun PasscodeSetupView(isOnboarding: Boolean = true, onDone: () -> Unit) {
    var step by remember { mutableStateOf(0) } // 0 = enter, 1 = confirm
    var firstCode by remember { mutableStateOf("") }
    var code by remember { mutableStateOf("") }
    var errorMsg by remember { mutableStateOf<String?>(null) }

    PasscodePadScreen(
        title = if (step == 0) "Create 4-Digit Passcode" else "Confirm Passcode",
        subtitle = errorMsg ?: (if (isOnboarding) "Optional — skip below to stay unlocked" else "Enter a 4-digit vault PIN"),
        code = code,
        showSkip = isOnboarding,
        onSkip = {
            AppState.skipPasscodeOnOnboarding()
            onDone()
        },
        onDigit = { d ->
            if (code.length < 4) {
                code += d
                if (code.length == 4) {
                    if (step == 0) {
                        firstCode = code
                        code = ""
                        step = 1
                        errorMsg = null
                    } else {
                        if (code == firstCode) {
                            Passcode.set(code)
                            AppState.finishPasscodeSetup()
                            onDone()
                        } else {
                            errorMsg = "Passcodes didn't match. Try again."
                            code = ""
                            step = 0
                        }
                    }
                }
            }
        },
        onBackspace = { if (code.isNotEmpty()) code = code.dropLast(1) }
    )
}

@Composable
fun LockView() {
    val ctx = LocalContext.current
    val activity = ctx as? FragmentActivity
    val prefs = remember { ctx.getSharedPreferences("tt_passcode_lock", Context.MODE_PRIVATE) }
    val settings by UserStore.shared.data.collectAsState()
    val scope = rememberCoroutineScope()

    var code by remember { mutableStateOf("") }
    var failures by remember { mutableIntStateOf(0) }
    var lockedUntilMs by remember { mutableLongStateOf(prefs.getLong("lockedUntilMs", 0L)) }
    var message by remember { mutableStateOf<String?>(null) }
    var showRecovery by remember { mutableStateOf(false) }
    var recoveryKey by remember { mutableStateOf("") }

    LaunchedEffect(Unit) {
        if (settings.settings.faceID && Biometrics.available(ctx)) {
            Biometrics.authenticate(activity) { ok -> if (ok) AppState.unlock() }
        }
    }

    Box(modifier = Modifier.fillMaxSize()) {
        PasscodePadScreen(
            title = "Unlock Vault",
            subtitle = message,
            code = code,
            showBiometric = settings.settings.faceID && Biometrics.available(ctx),
            onBiometric = {
                Biometrics.authenticate(activity) { ok -> if (ok) AppState.unlock() }
            },
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
                        if (Passcode.verify(code)) {
                            failures = 0
                            prefs.edit().remove("lockedUntilMs").apply()
                            AppState.unlock()
                        } else {
                            code = ""
                            failures += 1
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
            },
            onBackspace = { if (code.isNotEmpty()) code = code.dropLast(1) }
        )

        TextButton(
            onClick = { showRecovery = true },
            modifier = Modifier.align(Alignment.BottomCenter).padding(bottom = 22.dp)
        ) {
            Text("Forgot Passcode? Recover with License Key", color = Theme.textSecondary, fontSize = 13.sp)
        }
    }

    if (showRecovery) {
        AlertDialog(
            onDismissRequest = { showRecovery = false },
            title = { Text("Reset Passcode") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("Enter your active License Key to remove your passcode without losing likes or follows.")
                    OutlinedTextField(value = recoveryKey, onValueChange = { recoveryKey = it.uppercase() }, placeholder = { Text("TT-XXXX-XXXX-XXXX") })
                }
            },
            confirmButton = {
                TextButton(onClick = {
                    scope.launch {
                        if (LicenseManager.verifyPasscodeRecovery(recoveryKey)) {
                            AppState.removePasscodeKeepingData()
                            showRecovery = false
                        } else {
                            message = "License key did not match."
                            showRecovery = false
                        }
                    }
                }) { Text("Remove Passcode") }
            },
            dismissButton = {
                TextButton(onClick = { showRecovery = false }) { Text("Cancel") }
            }
        )
    }
}

@Composable
private fun PasscodePadScreen(
    title: String,
    subtitle: String? = null,
    code: String,
    showSkip: Boolean = false,
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
        Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
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
                Text("Skip Passcode", color = Theme.textSecondary)
            }
        }
    }
}

@Composable
private fun PadButton(label: String, onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .size(72.dp)
            .clip(CircleShape)
            .liquidGlassCircle()
            .clickable { onClick() },
        contentAlignment = Alignment.Center
    ) {
        Text(label, color = Color.White, fontSize = 24.sp, fontWeight = FontWeight.SemiBold)
    }
}
