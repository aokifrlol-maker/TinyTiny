package com.bella.tinytiny

import android.content.ContentValues
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.webkit.CookieManager
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.Request
import java.io.File
import java.io.FileOutputStream

object OfflineManager {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val client = TinyTinyApplication.longTransferHttpClient

    val activeDownloads = MutableStateFlow<Set<String>>(emptySet())
    val downloadProgress = MutableStateFlow<Map<String, Double>>(emptyMap())
    val lastError = MutableStateFlow<String?>(null)
    val diskUsageText = MutableStateFlow("0 MB")

    private val vaultDir: File by lazy {
        File(TinyTinyApplication.instance.filesDir, "OfflineVault").apply { mkdirs() }
    }

    private val stemToMediaPath = java.util.concurrent.ConcurrentHashMap<String, String>()
    private val stemToThumbPath = java.util.concurrent.ConcurrentHashMap<String, String>()
    @Volatile private var cacheIndexed = false

    private fun ensureIndex() {
        if (cacheIndexed) return
        synchronized(this) {
            if (cacheIndexed) return
            vaultDir.listFiles()?.forEach { f ->
                if (f.isFile && f.length() > 0) {
                    val name = f.name
                    if (name.endsWith("_thumb.jpg")) {
                        stemToThumbPath[name.removeSuffix("_thumb.jpg")] = "file://${f.absolutePath}"
                    } else {
                        val stem = name.substringBeforeLast('.')
                        stemToMediaPath[stem] = "file://${f.absolutePath}"
                    }
                }
            }
            cacheIndexed = true
        }
    }

    private fun safeFileStem(id: String): String =
        id.replace(Regex("[^A-Za-z0-9_-]"), "_").take(64).ifEmpty { "media" }

    fun localMediaURL(id: String): String? {
        ensureIndex()
        val stem = safeFileStem(id)
        stemToMediaPath[stem]?.let { return it }
        return null
    }

    fun localThumbURL(id: String): String? {
        ensureIndex()
        val stem = safeFileStem(id)
        return stemToThumbPath[stem]
    }

    fun isDownloaded(gif: Gif): Boolean = localMediaURL(gif.id) != null
    fun isDownloading(id: String): Boolean = id in activeDownloads.value

    fun toggleDownload(gif: Gif) {
        if (isDownloaded(gif)) {
            removeDownload(gif)
        } else {
            scope.launch { download(gif) }
        }
    }

    private fun setProgress(id: String, value: Double?) {
        if (value == null) {
            downloadProgress.value = downloadProgress.value - id
        } else {
            val clamped = value.coerceIn(0.0, 1.0)
            val prev = downloadProgress.value[id]
            // Throttle progress updates to >=3% steps to prevent recomposition storms
            if (prev == null || kotlin.math.abs(clamped - prev) >= 0.03 || clamped >= 0.99) {
                downloadProgress.value = downloadProgress.value + (id to clamped)
            }
        }
    }

    suspend fun download(gif: Gif) {
        if (gif.id in activeDownloads.value) return
        activeDownloads.value = activeDownloads.value + gif.id
        setProgress(gif.id, 0.08)
        lastError.value = null
        try {
            val hd = UserStore.shared.data.value.settings.hd
            val candidates = mutableListOf<String>()
            if (gif.isLongVideoPost) {
                val resolved = LongVideoAPI.resolvePlayableURLs(gif)
                candidates.addAll(resolved.filter { !it.lowercase().contains(".m3u8") })
            }
            if (gif.isImage) {
                candidates.addAll(gif.imageFallbackURLs)
            } else {
                candidates.addAll(gif.allVideoURLs(hd).filter { !it.lowercase().contains(".m3u8") })
                if (candidates.isEmpty()) candidates.addAll(gif.imageFallbackURLs)
            }
            if (candidates.isEmpty()) {
                MediaMetaRegistry.albumItems(gif.id).firstOrNull()?.url?.let { candidates.add(it) }
            }
            val uniqueCandidates = candidates.distinct().filter { !it.startsWith("file://") }
            if (uniqueCandidates.isEmpty()) {
                lastError.value = "No downloadable media URL available."
                return
            }

            var savedFile: File? = null
            for (u in uniqueCandidates) {
                val ext = u.substringAfterLast('.', "").substringBefore('?').lowercase()
                    .takeIf { it in setOf("mp4", "mov", "m4v", "webm", "gif", "jpg", "jpeg", "png", "webp") }
                    ?: if (gif.isImage) "jpg" else "mp4"
                val dest = File(vaultDir, "${safeFileStem(gif.id)}.$ext")
                val ok = downloadToFile(u, dest) { frac ->
                    setProgress(gif.id, 0.15 + frac * 0.72)
                }
                if (ok) {
                    savedFile = dest
                    break
                }
            }
            if (savedFile != null) {
                val stem = safeFileStem(gif.id)
                stemToMediaPath[stem] = "file://${savedFile.absolutePath}"
                setProgress(gif.id, 0.90)
                saveOfflineThumbnail(gif, savedFile)
                val thumbFile = File(vaultDir, "${stem}_thumb.jpg")
                if (thumbFile.exists() && thumbFile.length() > 0) {
                    stemToThumbPath[stem] = "file://${thumbFile.absolutePath}"
                }
                setProgress(gif.id, 1.0)
                // Keep original remote URLs intact in UserStore so cloud backup stays valid on iOS!
                withContext(Dispatchers.Main) {
                    UserStore.shared.recordDownloaded(gif)
                }
                refreshDiskUsage()
            } else {
                lastError.value = "Download failed. Try again."
            }
        } finally {
            activeDownloads.value = activeDownloads.value - gif.id
            setProgress(gif.id, null)
        }
    }

    private fun saveOfflineThumbnail(gif: Gif, mediaFile: File) {
        val thumbDest = File(vaultDir, "${safeFileStem(gif.id)}_thumb.jpg")
        val remoteThumb = gif.posterUrl ?: gif.thumbnailUrl
        if (!remoteThumb.isNullOrEmpty() && !remoteThumb.startsWith("file://")) {
            if (downloadToFile(remoteThumb, thumbDest, minBytes = 256, onProgress = {})) return
        }
        // Fallback: extract first video frame via MediaMetadataRetriever
        val ext = mediaFile.extension.lowercase()
        if (ext in setOf("mp4", "mov", "m4v", "webm")) {
            val mmr = MediaMetadataRetriever()
            try {
                mmr.setDataSource(mediaFile.absolutePath)
                val bmp = mmr.getFrameAtTime(0, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
                if (bmp != null) {
                    FileOutputStream(thumbDest).use { out ->
                        bmp.compress(Bitmap.CompressFormat.JPEG, 82, out)
                    }
                    bmp.recycle()
                }
            } catch (_: Throwable) {
            } finally {
                try { mmr.release() } catch (_: Throwable) {}
            }
        }
    }

    private fun downloadToFile(
        url: String,
        dest: File,
        minBytes: Long = 1024L,
        onProgress: (Double) -> Unit
    ): Boolean {
        for (useRef in listOf(true, false)) {
            try {
                val rb = Request.Builder().url(url)
                for ((k, v) in MediaHeaders.headers(url, includeReferer = useRef)) {
                    rb.header(k, v)
                }
                try {
                    val cookies = CookieManager.getInstance().getCookie(url)
                    if (!cookies.isNullOrEmpty()) rb.header("Cookie", cookies)
                } catch (_: Throwable) {}

                client.newCall(rb.build()).execute().use { resp ->
                    if (!resp.isSuccessful) return@use
                    val contentType = (resp.header("Content-Type") ?: "").lowercase()
                    if (contentType.contains("text/html") ||
                        contentType.contains("application/json") ||
                        contentType.contains("mpegurl")
                    ) {
                        return@use
                    }
                    val body = resp.body ?: return@use
                    val total = body.contentLength()
                    val tmp = File(dest.parentFile, dest.name + ".part")
                    var copied = 0L
                    FileOutputStream(tmp).use { out ->
                        val buf = ByteArray(16 * 1024)
                        val inp = body.byteStream()
                        while (true) {
                            val n = inp.read(buf)
                            if (n <= 0) break
                            out.write(buf, 0, n)
                            copied += n
                            if (total > 0) onProgress(copied.toDouble() / total.toDouble())
                        }
                    }
                    if (tmp.length() >= minBytes) {
                        if (dest.exists()) dest.delete()
                        if (tmp.renameTo(dest)) return true
                    }
                    tmp.delete()
                }
            } catch (_: Throwable) {}
        }
        return false
    }

    fun saveToMediaStoreGallery(file: File): Boolean {
        return try {
            val ext = file.extension.lowercase()
            val isVideo = ext in setOf("mp4", "mov", "m4v", "webm")
            val mime = when (ext) {
                "mp4" -> "video/mp4"
                "mov" -> "video/quicktime"
                "m4v" -> "video/x-m4v"
                "webm" -> "video/webm"
                "gif" -> "image/gif"
                "png" -> "image/png"
                "webp" -> "image/webp"
                else -> "image/jpeg"
            }
            val ctx = TinyTinyApplication.instance
            val resolver = ctx.contentResolver
            val collection = if (isVideo) {
                if (Build.VERSION.SDK_INT >= 29) MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
                else MediaStore.Video.Media.EXTERNAL_CONTENT_URI
            } else {
                if (Build.VERSION.SDK_INT >= 29) MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
                else MediaStore.Images.Media.EXTERNAL_CONTENT_URI
            }
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, file.name)
                put(MediaStore.MediaColumns.MIME_TYPE, mime)
                if (Build.VERSION.SDK_INT >= 29) {
                    put(
                        MediaStore.MediaColumns.RELATIVE_PATH,
                        (if (isVideo) Environment.DIRECTORY_MOVIES else Environment.DIRECTORY_PICTURES) + "/TinyTiny"
                    )
                }
            }
            val uri = resolver.insert(collection, values) ?: return false
            resolver.openOutputStream(uri)?.use { out ->
                file.inputStream().use { it.copyTo(out) }
            }
            true
        } catch (_: Throwable) {
            false
        }
    }

    fun removeDownload(gif: Gif) {
        val stem = safeFileStem(gif.id)
        stemToMediaPath.remove(stem)
        stemToThumbPath.remove(stem)
        UserStore.shared.removeDownloaded(gif.id)
        scope.launch {
            val dir = vaultDir
            for (ext in listOf("mp4", "mov", "m4v", "webm", "gif", "jpg", "jpeg", "png", "webp")) {
                File(dir, "$stem.$ext").delete()
            }
            File(dir, "${stem}_thumb.jpg").delete()
            refreshDiskUsage()
        }
    }

    fun clearAllDownloads() {
        stemToMediaPath.clear()
        stemToThumbPath.clear()
        UserStore.shared.clearAllDownloaded()
        scope.launch {
            vaultDir.listFiles()?.forEach { it.delete() }
            refreshDiskUsage()
        }
    }

    fun refreshDiskUsage() {
        scope.launch {
            val totalBytes = vaultDir.listFiles()?.sumOf { it.length() } ?: 0L
            val mb = totalBytes / (1024.0 * 1024.0)
            diskUsageText.value = when {
                mb < 0.1 -> "0 MB"
                mb >= 1024.0 -> String.format("%.2f GB", mb / 1024.0)
                else -> String.format("%.1f MB", mb)
            }
        }
    }
}
