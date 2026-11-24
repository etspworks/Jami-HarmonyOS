/*
 * comp_renderer_layer — ported from Ring/Ring/Calls/Views/RendererLayerView.swift
 * `private final class VideoSurfaceView` (line 22) and `final class RendererLayerView` (line 34):
 *
 *   VideoSurfaceView    layerClass = AVSampleBufferDisplayLayer  — the raw video surface
 *   RendererLayerView   owns that surface, subscribes to a FrameDistributor, and reports
 *                       `onVideoContentChanged` / `onWholeFrameDisplayChanged` as frames arrive;
 *                       `renderedVideoRect` is the surface's own frame.
 *
 * On HarmonyOS the surface is an XComponent: its `onLoad` hands back the surface id the video
 * decoder renders into (S4 wires it to the call's frame source). The scaling policy the source
 * keeps (`aspectFill` vs whole-frame) is the XComponent's own fit here.
 *
 * The decoded frames come from libjami: VideoService attaches the surface to the sink.
 */

import { ServiceRegistry } from '../common/ServiceRegistry';

@Component
export struct RendererLayerView {
  /** Swift `participantId` / the sink the distributor feeds — the surface's identity. */
  rendererId: string = '';
  /** Swift `showsWholeFrame` — whole frame (contain) vs `aspectFill` (cover). */
  showsWholeFrame: boolean = false;
  /** Swift `onVideoContentChanged` — the surface reports its id once the component is ready. */
  onSurfaceReady?: (surfaceId: string) => void;

  private controller: XComponentController = new XComponentController();
  private surfaceId: string = '';

  build() {
    XComponent({
      id: this.rendererId,
      type: XComponentType.SURFACE,
      controller: this.controller
    })
      .width('100%')
      .height('100%')
      .onLoad(() => {
        const surfaceId: string = this.controller.getXComponentSurfaceId();
        this.surfaceId = surfaceId;
        // libjami's decoded frames for this sink are drawn into the surface natively.
        ServiceRegistry.shared().videoService.setSinkSurface(this.rendererId, surfaceId);
        const handler: ((surfaceId: string) => void) | undefined = this.onSurfaceReady;
        if (handler !== undefined) {
          handler(surfaceId);
        }
      })
      .onDestroy(() => {
        // A sink picture-in-picture took over stays on the floating window.
        ServiceRegistry.shared().videoService.releaseSinkSurface(this.rendererId, this.surfaceId, null);
      })
  }
}
