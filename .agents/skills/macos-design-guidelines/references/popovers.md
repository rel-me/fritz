# Popovers and transient editors

Check that the popover is anchored to the invoking control and remains usable
with long text, a small window, and keyboard navigation. Choose sizing/scrolling
from actual content rather than an arbitrary fixed maximum.

Verify dismissal, focus return, and pending edits for outside clicks, Escape,
and source-view removal. Do not assume framework defaults cover a custom editor's
lifecycle. Use a sheet or separate window only when the workflow needs its
persistence or interaction model; avoid redesigning an unrelated presentation.
