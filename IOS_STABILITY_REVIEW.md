# iOS Implementation — Stability & Error-Handling Review

**Scope:** `flutter_screen_recording/ios/Classes/` (Swift/ObjC ReplayKit implementation).
**Date:** 2026-06-23
**Reviewer goal:** Make the plugin crash-safe and robust when used inside a host app that
*simultaneously* runs a camera preview (`AVCaptureSession`) and an ML Kit analysis pipeline.
**Out of scope:** the example app (do not modify).

## Files reviewed

| File | Role |
| --- | --- |
| `SwiftFlutterScreenRecordingPlugin.swift` | Main plugin logic (start/stop, writer lifecycle, buffer handling). |
| `FSRSampleBufferAppender.{h,m}` | ObjC wrapper that converts `appendSampleBuffer:` `NSException`s into `NSError`. |
| `FlutterScreenRecordingPlugin.{h,m}` | ObjC registration shim. |

## Overall assessment

The code is in good shape after the recent refactor: it serializes all writer state on a
dedicated `writerQueue`, tracks a per-recording `UUID` to ignore stale callbacks, uses
non-blocking back-pressure so it never stalls ReplayKit's thread, and already wraps the most
dangerous call (`appendSampleBuffer:`) in an ObjC `@try/@catch` bridge. The issues below are
about closing the **remaining** crash surfaces and hardening the concurrent-camera scenario.

The single most important context: **ReplayKit shares one process-wide `AVAudioSession` with
your camera/ML Kit capture session.** Most of the high-risk items stem from that interaction,
not from the recording logic itself.

---

## HIGH risk

### H1 — Unprotected `AVAssetWriter` setup can throw an uncatchable `NSException` (hard crash) — ✅ FIXED (2026-06-23)

> **Status:** Implemented. Added `FSRAssetWriterBridge.{h,m}` (an ObjC `@try/@catch`
> bridge mirroring `FSRSampleBufferAppender`) and routed `addInput`, `startWriting`+
> `startSession`, `markAsFinished`, and `finishWriting` through it, plus a
> `presentationTime.isNumeric` guard before starting the session. Every failure now flows
> into the existing graceful paths (`failRecording` / `STOP_ERROR`) with exactly-once
> `FlutterResult` delivery. Verified: ObjC syntax-checked against the iOS SDK and the
> example app builds for simulator (`Xcode build done`, 0 errors). Original analysis below.


**Where:** `SwiftFlutterScreenRecordingPlugin.swift`, first-frame setup block in
`handleVideoBuffer` — `writer.startSession(atSourceTime:)` at ~line 329, also
`writer.add(_:)` (296) and `writer.startWriting()` (320).

**Problem:** The team correctly identified that `appendSampleBuffer:` can throw an
`NSException` that Swift cannot catch, and built `FSRSampleBufferAppender` for it. But the
*session-start path* has the same hazard and is **not** protected:

- `-[AVAssetWriter startSessionAtSourceTime:]` throws `NSInvalidArgumentException` if the
  time is not numeric. The presentation timestamp is taken straight from the first ReplayKit
  buffer (`CMSampleBufferGetPresentationTimeStamp`) and passed to `startSession` **without a
  validity check**. If ReplayKit ever hands over a frame with a non-numeric PTS (seen under
  audio-session contention / capture restarts — exactly your camera scenario), the app
  hard-crashes.
- `-[AVAssetWriter addInput:]` and `markAsFinished` can also throw in unexpected states.

A Swift `do/catch` will **not** catch these — they are ObjC exceptions and will terminate the
process.

**Fix:**
1. Guard the timestamp before starting the session:
   ```swift
   let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
   guard presentationTime.isNumeric else {
       failRecording(id: recordingID, reason: "First video buffer has a non-numeric PTS")
       return
   }
   ```
2. Route the throwing `AVAssetWriter` calls (`startSession`, optionally `add`/`startWriting`/
   `markAsFinished`/`finishWriting`) through an ObjC `@try/@catch` bridge, mirroring
   `FSRSampleBufferAppender`. Add e.g. `FSRAssetWriterBridge` with:
   ```objc
   + (BOOL)startWriter:(AVAssetWriter *)writer
       atSourceTime:(CMTime)time
              error:(NSError **)error NS_SWIFT_NAME(start(_:atSourceTime:));
   ```
   that wraps `startWriting` + `startSessionAtSourceTime:` and returns an `NSError` instead of
   throwing. On failure, call `failRecording(...)` as today. This converts every remaining
   "writer threw" into a graceful, reported failure instead of a crash.

---

### H2 — Microphone path can hard-crash and/or break the host camera session — ✅ FIXED (2026-06-23)

> **Status:** Implemented in `SwiftFlutterScreenRecordingPlugin.swift` + README.
> (a) Added `hasMicrophoneUsageDescription()` and a preflight at the top of
> `startRecording`: when audio is requested but `NSMicrophoneUsageDescription` is
> missing/empty, it fails with `FlutterError("MIC_USAGE_DESCRIPTION_MISSING", …)` before
> any writer state exists — turning the TCC hard-crash into a catchable error.
> (b) Added `configureAudioSessionForCoexistence()` (called only when audio is requested,
> before `startCapture`): conservatively adds `AVAudioSession`'s `.mixWithOthers` option
> while preserving the host's category/mode, never calling `setActive`, treating errors as
> non-fatal — so it won't interrupt or stomp on the host camera `AVCaptureSession`.
> README now documents the mandatory mic key and a "Using alongside a camera /
> AVCaptureSession" section. Verified: example app builds for simulator (0 errors).
> A future improvement (deferred): observe `AVAudioSession.interruptionNotification` to
> re-finalize gracefully — tracked under M4. Original analysis below.


**Where:** `recorder.isMicrophoneEnabled = recordAudio` (line 148) and the audio-input setup
(299–318); triggered by `startRecordScreenAndAudio`.

**Two distinct problems:**

**(a) Missing `NSMicrophoneUsageDescription` → TCC hard crash.**
When `isMicrophoneEnabled = true`, ReplayKit accesses the mic. If the host app's `Info.plist`
lacks `NSMicrophoneUsageDescription`, iOS **terminates the process immediately** (privacy
crash) — there is no error to catch. The plugin neither checks for the key nor preflights
authorization.

**(b) Audio-session takeover conflicts with your `AVCaptureSession` (camera + ML Kit).**
Enabling the ReplayKit mic forces the shared `AVAudioSession` into a record-capable
configuration. If your camera session also uses audio (or simply has the session active),
this can trigger `AVCaptureSessionWasInterruptedNotification` /
`AVCaptureSessionRuntimeErrorNotification`, silently drop the camera's audio, or in worst
cases stall the capture pipeline that ML Kit feeds from.

**Fix:**
1. **Preflight, don't crash:** before enabling the mic, check authorization and degrade
   gracefully instead of forcing the system to kill the app:
   ```swift
   if recordAudio {
       switch AVAudioSession.sharedInstance().recordPermission {
       case .granted: break
       case .denied, .undetermined:
           // Either request, or fall back to video-only and report it,
           // rather than letting ReplayKit hit an unprovisioned mic.
       @unknown default: break
       }
   }
   ```
   Also detect a missing usage-description key at runtime and fail with a clear
   `FlutterError("MIC_PERMISSION", ...)` rather than allowing the TCC crash.
2. **Document the Info.plist requirement** prominently (README already starts to — finish it):
   `NSMicrophoneUsageDescription` is mandatory whenever `startRecordScreenAndAudio` is used.
3. **Protect the host capture session:** document that audio recording will reconfigure the
   shared `AVAudioSession`. Recommend (and ideally expose an option) to record **video-only**
   while a camera session is live. If audio is required, the plugin should set an explicit,
   compatible category once (`.playAndRecord` with `.mixWithOthers`/`.allowBluetooth`) and the
   host should be prepared to re-activate its own session on
   `AVAudioSession.interruptionNotification`. At minimum, add a doc section "Using alongside a
   camera/AVCaptureSession".

---

### H3 — No availability / busy-state preflight before `startCapture` — ✅ FIXED (2026-06-23)

> **Status:** Implemented in `SwiftFlutterScreenRecordingPlugin.swift`. Added a
> `guard recorder.isAvailable` preflight at the top of `startRecording` (before any
> writer/AVAssetWriter state is created) that fails fast with
> `FlutterError("RECORDER_UNAVAILABLE", …)`. This turns slow/opaque `startCapture`
> failures (AirPlay/mirroring active, Screen Time/MDM restriction, another capturer
> holding the singleton) into an immediate, descriptive error and avoids briefly
> creating-then-discarding a writer. Verified: example app builds for simulator (0 errors).
>
> **Deferred (the "consider" part):** setting `recorder.delegate` for
> `screenRecorderDidChangeAvailability(_:)`. For `startCapture`-based recording, mid-session
> failures already surface through the capture handler's error path, so a delegate would
> largely duplicate that and risks false-positive teardowns from transient availability
> flicker. Revisit alongside M4 (interruption/lifecycle handling) if richer signalling is
> wanted. Original analysis below.


**Where:** `startRecording`, around line 148–149. The code guards its *own* `isRecording`
flag but never consults ReplayKit's actual state.

**Problem:** `RPScreenRecorder.shared()` is a process-wide singleton. If the recorder is
unavailable (Screen Recording restricted via MDM/Screen Time, AirPlay/mirroring active, a
prior session not fully torn down, or another component already capturing), `startCapture`
will fail. Today that surfaces only via the completion handler's error — acceptable — but
there is no fast, explicit check and `RPScreenRecorder.isAvailable` is ignored, so failures
are slower and less clear, and a wedged shared recorder can leave the plugin's `isRecording`
out of sync with reality.

**Fix:** Before calling `startCapture`, check `recorder.isAvailable` and reject early with a
descriptive `FlutterError("RECORDER_UNAVAILABLE", ...)`. Consider setting `recorder.delegate`
to observe `screenRecorderDidChangeAvailability(_:)` so the plugin can self-correct if the
system revokes availability mid-session.

---

## MEDIUM risk

### M1 — Mid-recording failures are silent to Dart (state desync)

**Where:** `failRecording` (627–641). It logs, tears down native state, and stops capture —
but **never notifies Flutter**. Triggers: disk full, writer failure, ReplayKit capture error
after start, a thrown append.

**Problem:** After a silent `failRecording`, Dart still believes recording is active. The
subsequent `stopRecordScreen` returns `NOT_RECORDING` (because `isRecording` was reset), which
the Dart layer swallows into an empty string (`flutter_screen_recording.dart`,
`stopRecordScreen` catch → returns `""`). The user gets no file and no signal — the recording
"vanished." In a long camera session this is the most likely real-world failure mode.

**Fix:** Add a `FlutterEventChannel` (e.g. `flutter_screen_recording/events`) and emit a
structured event from `failRecording` (`{"event":"error","reason":...}`). Expose it on the Dart
side as a stream so the host app can react (stop UI spinner, retry, surface a message). If an
event channel is too large a change, at minimum cache the last failure reason and return it
from the next `stopRecordScreen` instead of a bare `NOT_RECORDING`.

### M2 — `FlutterResult` can be left undelivered → permanently hung Dart Future

**Where:** `startRecording` result delivered only from `startCapture`'s `completionHandler`;
`stopRecording` result delivered only from nested `stopCapture` → `finishWriting`
completions.

**Problem:** Each path depends on a system callback firing exactly once. If a completion
handler never fires (app backgrounded mid-stop, ReplayKit wedged), the `FlutterResult` is
never called and the Dart `await` hangs forever. The Dart wrapper has **no timeout**, so the
host app's recording state is stuck. There is also no guard preventing a double-delivery if a
callback ever fires twice (calling `FlutterResult` twice is itself undefined behavior).

**Fix:**
1. Wrap `result` in a one-shot delivery guard (an atomic "already delivered" flag inside
   `deliver`, keyed per call) so it can never be invoked twice.
2. Add a watchdog timeout on `writerQueue` for start/stop (e.g. fail the result after N
   seconds if no completion arrives) so the Future always resolves.
3. Add a defensive `.timeout(...)` in the Dart layer as a backstop.

### M3 — `writerQueue.sync` from the main thread can stall the UI under load

**Where:** `startRecording` (`writerQueue.sync`, line 97) and `stopRecording`
(`writerQueue.sync`, line 411), both invoked on the platform/main thread.

**Problem:** `writerQueue` is also the queue doing video-buffer appends. When the main thread
calls `.sync`, it blocks until any in-flight append finishes. Under your heavy concurrent load
(camera + ML Kit + encoding), an append can take long enough to cause visible UI jank, and in
the pathological case contributes to a watchdog hang. `startRecording`'s synced block also does
file I/O (`removeItem`), which can be slow for a large pre-existing file.

**Fix:** Make start/stop fully asynchronous: dispatch the setup/teardown with
`writerQueue.async`, read interface orientation on the main thread first (it already is), and
deliver the result via the existing async `deliver`. Nothing in start/stop needs a synchronous
return value to the caller.

### M4 — App-lifecycle / interruption transitions are unobserved

**Where:** whole plugin — no `AVAudioSession.interruptionNotification`,
`UIApplication.didEnterBackground`, or `AVCaptureSession` interruption handling.

**Problem:** ReplayKit may stop or stall when the app backgrounds, on a phone call, or on an
audio-session interruption (Siri, another app grabbing the mic). Today this only surfaces if
ReplayKit happens to deliver an error; otherwise the writer may sit idle and produce a
truncated/short file with no signal. Closely related to M1.

**Fix:** Observe `AVAudioSession.interruptionNotification` and app background transitions; on a
non-resumable interruption, finalize or fail the recording deterministically and notify via the
M1 event channel. Re-activate the host audio session on `.ended` if the plugin changed it.

### M5 — Documents-directory index force-access

**Where:** `FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]`
(line 88–91).

**Problem:** `[0]` will crash if the array is empty. Practically the Documents directory
always exists, so this is low probability — but it is an avoidable force-index in a "must not
crash" library.

**Fix:** Use `.first` with a graceful `FlutterError("FILE_ERROR", ...)` fallback. (Borderline
LOW; grouped here because it's a guaranteed crash if it ever hits.)

---

## LOW risk / polish

### L1 — Podspec deployment target (10.0) vs. actual minimum (iOS 11)
`flutter_screen_recording.podspec` sets `s.ios.deployment_target = '10.0'`, but every code
path is gated `@available(iOS 11.0, *)` and the README says 11.0+. Raise the podspec to `'11.0'`
to match reality (or higher — `startCapture` is 11+, and you may want 12/13 for the scene APIs).
This also lets you delete the now-dead iOS-10 fallback branches.

### L2 — Logging via `print`
Failures are logged with `print(...)` (e.g. lines 316, 630, 637). These are stripped in release
inconsistently and are not filterable. Switch to `os_log`/`Logger` with a dedicated subsystem,
gated for debug verbosity, so production crashes/issues are diagnosable from device logs.

### L3 — Back-pressure depth is a hard-coded magic number
`videoBufferBackpressure = DispatchSemaphore(value: 2)` (line 18). Reasonable default, but
document why "2" and consider exposing it / scaling it, since your ML Kit pipeline competes for
memory and CPU. (No correctness bug — the `defer`/`signal` pairing is balanced.)

### L4 — Podspec metadata placeholders
`homepage`, `author`, `license` email are still template placeholders
(`http://example.com`, `email@example.com`). Cosmetic, but worth fixing before publishing.

### L5 — No `RPScreenRecorder.delegate` for availability changes
Optional hardening tied to H3/M4: setting the delegate lets the plugin react to the system
revoking screen-recording availability mid-session instead of discovering it only on the next
buffer/stop.

---

## Suggested implementation order (for the fixing agent)

1. **H1** — add PTS validity guard + ObjC try/catch bridge for `startSession`/setup. *(Removes
   the most likely remaining hard-crash; small, self-contained.)*
2. **H2** — mic permission preflight + graceful video-only fallback + README/Info.plist docs +
   audio-session-vs-camera guidance. *(Directly addresses the concurrent-camera crash risk.)*
3. **M1 + M2** — event channel for async failures, one-shot result guard, start/stop watchdog.
   *(Eliminates silent-failure and hung-Future state desyncs.)*
4. **M3** — convert start/stop to fully async on `writerQueue`. *(Removes main-thread stalls.)*
5. **H3 + M4 + L5** — availability preflight, delegate, interruption/lifecycle observers.
6. **M5, L1–L4** — defensive index, podspec target, logging, magic-number doc, metadata.

### Cross-cutting principle
Every call into AVFoundation/ReplayKit that can throw an `NSException` (`startSession`,
`addInput`, `markAsFinished`, `appendSampleBuffer:`) must go through an ObjC `@try/@catch`
bridge, because Swift `do/catch` cannot catch them. `FSRSampleBufferAppender` is the model;
extend that pattern to the writer-setup path. Combined with PTS validity checks and graceful
failure reporting (M1), no AVFoundation error should ever be able to terminate the host app.
