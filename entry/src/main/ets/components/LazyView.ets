/*
 * comp_lazy_view — ported from
 * Ring/Ring/Features/Conversations/SmartList/SwiftUI/Views/SmartListContainer.swift
 * `struct LazyView<Content>` (line 326). SwiftUI built a navigation destination eagerly;
 * LazyView deferred it behind a closure. ArkUI's equivalent is a @BuilderParam evaluated
 * only once `isActive` is true, so an off-screen destination costs nothing.
 */
@Component
export struct LazyView {
  /** Swift `let build: () -> Content`. */
  @BuilderParam content: () => void;
  /** The destination is only reached (and therefore only built) once this turns true. */
  isActive: boolean = true;

  build() {
    Column() {
      if (this.isActive) {
        this.content()
      }
    }
  }
}
