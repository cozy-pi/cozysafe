package com.cozypi.cozysafe

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Handler
import android.os.Looper
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import com.google.zxing.Binarizer
import com.google.zxing.BinaryBitmap
import com.google.zxing.DecodeHintType
import com.google.zxing.LuminanceSource
import com.google.zxing.PlanarYUVLuminanceSource
import com.google.zxing.RGBLuminanceSource
import com.google.zxing.ReaderException
import com.google.zxing.common.GlobalHistogramBinarizer
import com.google.zxing.common.HybridBinarizer
import com.google.zxing.qrcode.QRCodeReader
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/** Pictures are decoded at most this many pixels on their longer side. */
private const val MAX_SIDE = 2000
/** A picked image larger than this is not read. */
private const val MAX_BYTES = 64 shl 20

/** "cozysafe/qr" (2FA setup): the text of a QR code in a camera frame or in one picked
 *  image; Dart checks it is an otpauth:// link. ZXing decodes in memory only: nothing is
 *  written to a file and nothing is logged. Made in onCreate (it registers the picker). */
class QrCode(private val activity: FlutterFragmentActivity) {
    private val main = Handler(Looper.getMainLooper())
    private val images = Executors.newSingleThreadExecutor()
    private val frames = Executors.newSingleThreadExecutor()
    private val frameBusy = AtomicBoolean(false)
    private var pickResult: MethodChannel.Result? = null
    // The system photo picker: one image, no permission to read the library.
    private val pick: ActivityResultLauncher<PickVisualMediaRequest> =
        activity.registerForActivityResult(ActivityResultContracts.PickVisualMedia()) { picked(it) }

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            // null: cancelled; "": no QR code in the image.
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
            "decodeImage" -> {
                val bytes = call.argument<ByteArray>("bytes") ?: return result.success("")
                images.execute {
                    val text = try { decodeImage(bytes) } catch (_: Throwable) { null }
                    main.post { result.success(text ?: "") }
                }
            }
            // The Y plane of a camera frame, a few times a second: one at a time, a frame
            // that comes while another is decoded is skipped (null).
            "decodeFrame" -> {
                val bytes = call.argument<ByteArray>("bytes")
                val width = call.argument<Number>("width")?.toInt() ?: 0
                val height = call.argument<Number>("height")?.toInt() ?: 0
                val stride = call.argument<Number>("rowStride")?.toInt() ?: width
                if (bytes == null || !frameBusy.compareAndSet(false, true)) return result.success(null)
                frames.execute {
                    val text = try { decodeFrame(bytes, width, height, stride) } catch (_: Throwable) { null }
                    frameBusy.set(false)
                    main.post { result.success(text) }
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun picked(uri: Uri?) {
        val result = pickResult ?: return
        pickResult = null
        if (uri == null) return result.success(null)
        images.execute {
            val text = try {
                activity.contentResolver.openInputStream(uri)?.use { readCapped(it) }?.let { decodeImage(it) }
            } catch (_: Throwable) {
                null
            }
            main.post { result.success(text ?: "") }
        }
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

    private fun decodeFrame(y: ByteArray, width: Int, height: Int, stride: Int): String? {
        if (width <= 0 || height <= 0 || stride < width) return null
        if (y.size.toLong() < (height - 1).toLong() * stride + width) return null
        val source = PlanarYUVLuminanceSource(y, stride, height, 0, 0, width, height, false)
        return read(HybridBinarizer(source), null)
    }

    /** A picture in memory (JPEG, PNG, HEIF…), scaled down, then tried with both
     *  binarizers, as it is and inverted (light code on a dark background). */
    private fun decodeImage(bytes: ByteArray): String? {
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
        val hints = mapOf(DecodeHintType.TRY_HARDER to true)
        val plain: LuminanceSource = RGBLuminanceSource(w, h, pixels)
        for (source in listOf(plain, plain.invert())) {
            read(HybridBinarizer(source), hints)?.let { return it }
            read(GlobalHistogramBinarizer(source), hints)?.let { return it }
        }
        return null
    }

    private fun read(binarizer: Binarizer, hints: Map<DecodeHintType, Any>?): String? =
        try {
            QRCodeReader().decode(BinaryBitmap(binarizer), hints).text
        } catch (_: ReaderException) {
            null
        }
}
