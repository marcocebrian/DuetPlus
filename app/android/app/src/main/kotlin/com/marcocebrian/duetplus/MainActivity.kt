package com.marcocebrian.duetplus

import android.os.Handler
import android.os.Looper
import com.yausername.youtubedl_android.YoutubeDL
import com.yausername.youtubedl_android.YoutubeDLRequest
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.io.File

/**
 * Bridge to yt-dlp (youtubedl-android: Python 3.11 + yt-dlp + QuickJS).
 * Methods: init, update, download {url, dir, name, id}, cancel {id}.
 * Progress is pushed back as "progress" {id, p (0..1)}.
 */
class MainActivity : FlutterActivity() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val main = Handler(Looper.getMainLooper())
    private val initLock = Mutex()
    private var ready = false
    private lateinit var channel: MethodChannel

    private suspend fun ensureInit() = initLock.withLock {
        if (!ready) {
            YoutubeDL.getInstance().init(applicationContext)
            ready = true
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "duet/ytdlp")
        channel.setMethodCallHandler { call, result ->
            fun ok(v: Any?) = main.post { result.success(v) }
            fun fail(e: Throwable) {
                // Full detail: exception chain + top frames (was just "e").
                val chain = generateSequence(e) { it.cause }.take(4)
                    .joinToString(" <- ") { "${it.javaClass.name}: ${it.message ?: ""}" }
                val frames = e.stackTrace.take(6).joinToString("\n") { "  at $it" }
                android.util.Log.e("duet-ytdlp", chain, e)
                main.post { result.error("ytdlp", chain, frames) }
            }
            when (call.method) {
                "init" -> scope.launch {
                    try {
                        ensureInit()
                        ok(YoutubeDL.getInstance().version(applicationContext))
                    } catch (e: Throwable) { fail(e) }
                }
                "update" -> scope.launch {
                    try {
                        ensureInit()
                        val st = YoutubeDL.getInstance().updateYoutubeDL(applicationContext, YoutubeDL.UpdateChannel.STABLE)
                        ok("${st?.name}:${YoutubeDL.getInstance().version(applicationContext)}")
                    } catch (e: Throwable) { fail(e) }
                }
                "download" -> scope.launch {
                    val url = call.argument<String>("url")!!
                    val dir = call.argument<String>("dir")!!
                    val name = call.argument<String>("name")!!
                    val id = call.argument<String>("id") ?: name
                    try {
                        ensureInit()
                        File(dir).mkdirs()
                        File(dir).listFiles { f -> f.name.startsWith("$name.") }?.forEach { it.delete() }
                        val req = YoutubeDLRequest(url).apply {
                            // Opus/WebM (itag 251) first: every phone decodes it identically.
                            addOption("-f", "251/bestaudio[ext=webm]/bestaudio")
                            addOption("-o", "$dir/$name.%(ext)s")
                            addOption("--no-playlist")
                            addOption("--no-part")
                            addOption("--no-mtime")
                        }
                        YoutubeDL.getInstance().execute(req, id) { p, _, _ ->
                            main.post { channel.invokeMethod("progress", mapOf("id" to id, "p" to (p / 100.0))) }
                        }
                        val f = File(dir).listFiles { x -> x.name.startsWith("$name.") }?.maxByOrNull { it.length() }
                        if (f == null || f.length() == 0L) fail(IllegalStateException("yt-dlp produced no file"))
                        else ok(f.absolutePath)
                    } catch (e: Throwable) { fail(e) }
                }
                "cancel" -> {
                    val id = call.argument<String>("id")
                    result.success(id != null && YoutubeDL.getInstance().destroyProcessById(id))
                }
                else -> result.notImplemented()
            }
        }
    }
}
