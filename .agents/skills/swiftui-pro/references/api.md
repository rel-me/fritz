# API compatibility review

Check the affected target's platform, language mode, and compiler settings in
`app/Package.swift` and `app/project.yml` before
recommending a replacement. Distinguish an actual compiler diagnostic or behavior
problem from a newer spelling that happens to exist.

For a replacement, establish availability on Fritz's minimum macOS version and
preservation of behavior, accessibility, and state identity. Keep mechanical
modernization within the requested scope. Do not flag GeometryReader, explicit
bindings, tab declarations, or Foundation APIs merely by their names.

Fritz uses native SwiftUI/AppKit views. Preserve the private-pipe Rust agent
boundary and native rendering. Read the affected wrapper and caller before
changing native interoperability code.
