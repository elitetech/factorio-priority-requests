# Priority Requesters

Priority Requesters is a Factorio mod that adds chest-level priorities to requester chests.

## What it does

Factorio does not expose a native requester priority setting in the runtime API. This mod approximates requester priorities by throttling the *requests* of lower-priority chests when supply is contested inside the same logistic network, so robots naturally service the higher-priority chests first.

When enough items exist for everyone, every requester chest keeps its full request and all of them can be serviced. When supply is short, the mod reduces (or zeroes out) the requested amount on lower-priority chests down to whatever they've already got or already have inbound, freeing up the remaining supply for higher-priority chests.

## How it works

### Tracking requester chests

- Every `logistic-container` entity with a requester logistic point is tracked in `storage.requesters`, keyed by `unit_number`. A record stores the entity reference, its `priority` (default `5`), its `desired_filters` (the requests the player actually configured), its `applied_filters` (the requests the mod last wrote to the entity), and a `status` for the GUI.
- Each record is also associated with a "network key" — a combination of force, surface, and logistic network id (or a `pending:` placeholder if the entity isn't connected to a network yet). Requesters are grouped by network key in `storage.network_members` so priority contention is only resolved among chests that actually share the same logistic network.
- Event hooks keep this state in sync: entities are tracked on `on_built_entity`/`on_robot_built_entity`/`script_raised_built`/`on_space_platform_built_entity`, and cleaned up on `on_player_mined_entity`/`on_robot_mined_entity`/`on_space_platform_mined_entity`/`script_raised_destroy`/`on_entity_died`.

### Reconciliation (the priority algorithm)

- Whenever something relevant changes, the entity's network key is marked "dirty" in `storage.dirty_networks`. `on_entity_logistic_slot_changed` marks a network dirty immediately when a player edits requests; a periodic `on_tick` pass (governed by the `fpr-update-interval` mod setting) also re-marks every network dirty so the mod recovers from changes that don't raise direct events (network topology changes, deliveries completing, etc.).
- Dirty networks are reconciled in `reconcile_network`, which runs once per affected network per pass:
  1. All tracked requesters in the network are sorted by priority descending (ties broken by `unit_number`).
  2. For each requested item on each chest, the mod computes: how much the chest already holds, how much is already targeted for delivery to it, and how much supply remains in the network's storage/passive-provider/buffer/active-provider inventories for that item (tracked as a shared "remaining supply" pool, consumed in priority order).
  3. Chests at the highest priority level always keep their full desired request. Chests below the highest priority have their *effective* requested count capped at `current + incoming + whatever's left of the shared supply pool` — so they only request items that are actually available.
  4. The effective (capped) filters are written back to the chest's requester point (`apply_effective_requests`), while the full original request is preserved in `desired_filters` so nothing is lost if priority changes or supply frees up later.
  5. Each chest's status is set for the GUI: `no_requests`, `satisfied` (nothing missing), `deferred` (missing items but capped below what's needed and nothing currently inbound), or `active` (currently being serviced).
- This means the mod never disables a requester chest outright — it narrows what the chest is currently allowed to ask for, which is enough to make robots prioritize higher-priority chests without fighting the game's own logistic dispatch logic.

### GUI

- Opening a requester chest (`on_gui_opened`) creates a small relative panel (anchored to the right of the container dialog) showing: a "Priority:" label with an inline, narrow drop-down (values 0–10) next to it, a status line, and a row of item tiles for each requested item.
- Each item tile is a native item sprite-button showing the requested count, with a tooltip listing satisfaction (current/desired), how much is on the way, and how much is in logistic storage.
- Changing the drop-down (`on_gui_selection_state_changed`) calls `set_priority` and immediately triggers reconciliation for that chest's network. The panel refreshes on the periodic tick pass and is destroyed when the player closes the GUI (`on_gui_closed`) or the tracked entity becomes invalid.

### Preserving priority across copy/blueprint

- Priority survives the vanilla "copy/paste entity settings" tool via `on_entity_settings_pasted`, which copies priority and desired filters from source to destination.
- Priority also survives blueprinting: `on_player_setup_blueprint` writes each requester chest's priority into a blueprint entity tag (`fpr_priority`), and `handle_built` reads that tag back out (via the `tags` field on the built-entity events) to restore priority when the blueprint is built.

## Known limitations

- This is not true robot dispatch control. The mod can only influence how much a requester chest is currently allowed to request, not directly command robots.
- Deliveries already in flight may still complete for a lower-priority chest.
- Priority is currently chest-level only. Per-slot priority and circuit-driven priority are not implemented yet.
- Supply estimation is approximate and based on logistic network contents plus already-targeted deliveries, refreshed once per reconciliation pass.

## Files

- `info.json` contains mod metadata.
- `settings.lua` defines the reconciliation interval setting (`fpr-update-interval`).
- `control.lua` is the runtime entry point; it just requires `scripts/events.lua`.
- `scripts/constants.lua` holds shared GUI element names and priority level values.
- `scripts/state.lua` initializes save data and tracks network membership/dirty state.
- `scripts/filters.lua` normalizes, compares, and applies requester logistic filter definitions, and computes network supply.
- `scripts/requester.lua` tracks requester chests, their network association, and priority.
- `scripts/gui.lua` builds and updates the per-chest priority panel.
- `scripts/reconcile.lua` runs the priority/supply-reservation algorithm per network.
- `scripts/events.lua` wires the modules together and registers all Factorio event handlers.
- `locale/en/factorio-priority-requests.cfg` contains English locale strings.

## Suggested test cases

1. Place two requester chests in the same logistic network and request the same scarce item.
2. Give one chest a higher priority and confirm it stays active while the lower one is deferred.
3. Change requests while the chest is open and confirm the status updates after the next reconciliation.
4. Copy settings from one requester chest to another and confirm the priority value copies too.
5. Blueprint a requester chest and build the blueprint elsewhere; confirm the priority carries over.
6. Mine and rebuild requester chests and confirm stale state is cleared.