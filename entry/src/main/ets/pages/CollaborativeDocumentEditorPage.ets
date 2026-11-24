/*
 * screen_collab_editor — "Collaborative Document Editor", ported from
 *   Ring/Ring/Features/Collab/CollabEditorViewController.swift + CollabEditorViewModel.swift
 *   Ring/Ring/Features/Collab/CollabHistoryPanel.swift + CollabSchemeHandler.swift
 *
 * presentation: modal, hostScreen: screen_conversation. `ConversationState.openCollabDocument`
 * presents the editor's navigation controller over the conversation, so it is the @CustomDialog
 * ConversationChatPage mounts — NOT a routed page and NOT in main_pages.json.
 *
 * NO CAPTURED STATE (the gallery declared this screen uncapturable): structure from source only.
 *
 * S3 — `CollabEditorViewController`'s view tree:
 *   navigationItem  leftBarButtonItem  L10n.Global.close  "collab_editor_close"
 *                   rightBarButtonItem ellipsis.circle    "collab_editor_menu"
 *                     -> showMenu() action sheet: Rename | Version history | Export a local copy
 *                     -> showExportMenu() action sheet: PDF (print dialog), HTML, Markdown, text
 *   webView         WKWebView over the jami-collab:// scheme handler  -> ArkWeb `Web`
 *   formatBar       a horizontal scroller of the 18 `formatItems`, each
 *                   "collab_editor_format_<symbol>" (bold, italic, …, H1/H2/H3 as TITLES)
 *   versionBar      hidden until a version is being read: versionLabel | leave | restore
 *                   ("collab_editor_version_leave" / "collab_editor_version_restore")
 *   historyPanel    CollabHistoryPanel (comp_collab_history_panel), 300 pt beside the editor
 *   loadingView / errorLabel  centred over the whole view
 *
 * The version bar and the format bar occupy the SAME band (the source pins versionBar to
 * formatBar's four edges), so they are exclusive branches here, not two stacked rows.
 *
 * The page is iOS's own Ring/CollabEditor bundle (Quill + Yjs) out of rawfile/collab. It talks to
 * the application through `window.JamiBridge` (src/host.js: the Android-style interface WKWebView
 * lacks), which ArkWeb's javaScriptProxy provides as-is, and is driven through
 * `window.JamiEditor.<fn>(...)` exactly as CollabEditorViewController.callEditor does. Y-CRDT
 * updates cross as base64; the daemon holds the replica of record.
 */
import { webview } from '@kit.ArkWeb';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { fileIo, picker } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { i18n, intl } from '@kit.LocalizationKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError, print } from '@kit.BasicServicesKit';
import { ArrayDataSource } from '../common/ArrayDataSource';
import { ServiceRegistry } from '../common/ServiceRegistry';
import {
  AwarenessUpdate,
  CollaborationService,
  DocumentEvent,
  ParticipantLeft
} from '../common/CollaborationService';
import { describeError } from '../common/ErrorText';
import { ShareActions } from '../common/ShareActions';
import { CollaborativeDocument } from '../model/CollaborativeDocument';
import { CollaborativeVersion } from '../model/CollaborativeVersion';
import { CollabHistoryPanel, CollabVersionEntry } from '../components/CollabHistoryPanel';
import { CollabNamePrompt } from '../components/CollabNamePrompt';
import { LengthMetrics, window } from '@kit.ArkUI';

/* ── S5 metrics, the source's own (CollabEditorViewController.swift:494-501) ─────── */
/** Swift `private static let barHeight: CGFloat = 48`. */
const BAR_HEIGHT: number = 48;
/** Swift `touchTarget = 44`, `buttonSpacing = 4`, `margin = 8`. */
const TOUCH_TARGET: number = 44;
const BUTTON_SPACING: number = 4;
/**
 * Swift `setUpNavigationBar()` sets no tint on Close or the ellipsis, so they take the iOS
 * default (systemBlue): the iPhone 4.20 draws both #007AFF, not the Jami navy.
 */
const IOS_TINT_BLUE: string = '#007AFF';
/** UIFont.TextStyle.footnote: 13 pt. */
const FOOTNOTE_SIZE: number = 13;
const BAR_MARGIN: number = 8;
/** Swift `panelWidth = 300` — the history panel beside the editor. */
const HISTORY_PANEL_WIDTH: number = 300;
/** Swift `inactiveAlpha = 0.55`. */
const INACTIVE_ALPHA: number = 0.55;
/** The format-bar glyph size inside its 44pt tap target. */
const FORMAT_GLYPH_SIZE: number = 20;
/** UIButton(type: .system)'s selected look: the tint fills a rounded square behind the glyph. */
const SELECTED_SIZE: number = 32;
const SELECTED_RADIUS: number = 6;

/** Swift `enum CollabFormat` / `FormatItem` — the formatting bar's 18 entries. */
export class CollabFormatItem {
  /** Swift `item.format` — also the id suffix: "collab_editor_format_<symbol>". */
  format: string;
  /** Swift `item.symbol` — null on the heading items, which carry a TITLE instead. */
  icon: Resource | null;
  /** Swift `item.title` — "H1", "H2", "H3". */
  title: string;
  /** Swift `item.label` — the accessibility label. */
  label: Resource;

  constructor(format: string, icon: Resource | null, title: string, label: Resource) {
    this.format = format;
    this.icon = icon;
    this.title = title;
    this.label = label;
  }
}

/**
 * Swift `CollabEditorViewController.formatItems` (line 517), in order. SF Symbols resolved
 * through results/plan/icon-map.json; `text.justify` has no SDK equivalent, so the justify
 * item takes `sys.symbol.line_3_horizontal` (three full-width rules — the closest glyph in the
 * SDK's symbol table, which carries no justify entry), and undo/redo take the SDK's own
 * `undo`/`redo`.
 */
const FORMAT_ITEMS: CollabFormatItem[] = [
  new CollabFormatItem('bold', $r('sys.symbol.bold'), '', $r('app.string.collab_bold')),
  new CollabFormatItem('italic', $r('sys.symbol.italic'), '', $r('app.string.collab_italic')),
  new CollabFormatItem('underline', $r('sys.symbol.underline'), '',
    $r('app.string.collab_underline')),
  new CollabFormatItem('strike', $r('sys.symbol.strikethrough'), '',
    $r('app.string.collab_strikethrough')),
  new CollabFormatItem('header1', null, 'H1', $r('app.string.collab_heading')),
  new CollabFormatItem('header2', null, 'H2', $r('app.string.collab_heading')),
  new CollabFormatItem('header3', null, 'H3', $r('app.string.collab_heading')),
  new CollabFormatItem('listBullet', $r('sys.symbol.list_bullet'), '',
    $r('app.string.collab_bullet_list')),
  new CollabFormatItem('listOrdered', $r('sys.symbol.list_number'), '',
    $r('app.string.collab_ordered_list')),
  new CollabFormatItem('alignLeft', $r('sys.symbol.text_alignleft'), '',
    $r('app.string.collab_align_left')),
  new CollabFormatItem('alignCenter', $r('sys.symbol.text_aligncenter'), '',
    $r('app.string.collab_align_center')),
  new CollabFormatItem('alignRight', $r('sys.symbol.text_alignright'), '',
    $r('app.string.collab_align_right')),
  new CollabFormatItem('alignJustify', $r('sys.symbol.line_3_horizontal'), '',
    $r('app.string.collab_align_justify')),
  new CollabFormatItem('link', $r('sys.symbol.link'), '', $r('app.string.collab_link_title')),
  new CollabFormatItem('image', $r('sys.symbol.ohos_photo'), '',
    $r('app.string.collab_insert_image')),
  new CollabFormatItem('clear', $r('sys.symbol.textformat'), '',
    $r('app.string.collab_clear_format')),
  new CollabFormatItem('undo', $r('sys.symbol.undo'), '', $r('app.string.collab_undo')),
  new CollabFormatItem('redo', $r('sys.symbol.redo'), '', $r('app.string.collab_redo'))
];

const LOG_DOMAIN: number = 0x0001;
const LOG_TAG: string = 'CollabEditor';

/**
 * AppStorage keys the host writes before it opens the editor: a @CustomDialog's builder
 * arguments are fixed when the host BUILDS its controller (the screen_media_record pattern).
 */
export const COLLAB_EDITOR_ACCOUNT_KEY: string = 'collabEditorAccountId';
export const COLLAB_EDITOR_CONVERSATION_KEY: string = 'collabEditorConversationId';
export const COLLAB_EDITOR_DOCUMENT_KEY: string = 'collabEditorDocumentId';

/** Swift `apply(_ format:)` — the port's format ids as `window.JamiEditor` calls. */
const FORMAT_CALLS: Record<string, string> = {
  'bold': 'toggle("bold")', 'italic': 'toggle("italic")', 'underline': 'toggle("underline")',
  'strike': 'toggle("strike")', 'header1': 'setHeader(1)', 'header2': 'setHeader(2)',
  'header3': 'setHeader(3)', 'listBullet': 'setList("bullet")', 'listOrdered': 'setList("ordered")',
  'alignLeft': 'setAlign("left")', 'alignCenter': 'setAlign("center")',
  'alignRight': 'setAlign("right")', 'alignJustify': 'setAlign("justify")',
  'clear': 'clearFormat()', 'undo': 'undo()', 'redo': 'redo()'
};

/** Which iOS action sheet is over the editor: none, Swift `showMenu()` or `showExportMenu()`. */
const SHEET_NONE: number = 0;
const SHEET_MENU: number = 1;
const SHEET_EXPORT: number = 2;
/** UIKit's action sheet: an 8 pt inset, 57 pt rows, the home-indicator clearance, the dim. */
const SHEET_INSET: number = 8;
const SHEET_ROW_HEIGHT: number = 57;
const SHEET_BOTTOM_INSET: number = 34;
const SHEET_SCRIM: string = '#33000000';
/** Swift `CustomAlert`'s scrim and inset, behind the rename prompt. */
const PROMPT_SCRIM: string = '#80000000';
const PROMPT_INSET: number = 16;
/**
 * Where the page asks for a picture: editor.js names it `new URL('/attachment/', page)` + the
 * encoded id, which under ArkWeb's rawfile origin is a resource: URL (CollabSchemeHandler
 * `attachmentPath`). The CSP lets the page load images from resource: and data: alone.
 */
const ATTACHMENT_SCHEME: string = 'resource:';
const ATTACHMENT_PATH: string = '/attachment/';
/** Swift `CollabEditorViewModel.cursorColors` — a peer's caret colour, by order of arrival. */
const CURSOR_COLORS: string[] = [
  '#E53935', '#1E88E5', '#43A047', '#FB8C00', '#8E24AA', '#00ACC1', '#F4511E'
];
/** Swift `CollabEditorViewModel.shortId` — what a caret wears until a name is known. */
const SHORT_ID_LENGTH: number = 8;
/** Swift `CollabEditorViewModel.maxAttachmentBytes` — the daemon's own ceiling. */
const MAX_ATTACHMENT_BYTES: number = 16 * 1024 * 1024;

/**
 * A string a page script returned. ArkWeb on OS 7 hands it back JSON-quoted ('"true"'), older
 * builds bare; both come out as the bare string.
 */
function scriptString(result: webview.JsMessageExt): string {
  const raw: string = result.getString();
  return raw.startsWith('"') ? JSON.parse(raw) as string : raw;
}

/** One row of an action sheet: its title and what it does. */
class SheetAction {
  label: Resource;
  action: () => void;

  constructor(label: Resource, action: () => void) {
    this.label = label;
    this.action = action;
  }
}

/** Swift `struct ExportFormat` — a format the page writes, and the file it is written to. */
class ExportFormat {
  /** The name `window.JamiEditor.exportAs` takes. */
  name: string;
  fileExtension: string;
  label: Resource;

  constructor(name: string, fileExtension: string, label: Resource) {
    this.name = name;
    this.fileExtension = fileExtension;
    this.label = label;
  }
}

/** Swift `CollabEditorViewController.exportFormats`, in order. */
const EXPORT_FORMATS: ExportFormat[] = [
  new ExportFormat('html', 'html', $r('app.string.collab_export_html')),
  new ExportFormat('md', 'md', $r('app.string.collab_export_markdown')),
  new ExportFormat('txt', 'txt', $r('app.string.collab_export_text'))
];

/**
 * Swift `struct WrittenDocument` — what `exportAs` answers: the text, the attachment ids it left
 * to be put in, and the scheme it named them under this time.
 */
interface WrittenDocument {
  text: string;
  attachments: string[];
  scheme: string;
}

/** Swift `CollabSchemeHandler.mimeType(of:)` — a picture's kind from its first bytes. */
function pictureType(data: Uint8Array): string {
  if (data.length > 3 && data[0] === 0xFF && data[1] === 0xD8) {
    return 'image/jpeg';
  }
  if (data.length > 8 && data[0] === 0x89 && data[1] === 0x50) {
    return 'image/png';
  }
  if (data.length >= 12 && data[0] === 0x52 && data[8] === 0x57) {
    return 'image/webp';
  }
  if (data.length > 6 && data[0] === 0x47 && data[1] === 0x49) {
    return 'image/gif';
  }
  return 'application/octet-stream';
}

/**
 * Swift `CollabEditorViewModel.embed(_:in:under:)`: each picture's bytes, as a data URI, in place
 * of the name the page wrote it under (`scheme` + encodeURIComponent(id)), in one pass. The
 * names are matched longest first, one id being able to open another; a name with no bytes
 * keeps its address.
 */
export function embedPictures(bytes: Map<string, Uint8Array>, text: string,
  scheme: string): string {
  const base64: util.Base64Helper = new util.Base64Helper();
  const pictures: Map<string, string> = new Map<string, string>();
  const names: string[] = [];
  bytes.forEach((data: Uint8Array, attachmentId: string): void => {
    const name: string = encodeURIComponent(attachmentId);
    names.push(name);
    if (data.length > 0) {
      pictures.set(name, `data:${pictureType(data)};base64,${base64.encodeToStringSync(data)}`);
    }
  });
  const parts: string[] = text.split(scheme);
  if (parts.length < 2 || names.length === 0) {
    return text;
  }
  names.sort((a: string, b: string): number => b.length - a.length);
  let written: string = parts[0];
  for (let index: number = 1; index < parts.length; index++) {
    const part: string = parts[index];
    const name: string | undefined = names.find((candidate: string) => part.startsWith(candidate));
    const picture: string | undefined = name === undefined ? undefined : pictures.get(name);
    if (name === undefined || picture === undefined) {
      written += scheme + part;
      continue;
    }
    written += picture + part.substring(name.length);
  }
  return written;
}

/** Swift `exportFileName`'s forbidden set: / \\ : * ? " < > | and the control characters. */
const FILE_NAME_FORBIDDEN: string = '[/\\\\:*?"<>|\\u0000-\\u001F\\u007F]';

/** Swift `exportFileName(_:)` — the document's name, made into something a file system takes. */
function exportFileName(name: string, fileExtension: string, untitled: string): string {
  let base: string = name.replace(new RegExp(FILE_NAME_FORBIDDEN, 'g'), ' ').trim();
  if (base.length === 0) {
    base = untitled;
  }
  return `${base.substring(0, 80).trim()}.${fileExtension}`;
}

/** setLink: time for the page to take the focus back after the link card closes. */
const LINK_REFOCUS_DELAY_MS: number = 150;
/** setLink: time for Quill's selectionchange handler (a 1 ms timer) to see the restored range. */
const LINK_SELECTION_SETTLE_MS: number = 30;

/** Swift `showFormats(_:)` reads `formats` out of the page's `onSelection` report. */
interface SelectionFormats {
  bold: boolean;
  italic: boolean;
  underline: boolean;
  strike: boolean;
  link: string;
  header: number;
  list: string;
  align: string;
}

interface SelectionReport {
  formats: SelectionFormats;
}

/** The link prompt's buttons: UIKit's alert text size and row height. */
const PROMPT_BUTTON_HEIGHT: number = 44;
/** UIKit's destructive red, for the link prompt's Remove. */
const DESTRUCTIVE_RED: string = '#FF3B30';

/**
 * The page's `window.JamiBridge` (CollabEditor src/host.js) — what the editor may tell the
 * application. Arrow fields, so a call from the page needs no `this` binding.
 */
class EditorBridge {
  onReady: () => void;
  onUpdate: (base64: string) => void;
  onAwareness: (state: string) => void;
  onSelection: (json: string) => void;
  onLinkRequested: () => void = (): void => {};
  onImageRequested: () => void = (): void => {};
  onLog: (message: string) => void = (message: string): void => {
    hilog.debug(LOG_DOMAIN, LOG_TAG, 'page: %{public}s', message);
  };

  constructor(onReady: () => void, onUpdate: (base64: string) => void,
    onAwareness: (state: string) => void, onSelection: (json: string) => void) {
    this.onSelection = onSelection;
    this.onReady = onReady;
    this.onUpdate = onUpdate;
    this.onAwareness = onAwareness;
  }
}

@CustomDialog
export struct CollaborativeDocumentEditorOverlay {
  /** Injected by the host's CustomDialogController. */
  controller?: CustomDialogController;

  /** Owned by screen_conversation; the host's @State drives this overlay. */
  @Link isPresented: boolean;
  /** Swift `viewModel.accountId` / `conversationId` / `documentId`, handed in by the host. */
  accountId: string = '';
  conversationId: string = '';
  documentId: string = '';

  /** The mounted editor's `closeTopLayer`, for a host's Back (T-1602). */
  private static layerCloser: (() => boolean) | null = null;

  /**
   * A host's `onWillDismiss` on Back: closes only what is over the editor (the rename or link
   * prompt, the action sheet, else the keyboard) and returns true, so the editor stays. These
   * are drawn inside the dialog and the Web is not a text field, so ArkUI's own "Back closes the
   * keyboard first" never applied and the first Back closed the whole editor. False: none open.
   */
  static closeOpenLayer(): boolean {
    const closer: (() => boolean) | null = CollaborativeDocumentEditorOverlay.layerCloser;
    return closer !== null && closer();
  }

  /** Swift `viewModel.documentName` — the navigation title. */
  @State private documentName: string = '';
  /** The editor page; its content is the Y-CRDT replica the page holds. */
  private webController: webview.WebviewController = new webview.WebviewController();
  private bridge: EditorBridge = new EditorBridge(
    (): void => {
      this.openDocument();
    },
    (base64: string): void => {
      this.localUpdate(base64);
    },
    (state: string): void => {
      this.reportAwareness(state);
    },
    (json: string): void => {
      this.showFormats(json);
    });
  /** Swift `viewModel.opened`. */
  private opened: boolean = false;
  /** Swift `pendingLocalUpdates` — what the page reported before the document was read. */
  private pendingLocalUpdates: string[] = [];
  /** The daemon subscriptions (remote updates, removals), released with the editor. */
  private stopListening: (() => void)[] = [];
  /** bindingContract[history rows] <- svc_collaboration (CollaborativeVersion list). */
  @State historyRows: ArrayDataSource<CollabVersionEntry> =
    new ArrayDataSource<CollabVersionEntry>([]);
  /** Swift `shownCommitId` — the version being read; empty means the document itself. */
  @State private shownCommitId: string = '';
  /** Swift `versionLabel.text`. */
  @State private versionLabel: string = '';
  /** conditionalVariants[history_open]: the version history panel is shown. */
  @State isHistoryOpen: boolean = false;
  /** conditionalVariants[rich_text]: `document.isRichText` — the format bar's own condition. */
  @State isRichText: boolean = true;
  /** conditionalVariants[read_only]: the document cannot be edited. */
  @State isReadOnly: boolean = false;
  /** Swift `loadingView.startAnimating()` / `errorLabel`. */
  @State isLoading: boolean = true;
  @State errorText: string = '';
  /** The window's status-bar height: the dialog covers the whole window, the bar sits below it. */
  @State private topInset: number = 0;
  /**
   * The navigation indicator's height, kept clear under the format bar while no keyboard is up
   * (iPhone 4.20: the bar sits above the home indicator, on the keyboard when one is shown).
   */
  private navigationInset: number = 0;
  @State private bottomInset: number = 0;
  /** The action sheet over the editor (SHEET_*). */
  @State private sheet: number = SHEET_NONE;
  /** The soft keyboard is up (keyboardHeightChange). */
  private keyboardUp: boolean = false;
  /** The keyboard was up when the menu took the focus; Cancel gives it back (UIKit does). */
  private refocusOnCancel: boolean = false;
  /** Swift `viewModel.present` — "peerId/clientId" of every caret shown, one per device. */
  private present: Set<string> = new Set<string>();
  /** Swift `viewModel.peers` — each peer's caret colour, kept once given. */
  private peerColors: Map<string, string> = new Map<string, string>();
  /** Swift `viewModel.otherParticipants` — the people (not devices) editing besides this one. */
  @State private otherParticipants: number = 0;
  /** Swift `promptRename()` — the rename alert is up, and its field. */
  @State private isRenaming: boolean = false;
  /** Swift `currentLink` — the link under the caret, from the page's selection report. */
  private currentLink: string = '';
  /** Swift `promptLink()` — the link alert is up, its field, and whether Remove is offered. */
  @State private isLinking: boolean = false;
  @State private pendingLink: string = '';
  @State private canRemoveLink: boolean = false;
  @State private pendingName: string = '';
  /** Swift `showFormats(_:)`'s `active(_:)` — the items describing the text under the caret. */
  @State private activeFormats: string[] = [];

  /** The name and the history; the document itself opens once the page says it is ready. */
  aboutToAppear(): void {
    CollaborativeDocumentEditorOverlay.layerCloser = this.closeTopLayer;
    window.getLastWindow(getContext(this)).then((win: window.Window): void => {
      this.topInset = px2vp(win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM).topRect.height);
      this.navigationInset = px2vp(win.getWindowAvoidArea(
        window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR).bottomRect.height);
      this.bottomInset = this.navigationInset;
      // The dialog itself avoids the keyboard; the indicator inset only applies without one.
      const onKeyboard = (height: number): void => {
        this.bottomInset = height > 0 ? 0 : this.navigationInset;
        this.keyboardUp = height > 0;
      };
      win.on('keyboardHeightChange', onKeyboard);
      this.stopListening.push((): void => {
        win.off('keyboardHeightChange', onKeyboard);
      });
    }).catch((error: BusinessError): void => {
      hilog.warn(0x0001, 'CollabEditor', `avoid area unavailable: ${error.code}`);
    });
    if (this.documentId.length === 0) {
      this.accountId = AppStorage.get<string>(COLLAB_EDITOR_ACCOUNT_KEY) ?? '';
      this.conversationId = AppStorage.get<string>(COLLAB_EDITOR_CONVERSATION_KEY) ?? '';
      this.documentId = AppStorage.get<string>(COLLAB_EDITOR_DOCUMENT_KEY) ?? '';
    }
    this.isLoading = true;
    const collaboration: CollaborationService = ServiceRegistry.shared().collaborationService;
    collaboration.name(this.accountId, this.conversationId, this.documentId)
      .then((name: string): Promise<CollaborativeDocument[]> | undefined => {
        if (name.length > 0) {
          this.documentName = name;
          return undefined;
        }
        // A document removed from this device has no name here (device: 'Download and open'
        // showed a blank bar); the conversation's document list still carries it.
        return collaboration.documents(this.accountId, this.conversationId);
      })
      .then((documents: CollaborativeDocument[] | undefined): void => {
        const listed: CollaborativeDocument | undefined =
          documents?.find((document: CollaborativeDocument) => document.id === this.documentId);
        if (listed !== undefined) {
          this.documentName = listed.name;
        }
      })
      .catch((error: Object): void => {
        this.reportFailure(error);
      });
  }

  aboutToDisappear(): void {
    if (CollaborativeDocumentEditorOverlay.layerCloser === this.closeTopLayer) {
      CollaborativeDocumentEditorOverlay.layerCloser = null;
    }
    this.stopListening.forEach((stop: () => void): void => {
      stop();
    });
    this.stopListening = [];
    ServiceRegistry.shared().collaborationService
      .closeDocument(this.accountId, this.conversationId, this.documentId)
      .catch((error: Object): void => {
        hilog.debug(LOG_DOMAIN, LOG_TAG, 'closeDocument: %{public}s',
          describeError(error as BusinessError));
      });
  }

  /**
   * Swift `openDocument()` on the page's onReady: seed the page with the whole document, send
   * what it did while waiting, then follow the others' edits (`listen()`).
   */
  private openDocument(): void {
    const collaboration: CollaborationService = ServiceRegistry.shared().collaborationService;
    collaboration.openDocument(this.accountId, this.conversationId, this.documentId)
      .then((state: Uint8Array): void => {
        this.isLoading = false;
        if (state.length === 0) {
          // Swift `showOpenFailure()`.
          this.errorText = getContext(this).resourceManager.getStringByNameSync('collab_open_error');
          this.isReadOnly = true;
          return;
        }
        this.opened = true;
        this.callEditor('applyUpdate', state);
        this.pendingLocalUpdates.forEach((update: string): void => {
          this.localUpdate(update);
        });
        this.pendingLocalUpdates = [];
        this.stopListening.push(
          collaboration.updates(this.accountId, this.conversationId, this.documentId,
            (update: Uint8Array): void => {
              this.callEditor('applyUpdate', update);
            }),
          // Swift `viewModel.renames`: a rename made by another member retitles the editor
          // (T-1603); the daemon announces a local one too.
          collaboration.documentsRenamed.subscribe((event: DocumentEvent): void => {
            if (event.accountId === this.accountId && event.conversationId === this.conversationId
              && event.documentId === this.documentId) {
              this.documentName = event.value;
            }
          }),
          // Swift `viewModel.removals` -> `documentRemoved(everywhere:)`.
          collaboration.removals(this.accountId, this.conversationId, this.documentId,
            (everywhere: boolean): void => {
              this.documentRemoved(everywhere);
            }),
          // Swift `viewModel.attachments` -> `attachmentArrived`: a picture the page asked for
          // before it reached this device is asked for again.
          collaboration.attachments(this.accountId, this.conversationId, this.documentId,
            (attachmentId: string): void => {
              this.runEditor(`attachmentArrived(${JSON.stringify(attachmentId)})`);
            }),
          // Swift `viewModel.awareness` / `departures` — who else has the document open.
          collaboration.awareness(this.accountId, this.conversationId, this.documentId,
            (update: AwarenessUpdate): void => {
              this.present.add(`${update.peerId}/${update.clientId}`);
              this.publishParticipants();
              this.drawCaret(update);
            }),
          collaboration.departures(this.accountId, this.conversationId, this.documentId,
            (left: ParticipantLeft): void => {
              this.present.delete(`${left.peerId}/${left.clientId}`);
              this.publishParticipants();
              // Swift `callEditor("removeCursor", peerId, clientId)`.
              this.runEditor(`removeCursor(${JSON.stringify(left.peerId)},${left.clientId})`);
            }));
      })
      .catch((error: Object): void => {
        this.reportFailure(error);
      });
  }

  /**
   * Swift `listen()`'s awareness half: `applyAwareness(peerId, clientId, state, name, color)`,
   * which the page draws as the peer's caret and selection. Swift `peer(for:)` names it: a
   * colour by order of arrival, kept; the profile's alias once it has loaded, a fragment of
   * the id until then — carets move constantly, so the next event carries the corrected label.
   */
  private drawCaret(update: AwarenessUpdate): void {
    let color: string | undefined = this.peerColors.get(update.peerId);
    if (color === undefined) {
      color = CURSOR_COLORS[this.peerColors.size % CURSOR_COLORS.length];
      this.peerColors.set(update.peerId, color);
    }
    const alias: string | null = ServiceRegistry.shared().profileService
      .getProfile(update.peerId, this.accountId).value.alias;
    const name: string = alias !== null && alias.length > 0 ? alias
      : update.peerId.substring(0, SHORT_ID_LENGTH);
    this.runEditor(`applyAwareness(${JSON.stringify(update.peerId)},${update.clientId},`
      + `${JSON.stringify(update.state)},${JSON.stringify(name)},${JSON.stringify(color)})`);
  }

  /** Swift `publishParticipants()` — one person editing from two devices is one person. */
  private publishParticipants(): void {
    const others: Set<string> = new Set<string>();
    this.present.forEach((caret: string): void => {
      others.add(caret.split('/')[0]);
    });
    this.otherParticipants = others.size;
  }

  /** Swift `viewModel.participantsDescription` — the navigation prompt. */
  private participantsDescription(): string {
    const manager = getContext(this).resourceManager;
    if (this.otherParticipants === 0) {
      return manager.getStringByNameSync('collab_editing_alone');
    }
    return this.otherParticipants === 1 ? manager.getStringByNameSync('collab_editing_one_other')
      : manager.getStringByNameSync('collab_editing_others', this.otherParticipants);
  }

  /** Swift `case "onUpdate"` — a local edit, held until the document has been read. */
  private localUpdate(base64: string): void {
    if (!this.opened) {
      hilog.info(LOG_DOMAIN, LOG_TAG, 'onUpdate held until the document is open');
      this.pendingLocalUpdates.push(base64);
      return;
    }
    ServiceRegistry.shared().collaborationService
      .applyUpdate(this.accountId, this.conversationId, this.documentId,
        new util.Base64Helper().decodeSync(base64))
      .catch((error: Object): void => {
        this.reportFailure(error);
      });
  }

  /** Swift `case "onAwareness"` -> `viewModel.report(awareness:)`. */
  private reportAwareness(state: string): void {
    // Swift `guard self.opened`: no caret is published for a document not yet read.
    if (!this.opened) {
      return;
    }
    ServiceRegistry.shared().collaborationService
      .setAwareness(this.accountId, this.conversationId, this.documentId, state)
      .catch((error: Object): void => {
        this.reportFailure(error);
      });
  }

  /** Swift `callEditor(_:_:)` — `window.JamiEditor.<fn>("<base64>")`, or no argument. */
  private callEditor(fn: string, state?: Uint8Array): void {
    const arg: string = state === undefined
      ? '' : JSON.stringify(new util.Base64Helper().encodeToStringSync(state));
    this.runEditor(`${fn}(${arg})`);
  }

  private runEditor(call: string): void {
    this.runScript(`window.JamiEditor.${call}`);
  }

  /** Swift `history(...)` -> the panel's rows (bindingContract[history rows]), and how many. */
  private loadHistory(): Promise<number> {
    return ServiceRegistry.shared().collaborationService
      .history(this.accountId, this.conversationId, this.documentId)
      .then((versions: CollaborativeVersion[]): number => {
        const rows: CollabVersionEntry[] = [];
        for (const version of versions) {
          rows.push(new CollabVersionEntry(version, this.versionEntryLabel(version)));
        }
        this.historyRows.reload(rows);
        return rows.length;
      });
  }

  /** Swift `describe(_:)`: a medium date and a short time, in the device's locale. */
  private describeVersion(version: CollaborativeVersion): string {
    return new intl.DateTimeFormat(i18n.System.getSystemLocale(),
      { dateStyle: 'medium', timeStyle: 'short' }).format(new Date(version.timestamp * 1000));
  }

  /**
   * Swift `label(for:names:)`: "Me" for this account, else the author's profile name or the
   * first 8 characters of the id (`names(for:)`), then the time and, when the checkpoint
   * carries any, the number of changes (L10n.Collab.versionDeltas / versionBy).
   */
  private versionEntryLabel(version: CollaborativeVersion): string {
    const time: string = this.describeVersion(version);
    if (version.author.length === 0) {
      return time;
    }
    const registry: ServiceRegistry = ServiceRegistry.shared();
    const resources = getContext(this).resourceManager;
    let who: string;
    if (version.author === registry.accountService.getAccount(this.accountId)?.jamiId) {
      who = resources.getStringByNameSync('account_me');
    } else {
      const alias: string | null =
        registry.profileService.getProfile(version.author, this.accountId).value.alias;
      who = alias !== null && alias.length > 0 ? alias
        : version.author.substring(0, SHORT_ID_LENGTH);
    }
    return version.deltas > 0
      ? resources.getStringByNameSync('collab_version_deltas', who, time, version.deltas)
      : resources.getStringByNameSync('collab_version_by', who, time);
  }

  /** A failure is shown rather than swallowed. */
  private reportFailure(error: Object): void {
    this.isLoading = false;
    this.errorText = describeError(error as BusinessError);
    hilog.error(LOG_DOMAIN, LOG_TAG, 'collab editor failed: %{public}s', this.errorText);
  }

  /** Swift `closeEditor()` — dismisses the editor navigation controller. */
  private dismiss(): void {
    this.isPresented = false;
    const dialog: CustomDialogController | undefined = this.controller;
    if (dialog !== undefined) {
      dialog.close();
    }
  }

  /**
   * Swift `showHistory()` — a second tap puts the list away, as it opened it. Otherwise the
   * versions are read afresh, and a document with none says so (`L10n.Collab.noHistory`)
   * instead of opening an empty panel.
   */
  private toggleHistory(): void {
    if (this.isHistoryOpen) {
      this.isHistoryOpen = false;
      return;
    }
    this.loadHistory()
      .then((count: number): void => {
        if (count === 0) {
          this.showMessage('collab_no_history');
          return;
        }
        this.isHistoryOpen = true;
      })
      .catch((error: Object): void => {
        this.reportFailure(error);
      });
  }

  /** Swift `viewModel.title` — an unnamed document is "Untitled document". */
  private title(): string {
    return this.documentName.length > 0 ? this.documentName
      : getContext(this).resourceManager.getStringByNameSync('collab_untitled');
  }

  /**
   * Swift `documentRemoved(everywhere:)` — says what happened, then closes: closing on its own
   * would make the screen vanish mid-sentence, staying would leave the user typing into
   * something no longer backed by anything.
   */
  private documentRemoved(everywhere: boolean): void {
    this.getUIContext().showAlertDialog({
      title: everywhere ? $r('app.string.collab_document_removed')
        : $r('app.string.collab_document_removed_locally'),
      message: getContext(this).resourceManager.getStringByNameSync(everywhere
        ? 'collab_document_removed_message' : 'collab_document_removed_locally_message',
        this.title()),
      alignment: DialogAlignment.Center,
      autoCancel: false,
      // Back dismisses the alert too; either way the editor closes.
      cancel: (): void => {
        this.dismiss();
      },
      confirm: {
        value: $r('app.string.global_ok'),
        action: (): void => {
          this.dismiss();
        }
      }
    });
  }

  /** Swift `showMessage(_:)` — a message alert with OK. */
  private showMessage(resourceName: string): void {
    this.getUIContext().showAlertDialog({
      message: getContext(this).resourceManager.getStringByNameSync(resourceName),
      alignment: DialogAlignment.Center,
      autoCancel: true,
      confirm: {
        value: $r('app.string.global_ok'),
        action: (): void => {}
      }
    });
  }

  /**
   * Swift `showMenu()`: Rename, Version history, and Export a local copy unless a version is
   * being read — "an export during a preview would write the version, not the document".
   */
  private menuActions(): SheetAction[] {
    const actions: SheetAction[] = [
      new SheetAction($r('app.string.collab_rename'), (): void => {
        this.promptRename();
      }),
      new SheetAction($r('app.string.collab_history'), (): void => {
        this.toggleHistory();
      })
    ];
    if (this.shownCommitId.length === 0) {
      actions.push(new SheetAction($r('app.string.collab_export'),
        (): void => {
          this.sheet = SHEET_EXPORT;
        }));
    }
    return actions;
  }

  /** Swift `showExportMenu()` — PDF through the print dialog, then what the page writes. */
  private exportActions(): SheetAction[] {
    const actions: SheetAction[] = [
      new SheetAction($r('app.string.collab_export_pdf'), (): void => {
        this.exportToPdf();
      })
    ];
    EXPORT_FORMATS.forEach((format: ExportFormat): void => {
      actions.push(new SheetAction(format.label, (): void => {
        this.export(format, []);
      }));
    });
    return actions;
  }

  /**
   * Swift `exportToPdf()`: UIPrintInteractionController over the web view's own print formatter,
   * named after the document. The page renders itself, pictures and all; ArkWeb's print adapter
   * is the same thing for the system print dialog. Needs ohos.permission.PRINT (module.json5).
   */
  private exportToPdf(): void {
    try {
      print.print(this.title(), this.webController.createWebPrintDocumentAdapter(this.title()), {},
        getContext(this))
        .catch((error: BusinessError): void => {
          this.exportFailed(error);
        });
    } catch (error) {
      this.exportFailed(error as BusinessError);
    }
  }

  /** Swift `promptRename()` — the name alert, filled with the current name. */
  private promptRename(): void {
    this.pendingName = this.documentName;
    this.isRenaming = true;
  }

  /** Swift the rename alert's OK: an empty name changes nothing; a refusal is `openError`. */
  private rename(): void {
    this.isRenaming = false;
    const name: string = this.pendingName.trim();
    if (name.length === 0) {
      return;
    }
    ServiceRegistry.shared().collaborationService
      .setName(this.accountId, this.conversationId, this.documentId, name)
      .then((): void => {
        this.documentName = name;
      })
      .catch((): void => {
        this.showMessage('collab_open_error');
      });
  }

  /**
   * Swift `export(_:without:)`: the page writes the document out, leaving out the pictures in
   * `without`, and names the ones still to be put in.
   */
  private export(format: ExportFormat, without: string[]): void {
    const call: string = `JSON.stringify(window.JamiEditor.exportAs(${JSON.stringify(format.name)},`
      + `${JSON.stringify(this.title())},${JSON.stringify(without)}))`;
    this.webController.runJavaScriptExt(call)
      .then((result: webview.JsMessageExt): Promise<void> =>
        this.fillAndShare(format, without, JSON.parse(scriptString(result)) as WrittenDocument))
      .catch((error: BusinessError): void => {
        this.exportFailed(error);
      });
  }

  /**
   * Swift `export`'s second half: the bytes of every picture the page named. One that has not
   * reached this device is asked about, and the document is written again without it,
   * together with the ones already left out.
   */
  private async fillAndShare(format: ExportFormat, without: string[],
    written: WrittenDocument): Promise<void> {
    const collaboration: CollaborationService = ServiceRegistry.shared().collaborationService;
    const bytes: Map<string, Uint8Array> = new Map<string, Uint8Array>();
    for (const attachmentId of written.attachments) {
      bytes.set(attachmentId, await collaboration.attachment(this.accountId, this.conversationId,
        this.documentId, attachmentId));
    }
    const absent: string[] = written.attachments.filter((attachmentId: string): boolean =>
      (bytes.get(attachmentId) ?? new Uint8Array(0)).length === 0);
    if (absent.length > 0) {
      this.confirmMissingPictures(absent.length,
        (): void => {
          this.export(format, without.concat(absent));
        });
      return;
    }
    await this.share(embedPictures(bytes, written.text, written.scheme), format);
  }

  /** Swift `confirmMissingPictures(_:then:)` — Cancel, or Export anyway without them. */
  private confirmMissingPictures(count: number, then: () => void): void {
    this.getUIContext().showAlertDialog({
      title: $r('app.string.collab_export'),
      message: getContext(this).resourceManager
        .getStringByNameSync('collab_export_missing_images', count),
      alignment: DialogAlignment.Center,
      autoCancel: true,
      primaryButton: {
        value: $r('app.string.global_cancel'),
        action: (): void => {}
      },
      secondaryButton: {
        value: $r('app.string.collab_export_anyway'),
        action: then
      }
    });
  }

  /**
   * Swift `share(_:as:)` — `exportFile` then the share sheet: the text in a file of its own,
   * handed over rather than saved. One directory, emptied by the next export.
   */
  private async share(text: string, format: ExportFormat): Promise<void> {
    const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    const directory: string = `${context.cacheDir}/collab-export`;
    if (fileIo.accessSync(directory)) {
      fileIo.rmdirSync(directory);
    }
    fileIo.mkdirSync(directory);
    const path: string = `${directory}/${exportFileName(this.documentName, format.fileExtension,
      context.resourceManager.getStringByNameSync('collab_untitled'))}`;
    const file: fileIo.File =
      fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY);
    try {
      fileIo.writeSync(file.fd, text);
    } finally {
      fileIo.closeSync(file);
    }
    await ShareActions.shareFile(context, path);
  }

  /** Swift `showMessage(L10n.Collab.exportError)`, with the cause in the log. */
  private exportFailed(error: BusinessError): void {
    hilog.error(LOG_DOMAIN, LOG_TAG, 'export failed: %{public}s', describeError(error));
    this.showMessage('collab_export_error');
  }

  /**
   * UIAlertController(.actionSheet): the actions on one card, Cancel bold on its own. A tap on
   * the dimmed editor is Cancel, as on iPhone.
   */
  @Builder
  private actionSheet(actions: SheetAction[]) {
    Stack({ alignContent: Alignment.Bottom }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(SHEET_SCRIM)
        .onClick(() => {
          this.cancelSheet();
        })

      Column({ space: SHEET_INSET }) {
        Column() {
          ForEach(actions, (item: SheetAction, index: number) => {
            if (index > 0) {
              Divider()
                .color($r('sys.color.comp_divider'))
            }
            Text(item.label)
              .width('100%')
              .constraintSize({ minHeight: SHEET_ROW_HEIGHT })
              .textAlign(TextAlign.Center)
              .fontSize($r('sys.float.Body_L'))
              .fontColor(IOS_TINT_BLUE)
              .onClick(() => {
                this.sheet = SHEET_NONE;
                item.action();
              })
          }, (item: SheetAction, index: number) => `${this.sheet}-${index}`)
        }
        .width('100%')
        .backgroundColor($r('sys.color.background_secondary'))
        .borderRadius($r('sys.float.ohos_id_corner_radius_dialog'))
        .clip(true)

        // Swift `UIAlertAction(title: L10n.Global.cancel, style: .cancel)`.
        Text($r('app.string.global_cancel'))
          .id('collab_editor_sheet_cancel')
          .width('100%')
          .constraintSize({ minHeight: SHEET_ROW_HEIGHT })
          .textAlign(TextAlign.Center)
          .fontSize($r('sys.float.Body_L'))
          // UIKit draws the .cancel action semibold (iPhone 4.20).
          .fontWeight(600)
          .fontColor(IOS_TINT_BLUE)
          .backgroundColor($r('sys.color.background_primary'))
          .borderRadius($r('sys.float.ohos_id_corner_radius_dialog'))
          .onClick(() => {
            this.cancelSheet();
          })
      }
      .width('100%')
      .padding({
        start: LengthMetrics.vp(SHEET_INSET),
        end: LengthMetrics.vp(SHEET_INSET),
        bottom: LengthMetrics.vp(SHEET_BOTTOM_INSET)
      })
    }
    .width('100%')
    .height('100%')
  }

  /**
   * Swift `apply(_ format:)`. The image item picks a picture; the link item asks for an address.
   */
  private applyFormat(format: string): void {
    if (format === 'image') {
      this.pickImage();
      return;
    }
    if (format === 'link') {
      this.promptLink();
      return;
    }
    const call: string | undefined = FORMAT_CALLS[format];
    if (call !== undefined) {
      this.runEditor(call);
    }
  }

  /**
   * Swift `showFormats(_:)` — keeps the link under the caret for the link prompt, and lights up
   * the buttons that describe the text under the caret.
   */
  private showFormats(json: string): void {
    let formats: SelectionFormats;
    try {
      formats = (JSON.parse(json) as SelectionReport).formats;
    } catch (error) {
      this.currentLink = '';
      return;
    }
    this.currentLink = typeof formats.link === 'string' ? formats.link : '';
    const lit: Record<string, boolean> = {
      'bold': formats.bold === true, 'italic': formats.italic === true,
      'underline': formats.underline === true, 'strike': formats.strike === true,
      'header1': formats.header === 1, 'header2': formats.header === 2,
      'header3': formats.header === 3,
      'listBullet': formats.list === 'bullet', 'listOrdered': formats.list === 'ordered',
      // Left alignment is the absence of the attribute.
      'alignLeft': formats.align === '', 'alignCenter': formats.align === 'center',
      'alignRight': formats.align === 'right', 'alignJustify': formats.align === 'justify',
      'link': this.currentLink.length > 0
    };
    this.activeFormats = FORMAT_ITEMS.map((item: CollabFormatItem): string => item.format)
      .filter((format: string): boolean => lit[format] === true);
  }

  private isActive(format: string): boolean {
    return this.activeFormats.indexOf(format) >= 0;
  }

  /**
   * Swift `promptLink()`: "Link", the field filled with the link under the caret (placeholder
   * "Address", a URL keyboard), Add, Remove when there is a link, Cancel. The page itself
   * adds https:// to a bare address and refuses any scheme but http, https and mailto.
   */
  private promptLink(): void {
    // The card's TextInput takes the focus off the page, which collapses the page's selection.
    // UIKit's alert does not; keep the selected range so setLink can put it back.
    this.runScript('(function(){var s=document.getSelection();' +
      'window.__jamiLinkRange=s&&s.rangeCount>0?s.getRangeAt(0).cloneRange():null;})()');
    this.pendingLink = this.currentLink;
    this.canRemoveLink = this.currentLink.length > 0;
    this.isLinking = true;
  }

  /** Swift the link alert's Add / Remove: `setLink(address)`, an empty address removing it. */
  private setLink(address: string): void {
    this.isLinking = false;
    // Device: with the selection collapsed by the card's field, Add left the word unlinked.
    // Give the page its focus back, restore the range kept in promptLink, then let Quill's
    // selectionchange catch up before formatting.
    try {
      this.webController.requestFocus();
    } catch (error) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'editor focus failed: %{public}s',
        describeError(error as BusinessError));
    }
    const call: string = `window.JamiEditor.setLink(${JSON.stringify(address.trim())})`;
    setTimeout((): void => {
      this.runScript('(function(){var r=window.__jamiLinkRange;window.__jamiLinkRange=null;' +
        'if(r){var s=document.getSelection();s.removeAllRanges();s.addRange(r);}' +
        `setTimeout(function(){${call};},${LINK_SELECTION_SETTLE_MS});})()`);
    }, LINK_REFOCUS_DELAY_MS);
  }

  /**
   * The sheet's Cancel (and a tap on the dimmed editor). UIKit hands the first responder back to
   * the web view when a cancelled action sheet goes away, so a keyboard that was up comes back
   * and the editor is as it was before the menu (T-1352 review).
   */
  private cancelSheet(): void {
    this.sheet = SHEET_NONE;
    if (!this.refocusOnCancel) {
      return;
    }
    this.refocusOnCancel = false;
    try {
      this.webController.requestFocus();
    } catch (error) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'editor focus failed: %{public}s',
        describeError(error as BusinessError));
    }
  }

  /**
   * Back: the topmost layer goes, as its Cancel does (the rename prompt is drawn over the link
   * prompt, both over the sheet); with none, a keyboard that is up goes by letting the page's
   * focus go, as the menu does (T-1352).
   */
  private closeTopLayer: () => boolean = (): boolean => {
    if (this.isRenaming) {
      this.isRenaming = false;
      return true;
    }
    if (this.isLinking) {
      this.isLinking = false;
      return true;
    }
    if (this.sheet !== SHEET_NONE) {
      this.cancelSheet();
      return true;
    }
    if (!this.keyboardUp) {
      return false;
    }
    this.getUIContext().getFocusController().clearFocus();
    return true;
  };

  /** runJavaScript on the editor page; a failure is logged, never thrown. */
  private runScript(script: string): void {
    try {
      this.webController.runJavaScript(script)
        .catch((error: BusinessError): void => {
          hilog.warn(LOG_DOMAIN, LOG_TAG, 'editor call failed: %{public}s', describeError(error));
        });
    } catch (error) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'editor call failed: %{public}s',
        describeError(error as BusinessError));
    }
  }

  /** A link-alert button, in UIKit's default tint or its destructive red. */
  @Builder
  private linkButton(id: string, title: Resource, color: ResourceColor,
    weight: number | FontWeight, action: () => void) {
    Text(title)
      .id(id)
      .textAlign(TextAlign.Center)
      .constraintSize({ minWidth: PROMPT_BUTTON_HEIGHT, minHeight: PROMPT_BUTTON_HEIGHT })
      .fontSize($r('sys.float.Body_L'))
      .fontWeight(weight)
      .fontColor(color)
      .onClick(action)
  }

  /** Swift `promptLink()`'s UIAlertController, drawn as the rename prompt's card. */
  @Builder
  private linkPrompt() {
    Column({ space: PROMPT_INSET }) {
      Text($r('app.string.collab_link_title'))
        .width('100%')
        .textAlign(TextAlign.Center)
        .fontSize($r('sys.float.Body_L'))
        .fontWeight(600)
        .fontColor($r('app.color.label'))
      TextInput({ placeholder: $r('app.string.collab_link_hint'), text: this.pendingLink })
        .id('collab_editor_link_field')
        .width('100%')
        .type(InputType.URL)
        .fontSize($r('sys.float.Body_M'))
        .fontColor($r('app.color.label'))
        .placeholderColor($r('app.color.placeholder_text'))
        .backgroundColor($r('sys.color.background_primary'))
        // UIAlertController focuses its text field: the URL keyboard comes up with the alert.
        .defaultFocus(true)
        .onAppear((): void => {
          focusControl.requestFocus('collab_editor_link_field');
        })
        .onChange((value: string) => {
          this.pendingLink = value;
        })
      // UIKit lays two actions side by side, Cancel first, and stacks three. UIAlertController
      // draws them in the default tint (systemBlue), the .cancel action bold (iPhone 4.20).
      if (this.canRemoveLink) {
        Column() {
          this.linkButton('collab_editor_link_add', $r('app.string.collab_link_add'),
            IOS_TINT_BLUE, FontWeight.Regular,
            (): void => {
              this.setLink(this.pendingLink);
            })
          this.linkButton('collab_editor_link_remove', $r('app.string.collab_link_remove'),
            DESTRUCTIVE_RED, FontWeight.Regular, (): void => {
              this.setLink('');
            })
          this.linkButton('collab_editor_link_cancel', $r('app.string.global_cancel'),
            IOS_TINT_BLUE, 600, (): void => {
              this.isLinking = false;
            })
        }
        .width('100%')
      } else {
        Row() {
          this.linkButton('collab_editor_link_cancel', $r('app.string.global_cancel'),
            IOS_TINT_BLUE, 600, (): void => {
              this.isLinking = false;
            })
          Blank()
          this.linkButton('collab_editor_link_add', $r('app.string.collab_link_add'),
            IOS_TINT_BLUE, FontWeight.Regular,
            (): void => {
              this.setLink(this.pendingLink);
            })
        }
        .width('100%')
      }
    }
    .width('100%')
    .padding(PROMPT_INSET)
    .backgroundColor($r('sys.color.background_secondary'))
    .borderRadius($r('sys.float.ohos_id_corner_radius_dialog'))
  }

  /**
   * CollabSchemeHandler `serveAttachment`: a picture the page asks for is answered with the
   * attachment's bytes from libjami; one this device does not hold yet is refused (normal
   * right after a peer inserted it; `attachmentArrived` asks again). Every other request is
   * left to the web view, which the CSP keeps to the bundle itself.
   */
  private serveAttachment(url: string): WebResourceResponse | null {
    const at: number = url.indexOf(ATTACHMENT_PATH);
    if (!url.startsWith(ATTACHMENT_SCHEME) || at < 0) {
      return null;
    }
    const attachmentId: string =
      decodeURIComponent(url.substring(at + ATTACHMENT_PATH.length).split('?')[0]);
    // The proof the page's picture request reached the application.
    hilog.info(LOG_DOMAIN, LOG_TAG, 'attachment %{public}s requested', attachmentId);
    const response: WebResourceResponse = new WebResourceResponse();
    // The page is laying an image out and waits; the bytes are handed over when read.
    response.setResponseIsReady(false);
    ServiceRegistry.shared().collaborationService
      .attachment(this.accountId, this.conversationId, this.documentId, attachmentId)
      .then((data: Uint8Array): void => {
        if (data.length === 0) {
          response.setResponseCode(404);
          response.setReasonMessage('Not Found');
        } else {
          response.setResponseCode(200);
          response.setReasonMessage('OK');
          response.setResponseMimeType(pictureType(data));
          response.setResponseData(
            data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength) as ArrayBuffer);
        }
        response.setResponseIsReady(true);
      })
      .catch((): void => {
        response.setResponseCode(404);
        response.setReasonMessage('Not Found');
        response.setResponseIsReady(true);
      });
    return response;
  }

  /** Swift `pickImage()` — PHPicker, images only, one at a time. */
  private pickImage(): void {
    const options: picker.PhotoSelectOptions = new picker.PhotoSelectOptions();
    options.MIMEType = picker.PhotoViewMIMETypes.IMAGE_TYPE;
    options.maxSelectNumber = 1;
    new picker.PhotoViewPicker().select(options)
      .then((result: picker.PhotoSelectResult): Promise<void> | undefined =>
        result.photoUris.length > 0 ? this.attachPicked(result.photoUris[0]) : undefined)
      .catch((error: BusinessError): void => {
        hilog.error(LOG_DOMAIN, LOG_TAG, 'image pick failed: %{public}s', describeError(error));
        this.showMessage('collab_image_error');
      });
  }

  /**
   * Swift `picker(_:didFinishPicking:)` + `attach(image:width:height:)`: the bytes travel as
   * they came, only the size is read to lay the picture out. Over the daemon's ceiling is
   * `imageTooLarge`; a refusal is `imageError`; otherwise the page inserts it at the caret.
   */
  private async attachPicked(uri: string): Promise<void> {
    const file: fileIo.File = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
    let buffer: ArrayBuffer;
    try {
      buffer = new ArrayBuffer(fileIo.statSync(file.fd).size);
      fileIo.readSync(file.fd, buffer);
    } finally {
      fileIo.closeSync(file);
    }
    if (buffer.byteLength > MAX_ATTACHMENT_BYTES) {
      this.showMessage('collab_image_too_large');
      return;
    }
    let width: number = 0;
    let height: number = 0;
    const source: image.ImageSource = image.createImageSource(buffer);
    try {
      const info: image.ImageInfo = await source.getImageInfo();
      width = info.size.width;
      height = info.size.height;
    } finally {
      source.release();
    }
    const attachmentId: string = await ServiceRegistry.shared().collaborationService
      .addAttachment(this.accountId, this.conversationId, this.documentId, new Uint8Array(buffer));
    if (attachmentId.length === 0) {
      this.showMessage('collab_image_error');
      return;
    }
    this.runEditor(`insertImage(${JSON.stringify(attachmentId)},${width},${height})`);
  }

  /** Swift `leaveVersion()` — back from the version being read to the document. */
  private leaveVersion(): void {
    this.callEditor('leaveVersion');
    this.shownCommitId = '';
    this.versionLabel = '';
  }

  /**
   * Swift `restoreVersion()` -> `askEditor("restoreVersion")`: the page puts the document back
   * to the version it shows as an ordinary edit, which the others receive the usual way (true),
   * finds that version is already the document (false), or fails (null). Sending the old state
   * to the daemon instead changed nothing: a Y-CRDT merge of an older state is a no-op.
   */
  private restoreVersion(): void {
    if (this.shownCommitId.length === 0) {
      return;
    }
    this.webController.runJavaScriptExt('String(window.JamiEditor.restoreVersion())')
      .then((result: webview.JsMessageExt): void => {
        const answer: string = scriptString(result);
        if (answer !== 'true' && answer !== 'false') {
          this.showMessage('collab_version_restore_error');
          return;
        }
        this.endVersionReading();
        this.showMessage(answer === 'true' ? 'collab_version_restored'
          : 'collab_version_unchanged');
      })
      .catch((error: BusinessError): void => {
        hilog.error(LOG_DOMAIN, LOG_TAG, 'restore failed: %{public}s', describeError(error));
        this.showMessage('collab_version_restore_error');
      });
  }

  /** Swift `endVersionReading()` — the page has left the version on its own; so does the list. */
  private endVersionReading(): void {
    this.shownCommitId = '';
    this.versionLabel = '';
    this.isHistoryOpen = false;
  }

  /** Swift `onSelect` on the history panel — show that version. */
  private showVersion(version: CollaborativeVersion): void {
    this.shownCommitId = version.commitId;
    // Swift `L10n.Collab.versionShown(viewModel.describe(version))`: a medium date, a short time.
    const shown: string = this.describeVersion(version);
    this.versionLabel =
      getContext(this).resourceManager.getStringByNameSync('collab_version_shown', shown);
    ServiceRegistry.shared().collaborationService
      .stateAt(this.accountId, this.conversationId, this.documentId, version.commitId)
      .then((state: Uint8Array): void => {
        this.callEditor('showVersion', state);
      })
      .catch((error: Object): void => {
        this.reportFailure(error);
      });
  }

  /** Swift `setUpFormatBar()` — the horizontal scroller of format buttons. */
  @Builder
  private formatBar() {
    // Swift `formatBar` — a `jamiFormBackground` scroller `barHeight` tall, its buttons
    // `buttonSpacing` apart on `touchTarget` tap areas.
    Scroll() {
      Row({ space: BUTTON_SPACING }) {
        ForEach(FORMAT_ITEMS, (item: CollabFormatItem) => {
          // Swift `makeButton`: a symbol when the item has one, else its title (H1/H2/H3),
          // tinted `jamiPrimaryControl` at `inactiveAlpha`; `showFormats` selects the active
          // ones (full alpha, the tint filling the square behind a knocked-out glyph).
          Stack() {
            if (item.icon !== null) {
              SymbolGlyph(item.icon)
                .fontSize(FORMAT_GLYPH_SIZE)
                .fontColor([this.isActive(item.format) ? $r('app.color.jami_form_background')
                  : $r('app.color.jami_primary_control')])
                .width(SELECTED_SIZE)
                .height(SELECTED_SIZE)
                .borderRadius(SELECTED_RADIUS)
                .backgroundColor(this.isActive(item.format) ? $r('app.color.jami_primary_control')
                  : Color.Transparent)
            } else {
              // Swift `.preferredFont(forTextStyle: .headline)`: 17 pt SEMIBOLD.
              Text(item.title)
                .fontSize($r('sys.float.Body_L'))
                .fontWeight(600)
                .fontColor(this.isActive(item.format) ? $r('app.color.jami_form_background')
                  : $r('app.color.jami_primary_control'))
                .textAlign(TextAlign.Center)
                .width(SELECTED_SIZE)
                .height(SELECTED_SIZE)
                .borderRadius(SELECTED_RADIUS)
                .backgroundColor(this.isActive(item.format) ? $r('app.color.jami_primary_control')
                  : Color.Transparent)
            }
          }
          .id(`collab_editor_format_${item.format}`)
          .accessibilityText(item.label)
          .width(TOUCH_TARGET)
          .height(TOUCH_TARGET)
          .opacity(this.isActive(item.format) ? 1 : INACTIVE_ALPHA)
          .onClick(() => {
            this.applyFormat(item.format);
          })
        }, (item: CollabFormatItem) => item.format)
      }
      .alignItems(VerticalAlign.Center)
      .padding({
        start: LengthMetrics.vp(BAR_MARGIN),
        end: LengthMetrics.vp(BAR_MARGIN)
      })
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
    .height(BAR_HEIGHT)
    .backgroundColor($r('app.color.jami_form_background'))
  }

  /** Swift `setUpVersionBar()` — the same band as the format bar, shown while reading one. */
  @Builder
  private versionBar() {
    // Swift `versionBar` — the same `jamiFormBackground` band as the format bar, its label
    // and its two actions all `.footnote`; the actions are plain system buttons (systemBlue,
    // regular weight, as the iPhone 4.20 draws them).
    Row({ space: BUTTON_SPACING }) {
      Text(this.versionLabel)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .fontSize(FOOTNOTE_SIZE)
        .fontColor($r('app.color.label'))
        .layoutWeight(1)
      Blank()
      // UIButton(type: .system) has no side inset: padding on all four sides took 32vp from the
      // label, which wrapped to "Version of / Nov 16, …" on the folded Mate X7 (T-1112).
      Text($r('app.string.collab_version_leave'))
        .id('collab_editor_version_leave')
        .fontSize(FOOTNOTE_SIZE)
        .fontColor(IOS_TINT_BLUE)
        .padding({ top: $r('sys.float.padding_level4'), bottom: $r('sys.float.padding_level4') })
        .onClick(() => {
          this.leaveVersion();
        })
      Text($r('app.string.collab_version_restore'))
        .id('collab_editor_version_restore')
        .fontSize(FOOTNOTE_SIZE)
        .fontColor(IOS_TINT_BLUE)
        .padding({ top: $r('sys.float.padding_level4'), bottom: $r('sys.float.padding_level4') })
        .onClick(() => {
          this.restoreVersion();
        })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .constraintSize({ minHeight: BAR_HEIGHT })
    .padding({
      start: LengthMetrics.vp(BAR_MARGIN),
      end: LengthMetrics.vp(BAR_MARGIN)
    })
    .backgroundColor($r('app.color.jami_form_background'))
  }

  build() {
    Stack() {
      Column() {
        // Swift `showTitle()` — `navigationItem.prompt`, the line above the navigation bar.
        Text(this.participantsDescription())
          .id('collab_editor_presence')
          .width('100%')
          .textAlign(TextAlign.Center)
          .fontSize($r('sys.float.Body_S'))
          .fontColor($r('app.color.label'))
          .padding({ top: LengthMetrics.vp(BAR_MARGIN) })
        // Swift `setUpNavigationBar()` — Close leading, the document name centred, the overflow
        // menu trailing.
        Row() {
          Text($r('app.string.global_close'))
            .id('collab_editor_close')
            .fontSize($r('sys.float.Body_L'))
            .fontColor(IOS_TINT_BLUE)
            .onClick(() => {
              this.dismiss();
            })
          Blank()
          Text(this.title())
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            // UIKit truncates the title's tail mid-word; ArkUI cut at the last whole word, so
            // "Meeting Minutes AAA…A" read "Meeting Minutes ..." (T-1360).
            .wordBreak(WordBreak.BREAK_ALL)
            .fontSize($r('sys.float.Body_L'))
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.label'))
            .textAlign(TextAlign.Center)
            .layoutWeight(1)
          Blank()
          SymbolGlyph($r('sys.symbol.ellipsis_circle'))
            .id('collab_editor_menu')
            .accessibilityText($r('app.string.collab_menu'))
            .fontSize(FORMAT_GLYPH_SIZE)
            .fontColor([IOS_TINT_BLUE])
            .width(TOUCH_TARGET)
            .height(TOUCH_TARGET)
            .onClick(() => {
              // UIKit's action sheet takes the first responder from the web view, so the keyboard
              // goes down; this sheet is drawn in the page, so the page's focus is let go (T-1352).
              this.refocusOnCancel = this.keyboardUp;
              this.getUIContext().getFocusController().clearFocus();
              this.sheet = SHEET_MENU;
            })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .constraintSize({ minHeight: BAR_HEIGHT })
        .padding({
          start: LengthMetrics.vp(BAR_MARGIN),
          end: LengthMetrics.vp(BAR_MARGIN)
        })
        .backgroundColor($r('sys.color.background_primary'))

        Row() {
          Stack({ alignContent: Alignment.Center }) {
            // Swift: the WKWebView over the jami-collab:// scheme handler; ArkWeb serves the
            // same bundle out of rawfile, with JamiBridge in place of the message handler and
            // onInterceptRequest answering the page's pictures (serveAttachment).
            // The declarative proxy is registered before the first load, as editor.js needs it
            // when it boots. ArkWeb logs "native proxy object not found, name:JamiBridge" on every
            // call carrying a string: it looks the name up among C-API proxies first, then hands
            // the call to this ArkTS object. The hilog lines in localUpdate/applyUpdate show the
            // call arriving.
            Web({ src: $rawfile('collab/editor.html'), controller: this.webController })
              .width('100%')
              .height('100%')
              .javaScriptAccess(true)
              .onInterceptRequest((event: OnInterceptRequestEvent) =>
                this.serveAttachment(event.request.getRequestUrl()))
              .javaScriptProxy({
                object: this.bridge,
                name: 'JamiBridge',
                methodList: ['onReady', 'onUpdate', 'onAwareness', 'onSelection', 'onLinkRequested',
                  'onImageRequested', 'onLog'],
                controller: this.webController
              })

            // Swift `loadingView` / `errorLabel`, centred over the editor.
            if (this.isLoading) {
              LoadingProgress()
                .width(TOUCH_TARGET)
                .height(TOUCH_TARGET)
                .color($r('app.color.jami'))
            }
            if (this.errorText.length > 0) {
              Text(this.errorText)
                .width('100%')
                .fontSize($r('sys.float.Body_M'))
                .fontColor($r('sys.color.font_secondary'))
                .textAlign(TextAlign.Center)
                .padding($r('sys.float.ohos_id_elements_margin_horizontal_l'))
            }
          }
          .layoutWeight(1)

          // Swift `historyPanel`, 300 pt beside the editor rather than over it.
          if (this.isHistoryOpen) {
            Column() {
              CollabHistoryPanel({
                entries: this.historyRows,
                shownCommitId: this.shownCommitId,
                onSelect: (version: CollaborativeVersion): void => {
                  this.showVersion(version);
                },
                // Swift `historyPanel.onClose`: one way out of the reading, whatever was read.
                onClose: (): void => {
                  if (this.shownCommitId.length > 0) {
                    this.leaveVersion();
                  }
                  this.isHistoryOpen = false;
                }
              })
            }
            // Swift `panelWidth = 300` at .defaultHigh, capped at 60% of the view (required): on
            // a phone the cap wins (iPhone 4.20: 234 of 390 pt). jamiFormBackground, as the bar.
            .width(HISTORY_PANEL_WIDTH)
            .constraintSize({ maxWidth: '60%' })
            .height('100%')
            .backgroundColor($r('app.color.jami_form_background'))
            .border({
              width: { start: LengthMetrics.vp(0.5) },
              color: { start: $r('sys.color.comp_divider') }
            })
          }
        }
        .layoutWeight(1)
        .width('100%')

        // Swift: versionBar is pinned to formatBar's own edges — one band, two states. A
        // read-only document offers no formatting at all.
        if (this.shownCommitId.length > 0) {
          this.versionBar()
        } else if (this.isRichText && !this.isReadOnly) {
          this.formatBar()
        }
      }
      .width('100%')
      .height('100%')
      .padding({ top: this.topInset, bottom: this.bottomInset })

      // Swift `showMenu()` / `showExportMenu()`.
      if (this.sheet === SHEET_MENU) {
        this.actionSheet(this.menuActions())
      } else if (this.sheet === SHEET_EXPORT) {
        this.actionSheet(this.exportActions())
      }

      // Swift `promptLink()` — the link alert over the whole editor.
      if (this.isLinking) {
        Column() {
          this.linkPrompt()
        }
        .width('100%')
        .height('100%')
        .padding(PROMPT_INSET)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(PROMPT_SCRIM)
      }

      // Swift `promptRename()` — the name alert over the whole editor.
      if (this.isRenaming) {
        Column() {
          CollabNamePrompt({
            title: $r('app.string.collab_rename'),
            confirmTitle: $r('app.string.global_ok'),
            name: $pendingName,
            // Swift `promptRename()` is a UIAlertController.
            systemAlert: true,
            onCancel: (): void => {
              this.isRenaming = false;
            },
            onConfirm: (): void => {
              this.rename();
            }
          })
        }
        .width('100%')
        .height('100%')
        .padding(PROMPT_INSET)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(PROMPT_SCRIM)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('sys.color.background_primary'))
    .id('screen_collab_editor')
  }
}
