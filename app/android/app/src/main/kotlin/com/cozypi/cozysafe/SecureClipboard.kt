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
/// The process may be gone before then, so a note is kept on the phone that a secret is
/// out and until when (the time only, never the text): the next time the app is in
/// front it clears what was left ([leftBehind]).
object SecureClipboard {
    private const val LABEL = "cozysafe-secret"
    private const val PREFS = "cozysafe_clipboard"
    private const val UNTIL = "secret-until"

    /// The longest a copy lasts (Settings: 3 minutes). A note asking for more than this
    /// from now means the phone's clock was moved: it is treated as overdue.
    private const val LONGEST_MS = 180_000L
    private val handler = Handler(Looper.getMainLooper())
    private var pending: Runnable? = null

    fun copy(context: Context, text: String, seconds: Int) {
        val app = context.applicationContext
        val manager = app.getSystemService(ClipboardManager::class.java) ?: return
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
        if (seconds <= 0) {
            note(app, 0L)
            return
        }
        note(app, System.currentTimeMillis() + seconds * 1000L)
        clearIn(app, seconds * 1000L)
    }

    private fun clearIn(app: Context, ms: Long) {
        val task = Runnable {
            pending = null
            // A clear that fails keeps the note: [leftBehind] tries again.
            if (clear(app, true)) note(app, 0L)
        }
        pending = task
        handler.postDelayed(task, ms)
    }

    /// Empty the clipboard. From the background Android 10+ hides the clipboard from this
    /// app (nothing to compare with), and that is exactly when a secret must go: the
    /// person switched apps to paste. Something copied since then goes too (as other
    /// password managers do); the price of never leaving a password behind. In front,
    /// where the clipboard can be read, something else copied since is left alone.
    /// [ownOnly]: only a clip this object put there (a note's text has another label).
    fun clear(context: Context, ownOnly: Boolean): Boolean {
        val manager = context.applicationContext.getSystemService(ClipboardManager::class.java) ?: return false
        return try {
            val seen = manager.primaryClipDescription
            if (ownOnly && seen != null && seen.label?.toString() != LABEL) {
                true
            } else {
                if (Build.VERSION.SDK_INT >= 28) manager.clearPrimaryClip()
                else manager.setPrimaryClip(ClipData.newPlainText("", ""))
                true
            }
        } catch (e: Exception) {
            false
        }
    }

    /// The app is in front (MainActivity.onWindowFocusChanged). A note with no clear
    /// waiting in this process means the process died with a secret out, or a clear
    /// failed: the time left is waited out, and an overdue one is cleared now, if the
    /// clipboard still holds this app's secret.
    fun leftBehind(context: Context) {
        if (pending != null) return
        val app = context.applicationContext
        val until = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getLong(UNTIL, 0L)
        if (until == 0L) return
        val left = until - System.currentTimeMillis()
        if (left > 0L && left <= LONGEST_MS) {
            clearIn(app, left)
            return
        }
        if (clear(app, true)) note(app, 0L)
    }

    private fun note(app: Context, until: Long) {
        val edit = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
        if (until > 0L) edit.putLong(UNTIL, until) else edit.remove(UNTIL)
        edit.apply()
    }
}
