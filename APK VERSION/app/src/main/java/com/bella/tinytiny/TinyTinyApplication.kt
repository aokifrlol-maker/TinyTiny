package com.bella.tinytiny

import android.app.Application
import android.os.Build
import android.webkit.CookieManager
import androidx.annotation.OptIn
import androidx.media3.common.util.UnstableApi
import androidx.media3.database.StandaloneDatabaseProvider
import androidx.media3.datasource.cache.LeastRecentlyUsedCacheEvictor
import androidx.media3.datasource.cache.SimpleCache
import coil.ImageLoader
import coil.ImageLoaderFactory
import coil.decode.GifDecoder
import coil.decode.ImageDecoderDecoder
import okhttp3.Cache
import okhttp3.OkHttpClient
import java.io.File
import java.util.concurrent.TimeUnit

class TinyTinyApplication : Application(), ImageLoaderFactory {
    companion object {
        lateinit var instance: TinyTinyApplication
            private set

        val sharedHttpClient: OkHttpClient by lazy {
            val cacheDir = File(instance.cacheDir, "http_cache").apply { mkdirs() }
            OkHttpClient.Builder()
                .cache(Cache(cacheDir, 150L * 1024L * 1024L))
                .connectTimeout(18, TimeUnit.SECONDS)
                .readTimeout(25, TimeUnit.SECONDS)
                .writeTimeout(25, TimeUnit.SECONDS)
                .followRedirects(true)
                .followSslRedirects(true)
                .build()
        }

        val longTransferHttpClient: OkHttpClient by lazy {
            OkHttpClient.Builder()
                .connectTimeout(20, TimeUnit.SECONDS)
                .readTimeout(180, TimeUnit.SECONDS)
                .writeTimeout(180, TimeUnit.SECONDS)
                .followRedirects(true)
                .followSslRedirects(true)
                .build()
        }

        @OptIn(UnstableApi::class)
        val mediaSimpleCache: SimpleCache by lazy {
            val cacheDir = File(instance.cacheDir, "exo_media_cache").apply { mkdirs() }
            SimpleCache(
                cacheDir,
                LeastRecentlyUsedCacheEvictor(250L * 1024L * 1024L),
                StandaloneDatabaseProvider(instance)
            )
        }
    }

    override fun onCreate() {
        super.onCreate()
        instance = this
        // Warm up ExoPlayer SQLite SimpleCache & OfflineManager index off the main thread
        Thread {
            try { mediaSimpleCache } catch (_: Throwable) {}
            try { OfflineManager.localMediaURL("__warmup__") } catch (_: Throwable) {}
        }.start()
    }

    override fun newImageLoader(): ImageLoader {
        val headerClient = sharedHttpClient.newBuilder()
            .cache(null)
            .addInterceptor { chain ->
                val req = chain.request()
                val urlStr = req.url.toString()
                val headers = MediaHeaders.headers(urlStr, includeReferer = true)
                val b = req.newBuilder()
                for ((k, v) in headers) {
                    if (req.header(k) == null) b.header(k, v)
                }
                if (req.header("Cookie") == null) {
                    try {
                        val cookies = CookieManager.getInstance().getCookie(urlStr)
                        if (!cookies.isNullOrEmpty()) b.header("Cookie", cookies)
                    } catch (_: Throwable) {}
                }
                chain.proceed(b.build())
            }
            .build()

        return ImageLoader.Builder(this)
            .okHttpClient(headerClient)
            .components {
                if (Build.VERSION.SDK_INT >= 28) {
                    add(ImageDecoderDecoder.Factory())
                } else {
                    add(GifDecoder.Factory())
                }
            }
            .crossfade(true)
            .build()
    }
}
