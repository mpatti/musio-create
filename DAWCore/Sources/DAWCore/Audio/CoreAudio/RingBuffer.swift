import Foundation

// MARK: - Ring Buffer

/// Lock-free single-producer single-consumer ring buffer
/// Used for realtime-safe communication between main thread and audio thread
///
/// Design:
/// - Main thread (producer) writes events via `push()`
/// - Audio thread (consumer) reads events via `peek()` and `pop()`
/// - No locks, no allocations on audio thread
/// - Power-of-2 capacity for efficient masking
public final class RingBuffer<T> {
    
    // MARK: - Properties
    
    /// The backing storage
    private let buffer: UnsafeMutablePointer<T?>
    
    /// Capacity (always power of 2)
    private let capacity: Int
    
    /// Bitmask for efficient modulo (capacity - 1)
    private let mask: Int
    
    /// Write position (only written by producer/main thread)
    /// Using UnsafeMutablePointer for atomic-like behavior
    private var head: Int = 0
    
    /// Read position (only written by consumer/audio thread)
    private var tail: Int = 0
    
    // MARK: - Initialization
    
    /// Create a ring buffer with the specified minimum capacity
    /// Actual capacity will be rounded up to the next power of 2
    public init(capacity: Int) {
        let actualCapacity = Self.nextPowerOf2(max(capacity, 2))
        self.capacity = actualCapacity
        self.mask = actualCapacity - 1
        
        // Allocate and initialize buffer
        self.buffer = UnsafeMutablePointer<T?>.allocate(capacity: actualCapacity)
        self.buffer.initialize(repeating: nil, count: actualCapacity)
    }
    
    deinit {
        // Clean up
        buffer.deinitialize(count: capacity)
        buffer.deallocate()
    }
    
    // MARK: - Producer Methods (Main Thread)
    
    /// Push an element to the buffer
    /// - Parameter element: The element to push
    /// - Returns: true if successful, false if buffer is full
    /// - Note: Only call from producer (main) thread
    @discardableResult
    public func push(_ element: T) -> Bool {
        let currentHead = head
        let nextHead = (currentHead + 1) & mask
        
        // Check if buffer is full
        // We leave one slot empty to distinguish full from empty
        if nextHead == tail {
            return false
        }
        
        // Write element
        buffer[currentHead] = element
        
        // Memory barrier to ensure write is visible before head update
        OSMemoryBarrier()
        
        // Update head
        head = nextHead
        
        return true
    }
    
    /// Push multiple elements to the buffer
    /// - Parameter elements: The elements to push
    /// - Returns: Number of elements successfully pushed
    /// - Note: Only call from producer (main) thread
    @discardableResult
    public func push(contentsOf elements: [T]) -> Int {
        var pushed = 0
        for element in elements {
            if push(element) {
                pushed += 1
            } else {
                break
            }
        }
        return pushed
    }
    
    // MARK: - Consumer Methods (Audio Thread)
    
    /// Peek at the next element without removing it
    /// - Returns: The next element, or nil if buffer is empty
    /// - Note: Only call from consumer (audio) thread
    public func peek() -> T? {
        // Memory barrier to ensure we see latest writes
        OSMemoryBarrier()
        
        if head == tail {
            return nil
        }
        
        return buffer[tail]
    }
    
    /// Pop the next element from the buffer
    /// - Note: Only call from consumer (audio) thread
    public func pop() {
        guard head != tail else { return }
        
        // Clear the slot (helps with debugging, not strictly necessary)
        buffer[tail] = nil
        
        // Update tail
        tail = (tail + 1) & mask
    }
    
    /// Pop and return the next element
    /// - Returns: The next element, or nil if buffer is empty
    /// - Note: Only call from consumer (audio) thread
    public func popAndReturn() -> T? {
        guard let element = peek() else { return nil }
        pop()
        return element
    }
    
    // MARK: - Query Methods (Thread-Safe)
    
    /// Check if buffer is empty
    /// - Note: Safe to call from any thread, but result may be stale
    public var isEmpty: Bool {
        OSMemoryBarrier()
        return head == tail
    }
    
    /// Get approximate count of elements in buffer
    /// - Note: Safe to call from any thread, but result may be stale
    public var count: Int {
        OSMemoryBarrier()
        let h = head
        let t = tail
        if h >= t {
            return h - t
        } else {
            return capacity - t + h
        }
    }
    
    /// Get available space in buffer
    public var availableSpace: Int {
        capacity - 1 - count
    }
    
    // MARK: - Reset (Main Thread Only)
    
    /// Clear all elements from the buffer
    /// - Warning: Only call when audio thread is not accessing the buffer
    public func clear() {
        // Set tail to head (effectively empties the buffer)
        tail = head
    }
    
    /// Reset the buffer completely
    /// - Warning: Only call when audio thread is not accessing the buffer
    public func reset() {
        head = 0
        tail = 0
        for i in 0..<capacity {
            buffer[i] = nil
        }
    }
    
    // MARK: - Helpers
    
    private static func nextPowerOf2(_ n: Int) -> Int {
        var v = n
        v -= 1
        v |= v >> 1
        v |= v >> 2
        v |= v >> 4
        v |= v >> 8
        v |= v >> 16
        v += 1
        return v
    }
}

// MARK: - Specialized Ring Buffer for MIDI Events

/// A ring buffer specifically optimized for MIDI events
/// Pre-sorted by sample position for efficient processing
public final class MIDIEventRingBuffer {
    
    private let buffer: RingBuffer<ScheduledMIDIEvent>
    
    public init(capacity: Int = 16384) {
        self.buffer = RingBuffer(capacity: capacity)
    }
    
    /// Schedule a MIDI event
    @discardableResult
    public func schedule(_ event: ScheduledMIDIEvent) -> Bool {
        buffer.push(event)
    }
    
    /// Schedule multiple events (should be pre-sorted by sample position)
    @discardableResult
    public func schedule(contentsOf events: [ScheduledMIDIEvent]) -> Int {
        buffer.push(contentsOf: events)
    }
    
    /// Get the next event if it falls within the sample range
    /// - Parameters:
    ///   - startSample: Start of the buffer range
    ///   - endSample: End of the buffer range
    /// - Returns: The event if it's in range, nil otherwise
    public func peekIfInRange(startSample: Int64, endSample: Int64) -> ScheduledMIDIEvent? {
        guard let event = buffer.peek() else { return nil }
        
        // If event is in the past, skip it
        if event.samplePosition < startSample {
            buffer.pop()
            return peekIfInRange(startSample: startSample, endSample: endSample)
        }
        
        // If event is in the future, don't return it yet
        if event.samplePosition >= endSample {
            return nil
        }
        
        return event
    }
    
    /// Pop the current event
    public func pop() {
        buffer.pop()
    }
    
    /// Clear all events
    public func clear() {
        buffer.clear()
    }
    
    public var isEmpty: Bool {
        buffer.isEmpty
    }
    
    public var count: Int {
        buffer.count
    }
}

// MARK: - Audio Buffer Pool

/// A pool of pre-allocated audio buffers for realtime use
/// Avoids allocation on the audio thread
public final class AudioBufferPool {
    
    private var availableBuffers: [UnsafeMutablePointer<Float>] = []
    private let bufferSize: Int
    private let lock = NSLock()
    
    public init(bufferCount: Int, bufferSize: Int) {
        self.bufferSize = bufferSize
        
        // Pre-allocate buffers
        for _ in 0..<bufferCount {
            let buffer = UnsafeMutablePointer<Float>.allocate(capacity: bufferSize)
            buffer.initialize(repeating: 0, count: bufferSize)
            availableBuffers.append(buffer)
        }
    }
    
    deinit {
        for buffer in availableBuffers {
            buffer.deinitialize(count: bufferSize)
            buffer.deallocate()
        }
    }
    
    /// Acquire a buffer from the pool
    /// - Warning: For offline use only, not realtime safe due to lock
    public func acquire() -> UnsafeMutablePointer<Float>? {
        lock.lock()
        defer { lock.unlock() }
        return availableBuffers.popLast()
    }
    
    /// Return a buffer to the pool
    /// - Warning: For offline use only, not realtime safe due to lock
    public func release(_ buffer: UnsafeMutablePointer<Float>) {
        lock.lock()
        defer { lock.unlock() }
        
        // Zero the buffer before returning
        buffer.initialize(repeating: 0, count: bufferSize)
        availableBuffers.append(buffer)
    }
}
