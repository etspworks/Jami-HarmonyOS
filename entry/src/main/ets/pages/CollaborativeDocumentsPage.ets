/*
 * screen_collab_documents — "Collaborative Documents", ported from
 *   Ring/Ring/Features/Collab/CollabDocumentsView.swift (CollabDocumentsView,
 *     CollabNewDocumentButton, DocumentRow, CollabNamePrompt, CollabNewDocumentPrompt)
 *   Ring/Ring/Features/Collab/CollabDocumentsVM.swift
 *   Ring/Ring/Features/Collab/CollabDocumentRemoval.swift
 *   Ring/Ring/Services/CollaborationService.swift
 *   Ring/Ring/Features/Conversations/views/ConfirmationAlert.swift
 *
 * presentation: sheet, hostScreen: screen_swarm_info. It is the documents section of
 * SwarmInfoView, so it is the content of a .bindSheet() mounted by SwarmConversationInfoPage
 * (bound to that page's `Documents` segment control) — NOT a routed page and NOT registered in
 * main_pages.json.
 *
 * NO CAPTURED STATE (the gallery declared this screen uncapturable): every control and branch
 * below comes from the source only.
 *
 * S3 — the real tree of `CollabDocumentsView.documentSection`:
 *   if viewModel.documents.isEmpty {
 *       Section { Text(L10n.Collab.noDocuments) }
 *   } else {
 *       Section(header: Text(L10n.Collab.documents)) {
 *           ForEach(viewModel.documents, id: \.id) { DocumentRow(document:viewModel:open:
 *                                                                requestRemoval:) } }
 *   }
 *   .onAppear(perform: viewModel.reload)
 *   .alert(isPresented: $viewModel.failed) { Alert(title: Text(viewModel.failureMessage)) }
 *   plus CollabNewDocumentButton and CollabNewDocumentPrompt, which SwarmInfoView renders
 *   beside the section over the same view model.
 *
 * bindingContract: [collaborative document list] / [rows] are svc_collaboration —
 * `CollaborationService.documents(accountId:conversationId:)`, the daemon's own list, rendered
 * through LazyForEach over an ArrayDataSource. It starts EMPTY and is filled by the service;
 * no row is a literal. [row title] is CollaborativeDocument.name through the VM's `title(of:)`
 * (an unnamed document reads "Untitled document", as the source says), and [row icon] is the
 * document's own kind.
 *
 * conditionalVariants, each a real `if` on its own bound selector:
 *   empty        — isEmpty, the conversation holds no documents
 *   naming       — the CollabNamePrompt is up: a dialog over the whole screen (startNaming)
 *   failed       — `viewModel.failed` -> the one-line alert, a system alert (fail())
 *   has_removals — hasRemovals, `!viewModel.removals(for: document).isEmpty`, which gates BOTH
 *                  the swipe action and the menu's removal items, per document
 *
 * navOut: present -> screen_collab_editor, trigger "Document row". Swift
 * `stateEmitter.openDocument(…)` reaches the conversation coordinator, whose
 * `openCollabDocument` presents CollabEditorViewController full screen over what is on top:
 * this screen, pushed (`.show`) on the conversation. So the section presents the editor itself,
 * and Close comes back to the Documents view (ConversationNavigation.swift:167).
 *
 * DAEMON GAP (Rule 11): every CollaborationService call here (documents, createDocument,
 * removeDocument, removeDocumentLocally) is jami-daemon work. Each control calls the real
 * service and renders its failure through the source's own alert — nothing fakes a document,
 * and nothing disappears from the list behind a removal the daemon never performed.
 */
import { common } from '@kit.AbilityKit';
import { LengthMetrics } from '@kit.ArkUI';
import { ArrayDataSource } from '../common/ArrayDataSource';
import {
  CollaborationService,
  CollaborativeDocumentChangeKind,
  CreatedDocument,
  DocumentChangeEvent,
  DocumentEvent,
  DocumentRemoved
} from '../common/CollaborationService';
import { CollabNamePrompt } from '../components/CollabNamePrompt';
import {
  COLLAB_EDITOR_ACCOUNT_KEY,
  COLLAB_EDITOR_CONVERSATION_KEY,
  COLLAB_EDITOR_DOCUMENT_KEY,
  CollaborativeDocumentEditorOverlay
} from './CollaborativeDocumentEditorPage';
import { CollabNewDocumentButton } from '../components/CollabNewDocumentButton';
import {
  CollabDocumentRemoval,
  DESTRUCTIVE_RED,
  DOCUMENT_ROW_INSET,
  DOCUMENT_ROW_TEXT_INSET,
  DocumentRowView,
  availableRemovals,
  removalMenuTitle
} from '../components/DocumentRow';
import { ServiceRegistry } from '../common/ServiceRegistry';
import { groupMember } from '../components/ExpandableAvatar';
import { CollaborativeDocument } from '../model/CollaborativeDocument';
import { ConversationParticipant } from '../model/ConversationParticipant';

/** Swift `DocumentsLayout.margin`. */
const SECTION_MARGIN: number = 16;

/* ── S5 (the source's own, plus the iOS grouped-list defaults it inherits) ──────────────
 * `CollabDocumentsView.documentSection` is a `Section` of SwarmInfoView's List, styled by
 * `adaptiveInsetGroupedListStyle()`: `.insetGrouped` on iOS 26, `.grouped` before. The
 * reference iPhone runs iOS 18, so it is `.grouped`: a grey page, full-width white rows, and an
 * uppercase grey header at the rows' content inset — the Members tab's own table (MemberList).
 */
/** The grouped header's spacing, as MemberList's (the same table on the same screen). */
const SECTION_HEADER_TOP: number = 18;
const SECTION_HEADER_BOTTOM: number = 6;
/**
 * SwarmInfoView `Layout.floatingButtonClearance` — the List's bottom inset (`.safeAreaInset`)
 * while the documents are shown, so the last row scrolls clear of the New document button.
 */
const FLOATING_BUTTON_CLEARANCE: number = 88;
/** The iOS grouped-row hairline. */
const HAIRLINE: number = 0.5;
/** Swift `CustomAlert`'s ZStack — `Color.black.opacity(0.5)` behind the centred card. */
const ALERT_SCRIM: string = '#80000000';
/**
 * Swift `tint(for:)` on the swipe buttons — `.jamiWarning` (UIColor.orange) for a local
 * removal, `.jamiFailure` (`UIColor(hex: 0xf00000)`) for the one that retires it for everyone.
 */
const JAMI_WARNING: string = '#FF9500';
const JAMI_FAILURE: string = '#F00000';
/** iPhone 4.20 swipe buttons: 74 pt wide, a ~20 pt glyph. */
const SWIPE_BUTTON_WIDTH: number = 74;
const SWIPE_ICON_SIZE: number = 20;
/**
 * UIKit draws a swipe action's title under its icon only on a row at least this tall; a shorter
 * row gets the icon alone. ponytail: UIKit's threshold as commonly measured, not a documented
 * constant; tune on device if a 2-line row disagrees with the iPhone.
 */
const SWIPE_TITLE_MIN_HEIGHT: number = 91;
const SWIPE_TITLE_GAP: number = 2;
/** Swift `DocumentRow.symbol` — the two glyphs a document row can carry. */
const DOC_ICON_STORED: string = 'doc.richtext';
const DOC_ICON_REMOTE: string = 'arrow.down.doc';
/** The title the opened document is handed over with, beside `pendingCollabDocumentId`. */
export const PENDING_COLLAB_DOCUMENT_NAME_KEY: string = 'pendingCollabDocumentName';

@Component
export struct CollaborativeDocumentsSheet {
  /** Owned by screen_swarm_info; the host's @State drives the sheet. */
  @Link isPresented: boolean;
  /** Swift `CollabDocumentsVM(accountId:conversationId:)` — supplied by the presenting host. */
  @Prop accountId: string = '';
  @Prop conversationId: string = '';
  /** Swift `private let localJamiId` — who this device is, for `removals(for:)`. */
  @Prop localJamiId: string = '';
  /**
   * Not called: the section presents the editor over the info screen itself (see navOut). Kept
   * because both hosts still pass it.
   */
  onOpenDocument?: (documentId: string) => void;

  /** bindingContract[collaborative document list] / [rows]: svc_collaboration. */
  @State collaborativeDocumentList: CollaborativeDocument[] = [];
  /** conditionalVariants[empty]: Swift `viewModel.documents.isEmpty`. */
  @State isEmpty: boolean = true;
  /** conditionalVariants[has_removals]: any row offering a removal (per row, below). */
  @State hasRemovals: boolean = false;
  /**
   * bindingContract[row title]: CollaborativeDocument.name through Swift `title(of:)` — the
   * title the opened row hands to the editor (`open(document.id, viewModel.title(of:))`).
   */
  @State rowTitle: string = '';
  /**
   * bindingContract[row icon]: the document's own kind — Swift `DocumentRow.symbol`,
   * `storedLocally ? "doc.richtext" : "arrow.down.doc"`, for the document being opened.
   */
  @State rowIcon: string = '';
  /** True while svc_collaboration is in flight. */
  @State isLoading: boolean = false;
  /** screen_collab_editor's presentation flag while it is up over this section. */
  @State private showEditor: boolean = false;
  /**
   * Swift `openCollabDocument(accountId:conversationId:documentId:name:)`: the editor, full
   * screen over the info screen, as ConversationChatPage presents it over the conversation.
   */
  private editorDialog: CustomDialogController = new CustomDialogController({
    builder: CollaborativeDocumentEditorOverlay({ isPresented: $showEditor }),
    autoCancel: true,
    // T-1602: Back with a prompt, the menu or the keyboard up closes only that.
    onWillDismiss: (action: DismissDialogAction): void => {
      if (action.reason === DismissReason.PRESS_BACK
        && CollaborativeDocumentEditorOverlay.closeOpenLayer()) {
        return;
      }
      this.showEditor = false;
      action.dismiss();
    },
    customStyle: true,
    width: '100%',
    height: '100%',
    cornerRadius: 0,
    // The format bar sits ON the keyboard, as iOS's: the default 16 vp distance showed a strip
    // of this info screen between the two.
    keyboardAvoidDistance: LengthMetrics.vp(0)
  });

  /** bindingContract[rows]: LazyForEach's source (CLAUDE.md rule 7), reloaded from the
   * service's own list — `CollaborationService.documents(accountId:conversationId:)`. */
  @State rows: ArrayDataSource<CollaborativeDocument> =
    new ArrayDataSource<CollaborativeDocument>([]);
  /**
   * Swift `CollabNewDocumentPrompt`, which SwarmInfoView raises "over the whole screen, not over
   * the tab it was asked from". This section is only the lower half of the info screen, so a
   * layer of its own Stack centred the prompt in that half and left the header undimmed: it is
   * a dialog, with `CustomAlert`'s black 0.5 scrim and no dismissal on a tap outside.
   */
  private namePrompt: CustomDialogController = new CustomDialogController({
    builder: CollabNewDocumentDialog({
      // Swift CollabNewDocumentPrompt is a CustomAlert: Create stays the bold one.
      systemAlert: false,
      onCreate: (name: string): void => {
        this.confirmName(name);
      }
    }),
    autoCancel: false,
    customStyle: true,
    alignment: DialogAlignment.Center,
    maskColor: ALERT_SCRIM
  });
  /** The list's scroller, to put a swipe away once its removal is asked for. */
  private scroller: ListScroller = new ListScroller();
  /**
   * Swift `@Published private(set) var waiting` — the documents changed since they were last
   * opened here. Rows read it through their LazyForEach key, so a change rebuilds them.
   */
  private waiting: Set<string> = new Set<string>();
  /** Swift `disposeBag` — the daemon subscriptions, released with the section. */
  private stopListening: (() => void)[] = [];

  /** Swift `.onAppear(perform: viewModel.reload)`, plus the VM's `subscribeDocumentChanges()`. */
  aboutToAppear(): void {
    this.subscribeDocumentChanges();
    this.reload();
  }

  aboutToDisappear(): void {
    this.stopListening.forEach((stop: () => void): void => {
      stop();
    });
    this.stopListening = [];
    // A CustomDialog outlives the component that opened it; its mask would eat every tap.
    this.editorDialog.close();
  }

  /**
   * Swift `subscribeDocumentChanges()`: a document announced (an update with no content),
   * renamed or removed, on another device or on this one, reloads the list. The removals
   * included: nothing is dropped from the list by hand, the daemon's own event rebuilds it.
   */
  private subscribeDocumentChanges(): void {
    const service: CollaborationService = ServiceRegistry.shared().collaborationService;
    const here = (accountId: string, conversationId: string): boolean =>
      accountId === this.accountId && conversationId === this.conversationId;
    // Swift `subscribeDocumentsWaitingToBeRead()`.
    this.stopListening.push(service.documentsWaitingToBeRead(this.accountId, this.conversationId,
      (waiting: Set<string>): void => {
        this.waiting = waiting;
        this.rows.reload(this.collaborativeDocumentList);
      }));
    this.stopListening.push(
      service.documentChanges.subscribe((event: DocumentChangeEvent): void => {
        if (here(event.accountId, event.conversationId)
          && event.change.kind === CollaborativeDocumentChangeKind.NOTIFICATION) {
          this.reload();
        }
      }),
      service.documentsRenamed.subscribe((event: DocumentEvent): void => {
        if (here(event.accountId, event.conversationId)) {
          this.reload();
        }
      }),
      service.documentsRemoved.subscribe((event: DocumentRemoved): void => {
        if (here(event.accountId, event.conversationId)) {
          this.reload();
        }
      }));
  }

  /** Swift `reload()` — `collaborationService.documents(accountId:conversationId:)`. */
  private reload(): void {
    this.isLoading = true;
    const service: CollaborationService = ServiceRegistry.shared().collaborationService;
    service.documents(this.accountId, this.conversationId)
      .then((documents: CollaborativeDocument[]): void => {
        this.applyDocuments(documents);
      })
      .catch((): void => {
        this.isLoading = false;
        this.applyDocuments([]);
      });
  }

  private applyDocuments(documents: CollaborativeDocument[]): void {
    this.isLoading = false;
    this.collaborativeDocumentList = documents;
    this.rows.reload(documents);
    this.isEmpty = documents.length === 0;
    this.hasRemovals = documents.some((document: CollaborativeDocument) =>
      availableRemovals(document, this.localJamiId).length > 0);
  }

  /** Swift `viewModel.title(of:)` — an unnamed document is "Untitled document". */
  private title(document: CollaborativeDocument): string {
    return document.name.length === 0
      ? this.resolve('collab_untitled')
      : document.name;
  }

  /**
   * Swift `CollabDocumentsVM.detail(of:)` / `static detail(authorName:storedLocally:)`. Without
   * an author the source shows nothing for a held document and "not downloaded" for one that
   * is not held.
   */
  private detail(document: CollaborativeDocument): string {
    const author: string | null = document.author;
    if (author === null || author.length === 0) {
      return document.storedLocally ? '' : this.resolve('collab_not_downloaded');
    }
    return this.resolveWith(document.storedLocally
      ? 'collab_created_by' : 'collab_created_by_not_downloaded', this.authorName(author));
  }

  /**
   * Swift `static authorName(for:resolved:localJamiId:)`: the member's resolved name (as the
   * Members tab names them), else the first eight characters of the id, and "(You)" after this
   * account's own documents.
   */
  private authorName(author: string): string {
    const isLocal: boolean = this.localJamiId.length > 0 && author === this.localJamiId;
    const known: string =
      groupMember(new ConversationParticipant(author, isLocal), this.accountId).name;
    const name: string = known.length > 0 && known !== author ? known : author.substring(0, 8);
    return isLocal ? `${name} (${this.resolve('conversation_yourself')})` : name;
  }

  /** Swift `viewModel.startNaming()` — the dialog's field starts empty on every opening. */
  private startNaming(): void {
    this.namePrompt.open();
  }

  /**
   * Swift `CollabNewDocumentPrompt.create()` — `viewModel.create(named:)`, then the created
   * document is reloaded into the list AND opened. A failure is the source's own alert.
   */
  private confirmName(name: string): void {
    ServiceRegistry.shared().collaborationService
      .createDocument(this.accountId, this.conversationId, name)
      .then((document: CreatedDocument): void => {
        this.reload();
        // Swift `create(named:then:)` hands the editor BOTH the id and the name it was given.
        this.openDocumentNamed(document.id, document.name, false);
      })
      .catch((): void => {
        this.fail('collab_create_error');
      });
  }

  /**
   * Swift `open(_:_:)` -> `stateEmitter.openDocument(in:documentId:name:)` ->
   * ConversationState.openCollabDocument -> CollabEditorViewController (edge: present).
   */
  private openDocument(document: CollaborativeDocument): void {
    this.openDocumentNamed(document.id, this.title(document), document.storedLocally);
  }

  /**
   * Swift `open(_ documentId:_ name:)` — the state the editor is opened with: the document's
   * id, its resolved title and the glyph DocumentRow picked for it. The editor comes up over
   * this screen; closing it shows the Documents view again (device: it used to land on the
   * conversation, T-1303).
   */
  private openDocumentNamed(documentId: string, name: string, storedLocally: boolean): void {
    this.rowTitle = name;
    this.rowIcon = storedLocally ? DOC_ICON_STORED : DOC_ICON_REMOTE;
    AppStorage.setOrCreate<string>(PENDING_COLLAB_DOCUMENT_NAME_KEY, this.rowTitle);
    // The controller's builder arguments were fixed when it was built: the ids travel here.
    AppStorage.setOrCreate<string>(COLLAB_EDITOR_ACCOUNT_KEY, this.accountId);
    AppStorage.setOrCreate<string>(COLLAB_EDITOR_CONVERSATION_KEY, this.conversationId);
    AppStorage.setOrCreate<string>(COLLAB_EDITOR_DOCUMENT_KEY, documentId);
    this.showEditor = true;
    this.editorDialog.open();
  }

  /**
   * SwarmInfoView `requestDocumentRemoval` -> `documentRemovalAlert(for:)`: the menu and the
   * swipe both end at this confirmation, Cancel beside a destructive Remove.
   */
  private confirmRemoval(removal: CollabDocumentRemoval, document: CollaborativeDocument): void {
    try {
      this.scroller.closeAllSwipeActions();
    } catch (error) {
      // Only throws while the List is unbound; the alert still has to come up.
    }
    const local: boolean = removal === CollabDocumentRemoval.FROM_THIS_DEVICE;
    this.getUIContext().showAlertDialog({
      title: local ? $r('app.string.collab_remove_locally_title')
        : $r('app.string.collab_remove_title'),
      message: this.resolveWith(local ? 'collab_remove_locally_message' : 'collab_remove_message',
        this.title(document)),
      alignment: DialogAlignment.Center,
      autoCancel: true,
      primaryButton: {
        value: $r('app.string.global_cancel'),
        action: (): void => {}
      },
      secondaryButton: {
        value: $r('app.string.collab_remove'),
        fontColor: DESTRUCTIVE_RED,
        action: (): void => {
          this.requestRemoval(removal, document);
        }
      }
    });
  }

  /**
   * Swift `viewModel.perform(_:on:)`. The two removals
   * are different questions: one reclaims what this device stored, the other retires the
   * document for every member — so each calls its own service method.
   */
  private requestRemoval(removal: CollabDocumentRemoval, document: CollaborativeDocument): void {
    const service: CollaborationService = ServiceRegistry.shared().collaborationService;
    if (removal === CollabDocumentRemoval.FROM_THIS_DEVICE) {
      service.removeDocumentLocally(this.accountId, this.conversationId, document.id)
        .then((removed: boolean): void => {
          // Swift drops nothing from the list here: the daemon's own removal event is what
          // rebuilds it, so what the author sees is what the peers see.
          if (!removed) {
            this.fail('collab_remove_locally_error');
          }
        })
        .catch((): void => {
          this.fail('collab_remove_locally_error');
        });
      return;
    }
    service.removeDocument(this.accountId, this.conversationId, document.id)
      .then((removed: boolean): void => {
        if (!removed) {
          this.fail('collab_remove_error');
        }
      })
      .catch((): void => {
        this.fail('collab_remove_error');
      });
  }

  /**
   * Swift `fail(with:)` -> `.alert(isPresented: $viewModel.failed) { Alert(title:) }`: one
   * message, one system alert over the whole screen, whichever call failed.
   */
  private fail(resourceName: string): void {
    this.getUIContext().showAlertDialog({
      title: this.resolve(resourceName),
      message: '',
      alignment: DialogAlignment.Center,
      autoCancel: true,
      confirm: {
        value: $r('app.string.global_ok'),
        action: (): void => {}
      }
    });
  }

  /** A localized string resolved to plain text — a row shows a message, not a resource. */
  private resolve(name: string): string {
    const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    return context.resourceManager.getStringByNameSync(name);
  }

  private resolveWith(name: string, argument: string): string {
    const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    return context.resourceManager.getStringByNameSync(name, argument);
  }

  /**
   * Swift `.swipeActions(edge: .trailing) { ForEach(viewModel.removals(for: document)) … }` —
   * ArkUI puts a swipe on the LIST ITEM, so this is the swipe half of the row's removal pair.
   * It renders nothing at all for a document that offers no removal, which is what the source
   * does: an action it withholds must be absent, not merely disabled.
   */
  @Builder
  private swipeRemovals(document: CollaborativeDocument) {
    // conditionalVariants[has_removals] — per document, exactly as `removals(for:)` computes it.
    if (availableRemovals(document, this.localJamiId).length > 0) {
      Row() {
        // SwiftUI lays a trailing swipe out from the edge inwards: the FIRST removal sits at the
        // trailing edge (iPhone 4.20: orange minus.circle outermost, red trash inside it).
        ForEach(availableRemovals(document, this.localJamiId).reverse(),
          (removal: CollabDocumentRemoval) => {
            // Swift `Label(removal.swipeTitle, systemImage: removal.symbol)` in the symbol's
            // fill variant; its title shows under the icon on a tall enough row (T-1104).
            Button({ type: ButtonType.Normal }) {
              CollabSwipeRemovalLabel({ removal: removal })
            }
            // One id per action (T-1604): Remove is for everyone, Offload this device only.
            .id(removal === CollabDocumentRemoval.FOR_EVERYONE
              ? 'collab_documents_swipe_remove' : 'collab_documents_swipe_offload')
            // Swift `.accessibilityLabel(removal.menuTitle)` — the icon READS the full title.
            .accessibilityText(removalMenuTitle(removal))
            .width(SWIPE_BUTTON_WIDTH)
            .height('100%')
            // Swift `.tint(tint(for: removal))` — warning for local, failure for everyone.
            .backgroundColor(removal === CollabDocumentRemoval.FOR_EVERYONE
              ? JAMI_FAILURE
              : JAMI_WARNING)
            .onClick(() => {
              this.confirmRemoval(removal, document);
            })
          }, (removal: CollabDocumentRemoval) => removal)
      }
      .height('100%')
    }
  }

  build() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      Column() {
        // Swift `documentSection` — the empty state and the list are exclusive branches.
        if (this.isEmpty) {
          // Swift `.font(.callout).foregroundColor(.secondary)` on a clear row background.
          Text($r('app.string.collab_no_documents'))
            .id('collabDocumentsEmpty')
            .width('100%')
            .textAlign(TextAlign.Center)
            .fontSize($r('sys.float.Body_M'))
            .fontColor($r('app.color.secondary_label'))
            .padding({
              start: LengthMetrics.vp(SECTION_MARGIN),
              end: LengthMetrics.vp(SECTION_MARGIN),
              top: LengthMetrics.vp(SECTION_MARGIN * 2),
              bottom: LengthMetrics.vp(SECTION_MARGIN * 2)
            })
        } else {
          // Swift `Section(header: Text(L10n.Collab.documents))` — `.grouped` uppercases it.
          Text($r('app.string.collab_documents'))
            .width('100%')
            .textCase(TextCase.UpperCase)
            .fontSize($r('sys.float.Body_S'))
            .fontColor($r('app.color.secondary_label'))
            .padding({
              start: LengthMetrics.vp(DOCUMENT_ROW_INSET),
              end: LengthMetrics.vp(DOCUMENT_ROW_INSET),
              top: LengthMetrics.vp(SECTION_HEADER_TOP),
              bottom: LengthMetrics.vp(SECTION_HEADER_BOTTOM)
            })

          List({ scroller: this.scroller }) {
            LazyForEach(this.rows, (document: CollaborativeDocument) => {
              ListItem() {
                DocumentRowView({
                  document: document,
                  title: this.title(document),
                  detail: this.detail(document),
                  waiting: this.waiting.has(document.id),
                  removals: availableRemovals(document, this.localJamiId),
                  onOpen: (): void => {
                    this.openDocument(document);
                  },
                  onRequestRemoval: (removal: CollabDocumentRemoval): void => {
                    this.confirmRemoval(removal, document);
                  }
                })
              }
              // `.grouped` — a white row the full width of the screen.
              .backgroundColor($r('sys.color.comp_background_list_card'))
              .swipeAction({
                end: {
                  builder: (): void => {
                    this.swipeRemovals(document)
                  }
                }
              })
            }, (document: CollaborativeDocument) =>
              // Everything the row draws: with the id alone a reload after 'Remove from this
              // device' or a rename kept the old row (still 'Open', no 'not downloaded').
              `${document.id}|${this.title(document)}|${this.detail(document)}|` +
              `${this.waiting.has(document.id)}`)
          }
          .width('100%')
          .layoutWeight(1)
          .contentEndOffset(FLOATING_BUTTON_CLEARANCE)
          // UIKit insets a row's separator to its text, past the glyph.
          .divider({
            strokeWidth: HAIRLINE,
            color: $r('sys.color.comp_divider'),
            startMargin: DOCUMENT_ROW_TEXT_INSET
          })
        }

      }
      .width('100%')
      .height('100%')
      // iOS grouped list — the grey page the white cards sit on.
      .backgroundColor($r('sys.color.background_secondary'))

      // Swift `CollabNewDocumentButton`, floating over the section.
      CollabNewDocumentButton({
        onStartNaming: (): void => {
          this.startNaming();
        }
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('sys.color.background_secondary'))
    .id('screen_collab_documents')
  }
}

/**
 * Swift `promptNewCollabDocument()` (ConversationViewController.swift:255) — the conversation's
 * "New document" alert: a name field, Cancel and Create — and, raised by the documents section
 * above, `CollabNewDocumentPrompt`, the same three controls. The host's CustomDialogController
 * supplies the alert's modality and dimming; Create hands the name back.
 */
/**
 * Swift `Label(removal.swipeTitle, systemImage: removal.symbol)` as a swipe action draws it:
 * the white fill glyph, with "Remove" / "Offload" under it once the row is tall enough
 * (TC-DOCS-033-2: a 3-line row shows both; a 2-line one shows the glyph alone).
 */
@Component
struct CollabSwipeRemovalLabel {
  removal: CollabDocumentRemoval = CollabDocumentRemoval.FROM_THIS_DEVICE;
  @State private showsTitle: boolean = false;

  build() {
    Column({ space: SWIPE_TITLE_GAP }) {
      SymbolGlyph(this.removal === CollabDocumentRemoval.FOR_EVERYONE
        ? $r('sys.symbol.trash_fill')
        : $r('sys.symbol.minus_circle_fill'))
        .fontSize(SWIPE_ICON_SIZE)
        .fontColor([Color.White])
      if (this.showsTitle) {
        // Swift `swipeTitle` — "a swipe button fits about a dozen characters, so it says less".
        Text(this.removal === CollabDocumentRemoval.FOR_EVERYONE
          ? $r('app.string.collab_remove_everywhere_action')
          : $r('app.string.collab_remove_locally_action'))
          .fontSize($r('sys.float.Body_M'))
          .fontWeight(FontWeight.Medium)
          .fontColor(Color.White)
          .maxLines(1)
      }
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .onAreaChange((_old: Area, area: Area): void => {
      this.showsTitle = Number(area.height) >= SWIPE_TITLE_MIN_HEIGHT;
    })
  }
}

@CustomDialog
export struct CollabNewDocumentDialog {
  controller?: CustomDialogController;
  /** Swift `alert.textFields?.first?.text`. */
  @State name: string = '';
  /** Swift `viewModel.createCollabDocument(named:)`. */
  onCreate?: (name: string) => void;
  /**
   * The chat's prompt is Swift `promptNewCollabDocument()`, a UIAlertController (Cancel bold);
   * the documents list passes false for its CustomAlert.
   */
  systemAlert: boolean = true;

  build() {
    CollabNamePrompt({
      title: $r('app.string.collab_new_document'),
      confirmTitle: $r('app.string.collab_create'),
      name: $name,
      systemAlert: this.systemAlert,
      onCancel: (): void => {
        this.controller?.close();
      },
      onConfirm: (): void => {
        this.controller?.close();
        const create: ((name: string) => void) | undefined = this.onCreate;
        if (create !== undefined) {
          create(this.name);
        }
      }
    })
      .padding(SECTION_MARGIN)
  }
}
