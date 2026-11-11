import AVFoundation
import CoreImage
import CoreVideo
import Metal
import RealityKit
import UIKit

struct VideoSettings {
    /// Record the microphone along with the picture.
    var recordAudio = false
    /// 0 = no limit.
    var maxDurationMillis = 0
}

/// A finished video file, still in the app's temporary folder.
struct Recording {
    let file: URL
    let hasAudio: Bool
}

/// Records the rendered 3D view (camera feed + characters, never the SwiftUI controls) into an H.264 file,
/// 1080 x 1920, with the logo drawn into every frame.
///
/// How a frame travels:
///  1. RealityKit calls the view's post-process callback on its render thread once per frame. The callback copies
///     the frame to the screen unchanged, and for every frame that is due it also scales the frame into a pixel
///     buffer of the output size, on the GPU, inside the command buffer RealityKit handed in.
///  2. When that command buffer has completed, the pixel buffer holds the frame. On the recorder's own queue the
///     logo is drawn onto it with Core Graphics and the buffer is appended to the asset writer.
///
/// The callback is installed only while a recording runs, so the normal rendering path is untouched otherwise.
/// Start / stop / attach are main-actor calls; the frame work happens on RealityKit's render thread and on the
/// recorder's own queue.
final class SceneRecorder: @unchecked Sendable {

    static let outputWidth = 1080
    static let outputHeight = 1920
    static let framesPerSecond = 30
    static let videoBitRate = 12_000_000

    /// Name of a take while it sits in the temporary folder: `take-<uuid>.mp4`. The capture controller looks for
    /// these names when it collects what a killed process left behind.
    static let takePrefix = "take-"
    static let takeSuffix = ".mp4"

    let overlay: LogoOverlay

    /// Called on the main actor for every way a recording can end; nil when nothing usable was written.
    @MainActor var onRecordingFinished: ((Recording?) -> Void)?

    @MainActor private weak var arView: ARView?
    @MainActor private(set) var isRecording = false

    private let microphone = MicrophoneCapture()
    private let lock = NSLock()
    /// Guarded by `lock`: read on the render thread, written on the main actor.
    private var session: RecordingSession?

    init(overlay: LogoOverlay) {
        self.overlay = overlay
    }

    /// Length of the running recording, counted from its first frame.
    var elapsedMillis: Int {
        currentSession()?.elapsedMillis ?? 0
    }

    @MainActor
    func attach(to view: ARView) {
        arView = view
    }

    @MainActor
    func detach(from view: ARView) {
        guard arView === view else { return }
        // The view is going away and with it the frames: end the take and keep the file.
        if isRecording { stopRecording() }
        arView = nil
    }

    /// Starts recording the attached view. Returns false when there is no view to record or the encoder refused.
    @MainActor
    func startRecording(settings: VideoSettings) -> Bool {
        guard !isRecording, let view = arView, view.window != nil, view.bounds.width > 0 else { return false }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(SceneRecorder.takePrefix)\(UUID().uuidString)\(SceneRecorder.takeSuffix)")
        guard let newSession = try? RecordingSession(
            url: url,
            recordAudio: settings.recordAudio,
            maxDurationMillis: settings.maxDurationMillis,
            overlay: overlay
        ) else { return false }
        newSession.onLimitReached = limitCallback()
        if newSession.wantsAudio {
            microphone.onSampleBuffer = SceneRecorder.audioSink(for: newSession)
            _ = microphone.start()
        }
        setSession(newSession)
        isRecording = true
        view.renderCallbacks.postProcess = postProcessCallback()
        return true
    }

    /// Ends the running recording; `onRecordingFinished` follows once the file is closed.
    @MainActor
    func stopRecording() {
        guard isRecording, let finished = currentSession() else { return }
        isRecording = false
        arView?.renderCallbacks.postProcess = nil
        setSession(nil)
        microphone.stop()
        microphone.onSampleBuffer = nil
        finished.finish(finishCallback())
    }

    // MARK: callbacks that run off the main thread

    // These closures are called on the render thread, the microphone queue and the writer queue. They are built in
    // functions that belong to no actor, so that the closures do not count as main-actor code themselves.

    private nonisolated func postProcessCallback() -> (ARView.PostProcessContext) -> Void {
        return { [weak self] context in
            self?.postProcess(context)
        }
    }

    private nonisolated func limitCallback() -> () -> Void {
        return { [weak self] in
            Task { @MainActor [weak self] in
                self?.stopRecording()
            }
        }
    }

    private nonisolated func finishCallback() -> (Recording?) -> Void {
        return { [weak self] recording in
            Task { @MainActor [weak self] in
                self?.onRecordingFinished?(recording)
            }
        }
    }

    private nonisolated static func audioSink(for session: RecordingSession) -> (CMSampleBuffer) -> Void {
        return { [weak session] buffer in
            session?.appendAudio(buffer)
        }
    }

    // MARK: render thread

    private func postProcess(_ context: ARView.PostProcessContext) {
        // A registered callback has to write the output texture or nothing is displayed: pass the frame through.
        if let blit = context.commandBuffer.makeBlitCommandEncoder() {
            blit.copy(from: context.sourceColorTexture, to: context.targetColorTexture)
            blit.endEncoding()
        }
        currentSession()?.encodeFrame(context)
    }

    private func currentSession() -> RecordingSession? {
        lock.lock()
        defer { lock.unlock() }
        return session
    }

    private func setSession(_ value: RecordingSession?) {
        lock.lock()
        session = value
        lock.unlock()
    }
}

/// One video file being written. Three threads meet here: RealityKit's render thread (`encodeFrame`), the
/// microphone's queue (`appendAudio`) and the writer queue that everything touching the asset writer runs on.
private final class RecordingSession: @unchecked Sendable {

    let wantsAudio: Bool
    var onLimitReached: (() -> Void)?

    private let url: URL
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    /// The recorder's own pool. The adaptor has one too, but only once the writer's session has started, and the
    /// session starts with the first frame, which needs a buffer first.
    private let pixelBufferPool: CVPixelBufferPool
    private let audioInput: AVAssetWriterInput?
    private let overlay: LogoOverlay
    private let maxDuration: CMTime?
    private let queue = DispatchQueue(label: "farm.monastyr2.ar.recorder")
    private let width = SceneRecorder.outputWidth
    private let height = SceneRecorder.outputHeight

    // Render thread only.
    private var textureCache: CVMetalTextureCache?
    private var ciContext: CIContext?
    private var lastEncodedSeconds = -Double.infinity

    // Writer queue only.
    private var sessionStarted = false
    private var startTime = CMTime.invalid
    private var lastVideoTime = CMTime.invalid
    private var frameCount = 0
    private var wroteAudio = false
    private var finishing = false
    private var limitReported = false

    // Any thread, guarded by `stateLock`.
    private let stateLock = NSLock()
    private var accepting = true
    private var firstFrameSeconds: Double?

    init(url: URL, recordAudio: Bool, maxDurationMillis: Int, overlay: LogoOverlay) throws {
        let newWriter = try AVAssetWriter(outputURL: url, fileType: .mp4)

        let compression: [String: Any] = [
            AVVideoAverageBitRateKey: SceneRecorder.videoBitRate,
            AVVideoExpectedSourceFrameRateKey: SceneRecorder.framesPerSecond,
            AVVideoMaxKeyFrameIntervalKey: SceneRecorder.framesPerSecond * 2,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
        ]
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264.rawValue,
            AVVideoWidthKey: SceneRecorder.outputWidth,
            AVVideoHeightKey: SceneRecorder.outputHeight,
            AVVideoCompressionPropertiesKey: compression,
        ]
        let newVideoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        newVideoInput.expectsMediaDataInRealTime = true
        // IOSurface-backed and Metal-compatible, so the GPU can render straight into the buffers.
        // (The same attributes describe the recorder's own pool and tell the adaptor what to expect.)
        let bufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: SceneRecorder.outputWidth,
            kCVPixelBufferHeightKey as String: SceneRecorder.outputHeight,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        let newAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: newVideoInput, sourcePixelBufferAttributes: bufferAttributes
        )
        var createdPool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, bufferAttributes as CFDictionary, &createdPool)
        guard let newPool = createdPool else { throw CocoaError(.fileWriteUnknown) }
        guard newWriter.canAdd(newVideoInput) else { throw CocoaError(.fileWriteUnknown) }
        newWriter.add(newVideoInput)

        var newAudioInput: AVAssetWriterInput?
        if recordAudio {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 96_000,
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            if newWriter.canAdd(input) {
                newWriter.add(input)
                newAudioInput = input
            }
        }

        guard newWriter.startWriting() else { throw newWriter.error ?? CocoaError(.fileWriteUnknown) }

        self.url = url
        self.overlay = overlay
        writer = newWriter
        videoInput = newVideoInput
        adaptor = newAdaptor
        pixelBufferPool = newPool
        audioInput = newAudioInput
        wantsAudio = newAudioInput != nil
        maxDuration = maxDurationMillis > 0 ? CMTime(value: CMTimeValue(maxDurationMillis), timescale: 1000) : nil
    }

    var elapsedMillis: Int {
        stateLock.lock()
        let first = firstFrameSeconds
        stateLock.unlock()
        guard let first else { return 0 }
        return max(0, Int((CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())) - first) * 1000))
    }

    private var isAccepting: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return accepting
    }

    // MARK: render thread

    /// Scales the frame RealityKit just rendered into a pixel buffer, as part of RealityKit's own command buffer.
    func encodeFrame(_ context: ARView.PostProcessContext) {
        guard isAccepting, videoInput.isReadyForMoreMediaData else { return }
        let hostTime = CMClockGetTime(CMClockGetHostTimeClock())
        let seconds = CMTimeGetSeconds(hostTime)
        // The view renders at up to 60 (or 120) frames a second; the file gets `framesPerSecond`.
        guard seconds - lastEncodedSeconds >= 0.9 / Double(SceneRecorder.framesPerSecond) else { return }

        var newBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pixelBufferPool, &newBuffer) == kCVReturnSuccess,
              let pixelBuffer = newBuffer
        else { return }

        if textureCache == nil {
            var cache: CVMetalTextureCache?
            CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, context.device, nil, &cache)
            textureCache = cache
        }
        guard let cache = textureCache else { return }

        let source = context.sourceColorTexture
        // Colour management is switched off below, so numbers go from texture to texture as they are sampled. A
        // source that samples as linear light is therefore written through an sRGB view of the pixel buffer, which
        // encodes on the way in; a source that already holds display-encoded values is written as it is.
        let targetFormat: MTLPixelFormat = RecordingSession.samplesLinearLight(source.pixelFormat) ? .bgra8Unorm_srgb : .bgra8Unorm
        var newTexture: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pixelBuffer, nil, targetFormat, width, height, 0, &newTexture
        ) == kCVReturnSuccess,
            let metalTexture = newTexture,
            let target = CVMetalTextureGetTexture(metalTexture)
        else { return }

        if ciContext == nil {
            ciContext = CIContext(mtlDevice: context.device, options: [
                .workingColorSpace: NSNull(),
                .outputColorSpace: NSNull(),
                .cacheIntermediates: false,
            ])
        }
        guard let renderer = ciContext,
              let image = CIImage(mtlTexture: source, options: [.colorSpace: NSNull()]),
              image.extent.width > 0, image.extent.height > 0
        else { return }
        // The stage box is 9:16 like the file, so this is a plain resize.
        let scaled = image.transformed(by: CGAffineTransform(
            scaleX: CGFloat(width) / image.extent.width,
            y: CGFloat(height) / image.extent.height
        ))
        let destination = CIRenderDestination(mtlTexture: target, commandBuffer: context.commandBuffer)
        // Texture to texture: row 0 of the source stays row 0 of the target.
        destination.isFlipped = false
        destination.colorSpace = nil
        do {
            _ = try renderer.startTask(toRender: scaled, to: destination)
        } catch {
            return
        }
        lastEncodedSeconds = seconds

        // The pixels exist once the GPU has run the command buffer. `metalTexture` is captured to keep the
        // texture alive until then.
        context.commandBuffer.addCompletedHandler { [self] _ in
            queue.async {
                self.append(pixelBuffer, keeping: metalTexture, at: hostTime)
            }
        }
    }

    /// True for formats whose sampled values are linear light: sRGB formats (decoded by the GPU on read) and
    /// floating-point render targets.
    private static func samplesLinearLight(_ format: MTLPixelFormat) -> Bool {
        switch format {
        case .bgra8Unorm_srgb, .rgba8Unorm_srgb, .bgr10_xr_srgb, .bgra10_xr_srgb,
             .rgba16Float, .rgba32Float, .rg11b10Float, .rgb9e5Float:
            return true
        default:
            return false
        }
    }

    // MARK: writer queue

    private func append(_ pixelBuffer: CVPixelBuffer, keeping texture: CVMetalTexture, at time: CMTime) {
        _ = texture
        guard !finishing, writer.status == .writing else { return }
        // Only against a frame that was really written: an invalid time compares as later than every real one.
        if lastVideoTime.isValid, CMTimeCompare(time, lastVideoTime) <= 0 { return }

        drawOverlay(on: pixelBuffer)

        if !sessionStarted {
            writer.startSession(atSourceTime: time)
            sessionStarted = true
            startTime = time
            stateLock.lock()
            firstFrameSeconds = CMTimeGetSeconds(time)
            stateLock.unlock()
        }
        guard videoInput.isReadyForMoreMediaData else { return }
        if adaptor.append(pixelBuffer, withPresentationTime: time) {
            frameCount += 1
            lastVideoTime = time
        }
        if let limit = maxDuration, !limitReported, CMTimeCompare(CMTimeSubtract(time, startTime), limit) >= 0 {
            limitReported = true
            onLimitReached?()
        }
    }

    private func drawOverlay(on pixelBuffer: CVPixelBuffer) {
        guard CVPixelBufferLockBaseAddress(pixelBuffer, []) == kCVReturnSuccess else { return }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        // 32BGRA in memory is "premultiplied first, little-endian 32-bit" to Core Graphics.
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let context = CGContext(
            data: base,
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ) else { return }
        overlay.draw(in: context, width: context.width, height: context.height)
    }

    /// Called on the microphone's queue.
    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        guard isAccepting else { return }
        queue.async {
            guard !self.finishing, self.sessionStarted, self.writer.status == .writing,
                  let input = self.audioInput, input.isReadyForMoreMediaData
            else { return }
            // Sound from before the first picture has no place on the time line.
            let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            guard CMTimeCompare(time, self.startTime) >= 0 else { return }
            if input.append(sampleBuffer) { self.wroteAudio = true }
        }
    }

    /// Closes the file. `completion` runs on an arbitrary queue; nil means nothing usable was recorded.
    func finish(_ completion: @escaping (Recording?) -> Void) {
        stateLock.lock()
        accepting = false
        stateLock.unlock()
        queue.async {
            self.finishing = true
            guard self.sessionStarted, self.frameCount > 0, self.writer.status == .writing else {
                self.writer.cancelWriting()
                try? FileManager.default.removeItem(at: self.url)
                completion(nil)
                return
            }
            self.videoInput.markAsFinished()
            self.audioInput?.markAsFinished()
            let writer = self.writer
            let recording = Recording(file: self.url, hasAudio: self.wroteAudio)
            writer.finishWriting {
                if writer.status == .completed {
                    completion(recording)
                } else {
                    try? FileManager.default.removeItem(at: recording.file)
                    completion(nil)
                }
            }
        }
    }
}
