# TokenScope WidgetKit Extension Source

This folder contains WidgetKit source intended for an Xcode app target/extension.
Swift Package Manager cannot build a WidgetKit extension target directly, so the
main SwiftPM app builds and tests the shared widget summary model while this file
is ready to be added to a `TokenScopeWidgetsExtension` target in Xcode.

Required production setup:

1. Create `TokenScopeWidgetsExtension` in Xcode.
2. Add `TokenScopeWidget.swift` to that extension target.
3. Enable App Groups for main app and widget, e.g. `group.com.tokenscope.app`.
4. Pass the same App Group id to `WidgetSummaryStore.defaultURL(appGroupIdentifier:)`.
