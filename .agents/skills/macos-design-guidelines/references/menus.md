# Menus and command discovery

Check that Fritz's standard app commands remain recognizable and common actions
are discoverable in the menu bar. Titles, enabled state, and checkmarks should
reflect the selected window/thread and available operations.

Preserve standard shortcuts. Add custom shortcuts for frequently used commands,
not every menu item; avoid collisions with system and text-editing commands.
A context menu is useful for actions on a particular item, not mandatory on every
control. Verify its actions target the clicked/selected record correctly.

Test command routing when focus moves between the sidebar, chat composer,
and another Fritz window. Missing or ambiguous actions matter more than an exact
menu template. Follow [Apple's keyboard guidance](https://developer.apple.com/design/human-interface-guidelines/keyboards)
for shortcut conventions.
