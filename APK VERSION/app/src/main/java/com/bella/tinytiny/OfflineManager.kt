package com.bella.tinytiny

import android.content.ContentValues
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
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
    private val client = TinyTinyApplication.sharedHttpClient

    val activeDownloads = MutableStateFlow<Set<String>>(emptySet())
    val lastError = MutableStateFlow<String?>(null)
    val diskUsageText = MutableStateFlow("0 MB")

    private val vaultDir: File
        get() = File(TinyTinyApplication.instance.filesDir, "OfflineVault").apply { mkdirs() }

    private fun safeFileStem(id: String): String = id.replace(Regex("[^A-Za-z0-9._-]"), "_")

    fun localMediaURL(id: String): String? {
        val stem = safeFileStem(id)
        val dir = vaultDir
        for (ext in listOf("mp4", "mov", "m4v", "gif", "jpg", "jpeg", "png", "webp")) {
            val f = File(dir, "$stem.$ext")
            if (f.exists() && f.length() > 0) return "file://${f.absolutePath}"
        }
        return null
    }

    fun isDownloaded(gif: Gif): Boolean = localMediaURL(gif.id) != null

    fun toggleDownload(gif: Gif) {
        if (isDownloaded(gif)) {
            removeDownload(gif)
        } else {
            scope.launch { download(gif) }
        }
    }

    suspend fun download(gif: Gif) {
        if (gif.id in activeDownloads.value) return
        activeDownloads.value = activeDownloads.value + gif.id
        lastError.value = null
        try {
            if (gif.isLongVideoPost) {
                LongVideoAPI.resolvePlayableURLs(gif)
            }
            val hd = UserStore.shared.data.value.settings.hd
            val candidates = gif.allVideoURLs(hd).filter { !it.lowercase().contains(".m3u8") }.toMutableList()
            if (candidates.isEmpty()) {
                gif.imageURL?.let { candidates.add(it) }
            }
            if (candidates.isEmpty()) {
                MediaMetaRegistry.albumItems(gif.id).firstOrNull()?.url?.let { candidates.add(it) }
            }
            if (candidates.isEmpty()) {
                lastError.value = "No downloadable media URL available."
                return
            }

            var savedFile: File? = null
            for (u in candidates) {
                if (u.startsWith("file://")) continue
                val ext = u.substringAfterLast('.', "").substringBefore('?').lowercase()
                    .takeIf { it in setOf("mp4", "mov", "m4v", "gif", "jpg", "jpeg", "png", "webp") }
                    ?: if (gif.isImage) "jpg" else "mp4"
                val dest = File(vaultDir, "${safeFileStem(gif.id)}.$ext")
                val ok = downloadToFile(u, dest)
                if (ok) {
                    savedFile = dest
                    break
                }
            }
            if (savedFile != null) {
                val localPost = gif.copy(
                    mediaUrl = "file://${savedFile.absolutePath}",
                    muxedUrl = "file://${savedFile.absolutePath}",
                    muxedUrlHd = "file://${savedFile.absolutePath}"
                )
                withContext(Dispatchers.Main) {
                    UserStore.shared.recordDownloaded(localPost)
                }
                refreshDiskUsage()
            } else {
                lastError.value = "Download failed. Try again."
            }
        } finally {
            activeDownloads.value = activeDownloads.value - gif.id
        }
    }

    private fun downloadToFile(url: String, dest: File): Boolean {
        for (useRef in listOf(true, false)) {
            try {
                val rb = Request.Builder().url(url)
                for ((k, v) in MediaHeaders.headers(url, includeReferer = useRef)) {
                    rb.header(k, v)
                }
                client.newCall(rb.build()).execute().use { resp ->
                    if (resp.isSuccessful) {
                        val body = resp.body
                        if (body != null) {
                            val tmp = File(dest.parentFile, dest.name + ".part")
                            FileOutputStream(tmp).use { out ->
                                body.byteStream().copyTo(out)
                            }
                            if (tmp.length() > 1024) {
                                tmp.renameTo(dest)
                                return true
                            } else {
                                tmp.delete()
                            }
                        }
                    }
                }
            } catch (_: Throwable) {}
        }
        return false
    }

    private fun saveToMediaStoreGallery(file: File, isVideo: Boolean) {
        try {
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
                put(MediaStore.MediaColumns.MIME_TYPE, if (isVideo) "video/mp4" else "image/jpeg")
                if (Build.VERSION.SDK_INT >= 29) {
                    put(
                        MediaStore.MediaColumns.RELATIVE_PATH,
                        (if (isVideo) Environment.DIRECTORY_MOVIES else Environment.DIRECTORY_PICTURES) + "/TinyTiny"
                    )
                }
            }
            val uri = resolver.insert(collection, values) ?: return
            resolver.openOutputStream(uri)?.use { out ->
                file.inputStream().use { it.copyTo(out) }
            }
        } catch (_: Throwable) {}
    }

    fun removeDownload(gif: Gif) {
        val stem = safeFileStem(gif.id)
        val dir = vaultDir
        for (ext in listOf("mp4", "mov", "m4v", "gif", "jpg", "jpeg", "png", "webp")) {
            File(dir, "$stem.$ext").delete()
        }
        UserStore.shared.removeDownloaded(gif.id)
        refreshDiskUsage()
    }

    fun clearAllDownloads() {
        vaultDir.listFiles()?.forEach { it.delete() }
        UserStore.shared.clearAllDownloaded()
        refreshDiskUsage()
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
