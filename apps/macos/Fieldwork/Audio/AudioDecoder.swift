import AVFoundation
import DrillMedia

/// Native WAV/MP3 decoding through AVFoundation. Produces a mono float view for
/// waveform peaks; the embedded source bytes are never modified.
enum AudioDecoder {
    struct DecodeError: LocalizedError {
        var errorDescription: String?
    }

    static func decode(url: URL) throws -> PCMAudio {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        let frames = file.length
        guard frames > 0, format.sampleRate > 0 else { throw DecodeError(errorDescription: "The file contains no audio samples.") }
        guard frames < 48_000 * 60 * 60 else { throw DecodeError(errorDescription: "Audio longer than one hour is not supported yet.") }
        let channels = Int(format.channelCount)
        var mono = [Float](repeating: 0, count: Int(frames))
        let chunk: AVAudioFrameCount = 1 << 16
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else {
            throw DecodeError(errorDescription: "Could not allocate an audio buffer.")
        }
        var offset = 0
        while file.framePosition < frames {
            try file.read(into: buffer, frameCount: chunk)
            let n = Int(buffer.frameLength)
            if n == 0 { break }
            guard let data = buffer.floatChannelData else { break }
            let scale = 1 / Float(channels)
            for i in 0..<n where offset + i < mono.count {
                var sum: Float = 0
                for c in 0..<channels { sum += data[c][i] }
                mono[offset + i] = sum * scale
            }
            offset += n
        }
        return PCMAudio(sampleRate: format.sampleRate, channelCount: channels, frameCount: frames, mono: mono)
    }

    /// AVAudioFile reads from URLs, so embedded bytes are written once to a
    /// private cache file named by content hash.
    static func materialize(_ data: Data, name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("FieldworkAudio", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) { try data.write(to: url, options: .atomic) }
        return url
    }
}
