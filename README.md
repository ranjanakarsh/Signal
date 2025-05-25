# Signal.swift

> A lightweight, thread-safe, reactive state management library for Swift — built with Swift Concurrency, Combine compatibility, and high-end scalability in mind.

---

![Swift](https://img.shields.io/badge/Swift-5.9-orange)
![iOS](https://img.shields.io/badge/iOS-13+-blue)
![License](https://img.shields.io/badge/License-MIT-lightgrey)
![Platform](https://img.shields.io/badge/Platform-iOS%20%7C%20macOS%20%7C%20tvOS-lightblue)

---

## Motivation

`Signal.swift` was born out of the need for a **minimal yet powerful** reactive layer suitable for large-scale iOS applications — like social networks or dating apps — without the overhead of RxSwift or Combine-only constraints.

Designed by [@ranjanakarsh](https://github.com/ranjanakarsh), it blends:

- **Actor-based safety** with Swift Concurrency  
- **Multicast emissions** with weak references  
- **Type erasure**, **Combine bridging**, and **value replay**  
- **Debouncing, throttling**, and event-state models  
- **Debug tracing and performance logging**

---

## ✨ Features

- Actor-isolated signals for race-free data propagation  
- Auto-cleanup of deallocated subscribers  
- `emit`, `complete`, `fail` for lifecycle awareness  
- Type-safe events: `.next`, `.completed`, `.failed`  
- Value replay with configurable buffer size (`ValueSignal`)  
- Throttled and debounced emissions  
- Combine-compatible `.publisher`  
- Token-based unsubscribe system  
- Lightweight — no third-party dependencies required (except `swift-atomics`)  

---

## 📦 Installation

### Swift Package Manager (Recommended)

```swift
.package(url: "https://github.com/ranjanakarsh/Signal.swift.git", from: "1.0.0")
```

Then import:
```swift
import Signal
```

---

## Quick Start
### Basic Usage

```swift
let signal = Signal<String>()

let token = signal.subscribe(owner: self) { value in
    print("Received:", value)
}

signal.emit("Hello world!")
```

### With Completion and Failure

```swift
signal.subscribeEvent(owner: self) { event in
    switch event {
    case .next(let value): print("Received:", value)
    case .completed: print("Signal completed")
    case .failed(let error): print("Error:", error)
    }
}

signal.emit("final value")
signal.complete()
```

### Value Replay
```swift
let valueSignal = ValueSignal<Int>(replayCount: 2)
valueSignal.emit(1)
valueSignal.emit(2)

valueSignal.subscribe(owner: self) { value in
    print("Got replayed value:", value)
}
```

### Combine Integration
```swift
let publisher = await signal.publisher
let cancellable = publisher.sink { value in
    print("Combine received:", value)
}
```

## Architecture

### Signal Types

| Type    | Description |
| -------- | ------- |
| `Signal<T>`  | Multicasts values to multiple observers |
| `ValueSignal<T>` | Replays latest values on new subscriptions |
| `AnySignal<T>` | Type-erased wrapper for protocol abstraction |
| `SignalResult<T, E>` | Convenience enum for result-based signaling |
