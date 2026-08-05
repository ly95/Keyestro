# Architecture overview

Keyestro has three boundaries:

1. `KeyestroDomain` is Foundation-only and owns versioned identifiers, query/action models, normalization, matching, ranking, and deduplication.
2. `KeyestroCore` owns providers and protocol-based adapters for macOS services, persistence, processes, permissions, capture, and extensions.
3. `KeyestroApp` owns AppKit lifecycle/window focus and SwiftUI presentation. It reaches system behavior only through core coordinators and services.

Each search has a monotonically increasing generation and request UUID. Providers run concurrently and stream bounded batches. The coordinator discards stale events, validates candidates, deduplicates canonical resources, ranks deterministically, and publishes at most 50 visible items. Actions resolve stable item and action IDs again immediately before execution.

Native extensions run one process per extension and communicate using length-bounded JSON-RPC 2.0 over standard pipes. They never provide executable UI objects or load code into the app process.
