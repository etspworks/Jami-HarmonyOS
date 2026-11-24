/*
 * comp_document_picker — ported from Ring/Ring/UI/SwiftUIViews/DocumentPicker.swift
 * `struct DocumentPicker: UIViewControllerRepresentable`:
 *
 *   @Binding var fileURL: URL?
 *   var type: UTType
 *   makeUIViewController -> UIDocumentPickerViewController(forOpeningContentTypes: [type])
 *                           allowsMultipleSelection = false
 *   coordinator.documentPicker(_:didPickDocumentAt:) { fileURL = url }
 *
 * The source mounts it inside `.sheet(isPresented: $viewModel.pickerPresented)`, i.e. the
 * picker EXISTS only while the flag is true and writes the picked URL back into the caller's
 * binding. That is reproduced here: the caller renders this component under its own
 * `if (presented)`, the picker is raised as the component appears, and both bindings are
 * written on the way out — `fileUri` with the pick, `presented` back to false, exactly like
 * the sheet dismissing itself.
 *
 * feat_document_picker: UIDocumentPickerViewController -> @ohos.file.picker DocumentViewPicker
 * (a system UI gesture; no storage permission is requested and none is needed).
 */
import picker from '@ohos.file.picker';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { describeError } from '../common/ErrorText';

const LOG_DOMAIN: number = 0x0001;
const LOG_TAG: string = 'DocumentPicker';

@Component
export struct DocumentPicker {
  /** Swift `@Binding var fileURL: URL?` — empty means the source's `nil`. */
  @Link fileUri: string;
  /** Swift `.sheet(isPresented: $viewModel.pickerPresented)` — the sheet's own presentation. */
  @Link presented: boolean;
  /**
   * Swift `var type: UTType`, as the HarmonyOS picker spells it: a suffix filter, empty for
   * the source's `.item` (any document).
   */
  fileSuffixFilters: string[] = [];
  /** Swift `allowsMultipleSelection = false`. */
  maxSelectNumber: number = 1;
  /** describeError() output handed back to the caller; empty when the pick succeeded. */
  onError?: (message: string) => void;

  /** The sheet is raised as it is mounted — Swift presents the VC the moment the flag flips. */
  aboutToAppear(): void {
    this.select();
  }

  /** Swift `makeUIViewController` + `documentPicker(_:didPickDocumentAt:)`. */
  private select(): void {
    const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
    options.maxSelectNumber = this.maxSelectNumber;
    if (this.fileSuffixFilters.length > 0) {
      options.fileSuffixFilters = this.fileSuffixFilters;
    }
    new picker.DocumentViewPicker().select(options)
      .then((uris: string[]): void => {
        // Swift's coordinator only assigns on a pick; a cancelled picker leaves fileURL alone.
        if (uris.length > 0) {
          this.fileUri = uris[0];
        }
        this.presented = false;
      })
      .catch((error: BusinessError): void => {
        const message: string = describeError(error);
        hilog.error(LOG_DOMAIN, LOG_TAG, 'document pick failed: %{public}s', message);
        this.presented = false;
        const handler: ((message: string) => void) | undefined = this.onError;
        if (handler !== undefined) {
          handler(message);
        }
      });
  }

  /**
   * The source's picker is a presented view controller, so it contributes nothing to the
   * host's own layout — the ArkUI counterpart is the same: a zero-sized mount point.
   */
  build() {
    Stack() {
    }
    .width(0)
    .height(0)
  }
}
