import XCTest
import DrillTiming
import DrillCore
import DrillMedia
import DrillExport
@testable import DrillDocument

final class MediaExportTests: XCTestCase {
    func testWAVDecodingOfCommonPCMFormats() throws {
        let samples: [Float] = (0..<1000).map { Float(sin(Double($0) / 20)) * 0.5 }
        let pcm16 = try WAVDecoder.decode(WAVDecoder.encode16(samples, sampleRate: 22_050))
        XCTAssertEqual(pcm16.sampleRate, 22_050)
        XCTAssertEqual(pcm16.frameCount, 1000)
        XCTAssertEqual(pcm16.mono[100], samples[100], accuracy: 1e-4)

        // Stereo 24-bit and 32-bit float, built by hand.
        func wav(tag: Int, bits: Int, channels: Int, frames: [[Double]]) -> Data {
            var d = Data()
            func u32(_ v: Int) { d.append(contentsOf: (0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) }) }
            func u16(_ v: Int) { d.append(contentsOf: (0..<2).map { UInt8((v >> (8 * $0)) & 0xFF) }) }
            let block = bits / 8 * channels
            d.append(contentsOf: Array("RIFF".utf8)); u32(36 + frames.count * block)
            d.append(contentsOf: Array("WAVE".utf8))
            d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(tag); u16(channels); u32(48_000); u32(48_000 * block); u16(block); u16(bits)
            d.append(contentsOf: Array("LIST".utf8)); u32(4); d.append(contentsOf: Array("INFO".utf8))  // unrelated chunk is skipped
            d.append(contentsOf: Array("data".utf8)); u32(frames.count * block)
            for frame in frames {
                for v in frame {
                    if tag == 3 { u32(Int(Float(v).bitPattern)) } else {
                        let i = Int((v * 8_388_607).rounded())
                        d.append(contentsOf: (0..<3).map { UInt8((i >> (8 * $0)) & 0xFF) })
                    }
                }
            }
            return d
        }
        let s24 = try WAVDecoder.decode(wav(tag: 1, bits: 24, channels: 2, frames: [[0.5, -0.5], [1.0, 0.0], [-0.25, -0.25]]))
        XCTAssertEqual(s24.channelCount, 2)
        XCTAssertEqual(s24.mono.map { Double($0) }, [0, 0.5, -0.25], accuracy: 1e-5)
        let f32 = try WAVDecoder.decode(wav(tag: 3, bits: 32, channels: 1, frames: [[0.75], [-0.125]]))
        XCTAssertEqual(f32.mono, [0.75, -0.125])
        XCTAssertThrowsError(try WAVDecoder.decode(wav(tag: 2, bits: 16, channels: 1, frames: [[0]]))) // ADPCM
        XCTAssertEqual(AudioSniffer.detect(Data([0x49, 0x44, 0x33, 4, 0])), .mp3)
        XCTAssertEqual(AudioSniffer.detect(Data([0xFF, 0xFB, 0x90, 0])), .mp3)
        XCTAssertNil(AudioSniffer.detect(Data("hello".utf8)))
    }

    func testPeakPyramidReturnsTrueExtremes() {
        var samples = [Float](repeating: 0, count: 100_000)
        samples[12_345] = 0.9
        samples[77_777] = -0.7
        let peaks = WaveformPeaks(audio: PCMAudio(sampleRate: 48_000, channelCount: 1, frameCount: 100_000, mono: samples))
        XCTAssertGreaterThan(peaks.levels.count, 2)
        let overview = peaks.peaks(frames: 0..<100_000, buckets: 10)
        XCTAssertEqual(overview.count, 10)
        XCTAssertEqual(overview[1].max, 0.9)
        XCTAssertEqual(overview[7].min, -0.7)
        XCTAssertEqual(overview[4].max, 0)
        // Zoomed-in view uses the finest level and still finds the spike.
        let zoom = peaks.peaks(frames: 12_000..<13_000, buckets: 100)
        XCTAssertEqual(zoom.map(\.max).max(), 0.9)
    }

    func testCoordinatePDFIsStructurallyValidAndReadable() throws {
        let show = try SampleShow.make()
        let data = try CoordinateSheet.render(show, movementID: show.movements[0].id)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("%PDF-1.4"))
        XCTAssertTrue(text.hasSuffix("%%EOF\n"))
        // Every xref offset must point at its "n 0 obj" header.
        let bytes = [UInt8](data)
        let startxref = text.range(of: "startxref\n", options: .backwards)!
        let xrefOffset = Int(text[startxref.upperBound...].split(separator: "\n")[0])!
        let xref = String(decoding: bytes[xrefOffset...], as: UTF8.self)
        let lines = xref.split(separator: "\n")
        let count = Int(lines[1].split(separator: " ")[1])!
        for i in 1..<count {
            let offset = Int(lines[2 + i].prefix(10))!
            let header = String(decoding: bytes[offset..<(offset + 12)], as: UTF8.self)
            XCTAssertTrue(header.hasPrefix("\(i) 0 obj"), "object \(i) offset")
        }
        // 18 performer sheets + 4 set charts.
        XCTAssertTrue(text.contains("/Count 22"))
        XCTAssertTrue(text.contains("(T1) Tj"))
        XCTAssertTrue(text.contains("On front hash"))
        XCTAssertTrue(text.contains("(Set 3) Tj"))
    }

    func testRowsDescribeMissingDataAndRefuseEmptyExport() throws {
        let session = try DocumentSession(show: try Show.makeNew(title: "Empty", measures: 4))
        XCTAssertThrowsError(try CoordinateSheet.render(session.show, movementID: session.show.movements[0].id)) {
            XCTAssertTrue("\($0)".contains("Add performers"))
        }
        try session.perform(try session.show.makeRoster([RosterSectionRequest(name: "Flute", prefix: "F", count: 1)]))
        let rows = try CoordinateSheet.rows(for: session.show.performers[0].id, in: session.show, movementID: session.show.movements[0].id)
        XCTAssertEqual(rows.first?.sideToSide, "No position")
        XCTAssertEqual(rows.first?.counts, "Preset")
    }
}

private func XCTAssertEqual(_ a: [Double], _ b: [Double], accuracy: Double, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(a.count, b.count, file: file, line: line)
    for (x, y) in zip(a, b) { XCTAssertEqual(x, y, accuracy: accuracy, file: file, line: line) }
}
