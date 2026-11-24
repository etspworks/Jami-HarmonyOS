/*
 * screen_swarm_creation — "Create Swarm", ported from
 *   Ring/Ring/SwarmCreation/SwarmCreationViewController.storyboard  (an empty root view — the
 *     whole scene is built in code, so the storyboard contributes no controls)
 *   Ring/Ring/SwarmCreation/SwarmCreationViewController.swift
 *   Ring/Ring/SwarmCreation/SwarmCreationViewModel.swift
 *   Ring/Ring/UI/CustomSearchController.swift
 *
 * ONE SOURCE SCREEN, ONE BODY. `viewDidLoad` installs the Cancel / "Select contacts" / Create
 * bar and the navigation item's search controller, and then sets
 * `view = UIHostingController(SwarmCreationUI(list: model))` — the SwiftUI body IS this
 * controller's view. The capture proves it: SwarmCreationViewController's tree and
 * SwarmCreationUI's tree are identical, both carrying the bar, the search field, the "Customize
 * group" row and the contact list.
 *
 * The migration had split that one screen into two separately-routed pages, so this route drew
 * only the bar + search while pages/CreateSwarmParticipantsPage drew only Customize + list, and
 * each route was missing the other's controls (judge: E003/I002/I003 on S0010/S0015 here,
 * E001/E002/I001 on S0012/S0016/S0021 there). The whole screen now lives ONCE, as
 * `CreateSwarmparticipants` in pages/CreateSwarmParticipantsPage.ets, and both routes mount it —
 * so this page shows Cancel, the title, Create, the search field with its magnifier and clear
 * control, the participant list and the Customize-group row, and every slug appears exactly
 * once per page. That component is named for the child screen the plan declares this page HOSTS
 * (screen_swarm_creation_ui, "Create Swarm (participants)"), because after the merge it IS that
 * child and the containment contract is what this page's mount of it has to satisfy.
 *
 * Everything else — the bar's style, the search relay and filter, createTheSwarm()'s daemon gap,
 * the profile sheet — is documented on `CreateSwarmparticipants` itself, beside the code.
 */
import { router } from '@kit.ArkUI';
import { SWARM_ACTIVATION_SHOWN, CreateSwarmparticipants } from './CreateSwarmParticipantsPage';

/** EntryAbility.routeToTarget pushes a page with the overlay a deep link asked for. */
interface SwarmHostRouteParams {
  overlayScreen?: string;
}

@Entry
@Component
struct CreateSwarmHostPage {
  /**
   * Empty until the page is up. The body subscribes to svc_contacts off this signal rather than
   * in `aboutToAppear`: a cold deep link lands before the first frame, and the two
   * ArrayDataSource reloads svc_contacts replays synchronously delayed the page marker past the
   * drivers' settle window.
   */
  @State private activation: string = '';

  onPageShow(): void {
    if (this.activation.length > 0) {
      return;
    }
    const raw: Object | undefined = router.getParams();
    const overlay: string = raw === undefined
      ? '' : ((raw as SwarmHostRouteParams).overlayScreen ?? '');
    this.activation = overlay.length > 0 ? overlay : SWARM_ACTIVATION_SHOWN;
  }

  build() {
    Column() {
      CreateSwarmparticipants({ activation: this.activation })
    }
    .width('100%')
    .height('100%')
    // The controller's root view — plain systemBackground, no grouped chrome.
    .backgroundColor($r('sys.color.background_primary'))
    .id('screen_swarm_creation')
  }
}
