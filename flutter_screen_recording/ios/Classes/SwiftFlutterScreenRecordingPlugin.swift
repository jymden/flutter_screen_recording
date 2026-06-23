import AVFoundation
import Flutter
import ImageIO
import ReplayKit
import UIKit

public class SwiftFlutterScreenRecordingPlugin: NSObject, FlutterPlugin {
    private enum WriterSetupResult {
        case success
        case alreadyRecording
        case failure(Error)
    }

    private let recorder = RPScreenRecorder.shared()
    private let writerQueue = DispatchQueue(label: "flutter_screen_recording.writer")
    private let targetVideoFramesPerSecond: Int32 = 30
    private let maxEncodedVideoLongEdge = 1_440
    private let videoBufferBackpressure = DispatchSemaphore(value: 2)

    // These properties are read and written only on writerQueue.
    private var videoWriter: AVAssetWriter?
    private var videoWriterInput: AVAssetWriterInput?
    private var audioWriterInput: AVAssetWriterInput?
    private var videoOutputURL: URL?
    private var recordingID: UUID?
    private var isRecording = false
    private var recordAudio = false
    private var sessionStarted = false
    private var sessionStartTime: CMTime?
    private var lastWrittenVideoTimestamp: CMTime?
    private var startInterfaceOrientation: UIInterfaceOrientation = .unknown

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "flutter_screen_recording",
            binaryMessenger: registrar.messenger()
        )
        let instance = SwiftFlutterScreenRecordingPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "startRecordScreen":
            guard let args = call.arguments as? [String: Any],
                let name = args["name"] as? String,
                let includeAudio = args["audio"] as? Bool
            else {
                deliver(
                    FlutterError(
                        code: "INVALID_ARGUMENTS",
                        message: "Missing arguments",
                        details: nil
                    ),
                    to: result
                )
                return
            }

            startRecording(videoName: name, recordAudio: includeAudio, result: result)

        case "stopRecordScreen":
            stopRecording(result: result)

        default:
            deliver(FlutterMethodNotImplemented, to: result)
        }
    }

    func startRecording(
        videoName: String,
        recordAudio: Bool,
        result: @escaping FlutterResult
    ) {
        guard #available(iOS 11.0, *) else {
            deliver(
                FlutterError(
                    code: "IOS_VERSION_ERROR",
                    message: "This feature is only available on iOS 11 or later",
                    details: nil
                ),
                to: result
            )
            return
        }

        let orientation = currentInterfaceOrientation()
        let documentsURL = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0]
        let outputURL = documentsURL.appendingPathComponent("\(videoName).mp4")

        let newRecordingID = UUID()

        // Creating the writer is part of its lifecycle and is therefore serialized too.
        let setupResult = writerQueue.sync { () -> WriterSetupResult in
            guard !self.isRecording, self.videoWriter == nil else {
                return .alreadyRecording
            }

            do {
                if FileManager.default.fileExists(atPath: outputURL.path) {
                    try FileManager.default.removeItem(at: outputURL)
                }

                self.videoWriter = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
                self.videoOutputURL = outputURL
                self.recordingID = newRecordingID
                self.isRecording = true
                self.recordAudio = recordAudio
                self.sessionStarted = false
                self.startInterfaceOrientation = orientation
                return .success
            } catch {
                self.resetWriterState()
                return .failure(error)
            }
        }

        switch setupResult {
        case .alreadyRecording:
            deliver(
                FlutterError(
                    code: "ALREADY_RECORDING",
                    message: "Recording is already in progress",
                    details: nil
                ),
                to: result
            )
            return

        case .failure(let error):
            deliver(
                FlutterError(
                    code: "FILE_ERROR",
                    message: "Unable to create or replace the video file",
                    details: error.localizedDescription
                ),
                to: result
            )
            return

        case .success:
            break
        }

        recorder.isMicrophoneEnabled = recordAudio
        recorder.startCapture(
            handler: { [weak self] sampleBuffer, sampleBufferType, error in
                guard let self = self else { return }

                if let error = error {
                    self.writerQueue.async {
                        guard self.recordingID == newRecordingID, self.isRecording else {
                            return
                        }

                        self.failRecording(
                            id: newRecordingID,
                            reason: "ReplayKit capture failed: \(error.localizedDescription)"
                        )
                    }
                    return
                }

                if sampleBufferType == .video {
                    switch self.videoBufferBackpressure.wait(timeout: .now()) {
                    case .success:
                        break
                    case .timedOut:
                        return
                    }
                }

                self.writerQueue.async {
                    let shouldSignalVideoBuffer = sampleBufferType == .video
                    defer {
                        if shouldSignalVideoBuffer {
                            self.videoBufferBackpressure.signal()
                        }
                    }

                    guard self.recordingID == newRecordingID, self.isRecording else {
                        return
                    }

                    switch sampleBufferType {
                    case .video:
                        self.handleVideoBuffer(sampleBuffer, recordingID: newRecordingID)

                    case .audioMic where self.recordAudio:
                        self.handleAudioBuffer(sampleBuffer, recordingID: newRecordingID)

                    default:
                        break
                    }
                }
            },
            completionHandler: { [weak self] error in
                guard let self = self else { return }

                self.writerQueue.async {
                    let recordingIsCurrent = self.recordingID == newRecordingID

                    if let error = error {
                        if recordingIsCurrent {
                            self.isRecording = false
                            self.cancelAndResetWriterState(removeOutput: true)
                        }

                        self.deliver(
                            FlutterError(
                                code: "CAPTURE_ERROR",
                                message: "Failed to start screen recording",
                                details: error.localizedDescription
                            ),
                            to: result
                        )
                    } else if recordingIsCurrent {
                        self.deliver(true, to: result)
                    } else {
                        self.deliver(
                            FlutterError(
                                code: "CAPTURE_ERROR",
                                message: "Screen recording ended before capture started",
                                details: nil
                            ),
                            to: result
                        )
                    }
                }
            }
        )
    }

    @available(iOS 11.0, *)
    private func handleVideoBuffer(_ sampleBuffer: CMSampleBuffer, recordingID: UUID) {
        guard self.recordingID == recordingID,
            isRecording,
            CMSampleBufferDataIsReady(sampleBuffer),
            let writer = videoWriter
        else {
            return
        }

        if !sessionStarted {
            guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
                failRecording(id: recordingID, reason: "Video buffer has no format description")
                return
            }

            let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
            let rawWidth = Int(dimensions.width)
            let rawHeight = Int(dimensions.height)
            let encodedSize = encodedVideoSize(width: rawWidth, height: rawHeight)

            guard encodedSize.width > 0, encodedSize.height > 0 else {
                failRecording(
                    id: recordingID,
                    reason: "ReplayKit returned invalid video dimensions \(rawWidth)x\(rawHeight)"
                )
                return
            }

            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: encodedSize.width,
                AVVideoHeightKey: encodedSize.height,
                AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: bitrate(
                        width: encodedSize.width,
                        height: encodedSize.height
                    ),
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264MainAutoLevel,
                    AVVideoExpectedSourceFrameRateKey: targetVideoFramesPerSecond,
                    AVVideoMaxKeyFrameIntervalKey: targetVideoFramesPerSecond * 2,
                    AVVideoAllowFrameReorderingKey: false,
                ],
            ]

            let newVideoInput = AVAssetWriterInput(
                mediaType: .video,
                outputSettings: videoSettings
            )
            newVideoInput.expectsMediaDataInRealTime = true
            // AVAssetWriter requires this metadata transform before startWriting().
            newVideoInput.transform = videoTransform(for: sampleBuffer)

            guard writer.canAdd(newVideoInput) else {
                failRecording(id: recordingID, reason: "AVAssetWriter cannot add the video input")
                return
            }

            do {
                try FSRAssetWriterBridge.add(newVideoInput, to: writer)
            } catch {
                failRecording(
                    id: recordingID,
                    reason: "AVAssetWriter failed to add the video input: \(error.localizedDescription)"
                )
                return
            }
            videoWriterInput = newVideoInput

            if recordAudio {
                let audioSettings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 44_100,
                    AVNumberOfChannelsKey: 2,
                ]
                let newAudioInput = AVAssetWriterInput(
                    mediaType: .audio,
                    outputSettings: audioSettings
                )
                newAudioInput.expectsMediaDataInRealTime = true

                if writer.canAdd(newAudioInput) {
                    do {
                        try FSRAssetWriterBridge.add(newAudioInput, to: writer)
                        audioWriterInput = newAudioInput
                    } catch {
                        // Video is still useful if the mic input cannot be added.
                        print("flutter_screen_recording: failed to add the audio input; recording without audio: \(error.localizedDescription)")
                    }
                } else {
                    // Video is still useful if this device cannot add the requested mic input.
                    print("flutter_screen_recording: AVAssetWriter cannot add the audio input; recording without audio")
                }
            }

            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            // startSession(atSourceTime:) throws an uncatchable NSException if the
            // time is not numeric, so reject such a first frame up front.
            guard presentationTime.isNumeric else {
                failRecording(
                    id: recordingID,
                    reason: "First video buffer has a non-numeric presentation timestamp"
                )
                return
            }

            do {
                try FSRAssetWriterBridge.startWriting(writer, atSourceTime: presentationTime)
            } catch {
                failRecording(
                    id: recordingID,
                    reason: "AVAssetWriter failed to start: \(error.localizedDescription)"
                )
                return
            }

            sessionStartTime = presentationTime
            sessionStarted = true
        }

        guard writer.status == .writing else {
            if writer.status == .failed || writer.status == .cancelled {
                failRecording(
                    id: recordingID,
                    reason: "AVAssetWriter stopped while recording video: \(writer.error?.localizedDescription ?? "unknown error")"
                )
            }
            return
        }

        guard let input = videoWriterInput,
            input.isReadyForMoreMediaData
        else {
            return
        }

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if shouldDropVideoFrame(at: presentationTime) {
            return
        }

        do {
            try FSRSampleBufferAppender.append(sampleBuffer, to: input)
            lastWrittenVideoTimestamp = presentationTime
        } catch {
            failRecording(
                id: recordingID,
                reason: "Failed to append a video buffer: \(error.localizedDescription)"
            )
        }
    }

    @available(iOS 11.0, *)
    private func handleAudioBuffer(_ sampleBuffer: CMSampleBuffer, recordingID: UUID) {
        guard self.recordingID == recordingID,
            isRecording,
            sessionStarted,
            CMSampleBufferDataIsReady(sampleBuffer),
            let writer = videoWriter,
            writer.status == .writing,
            let input = audioWriterInput,
            input.isReadyForMoreMediaData
        else {
            return
        }

        // The session is started from the first video frame, so mic samples can
        // carry timestamps that are invalid or earlier than the session start.
        // Appending those makes appendSampleBuffer: throw, so drop them instead.
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if shouldDropAudioBuffer(at: presentationTime) {
            return
        }

        do {
            try FSRSampleBufferAppender.append(sampleBuffer, to: input)
        } catch {
            failRecording(
                id: recordingID,
                reason: "Failed to append an audio buffer: \(error.localizedDescription)"
            )
        }
    }

    func stopRecording(result: @escaping FlutterResult) {
        guard #available(iOS 11.0, *) else {
            deliver(
                FlutterError(
                    code: "IOS_VERSION_ERROR",
                    message: "This feature is only available on iOS 11 or later",
                    details: nil
                ),
                to: result
            )
            return
        }

        let activeRecordingID = writerQueue.sync { () -> UUID? in
            if self.isRecording, let id = self.recordingID {
                self.isRecording = false
                return id
            }
            return nil
        }

        guard let stoppingRecordingID = activeRecordingID else {
            deliver(
                FlutterError(
                    code: "NOT_RECORDING",
                    message: "No recording in progress",
                    details: nil
                ),
                to: result
            )
            return
        }

        recorder.stopCapture { [weak self] captureError in
            guard let self = self else { return }

            self.writerQueue.async {
                guard self.recordingID == stoppingRecordingID,
                    let writer = self.videoWriter
                else {
                    self.deliver(
                        FlutterError(
                            code: "STOP_ERROR",
                            message: "No active writer",
                            details: nil
                        ),
                        to: result
                    )
                    return
                }

                if let captureError = captureError {
                    self.cancelAndResetWriterState(removeOutput: true)
                    self.deliver(
                        FlutterError(
                            code: "STOP_ERROR",
                            message: "Failed to stop ReplayKit capture",
                            details: captureError.localizedDescription
                        ),
                        to: result
                    )
                    return
                }

                guard self.sessionStarted, writer.status == .writing else {
                    let writerError = writer.error?.localizedDescription
                    self.cancelAndResetWriterState(removeOutput: true)
                    self.deliver(
                        FlutterError(
                            code: "STOP_ERROR",
                            message: "No video frames were written",
                            details: writerError
                        ),
                        to: result
                    )
                    return
                }

                do {
                    if let videoInput = self.videoWriterInput {
                        try FSRAssetWriterBridge.markAsFinished(videoInput)
                    }
                    if let audioInput = self.audioWriterInput {
                        try FSRAssetWriterBridge.markAsFinished(audioInput)
                    }
                } catch {
                    self.cancelAndResetWriterState(removeOutput: true)
                    self.deliver(
                        FlutterError(
                            code: "STOP_ERROR",
                            message: "Failed to finalize the recording inputs",
                            details: error.localizedDescription
                        ),
                        to: result
                    )
                    return
                }

                let outputPath = self.videoOutputURL?.path

                do {
                    try FSRAssetWriterBridge.finishWriting(writer) { [weak self] in
                        guard let self = self else { return }

                        self.writerQueue.async {
                            guard self.recordingID == stoppingRecordingID else {
                                return
                            }

                            let status = writer.status
                            let writerError = writer.error?.localizedDescription
                            self.resetWriterState()

                            if status == .completed, let outputPath = outputPath {
                                self.deliver(outputPath, to: result)
                            } else {
                                self.removeOutputFile(atPath: outputPath)
                                self.deliver(
                                    FlutterError(
                                        code: "STOP_ERROR",
                                        message: "Failed to finish writing",
                                        details: writerError
                                    ),
                                    to: result
                                )
                            }
                        }
                    }
                } catch {
                    // finishWriting threw synchronously, so its completion handler
                    // will never run; report and clean up here instead.
                    self.cancelAndResetWriterState(removeOutput: true)
                    self.deliver(
                        FlutterError(
                            code: "STOP_ERROR",
                            message: "Failed to finish writing",
                            details: error.localizedDescription
                        ),
                        to: result
                    )
                }
            }
        }
    }

    @available(iOS 11.0, *)
    private func videoTransform(for sampleBuffer: CMSampleBuffer) -> CGAffineTransform {
        // Apple deprecated this key, so use it only when ReplayKit still supplies it.
        if let value = CMGetAttachment(
            sampleBuffer,
            key: RPVideoSampleOrientationKey as CFString,
            attachmentModeOut: nil
        ) as? NSNumber,
            let orientation = CGImagePropertyOrientation(rawValue: value.uint32Value)
        {
            return transform(for: orientation)
        }

        return transform(for: startInterfaceOrientation)
    }

    private func transform(for orientation: CGImagePropertyOrientation) -> CGAffineTransform {
        switch orientation {
        case .down, .downMirrored:
            return CGAffineTransform(rotationAngle: .pi)
        case .left, .leftMirrored:
            return CGAffineTransform(rotationAngle: .pi / 2)
        case .right, .rightMirrored:
            return CGAffineTransform(rotationAngle: -.pi / 2)
        default:
            return .identity
        }
    }

    private func transform(for orientation: UIInterfaceOrientation) -> CGAffineTransform {
        switch orientation {
        case .portraitUpsideDown:
            return CGAffineTransform(rotationAngle: .pi)
        case .landscapeLeft:
            return CGAffineTransform(rotationAngle: .pi / 2)
        case .landscapeRight:
            return CGAffineTransform(rotationAngle: -.pi / 2)
        default:
            return .identity
        }
    }

    private func bitrate(width: Int, height: Int) -> Int {
        switch width * height {
        case 3_000_000...:
            return 9_000_000
        case 2_000_000...:
            return 7_000_000
        case 1_000_000...:
            return 5_000_000
        default:
            return 3_500_000
        }
    }

    private func encodedVideoSize(width: Int, height: Int) -> (width: Int, height: Int) {
        let evenWidth = width - (width % 2)
        let evenHeight = height - (height % 2)
        let longEdge = max(evenWidth, evenHeight)

        guard evenWidth > 0, evenHeight > 0, longEdge > maxEncodedVideoLongEdge else {
            return (evenWidth, evenHeight)
        }

        let scale = Double(maxEncodedVideoLongEdge) / Double(longEdge)
        let scaledWidth = max(2, Int(Double(evenWidth) * scale))
        let scaledHeight = max(2, Int(Double(evenHeight) * scale))

        return (
            scaledWidth - (scaledWidth % 2),
            scaledHeight - (scaledHeight % 2)
        )
    }

    private func shouldDropVideoFrame(at timestamp: CMTime) -> Bool {
        guard timestamp.isValid,
            let lastWrittenVideoTimestamp = lastWrittenVideoTimestamp,
            lastWrittenVideoTimestamp.isValid
        else {
            return false
        }

        let minimumFrameDuration = CMTime(
            value: 1,
            timescale: targetVideoFramesPerSecond
        )
        return CMTimeCompare(
            CMTimeSubtract(timestamp, lastWrittenVideoTimestamp),
            minimumFrameDuration
        ) < 0
    }

    private func shouldDropAudioBuffer(at timestamp: CMTime) -> Bool {
        guard timestamp.isValid else {
            return true
        }

        guard let sessionStartTime = sessionStartTime, sessionStartTime.isValid else {
            return false
        }

        return CMTimeCompare(timestamp, sessionStartTime) < 0
    }

    private func currentInterfaceOrientation() -> UIInterfaceOrientation {
        if #available(iOS 13.0, *) {
            return UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive }?
                .interfaceOrientation ?? .unknown
        }

        return UIApplication.shared.statusBarOrientation
    }

    // Must be called on writerQueue.
    private func failRecording(id: UUID, reason: String) {
        guard recordingID == id else { return }

        print("flutter_screen_recording: \(reason)")
        isRecording = false
        cancelAndResetWriterState(removeOutput: true)

        DispatchQueue.main.async { [weak self] in
            self?.recorder.stopCapture { error in
                if let error = error {
                    print("flutter_screen_recording: failed to stop capture after writer failure: \(error.localizedDescription)")
                }
            }
        }
    }

    // Must be called on writerQueue.
    private func cancelAndResetWriterState(removeOutput: Bool) {
        let outputPath = videoOutputURL?.path
        videoWriter?.cancelWriting()
        resetWriterState()

        if removeOutput {
            removeOutputFile(atPath: outputPath)
        }
    }

    // Must be called on writerQueue.
    private func resetWriterState() {
        videoWriter = nil
        videoWriterInput = nil
        audioWriterInput = nil
        videoOutputURL = nil
        recordingID = nil
        isRecording = false
        recordAudio = false
        sessionStarted = false
        sessionStartTime = nil
        lastWrittenVideoTimestamp = nil
        startInterfaceOrientation = .unknown
    }

    private func removeOutputFile(atPath path: String?) {
        guard let path = path, FileManager.default.fileExists(atPath: path) else {
            return
        }
        try? FileManager.default.removeItem(atPath: path)
    }

    private func deliver(_ value: Any?, to result: @escaping FlutterResult) {
        DispatchQueue.main.async {
            result(value)
        }
    }
}
