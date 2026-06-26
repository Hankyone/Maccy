import SwiftUI

private struct HoverSelectionModifier: ViewModifier {
  @Environment(AppState.self) private var appState
  var id: UUID

  // When the preview is open, delay selection changes so the user can
  // move the mouse toward the preview without triggering intermediate items.
  // This mimics the "safe triangle" hysteresis that NSMenu provides natively.
  static let previewHoverDelay: UInt64 = 150_000_000 // 150ms in nanoseconds

  // During scrolling, items move under a stationary cursor and fire onHover.
  // Ignore these by checking if the mouse actually moved recently.
  static let mouseMoveTimeout: Duration = .milliseconds(200)

  func body(content: Content) -> some View {
    content.onHover { hovering in
      if hovering {
        // Skip hover events that come from scrolling (mouse hasn't actually moved)
        if !HoverSelectionCoordinator.shared.mouseMovedRecently() {
          return
        }

        if appState.preview.state.isOpen {
          // Delay selection when preview is open so the user can sweep
          // the mouse across items toward the preview without each
          // intermediate item becoming selected.
          HoverSelectionCoordinator.shared.scheduleHover(id: id) {
            performSelection()
          }
        } else {
          HoverSelectionCoordinator.shared.cancel()
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
  private var lastMouseMovedAt: ContinuousClock.Instant = .now

  func scheduleHover(id: UUID, action: @escaping () -> Void) {
    pendingTask?.cancel()
    pendingTask = Task { @MainActor in
      try? await Task.sleep(nanoseconds: HoverSelectionModifier.previewHoverDelay)
      guard !Task.isCancelled else { return }
      action()
    }
  }

  func cancel() {
    pendingTask?.cancel()
    pendingTask = nil
  }

  func recordMouseMove() {
    lastMouseMovedAt = .now
  }

  func mouseMovedRecently() -> Bool {
    let elapsed = ContinuousClock.now - lastMouseMovedAt
    return elapsed <= HoverSelectionModifier.mouseMoveTimeout
  }
}

extension View {
  func hoverSelectionId(_ id: UUID) -> some View {
    modifier(HoverSelectionModifier(id: id))
  }
}
