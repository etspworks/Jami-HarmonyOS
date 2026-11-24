/*
 * comp_video_preview_layer — ported from
 * Ring/Ring/Features/Conversations/MediaRecord/MediaRecordView.swift
 * `private struct VideoPreviewLayer` (line 300):
 *
 *   GeometryReader { geo in
 *     if viewModel.audioOnly { Color(UIColor.systemBackground) }
 *     else { Color.black
 *            if let image = viewModel.previewImage {
 *              Image(uiImage: image).resizable().scaledToFill()
 *                .frame(geo.size).clipped() } }
 *   }
 *
 * FRAMES BECAME A SURFACE. iOS pushed one `UIImage` per captured frame into this view;
 * HarmonyOS renders the camera straight into an XComponent surface, which is what
 * `VideoService.setPreviewSurface(surfaceId)` takes (VideoService.ts:1421 and its header
 * note). So the `previewImage` binding becomes "hand the surface id to svc_video" — the
 * preview frames are still svc_video's, never a bundled placeholder.
 *
 * The black backdrop stays: it is what shows before the first frame arrives, and it is
 * still what shows if the device has no camera.
 *
 * Not interactive — no Rule-12 slug, because nothing here has an onClick.
 *
 * S3: structure only.
 */

@Component
export struct VideoPreviewLayer {
  /** Swift `viewModel.audioOnly` — the audio branch draws the plain page background. */
  @Prop audioOnly: boolean = false;
  /** ArkUI's replacement for `viewModel.previewImage`: the surface svc_video renders into. */
  onSurfaceReady?: (surfaceId: string) => void;
  /** The surface is going away; svc_video must stop rendering into it. */
  onSurfaceReleased?: () => void;

  private surfaceController: XComponentController = new XComponentController();

  build() {
    Stack() {
      if (this.audioOnly) {
        // Swift `Color(UIColor.systemBackground)`.
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor($r('sys.color.background_primary'))
      } else {
        // Swift `Color.black` under the frames.
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(Color.Black)
        XComponent({
          id: 'mediaRecordPreview',
          type: XComponentType.SURFACE,
          controller: this.surfaceController
        })
          .width('100%')
          .height('100%')
          .onLoad(() => {
            const ready: ((surfaceId: string) => void) | undefined = this.onSurfaceReady;
            const surfaceId: string = this.surfaceController.getXComponentSurfaceId();
            if (ready !== undefined && surfaceId.length > 0) {
              ready(surfaceId);
            }
          })
          .onDestroy(() => {
            const released: (() => void) | undefined = this.onSurfaceReleased;
            if (released !== undefined) {
              released();
            }
          })
      }
    }
    .width('100%')
    .height('100%')
  }
}
