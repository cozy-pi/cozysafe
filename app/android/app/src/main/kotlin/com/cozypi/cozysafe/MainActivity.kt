package com.cozypi.cozysafe

import android.content.ContentUris
import android.net.Uri
import android.os.Build
import android.os.Bundle
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

class MainActivity : FlutterFragmentActivity() {
    // "cozysafe/originals" (lib/originals.dart): pick photos, videos or files keeping
    // where each came from, so that after they are encrypted into the vault the person can
    // remove the originals. Android itself asks before anything is deleted.
    private var pickResult: MethodChannel.Result? = null
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
        MethodChannel(messenger, "cozysafe/privacy").setMethodCallHandler { call, result ->
            if (call.method == "setSecure") {
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
        MethodChannel(messenger, "cozysafe/originals").setMethodCallHandler { call, result ->
            when (call.method) {
                "pickMedia" -> {
                    pickResult = result
                    pickMedia.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageAndVideo))
                }
                "pickFiles" -> {
                    pickResult = result
                    pickDocs.launch(arrayOf("*/*"))
                }
                "delete" -> delete(call.argument<List<String>>("ids") ?: emptyList(), result)
                "release" -> result.success(null)
                else -> result.notImplemented()
            }
        }
    }

    /// Copy each picked item into the app's cache (the vault encrypts from there; the copy
    /// is deleted right after) and say where it came from.
    private fun deliver(uris: List<Uri>) {
        val result = pickResult ?: return
        pickResult = null
        Thread {
            val out = mutableListOf<Map<String, String>>()
            val dir = File(cacheDir, "pick").apply { mkdirs() }
            for (uri in uris) {
                try {
                    var name = "file"
                    contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
                        if (c.moveToFirst() && !c.isNull(0)) name = c.getString(0)
                    }
                    val safe = name.replace('/', '-')
                    val copy = File(dir, "${System.nanoTime()}-$safe")
                    contentResolver.openInputStream(uri)?.use { input -> copy.outputStream().use { input.copyTo(it) } }
                    out.add(mapOf(
                        "path" to copy.path,
                        "name" to safe,
                        "mime" to (contentResolver.getType(uri) ?: ""),
                        "id" to uri.toString(),
                    ))
                } catch (e: Exception) {
                    // Not readable: left out, like a cancelled pick.
                }
            }
            runOnUiThread { result.success(out) }
        }.start()
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
}
