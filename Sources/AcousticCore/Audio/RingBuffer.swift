import Foundation
import Synchronization

/// Lock-free single-producer, single-consumer stereo ring buffer.
/// Producer (Core Audio RT IOProc thread) performs zero allocations and zero locks.
public final class StereoRingBuffer: @unchecked Sendable {
    public let capacity: Int
    private let mask: Int
    private let left: UnsafeMutablePointer<Float>
    private let right: UnsafeMutablePointer<Float>
    private let writeIndex = Atomic<Int>(0)

    /// Capacity must be a power of two (defaults to 16384 frames ≈ 340ms @ 48kHz).
    public init(capacity: Int = 16384) {
        precondition(capacity > 0 && (capacity & (capacity - 1)) == 0, "Capacity must be power of two")
        self.capacity = capacity
        self.mask = capacity - 1
        self.left = .allocate(capacity: capacity)
        self.right = .allocate(capacity: capacity)
        self.left.initialize(repeating: 0, count: capacity)
        self.right.initialize(repeating: 0, count: capacity)
    }

    deinit {
        left.deallocate()
        right.deallocate()
    }

    public var totalFramesWritten: Int {
        writeIndex.load(ordering: .acquiring)
    }

    /// Real-time audio thread write for interleaved stereo Float32 buffer.
    @inline(__always)
    public func writeInterleaved(_ samples: UnsafePointer<Float>, frameCount: Int, channels: Int) {
        guard frameCount > 0, channels > 0 else { return }
        var idx = writeIndex.load(ordering: .relaxed)
        if channels >= 2 {
            for i in 0..<frameCount {
                let slot = idx & mask
                left[slot] = samples[i * channels]
                right[slot] = samples[i * channels + 1]
                idx &+= 1
            }
        } else {
            for i in 0..<frameCount {
                let slot = idx & mask
                let s = samples[i]
                left[slot] = s
                right[slot] = s
                idx &+= 1
            }
        }
        writeIndex.store(idx, ordering: .releasing)
    }

    /// Real-time audio thread write for non-interleaved planar Float32 buffers.
    @inline(__always)
    public func writePlanar(leftSrc: UnsafePointer<Float>, rightSrc: UnsafePointer<Float>?, frameCount: Int) {
        guard frameCount > 0 else { return }
        var idx = writeIndex.load(ordering: .relaxed)
        let rSrc = rightSrc ?? leftSrc
        for i in 0..<frameCount {
            let slot = idx & mask
            left[slot] = leftSrc[i]
            right[slot] = rSrc[i]
            idx &+= 1
        }
        writeIndex.store(idx, ordering: .releasing)
    }

    /// Snapshot the most recent `count` stereo frames into destination buffers (DSP/render thread).
    /// Returns the total monotonic frame counter so caller knows if new audio arrived.
    @discardableResult
    public func readLatest(count: Int, intoLeft dstL: UnsafeMutablePointer<Float>, intoRight dstR: UnsafeMutablePointer<Float>) -> Int {
        let end = writeIndex.load(ordering: .acquiring)
        let n = min(count, capacity)
        let start = end &- n
        for i in 0..<n {
            let slot = (start &+ i) & mask
            dstL[i] = left[slot]
            dstR[i] = right[slot]
        }
        return end
    }

    /// Computes the stereo RMS energy of the latest `frameCount` frames without allocating.
    public func recentRMS(frameCount: Int = 2048) -> Float {
        let end = writeIndex.load(ordering: .acquiring)
        let n = min(frameCount, capacity)
        guard n > 0 else { return 0 }
        let start = end &- n
        var sumSq: Float = 0
        for i in 0..<n {
            let slot = (start &+ i) & mask
            let l = left[slot]
            let r = right[slot]
            sumSq += l * l + r * r
        }
        return sqrt(sumSq / Float(n * 2))
    }

    public func clear() {
        left.update(repeating: 0, count: capacity)
        right.update(repeating: 0, count: capacity)
    }
}
