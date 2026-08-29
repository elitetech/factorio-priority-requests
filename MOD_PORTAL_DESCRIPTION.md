# Priority Requesters

Assign a priority to every requester chest so construction/logistic robots service your most important requests first — no more watching a dozen chests fight over the same batch of scarce items.

## The problem

Factorio's logistic network delivers items to requester chests roughly in the order robots happen to path to them. When supply is tight (you've just started producing a new item, or a big base is competing for a handful of modules), there's no way to say "fill this chest before that one." Requests just get serviced in whatever order the robots find convenient.

## What this mod does

Priority Requesters lets you assign each requester chest a **priority from 0 (lowest) to 10 (highest)**. When there's enough supply in the network for every chest's request, nothing changes — every chest gets everything it asked for, same as vanilla. But when supply is contested, the mod automatically throttles the *requested amount* on lower-priority chests down to whatever they've already got (or already have in transit), freeing up the remaining supply so higher-priority chests are serviced first.

Nothing is deleted or disabled — the mod only narrows what a chest is currently allowed to ask for. As soon as supply frees up (or you raise a chest's priority), its full original request comes right back.

## Features

- **Per-chest priority (0–10)** set from a small panel that appears next to the vanilla logistics GUI whenever you open a requester chest.
- **Automatic, per-network reconciliation.** Priority contention is only resolved among chests that actually share the same logistic network — a busy network on one surface won't starve requests on another.
- **Live status at a glance.** Each chest's panel shows whether it's currently `Active`, `Waiting on higher priority`, already `Satisfied`, or has no requests configured, plus a per-item breakdown (requested / on the way / in logistic storage).
- **Circuit network control of request amounts.** If a requester chest's logistic section is circuit-controlled, the mod respects the live circuit-driven demand and still applies priority throttling on top of it.
- **Circuit network control of priority.** Instead of (or in addition to) picking a priority manually, you can wire a signal into the chest and pick that signal in the priority panel — the chest's priority is then read live from the circuit network every update, so you can drive priority from production ratios, storage levels, or any other in-base logic.
- **Survives copy/paste and blueprints.** Priority is preserved when you use the copy-settings tool on a requester chest, and it's stored in blueprint tags so it comes back correctly when you build from a blueprint.
- **Configurable update interval.** A mod setting controls how often (in ticks) the mod re-scans requester chests to catch changes that don't raise direct game events (deliveries completing, network topology changes, etc.). Lower it for snappier reactions, raise it to save UPS on very large bases.
- **Optional debug logging** (mod setting) for diagnosing unexpected behavior.

## How to use it

1. Build a requester chest and set up its item requests as normal, using the vanilla logistics GUI.
2. Open the chest — a small "Requester priority" panel appears alongside it.
3. Pick a priority from the drop-down (default is 5), or click the signal button to drive priority from your circuit network instead.
4. That's it. When supply is scarce, chests with a lower priority automatically get throttled first; raise their priority (or wait for supply to free up) to have them serviced again.

## Known limitations

- This mod does not directly command robots — it can only change how much a chest is currently allowed to request. Deliveries already in flight when priority changes may still complete.
- Priority is chest-level, not per-slot: all items requested by the same chest share that chest's priority.
- Supply estimation is approximate — it's based on the network's current storage/provider inventories plus already-targeted deliveries, refreshed on the interval described above.

## Compatibility

- Requires the base game (`base >= 2.0.0`) — no other mod dependencies.
- Works alongside any mod that adds its own requester-chest-like entities, as long as they use the standard logistic requester point API.

## Feedback

Bug reports and suggestions are welcome — please include your mod list and, if possible, steps to reproduce.
