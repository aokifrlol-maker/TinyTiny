package com.bella.tinytiny

import android.content.Context
import android.content.SharedPreferences
import android.util.Base64
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Client-side AES-256-GCM encryption layer (`TTENC1` envelope).
 * Identical wire format to iOS `CryptoBox.swift` (`"TTENC1"` + 12-byte IV + ciphertext + 16-byte GCM tag).
 */
object CryptoBox {
    private const val PREFS_NAME = "tinytiny_secure_keys_v1"
    private const val SEEDR_MASTER_KEY_PREF = "tinytiny.seedr.masterkey.v1"
    private const val LOCAL_VAULT_KEY_PREF = "tinytiny.local.vaultkey.v1"
    private val MAGIC_HEADER = "TTENC1".toByteArray(Charsets.UTF_8)

    val json = Json {
        ignoreUnknownKeys = true
        isLenient = true
        encodeDefaults = true
    }

    private fun securePrefs(context: Context = TinyTinyApplication.instance): SharedPreferences {
        return try {
            val masterKey = MasterKey.Builder(context)
                .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
                .build()
            EncryptedSharedPreferences.create(
                context,
                PREFS_NAME,
                masterKey,
                EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
            )
        } catch (_: Throwable) {
            context.getSharedPreferences(PREFS_NAME + "_fallback", Context.MODE_PRIVATE)
        }
    }

    fun generateKey(): ByteArray {
        val bytes = ByteArray(32)
        SecureRandom().nextBytes(bytes)
        return bytes
    }

    fun localVaultKey(): ByteArray {
        val prefs = securePrefs()
        val existing = prefs.getString(LOCAL_VAULT_KEY_PREF, null)
        if (!existing.isNullOrEmpty()) {
            val decoded = importKeyBase64URL(existing)
            if (decoded != null && decoded.size == 32) return decoded
        }
        val fresh = generateKey()
        prefs.edit().putString(LOCAL_VAULT_KEY_PREF, exportKeyBase64URL(fresh)).apply()
        return fresh
    }

    fun seedrVaultKey(): ByteArray {
        val prefs = securePrefs()
        val existing = prefs.getString(SEEDR_MASTER_KEY_PREF, null)
        if (!existing.isNullOrEmpty()) {
            val decoded = importKeyBase64URL(existing)
            if (decoded != null && decoded.size == 32) return decoded
        }
        val fresh = generateKey()
        prefs.edit().putString(SEEDR_MASTER_KEY_PREF, exportKeyBase64URL(fresh)).apply()
        return fresh
    }

    fun exportKeyBase64URL(key: ByteArray): String {
        return Base64.encodeToString(key, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)
    }

    fun importKeyBase64URL(token: String): ByteArray? {
        return try {
            val clean = token.trim().replace("-", "+").replace("_", "/")
            val padded = clean + "=".repeat((4 - clean.length % 4) % 4)
            val data = Base64.decode(padded, Base64.DEFAULT)
            if (data.size == 32) data else null
        } catch (_: Throwable) {
            null
        }
    }

    fun exportSeedrMasterKeyString(): String = exportKeyBase64URL(seedrVaultKey())

    fun restoreSeedrMasterKeyIfMissing(token: String) {
        val prefs = securePrefs()
        if (prefs.contains(SEEDR_MASTER_KEY_PREF)) return
        val key = importKeyBase64URL(token) ?: return
        prefs.edit().putString(SEEDR_MASTER_KEY_PREF, exportKeyBase64URL(key)).apply()
    }

    fun seal(plaintext: ByteArray, key: ByteArray): ByteArray {
        require(key.size == 32) { "Key must be 256-bit" }
        val iv = ByteArray(12)
        SecureRandom().nextBytes(iv)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, iv))
        val ctAndTag = cipher.doFinal(plaintext)
        return ByteArray(MAGIC_HEADER.size + iv.size + ctAndTag.size).apply {
            System.arraycopy(MAGIC_HEADER, 0, this, 0, MAGIC_HEADER.size)
            System.arraycopy(iv, 0, this, MAGIC_HEADER.size, iv.size)
            System.arraycopy(ctAndTag, 0, this, MAGIC_HEADER.size + iv.size, ctAndTag.size)
        }
    }

    fun open(ciphertext: ByteArray, key: ByteArray): ByteArray {
        require(key.size == 32) { "Key must be 256-bit" }
        val offset = if (isEncryptedEnvelope(ciphertext)) MAGIC_HEADER.size else 0
        require(ciphertext.size > offset + 12 + 16) { "Ciphertext too short" }
        val iv = ciphertext.copyOfRange(offset, offset + 12)
        val payload = ciphertext.copyOfRange(offset + 12, ciphertext.size)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, iv))
        return cipher.doFinal(payload)
    }

    fun isEncryptedEnvelope(data: ByteArray): Boolean {
        if (data.size < MAGIC_HEADER.size) return false
        for (i in MAGIC_HEADER.indices) {
            if (data[i] != MAGIC_HEADER[i]) return false
        }
        return true
    }

    inline fun <reified T> sealCodable(value: T): ByteArray? {
        return try {
            val raw = json.encodeToString(value).toByteArray(Charsets.UTF_8)
            seal(raw, localVaultKey())
        } catch (_: Throwable) {
            null
        }
    }

    inline fun <reified T> openCodable(data: ByteArray): T? {
        return try {
            val plain = if (isEncryptedEnvelope(data)) open(data, localVaultKey()) else data
            json.decodeFromString<T>(String(plain, Charsets.UTF_8))
        } catch (_: Throwable) {
            null
        }
    }
}
