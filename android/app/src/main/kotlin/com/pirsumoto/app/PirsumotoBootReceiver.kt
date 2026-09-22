package com.pirsumoto.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** Restore the foreground host after an unlocked boot or an app update. */
class PirsumotoBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED -> PirsumotoBackgroundService.start(context)
        }
    }
}
