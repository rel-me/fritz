# System integration

Review only the integration the task concerns: Dock behavior, file handling,
sharing, notifications, or another existing macOS capability. Check its lifecycle,
permissions, focused target, cancellation, and failure feedback.

Do not add Spotlight indexing, Quick Look, App Intents, scripting dictionaries,
or share extensions simply because they are possible on macOS. Fritz's Rust CLI
owns provider operations; the app communicates with its bundled agent through
private pipes. A design review does not require an HTTP service or new transport.
