package com.cozypi.cozysafe

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Handler
import android.os.Looper
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.InputStream

/** Pictures are decoded at most this many pixels on their longer side. */
private const val MAX_SIDE = 2000
/** A picked image larger than this is not read. */
private const val MAX_BYTES = 64 shl 20

/** "cozysafe/qr" (2FA setup): one picture from the system photo picker, decoded in memory
 *  and handed to Dart as its brightness plane (8 bits a pixel); Dart reads the QR code
 *  with the app's own Rust decoder (rqrr, `qrReadText`), as it does for camera frames.
 *  Nothing is written to a file and nothing is logged. Made in onCreate (it registers
 *  the picker). */
class QrCode(private val activity: FlutterFragmentActivity) {
    private val main = Handler(Looper.getMainLooper())
    private var pickResult: MethodChannel.Result? = null
    // The system photo picker: one image, no permission to read the library.
    private val pick: ActivityResultLauncher<PickVisualMediaRequest> =
        activity.registerForActivityResult(ActivityResultContracts.PickVisualMedia()) { picked(it) }

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            // null: cancelled; {luma, width, height}: the picture (width 0: unreadable).
            "pickImage" -> {
                pickResult?.success(null)
                pickResult = result
                try {
                    pick.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
                } catch (_: Throwable) {
                    pickResult = null
                    result.success(null)
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun picked(uri: Uri?) {
        val result = pickResult ?: return
        pickResult = null
        if (uri == null) return result.success(null)
        // One short-lived thread per picture: nothing is left running after it.
        Thread {
            val plane = try {
                activity.contentResolver.openInputStream(uri)?.use { readCapped(it) }?.let { luma(it) }
            } catch (_: Throwable) {
                null
            }
            val answer: Map<String, Any> = plane ?: mapOf("luma" to ByteArray(0), "width" to 0, "height" to 0)
            main.post { result.success(answer) }
        }.start()
    }

    private fun readCapped(input: InputStream): ByteArray? {
        val out = ByteArrayOutputStream()
        val buffer = ByteArray(64 * 1024)
        while (true) {
            val n = input.read(buffer)
            if (n < 0) break
            out.write(buffer, 0, n)
            if (out.size() > MAX_BYTES) return null
        }
        return out.toByteArray()
    }

    /** A picture in memory (JPEG, PNG, HEIF…), scaled down to [MAX_SIDE], as grey bytes. */
    private fun luma(bytes: ByteArray): Map<String, Any>? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        var sample = 1
        while (maxOf(bounds.outWidth, bounds.outHeight) / sample > MAX_SIDE) sample *= 2
        val options = BitmapFactory.Options().apply {
            inSampleSize = sample
            inPreferredConfig = Bitmap.Config.ARGB_8888
        }
        val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options) ?: return null
        val w = bitmap.width
        val h = bitmap.height
        val pixels = IntArray(w * h)
        bitmap.getPixels(pixels, 0, w, 0, 0, w, h)
        bitmap.recycle()
        val grey = ByteArray(w * h)
        for (i in pixels.indices) {
            val p = pixels[i]
            val r = (p shr 16) and 0xff
            val g = (p shr 8) and 0xff
            val b = p and 0xff
            // ITU-R BT.601 weights, in integers; a transparent pixel reads as white.
            val a = (p ushr 24) and 0xff
            val y = (77 * r + 150 * g + 29 * b) shr 8
            grey[i] = (255 - ((255 - y) * a) / 255).toByte()
        }
        return mapOf("luma" to grey, "width" to w, "height" to h)
    }
}
