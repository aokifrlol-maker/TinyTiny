package com.bella.tinytiny

import android.util.Base64
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Binary-compatible with iOS CryptoBox.swift:
 * `TTENC1` (6 bytes) + 12-byte GCM nonce + ciphertext + 16-byte GCM tag.
 */
object CryptoBox {
    private val magic = "TTENC1".toByteArray(Charsets.UTF_8)
    private const val NONCE_SIZE = 12
    private const val TAG_BITS = 128

    fun generateKey(): SecretKey {
        val bytes = ByteArray(32)
        SecureRandom().nextBytes(bytes)
        return SecretKeySpec(bytes, "AES")
    }

    fun exportKeyBase64URL(key: SecretKey): String {
        return Base64.encodeToString(key.encoded, Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP)
    }

    fun importKeyBase64URL(raw: String): SecretKey? {
        return try {
            val decoded = decodeBase64URL(raw)
            if (decoded.size != 32) return null
            SecretKeySpec(decoded, "AES")
        } catch (_: Exception) {
            null
        }
    }

    fun decodeBase64URL(raw: String): ByteArray {
        val clean = raw.trim()
            .replace('-', '+')
            .replace('_', '/')
        val pad = (4 - clean.length % 4) % 4
        val padded = clean + "=".repeat(pad)
        return Base64.decode(padded, Base64.DEFAULT)
    }

    fun encodeBase64URL(bytes: ByteArray): String {
        return Base64.encodeToString(bytes, Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP)
    }

    fun seal(plaintext: ByteArray, key: SecretKey): ByteArray {
        val nonce = ByteArray(NONCE_SIZE)
        SecureRandom().nextBytes(nonce)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key, GCMParameterSpec(TAG_BITS, nonce))
        val combined = cipher.doFinal(plaintext)
        return magic + nonce + combined
    }

    fun open(payload: ByteArray, key: SecretKey): ByteArray? {
        return try {
            if (payload.size <= magic.size + NONCE_SIZE + 16) return null
            for (i in magic.indices) {
                if (payload[i] != magic[i]) return null
            }
            val nonce = payload.copyOfRange(magic.size, magic.size + NONCE_SIZE)
            val cipherAndTag = payload.copyOfRange(magic.size + NONCE_SIZE, payload.size)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(TAG_BITS, nonce))
            cipher.doFinal(cipherAndTag)
        } catch (_: Exception) {
            null
        }
    }
}
