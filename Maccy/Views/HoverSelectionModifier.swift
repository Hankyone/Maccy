import SwiftUI

private struct HoverSelectionModifier: ViewModifier {
  @Environment(AppState.self) private var appState
  var id: UUID

  // Short debounce for normal hover — fast enough to feel responsive,
  // but coalesces rapid hover events from scrolling into a single selection.
  static let hoverDebounce: UInt64 = 50_000_000 // 50ms

  // Longer delay when preview is open so the user can sweep the mouse
  // toward the preview without each intermediate item becoming selected.
  // This mimics the "safe triangle" hysteresis that NSMenu provides natively.
  static let previewHoverDelay: UInt64 = 150_000_000 // 150ms

  func body(content: Content) -> some View {
    content.onHover { hovering in
      if hovering {
        let delay = appState.preview.state.isOpen
          ? HoverSelectionModifier.previewHoverDelay
          : HoverSelectionModifier.hoverDebounce
        HoverSelectionCoordinator.shared.scheduleHover(id: id, delay: delay) {
          performSelection()
        }
      }
    }
  }

  private func performSelection() {
    if !appState.navigator.isKeyboardNavigating && !appState.navigator.isMultiSelectInProgress {
      appState.navigator.selectWithoutScrolling(id: id)
    } else {
      appState.navigator.hoverSelectionWhileKeyboardNavigating = id
    }
  }
}

@MainActor
final class HoverSelectionCoordinator {
  static let shared = HoverSelectionCoordinator()
  private var pendingTask: Task<Void, Never>?
  private var lastScheduledId: UUID?

  func scheduleHover(id: UUID, delay: UInt64, action: @escaping () -> Void) {
    // If the same item is already pending, don't reschedule
    guard lastScheduledId != id else { return }
    lastScheduledId = id
    pendingTask?.cancel()
    pendingTask = Task { @MainActor in
      try? await Task.sleep(nanoseconds: delay)
      guard !Task.isCancelled else { return }
      lastScheduledId = nil
      action()
    }
  }

  func cancel() {
    pendingTask?.cancel()
    pendingTask = nil
    lastScheduledId = nil
  }
}

extension View {
  func hoverSelectionId(_ id: UUID) -> some View {
    modifier(HoverSelectionModifier(id: id))
  }
}
