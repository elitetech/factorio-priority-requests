-- Shared save-data helpers: table initialization, network membership, and dirty-network tracking.
local state = {}

function state.init_globals()
  storage.requesters = storage.requesters or {}
  storage.network_members = storage.network_members or {}
  storage.dirty_networks = storage.dirty_networks or {}
  storage.player_state = storage.player_state or {}
end

function state.get_update_interval()
  local setting = settings.global["fpr-update-interval"]
  if not setting then
    return 60
  end

  return math.max(1, setting.value)
end

function state.mark_network_dirty(network_key)
  if network_key then
    storage.dirty_networks[network_key] = true
  end
end

function state.remove_member_from_network(network_key, unit_number)
  if not network_key then
    return
  end

  local members = storage.network_members[network_key]
  if not members then
    return
  end

  members[unit_number] = nil
  if not next(members) then
    storage.network_members[network_key] = nil
    storage.dirty_networks[network_key] = nil
  end
end

function state.add_member_to_network(network_key, unit_number)
  if not network_key then
    return
  end

  local members = storage.network_members[network_key]
  if not members then
    members = {}
    storage.network_members[network_key] = members
  end

  members[unit_number] = true
end

return state
