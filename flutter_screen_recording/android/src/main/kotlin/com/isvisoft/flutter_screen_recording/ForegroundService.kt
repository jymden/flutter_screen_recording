package com.isvisoft.flutter_screen_recording

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.IBinder
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import android.app.Activity
import android.os.Binder

class ForegroundService : Service() {
    private val CHANNEL_ID = "ForegroundService Kotlin"
    private val REQUEST_CODE_MEDIA_PROJECTION = 1001

    companion object {
        fun startService(context: Context, title: String, message: String) {
            println("-------------------------- startService");

            try {
                val startIntent = Intent(context, ForegroundService::class.java)
                startIntent.putExtra("messageExtra", message)
                startIntent.putExtra("titleExtra", title)
                println("-------------------------- startService2");

                ContextCompat.startForegroundService(context, startIntent)
                println("-------------------------- startService3");

            } catch (err: Exception) {
                println("startService err");
                println(err);
            }
        }

        fun stopService(context: Context) {
            val stopIntent = Intent(context, ForegroundService::class.java)
                .setAction(ACTION_STOP)
            context.startService(stopIntent)
        }

        const val ACTION_STOP = "com.foregroundservice.ACTION_STOP"
    }


    @Suppress("DEPRECATION")
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {

        if (intent?.action == ACTION_STOP) {

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                stopForeground(STOP_FOREGROUND_REMOVE)
            } else {
                stopForeground(true)
            }

            stopSelf()

            return START_NOT_STICKY
        } else {

            try {

                println("-------------------------- onStartCommand")

                // Verificar permisos en Android 14 (SDK 34)
                // H2 (PARTIAL FIX): we still attempt to surface the
                // FOREGROUND_SERVICE_MEDIA_PROJECTION permission state here, but requesting a
                // runtime permission from a Service is not valid — `this` is a Service, not an
                // Activity, so `this as Activity` throws ClassCastException. The request is now
                // wrapped so it can NEVER abort onStartCommand, and we ALWAYS promote to the
                // foreground afterwards. Without that, the throw skipped startForeground() and
                // the system killed the process with an uncatchable
                // ForegroundServiceDidNotStartInTimeException. Removing the request entirely is
                // intentionally deferred pending further investigation.
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE &&
                    ContextCompat.checkSelfPermission(
                        this,
                        Manifest.permission.FOREGROUND_SERVICE_MEDIA_PROJECTION
                    ) == PackageManager.PERMISSION_DENIED
                ) {
                    println("MediaProjection permission not granted, requesting permission")

                    try {
                        // Solicitar el permiso si no ha sido concedido
                        ActivityCompat.requestPermissions(
                            this as Activity,
                            arrayOf(Manifest.permission.FOREGROUND_SERVICE_MEDIA_PROJECTION),
                            REQUEST_CODE_MEDIA_PROJECTION
                        )
                    } catch (e: Exception) {
                        // Expected: a Service cannot be cast to Activity / cannot request runtime
                        // permissions. Swallow so we still reach startForeground() below.
                        println("requestPermissions from service failed (expected): " + e.message)
                    }
                }

                // Always promote to the foreground so startForeground() runs within the system
                // time window, regardless of the permission branch above.
                startForegroundServiceWithNotification(intent)

                return START_STICKY
            } catch (err: Exception) {
                println("onStartCommand err")
                println(err)
            }
            return START_STICKY
        }
    }

    private fun startForegroundServiceWithNotification(intent: Intent?) {
        var title = intent?.getStringExtra("titleExtra") ?: "Flutter Screen Recording"
        var message = intent?.getStringExtra("messageExtra") ?: ""

        createNotificationChannel()
        val notificationIntent = Intent(this, FlutterScreenRecordingPlugin::class.java)

        val pendingIntent = PendingIntent.getActivity(
            this, 0, notificationIntent, PendingIntent.FLAG_MUTABLE
        )

        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(message)
            .setSmallIcon(android.R.drawable.presence_video_online)
            .setContentIntent(pendingIntent)
            .build()

        startForeground(1, notification)
        println("-------------------------- startForegroundServiceWithNotification")
    }

    override fun onBind(intent: Intent): IBinder {
        return Binder()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val serviceChannel = NotificationChannel(
                CHANNEL_ID, "Foreground Service Channel", NotificationManager.IMPORTANCE_DEFAULT
            )
            val manager = getSystemService(NotificationManager::class.java)
            manager!!.createNotificationChannel(serviceChannel)
        }
    }
}