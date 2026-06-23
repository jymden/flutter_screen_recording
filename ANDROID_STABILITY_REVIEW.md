# Android Implementation — Stability & Error-Handling Review

**Scope:** `flutter_screen_recording/android/src/main/kotlin/com/isvisoft/flutter_screen_recording/`
(Kotlin `MediaProjection` + `MediaRecorder` implementation) plus the plugin `AndroidManifest.xml`
and `build.gradle`.
**Date:** 2026-06-23
**Reviewer goal:** Make the plugin crash-safe and robust when used inside a host app that
*simultaneously* runs a camera preview (`Camera2`/`CameraX`) and an ML Kit analysis pipeline.
**Out of scope:** the example app (do not modify).

## Files reviewed

| File | Role |
| --- | --- |
| `FlutterScreenRecordingPlugin.kt` | Main plugin logic (method channel, permission flow, recorder + virtual display lifecycle). |
| `ForegroundService.kt` | `mediaProjection` foreground service + notification. |
| `AndroidManifest.xml` | Permissions + service declaration. |
| `build.gradle` | SDK levels, dependencies, repositories. |
| `method_channel_flutter_screen_recording.dart` / `flutter_screen_recording.dart` | Dart bridge (how `audio` flag and results flow). |

## Overall assessment

The Android side is **noticeably more fragile than the iOS side**. iOS has been hardened with
serialized state, one-shot result delivery, ObjC `@try/@catch` bridges and PTS guards. The
Android implementation has not had the same pass and still contains:

- **Two concrete hard-crash paths** that are not in a `try/catch`: a stale `Activity` reference
  (lifecycle) and a `Service`-cast `ClassCastException` in the Android-14 permission branch.
- **A success-reported-on-failure path**: `startRecordScreen()` swallows every `MediaRecorder`
  setup/`start()` exception, yet the caller still reports `true` to Dart and builds a virtual
  display — so a failed start looks like a running recording and later crashes/produces an empty
  file.
- **Native resource leaks**: `MediaRecorder` is `reset()` but never `release()`d or nulled, and
  the `Activity`/`MethodChannel` are never detached.

The most relevant context for your use case: on Android, screen recording and the camera don't
share an `AVAudioSession` the way they do on iOS, but they **do contend for two scarce system
resources** — the **microphone** (`MediaRecorder.AudioSource.MIC` vs. any `AudioRecord` your
camera/ML Kit stack uses) and the **hardware H.264 encoder** (your ML Kit pipeline + a 30 fps
full-resolution screen encode). Both contention cases currently fail *silently* and desync Dart
state rather than reporting an error. Several issues below center on that.

### Real-world signal (updated 2026-06-23)

The app author reports **no observed crashes on Android in practice** — the crashes that
motivated this work were iOS-only. This is consistent with the code, and it refines how to read
the severities below:

- Android wraps nearly every native call in `try/catch(Exception)`/`catch(Throwable)`, and the
  two "hard-crash" items (H1, H2) only fire on **narrow edge cases** — H1 needs the Activity to
  be destroyed/recreated *during* the permission flow (rotation, "Don't keep activities",
  low-memory); H2 needs `FOREGROUND_SERVICE_MEDIA_PROJECTION` (a normal, install-time-granted
  permission) to report *denied* on Android 14+, which essentially never happens. A typical
  single-orientation app simply never hits them. That is why Android has felt stable.
- The issues that actually bite this app are **not crashes** but **silent failures, resource
  leaks, and Dart/native state desync**: H3 (a failed `start()` is reported as success → empty
  file), M1 (encoder leak over many record cycles), M3 (system/user-stopped projection never
  reaches Dart), and the contention cases M2 (mic) / M9 (encoder limits). These degrade quietly
  and are the real return-on-effort here.

**Reframing, not downgrading.** Because this is a *public package* used by other apps and OS
versions, the crash items keep their HIGH classification (they are genuine crashes where they
fire). But for *this* app the priority order is the robustness items — see the updated
implementation order at the bottom. H1/H2/M1 were still worth doing: H1 also fixes a real
Activity **leak** in a long-running camera app, M1 fixes a real encoder leak, and H2's guard is
cheap insurance.

---

## HIGH risk

### H1 — Stale `Activity` binding + force-unwraps → NPE/crash and a leaked Activity — ✅ FIXED (2026-06-23)

> **Status:** Implemented in `FlutterScreenRecordingPlugin.kt`.
> (a) `onDetachedFromActivity()` now removes the `ActivityResultListener` and nulls
> `activityBinding`; `onDetachedFromActivityForConfigChanges()` delegates to it; and
> `onReattachedToActivityForConfigChanges()` re-adds the listener instead of only overwriting
> the binding — so the destroyed Activity is no longer retained and the listener is never
> stale/double-registered.
> (b) Force-unwraps were replaced with guarded access: `onMethodCall` fails with
> `FlutterError("NO_CONTEXT", …)` if no plugin context; the `startRecordScreen` branch resolves
> a guarded `activity` (→ `"NO_ACTIVITY"`) before touching `pendingResult`; `onActivityResult`
> guards the context and completes the pending result with `false` instead of NPE-ing.
> (c) The throwing `mProjectionManager by lazy` was replaced with a nullable
> `projectionManager()` helper; callers degrade gracefully (`"NO_PROJECTION_MANAGER"` /
> caught in `onServiceConnected`). Verified: example app builds a debug APK
> (`✓ Built app-debug.apk`, 0 errors). Original analysis below.

**Where:** `onDetachedFromActivity()` is empty (line 349); `activityBinding!!` is force-unwrapped
in `onMethodCall` setup (lines 157, 161, 171–172); `pluginBinding!!` is force-unwrapped in
`onMethodCall` (128), the `mProjectionManager` lazy (42), `startRecordScreen` (245, 253, 255) and
elsewhere.

**Problem:**
- `onDetachedFromActivity()` does **not** clear `activityBinding`, and
  `onReattachedToActivityForConfigChanges` only *overwrites* it. So after the host Activity is
  destroyed (rotation, backgrounding, `Don't keep activities`), the plugin keeps a reference to a
  **destroyed Activity**. This both **leaks the Activity** (serious in a long-running camera app)
  and means a later `startRecordScreen` runs `activityBinding!!.activity.windowManager` /
  `ActivityCompat.startActivityForResult(deadActivity, …)` against a finished Activity → undefined
  behavior / crash.
- `activityBinding!!.activity` inside `startRecordScreen` *is* wrapped in the method's
  `try/catch(Exception)`, so a clean NPE there is swallowed — but a `null`-vs-stale distinction
  matters: a **non-null but dead** Activity throws platform exceptions that are not all
  `Exception` subclasses you want to swallow, and `mProjectionManager` (line 42) throws a raw
  `Exception("MediaProjectionManager not found")` from a property initializer.
- `pluginBinding!!.applicationContext` on the very first line of `onMethodCall` (128) is **outside**
  the `try`, so if a method call ever arrives while `pluginBinding` is null it is an uncaught NPE.

**Fix:**
1. Track lifecycle properly:
   ```kotlin
   override fun onDetachedFromActivity() {
       activityBinding?.removeActivityResultListener(this)
       activityBinding = null
   }
   override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()
   override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
       activityBinding = binding
       binding.addActivityResultListener(this)
   }
   ```
2. Replace force-unwraps with guarded access and a clear `FlutterError`:
   ```kotlin
   val activity = activityBinding?.activity ?: run {
       result.error("NO_ACTIVITY", "Screen recording requires a foreground Activity", null)
       pendingResult = null
       return
   }
   ```
3. Make `mProjectionManager` nullable/guarded instead of `by lazy { … ?: throw }`, and fail the
   pending result gracefully if it can't be obtained.

---

### H2 — `ForegroundService` requests permissions via `this as Activity` → `ClassCastException` crash — 🟡 PARTIALLY FIXED (2026-06-23)

> **Status:** Crash-safe guard implemented in `ForegroundService.kt`; the permission-request
> logic was intentionally **kept** for further investigation (per request).
>
> **What was done (the safe guard):**
> 1. Wrapped the `ActivityCompat.requestPermissions(this as Activity, …)` call in its own
>    `try/catch` so the `ClassCastException` can never abort `onStartCommand`.
> 2. **Hoisted `startForegroundServiceWithNotification(intent)` so it is now called
>    unconditionally**, after the permission block, on every path (granted / denied / pre-14).
>
> **Why this is the real fix.** The `ClassCastException` itself was already caught by the
> existing outer `catch (err: Exception)` — so it never crashed directly. The *actual* crash
> was a second-order effect: on the permission-denied branch the throw skipped
> `startForegroundServiceWithNotification(intent)` entirely, so the service never called
> `startForeground()` within the system window and Android killed the process with an
> **uncatchable** `ForegroundServiceDidNotStartInTimeException`. Guaranteeing `startForeground()`
> always runs is what removes the crash. The host app using the package will no longer be
> terminated by this path.
>
> **What was deliberately NOT done (deferred for investigation):**
> - The `checkSelfPermission` + `requestPermissions(this as Activity, …)` request is still
>   present (now wrapped). It remains a no-op in practice — you cannot request runtime
>   permissions from a `Service`, and `FOREGROUND_SERVICE_MEDIA_PROJECTION` is a normal,
>   install-time-granted permission anyway. The eventual fix (per the original analysis) is to
>   delete the request and either just foreground unconditionally or check-and-fail-fast.
> - The typed `startForeground(id, notification, FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)`
>   overload (API 29+) was not adopted yet — still using the 2-arg form. Revisit together with
>   the deferred removal and M4 (FGS readiness ordering).
>
> **Note for the next pass:** in the genuinely-denied edge case (a ROM that reports the normal
> permission as denied), `startForeground` for a `mediaProjection` service can still throw
> `SecurityException`; it is caught by the outer handler but the service may then fail to
> foreground. This is rare and tied to the deferred full fix. Verified: example app builds a
> debug APK (`✓ Built app-debug.apk`, 0 errors). Original analysis below.

**Where:** `ForegroundService.onStartCommand`, Android-14 branch (lines 73–87).

**Problem:** On Android 14 (`UPSIDE_DOWN_CAKE`), if
`FOREGROUND_SERVICE_MEDIA_PROJECTION` is reported as `PERMISSION_DENIED`, the code does:
```kotlin
ActivityCompat.requestPermissions(this as Activity, …)
```
`this` is a **`Service`**, not an `Activity`. `this as Activity` is an unconditional
**`ClassCastException`** at runtime, and it is *not* inside a `try/catch` that can save the app
(the surrounding `try` catches `Exception`, so it would be caught here — but the deeper bug is
that **you cannot request runtime permissions from a Service at all**, and on the denied path
`startForeground` is then never called). A foreground service that fails to call
`startForeground()` within the system timeout is killed with
`ForegroundServiceDidNotStartInTimeException`.

In practice `FOREGROUND_SERVICE_MEDIA_PROJECTION` is a **normal**, install-time-granted
permission, so `checkSelfPermission` should return `GRANTED` and this branch usually isn't taken
— but the logic is wrong and the crash path is real on any device/ROM where the check returns
denied. It is dead-but-dangerous code.

**Fix:**
- Delete the runtime-permission request from the service entirely. `FOREGROUND_SERVICE_MEDIA_PROJECTION`
  is granted at install via the manifest; just call `startForegroundServiceWithNotification(intent)`
  unconditionally.
- If you want a guard, *check* the permission and **fail fast** (stop the service, signal the
  plugin to complete the pending result with an error) instead of trying to request it from a
  service.
- Call the typed overload so the projection type is explicit on API 29+:
  ```kotlin
  if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q)
      startForeground(1, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
  else startForeground(1, notification)
  ```

---

### H3 — `startRecordScreen()` swallows failures but the caller reports success → state desync + later `stop()` crash

**Where:** `startRecordScreen()` (241–286) catches *all* exceptions and returns `Unit`;
`onServiceConnected` (90–106) calls it, then unconditionally builds the virtual display and calls
`completePendingResult(true)`.

**Problem:** `prepare()`/`start()` (277–278) throw whenever the encoder or microphone is
unavailable — **exactly your scenario**: the H.264 encoder is already saturated by the ML Kit
camera pipeline, or the MIC is held by the camera/audio stack. The exception is logged and
swallowed, so:
1. `mMediaRecorder` is left created-but-not-started.
2. Control returns to `onServiceConnected`, which creates a `VirtualDisplay` rendering into a
   dead recorder surface and reports **`true`** to Dart.
3. The host app believes recording is active. On `stopRecordScreen`, `mMediaRecorder?.stop()` is
   called on a recorder that never started → `IllegalStateException` (caught), and the user gets
   an empty/0-byte `.mp4` and a `stopRecordScreen` that returns `""`.

So a recoverable resource conflict becomes a "recording silently vanished" bug with no signal to
Dart — the single most likely real-world failure in a concurrent-camera app.

**Fix:**
1. Make `startRecordScreen()` return success/failure:
   ```kotlin
   private fun startRecordScreen(): Boolean { … return true / false in catch }
   ```
2. In `onServiceConnected`, only proceed to `createVirtualDisplay()` + `completePendingResult(true)`
   if start succeeded; otherwise tear down (`release` recorder, stop service, stop projection) and
   `completePendingResult(false)`.
3. Order matters: create the `MediaProjection` and `VirtualDisplay` **after** a successful
   `MediaRecorder.prepare()` (you need the surface), but make `start()` failure abort the whole
   chain.

---

## MEDIUM risk

### M1 — `MediaRecorder` is never `release()`d or nulled → native encoder leak — ✅ FIXED (2026-06-23)

> **Status:** Implemented in `FlutterScreenRecordingPlugin.kt`. Added a single crash-safe
> `releaseMediaRecorder()` helper that `reset()` + `release()`s the recorder (release was
> previously never called) inside a `try/catch` and always nulls `mMediaRecorder` in `finally`.
> `stopRecordScreen()` now tears down through it in its `finally` (and no longer leaves a
> reset-but-non-null recorder), and `MediaProjectionCallback.onStop()` uses the same helper.
> This frees the codec every record/stop cycle, stops the `!= null` guard from sticking across
> sessions, and makes the two teardown paths idempotent (closing a double-release/double-stop
> crash path). Verified: example app builds a debug APK (`✓ Built app-debug.apk`, 0 errors).
> Original analysis below.

**Where:** `stopRecordScreen` (288–303) calls `stop()` + `reset()` but never `release()`, and
never sets `mMediaRecorder = null`. `MediaProjectionCallback.onStop` (352–356) only calls
`reset()`.

**Problem:** Each record/stop cycle leaks a native `MediaRecorder` (and its codec). In a
long-lived app that starts/stops recording repeatedly while also running the camera encoder, this
exhausts `MediaCodec` instances and eventually `prepare()` starts failing for *everyone*,
including your camera pipeline. Leaving `mMediaRecorder` non-null after stop also breaks the
`if (mMediaRecorder != null)` guard in `stopRecordScreen` (it stays truthy across cycles).

**Fix:** Always `release()` then null in a `finally`:
```kotlin
try { mMediaRecorder?.stop() }
catch (e: RuntimeException) { /* no frames / stopped too soon — expected, log */ }
finally {
    mMediaRecorder?.reset()
    mMediaRecorder?.release()
    mMediaRecorder = null
    stopScreenSharing()
}
```
Apply the same `release()`+null in `MediaProjectionCallback.onStop`.

### M2 — Microphone source contention with the host camera/ML Kit pipeline (silent audio failure)

**Where:** `startRecordScreen`, audio branch (264–267): `setAudioSource(MIC)` +
`recordAudio!!` force-unwrap.

**Problem:** When `startRecordScreenAndAudio` is used, `MediaRecorder` grabs `AudioSource.MIC`.
If your camera/ML Kit stack (or any other component) holds an `AudioRecord`/mic session,
`prepare()`/`start()` can throw or the OS may mute one side depending on the
`AudioRecord`-sharing rules and OEM. Today that throw is swallowed by H3 and silently downgrades
the whole recording. Also `recordAudio!!` NPEs if the `"audio"` argument is ever absent (it
defaults from `call.argument<Boolean?>`), though it's currently inside the swallowing `try`.

**Fix:**
1. Null-safe the flag: `val withAudio = recordAudio == true`.
2. Decide audio capability *explicitly* and report it: if audio was requested but the mic source
   can't be configured, either fail with a clear error code (`"MIC_UNAVAILABLE"`) or fall back to
   video-only **and tell Dart** which mode you ended up in (don't silently drop audio).
3. Document (README) that `startRecordScreenAndAudio` competes with the host app's microphone and
   recommend video-only while a camera/audio capture session is live — mirror the iOS "Using
   alongside a camera" guidance.

### M3 — System/user revocation of the projection is invisible to Dart

**Where:** `MediaProjectionCallback.onStop` (351–357).

**Problem:** The user can stop the capture from the system notification/affordance, or another app
can take the projection. `onStop` resets the recorder and tears down sharing, but **never notifies
Flutter**. Dart still thinks recording is active; the next `stopRecordScreen` finds a non-null
(but reset) recorder, throws `IllegalStateException` on `stop()` (caught), and returns `""`. Same
silent-failure/state-desync class as iOS M1.

**Fix:** Add an `EventChannel` (e.g. `flutter_screen_recording/events`) and emit a structured
event from `onStop` and from the H3 failure path (`{"event":"stopped","reason":…}`). At minimum,
cache the last failure/stop reason and return it from the next `stopRecordScreen` instead of a
bare `""`.

### M4 — `getMediaProjection` vs. foreground-service ordering race (Android 14+)

**Where:** `onActivityResult` (83–116): `ForegroundService.startService(...)` (async via
`startForegroundService`) is called, then `bindService`, and `getMediaProjection(...)` runs inside
`onServiceConnected`.

**Problem:** On API 34+, `MediaProjectionManager.getMediaProjection` throws `SecurityException`
unless a foreground service of type `mediaProjection` is **already running**. `onStartCommand`
(which calls `startForeground`) and `onServiceConnected` are delivered independently; there is no
guarantee `startForeground` has executed before `getMediaProjection` runs. The `SecurityException`
is caught (→ `completePendingResult(false)`), so it's not a crash, but it makes start
intermittently fail under load.

**Fix:** Don't drive `getMediaProjection` off `onServiceConnected`. Instead start the FGS and have
the **service signal readiness** (e.g. the bound `Binder` exposes an `isForegrounded` flag set
*after* `startForeground`, or post the result back via a callback) before calling
`getMediaProjection`. Alternatively, request the projection and pass the token into the service,
and create the projection inside the service immediately after `startForeground`.

### M5 — `MediaRecorder.prepare()/start()` run synchronously on the main thread (ANR)

**Where:** `onServiceConnected` → `startRecordScreen` executes on the main thread (service
callbacks are main-thread by default).

**Problem:** `prepare()`/`start()` and codec allocation can block, especially when the encoder is
contended by your camera/ML Kit pipeline. Blocking the main thread risks an ANR. (iOS M3 is the
analogous concern.)

**Fix:** Move recorder setup/teardown to a background `Handler`/executor and post the
`completePendingResult` back to the main thread. Pass that handler to `createVirtualDisplay`'s
callback argument too (currently `null`).

### M6 — `stopService` via `startService(stopIntent)` can throw in background

**Where:** `ForegroundService.stopService` (42–46): `context.startService(stopIntent)`.

**Problem:** On Android O+, `startService` for a service that is not currently running, or from a
background context, throws `IllegalStateException` (`Not allowed to start service … app is in
background`). This can happen if projection was already torn down (`onStop` ran first) and the app
is backgrounded when `stopRecordScreen` is called. It's raw `startService`, not wrapped, on the
caller side.

**Fix:** Track service-running state and prefer `context.stopService(intent)` to deliver
termination, or guard the `startService` call in a `try/catch` and no-op if the service isn't
running. Make stop idempotent.

### M7 — `MethodChannel` registered in `onAttachedToActivity` and never torn down

**Where:** `onAttachedToActivity` (336–341) creates the `MethodChannel`;
`onDetachedFromEngine` (334) and `onDetachedFromActivity` (349) are empty.

**Problem:** Channel setup belongs to the **engine** lifecycle, not the activity lifecycle.
Registering it in `onAttachedToActivity` means: (a) method calls fail if the engine is attached
without an Activity; (b) the handler is never removed (`setMethodCallHandler(null)` is never
called) → leak; (c) if `onAttachedToActivity` is ever invoked more than once for an engine, you
re-register over the same channel name. The `addActivityResultListener` registration is likewise
never removed (ties into H1's Activity leak).

**Fix:** Create the channel in `onAttachedToEngine` and clear it in `onDetachedFromEngine`:
```kotlin
override fun onAttachedToEngine(binding) {
    pluginBinding = binding
    channel = MethodChannel(binding.binaryMessenger, "flutter_screen_recording").apply {
        setMethodCallHandler(this@FlutterScreenRecordingPlugin)
    }
}
override fun onDetachedFromEngine(binding) {
    channel?.setMethodCallHandler(null); channel = null; pluginBinding = null
}
```
Register/unregister the activity-result listener in the activity callbacks (see H1).

### M8 — `pendingResult` can hang the Dart Future across process death / config change

**Where:** `pendingResult` (58); `onActivityResult` no-pending branch (75–81).

**Problem:** The system permission dialog can outlive the Activity (low-memory process death,
config change). On return, `onActivityResult` may hit a **new** plugin instance whose
`pendingResult` is null — it logs "Ignoring activity result with no pending callback" and stops
the service, but the **original Dart `Future` is never completed**, so `startRecordScreen()`
awaits forever (the Dart wrapper has no timeout). Conversely, if the user dismisses the dialog
without producing a result, `pendingResult` stays set and every subsequent call returns
`"already_pending"` permanently.

**Fix:**
1. Make result delivery one-shot and always-fired (mirror iOS M2): guarantee `pendingResult` is
   completed on *every* exit path, including a watchdog/timeout.
2. Consider persisting minimal state so a recreated instance can fail the pending result cleanly.
3. Add a defensive `.timeout(...)` in the Dart layer as a backstop.

### M9 — Recording at full physical resolution can exceed encoder limits → silent `prepare()` failure

**Where:** `calculateResolution` (209–229) uses `metrics.widthPixels/heightPixels`;
`setVideoSize` (272) + `setVideoEncodingBitRate` (274).

**Problem:** On 1440p/4K devices the full-resolution H.264 `setVideoSize` can exceed the encoder's
supported `MediaCodecInfo` profile/level — `prepare()` throws and (per H3) the failure is
swallowed and reported as success. Likelihood rises when the camera pipeline already holds an
encoder instance.

**Fix:** Clamp the requested size to the codec's `VideoCapabilities`
(`MediaCodecList`/`getSupportedWidths/Heights`) and round to the alignment the codec reports
(you already round to even; codecs often need 16-alignment). Fall back to a capped resolution
(e.g. 1080p) rather than failing. Surface any unavoidable failure via M3's event channel.

---

## LOW risk / polish

### L1 — `println` / `Log.d` debug logging throughout
`FlutterScreenRecordingPlugin.kt` and `ForegroundService.kt` are full of `println("---- …")`
and `println(e.message)`. These go to stdout (logcat) unfiltered in release, are noisy, and leak
internal paths. Switch to a single tagged `Log` wrapper gated on `BuildConfig.DEBUG`.

### L2 — Heavy/unused dependencies and deprecated repositories
`build.gradle` pulls `com.github.HBiSoft:HBRecorder:2.0.5` (the plugin uses `MediaRecorder`
directly — **HBRecorder appears unused**) and adds the `bytedance`/`Volcengine` maven repo plus
the sunset `jcenter()`. Unused deps bloat the host APK and the extra repos slow/риск builds.
Remove HBRecorder if it is genuinely unused, drop `jcenter()`, and remove the Volcengine repo if
nothing needs it.

### L3 — Over-broad permissions force-merged into the host app
The plugin manifest unconditionally declares `RECORD_AUDIO`, `SYSTEM_ALERT_WINDOW`,
`RECEIVE_BOOT_COMPLETED`, and `WAKE_LOCK`. Via manifest merging these are added to **every host
app** — including your camera/ML Kit app — even for video-only screen recording.
`SYSTEM_ALERT_WINDOW` and `RECORD_AUDIO` are Play-Store-flagged/privacy-sensitive and can affect
review. Recommend: gate `RECORD_AUDIO` behind audio recording only (document that the host adds it
if needed), and drop `SYSTEM_ALERT_WINDOW`/`RECEIVE_BOOT_COMPLETED` unless a feature actually
needs them (the boot/wakelock behavior comes from `flutter_foreground_task`'s `autoRunOnBoot`,
which is questionable for a screen recorder).

### L4 — `videoName` used unsanitized in the output path
`mFileName += "/$videoName.mp4"` (257). A null name yields `null.mp4`; a name containing `/` or
`..` injects into the path. Validate/sanitize the name and reject empty/null with a clear error.

### L5 — `POST_NOTIFICATIONS` (Android 13+) not handled
The foreground-service notification requires `POST_NOTIFICATIONS` at runtime on API 33+. If the
host hasn't been granted it, the notification is silently absent (the FGS still runs, but UX is
degraded and some OEMs are stricter). Document that the host must request it, or request it as
part of the start flow.

### L6 — `onDetachedFromEngine` performs no cleanup
Empty (334). Combined with M7, nothing is released on engine detach. Null out bindings, channel,
and any in-flight recorder/projection here.

### L7 — Cosmetic
Mixed-language comments (Spanish in `ForegroundService`), a system framework drawable as the
notification icon (`android.R.drawable.presence_video_online`), the trailing-semicolon Kotlin
style, and magic numbers (`SCREEN_RECORD_REQUEST_CODE = 333`, hard-coded `30` fps). Low impact;
clean up opportunistically.

---

## Suggested implementation order (for the fixing agent)

> **Recommended next step for this app (given no observed Android crashes): H3.** With the crash
> edges (H1/H2) guarded and the encoder leak (M1) closed, the highest-value remaining work is
> robustness, not crash-proofing. **H3** is the top priority — today a failed `start()` (encoder
> or mic held by the camera/ML Kit pipeline) is reported to Dart as a *successful* recording,
> producing an empty file with no signal. **M3** (surface system/user-driven stops to Dart) and
> **M2/M9** (report mic/encoder contention instead of failing silently) come next. The crash
> items stay HIGH for other consumers of the package, but they are not what degrades this app.

1. **H1 ✅ + H2 🟡** — fix the two real crash paths first: proper Activity-lifecycle handling +
   force-unwrap removal (**H1 done — 2026-06-23**), and the `this as Activity` service crash
   (**H2 crash-safe guard done — 2026-06-23**; permission-request removal deferred for
   investigation). *(Small, self-contained, removes the hard crashes.)*
2. **H3 + M1 ✅** — make `startRecordScreen()` report failure, only report `true` on a genuinely
   started recorder (H3 pending), and always `release()`+null the recorder
   (**M1 done — 2026-06-23**). *(Eliminates the "silent vanished recording" + encoder leak — the
   most likely real-world failure under camera/ML Kit load.)*
3. **M3 + M8** — add the `EventChannel` for async stop/failure and make `pendingResult` one-shot
   with a watchdog + Dart timeout. *(Removes the silent-failure / hung-Future state desyncs.)*
4. **M2 + M9** — explicit audio capability reporting + encoder-aware resolution clamping +
   README "Using alongside a camera/microphone" guidance. *(Directly addresses concurrent-camera
   contention.)*
5. **M4 + M5 + M6 + M7** — FGS readiness ordering, off-main-thread recorder setup, idempotent
   stop, engine-lifecycle channel registration.
6. **L1–L7** — logging, dependency/permission trim, name sanitization, notification permission,
   cleanup, cosmetics.

### Cross-cutting principle
Adopt the discipline already applied on iOS: **every state transition either succeeds and is
reported as success, or fails and is reported as a structured error — never silently swallowed.**
Concretely for Android that means (a) no `try/catch` that logs-and-continues while the caller
reports success (H3), (b) every native resource (`MediaRecorder`, `MediaProjection`,
`VirtualDisplay`, `Activity`/channel bindings) is released exactly once on every teardown path
(M1, M7, L6), and (c) async/system-driven terminations (`MediaProjection.Callback.onStop`, lost
projection, killed FGS) are surfaced to Dart via an event channel (M3) so the host app's
recording state can never desync from reality.
