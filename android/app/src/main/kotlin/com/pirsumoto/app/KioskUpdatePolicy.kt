package com.pirsumoto.app

import android.app.admin.DevicePolicyManager
import android.app.admin.SystemUpdatePolicy
import android.content.ComponentName
import android.content.Context
import android.os.Parcel
import android.os.UserManager
import android.util.Base64

/** Preserve the owner's existing policy and restore it only on manual kiosk exit. */
object KioskUpdatePolicy {
    fun enter(context: Context, dpm: DevicePolicyManager, admin: ComponentName) {
        val prefs = context.getSharedPreferences("kiosk_update_policy", Context.MODE_PRIVATE)
        if (!prefs.getBoolean("active", false)) {
            val policy = dpm.systemUpdatePolicy
            val parcel = Parcel.obtain()
            val encoded = try {
                if (policy == null) "" else {
                    policy.writeToParcel(parcel, 0)
                    Base64.encodeToString(parcel.marshall(), Base64.NO_WRAP)
                }
            } finally { parcel.recycle() }
            prefs.edit().putBoolean("active", true)
                .putString("previous", encoded)
                .putBoolean("installRestricted", dpm.getUserRestrictions(admin).getBoolean(UserManager.DISALLOW_INSTALL_APPS))
                .commit()
        }
        // Android limits postponement to 30 days; a DPC cannot suppress updates forever.
        dpm.setSystemUpdatePolicy(admin, SystemUpdatePolicy.createPostponeInstallPolicy())
        dpm.addUserRestriction(admin, UserManager.DISALLOW_INSTALL_APPS)
    }

    fun exit(context: Context, dpm: DevicePolicyManager, admin: ComponentName) {
        val prefs = context.getSharedPreferences("kiosk_update_policy", Context.MODE_PRIVATE)
        if (!prefs.getBoolean("active", false)) return
        val encoded = prefs.getString("previous", "") ?: ""
        val policy = if (encoded.isEmpty()) null else {
            val bytes = Base64.decode(encoded, Base64.NO_WRAP)
            val parcel = Parcel.obtain()
            try {
                parcel.unmarshall(bytes, 0, bytes.size)
                parcel.setDataPosition(0)
                SystemUpdatePolicy.CREATOR.createFromParcel(parcel)
            } finally { parcel.recycle() }
        }
        dpm.setSystemUpdatePolicy(admin, policy)
        if (!prefs.getBoolean("installRestricted", false)) {
            dpm.clearUserRestriction(admin, UserManager.DISALLOW_INSTALL_APPS)
        }
        prefs.edit().clear().commit()
    }
}
