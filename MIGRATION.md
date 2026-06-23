# Migrera `flutter_screen_recording` in i din app (iOS + Android)

Den här guiden beskriver hur du löser upp plugin-gränsen helt och flyttar in all
kod (Dart + native iOS/Android) direkt i din app. Efteråt finns inget
plugin-paket kvar — koden bor i app-repot och du redigerar den direkt.

> **Scope:** Endast iOS + Android. Webb-stödet (`flutter_screen_recording_web`)
> och `flutter_screen_recording_platform_interface` slängs — vi kollapsar hela
> Dart-API:t till en enda fil i appen.

Begrepp i guiden:
- **APP** = roten på ditt app-repo (där appens `pubspec.yaml` ligger).
- **`<plugin>`** = mappen `flutter_screen_recording/flutter_screen_recording/`
  i det här repot (där plugin-koden ligger).

---

## Översikt: vad som flyttas

| Källa (i plugin-repot) | Mål (i din app) |
|---|---|
| `<plugin>/lib/flutter_screen_recording.dart` + platform-interface | `APP/lib/screen_recording/screen_recording.dart` (en sammanslagen fil, se steg 1) |
| `<plugin>/ios/Classes/SwiftFlutterScreenRecordingPlugin.swift` | `APP/ios/Runner/ScreenRecording/` |
| `<plugin>/ios/Classes/FSRAssetWriterBridge.{h,m}` | `APP/ios/Runner/ScreenRecording/` |
| `<plugin>/ios/Classes/FSRSampleBufferAppender.{h,m}` | `APP/ios/Runner/ScreenRecording/` |
| `<plugin>/ios/Classes/FlutterScreenRecordingPlugin.{h,m}` | **Slängs** (Obj-C-registreringsskal som inte behövs i appen) |
| `<plugin>/android/.../FlutterScreenRecordingPlugin.kt` | `APP/android/app/src/main/kotlin/com/isvisoft/flutter_screen_recording/` |
| `<plugin>/android/.../ForegroundService.kt` | `APP/android/app/src/main/kotlin/com/isvisoft/flutter_screen_recording/` |
| `<plugin>/android/.../AndroidManifest.xml` (permissions + service) | Slås in i `APP/android/app/src/main/AndroidManifest.xml` |

Inga tunga native-beroenden följer med:
- iOS: bara systemramverk (ReplayKit/AVFoundation) + `Flutter`.
- Android: `HBRecorder` deklareras i plugin-`build.gradle` men **används inte** i
  koden — ta inte med den. Bara `androidx.core`/`appcompat` (oftast redan på
  plats i en Flutter-app).
- Dart: `flutter_foreground_task` används fortfarande och blir ett vanligt
  pub-beroende i appen.

---

## Steg 1 — Dart

### 1a. Skapa den sammanslagna Dart-filen

Skapa `APP/lib/screen_recording/screen_recording.dart` med exakt detta innehåll.
Den slår ihop `FlutterScreenRecording` + platform-interface + method-channel till
en fil och pratar direkt med kanalerna:

```dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Inlinad version av flutter_screen_recording (iOS + Android).
class FlutterScreenRecording {
  static const MethodChannel _channel =
      MethodChannel('flutter_screen_recording');

  static const EventChannel _eventChannel =
      EventChannel('flutter_screen_recording/events');
  static Stream<Map<String, dynamic>>? _recordingEvents;

  static Future<bool> startRecordScreen(
    String name, {
    String? titleNotification,
    String? messageNotification,
  }) =>
      _start(name,
          audio: false,
          titleNotification: titleNotification,
          messageNotification: messageNotification);

  static Future<bool> startRecordScreenAndAudio(
    String name, {
    String? titleNotification,
    String? messageNotification,
  }) =>
      _start(name,
          audio: true,
          titleNotification: titleNotification,
          messageNotification: messageNotification);

  static Future<bool> _start(
    String name, {
    required bool audio,
    String? titleNotification,
    String? messageNotification,
  }) async {
    final title = titleNotification ?? "";
    final message = messageNotification ?? "";
    try {
      if (!kIsWeb) {
        _maybeStartFGS(title, message);
      }
      final bool start = await _channel.invokeMethod('startRecordScreen', {
        "name": name,
        "audio": audio,
        "title": title,
        "message": message,
      });
      return start;
    } catch (err) {
      print("startRecordScreen err");
      print(err);
    }
    return false;
  }

  static Future<String> get stopRecordScreen async {
    try {
      final String path = await _channel.invokeMethod('stopRecordScreen');
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

  /// Valfri, additiv ström av livscykel-events (async stop / fel).
  /// Endast Android i dagsläget; tom ström på iOS/web.
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

  static void _maybeStartFGS(String titleNotification, String messageNotification) {
    try {
      if (!kIsWeb && Platform.isAndroid) {
        FlutterForegroundTask.init(
          androidNotificationOptions: AndroidNotificationOptions(
            channelId: 'notification_channel_id',
            channelName: titleNotification,
            channelDescription: messageNotification,
            channelImportance: NotificationChannelImportance.LOW,
            priority: NotificationPriority.LOW,
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
```

### 1b. Uppdatera importerna i appen

Byt alla importer av paketet:

```dart
// FÖRE
import 'package:flutter_screen_recording/flutter_screen_recording.dart';
// EFTER
import 'package:<ditt_app_namn>/screen_recording/screen_recording.dart';
```

(`<ditt_app_namn>` = `name:`-fältet i appens `pubspec.yaml`.)

### 1c. Uppdatera `APP/pubspec.yaml`

- **Ta bort** `flutter_screen_recording:` ur `dependencies`.
- **Lägg till** `flutter_foreground_task: ^9.2.2` (användes tidigare transitivt
  via paketet, nu direkt).

Kör sedan `flutter pub get`.

---

## Steg 2 — Android

### 2a. Kopiera Kotlin-källorna

Behåll paketnamnet `com.isvisoft.flutter_screen_recording` (då slipper du ändra
`package`-deklarationer och `.kt`-referenser). Lägg båda filerna i:

```
APP/android/app/src/main/kotlin/com/isvisoft/flutter_screen_recording/
    FlutterScreenRecordingPlugin.kt
    ForegroundService.kt
```

Kopiera dem oförändrade — de använder bara `io.flutter.embedding.*`-API:er som
finns i appen. (Kotlin-paketet behöver inte matcha appens `applicationId`; det är
helt OK att ha en egen `com.isvisoft.*`-namespace bland app-koden.)

### 2b. Registrera plugin i `MainActivity`

Plugin-klassen implementerar `FlutterPlugin` + `ActivityAware`, så det räcker att
lägga till den i engine-registret — den kopplar då upp både method-/event-kanaler
och activity-livscykeln själv.

I `APP/android/app/src/main/kotlin/.../MainActivity.kt`:

```kotlin
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import com.isvisoft.flutter_screen_recording.FlutterScreenRecordingPlugin

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.plugins.add(FlutterScreenRecordingPlugin())
    }
}
```

### 2c. Slå in behörigheter + service i `AndroidManifest.xml`

I `APP/android/app/src/main/AndroidManifest.xml`, lägg dessa `uses-permission`
högst upp (om de inte redan finns):

```xml
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_MEDIA_PROJECTION" />
<uses-permission android:name="android.permission.WAKE_LOCK" />
<uses-permission android:name="android.permission.SYSTEM_ALERT_WINDOW" />
<uses-permission android:name="android.permission.RECORD_AUDIO" />
<uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED" />
<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
```

Och inuti `<application>`, deklarera servicen med **fullt kvalificerat** namn
(viktigt — appens manifest har en annan package än `.ForegroundService`):

```xml
<service
    android:name="com.isvisoft.flutter_screen_recording.ForegroundService"
    android:foregroundServiceType="mediaProjection" />
```

### 2d. `APP/android/app/build.gradle`

Kontrollera/justera:
- `minSdkVersion` **≥ 23** (plugin kräver 23).
- `compileSdkVersion` **≥ 34** (koden använder `UPSIDE_DOWN_CAKE` och
  `FOREGROUND_SERVICE_MEDIA_PROJECTION`, tillagda i API 34). Plugin använde 35.
- Lägg till `androidx.appcompat` om det inte redan dras in (ger `ContextCompat`,
  `NotificationCompat`, `ActivityCompat` som `ForegroundService` använder):
  ```gradle
  dependencies {
      implementation 'androidx.appcompat:appcompat:1.6.0'
  }
  ```
- Ta **inte** med `com.github.HBiSoft:HBRecorder` — den är oanvänd.

---

## Steg 3 — iOS

### 3a. Kopiera native-källorna in i Runner-target

Skapa `APP/ios/Runner/ScreenRecording/` och kopiera dit:

```
SwiftFlutterScreenRecordingPlugin.swift
FSRAssetWriterBridge.h
FSRAssetWriterBridge.m
FSRSampleBufferAppender.h
FSRSampleBufferAppender.m
```

**Släng** `FlutterScreenRecordingPlugin.h` och `FlutterScreenRecordingPlugin.m` —
den `.m`-filen importerar `<flutter_screen_recording/...-Swift.h>` (modul-headern
finns inte i app-targeten) och dess enda jobb (registrering) gör vi i
`AppDelegate` istället.

> **Lägg till filerna via Xcode** ("Add Files to Runner…", target = Runner), inte
> bara i filsystemet — då uppdateras `project.pbxproj` och header search paths så
> Swift hittar Obj-C-headern. När Xcode upptäcker Obj-C-filer i en Swift-target
> brukar den fråga om att skapa en bridging header — säg ja om du inte redan har
> en (`Runner-Bridging-Header.h` finns oftast redan i ett Flutter-projekt).

### 3b. Bridging header

Swift-koden anropar de två Obj-C-hjälparna, så de måste exponeras via Runners
bridging header. Lägg till i `APP/ios/Runner/Runner-Bridging-Header.h`:

```objc
#import "FSRAssetWriterBridge.h"
#import "FSRSampleBufferAppender.h"
```

(Kontrollera att `SWIFT_OBJC_BRIDGING_HEADER` i build settings pekar på den filen —
det gör den normalt redan i ett Flutter-projekt.)

### 3c. Registrera plugin i `AppDelegate`

`SwiftFlutterScreenRecordingPlugin` är fortfarande en `FlutterPlugin`, så
registrera den manuellt efter `GeneratedPluginRegistrant`. I
`APP/ios/Runner/AppDelegate.swift`:

```swift
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    if let registrar = self.registrar(forPlugin: "SwiftFlutterScreenRecordingPlugin") {
      SwiftFlutterScreenRecordingPlugin.register(with: registrar)
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
```

### 3d. Info.plist

Om du spelar in med ljud (`startRecordScreenAndAudio`) **måste**
`APP/ios/Runner/Info.plist` ha:

```xml
<key>NSMicrophoneUsageDescription</key>
<string>Appen behöver mikrofonen för att spela in ljud till skärminspelningen.</string>
```

Saknas nyckeln dödar iOS appen (TCC) — koden kollar detta och returnerar
felet `MIC_USAGE_DESCRIPTION_MISSING` istället, men lägg ändå in nyckeln.

### 3e. Pods

Kör `cd APP/ios && pod install` efter att filerna lagts till. Ingen ny pod
behövs (bara systemramverk), men `pod install` ser till att projektet är i synk.

---

## Steg 4 — Städa och verifiera

1. `flutter clean` i appen.
2. `flutter pub get`.
3. Sök i app-repot efter kvarvarande referenser till det gamla paketet:
   ```
   grep -rn "flutter_screen_recording" APP/lib APP/pubspec.yaml
   ```
   Allt ska nu peka på din egen `screen_recording.dart` (inte `package:flutter_screen_recording/...`).
4. Bygg och testa på fysisk enhet (skärminspelning fungerar dåligt i simulator/emulator):
   - `flutter run` på Android → starta/stoppa inspelning, verifiera att filen skapas.
   - `flutter run` på iOS → samma, samt ljud-varianten om du använder den.
5. Verifiera att `FlutterScreenRecording.recordingEvents`-strömmen fortfarande tas
   emot på Android (om du lyssnar på den).

---

## Fallgropar att hålla koll på

- **Android service-namn:** måste vara fullt kvalificerat
  (`com.isvisoft.flutter_screen_recording.ForegroundService`) i appens manifest,
  eftersom appens manifest-package skiljer sig från Kotlin-paketet. `.ForegroundService`
  skulle felaktigt resolvas mot appens `applicationId`.
- **iOS Obj-C-shimet:** ta inte med `FlutterScreenRecordingPlugin.m` — den importen
  av modul-headern bygger inte i app-targeten.
- **Bridging header:** glömmer du den får du "Use of undeclared identifier
  'FSRAssetWriterBridge'" vid Swift-bygget.
- **compileSdk < 34 på Android:** ger kompileringsfel på `UPSIDE_DOWN_CAKE` /
  `FOREGROUND_SERVICE_MEDIA_PROJECTION`.
- **`flutter_foreground_task`:** måste finnas kvar som direkt beroende i appens
  pubspec, annars kraschar Dart-koden på Android vid start/stop.
- **Plugin-registrering är nu manuell:** eftersom det inte längre är ett pub-plugin
  registreras inget automatiskt — `MainActivity` (Android) och `AppDelegate` (iOS)
  måste göra det (steg 2b/3c).
```
