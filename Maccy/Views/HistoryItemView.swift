import Defaults
import SwiftUI

struct HistoryItemView: View {
  @Bindable var item: HistoryItemDecorator
  var previous: HistoryItemDecorator?
  var next: HistoryItemDecorator?
  var index: Int

  private var selectionAppearance: SelectionAppearance {
    let previousSelected = previous?.isSelected ?? false
    let nextSelected = next?.isSelected ?? false
    switch (previousSelected, nextSelected) {
    case (true, false):
      return .topConnection
    case (false, true):
      return .bottomConnection
    case (true, true):
      return .topBottomConnection
    default:
      return .none
    }
  }

  @Default(.showHexColorSwatch) private var showHexColorSwatch
  @Environment(AppState.self) private var appState

  private var colorSwatchImage: NSImage? {
    guard showHexColorSwatch else { return nil }
    return ColorImage.from(item.title)
  }

  private func performSelect() {
    if NSEvent.modifierFlags.contains(.command) && appState.multiSelectionEnabled {
      appState.navigator.addToSelection(item: item)
    } else {
      let flags = NSEvent.ModifierFlags.currentModifierFlags
      Task {
        appState.history.select(item, flags: flags)
      }
    }
  }

  var body: some View {
    ListItemView(
      id: item.id,
      selectionId: item.id,
      appIcon: item.applicationImage,
      image: item.thumbnailImage,
      accessoryImage: item.thumbnailImage != nil ? nil : colorSwatchImage,
      attributedTitle: item.attributedTitle,
      shortcuts: item.shortcuts,
      isSelected: item.isSelected,
      selectionIndex: item.multiSelectionIndex,
      selectionAppearance: selectionAppearance,
      accessibilityLabel: item.accessibilityLabel
    ) {
      Text(verbatim: item.title)
    }
    .accessibilityIdentifier("copy-history-item")
    .buttonAction(performSelect)
    .onAppear {
      item.ensureThumbnailImage()
    }
    .accessibilityAction(named: Text(item.isPinned ? "history_item_unpin_action" : "history_item_pin_action")) {
      appState.history.togglePin(item)
    }
    .accessibilityAction(named: Text("history_item_delete_action")) {
      appState.history.delete(item)
    }
    .contextMenu { contextMenu }
  }

  @ViewBuilder
  private var contextMenu: some View {
    let selected = appState.navigator.selection.items
    if appState.navigator.isMultiSelectInProgress, selected.count > 1, selected.contains(item) {
      Button("Paste \(selected.count) Clips Together") {
        ClipActions.combine(selected, flags: HistoryItemAction.paste.modifierFlags)
      }
      Button("Copy \(selected.count) Clips Together") {
        ClipActions.combine(selected, flags: HistoryItemAction.copy.modifierFlags)
      }
      Divider()
    }
    Button("Paste") {
      appState.history.select(item, flags: HistoryItemAction.paste.modifierFlags)
    }
    Button("Copy") {
      appState.history.select(item, flags: HistoryItemAction.copy.modifierFlags)
    }
    if ClipActions.canPasteAsFilePath(item) || ClipActions.recognizedText(item) != nil
        || ClipActions.tidyJSON(item) != nil {
      Divider()
    }
    if ClipActions.canPasteAsFilePath(item) {
      Button("Paste as File Path") { ClipActions.pasteAsFilePath(item) }
    }
    if let text = ClipActions.recognizedText(item) {
      Button("Paste Recognized Text") { ClipActions.paste(text) }
    }
    if let json = ClipActions.tidyJSON(item) {
      Button("Paste as Tidy JSON") { ClipActions.paste(json) }
    }
    Divider()
    Button(item.isPinned ? "Unpin" : "Pin") { appState.history.togglePin(item) }
    Button("Delete", role: .destructive) { appState.history.delete(item) }
  }
}
