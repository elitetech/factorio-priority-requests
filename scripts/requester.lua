-- Requester chest tracking: identifying requester entities, associating them with
-- logistic networks, and keeping storage.requesters in sync with the game state.
local state = require("scripts.state")
local filters = require("scripts.filters")

local requester = {}

-- Set by scripts/events.lua once scripts/gui.lua is loaded, so a removed requester's
-- open GUI frame gets closed without requester.lua having to require gui.lua directly.
requester.on_requester_removed = nil

function requester.is_requester(entity)
  return entity
    and entity.valid
    and entity.unit_number
    and entity.get_requester_point
    and entity:get_requester_point() ~= nil
end

function requester.get_network_key(entity, fallback_key)
  if not requester.is_requester(entity) then
    return nil
  end

  local point = entity:get_requester_point()
  if not point or not point.valid then
    return nil
  end

  local network = point.logistic_network
  if network and network.valid then
    return string.format("%d:%d:%d", entity.force_index, entity.surface_index, network.network_id)
  end

  -- Only fall back to a previous key if it was itself a "pending" placeholder, not a
  -- real network key. Otherwise an entity that has actually lost its network would
  -- stay grouped under its old real network, letting reconciliation reserve shared
  -- supply for a chest that can no longer receive deliveries there.
  if fallback_key and fallback_key:match("^pending:") then
    return fallback_key
  end

  return string.format("pending:%d:%d", entity.surface_index, entity.unit_number)
end

function requester.track_requester(entity)
  if not requester.is_requester(entity) then
    return
  end

  local unit_number = entity.unit_number
  local record = storage.requesters[unit_number]
  local previous_network_key = record and record.network_key or nil
  local network_key = requester.get_network_key(entity, previous_network_key)

  if not record then
    local point = entity:get_requester_point()
    record = {
      entity = entity,
      priority = 5,
      status = "unknown",
      network_key = network_key,
      desired_filters = filters.get_point_filter_definitions(point),
      applied_filters = nil
    }
    storage.requesters[unit_number] = record
  else
    record.entity = entity
    record.network_key = network_key
    if not record.desired_filters then
      if record.desired_requests then
        record.desired_filters = filters.legacy_counts_to_filter_definitions(record.desired_requests)
        record.desired_requests = nil
      else
        local point = entity:get_requester_point()
        record.desired_filters = filters.get_point_filter_definitions(point)
      end
    end

    if not record.applied_filters and record.applied_requests then
      record.applied_filters = filters.legacy_counts_to_filter_definitions(record.applied_requests)
      record.applied_requests = nil
    end
  end

  if previous_network_key ~= network_key then
    state.remove_member_from_network(previous_network_key, unit_number)
    state.mark_network_dirty(previous_network_key)
  end

  state.add_member_to_network(network_key, unit_number)
  state.mark_network_dirty(network_key)
end

function requester.clean_requester(unit_number)
  local record = storage.requesters[unit_number]
  if not record then
    return
  end

  state.remove_member_from_network(record.network_key, unit_number)
  -- Only re-dirty the network if it still has other members; remove_member_from_network
  -- already clears the dirty flag when it empties the network, and re-marking it here
  -- would just trigger a pointless reconcile pass for a network that no longer exists.
  if storage.network_members[record.network_key] then
    state.mark_network_dirty(record.network_key)
  end
  storage.requesters[unit_number] = nil

  if requester.on_requester_removed then
    requester.on_requester_removed(unit_number)
  end
end

function requester.adjust_priority(unit_number, delta)
  local record = storage.requesters[unit_number]
  if not record then
    return
  end

  record.priority = math.max(0, record.priority + delta)
  state.mark_network_dirty(record.network_key)
end

function requester.set_priority(unit_number, priority)
  local record = storage.requesters[unit_number]
  if not record then
    return
  end

  record.priority = math.max(0, math.floor(priority or 0))
  state.mark_network_dirty(record.network_key)
end

function requester.register_existing_requesters()
  local existing_requesters = storage.requesters or {}

  storage.requesters = {}
  storage.network_members = {}
  storage.dirty_networks = {}

  for _, surface in pairs(game.surfaces) do
    for _, entity in pairs(surface.find_entities_filtered({type = "logistic-container"})) do
      if requester.is_requester(entity) then
        requester.track_requester(entity)

        local record = storage.requesters[entity.unit_number]
        local existing = existing_requesters[entity.unit_number]
        if record and existing then
          record.priority = existing.priority or record.priority
          if existing.desired_filters then
            record.desired_filters = filters.copy_filter_definitions(existing.desired_filters)
          elseif existing.desired_requests then
            record.desired_filters = filters.legacy_counts_to_filter_definitions(existing.desired_requests)
          end

          if existing.applied_filters then
            record.applied_filters = filters.copy_filter_definitions(existing.applied_filters)
          elseif existing.applied_requests then
            record.applied_filters = filters.legacy_counts_to_filter_definitions(existing.applied_requests)
          end
        end
      end
    end
  end
end

return requester
