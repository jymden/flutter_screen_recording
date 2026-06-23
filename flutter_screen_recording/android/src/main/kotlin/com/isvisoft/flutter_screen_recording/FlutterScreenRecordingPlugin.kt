package com.isvisoft.flutter_screen_recording

import android.annotation.SuppressLint
import android.app.Activity
import android.content.ComponentName
import android.content.Intent
import android.content.ServiceConnection
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.MediaRecorder
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Environment
import android.os.IBinder
import android.util.DisplayMetrics
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.plugin.common.PluginRegistry
import java.io.IOException

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding


class FlutterScreenRecordingPlugin :
    MethodCallHandler,
    PluginRegistry.ActivityResultListener,
    FlutterPlugin,
    ActivityAware {

    private var mScreenDensity: Int = 0
    var mMediaRecorder: MediaRecorder? = null
    private fun projectionManager(): MediaProjectionManager? {
        val context = pluginBinding?.applicationContext ?: return null
        return ContextCompat.getSystemService(context, MediaProjectionManager::class.java)
    }
    var mMediaProjection: MediaProjection? = null
    var mMediaProjectionCallback: MediaProjectionCallback? = null
    var mVirtualDisplay: VirtualDisplay? = null
    private var mDisplayWidth: Int = 1280
    private var mDisplayHeight: Int = 800
    private var videoName: String? = ""
    private var mFileName: String? = ""
    private var mTitle = "Your screen is being recorded"
    private var mMessage = "Your screen is being recorded"
    private var recordAudio: Boolean? = false;
    private val SCREEN_RECORD_REQUEST_CODE = 333

    private var pendingResult: Result? = null

    private var pluginBinding: FlutterPlugin.FlutterPluginBinding? = null
    private var activityBinding: ActivityPluginBinding? = null

    private var serviceConnection: ServiceConnection? = null

    private fun completePendingResult(value: Boolean) {
        pendingResult?.success(value)
        pendingResult = null
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {

        if (requestCode == SCREEN_RECORD_REQUEST_CODE) {
            val context = pluginBinding?.applicationContext
            if (context == null) {
                Log.w("ScreenRecordingPlugin", "Activity result with no plugin context; ignoring")
                completePendingResult(false)
                return true
            }

            if (pendingResult == null) {
                Log.w("ScreenRecordingPlugin", "Ignoring activity result with no pending callback")
                if (resultCode != Activity.RESULT_OK) {
                    ForegroundService.stopService(context)
                }
                return true
            }

            if (resultCode == Activity.RESULT_OK) {

                ForegroundService.startService(context, mTitle, mMessage)
                val intentConnection = Intent(context, ForegroundService::class.java)

                serviceConnection = object : ServiceConnection {

                    override fun onServiceConnected(name: ComponentName?, service: IBinder?) {

                        try {
                            startRecordScreen()
                            mMediaProjectionCallback = MediaProjectionCallback()
                            val projectionManager = projectionManager()
                                ?: throw IllegalStateException("MediaProjectionManager is unavailable")
                            mMediaProjection = projectionManager.getMediaProjection(resultCode, data!!)
                            mMediaProjection?.registerCallback(mMediaProjectionCallback!!, null)
                            mVirtualDisplay = createVirtualDisplay()
                            completePendingResult(true)

                        } catch (e: Throwable) {
                            e.message?.let {
                                Log.e("ScreenRecordingPlugin", it)
                            }
                            completePendingResult(false)
                        }
                    }

                    override fun onServiceDisconnected(name: ComponentName?) {
                    }
                }

                val isBound = context.bindService(intentConnection, serviceConnection!!, Activity.BIND_AUTO_CREATE)
                if (!isBound) {
                    ForegroundService.stopService(context)
                    completePendingResult(false)
                }

            } else {
                ForegroundService.stopService(context)
                completePendingResult(false)
            }
            return true
        }
        return false
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        val appContext = pluginBinding?.applicationContext
        if (appContext == null) {
            result.error("NO_CONTEXT", "Plugin is not attached to a Flutter engine", null)
            return
        }

        when (call.method) {
            "startRecordScreen" -> {
                if (pendingResult != null) {
                    result.error(
                        "already_pending",
                        "A screen recording request is already pending.",
                        null
                    )
                    return
                }

                try {
                    val activity = activityBinding?.activity ?: run {
                        result.error(
                            "NO_ACTIVITY",
                            "Screen recording requires a foreground Activity",
                            null
                        )
                        return
                    }

                    pendingResult = result
                    val title = call.argument<String?>("title")
                    val message = call.argument<String?>("message")

                    if (!title.isNullOrEmpty()) {
                        mTitle = title
                    }

                    if (!message.isNullOrEmpty()) {
                        mMessage = message
                    }

                    val metrics = DisplayMetrics()

                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                        val display = activity.display
                        display?.getRealMetrics(metrics)
                    } else {
                        @Suppress("DEPRECATION")
                        val defaultDisplay = activity.windowManager.defaultDisplay
                        @Suppress("DEPRECATION")
                        defaultDisplay?.getRealMetrics(metrics)
                    }
                    mScreenDensity = metrics.densityDpi
                    calculateResolution(metrics)
                    videoName = call.argument<String?>("name")
                    recordAudio = call.argument<Boolean?>("audio")

                    val projectionManager = projectionManager() ?: run {
                        pendingResult = null
                        result.error(
                            "NO_PROJECTION_MANAGER",
                            "MediaProjectionManager is unavailable on this device",
                            null
                        )
                        return
                    }

                    val permissionIntent = projectionManager.createScreenCaptureIntent()
                    ActivityCompat.startActivityForResult(
                        activity,
                        permissionIntent,
                        SCREEN_RECORD_REQUEST_CODE,
                        null
                    )

                } catch (e: Exception) {
                    println("Error onMethodCall startRecordScreen")
                    println(e.message)
                    pendingResult = null
                    result.success(false)
                }
            }

            "stopRecordScreen" -> {
                try {
                    serviceConnection?.let {
                        appContext.unbindService(it)
                    }
                    ForegroundService.stopService(appContext)
                    if (mMediaRecorder != null) {
                        stopRecordScreen()
                        result.success(mFileName)
                    } else {
                        result.success("")
                    }
                } catch (e: Exception) {
                    result.success("")
                }
            }

            else -> {
                result.notImplemented()
            }
        }
    }

    private fun calculateResolution(metrics: DisplayMetrics) {
        // Use the real physical pixel size of the device display.
        mDisplayWidth = metrics.widthPixels
        mDisplayHeight = metrics.heightPixels

        // Some encoders require even dimensions; round down to the nearest even number.
        // Should not change the aspect ratio in any meaningful way and does not crop.
        if (mDisplayWidth % 2 != 0) {
            mDisplayWidth -= 1
        }
        if (mDisplayHeight % 2 != 0) {
            mDisplayHeight -= 1
        }

        println("Density Dpi")
        println(metrics.densityDpi)
        println("Physical Resolution")
        println(metrics.widthPixels.toString() + " x " + metrics.heightPixels)
        println("Recording Resolution")
        println("$mDisplayWidth x $mDisplayHeight")
    }

    private fun calculateBitrate(width: Int, height: Int): Int {
        // Choose the bitrate dynamically based on total pixel count.
        val pixels = width.toLong() * height.toLong()
        return when {
            pixels >= 3_000_000L -> 20_000_000 // 20 Mbps for 3M+ pixels
            pixels >= 2_000_000L -> 14_000_000 // 14 Mbps for 2M+ pixels
            else -> 8_000_000                  // 8 Mbps otherwise
        }
    }

    private fun startRecordScreen() {
        try {

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                mMediaRecorder = MediaRecorder(pluginBinding!!.applicationContext)
            } else {
                @Suppress("DEPRECATION")
                mMediaRecorder = MediaRecorder()
            }

            try {
                mFileName = if (Environment.getExternalStorageState() == Environment.MEDIA_MOUNTED) {
                    pluginBinding!!.applicationContext.externalCacheDir?.absolutePath
                } else {
                    pluginBinding!!.applicationContext.cacheDir?.absolutePath
                }
                mFileName += "/$videoName.mp4"
            } catch (e: IOException) {
                println("Error creating name")
                return
            }

            mMediaRecorder?.setVideoSource(MediaRecorder.VideoSource.SURFACE)
            if (recordAudio!!) {
                mMediaRecorder?.setAudioSource(MediaRecorder.AudioSource.MIC);
                mMediaRecorder?.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4);
                mMediaRecorder?.setAudioEncoder(MediaRecorder.AudioEncoder.AAC);
            } else {
                mMediaRecorder?.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
            }
            mMediaRecorder?.setOutputFile(mFileName)
            mMediaRecorder?.setVideoSize(mDisplayWidth, mDisplayHeight)
            mMediaRecorder?.setVideoEncoder(MediaRecorder.VideoEncoder.H264)
            mMediaRecorder?.setVideoEncodingBitRate(calculateBitrate(mDisplayWidth, mDisplayHeight))
            mMediaRecorder?.setVideoFrameRate(30)

            mMediaRecorder?.prepare()
            mMediaRecorder?.start()

        } catch (e: Exception) {
            Log.d("--INIT-RECORDER", e.message + "")
            println("Error startRecordScreen")
            println(e.message)
        }

    }

    private fun stopRecordScreen() {
        try {
            println("stopRecordScreen")
            mMediaRecorder?.stop()
            println("stopRecordScreen success")

        } catch (e: Exception) {
            // stop() throws (IllegalStateException/RuntimeException) when it is called before any
            // frame was written or too soon after start(). The output file may be empty/corrupt,
            // but this is an expected, recoverable condition — never a crash.
            Log.d("--INIT-RECORDER", e.message + "")
            println("stopRecordScreen error")
            println(e.message)

        } finally {
            // Always release the native MediaRecorder (and its codec) and clear the reference,
            // otherwise every record/stop cycle leaks an encoder instance and eventually starves
            // other encoders in the app (e.g. a concurrent camera pipeline).
            releaseMediaRecorder()
            stopScreenSharing()
        }
    }

    private fun releaseMediaRecorder() {
        try {
            mMediaRecorder?.reset()
            mMediaRecorder?.release()
        } catch (e: Exception) {
            Log.d("--INIT-RECORDER", "releaseMediaRecorder: " + e.message)
        } finally {
            mMediaRecorder = null
        }
    }

    private fun createVirtualDisplay(): VirtualDisplay? {
        try {
            return mMediaProjection?.createVirtualDisplay(
                "MainActivity", mDisplayWidth, mDisplayHeight, mScreenDensity,
                DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR, mMediaRecorder?.surface, null, null
            )
        } catch (e: Exception) {
            println("createVirtualDisplay err")
            println(e.message)
            return null
        }
    }

    private fun stopScreenSharing() {
        if (mVirtualDisplay != null) {
            mVirtualDisplay?.release()
            if (mMediaProjection != null && mMediaProjectionCallback != null) {
                mMediaProjection?.unregisterCallback(mMediaProjectionCallback!!)
                mMediaProjection?.stop()
                mMediaProjection = null
            }
            Log.d("TAG", "MediaProjection Stopped")
        }
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        pluginBinding = binding
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {}

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        val channel = MethodChannel(pluginBinding!!.binaryMessenger, "flutter_screen_recording")
        channel.setMethodCallHandler(this)
        binding.addActivityResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        onDetachedFromActivity()
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activityBinding = binding
        binding.addActivityResultListener(this)
    }

    override fun onDetachedFromActivity() {
        activityBinding?.removeActivityResultListener(this)
        activityBinding = null
    }

    inner class MediaProjectionCallback : MediaProjection.Callback() {
        override fun onStop() {
            // The projection can be torn down by the system or the user (stop button in the
            // system UI). Release the recorder here too so the codec is freed and the reference
            // is cleared, keeping this path idempotent with stopRecordScreen().
            releaseMediaRecorder()
            mMediaProjection = null
            stopScreenSharing()
        }
    }
}
