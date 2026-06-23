# flutter_screen_recording

Flutter plugin to record the screen on Android, iOS, and web.

Current platform support in this repository:

- Android: `minSdkVersion 23`
- iOS: `iOS 11.0+`
- Web: supported through the federated web implementation

## Getting Started

Import the package:

```dart
import 'package:flutter_screen_recording/flutter_screen_recording.dart';
```

Start screen recording:

```dart
final bool started = await FlutterScreenRecording.startRecordScreen(
  'my_recording',
  titleNotification: 'Screen recording',
  messageNotification: 'Recording in progress',
);
```

Start screen recording with microphone audio:

```dart
final bool started = await FlutterScreenRecording.startRecordScreenAndAudio(
  'my_recording',
  titleNotification: 'Screen recording',
  messageNotification: 'Recording in progress',
);
```

Stop recording and get the output path or file name:

```dart
final String path = await FlutterScreenRecording.stopRecordScreen;
```

## Android

The Android implementation uses `MediaProjection`, `MediaRecorder`, and a foreground service.

- The plugin currently builds with `compileSdkVersion 35`
- The plugin manifest already includes its service declaration and required foreground-service permissions
- If you record audio, request microphone permission at runtime in your app
- On modern Android versions, you may also need notification permission for the foreground service notification

The example app requests permissions with `permission_handler` before starting recording.

## iOS

The iOS implementation uses `ReplayKit` and requires `iOS 11.0+`.

### Microphone audio

If you call `startRecordScreenAndAudio`, your app **must** declare a microphone usage
description, otherwise iOS terminates the process the moment ReplayKit touches the
microphone (a privacy/TCC kill that cannot be caught):

```xml
<key>NSMicrophoneUsageDescription</key>
<string>Save audio in video</string>
```

To protect against that crash, the plugin checks for this key before enabling the
microphone. If it is missing, `startRecordScreenAndAudio` fails with the error code
`MIC_USAGE_DESCRIPTION_MISSING` instead of crashing — so a misconfigured `Info.plist`
surfaces as a normal failure (the Dart API returns `false`). Recording **without** audio
(`startRecordScreen`) never requires the key.

### Using alongside a camera / `AVCaptureSession`

ReplayKit shares the single, process-wide `AVAudioSession` with any `AVCaptureSession`
your app runs (e.g. a camera preview feeding an ML pipeline). When the ReplayKit
microphone is enabled it activates that shared session, which can otherwise interrupt a
running capture session.

- **Recommended:** while a camera session is active, record **video only**
  (`startRecordScreen`). The screen recording already captures whatever the camera
  preview is showing, so audio is often unnecessary.
- If you do need microphone audio, the plugin configures the shared session
  cooperatively (it adds `AVAudioSession`'s `.mixWithOthers` option, preserving your
  app's existing category and mode and never calling `setActive`) to minimise the chance
  of interrupting your capture session. This is best-effort; for full control you should
  configure your own audio session (typically `.playAndRecord` with `.mixWithOthers`) and
  observe `AVAudioSession.interruptionNotification` to re-activate it as needed.

The plugin returns the local output file path. If your app later saves the file to the Photos library, also add the appropriate Photos usage description to your app.

## Web

The web implementation uses `getDisplayMedia` and `MediaRecorder`.

- Best experience is on modern desktop browsers
- Browser support depends on screen-capture and codec support
- The web implementation downloads the recorded file in the browser when recording stops

## Notes

- This package exposes asynchronous APIs; use `await` when starting and stopping recordings
- Notification title and message parameters are used by the Android implementation
- Returned output differs by platform: native platforms return a local path, while web triggers a browser download
