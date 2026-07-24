import XCTest
@testable import RommpleTVKit

final class AudioPacerTests: XCTestCase {
    // snes9x: 32040 Hz, 60.0988 fps → ~533 audio frames per video frame
    let pacer = AudioPacer.standard(sampleRate: 32040, fps: 60.0988)

    func testSteadyStateRunsOneFrame() {
        XCTAssertEqual(pacer.framesToRun(ringDepth: 533 * 3), 1)
    }
    func testLowBufferRunsTwo() {
        XCTAssertEqual(pacer.framesToRun(ringDepth: 100), 2)
    }
    func testHighBufferSkips() {
        XCTAssertEqual(pacer.framesToRun(ringDepth: 533 * 8), 0)
    }
    func testConvergesFromEmptyWithoutOscillating() {
        var depth = 0
        let perFrame = 533, perTickDrain = 534   // consumer slightly faster (drift)
        var history: [Int] = []
        // Period: run 2 adds +532 frames; 533 ticks × 1-frame drain recovers it → ~533-tick cycle.
        for _ in 0..<2000 {   // 2000 ticks; observe last 1200 to span ≥2 full periods phase-independently.
            let run = pacer.framesToRun(ringDepth: depth)
            depth += run * perFrame
            depth = max(0, depth - perTickDrain)
            history.append(run)
        }
        // After convergence the pacer must never starve (0 depth) again…
        XCTAssertFalse(history.suffix(1200).contains(0), "oscillation: skipped ticks in steady state")
        // …and must compensate for drift multiple times (once per ~533-tick period).
        XCTAssertGreaterThanOrEqual(history.suffix(1200).filter { $0 == 2 }.count, 2, "fewer than 2 corrections in window spanning ≥2 periods")
    }
    func testStandardConfigSane() {
        let p = AudioPacer.standard(sampleRate: 48000, fps: 60)
        XCTAssertEqual(p.framesToRun(ringDepth: 2400), 1)   // 3 frames of 800 = target
    }
}
