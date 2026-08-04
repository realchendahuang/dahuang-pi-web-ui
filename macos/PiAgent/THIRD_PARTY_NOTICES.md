# Pi Agent native client third-party notices

The native macOS target uses the following pinned Swift Package dependencies. The exact revisions are recorded in [`Package.resolved`](./Package.resolved) and are reviewed before an unsigned local App artifact is installed.

## SwiftTerm 1.11.2

- Upstream: [migueldeicaza/SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)
- Revision: `b1262db5b6bea699a8260a8c66999436c508ca56`
- License: MIT
- Use: AppKit `TerminalView` and VT emulation only. PTY creation, lifetime, cwd, replay buffer, and input authority remain in the Node session daemon.

The upstream repository's MIT copyright and license text are distributed with the Swift Package checkout used to build Pi Agent.

## swift-argument-parser 1.8.2

- Upstream: [apple/swift-argument-parser](https://github.com/apple/swift-argument-parser)
- Revision: `6a52f3251125d74daf04fcbd5e6f08a75d074382`
- License: Apache-2.0
- Use: Transitive package dependency declared by SwiftTerm; Pi Agent does not expose its command-line API as a product surface.

The Apache-2.0 license and NOTICE requirements are retained from the upstream package when the dependency is redistributed.
