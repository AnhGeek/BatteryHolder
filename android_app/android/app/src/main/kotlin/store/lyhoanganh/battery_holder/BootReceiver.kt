package store.lyhoanganh.battery_holder

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.os.Build

/**
 * Brings the beacon scan back after a reboot, so "keeps logging while the app is
 * closed" survives the phone restarting too.
 *
 * Logging comes back only if the user had switched it on; the flag is written
 * by MainActivity's method channel and defaults to off.
 */
class BootReceiver : BroadcastReceiver() {

    companion object {
        const val PREFS = "beacon_scan"
        const val KEY_ENABLED = "enabled"

        fun prefs(context: Context): SharedPreferences =
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return
        if (!prefs(context).getBoolean(KEY_ENABLED, false)) return

        val service = Intent(context, BeaconScanService::class.java).apply {
            action = BeaconScanService.ACTION_START
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            context.startForegroundService(service)
        } else {
            context.startService(service)
        }
    }
}
