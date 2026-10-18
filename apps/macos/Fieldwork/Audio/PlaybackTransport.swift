import AVFoundation
import QuartzCore

/// The playback clock. With audio loaded, time comes from the player node's
/// rendered sample position (the audio is the clock). Without audio, a
/// monotonic host clock runs through the same timing map. UI timers only read
/// `currentTime`; they never advance it.
@MainActor
final class PlaybackTransport {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private var file: AVAudioFile?
    private var sampleRate: Double = 44_100

    /// Audio time (seconds into the source file) where the current play/seek started.
    private var startSeconds: Double = 0
    private var hostStart: CFTimeInterval = 0
    private(set) var isPlaying = false
    /// Optional user output-latency calibration (seconds), stored per user, not in shows.
    var outputLatencyCalibration: Double = UserDefaults.standard.double(forKey: "FieldworkOutputLatencyCalibration")

    var rate: Double = 1 {
        didSet {
            let clamped = min(max(rate, 0.25), 2)
            let now = currentTime
            timePitch.rate = Float(clamped)
            if isPlaying && file == nil {
                startSeconds = now
                hostStart = CACurrentMediaTime()
            }
        }
    }

    init() {
        engine.attach(player)
        engine.attach(timePitch)
    }

    var hasAudio: Bool { file != nil }

    func load(url: URL) throws {
        stop()
        let file = try AVAudioFile(forReading: url)
        self.file = file
        sampleRate = file.processingFormat.sampleRate
        engine.disconnectNodeOutput(player)
        engine.disconnectNodeOutput(timePitch)
        engine.connect(player, to: timePitch, format: file.processingFormat)
        engine.connect(timePitch, to: engine.mainMixerNode, format: file.processingFormat)
        engine.prepare()
    }

    func unload() {
        stop()
        file = nil
    }

    func play(from seconds: Double) {
        stop()
        startSeconds = seconds
        guard let file else {
            hostStart = CACurrentMediaTime()
            isPlaying = true
            return
        }
        do {
            if !engine.isRunning { try engine.start() }
        } catch {
            NSLog("Fieldwork: audio engine failed to start: \(error)")
            hostStart = CACurrentMediaTime()
            isPlaying = true
            return
        }
        let startFrame = AVAudioFramePosition(max(0, seconds) * sampleRate)
        let remaining = file.length - startFrame
        guard remaining > 0 else {
            hostStart = CACurrentMediaTime()
            isPlaying = true
            return
        }
        player.scheduleSegment(file, startingFrame: startFrame, frameCount: AVAudioFrameCount(remaining), at: nil)
        if seconds < 0 {
            // Pre-roll: start the file later instead of seeking to a negative position.
            let delay = -seconds / Double(timePitch.rate)
            let hostTime = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: delay)
            player.play(at: AVAudioTime(hostTime: hostTime))
            startSeconds = 0
            hostStart = CACurrentMediaTime() + delay
        } else {
            player.play()
            hostStart = CACurrentMediaTime()
        }
        isPlaying = true
    }

    func pause() {
        let now = currentTime
        stop()
        startSeconds = now
    }

    func stop() {
        if player.isPlaying || isPlaying { player.stop() }
        isPlaying = false
    }

    func seek(to seconds: Double) {
        if isPlaying { play(from: seconds) } else { startSeconds = seconds }
    }

    /// Current audio time in seconds, from the rendered sample position.
    var currentTime: Double {
        guard isPlaying else { return startSeconds }
        if file != nil, let nodeTime = player.lastRenderTime, nodeTime.isSampleTimeValid,
           let playerTime = player.playerTime(forNodeTime: nodeTime) {
            let rendered = Double(playerTime.sampleTime) / playerTime.sampleRate
            let latency = engine.outputNode.presentationLatency + outputLatencyCalibration
            if rendered < 0 { return startSeconds + (CACurrentMediaTime() - hostStart) * Double(timePitch.rate) }
            return startSeconds + max(0, rendered - latency)
        }
        return startSeconds + (CACurrentMediaTime() - hostStart) * Double(timePitch.rate)
    }
}
