/*
 * comp_back_button — ported from Ring/Ring/Features/Walkthrough/Views/Views.swift
 * `struct BackButton` (line 263):
 *
 *   Button(action: action) {
 *     HStack { Image(systemName: "chevron.left"); Text(L10n.Actions.backAction) }
 *       .foregroundColor(.jami)
 *   }
 *   .accessibilityIdentifier("walkthroughBackButton")
 *
 * The walkthrough hides the system back item (`navigationBarBackButtonHidden(true)`) and
 * installs this in the leading toolbar slot, so the pop is the CALLER's action, not a plain
 * router.back() baked in here.
 *
 * `chevron.left` -> sys.symbol.chevron_left (results/plan/icon-map.json: exact).
 */
/* ── S5 metrics, the source's own (Views.swift:263-275) + the S0047 capture ─────── */
/** Capture: the chevron is x 17..27 / y 66..85 and the label x 39..77 — a 12 pt gap. */
const BACK_GAP: number = 12;
/**
 * The back chevron of every composed nav bar (T-1661). The iOS back indicator's ink is
 * 11 x 18.7 pt with a ~2.3 pt stroke (T-1634 ref); the HarmonyOS chevron_left ink is only
 * ~0.52 em tall, so 19 drew it at 5.2 x 9.8 vp. Device-tuned in the T-1661 review (BRA-AL00 vs
 * iOS 18.3 sim, Settings and chat bars): 36 drew 10.8 x 19.7 vp ink, 2.68 vp stroke, against
 * iOS 10.7 x 18.7 pt, 2.42 pt; 34 draws 10.15 x 18.5 vp, 2.53 vp (re-measured on the same bars).
 */
const BACK_CHEVRON_SIZE: number = 34;
const BACK_CHEVRON_WEIGHT: FontWeight = FontWeight.Medium;

/** The shared back chevron: one size, weight and colour for every page's back item. */
@Component
export struct BackChevron {
  build() {
    SymbolGlyph($r('sys.symbol.chevron_left'))
      .fontSize(BACK_CHEVRON_SIZE)
      .fontWeight(BACK_CHEVRON_WEIGHT)
      .fontColor([$r('app.color.jami')])
  }
}

@Component
export struct BackButton {
  /** Swift `.accessibilityIdentifier("walkthroughBackButton")`, overridable per call site. */
  identifier: string = 'walkthroughBackButton';
  /** Swift `let action: () -> Void`. */
  action: () => void = () => {
    console.debug('BackButton: no action supplied');
  };

  build() {
    // Swift `Button { HStack { chevron; Text } }` — the whole row is the tap target.
    Row({ space: BACK_GAP }) {
      // Swift `HStack { chevron; Text }.foregroundColor(.jami)` — capture: #00345F, which is
      // app.color.jami itself.
      BackChevron()
      Text($r('app.string.actions_back_action'))
        .fontSize($r('sys.float.Body_L'))
        .fontColor($r('app.color.jami'))
    }
    .alignItems(VerticalAlign.Center)
    .id(this.identifier)
    .onClick(() => {
      this.action();
    })
  }
}
