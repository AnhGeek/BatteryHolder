package com.batteryholder

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import org.json.JSONObject

/**
 * Posts the "battery low" warning, holds the per-board settings it is judged
 * against, and owns the repeat window.
 *
 * Two callers, one rule: `AppState` feeds live readings in from Dart while a
 * screen is open, and [BeaconScanService] feeds in the advertisements it logs
 * while the app is closed. The second is the one that matters — a board sleeps
 * most of its life and nobody is watching a chart at the moment its pack gives
 * out — which is why the settings are mirrored into SharedPreferences here
 * rather than kept in a Dart layer that may not be running.
 *
 * The repeat window lives here for the same reason, and only here: it is the
 * one piece of state that has to be right across a process that comes and goes.
 * A Dart map would forget every warning each time the app was swiped away, and
 * the user would be told about the same flat pack on every launch.
 */
object LowBatteryAlerts {

    private const val CHANNEL_ID = "low_battery"

    /**
     * Offset so a warning can never collide with the scan service's own
     * ongoing notification (id 42); the per-board id is added to it.
     */
    private const val NOTIFICATION_ID_BASE = 1000

    private const val DEFAULT_SAMPLES = 5

    /** Must match `DeviceAlertSetting.defaultRepeatAfter`. */
    private const val DEFAULT_REPEAT_MINUTES = 120

    private const val TAG = "LowBatteryAlerts"

    /**
     * Settings pushed from Dart, as the JSON `LowBatteryAlerts` persists:
     * `{"default": 3.5, "devices": {"aa:bb": {"enabled": true, "volts": 3.4,
     * "repeatMinutes": 120}}}`.
     *
     * A board that is not listed is not unwatched — it is on the default, which
     * is the whole point: a board seen for the first time while the app is
     * closed still warns, at the threshold the configured pack implies.
     *
     * `default` is 0 until Dart has pushed once, and 0 means "no honest
     * threshold yet": there is no chemistry and no cell count to derive one
     * from, and a guess would either warn about a 12 V pack forever or never
     * warn about a 1.2 V one.
     */
    const val KEY_SETTINGS = "alert_settings"
    const val KEY_SAMPLES = "alert_samples"

    /** Per board: epoch millis of the last warning posted about it. */
    private const val KEY_LAST_WARNED_PREFIX = "alert_last_"

    fun saveSettings(context: Context, settings: String, samples: Int) {
        BootReceiver.prefs(context).edit()
            .putString(KEY_SETTINGS, settings)
            .putInt(KEY_SAMPLES, if (samples > 0) samples else DEFAULT_SAMPLES)
            .apply()
    }

    fun samplesBeforeAlert(context: Context): Int =
        BootReceiver.prefs(context).getInt(KEY_SAMPLES, DEFAULT_SAMPLES)

    /** What one board is set to, or null when nothing should warn about it. */
    fun settingFor(context: Context, deviceId: String): Setting? {
        val raw = BootReceiver.prefs(context).getString(KEY_SETTINGS, null)
            ?: return null
        return try {
            val root = JSONObject(raw)
            val device = root.optJSONObject("devices")?.optJSONObject(deviceId)
            if (device != null) {
                if (!device.optBoolean("enabled", true)) return null
                val volts = device.optDouble("volts", 0.0)
                if (volts <= 0) return null
                Setting(volts, device.optInt("repeatMinutes", DEFAULT_REPEAT_MINUTES))
            } else {
                val volts = root.optDouble("default", 0.0)
                if (volts <= 0) return null
                Setting(volts, DEFAULT_REPEAT_MINUTES)
            }
        } catch (e: Exception) {
            Log.w(TAG, "settings parse failed: ${e.message}")
            null
        }
    }

    data class Setting(val thresholdVolts: Double, val repeatMinutes: Int)

    /**
     * Show the warning for one board, unless it was warned about too recently.
     *
     * Every path posts through here so there is exactly one clock. A flat pack
     * stays flat, so without the window the background scan would notify on
     * every wake — and the user would switch the feature off, which is the one
     * outcome worse than a late warning.
     *
     * Notified per board rather than as one rolling notification: two boards
     * going flat are two things to go and do, and a warning that overwrites the
     * previous board's is a warning lost.
     */
    fun postIfDue(
        context: Context,
        deviceId: String,
        title: String,
        body: String,
        repeatMinutes: Int,
    ): Boolean {
        val prefs = BootReceiver.prefs(context)
        val now = System.currentTimeMillis()
        val last = prefs.getLong(KEY_LAST_WARNED_PREFIX + deviceId, 0L)
        val window = (if (repeatMinutes > 0) repeatMinutes else DEFAULT_REPEAT_MINUTES) * 60_000L
        // A clock moved backwards would otherwise mute a board until it caught
        // up, so treat a last-warned in the future as "warn now".
        if (last != 0L && now >= last && now - last < window) return false

        val manager = context.getSystemService(NotificationManager::class.java) ?: return false
        ensureChannel(manager)

        val open = PendingIntent.getActivity(
            context,
            deviceId.hashCode(),
            Intent(context, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val notification: Notification =
            Notification.Builder(context, CHANNEL_ID)
                .setContentTitle(title)
                .setContentText(body)
                .setStyle(Notification.BigTextStyle().bigText(body))
                .setSmallIcon(android.R.drawable.stat_sys_warning)
                .setContentIntent(open)
                .setAutoCancel(true)
                .setWhen(now)
                .build()

        return try {
            manager.notify(
                NOTIFICATION_ID_BASE + (deviceId.hashCode() and 0xFFFF),
                notification
            )
            prefs.edit().putLong(KEY_LAST_WARNED_PREFIX + deviceId, now).apply()
            true
        } catch (e: SecurityException) {
            // POST_NOTIFICATIONS refused on 13+. Nothing to do but stay quiet,
            // and leave the window open so the next attempt still tries.
            Log.w(TAG, "notify denied: ${e.message}")
            false
        }
    }

    /**
     * Drop a board's window, so it may warn on its next low reading.
     *
     * Called when its settings change or it is forgotten: a threshold the user
     * just moved should be tested against the pack now, not in an hour and a
     * half left over from the old one.
     */
    fun clearWindow(context: Context, deviceId: String) {
        BootReceiver.prefs(context).edit()
            .remove(KEY_LAST_WARNED_PREFIX + deviceId)
            .apply()
    }

    /**
     * DEFAULT importance, unlike the scan service's LOW: this one is the whole
     * point of leaving the app installed, so it earns a sound and a heads-up.
     */
    private fun ensureChannel(manager: NotificationManager) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Low battery",
            NotificationManager.IMPORTANCE_DEFAULT
        ).apply {
            description = "Warns when a board's pack runs low."
        }
        manager.createNotificationChannel(channel)
    }
}
