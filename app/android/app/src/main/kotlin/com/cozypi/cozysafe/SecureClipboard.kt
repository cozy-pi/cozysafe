package com.cozypi.cozysafe

import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PersistableBundle

/// A copied password or one-time code (lib/entries/secure_clipboard.dart): marked
/// sensitive, so Android 13+ hides it in the copy preview and keyboards do not keep it,
/// and cleared after `seconds` (0: kept) while the process lives, in the background too.
/// A clear that cannot happen here (the process gone) is done by Dart when the app comes
/// back.
object SecureClipboard {
    private const val LABEL = "cozysafe-secret"
    private val handler = Handler(Looper.getMainLooper())
    private var pending: Runnable? = null

    fun copy(context: Context, text: String, seconds: Int) {
        val manager = context.getSystemService(ClipboardManager::class.java) ?: return
        val clip = ClipData.newPlainText(LABEL, text)
        clip.description.extras = PersistableBundle().apply {
            // ClipDescription.EXTRA_IS_SENSITIVE on 33+; the same key read by keyboards before.
            putBoolean(
                if (Build.VERSION.SDK_INT >= 33) ClipDescription.EXTRA_IS_SENSITIVE else "android.content.extra.IS_SENSITIVE",
                true,
            )
        }
        manager.setPrimaryClip(clip)
        pending?.let(handler::removeCallbacks)
        pending = null
        if (seconds <= 0) return
        val clear = Runnable {
            // Unconditionally: from the background Android 10+ hides the clipboard from
            // this app (no label to check), and that is exactly when it must go: the
            // person switched apps to paste. Something copied since goes too (as other
            // password managers do); the price of never leaving a password behind.
            try {
                if (Build.VERSION.SDK_INT >= 28) manager.clearPrimaryClip()
                else manager.setPrimaryClip(ClipData.newPlainText("", ""))
            } catch (e: Exception) {
                // Dart clears it when the app comes back (lib/entries/secure_clipboard.dart).
            }
        }
        pending = clear
        handler.postDelayed(clear, seconds * 1000L)
    }
}
