# Menu bar extras

Use this reference only for a requested menu-bar surface. Preserve Fritz's regular
app activation and primary window behavior; do not turn it into a menu-bar-only
utility or replace its launch coordinator.

Keep quick actions concise and move deeper workflows into the existing window
that owns them. Bound long titles based on the actual menu layout, with a way to
reach the full content. Do not impose an arbitrary character limit on all labels.

Verify action routing, enabled state, focus, and reopening the main window when
the extra is used. If native status-item behavior needs AppKit, follow the local
build-macos-apps references and keep state ownership with the existing model.
