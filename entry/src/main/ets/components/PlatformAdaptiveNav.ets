/*
 * comp_platform_adaptive_nav — ported from Ring/Ring/Extensions/View+Helpers.swift
 * `struct PlatformAdaptiveNavView<Content>` (line 125). The source picked NavigationStack
 * (iOS 16+) or NavigationView by OS version; HarmonyOS has one navigation container, so the
 * version branch disappears and what survives is the wrapper itself: the accent-coloured
 * navigation shell every hosted screen is placed inside.
 */
@Component
export struct PlatformAdaptiveNavView {
  /** Swift `let content: () -> Content`. */
  @BuilderParam content: () => void;

  build() {
    Column() {
      this.content()
    }
    .width('100%')
    .height('100%')
    // Swift `PlatformAdaptiveNavView` wraps every hosted screen in the navigation shell; on a
    // plain (non-grouped) iOS screen that resolves to `systemBackground`.
    .backgroundColor($r('sys.color.background_primary'))
  }
}
