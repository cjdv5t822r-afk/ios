import AVFoundation
import CoreMedia

/// Delivers microphone audio as sample buffers while a recording runs.
///
/// An audio-only `AVCaptureSession`: it works the same in AR and in Studio and leaves the AR session's own camera
/// pipeline alone (ARKit could deliver audio itself, but only after its session is re-run with another
/// configuration, which interrupts tracking at the very moment a take starts).
final class MicrophoneCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {

    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let queue = DispatchQueue(label: "farm.monastyr2.ar.microphone")
    private var configured = false

    private let sinkLock = NSLock()
    private var sink: ((CMSampleBuffer) -> Void)?

    /// Called on the microphone's own queue for every buffer, with time stamps on the host clock.
    /// Set from the main thread while buffers may still be arriving, hence the lock.
    var onSampleBuffer: ((CMSampleBuffer) -> Void)? {
        get {
            sinkLock.lock()
            defer { sinkLock.unlock() }
            return sink
        }
        set {
            sinkLock.lock()
            sink = newValue
            sinkLock.unlock()
        }
    }

    /// Starts capturing. Returns false when there is no usable microphone (the recording is then silent).
    func start() -> Bool {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return false }
        if !configured {
            guard let device = AVCaptureDevice.default(for: .audio),
                  let input = try? AVCaptureDeviceInput(device: device)
            else { return false }
            session.beginConfiguration()
            guard session.canAddInput(input), session.canAddOutput(output) else {
                session.commitConfiguration()
                return false
            }
            session.addInput(input)
            session.addOutput(output)
            output.setSampleBufferDelegate(self, queue: queue)
            session.commitConfiguration()
            configured = true
        }
        // startRunning blocks until the hardware is up; keep that off the main thread.
        queue.async { [session] in
            if !session.isRunning { session.startRunning() }
        }
        return true
    }

    func stop() {
        queue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        onSampleBuffer?(hostTimed(sampleBuffer))
    }

    /// The video frames are stamped with the host clock; the capture session may run on another one (the audio
    /// device's). Audio buffers are re-stamped so both tracks share a time line.
    private func hostTimed(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer {
        guard let clock = session.synchronizationClock else { return sampleBuffer }
        let hostClock = CMClockGetHostTimeClock()
        if CFEqual(clock, hostClock) { return sampleBuffer }
        var timing = CMSampleTimingInfo()
        guard CMSampleBufferGetSampleTimingInfo(sampleBuffer, at: 0, timingInfoOut: &timing) == noErr else { return sampleBuffer }
        timing.presentationTimeStamp = CMSyncConvertTime(timing.presentationTimeStamp, from: clock, to: hostClock)
        timing.decodeTimeStamp = .invalid
        var retimed: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &retimed
        )
        guard status == noErr, let retimed else { return sampleBuffer }
        return retimed
    }
}
