package com.pirsumoto.app

import android.content.Context
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor

/** One process-local engine shared by the foreground host and its optional UI. */
object FlutterEngineManager {
    const val ENGINE_ID = "pirsumoto_shared_engine"

    fun getOrCreateSharedEngine(context: Context): FlutterEngine {
        check(Looper.myLooper() == Looper.getMainLooper())
        FlutterEngineCache.getInstance().get(ENGINE_ID)?.let { return it }
        val app = context.applicationContext
        val engine = FlutterEngine(app)
        try {
            PirsumotoEngineChannels(app).register(engine)
            AutomationWebViewLifecycle.register(engine)
            PublicationDeadlineReceiver.register(app, engine)
            FlutterEngineCache.getInstance().put(ENGINE_ID, engine)
            engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
            Log.i("PirsumotoEngine", "Shared receiver engine created and Dart started")
            return engine
        } catch (error: Exception) {
            FlutterEngineCache.getInstance().remove(ENGINE_ID)
            engine.destroy()
            throw error
        }
    }
}
