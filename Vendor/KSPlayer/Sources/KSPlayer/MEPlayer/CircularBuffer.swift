//
//  CircularBuffer.swift
//  KSPlayer
//
//  Created by kintan on 2018/3/9.
//

import Foundation

/// 这个是单生产者，多消费者的阻塞队列和单生产者，多消费者的阻塞环形队列。并且环形队列还要有排序的能力。
/// 因为seek需要清空队列，所以导致他是多消费者。后续可以看下能不能改成单消费者的。
public class CircularBuffer<Item: ObjectQueueItem> {
    private var _buffer = ContiguousArray<Item?>()
//    private let semaphore = DispatchSemaphore(value: 0)
    private let condition = NSCondition()
    private var headIndex = UInt(0)
    private var tailIndex = UInt(0)
    private let expanding: Bool
    private let sorted: Bool
    private var destroyed = false
    private var inputEnded = false
    private var epoch: UInt64 = 0
    /// A flush starts a new timeline. A waiting consumer must not consume its first item.
    public var generation: UInt64 {
        condition.lock()
        defer { condition.unlock() }
        return epoch
    }
    @inline(__always)
    private var _count: Int { Int(tailIndex &- headIndex) }
    @inline(__always)
    public var count: Int {
//        condition.lock()
//        defer { condition.unlock() }
        Int(tailIndex &- headIndex)
    }

    public internal(set) var fps: Float = 24
    public private(set) var maxCount: Int
    private var mask: UInt
    public init(initialCapacity: Int = 256, sorted: Bool = false, expanding: Bool = true) {
        self.expanding = expanding
        self.sorted = sorted
        let capacity = initialCapacity.nextPowerOf2()
        _buffer = ContiguousArray<Item?>(repeating: nil, count: Int(capacity))
        maxCount = Int(capacity)
        mask = UInt(maxCount - 1)
        assert(_buffer.count == capacity)
    }

    public func push(_ value: Item, if predicate: (() -> Bool)? = nil) {
        condition.lock()
        defer { condition.unlock() }
        if destroyed || predicate?() == false {
            return
        }
        if _buffer[Int(tailIndex & mask)] != nil {
            assertionFailure("value is not nil of headIndex: \(headIndex),tailIndex: \(tailIndex), bufferCount: \(_buffer.count), mask: \(mask)")
        }
        _buffer[Int(tailIndex & mask)] = value
        if sorted {
            // 不用sort进行排序，这个比较高效
            var index = tailIndex
            while index > headIndex {
                guard let item = _buffer[Int((index - 1) & mask)] else {
                    assertionFailure("value is nil of index: \((index - 1) & mask) headIndex: \(headIndex),tailIndex: \(tailIndex), bufferCount: \(_buffer.count),  mask: \(mask)")
                    break
                }
                if item.timestamp <= _buffer[Int(index & mask)]!.timestamp {
                    break
                }
                _buffer.swapAt(Int((index - 1) & mask), Int(index & mask))
                index -= 1
            }
        }
        tailIndex &+= 1
        if _count >= maxCount {
            if expanding {
                // No more room left for another append so grow the buffer now.
                _doubleCapacity()
            } else {
                condition.wait()
            }
        } else {
            // 只有数据了。就signal。因为有可能这是最后的数据了。
            if _count == 1 {
                condition.signal()
            }
        }
    }

    public func pop(wait: Bool = false, generation expectedGeneration: UInt64? = nil, where predicate: ((Item, Int) -> Bool)? = nil) -> Item? {
        condition.lock()
        defer { condition.unlock() }
        if destroyed || (expectedGeneration != nil && expectedGeneration != epoch) {
            return nil
        }
        if headIndex == tailIndex {
            if wait, !inputEnded {
                condition.wait()
                if destroyed || headIndex == tailIndex
                    || (expectedGeneration != nil && expectedGeneration != epoch) {
                    return nil
                }
            } else {
                return nil
            }
        }
        let index = Int(headIndex & mask)
        guard let item = _buffer[index] else {
            assertionFailure("value is nil of index: \(index) headIndex: \(headIndex),tailIndex: \(tailIndex), bufferCount: \(_buffer.count), mask: \(mask)")
            return nil
        }
        if let predicate, !predicate(item, _count) {
            return nil
        } else {
            headIndex &+= 1
            _buffer[index] = nil
            if _count == maxCount >> 1 {
                condition.signal()
            }
            return item
        }
    }

    /// EOF must wake an empty packet consumer as well as one still decoding.
    public func finish() {
        condition.lock()
        inputEnded = true
        condition.broadcast()
        condition.unlock()
    }

    public var isDrained: Bool {
        condition.lock()
        defer { condition.unlock() }
        return inputEnded && _count == 0
    }

    /// Serialize a decoder state transition with seek's packet invalidation.
    public func update(ifGeneration generation: UInt64, _ action: () -> Void) {
        condition.lock()
        defer { condition.unlock() }
        guard !destroyed, epoch == generation else { return }
        action()
    }

    /// Keep the decode worker asleep at EOF until a seek or shutdown wakes it.
    public func waitForNewGeneration(after generation: UInt64) {
        condition.lock()
        defer { condition.unlock() }
        while !destroyed, epoch == generation { condition.wait() }
    }

    /// Inspect the next presentation item without consuming it.
    public var first: Item? {
        condition.lock()
        defer { condition.unlock() }
        guard !destroyed, headIndex != tailIndex else { return nil }
        return _buffer[Int(headIndex & mask)]
    }

    /// Change the admission boundary and remove queued preroll under the same lock.
    /// Wake a producer blocked by a full queue when space becomes available.
    @discardableResult
    public func discardPrefix(while predicate: (Item) -> Bool, updating update: () -> Void) -> Int {
        condition.lock()
        defer { condition.unlock() }
        guard !destroyed else { return 0 }
        update()
        var removed = 0
        while headIndex != tailIndex,
              let item = _buffer[Int(headIndex & mask)], predicate(item) {
            _buffer[Int(headIndex & mask)] = nil
            headIndex &+= 1
            removed += 1
        }
        if removed > 0 { condition.broadcast() }
        return removed
    }

    public func search(where predicate: (Item) -> Bool) -> [Item] {
        condition.lock()
        defer { condition.unlock() }
        var i = headIndex
        var result = [Item]()
        while i < tailIndex {
            if let item = _buffer[Int(i & mask)] {
                if predicate(item) {
                    result.append(item)
                    _buffer[Int(i & mask)] = nil
                    headIndex = i + 1
                }
            } else {
                assertionFailure("value is nil of index: \(i) headIndex: \(headIndex), tailIndex: \(tailIndex), bufferCount: \(_buffer.count), mask: \(mask)")
                return result
            }
            i += 1
        }
        return result
    }

    public func flush(updating update: (() -> Void)? = nil) {
        condition.lock()
        defer { condition.unlock() }
        epoch &+= 1
        inputEnded = false
        update?()
        headIndex = 0
        tailIndex = 0
        _buffer.removeAll(keepingCapacity: !destroyed)
        _buffer.append(contentsOf: ContiguousArray<Item?>(repeating: nil, count: destroyed ? 1 : maxCount))
        condition.broadcast()
    }

    public func shutdown() {
        destroyed = true
        flush()
    }

    private func _doubleCapacity() {
        var newBacking: ContiguousArray<Item?> = []
        let newCapacity = maxCount << 1 // Double the storage.
        precondition(newCapacity > 0, "Can't double capacity of \(_buffer.count)")
        assert(newCapacity % 2 == 0)
        newBacking.reserveCapacity(newCapacity)
        let head = Int(headIndex & mask)
        newBacking.append(contentsOf: _buffer[head ..< maxCount])
        if head > 0 {
            newBacking.append(contentsOf: _buffer[0 ..< head])
        }
        let repeatitionCount = newCapacity &- newBacking.count
        newBacking.append(contentsOf: repeatElement(nil, count: repeatitionCount))
        headIndex = 0
        tailIndex = UInt(newBacking.count &- repeatitionCount)
        _buffer = newBacking
        maxCount = newCapacity
        mask = UInt(maxCount - 1)
    }
}

extension FixedWidthInteger {
    /// Returns the next power of two.
    @inline(__always)
    func nextPowerOf2() -> Self {
        guard self != 0 else {
            return 1
        }
        return 1 << (Self.bitWidth - (self - 1).leadingZeroBitCount)
    }
}
