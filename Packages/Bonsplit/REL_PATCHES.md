# REL Bonsplit Package

This directory vendors Bonsplit 1.1.1 at revision
`7c322f078c388438e4b7896a86c57598aa7e203d`.

REL adds optional `tabBarBackground` and `activeTabBackground` appearance
values so the app can supply its adaptive workspace surface colors without
duplicating colors across the app and gallery. REL's default tabs use Chrome
geometry with a window-matched strip, subtle selection and hover fills, and no
pane container fill.
It also makes `allowCloseTabs` control close-button visibility as documented,
in addition to rejecting close operations in the controller.

Tab close controls stay mounted while hidden. Passive AppKit tracking areas
report hover independently of SwiftUI drag targets and refresh against the
current pointer when layout changes, including scrolling and tab selection.

Fritz imports this self-contained UI package from REL revision
`f062b1ba54de8b2181034623d46fb45f5fe5b3a0`, including its adaptive palette,
shared new-tab control, compact/overflow layout, context-menu API and hover
tracking. No application services or app state are included.

Fritz additionally omits content drop targets when both splitting and cross-pane
moves are disabled, hides inactive kept-alive content from accessibility, and
enforces `allowCloseTabs` in the public close APIs as well as the visible controls.
The package remains independently usable; Fritz also exports `Bonsplit` from its
root package and runs these package tests with `make test-swift`.

`BonsplitTabBar` extracts the standalone strip composition and trailing new-tab
action into the library, so hosts do not duplicate its width/overflow layout.
