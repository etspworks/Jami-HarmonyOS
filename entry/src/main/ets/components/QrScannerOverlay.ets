/*
 * comp_qr_scanner_overlay — ported from the `scanImage` view of
 * Ring/Ring/QRCode/ScanViewController.storyboard:
 *
 *   <imageView userInteractionEnabled="NO" alpha="0.7" image="scan"
 *              width="250" height="250" tintColor="white"/>
 *   centred on the controller's root view (centerX / centerY constraints)
 *
 * It is the viewfinder frame drawn OVER the live camera preview — chrome only, it never takes
 * a touch (`userInteractionEnabled="NO"`), which is why it carries no `.onClick` and no id.
 * The asset is the source app's own `scan` image, carried over by the assets pass.
 */

/** Storyboard `<constraint firstAttribute="width|height" constant="250"/>`. */
const VIEWFINDER_SIZE: number = 250;
/** Storyboard `alpha="0.69999999999999996"`. */
const VIEWFINDER_ALPHA: number = 0.7;

@Component
export struct QRCodeScannerOverlayView {
  /** The scan screens differ in how much room they give the frame; 250 is the storyboard's. */
  sideLength: number = VIEWFINDER_SIZE;

  build() {
    Image($r('app.media.scan'))
      .width(this.sideLength)
      .height(this.sideLength)
      .objectFit(ImageFit.Contain)
      .opacity(VIEWFINDER_ALPHA)
      // Storyboard `userInteractionEnabled="NO"` — the frame must never swallow a touch aimed
      // at the preview beneath it (arkts-and-arkui §3, overlay-swallows-touch).
      .hitTestBehavior(HitTestMode.Transparent)
  }
}
