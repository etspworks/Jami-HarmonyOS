/*
 * comp_participant_canvas — ported from
 *   Ring/Ring/Calls/Views/Canvas/ParticipantTileUIView.swift `final class ParticipantTileUIView`
 *     (line 42) + `struct ParticipantTileState` (line 21)
 *   Ring/Ring/Calls/Views/Canvas/ParticipantCanvas.swift `final class ParticipantCanvas`
 *     (line 56) + `struct CanvasTileModel` (line 21)
 *
 *   ParticipantTileUIView = the video surface (RendererLayerView) with, over it,
 *     - CallAvatarView, shown when the tile has no video (lifted by 1/6 in audio-only mode),
 *     - a name plate (`showsName`), and
 *     - the audio-muted / hand-raised / speaking indicators of ParticipantTileState.
 *   ParticipantCanvas = the tiles laid out in a grid (`CanvasLayoutMode.grid`), with the LOCAL
 *     PREVIEW floating over them when there is more than one tile (`previewFloats`), plus
 *     `onCanvasTapped` (the chrome toggle) and `onTileLongPressed`.
 *
 * The canvas's 1125 lines are overwhelmingly the preview's drag physics, dock animation and
 * frame-transform bookkeeping — behaviour of an already-correct tree. What the STRUCTURE is:
 * a keyed set of tiles, a grid, a floating preview, and the two gestures. That is what is built
 * here; the layout mode and the tile set are data (svc_calls), never literals.
 */
import { ConferenceParticipantInfo } from '../model/ConferenceParticipantInfo';
import { ServiceRegistry } from '../common/ServiceRegistry';
import { VideoFrameInfo, VideoService } from '../common/VideoService';
import { LengthMetrics } from '@kit.ArkUI';

/* ── S5 metrics, the source's own (ParticipantTileUIView.swift:45-205, Canvas) ────── */
/** Swift `Metrics.nameHorizontalPadding = 8` / `nameVerticalPadding = 3`. */
const NAME_H_PADDING: number = 8;
const NAME_V_PADDING: number = 3;
/** Swift `Metrics.nameEdgeMargin = 8` / `nameBottomMargin = 6`. */
const NAME_EDGE_MARGIN: number = 8;
const NAME_BOTTOM_MARGIN: number = 6;
/** Swift `nameLabel.font = .systemFont(ofSize: 13, weight: .medium)`, white. */
const NAME_FONT_SIZE: number = 13;
/** Swift `namePlate.layer.cornerRadius = namePlate.bounds.height / 2` — a capsule. */
const NAME_PLATE_RADIUS: number = 12;
/** The mute glyph beside the name. */
const NAME_GLYPH_SIZE: number = 12;
/** Swift `CanvasLayout.tileCornerRadius` on a card tile; `PreviewDocking.cornerRadius = 14`. */
const TILE_RADIUS: number = 14;
/** Swift `CanvasLayout.tileSpacing = 8` between card tiles. */
const TILE_SPACING: number = 8;
/** Swift `canvasPinched`: a pinch out past 1.15 fills the tile, a pinch in under 0.87 fits it. */
const PINCH_FILL_SCALE: number = 1.15;
const PINCH_FIT_SCALE: number = 0.87;

/**
 * Swift `enum CallTileSource` (CallTilePlanner.swift:21) — the per-tile TYPE the canvas is
 * built on. `CallTileComposer.model(from:)` reads it to pick the tile's frame source and its
 * layer transform: a `.localCamera` tile is fed by `videoService.localFrames` through
 * `videoService.localLayerTransform` (the front camera's MIRROR), a `.remoteStream` tile by
 * the sink's own distributor with no transform at all. `ParticipantCanvas` then parents the
 * two kinds differently (ParticipantCanvas.swift:231).
 */
export enum CanvasTileSource {
  LOCAL_CAMERA = 'localCamera',
  REMOTE_STREAM = 'remoteStream'
}

/** Swift `struct ParticipantTileState`. */
export class ParticipantTileState {
  showsVideo: boolean = false;
  showsName: boolean = false;
  isAudioMuted: boolean = false;
  isHandRaised: boolean = false;
  isSpeaking: boolean = false;
}

/** Swift `struct CanvasTileModel` — one tile's participant, state and frame source. */
export class CanvasTileModel {
  /** Swift `participant` <- svc_calls (ConferenceParticipantInfo). */
  participant: ConferenceParticipantInfo = new ConferenceParticipantInfo();
  tileState: ParticipantTileState = new ParticipantTileState();
  /** Swift `CallTilePlan.source` — which of the two tile kinds this is. */
  kind: CanvasTileSource = CanvasTileSource.REMOTE_STREAM;
  /** Swift `participant.isLocalPreview` — the tile that floats over the others. */
  isLocalPreview: boolean = false;
  /**
   * Swift `CanvasTileModel.fixedTransform` <- `videoService.localLayerTransform.mirrored`.
   * Only a `.localCamera` tile ever carries one; a remote sink is never mirrored.
   */
  isMirrored: boolean = false;
  /** Swift `avatarProvider` <- svc_profiles. */
  avatar: string = '';
  displayName: string = '';
  /** The name the avatar's initial and colour come from: displayName without '(You)'. */
  avatarName: string = '';
  isAvatarResolved: boolean = false;
  /** Swift `participantId` — the tile key and the renderer's sink id. */
  id: string = '';
}

/** Swift `ParticipantTileUIView`. */
@Component
export struct ParticipantTileUIView {
  tile: CanvasTileModel = new CanvasTileModel();
  /** comp_renderer_layer for THIS tile (Swift `let videoView = RendererLayerView()`). */
  @BuilderParam rendererBuilder: () => void;
  /** comp_call_avatar for THIS tile (Swift `avatarView`). */
  @BuilderParam avatarBuilder: () => void;
  /** Swift `onTileLongPressed(participantId)` — the per-participant moderator menu. */
  onLongPress?: (participantId: string) => void;
  /** Swift `canvasPinched` -> `videoScalingPolicyOverrides[id]`: true = whole frame (fit). */
  onScalingChosen?: (participantId: string, wholeFrame: boolean) => void;
  /**
   * Swift `videoView.hasVideoContent`: a remote frame drawn since the sink last (re)started.
   * The avatar stays up until then, and comes back when the peer stops sending (T-1627).
   */
  @State private hasVideoContent: boolean = true;
  private unwatchContent: (() => void) | null = null;

  aboutToAppear(): void {
    if (this.tile.kind !== CanvasTileSource.REMOTE_STREAM) {
      return;
    }
    const video: VideoService = ServiceRegistry.shared().videoService;
    this.hasVideoContent = video.shownSize(this.tile.id) !== null;
    this.unwatchContent = video.shownSizeChanged.subscribe((info: VideoFrameInfo): void => {
      if (info.sinkId === this.tile.id) {
        this.hasVideoContent = info.width > 0 && info.height > 0;
      }
    });
  }

  aboutToDisappear(): void {
    if (this.unwatchContent !== null) {
      this.unwatchContent();
      this.unwatchContent = null;
    }
  }

  /** Swift `canvasPinched(_:)` `.ended`: only a tile showing video, only past a threshold. */
  private pinched(scale: number): void {
    const handler: ((participantId: string, wholeFrame: boolean) => void) | undefined = this.onScalingChosen;
    if (handler === undefined || !this.tile.tileState.showsVideo || this.tile.id.length === 0) {
      return;
    }
    if (scale > PINCH_FILL_SCALE) {
      handler(this.tile.id, false);
    } else if (scale < PINCH_FIT_SCALE) {
      handler(this.tile.id, true);
    }
  }

  private fire(handler: ((participantId: string) => void) | undefined): void {
    if (handler !== undefined) {
      handler(this.tile.id);
    }
  }

  build() {
    Stack({ alignContent: Alignment.BottomStart }) {
      // Swift `CallTileComposer.model(from:)` branches the tile's video on `plan.source`:
      // a `.localCamera` tile gets `videoService.localLayerTransform`, which mirrors the front
      // camera, and a `.remoteStream` tile gets the sink's frames untransformed. Rendering
      // both the same way showed the local camera un-mirrored — the "that is not how I move"
      // preview.
      if (this.tile.kind === CanvasTileSource.LOCAL_CAMERA) {
        Stack() {
          this.rendererBuilder()
        }
        .width('100%')
        .height('100%')
        .scale({ x: this.tile.isMirrored ? -1 : 1, y: 1 })
      } else {
        this.rendererBuilder()
      }

      // Swift `avatarView` — shown instead of video whenever the tile has none
      // (`syncAvatarVisibility`: showsVideo && hasVideoContent). Opaque: the surface under it
      // still holds the last frame, where iOS flushes its layer.
      if (!this.tile.tileState.showsVideo || !this.hasVideoContent) {
        Stack() {
          this.avatarBuilder()
        }
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.jami_call_backdrop'))
      }

      // Swift `namePlate` + `nameLabel`.
      if (this.tile.tileState.showsName) {
        // Swift `namePlate` — a `jamiOnVideoScrim` capsule 8pt from the leading edge and 6pt
        // off the bottom, holding a 13pt medium white label.
        Row({ space: NAME_V_PADDING * 2 }) {
          Text(this.tile.displayName)
            .maxLines(1)
            // Swift `nameLabel.lineBreakMode = .byTruncatingMiddle`.
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .fontSize(NAME_FONT_SIZE)
            .fontWeight(FontWeight.Medium)
            .fontColor(Color.White)
          if (this.tile.tileState.isAudioMuted) {
            SymbolGlyph($r('sys.symbol.mic_slash_fill'))
              .fontSize(NAME_GLYPH_SIZE)
              .fontColor([Color.White])
          }
          // No raised hand here: Swift `ParticipantTileUIView.apply` never draws one on a tile;
          // the roster shows it (T-1596).
        }
        .alignItems(VerticalAlign.Center)
        .padding({
          start: LengthMetrics.vp(NAME_H_PADDING),
          end: LengthMetrics.vp(NAME_H_PADDING),
          top: LengthMetrics.vp(NAME_V_PADDING),
          bottom: LengthMetrics.vp(NAME_V_PADDING)
        })
        .backgroundColor($r('app.color.jami_on_video_scrim'))
        .borderRadius(NAME_PLATE_RADIUS)
        .margin({
          start: LengthMetrics.vp(NAME_EDGE_MARGIN),
          bottom: LengthMetrics.vp(NAME_BOTTOM_MARGIN)
        })
      }
    }
    .width('100%')
    .height('100%')
    // Swift `backgroundColor = .jamiCallBackdrop`, rounded to `tileCornerRadius` on a card.
    .backgroundColor($r('app.color.jami_call_backdrop'))
    .borderRadius(TILE_RADIUS)
    .clip(true)
    // No tap of its own: a tap goes through to the canvas, which toggles the chrome (Swift
    // `canvasTapped`). A tile answers only the long press and the pinch.
    .gesture(GestureGroup(GestureMode.Exclusive,
      PinchGesture().onActionEnd((event: GestureEvent) => {
        this.pinched(event.scale);
      }),
      LongPressGesture().onAction(() => {
        this.fire(this.onLongPress);
      })))
  }
}

/** Swift `ParticipantCanvas` — the grid of tiles plus the floating local preview. */
@Component
export struct ParticipantCanvas {
  /** bindingContract[participant tiles] <- svc_calls. */
  @Prop tiles: CanvasTileModel[] = [];
  /** Swift `previewId` — the local preview, drawn over the grid rather than in it. */
  preview: CanvasTileModel | null = null;
  /** Swift `onCanvasTapped` — toggles the call chrome. */
  onCanvasTapped?: () => void;
  /** Swift `ParticipantTileUIView(...)` — one tile, composed by the screen's page. */
  @BuilderParam tileBuilder: (tile: CanvasTileModel) => void;

  private static template(count: number): string {
    return new Array<string>(count).fill('1fr').join(' ');
  }

  /** Swift `CanvasLayout.gridLayout`: one column for 1 or 2 tiles, two from 3. */
  private static columns(count: number): number {
    return count <= 2 ? 1 : 2;
  }

  /** Three tiles take two rows (one wide over two); otherwise the tiles fill the columns. */
  private static rows(count: number): number {
    return count === 3 ? 2 : Math.max(1, Math.ceil(count / ParticipantCanvas.columns(count)));
  }

  /**
   * Swift `CanvasLayout.gridLayout`'s cell for one tile: [row, first column, last column]. Three
   * tiles are one wide tile over two (a square grid left the 4th cell empty, T-1590); from five,
   * an odd last tile spans both columns (`isLastAndOdd`). Looked up by id, so a roster change
   * moves a tile without rebuilding it.
   * ponytail: from 7 tiles Swift scrolls 3 rows per screen; here the rows shrink to fit.
   */
  private cell(tile: CanvasTileModel): number[] {
    const count: number = this.tiles.length;
    const index: number = this.tiles.findIndex((other: CanvasTileModel): boolean => other.id === tile.id);
    const columns: number = ParticipantCanvas.columns(count);
    const wide: boolean = (count === 3 && index === 0) ||
      (count >= 5 && count % 2 === 1 && index === count - 1);
    const slot: number = count === 3 && index > 0 ? index + 1 : index;
    const column: number = slot % columns;
    return [Math.floor(slot / columns), column, wide ? columns - 1 : column];
  }

  build() {
    Stack({ alignContent: Alignment.TopEnd }) {
      // Swift `CanvasLayoutMode.grid` — every remote participant, equal tiles.
      Grid() {
        ForEach(this.tiles, (tile: CanvasTileModel) => {
          GridItem() {
            this.tileBuilder(tile)
          }
          .rowStart(this.cell(tile)[0])
          .rowEnd(this.cell(tile)[0])
          .columnStart(this.cell(tile)[1])
          .columnEnd(this.cell(tile)[2])
        }, (tile: CanvasTileModel) => tile.id + tile.displayName + tile.tileState.showsVideo + tile.avatar.length +
          tile.isMirrored)
      }
      .width('100%')
      .height('100%')
      // Swift `CanvasLayoutMode.grid`: 1 tile fills, 2 stack, 3 are one wide over two, then two columns.
      .columnsTemplate(ParticipantCanvas.template(ParticipantCanvas.columns(this.tiles.length)))
      .rowsTemplate(ParticipantCanvas.template(ParticipantCanvas.rows(this.tiles.length)))
      // Swift `CanvasLayout.tileSpacing` between card tiles.
      .columnsGap(TILE_SPACING)
      .rowsGap(TILE_SPACING)

      // Swift `previewFloats` — the local preview floats only when there is another tile.
      if (this.preview !== null && this.tiles.length > 0) {
        this.tileBuilder(this.preview)
      }
    }
    .width('100%')
    .height('100%')
    // Swift `ParticipantCanvas.backgroundColor = .jamiCallCanvas`.
    .backgroundColor($r('app.color.jami_call_canvas'))
    .onClick(() => {
      const handler: (() => void) | undefined = this.onCanvasTapped;
      if (handler !== undefined) {
        handler();
      }
    })
  }
}
