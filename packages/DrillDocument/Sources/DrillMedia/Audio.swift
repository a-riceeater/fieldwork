import Foundation

public enum AudioContainer: String, Sendable {
    case wav
    case mp3
}

public struct AudioError: Error, Equatable, CustomStringConvertible, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// Decoded PCM, downmixed to mono for waveform display. Source samples are
/// never modified or re-encoded; this is a read-only view for peaks.
public struct PCMAudio: Sendable {
    public var sampleRate: Double
    public var channelCount: Int
    public var frameCount: Int64
    /// Mono samples in -1...1.
    public var mono: [Float]

    public init(sampleRate: Double, channelCount: Int, frameCount: Int64, mono: [Float]) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.frameCount = frameCount
        self.mono = mono
    }

    public var duration: Double { Double(frameCount) / sampleRate }
}

public enum AudioSniffer {
    /// Identifies a supported container from its leading bytes.
    public static func detect(_ data: Data) -> AudioContainer? {
        let b = [UInt8](data.prefix(12))
        if b.count >= 12, b[0...3] == [0x52, 0x49, 0x46, 0x46], b[8...11] == [0x57, 0x41, 0x56, 0x45] { return .wav }
        if b.count >= 3, b[0...2] == [0x49, 0x44, 0x33] { return .mp3 }                 // ID3 tag
        if b.count >= 2, b[0] == 0xFF, b[1] & 0xE0 == 0xE0 { return .mp3 }               // MPEG frame sync
        return nil
    }
}

/// Original RIFF/WAVE decoder: PCM 8/16/24/32-bit integer and 32/64-bit float,
/// including WAVE_FORMAT_EXTENSIBLE. Compressed WAV variants are rejected.
public enum WAVDecoder {
    public static func decode(_ data: Data) throws -> PCMAudio {
        let bytes = [UInt8](data)
        guard AudioSniffer.detect(data) == .wav else { throw AudioError("Not a WAV file.") }
        func le16(_ i: Int) -> Int { Int(bytes[i]) | Int(bytes[i + 1]) << 8 }
        func le32(_ i: Int) -> Int { Int(bytes[i]) | Int(bytes[i + 1]) << 8 | Int(bytes[i + 2]) << 16 | Int(bytes[i + 3]) << 24 }

        var format: (tag: Int, channels: Int, rate: Int, bits: Int, blockAlign: Int)?
        var dataRange: Range<Int>?
        var p = 12
        while p + 8 <= bytes.count {
            let id = String(bytes: bytes[p..<(p + 4)], encoding: .ascii) ?? ""
            let size = le32(p + 4)
            let body = p + 8
            guard size >= 0, body + size <= bytes.count || id == "data" else { throw AudioError("The WAV file is truncated.") }
            if id == "fmt " {
                guard size >= 16 else { throw AudioError("The WAV format chunk is too short.") }
                var tag = le16(body)
                if tag == 0xFFFE, size >= 40 { tag = le16(body + 24) }   // extensible: subformat GUID starts with the tag
                format = (tag, le16(body + 2), le32(body + 4), le16(body + 14), le16(body + 12))
            } else if id == "data" {
                dataRange = body..<min(body + size, bytes.count)
                if format != nil { break }
            }
            p = body + size + (size & 1)
        }
        guard let f = format else { throw AudioError("The WAV file has no format chunk.") }
        guard let range = dataRange else { throw AudioError("The WAV file has no audio data.") }
        guard f.channels > 0, f.channels <= 32, f.rate > 0, f.blockAlign > 0 else { throw AudioError("The WAV format is invalid.") }
        let isFloat = f.tag == 3
        guard f.tag == 1 || isFloat else { throw AudioError("Compressed WAV (format \(f.tag)) is not supported; export PCM WAV or MP3.") }
        let bytesPerSample = f.bits / 8
        guard [1, 2, 3, 4, 8].contains(bytesPerSample), (!isFloat || bytesPerSample >= 4), f.blockAlign == bytesPerSample * f.channels else {
            throw AudioError("Unsupported WAV sample format (\(f.bits)-bit).")
        }
        let frames = range.count / f.blockAlign
        var mono = [Float](repeating: 0, count: frames)
        let scale = 1 / Float(f.channels)
        for frame in 0..<frames {
            var sum: Float = 0
            let base = range.lowerBound + frame * f.blockAlign
            for c in 0..<f.channels {
                let i = base + c * bytesPerSample
                let v: Float
                switch (bytesPerSample, isFloat) {
                case (1, _): v = (Float(bytes[i]) - 128) / 128
                case (2, _): v = Float(Int16(bitPattern: UInt16(le16(i)))) / 32768
                case (3, _):
                    let raw = Int32(bytes[i]) | Int32(bytes[i + 1]) << 8 | Int32(bytes[i + 2]) << 16
                    v = Float((raw << 8) >> 8) / 8_388_608
                case (4, false): v = Float(Int32(bitPattern: UInt32(truncatingIfNeeded: le32(i)))) / 2_147_483_648
                case (4, true): v = Float(bitPattern: UInt32(truncatingIfNeeded: le32(i)))
                default:
                    var bits: UInt64 = 0
                    for k in 0..<8 { bits |= UInt64(bytes[i + k]) << (8 * UInt64(k)) }
                    v = Float(Double(bitPattern: bits))
                }
                sum += v
            }
            mono[frame] = sum * scale
        }
        return PCMAudio(sampleRate: Double(f.rate), channelCount: f.channels, frameCount: Int64(frames), mono: mono)
    }

    /// Writes 16-bit PCM mono WAV (used for original generated demo audio and tests).
    public static func encode16(_ samples: [Float], sampleRate: Int) -> Data {
        var d = Data()
        func u32(_ v: Int) { d.append(contentsOf: [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]) }
        func u16(_ v: Int) { d.append(contentsOf: [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]) }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + samples.count * 2)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(sampleRate); u32(sampleRate * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(samples.count * 2)
        for s in samples {
            let v = Int16(max(-1, min(1, s)) * 32767)
            u16(Int(UInt16(bitPattern: v)))
        }
        return d
    }
}

/// Multi-resolution min/max peak cache. Level 0 bins `baseBin` frames; each
/// level above groups four bins. Rendering asks only for the visible range.
public struct WaveformPeaks: Sendable {
    public struct Level: Sendable {
        public var framesPerBin: Int
        public var minimum: [Float]
        public var maximum: [Float]
    }

    public let sampleRate: Double
    public let frameCount: Int64
    public let levels: [Level]

    public init(audio: PCMAudio, baseBin: Int = 64) {
        sampleRate = audio.sampleRate
        frameCount = audio.frameCount
        var levels: [Level] = []
        var mins: [Float] = [], maxs: [Float] = []
        let samples = audio.mono
        var i = 0
        while i < samples.count {
            let end = min(i + baseBin, samples.count)
            var lo: Float = 1, hi: Float = -1
            for s in samples[i..<end] { lo = min(lo, s); hi = max(hi, s) }
            mins.append(lo); maxs.append(hi)
            i = end
        }
        var level = Level(framesPerBin: baseBin, minimum: mins, maximum: maxs)
        levels.append(level)
        while level.minimum.count > 64 {
            var nmin: [Float] = [], nmax: [Float] = []
            var j = 0
            while j < level.minimum.count {
                let end = min(j + 4, level.minimum.count)
                nmin.append(level.minimum[j..<end].min()!)
                nmax.append(level.maximum[j..<end].max()!)
                j = end
            }
            level = Level(framesPerBin: level.framesPerBin * 4, minimum: nmin, maximum: nmax)
            levels.append(level)
        }
        self.levels = levels
    }

    /// Min/max pairs for `buckets` equal slices of the frame range, using the
    /// coarsest level that still has at least one bin per bucket.
    public func peaks(frames: Range<Int64>, buckets: Int) -> [(min: Float, max: Float)] {
        guard buckets > 0, !frames.isEmpty, let first = levels.first else { return [] }
        let framesPerBucket = Double(frames.count) / Double(buckets)
        let level = levels.last { Double($0.framesPerBin) <= framesPerBucket } ?? first
        var result: [(Float, Float)] = []
        result.reserveCapacity(buckets)
        for b in 0..<buckets {
            let start = Double(frames.lowerBound) + Double(b) * framesPerBucket
            let end = start + framesPerBucket
            let i0 = max(0, Int(start / Double(level.framesPerBin)))
            let i1 = min(level.minimum.count, max(i0 + 1, Int((end / Double(level.framesPerBin)).rounded(.up))))
            if start >= Double(frameCount) || i0 >= level.minimum.count || start < 0 {
                result.append((0, 0))
                continue
            }
            result.append((level.minimum[i0..<i1].min()!, level.maximum[i0..<i1].max()!))
        }
        return result
    }
}
