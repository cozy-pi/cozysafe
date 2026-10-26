package com.cozypi.cozysafe

import android.app.LocaleManager
import android.content.ContentUris
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.LocaleList
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.view.WindowManager
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.IntentSenderRequest
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/** The foreground service that keeps a sync going with the phone locked: off until Google
 *  Play's declaration is filed (AndroidManifest.xml has its permissions commented out). */
private const val SYNC_SERVICE = false

class MainActivity : FlutterFragmentActivity() {
    // "cozysafe/originals" (lib/originals.dart): pick photos, videos or files keeping
    // where each came from, so that after they are encrypted into the vault the person can
    // remove the originals. Android itself asks before anything is deleted.
    private var pickResult: MethodChannel.Result? = null
    private var originals: MethodChannel? = null
    private var pickSession = 0
    @Volatile private var copyStopped = false
    private var deleteResult: MethodChannel.Result? = null
    private var pendingDocDeleted = 0
    private var pendingFailed = 0
    private var pendingMedia = 0
    private lateinit var pickMedia: ActivityResultLauncher<PickVisualMediaRequest>
    private lateinit var pickDocs: ActivityResultLauncher<Array<String>>
    private lateinit var confirmDelete: ActivityResultLauncher<IntentSenderRequest>

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Hide the vault from the recent-apps preview and from screenshots
        // (docs/ui.md, review 2). Settings can turn it off ("cozysafe/privacy").
        window.setFlags(WindowManager.LayoutParams.FLAG_SECURE, WindowManager.LayoutParams.FLAG_SECURE)
        // Recent apps never show the vault, even with screenshots allowed: with "Lock as
        // soon as I leave the app" off it stays open behind that preview (Android 13+).
        if (Build.VERSION.SDK_INT >= 33) setRecentsScreenshotEnabled(false)
        // The system photo picker: no permission to read the whole library.
        pickMedia = registerForActivityResult(ActivityResultContracts.PickMultipleVisualMedia(100)) { deliver(it) }
        pickDocs = registerForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { deliver(it) }
        confirmDelete = registerForActivityResult(ActivityResultContracts.StartIntentSenderForResult()) { r ->
            val ok = r.resultCode == RESULT_OK
            finishDelete(
                deleted = pendingDocDeleted + if (ok) pendingMedia else 0,
                failed = pendingFailed,
                cancelled = !ok,
            )
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        // While a sync runs (lib/sync/awake.dart): the screen stays on, and a foreground
        // service with a notification (SyncService) keeps it going with the phone locked.
        MethodChannel(messenger, "cozysafe/awake").setMethodCallHandler { call, result ->
            when (call.method) {
                "set" -> {
                    if (call.arguments as? Boolean == true) {
                        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    } else {
                        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        if (SYNC_SERVICE) SyncService.stop(this)
                    }
                    result.success(null)
                }
                "progress" -> {
                    if (!SYNC_SERVICE) return@setMethodCallHandler result.success(null)
                    askNotifications()
                    SyncService.show(
                        this,
                        call.argument<String>("title") ?: "",
                        call.argument<String>("text") ?: "",
                        call.argument<String>("channel") ?: "",
                        call.argument<Number>("done")?.toInt() ?: 0,
                        call.argument<Number>("total")?.toInt() ?: 0,
                    )
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(messenger, "cozysafe/privacy").setMethodCallHandler { call, result ->
            if (call.method == "openUrl") {
                // Our own pages only (lib/links.dart); the system opens the browser.
                val uri = Uri.parse(call.arguments as? String ?: "")
                if (uri.scheme != "https" || uri.host != "safe.cozypi.com") return@setMethodCallHandler result.success(false)
                try {
                    startActivity(Intent(Intent.ACTION_VIEW, uri))
                    result.success(true)
                } catch (e: Exception) {
                    result.success(false)
                }
            } else if (call.method == "openExternal") {
                // A link tapped in a note, after the person confirmed its host (lib/links.dart,
                // docs/security.md): http or https with a host, nothing else (no intent:,
                // file:, javascript: or app schemes), and only to a browsable app.
                val uri = Uri.parse(call.arguments as? String ?: "")
                val scheme = uri.scheme?.lowercase()
                if ((scheme != "https" && scheme != "http") || uri.host.isNullOrEmpty()) {
                    return@setMethodCallHandler result.success(false)
                }
                try {
                    startActivity(Intent(Intent.ACTION_VIEW, uri).addCategory(Intent.CATEGORY_BROWSABLE))
                    result.success(true)
                } catch (e: Exception) {
                    result.success(false)
                }
            } else if (call.method == "setSecure") {
                if (call.arguments == true) {
                    window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                } else {
                    window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                }
                result.success(null)
            } else {
                result.notImplemented()
            }
        }
        // The app's own language (lib/language.dart), the same value as Settings → Apps →
        // Cozy Safe → Language. Android 13+ only; null tells Dart to keep its own pref.
        MethodChannel(messenger, "cozysafe/language").setMethodCallHandler { call, result ->
            if (Build.VERSION.SDK_INT < 33) return@setMethodCallHandler result.success(null)
            val manager = getSystemService(LocaleManager::class.java)
            when (call.method) {
                "get" -> result.success(manager.applicationLocales.takeIf { !it.isEmpty }?.toLanguageTags())
                "set" -> {
                    val tag = call.argument<String>("tag") ?: ""
                    // Applied at once: the activity handles locale changes itself.
                    manager.applicationLocales = LocaleList.forLanguageTags(tag)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
        // Thumbnails for imported photos, made by the platform's decoder at the small size
        // directly (lib/screens/file_view.dart imageThumbnail): several at once, off the UI
        // thread. Pixels stay in memory; the JPEG goes back to Dart and is sealed there.
        MethodChannel(messenger, "cozysafe/media").setMethodCallHandler { call, result ->
            if (call.method == "decode") {
                // A photo to show that Flutter may not decode here (an iPhone's HEIC): the
                // platform decodes it in memory and hands back a JPEG; nothing is written.
                val bytes = call.argument<ByteArray>("bytes") ?: return@setMethodCallHandler result.success(null)
                val max = call.argument<Int>("maxSide") ?: 4096
                val main = android.os.Handler(android.os.Looper.getMainLooper())
                thumbnailPool.execute {
                    val jpeg = try { decodedJpeg(bytes, max) } catch (_: Throwable) { null }
                    main.post { result.success(jpeg) }
                }
                return@setMethodCallHandler
            }
            if (call.method != "thumbnail") return@setMethodCallHandler result.notImplemented()
            val path = call.argument<String>("path") ?: return@setMethodCallHandler result.success(null)
            val side = call.argument<Int>("shortSide") ?: 320
            val main = android.os.Handler(android.os.Looper.getMainLooper())
            thumbnailPool.execute {
                val bytes = try { thumbnailJpeg(path, side) } catch (_: Throwable) { null }
                main.post { result.success(bytes) }
            }
        }
        originals = MethodChannel(messenger, "cozysafe/originals").apply { setMethodCallHandler { call, result ->
            when (call.method) {
                "pickMedia" -> {
                    pickResult = result
                    pickSession = call.argument<Int>("session") ?: 0
                    pickMedia.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageAndVideo))
                }
                "pickFiles" -> {
                    pickResult = result
                    pickSession = call.argument<Int>("session") ?: 0
                    pickDocs.launch(arrayOf("*/*"))
                }
                "stopCopy" -> {
                    copyStopped = true
                    result.success(null)
                }
                "delete" -> delete(call.argument<List<String>>("ids") ?: emptyList(), result)
                "release" -> result.success(null)
                else -> result.notImplemented()
            }
        } }
    }

    private var askedNotifications = false

    /// Android 13+: the sync notification needs the person's yes. Asked when a sync
    /// starts, once per launch; if they say no the sync still keeps running, only the
    /// notification is hidden.
    private fun askNotifications() {
        if (Build.VERSION.SDK_INT < 33 || askedNotifications) return
        askedNotifications = true
        if (checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) return
        requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 7302)
    }

    override fun onDestroy() {
        // The app is closing (not just turning): no sync is left to keep alive.
        if (isFinishing && SYNC_SERVICE) SyncService.stop(this)
        super.onDestroy()
    }

    /// Copy each picked item into the app's cache (the vault encrypts from there; the copy
    /// is deleted right after) and say where it came from.
    private fun deliver(uris: List<Uri>) {
        val result = pickResult ?: return
        pickResult = null
        // The count first, then each file as soon as it is copied, so the vault encrypts
        // while the rest are still being copied (owner 2026-10-23). Three at a time.
        result.success(uris.size)
        if (uris.isEmpty()) return
        copyStopped = false
        val session = pickSession
        val dir = File(cacheDir, "pick").apply { mkdirs() }
        val pool = java.util.concurrent.Executors.newFixedThreadPool(3)
        for (uri in uris) pool.execute {
            val item = mutableMapOf<String, Any>("session" to session)
            val started = System.nanoTime()
            if (!copyStopped) try {
                var name = "file"
                contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
                    if (c.moveToFirst() && !c.isNull(0)) name = c.getString(0)
                }
                val safe = name.replace('/', '-')
                val copy = File(dir, "${System.nanoTime()}-$safe")
                contentResolver.openInputStream(uri)?.use { input -> copy.outputStream().use { input.copyTo(it) } }
                item.putAll(mapOf(
                    "path" to copy.path,
                    "name" to safe,
                    "mime" to (contentResolver.getType(uri) ?: ""),
                    "id" to uri.toString(),
                    "ms" to ((System.nanoTime() - started) / 1_000_000).toInt(),
                ))
            } catch (e: Exception) {
                // Not readable: sent without a path, and left out.
            }
            runOnUiThread { originals?.invokeMethod("copied", item) }
        }
        pool.shutdown()
    }

    /// A MediaStore item behind a photo-picker or media-documents URI, so Android can ask
    /// to delete it without this app reading the whole library.
    private fun mediaStoreUri(uri: Uri): Uri? {
        val type = contentResolver.getType(uri) ?: ""
        val collection = when {
            type.startsWith("video/") -> MediaStore.Video.Media.EXTERNAL_CONTENT_URI
            type.startsWith("image/") -> MediaStore.Images.Media.EXTERNAL_CONTENT_URI
            else -> return null
        }
        val id = when {
            uri.authority == "media" && uri.pathSegments.contains("picker") -> uri.lastPathSegment?.toLongOrNull()
            uri.authority == "com.android.providers.media.documents" ->
                DocumentsContract.getDocumentId(uri).substringAfter(':').toLongOrNull()
            uri.authority == "media" -> uri.lastPathSegment?.toLongOrNull()
            else -> null
        } ?: return null
        return ContentUris.withAppendedId(collection, id)
    }

    private fun delete(ids: List<String>, result: MethodChannel.Result) {
        if (deleteResult != null) return result.error("busy", null, null)
        deleteResult = result
        pendingDocDeleted = 0
        pendingFailed = 0
        val media = mutableListOf<Uri>()
        for (s in ids) {
            val uri = Uri.parse(s)
            val m = if (Build.VERSION.SDK_INT >= 30) mediaStoreUri(uri) else null
            if (m != null) {
                media.add(m)
                continue
            }
            try {
                if (DocumentsContract.deleteDocument(contentResolver, uri)) pendingDocDeleted++ else pendingFailed++
            } catch (e: Exception) {
                pendingFailed++
            }
        }
        if (media.isEmpty() || Build.VERSION.SDK_INT < 30) {
            return finishDelete(pendingDocDeleted, pendingFailed, false)
        }
        try {
            // Android shows the items and asks; they go to its trash where it has one.
            val ask = MediaStore.createDeleteRequest(contentResolver, media)
            pendingMedia = media.size
            confirmDelete.launch(IntentSenderRequest.Builder(ask.intentSender).build())
        } catch (e: Exception) {
            finishDelete(pendingDocDeleted, pendingFailed + media.size, false)
        }
    }

    private fun finishDelete(deleted: Int, failed: Int, cancelled: Boolean) {
        val result = deleteResult ?: return
        deleteResult = null
        pendingMedia = 0
        result.success(mapOf("deleted" to deleted, "failed" to failed, "cancelled" to cancelled))
    }

    private val thumbnailPool = java.util.concurrent.Executors.newFixedThreadPool(3)

    /// A JPEG whose shorter side is about [side] pixels, upright. ImageDecoder (Android 9+)
    /// decodes straight at the target size; older phones subsample with BitmapFactory and
    /// turn the picture by its EXIF orientation.
    /// [bytes] (a picture in memory) as a JPEG at most [maxSide] px on its longer side,
    /// turned upright. Android 9+ (ImageDecoder reads HEIF); null before that.
    private fun decodedJpeg(bytes: ByteArray, maxSide: Int): ByteArray? {
        if (Build.VERSION.SDK_INT < 28) return null
        val source = android.graphics.ImageDecoder.createSource(java.nio.ByteBuffer.wrap(bytes))
        val bitmap = android.graphics.ImageDecoder.decodeBitmap(source) { decoder, info, _ ->
            val w = info.size.width
            val h = info.size.height
            val scale = maxSide.toFloat() / maxOf(w, h)
            if (scale < 1f) decoder.setTargetSize(maxOf(1, (w * scale).toInt()), maxOf(1, (h * scale).toInt()))
            decoder.allocator = android.graphics.ImageDecoder.ALLOCATOR_SOFTWARE
        }
        val out = java.io.ByteArrayOutputStream()
        bitmap.compress(android.graphics.Bitmap.CompressFormat.JPEG, 92, out)
        bitmap.recycle()
        return out.toByteArray()
    }

    private fun thumbnailJpeg(path: String, side: Int): ByteArray? {
        val bitmap: android.graphics.Bitmap = if (Build.VERSION.SDK_INT >= 28) {
            val source = android.graphics.ImageDecoder.createSource(java.io.File(path))
            android.graphics.ImageDecoder.decodeBitmap(source) { decoder, info, _ ->
                val w = info.size.width
                val h = info.size.height
                val scale = side.toFloat() / minOf(w, h)
                if (scale < 1f) decoder.setTargetSize(maxOf(1, (w * scale).toInt()), maxOf(1, (h * scale).toInt()))
                decoder.allocator = android.graphics.ImageDecoder.ALLOCATOR_SOFTWARE
            }
        } else {
            val bounds = android.graphics.BitmapFactory.Options().apply { inJustDecodeBounds = true }
            android.graphics.BitmapFactory.decodeFile(path, bounds)
            if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
            var sample = 1
            while (minOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= side) sample *= 2
            val decoded = android.graphics.BitmapFactory.decodeFile(
                path, android.graphics.BitmapFactory.Options().apply { inSampleSize = sample }
            ) ?: return null
            val degrees = when (android.media.ExifInterface(path).getAttributeInt(
                android.media.ExifInterface.TAG_ORIENTATION, android.media.ExifInterface.ORIENTATION_NORMAL
            )) {
                android.media.ExifInterface.ORIENTATION_ROTATE_90 -> 90f
                android.media.ExifInterface.ORIENTATION_ROTATE_180 -> 180f
                android.media.ExifInterface.ORIENTATION_ROTATE_270 -> 270f
                else -> 0f
            }
            if (degrees == 0f) decoded else android.graphics.Bitmap.createBitmap(
                decoded, 0, 0, decoded.width, decoded.height,
                android.graphics.Matrix().apply { postRotate(degrees) }, true
            )
        }
        val out = java.io.ByteArrayOutputStream()
        bitmap.compress(android.graphics.Bitmap.CompressFormat.JPEG, 80, out)
        bitmap.recycle()
        return out.toByteArray()
    }
}
