# Pointer and selection

Use native hit testing, cursor, hover, and selection behavior where it fits the
control. Report an undiscoverable action, incorrect hit area, or misleading cursor
rather than requiring custom hover effects on every element.

Use context menus when they provide useful item-specific actions. Drag/drop and
multiple selection belong where the data operations support them; do not add
these features solely to satisfy a generic checklist. If supported, check target
identity, selection ranges, invalid drops, and cancellation.

For scrolling, verify mouse wheel and trackpad input, nested scroll views, and
content boundaries. Check chat selection, code copying, and sidebar/context-menu
actions using the native controls.
