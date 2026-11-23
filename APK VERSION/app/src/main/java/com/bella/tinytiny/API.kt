package com.bella.tinytiny

import android.util.Base64
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.Request
import org.json.JSONArray
import org.json.JSONObject
import java.net.URLEncoder
import java.util.UUID

class APIException(val code: Int, message: String) : Exception(message)

object GoonedAPI {
    private val client = TinyTinyApplication.sharedHttpClient

    private suspend fun <T> get(
        path: String,
        query: Map<String, String> = emptyMap(),
        decode: (String) -> T
    ): T = withContext(Dispatchers.IO) {
        val base = (Config.goonedBase + path).toHttpUrlOrNull() ?: throw APIException(0, "Bad URL")
        val ub = base.newBuilder()
        for ((k, v) in query) ub.addQueryParameter(k, v)
        val req = Request.Builder()
            .url(ub.build())
            .header("User-Agent", Config.userAgent)
            .header("Accept", "application/json")
            .header("Origin", Config.origin)
            .header("Referer", Config.referer)
            .header("Cache-Control", "no-cache")
            .build()
        client.newCall(req).execute().use { resp ->
            if (!resp.isSuccessful) throw APIException(resp.code, "Server error (${resp.code})")
            val body = resp.body?.string() ?: throw APIException(resp.code, "Empty response")
            decode(body)
        }
    }

    private fun encPath(s: String): String = URLEncoder.encode(s, "UTF-8").replace("+", "%20")

    fun randomForYouCursor(offset: Int = 0): String {
        val seed = UUID.randomUUID().toString().replace("-", "").lowercase().take(10)
        val json = """{"seed":"$seed","offset":$offset}"""
        return Base64.encodeToString(json.toByteArray(Charsets.UTF_8), Base64.NO_WRAP)
    }

    fun categoryExclusionCursor(seenIDs: List<String>): String? {
        val clean = seenIDs.filter { !it.startsWith("x_") }.take(120)
        if (clean.isEmpty()) return null
        val payload = JSONObject().apply {
            put("categoryPool", JSONObject().apply {
                put("from", JSONObject.NULL)
                put("head", JSONArray(clean))
            })
        }
        return Base64.encodeToString(payload.toString().toByteArray(Charsets.UTF_8), Base64.NO_WRAP)
    }

    suspend fun forYou(sort: String = "hot", time: String = "all", after: String? = null, limit: Int = 25): GoonedFeedResponse {
        val q = mutableMapOf("sort" to sort, "limit" to "$limit")
        if (sort == "top") q["t"] = time
        q["after"] = if (!after.isNullOrEmpty()) after else randomForYouCursor(0)
        return get("/reddit/foryou", q) { CryptoBox.json.decodeFromString(it) }
    }

    suspend fun category(
        name: String,
        sort: String = "hot",
        time: String = "all",
        after: String? = null,
        excludedHead: List<String> = emptyList(),
        limit: Int = 25
    ): GoonedFeedResponse {
        val q = mutableMapOf("sort" to sort, "limit" to "$limit")
        if (sort == "top") q["t"] = time
        if (!after.isNullOrEmpty()) {
            q["after"] = after
        } else {
            categoryExclusionCursor(excludedHead)?.let { q["after"] = it }
        }
        return get("/reddit/category/${encPath(name)}", q) { CryptoBox.json.decodeFromString(it) }
    }

    suspend fun subreddit(name: String, sort: String = "hot", time: String = "all", after: String? = null, limit: Int = 25): GoonedFeedResponse {
        val clean = name.replace("r/", "", ignoreCase = true).replace("/", "").trim()
        val q = mutableMapOf("sort" to sort, "limit" to "$limit")
        if (sort == "top") q["t"] = time
        if (!after.isNullOrEmpty()) q["after"] = after
        return get("/reddit/subreddit/${encPath(clean)}", q) { CryptoBox.json.decodeFromString(it) }
    }

    suspend fun user(username: String, sort: String = "hot", time: String = "all", after: String? = null, limit: Int = 25): GoonedFeedResponse {
        val clean = username.replace("u/", "", ignoreCase = true).replace("@", "").replace("/", "").trim()
        val q = mutableMapOf("sort" to sort, "limit" to "$limit")
        if (sort == "top") q["t"] = time
        if (!after.isNullOrEmpty()) q["after"] = after
        return get("/reddit/user/${encPath(clean)}", q) { CryptoBox.json.decodeFromString(it) }
    }

    suspend fun following(subreddits: List<String>, users: List<String>, after: String? = null): GoonedFeedResponse {
        val q = mutableMapOf<String, String>()
        if (subreddits.isNotEmpty()) q["subreddits"] = subreddits.joinToString(",")
        if (users.isNotEmpty()) q["users"] = users.joinToString(",")
        if (!after.isNullOrEmpty()) q["after"] = after
        return get("/reddit/following", q) { CryptoBox.json.decodeFromString(it) }
    }

    suspend fun search(query: String): GoonedSearchResponse {
        val clean = query.replace("r/", "", ignoreCase = true)
            .replace("u/", "", ignoreCase = true)
            .replace("@", "")
            .trim()
        if (clean.isEmpty()) return GoonedSearchResponse()
        return get("/reddit/search", mapOf("q" to clean)) { CryptoBox.json.decodeFromString(it) }
    }

    suspend fun categories(): List<GoonedCategory> {
        val resp = get("/reddit/categories") { CryptoBox.json.decodeFromString<GoonedCategoriesResponse>(it) }
        val list = resp.categories.map { (k, v) -> GoonedCategory(k, v.subscribers, v.subreddits) }
        return list.ifEmpty { GoonedCategory.defaultCategories }
    }
}
