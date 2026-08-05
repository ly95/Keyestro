# ADR 0001: Native Swift, AppKit, and SwiftUI

- Status: accepted
- Date: 2026-08-03

Keyestro targets macOS only. Swift 6 strict concurrency is the implementation language. AppKit owns panels, focus, hotkeys, pasteboard, Accessibility, Spotlight, and other system boundaries; SwiftUI owns content and settings views. Rust is excluded until profiling demonstrates a bounded pure-compute bottleneck and a separate ADR establishes a favorable maintenance tradeoff.
