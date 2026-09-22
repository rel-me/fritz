# Commands and Menus

## Intent

Use this when mapping desktop actions into menu items, keyboard shortcuts, and focused scene behavior.

## Core patterns

- Add `commands` at the scene level.
- Use `CommandMenu` for app-specific actions.
- Use `CommandGroup` to insert, replace, or remove menu sections.
- Use `FocusedValue` or scene state to make commands context-sensitive.
- Pair important commands with keyboard shortcuts and visible toolbar or content affordances when appropriate.

## Pitfalls

- Do not register the same shortcut in multiple places.
- Do not make commands the only discoverable path for a critical action.
- If you need responder-chain validation, custom menu item state, or AppKit-specific command behavior, use a narrow AppKit bridge following the nearest existing Fritz implementation.
