/*
 * comp_forward_contact_picker — ported from
 *   Ring/Ring/Features/Conversations/Preview/MediaPreviewView.swift
 *   `private struct ForwardContactPicker` (line 448):
 *
 *     ContactPickerView(viewModel: viewModel, onDismissed: nil)
 *         .onAppear {
 *             viewModel.type = .forConversation
 *             viewModel.conversationSelectedCB = { selected in callback(selected) }
 *             viewModel.bind()
 *         }
 *
 * It is a THIN WRAPPER over the app's existing contact picker, exactly as the source is: it
 * sets the picker to its conversation mode and routes the picked conversation ids back to the
 * caller's forward callback. No row set, no service of its own — ContactPickerSheet
 * (screen_contact_picker) owns both, so nothing here duplicates it.
 */
import { ContactPickerSheet } from '../pages/ContactPickerPage';

@Component
export struct ForwardContactPicker {
  /** Swift `.sheet(item: $model.activeSheet)` — the preview raises and lowers this picker. */
  @Link isPresented: boolean;
  /** Swift `let callback: ([String]) -> Void` — MediaPreviewModel.forwardCallback. */
  onConversationsSelected?: (conversationIds: string[]) => void;

  build() {
    // Swift `viewModel.type = .forConversation` is `pickerForConversation: true`.
    ContactPickerSheet({
      isPresented: $isPresented,
      pickerForConversation: true,
      onConversationsSelected: (conversationIds: string[]): void => {
        const handler: ((ids: string[]) => void) | undefined = this.onConversationsSelected;
        if (handler !== undefined) {
          handler(conversationIds);
        }
        this.isPresented = false;
      }
    })
  }
}
