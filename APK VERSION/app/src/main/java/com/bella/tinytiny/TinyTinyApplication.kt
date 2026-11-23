package com.bella.tinytiny

import android.app.Application
import android.os.Build
import coil.ImageLoader
import coil.ImageLoaderFactory
import coil.decode.GifDecoder
import coil.decode.ImageDecoderDecoder
import okhttp3.OkHttpClient
import java.util.concurrent.TimeUnit

class TinyTinyApplication : Application(), ImageLoaderFactory {
    companion object {
        lateinit var instance: TinyTinyApplication
            private set

        val sharedHttpClient: OkHttpClient by lazy {
            OkHttpClient.Builder()
                .connectTimeout(18, TimeUnit.SECONDS)
                .readTimeout(25, TimeUnit.SECONDS)
                .writeTimeout(25, TimeUnit.SECONDS)
                .followRedirects(true)
                .build()
        }
    }

    override fun onCreate() {
        super.onCreate()
        instance = this
    }

    override fun newImageLoader(): ImageLoader {
        val headerClient = sharedHttpClient.newBuilder()
            .addInterceptor { chain ->
                val req = chain.request()
                val headers = MediaHeaders.headers(req.url.toString(), includeReferer = true)
                val b = req.newBuilder()
                for ((k, v) in headers) {
                    if (req.header(k) == null) b.header(k, v)
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
