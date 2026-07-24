import Foundation

/// Pure pacing policy: audio ring depth is the clock. The display link asks
/// how many core frames to emit each tick; the answer keeps the ring near
/// target so the audio render thread never starves (crackle) or laps (latency).
public struct AudioPacer: Sendable {
    public let targetDepthFrames: Int
    public let lowWater: Int
    public let highWater: Int

    public init(targetDepthFrames: Int, lowWater: Int, highWater: Int) {
        precondition(lowWater < targetDepthFrames && targetDepthFrames < highWater)
        self.targetDepthFrames = targetDepthFrames
        self.lowWater = lowWater
        self.highWater = highWater
    }

    public static func standard(sampleRate: Double, fps: Double) -> AudioPacer {
        let perVideoFrame = Int(sampleRate / fps)
        return AudioPacer(targetDepthFrames: perVideoFrame * 3,
                          lowWater: perVideoFrame * 2,
                          highWater: perVideoFrame * 4)
    }

    public func framesToRun(ringDepth: Int) -> Int {
        if ringDepth < lowWater { return 2 }
        if ringDepth > highWater { return 0 }
        return 1
    }
}
