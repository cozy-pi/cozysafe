package com.cozypi.cozysafe

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/// Keeps the app running while a sync runs with the phone locked (lib/sync/awake.dart):
/// a foreground service of type dataSync whose only work is an ongoing, quiet
/// notification "Syncing… n of m". The sync itself runs on the Rust thread; this only
/// stops Android from freezing or killing the process under it, and it stops as soon as
/// the sync ends. Everything here runs on the main thread.
class SyncService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Android requires startForeground soon after startForegroundService, even when
        // the sync has ended in between; it then stops at once.
        val n = build(this, last)
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(ID, n)
        }
        running = true
        if (!on) stopSelf()
        // Killed by the system: do not come back by itself (the sync went with the process).
        return START_NOT_STICKY
    }

    // Android 15+ limits dataSync services to 6 hours a day: stop rather than be stopped.
    override fun onTimeout(startId: Int, fgsType: Int) {
        on = false
        stopSelf()
    }

    override fun onDestroy() {
        running = false
        super.onDestroy()
    }

    private class Shown(val title: String, val text: String, val channel: String, val done: Int, val total: Int)

    companion object {
        private const val ID = 7301
        private const val CHANNEL_ID = "sync"
        /// A sync wants the service (between Awake.set(true)'s first progress and set(false)).
        private var on = false
        /// The service is in the foreground.
        private var running = false
        private var last = Shown("", "", "", 0, 0)

        /// Shows or updates the notification; the first call starts the service. Dart makes
        /// it when the sync starts, with the app on screen, so Android allows the start;
        /// later calls only update the notification, which works with the phone locked.
        fun show(context: Context, title: String, text: String, channel: String, done: Int, total: Int) {
            last = Shown(title, text, channel, done, total)
            if (on) {
                if (running) manager(context).notify(ID, build(context, last))
                return
            }
            on = true
            try {
                context.startForegroundService(Intent(context, SyncService::class.java))
            } catch (e: Exception) {
                // Not allowed right now (the app already went to the background): the sync
                // goes on for as long as Android lets it.
                on = false
            }
        }

        fun stop(context: Context) {
            if (!on) return
            on = false
            // Not yet in the foreground: onStartCommand stops it right after.
            if (running) context.stopService(Intent(context, SyncService::class.java))
        }

        private fun manager(context: Context) =
            context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        private fun build(context: Context, s: Shown): Notification {
            val builder = if (Build.VERSION.SDK_INT >= 26) {
                // Low importance: in the shade and the status bar, no sound, no pop-up.
                // Creating it again only renames it (the language may have changed).
                val name = s.channel.ifEmpty { "Sync" }
                manager(context).createNotificationChannel(NotificationChannel(CHANNEL_ID, name, NotificationManager.IMPORTANCE_LOW))
                Notification.Builder(context, CHANNEL_ID)
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(context).setPriority(Notification.PRIORITY_LOW)
            }
            // A tap opens the app where the sync shows.
            context.packageManager.getLaunchIntentForPackage(context.packageName)?.let { open ->
                builder.setContentIntent(PendingIntent.getActivity(context, 0, open, PendingIntent.FLAG_IMMUTABLE))
            }
            builder.setSmallIcon(android.R.drawable.stat_notify_sync)
                .setContentTitle(s.title)
                .setContentText(s.text)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setShowWhen(false)
                .setProgress(maxOf(s.total, 0), s.done.coerceIn(0, maxOf(s.total, 0)), s.total <= 0)
            if (Build.VERSION.SDK_INT >= 31) builder.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
            return builder.build()
        }
    }
}
