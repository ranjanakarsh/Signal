// @ranjanakarsh
import Foundation
import Combine
import Atomics
import os.signpost

// MARK: - Signal Protocol

/// Protocol defining the core functionality of a signal
public protocol SignalProtocol<T> {
    associatedtype T
    
    /// Subscribe to signal emissions
    @discardableResult
    func subscribe(owner: AnyObject, queue: DispatchQueue?, handler: @escaping @Sendable (T) -> Void) async -> SignalToken
    
    /// Emit a value to all subscribers
    func emit(_ value: T)
}

/// Represents a lightweight, generic signal for broadcasting values to multiple observers.
public actor Signal<T>: SignalProtocol {
    // MARK: - Types
    
    /// Represents the state of a signal
    public enum State {
        case active
        case completed
        case failed(Error)
    }
    
    /// Event emitted by a signal
    public enum Event<Value> {
        case next(Value)
        case completed
        case failed(Error)
    }
    
    // MARK: - Properties
    
    private var subscribers: [SignalToken: SubscriberInfo] = [:]
    private var state: State = .active
    private var nextTokenId = ManagedAtomic<UInt64>(0)
    private var debugOptions = DebugOptions()
    
    // Throttling/debouncing properties
    private var throttleWorkItem: DispatchWorkItem?
    private var debounceWorkItem: DispatchWorkItem?
    
    // MARK: - Initialization
    
    public init(debugName: String? = nil) {
        self.debugOptions.name = debugName
        if debugOptions.loggingEnabled {
            let name = debugName ?? "Signal<\(T.self)>"
            print("[\(name)] Signal initialized")
        }
    }
    
    deinit {
        if debugOptions.loggingEnabled {
            let name = debugOptions.name ?? "Signal<\(T.self)>"
            print("[\(name)] Signal deinitializing with \(subscribers.count) subscribers")
        }
    }
    
    // MARK: - Subscription Management
    
    /// Subscribes an observer to receive updates.
    /// - Parameters:
    ///   - owner: The object owning the subscription (used for weak referencing)
    ///   - queue: The queue on which to execute the handler (defaults to main queue)
    ///   - handler: The closure to call on value emission
    /// - Returns: A token that can be used to unsubscribe
    @discardableResult
    public func subscribe(
        owner: AnyObject,
        queue: DispatchQueue? = .main,
        handler: @escaping @Sendable (T) -> Void
    ) async -> SignalToken {
        let token = createToken()
        let info = SubscriberInfo(owner: owner, queue: queue, handler: handler)
        
        subscribers[token] = info
        logDebug("New subscriber added (total: \(subscribers.count))")
        
        return token
    }
    
    /// Subscribes an observer to receive signal events (next, completed, failed).
    /// - Parameters:
    ///   - owner: The object owning the subscription
    ///   - queue: The queue on which to execute the handler
    ///   - handler: The closure to call on events
    /// - Returns: A token that can be used to unsubscribe
    @discardableResult
    public func subscribeEvent(
        owner: AnyObject,
        queue: DispatchQueue? = .main,
        handler: @escaping @Sendable (Event<T>) -> Void
    ) async -> SignalToken {
        let token = createToken()
        let info = SubscriberInfo(
            owner: owner,
            queue: queue,
            eventHandler: handler
        )
        
        subscribers[token] = info
        logDebug("New event subscriber added (total: \(subscribers.count))")
        
        return token
    }
    
    /// Unsubscribe using a token
    public func unsubscribe(token: SignalToken) {
        subscribers.removeValue(forKey: token)
        logDebug("Subscriber removed with token (total: \(subscribers.count))")
    }
    
    // MARK: - Emission
    
    /// Emits a new value to all current subscribers if the signal is still active.
    /// - Parameter value: The value to emit
    public nonisolated func emit(_ value: T) {
        Task { await _emit(value) }
    }
    
    /// Internal implementation of emit that runs on the actor
    private func _emit(_ value: T) {
        guard case .active = state else {
            logDebug("Attempted to emit on terminated signal - ignored")
            return
        }
        
        logDebug("Emitting value to \(subscribers.count) subscribers")
        cleanupDeallocatedSubscribers()
        
        // Capture current subscribers to avoid potential race conditions
        let currentSubscribers = subscribers
        
        for (_, info) in currentSubscribers {
            guard info.owner != nil else { continue }
            
            if let handler = info.handler {
                dispatchToQueue(info.queue) {
                    handler(value)
                }
            }
            
            if let eventHandler = info.eventHandler {
                dispatchToQueue(info.queue) {
                    eventHandler(Event.next(value))
                }
            }
        }
    }
    
    /// Emits a value with throttling (only emits once per specified interval)
    /// - Parameters:
    ///   - value: The value to emit
    ///   - interval: The minimum interval between emissions
    ///   - queue: The queue to use for throttling (defaults to global queue)
    public nonisolated func emitThrottled(
        _ value: T,
        interval: TimeInterval,
        queue: DispatchQueue = .global()
    ) {
        Task {
            await withCheckedContinuation { continuation in
                queue.async {
                    Task {
                        // Check if we can emit (throttle check)
                        let shouldEmit = await self.canEmitThrottled()
                        if shouldEmit {
                            // Emit immediately
                            await self._emit(value)
                            
                            // Set up the throttle timer
                            let workItem = DispatchWorkItem {
                                Task {
                                    await self.clearThrottleWorkItem()
                                }
                            }
                            
                            await self.setThrottleWorkItem(workItem)
                            queue.asyncAfter(deadline: .now() + interval, execute: workItem)
                        }
                        continuation.resume()
                    }
                }
            }
        }
    }
    
    /// Emits a value with debouncing (only emits after a period of inactivity)
    /// - Parameters:
    ///   - value: The value to emit
    ///   - delay: The delay before emission
    ///   - queue: The queue to use for debouncing (defaults to global queue)
    public nonisolated func emitDebounced(
        _ value: T,
        delay: TimeInterval,
        queue: DispatchQueue = .global()
    ) {
        Task {
            await withCheckedContinuation { continuation in
                queue.async {
                    Task {
                        // Cancel any existing work item
                        if let workItem = await self.getAndClearDebounceWorkItem() {
                            workItem.cancel()
                        }
                        
                        // Create a new work item
                        let workItem = DispatchWorkItem {
                            Task {
                                await self._emit(value)
                            }
                        }
                        
                        // Store the new work item
                        await self.setDebounceWorkItem(workItem)
                        queue.asyncAfter(deadline: .now() + delay, execute: workItem)
                        continuation.resume()
                    }
                }
            }
        }
    }
    
    // MARK: - Termination
    
    /// Completes the signal, preventing further emissions
    public func complete() {
        guard case .active = state else { return }
        
        state = .completed
        logDebug("Signal completed")
        
        notifyCompletion()
    }
    
    /// Fails the signal with an error, preventing further emissions
    /// - Parameter error: The error that caused the failure
    public func fail(error: Error) {
        guard case .active = state else { return }
        
        state = .failed(error)
        logDebug("Signal failed with error: \(error)")
        
        notifyFailure(error)
    }
    
    // MARK: - Private Methods
    
    private func notifyCompletion() {
        cleanupDeallocatedSubscribers()
        
        for (_, info) in subscribers {
            guard info.owner != nil else { continue }
            
            if let eventHandler = info.eventHandler {
                dispatchToQueue(info.queue) {
                    eventHandler(Event<T>.completed)
                }
            }
        }
    }
    
    private func notifyFailure(_ error: Error) {
        cleanupDeallocatedSubscribers()
        
        for (_, info) in subscribers {
            guard info.owner != nil else { continue }
            
            if let eventHandler = info.eventHandler {
                dispatchToQueue(info.queue) {
                    eventHandler(Event<T>.failed(error))
                }
            }
        }
    }
    
    private func cleanupDeallocatedSubscribers() {
        subscribers = subscribers.filter { _, info in
            info.owner != nil
        }
    }
    
    private func createToken() -> SignalToken {
        let id = nextTokenId.loadThenWrappingIncrement(ordering: .relaxed)
        return SignalToken(id: id)
    }
    
    private func dispatchToQueue(_ queue: DispatchQueue?, _ work: @Sendable @escaping () -> Void) {
        if let queue = queue {
            queue.async(execute: work)
        } else {
            work()
        }
    }
    
    // MARK: - Debug
    
    /// Set debug options for this signal
    /// - Parameter options: Debug configuration options
    public func setDebugOptions(_ options: DebugOptions) {
        self.debugOptions = options
    }
    
    /// Enable or disable debug logging
    /// - Parameter enabled: Whether debug logging should be enabled
    public func setDebugLogging(enabled: Bool) {
        debugOptions.loggingEnabled = enabled
    }
    
    /// Get the current number of active subscribers
    public var activeSubscriberCount: Int {
        get async {
            cleanupDeallocatedSubscribers()
            return subscribers.count
        }
    }
    
    private func logDebug(_ message: String) {
        let isEnabled = debugOptions.loggingEnabled
        let name = debugOptions.name ?? "Signal<\(T.self)>"
        let signpostID = debugOptions.signpostID
        
        if isEnabled {
            nonisolatedLogDebug(message: message, name: name, signpostID: signpostID)
        }
    }
    
    // Nonisolated version that doesn't access actor state
    private nonisolated func nonisolatedLogDebug(message: String, name: String, signpostID: OSSignpostID?) {
        if let signpostID = signpostID {
            let log = OSLog(subsystem: "com.signal", category: name)
            os_signpost(.event, log: log, name: "signal_event", signpostID: signpostID, "%{public}@: %{public}@", name, message)
        } else {
            print("[\(name)] \(message)")
        }
    }
    
    // MARK: - Combine Integration
    
    /// Get a Combine publisher for this signal
    public var publisher: AnyPublisher<T, Never> {
        get async {
            let subject = PassthroughSubject<T, Never>()
            
            // Subscribe to our signal and forward events to the subject
            let token = await subscribe(owner: SignalCombineAdapter()) { value in
                subject.send(value)
            }
            
            // Create a publisher that cleans up the subscription when it's cancelled
            return subject
                .handleEvents(receiveCancel: {
                    Task {
                        self.unsubscribe(token: token)
                    }
                })
                .eraseToAnyPublisher()
        }
    }
    
    // Helper class to keep the subscription alive
    private class SignalCombineAdapter {}
    
    // Helper methods for actor-isolated properties
    private func canEmitThrottled() -> Bool {
        return throttleWorkItem == nil
    }
    
    private func setThrottleWorkItem(_ workItem: DispatchWorkItem) {
        throttleWorkItem = workItem
    }
    
    private func clearThrottleWorkItem() {
        throttleWorkItem = nil
    }
    
    private func getAndClearDebounceWorkItem() -> DispatchWorkItem? {
        let workItem = debounceWorkItem
        debounceWorkItem = nil
        return workItem
    }
    
    private func setDebounceWorkItem(_ workItem: DispatchWorkItem) {
        debounceWorkItem = workItem
    }
}

// MARK: - Signal Token

/// A token representing a subscription to a signal
public struct SignalToken: Hashable, Equatable {
    let id: UInt64
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    public static func == (lhs: SignalToken, rhs: SignalToken) -> Bool {
        lhs.id == rhs.id
    }
}

// Move SubscriberInfo inside Signal as a nested type
extension Signal {
    /// Information about a subscriber
    fileprivate struct SubscriberInfo {
        weak var owner: AnyObject?
        let queue: DispatchQueue?
        let handler: ((T) -> Void)?
        let eventHandler: ((Signal<T>.Event<T>) -> Void)?
        
        init(
            owner: AnyObject,
            queue: DispatchQueue?,
            handler: ((T) -> Void)? = nil,
            eventHandler: ((Signal<T>.Event<T>) -> Void)? = nil
        ) {
            self.owner = owner
            self.queue = queue
            self.handler = handler
            self.eventHandler = eventHandler
        }
    }
}

// MARK: - Debug Options

extension Signal {
    /// Debug configuration options for a signal
    public struct DebugOptions {
        /// Name for debugging purposes
        public var name: String?
        
        /// Whether debug logging is enabled
        public var loggingEnabled: Bool = false
        
        /// Optional signpost ID for performance tracing
        public var signpostID: OSSignpostID?
        
        public init(name: String? = nil, loggingEnabled: Bool = false, signpostID: OSSignpostID? = nil) {
            self.name = name
            self.loggingEnabled = loggingEnabled
            self.signpostID = signpostID
        }
    }
}

// MARK: - Value Signal

/// A signal that caches the last value and immediately sends it to new subscribers
public actor ValueSignal<T>: SignalProtocol {
    private let signal = Signal<T>()
    private var cachedValues: [T] = []
    private let replayCount: Int
    
    /// Initialize a value signal with optional replay count
    /// - Parameter replayCount: Number of values to cache and replay (default: 1)
    public init(replayCount: Int = 1, debugName: String? = nil) {
        self.replayCount = max(1, replayCount)
        
        if let debugName = debugName {
            // Use Task to call the actor-isolated method asynchronously
            Task {
                await signal.setDebugOptions(Signal.DebugOptions(name: debugName))
            }
        }
    }
    
    /// Subscribes an observer to receive updates, immediately sending cached values.
    /// - Parameters:
    ///   - owner: The object owning the subscription
    ///   - queue: The queue on which to execute the handler
    ///   - handler: The closure to call on value emission
    /// - Returns: A token that can be used to unsubscribe
    @discardableResult
    public func subscribe(
        owner: AnyObject,
        queue: DispatchQueue? = .main,
        handler: @escaping @Sendable (T) -> Void
    ) async -> SignalToken {
        // Send cached values immediately
        for value in cachedValues {
            if let queue = queue {
                queue.async {
                    handler(value)
                }
            } else {
                handler(value)
            }
        }
        
        // Subscribe to future values
        return await signal.subscribe(owner: owner, queue: queue, handler: handler)
    }
    
    /// Emits a new value, caching it for future subscribers
    /// - Parameter value: The value to emit and cache
    public nonisolated func emit(_ value: T) {
        Task {
            await _emit(value)
        }
    }
    
    private func _emit(_ value: T) async {
        // Update cache
        cachedValues.append(value)
        if cachedValues.count > replayCount {
            cachedValues.removeFirst(cachedValues.count - replayCount)
        }
        
        // Forward to underlying signal
        signal.emit(value)
    }
    
    /// Completes the signal, preventing further emissions
    public func complete() {
        Task {
            await signal.complete()
        }
    }
    
    /// Fails the signal with an error, preventing further emissions
    /// - Parameter error: The error that caused the failure
    public func fail(error: Error) {
        Task {
            await signal.fail(error: error)
        }
    }
    
    /// Unsubscribe using a token
    public func unsubscribe(token: SignalToken) {
        Task {
            await signal.unsubscribe(token: token)
        }
    }
    
    /// Get the current number of active subscribers
    public var activeSubscriberCount: Int {
        get async {
            await signal.activeSubscriberCount
        }
    }
    
    /// Set debug options for this signal
    public func setDebugOptions(_ options: Signal<T>.DebugOptions) {
        Task {
            await signal.setDebugOptions(options)
        }
    }
    
    /// Get a Combine publisher for this signal
    public var publisher: AnyPublisher<T, Never> {
        get async {
            await signal.publisher
        }
    }
}

// MARK: - Type Erasure

/// A type-erased signal wrapper
public struct AnySignal<T>: SignalProtocol {
    private let _subscribe: (AnyObject, DispatchQueue?, @escaping @Sendable (T) -> Void) async -> SignalToken
    private let _emit: (T) -> Void
    
    /// Initialize with a concrete signal implementation
    public init<S: SignalProtocol>(_ signal: S) async where S.T == T {
        self._subscribe = { owner, queue, handler in
            await signal.subscribe(owner: owner, queue: queue, handler: handler)
        }
        self._emit = { value in
            signal.emit(value)
        }
    }
    
    /// Subscribe to the underlying signal
    @discardableResult
    public func subscribe(
        owner: AnyObject,
        queue: DispatchQueue? = .main,
        handler: @escaping @Sendable (T) -> Void
    ) async -> SignalToken {
        await _subscribe(owner, queue, handler)
    }
    
    /// Emit a value to the underlying signal
    public func emit(_ value: T) {
        _emit(value)
    }
}

// MARK: - Result Signal

/// Represents a result signal that can emit either a success or failure
public enum SignalResult<T, E: Error> {
    case success(T)
    case failure(E)
}
