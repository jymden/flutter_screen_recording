//import 'file:D:/Workspace/flutter_screen_recording/flutter_screen_recording_platform_interface/lib/flutter_screen_recording_platform_interface.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_screen_recording_platform_interface/flutter_screen_recording_platform_interface.dart';

class FlutterScreenRecording {
  static Future<bool> startRecordScreen(String name, {String? titleNotification, String? messageNotification}) async {
    try {
      if (titleNotification == null) {
        titleNotification = "";
      }
      if (messageNotification == null) {
        messageNotification = "";
      }

      if (!kIsWeb) {
        _maybeStartFGS(titleNotification, messageNotification);
      }
      final bool start = await FlutterScreenRecordingPlatform.instance.startRecordScreen(
        name,
        notificationTitle: titleNotification,
        notificationMessage: messageNotification,
      );

      return start;
    } catch (err) {
      print("startRecordScreen err");
      print(err);
    }

    return false;
  }

  static Future<bool> startRecordScreenAndAudio(String name, {String? titleNotification, String? messageNotification}) async {
    try {
      if (titleNotification == null) {
        titleNotification = "";
      }
      if (messageNotification == null) {
        messageNotification = "";
      }
      if (!kIsWeb) {
        _maybeStartFGS(titleNotification, messageNotification);
      }
      final bool start = await FlutterScreenRecordingPlatform.instance.startRecordScreenAndAudio(
        name,
        notificationTitle: titleNotification,
        notificationMessage: messageNotification,
      );
      return start;
    } catch (err) {
      print("startRecordScreenAndAudio err");
      print(err);
    }
    return false;
  }

  static Future<String> get stopRecordScreen async {
    try {
      final String path = await FlutterScreenRecordingPlatform.instance.stopRecordScreen;
      if (!kIsWeb && Platform.isAndroid) {
        FlutterForegroundTask.stopService();
      }
      return path;
    } catch (err) {
      print("stopRecordScreen err");
      print(err);
    }
    return "";
  }

  static const EventChannel _eventChannel =
      EventChannel('flutter_screen_recording/events');
  static Stream<Map<String, dynamic>>? _recordingEvents;

  /// Optional, additive stream of recording lifecycle events (async stop / errors).
  ///
  /// Purely additive — the existing `startRecordScreen` / `startRecordScreenAndAudio` /
  /// `stopRecordScreen` API is unchanged, and listening here is never required. Currently backed
  /// by the Android implementation; on web/iOS this is an empty stream until those platforms add
  /// native events.
  ///
  /// Events are maps, e.g.:
  ///  * `{"event": "stopped", "reason": "projection_stopped"}` — the OS/user stopped the capture
  ///    (not via [stopRecordScreen]); the host should reconcile its own recording state.
  ///  * `{"event": "error", "reason": "media_recorder_error", "what": <int>, "extra": <int>}` —
  ///    a mid-recording encoder error.
  static Stream<Map<String, dynamic>> get recordingEvents {
    if (kIsWeb || !Platform.isAndroid) {
      return const Stream.empty();
    }
    _recordingEvents ??=
        _eventChannel.receiveBroadcastStream().map<Map<String, dynamic>>(
              (dynamic event) => Map<String, dynamic>.from(event as Map),
            );
    return _recordingEvents!;
  }

  static _maybeStartFGS(String titleNotification, String messageNotification) {
    try {
      if (!kIsWeb && Platform.isAndroid) {
        FlutterForegroundTask.init(
          androidNotificationOptions: AndroidNotificationOptions(
            channelId: 'notification_channel_id',
            channelName: titleNotification,
            channelDescription: messageNotification,
            channelImportance: NotificationChannelImportance.LOW,
            priority: NotificationPriority.LOW,
            // iconData: const NotificationIconData(
            //   resType: ResourceType.mipmap,
            //   resPrefix: ResourcePrefix.ic,
            //   name: 'launcher',
            // ),
          ),
          iosNotificationOptions: const IOSNotificationOptions(
            showNotification: true,
            playSound: false,
          ),
          foregroundTaskOptions: ForegroundTaskOptions(
            eventAction: ForegroundTaskEventAction.repeat(5000),
            autoRunOnBoot: true,
            autoRunOnMyPackageReplaced: true,
            allowWakeLock: true,
            allowWifiLock: true,
          ),
        );
      }
    } catch (err) {
      print("_maybeStartFGS err");
      print(err);
    }
  }
}
