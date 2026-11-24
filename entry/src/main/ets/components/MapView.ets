/*
 * comp_map_view — ported from
 * .../MessageSwiftUI/Views/MapView.swift `struct MapView: UIViewRepresentable` (line 24):
 *
 *   makeUIView  MKMapView + MKTileOverlay("https://tile.openstreetmap.org/{z}/{x}/{y}.png")
 *                 with `canReplaceMapContent = true` — the platform map is REPLACED by
 *                 OpenStreetMap raster tiles, which is why the attribution button exists;
 *               if showZoomButton { a 55 pt "location.fill" button, "locationSharingZoomToUser",
 *                 pinned 120 pt above the bottom / 15 pt from the trailing edge };
 *               addPins(mapView:) — one annotation per shared position;
 *               zoomMap(mapView:) — centres on the first annotation, span 0.01°.
 *   updateUIView  addPins again whenever the coordinates change.
 *
 * CAPABILITY: the source does not use the platform's map data at all — it replaces it with OSM
 * tiles. Map Kit's `MapComponent` would put HMS map data back and needs an AppGallery-Connect
 * registration a self-signed build does not have, so the port keeps the SOURCE's own tile
 * endpoint: a small slippy-map page in ArkWeb fills the {z}/{x}/{y} template for the tiles
 * around the centre and draws the pins over them. Loading the template itself as a URL is what
 * made OSM answer "You requested an invalid tile."
 */
import { webview } from '@kit.ArkWeb';
import { util } from '@kit.ArkTS';
import { LengthMetrics } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { geoLocationManager } from '@kit.LocationKit';
import { ServiceRegistry } from '../common/ServiceRegistry';

/* ── S5 metrics, the source's own (MapView.swift:24-60) ──── */
/** Swift: a 55pt "location.fill" button, `cornerRadius = 16`, on `.systemBackground`. */
const ZOOM_BUTTON_SIZE: number = 55;
const ZOOM_BUTTON_RADIUS: number = 16;
const ZOOM_GLYPH_SIZE: number = 24;
/** Swift: pinned 120pt above the bottom, 15pt from the trailing edge. */
const ZOOM_BOTTOM_INSET: number = 120;
const ZOOM_TRAILING_INSET: number = 15;

const LOG_DOMAIN: number = 0x0001;
const LOG_TAG: string = 'MapView';

/** Swift `let urlTemplate = "https://tile.openstreetmap.org/{z}/{x}/{y}.png"`. */
const OSM_TILE_TEMPLATE: string = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
/**
 * The OSM tile usage policy asks an app for a User-Agent naming it; iOS's URLSession sends
 * "Jami/<build>". A browser User-Agent with no Referer (this page has none) gets blocked.
 */
const OSM_USER_AGENT: string = 'Jami-HarmonyOS (+https://jami.net)';

/**
 * Swift `zoom(on:)`'s `MKCoordinateSpan(latitudeDelta: 0.01)` fitted to the view height; the
 * pin is the 35pt round avatar of `viewFor annotation:` (the default person on Jami blue).
 * Tiles are the next zoom level's drawn at 128 px, as MKTileOverlay draws them on a retina
 * screen (T-1651 review: 256 px tiles showed labels ~1.7x larger than the iOS map).
 * ponytail: pan only; add pinch zoom if reviewers need it (a second pointer -> z ± 1).
 */
const MAP_PAGE: string = `<!DOCTYPE html><html><head>
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
<style>
html,body{margin:0;width:100%;height:100%;overflow:hidden;background:#F2EFE9;touch-action:none}
#m{position:absolute;left:0;top:0;width:100%;height:100%}
#m img,#m .p{position:absolute}
#m img{width:128px;height:128px}
#m .p{width:35px;height:35px;margin:-17.5px 0 0 -17.5px;border-radius:50%;background:#00345F}
</style></head><body><div id="m"><div id="t"></div><div id="p"></div></div><script>
var T='${OSM_TILE_TEMPLATE}',SPAN=0.01,z=15,c=null,pins=[],drag=null,m=document.getElementById('m');
var AVATAR='<svg viewBox="0 0 35 35" width="35" height="35"><circle cx="17.5" cy="13" r="6" fill="#fff"/><path d="M6.5 29a11 11 0 0 1 22 0z" fill="#fff"/></svg>';
function world(lat,lon){var s=256*Math.pow(2,z),r=lat*Math.PI/180;
  return {x:(lon+180)/360*s,y:(1-Math.log(Math.tan(r)+1/Math.cos(r))/Math.PI)/2*s};}
function center(lat,lon){
  z=Math.max(3,Math.min(19,Math.round(Math.log2(360*Math.cos(lat*Math.PI/180)*innerHeight/(256*SPAN)))));
  c=world(lat,lon);tiles();marks();}
function tiles(){if(!c)return;var x0=c.x-innerWidth/2,y0=c.y-innerHeight/2,n=Math.pow(2,z+1),h='';
  for(var x=Math.floor(x0/128);x*128<x0+innerWidth;x++)
    for(var y=Math.max(0,Math.floor(y0/128));y*128<y0+innerHeight&&y<n;y++)
      h+='<img src="'+T.replace('{z}',z+1).replace('{x}',((x%n)+n)%n).replace('{y}',y)+
        '" style="left:'+(x*128-x0)+'px;top:'+(y*128-y0)+'px">';
  document.getElementById('t').innerHTML=h;}
function marks(){if(!c)return;var x0=c.x-innerWidth/2,y0=c.y-innerHeight/2,h='';
  for(var i=0;i<pins.length;i++){var q=world(pins[i][0],pins[i][1]);
    h+='<div class="p" style="left:'+(q.x-x0)+'px;top:'+(q.y-y0)+'px">'+AVATAR+'</div>';}
  document.getElementById('p').innerHTML=h;}
function setPins(list){pins=list;if(!c&&list.length){center(list[0][0],list[0][1]);}else{marks();}}
onresize=function(){if(pins.length)center(pins[0][0],pins[0][1]);};
m.onpointerdown=function(e){drag={x:e.clientX,y:e.clientY};m.setPointerCapture(e.pointerId);};
m.onpointermove=function(e){if(drag)m.style.transform='translate('+(e.clientX-drag.x)+'px,'+(e.clientY-drag.y)+'px)';};
m.onpointerup=m.onpointercancel=function(e){if(!drag)return;
  if(c){c.x-=e.clientX-drag.x;c.y-=e.clientY-drag.y;}drag=null;m.style.transform='';tiles();marks();};
</script></body></html>`;

const MAP_PAGE_BASE64: string =
  new util.Base64Helper().encodeToStringSync(new util.TextEncoder().encodeInto(MAP_PAGE));

/** Swift `LocationSharingAnnotation` — one shared position on the map. */
export class LocationAnnotation {
  /** Whose position this is; also the list key. */
  peerUri: string = '';
  latitude: number = 0;
  longitude: number = 0;
}

@Component
export struct MapView {
  /** Swift `@Binding var annotations` — `updateUIView` re-adds the pins on every change. */
  @Prop @Watch('pushPins') annotations: LocationAnnotation[] = [];
  /** Swift `@Binding var showZoomButton` — only while the map is opened full-screen. */
  @Prop showZoomButton: boolean = false;

  private tileController: webview.WebviewController = new webview.WebviewController();

  /** Swift `addPins(mapView:)`; the first set also runs `zoomMap(mapView:)`. */
  private pushPins(): void {
    const pins: number[][] =
      this.annotations.map((pin: LocationAnnotation): number[] => [pin.latitude, pin.longitude]);
    this.run('setPins(' + JSON.stringify(pins) + ')');
  }

  /** Swift `zoomMap(onUserLocation: true)` — the device's own fix, when there is one. */
  private zoomToUser(): void {
    const location: geoLocationManager.Location | null =
      ServiceRegistry.shared().locationSharingService.currentLocation.value;
    if (location !== null) {
      this.run('center(' + location.latitude + ',' + location.longitude + ')');
    }
  }

  private run(script: string): void {
    this.tileController.runJavaScript(script).catch((error: Object): void => {
      hilog.debug(LOG_DOMAIN, LOG_TAG, 'map page not ready: %{public}s', JSON.stringify(error));
    });
  }

  build() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      // Swift `MKTileOverlay(urlTemplate:)` with `canReplaceMapContent` — the OSM raster
      // surface itself, with the pins drawn on it.
      Web({ src: 'about:blank', controller: this.tileController })
        .width('100%')
        .height('100%')
        .zoomAccess(false)
        .horizontalScrollBarAccess(false)
        .verticalScrollBarAccess(false)
        // The OSM User-Agent has no "Mobile", which turns the page's viewport meta off: the page
        // then lays out 980 px wide and draws tiles and pin ~4x smaller than iOS's 256 pt tiles.
        .metaViewport(true)
        .onControllerAttached(() => {
          this.tileController.setCustomUserAgent(OSM_USER_AGENT);
        })
        .onPageEnd((event: OnPageEndEvent) => {
          // The src's about:blank commits AFTER onControllerAttached and aborts a loadData made
          // there (hilog: LoadWithData, then LoadUrl about:blank, OnLoadError ERR_ABORTED), so
          // the map page is loaded once about:blank has finished. base64, because a plain data
          // URL ends at the page's first '#' (CSS ids, colours).
          if (event.url === 'about:blank') {
            this.tileController.loadData(MAP_PAGE_BASE64, 'text/html', 'base64');
            return;
          }
          this.pushPins();
        })

      // Swift `if showZoomButton` — the 55 pt zoom-to-user button, opened map only.
      if (this.showZoomButton) {
        SymbolGlyph($r('sys.symbol.location_up_fill'))
          .id('locationSharingZoomToUser')
          .accessibilityText($r('app.string.alerts_location_sharing'))
          .fontSize(ZOOM_GLYPH_SIZE)
          .fontColor([$r('app.color.label')])
          .width(ZOOM_BUTTON_SIZE)
          .height(ZOOM_BUTTON_SIZE)
          .backgroundColor($r('sys.color.background_primary'))
          .borderRadius(ZOOM_BUTTON_RADIUS)
          .clip(true)
          .margin({
            end: LengthMetrics.vp(ZOOM_TRAILING_INSET),
            bottom: LengthMetrics.vp(ZOOM_BOTTOM_INSET)
          })
          .onClick(() => {
            this.zoomToUser();
          })
      }
    }
    .width('100%')
    .height('100%')
  }
}
