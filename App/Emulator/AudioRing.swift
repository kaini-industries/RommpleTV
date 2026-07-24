import Foundation
import os

// Single-producer (display-link thread) / single-consumer (audio render
// thread) ring of interleaved Int16 stereo frames.
final class AudioRing: @unchecked Sendable {
    private var buffer: [Int16]
    private var readIndex = 0, writeIndex = 0, count = 0
    private var lock = os_unfair_lock()
    private let capacityFrames: Int

    init(capacityFrames: Int = 32768) {
        precondition(capacityFrames > 0)
        self.capacityFrames = capacityFrames
        buffer = [Int16](repeating: 0, count: capacityFrames * 2)
    }

    func write(_ samples: UnsafePointer<Int16>, frameCount: Int) {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        for f in 0..<frameCount {
            if count == capacityFrames { break }              // overrun: drop newest
            let w = writeIndex * 2
            buffer[w] = samples[f * 2]; buffer[w + 1] = samples[f * 2 + 1]
            writeIndex = (writeIndex + 1) % capacityFrames; count += 1
        }
    }

    /// Thread-safe snapshot of buffered frame count — the pacer's clock.
    var depthFrames: Int {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return count
    }

    /// Fills `out` with `frameCount` interleaved frames; zero-fills on underrun.
    func read(into out: UnsafeMutablePointer<Int16>, frameCount: Int) {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        for f in 0..<frameCount {
            let o = f * 2
            if count > 0 {
                let r = readIndex * 2
                out[o] = buffer[r]; out[o + 1] = buffer[r + 1]
                readIndex = (readIndex + 1) % capacityFrames; count -= 1
            } else { out[o] = 0; out[o + 1] = 0 }
        }
    }
}
