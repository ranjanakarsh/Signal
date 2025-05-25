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
    func subscribe(owner: AnyObject, queue: DispatchQueue?, handler: @escaping @Sendable (T) -> Void) -> SignalToken
    
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
        logDebug("Signal initialized")
    }
    
    deinit {
        logDebug("Signal deinitializing with \(subscribers.count) subscribers")
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
    ) -> SignalToken {
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
    ) -> SignalToken {
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
                    eventHandler(.next(value))
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
                    Task { @MainActor in
                        if self.throttleWorkItem == nil {
                            // Emit immediately and set up the throttle timer
                            Task { await self._emit(value) }
                            
                            let workItem = DispatchWorkItem {
                                Task { @MainActor in
                                    self.throttleWorkItem = nil
                                }
                            }
                            
                            self.throttleWorkItem = workItem
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
                    Task { @MainActor in
                        // Cancel any existing work item
                        self.debounceWorkItem?.cancel()
                        
                        // Create a new work item
                        let workItem = DispatchWorkItem {
                            Task {
                                await self._emit(value)
                            }
                        }
                        
                        self.debounceWorkItem = workItem
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
                    eventHandler(.completed)
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
                    eventHandler(.failed(error))
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
    
    private func dispatchToQueue(_ queue: DispatchQueue?, _ work: @escaping () -> Void) {
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
        guard debugOptions.loggingEnabled else { return }
        
        let name = debugOptions.name ?? "Signal<\(T.self)>"
        if let signpostID = debugOptions.signpostID {
            let log = OSLog(subsystem: "com.signal", category: name)
            os_signpost(.event, log: log, name: name, signpostID: signpostID, "%{public}@", message)
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
            let token = subscribe(owner: SignalCombineAdapter()) { value in
                subject.send(value)
            }
            
            // Create a publisher that cleans up the subscription when it's cancelled
            return subject
                .handleEvents(receiveCancel: {
                    Task {
                        await self.unsubscribe(token: token)
                    }
                })
                .eraseToAnyPublisher()
        }
    }
    
    // Helper class to keep the subscription alive
    private class SignalCombineAdapter {}
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

// MARK: - Subscriber Info

/// Information about a subscriber
private struct SubscriberInfo {
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
            signal.setDebugOptions(Signal.DebugOptions(name: debugName))
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
    ) -> SignalToken {
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
    
    private func _emit(_ value: T) {
        // Update cache
        cachedValues.append(value)
        if cachedValues.count > replayCount {
            cachedValues.removeFirst(cachedValues.count - replayCount)
        }
        
        // Forward to underlying signal
        await signal.emit(value)
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
    private let _subscribe: (AnyObject, DispatchQueue?, @escaping @Sendable (T) -> Void) -> SignalToken
    private let _emit: (T) -> Void
    
    /// Initialize with a concrete signal implementation
    public init<S: SignalProtocol>(_ signal: S) where S.T == T {
        self._subscribe = { owner, queue, handler in
            signal.subscribe(owner: owner, queue: queue, handler: handler)
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
    ) -> SignalToken {
        _subscribe(owner, queue, handler)
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

// MARK: - Usage Example
/*
// Example usage:

class ViewModel {
    let isLoadingSignal = Signal<Bool>()
    let authResultSignal = Signal<SignalResult<AuthState, AuthError>>()
    let valueSignal = ValueSignal<String>(replayCount: 3, debugName: "UserNameSignal")
    
    // Type-erased signal for use in protocols
    var onboardingCompletedSignal: AnySignal<Bool> {
        get async {
            return AnySignal(Signal<Bool>())
        }
    }
    
    func setupCombinePublisher() async {
        let publisher = await valueSignal.publisher
        // Use with Combine ecosystem
        let cancellable = publisher.sink { value in
            print("Received value from publisher: \(value)")
        }
    }
    
    func trackUserActivity() {
        // Debounced emission for analytics
        valueSignal.emitDebounced("User typing...", delay: 0.5)
        
        // Throttled emission for UI updates
        isLoadingSignal.emitThrottled(true, interval: 0.2)
    }
}

class ViewController: UIViewController {
    let viewModel = ViewModel()
    private var tokens: [SignalToken] = []
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // Subscribe to a boolean signal on the main queue (default)
        let loadingToken = viewModel.isLoadingSignal.subscribe(owner: self) { [weak self] isLoading in
            self?.showLoading(isLoading)
        }
        tokens.append(loadingToken)
        
        // Subscribe to a result signal on a background queue
        let authToken = viewModel.authResultSignal.subscribe(
            owner: self,
            queue: .global(qos: .background)
        ) { result in
            switch result {
            case .success(let state):
                print("Auth success: \(state)")
            case .failure(let error):
                print("Auth failed: \(error)")
            }
        }
        tokens.append(authToken)
        
        // Subscribe to a value signal with event-based API
        let valueToken = await viewModel.valueSignal.subscribeEvent(owner: self) { event in
            switch event {
            case .next(let value):
                print("Latest value: \(value)")
            case .completed:
                print("Value signal completed")
            case .failed(let error):
                print("Value signal failed: \(error)")
            }
        }
        tokens.append(valueToken)
        
        // Enable debug logging
        await viewModel.valueSignal.setDebugOptions(
            Signal.DebugOptions(name: "ValueSignal", loggingEnabled: true)
        )
    }
    
    func showLoading(_ loading: Bool) {
        // Show/hide loading UI
    }
    
    deinit {
        // Not necessary as signals automatically clean up, but can be done explicitly
        tokens.forEach { token in
            viewModel.isLoadingSignal.unsubscribe(token: token)
        }
    }
}
*/ 