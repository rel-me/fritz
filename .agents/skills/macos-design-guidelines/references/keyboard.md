# Keyboard access

Distinguish keyboard accessibility from a dedicated shortcut. People should be
able to reach relevant controls and complete the workflow with keyboard access;
every action does not need its own key combination.

Check focus order, visible focus, traversal out of custom controls, and standard
selection/editing behavior with macOS Full Keyboard Access. Preserve shortcuts
used by text editing and the chat composer. Use the
[keyboard lookup](keyboard-reference.md) only for an affected standard command.

Test Return and Escape in the focused context. Return must not unexpectedly
submit an ordinary multiline editor; Fritz's chat composer intentionally uses
Return to send and Shift-Return for a newline. Escape stops generation in chat
and must not silently discard edits or cancel unrelated work elsewhere. Verify the intended default/cancel actions instead of assuming
all sheets dismiss automatically. Deletion, undo, and previews should follow the
surface's supported data operations; do not invent undo for irreversible actions.

[Apple keyboard guidance](https://developer.apple.com/design/human-interface-guidelines/keyboards)
recommends custom shortcuts for frequently used app-specific commands.
