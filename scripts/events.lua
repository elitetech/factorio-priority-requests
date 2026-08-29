-- Entry point: wires up modules and registers all Factorio event handlers.
local state = require("scripts.state")
local constants = require("scripts.constants")
local filters = require("scripts.filters")
local requester = require("scripts.requester")
local gui = require("scripts.gui")
local reconcile = require("scripts.reconcile")

-- Let requester.clean_requester() close a removed chest's open GUI frame without
-- scripts/requester.lua having to require scripts/gui.lua directly.
requester.on_requester_removed = gui.close_frames_for_unit

local function handle_built(event)
  requester.track_requester(event.entity)

  local tags = event.tags
  local priority = tags and tags[constants.PRIORITY_TAG_KEY]
  if priority ~= nil then
    local record = storage.requesters[event.entity.unit_number]
    if record then
      record.priority = math.max(0, math.floor(priority))
      state.mark_network_dirty(record.network_key)
    end
  end
end

local function handle_removed(event)
  if event.entity and event.entity.unit_number then
    requester.clean_requester(event.entity.unit_number)
  end
end

local function handle_logistic_slot_changed(event)
  if not requester.is_requester(event.entity) then
    return
  end

  local unit_number = event.entity.unit_number
  requester.track_requester(event.entity)
  local record = storage.requesters[unit_number]
  if record then
    local point = event.entity:get_requester_point()
    local current_filters = filters.get_point_filter_definitions(point)
    if filters.filter_definitions_equal(current_filters, record.applied_filters) then
      return
    end

    record.desired_filters = current_filters
    record.applied_filters = nil
    state.mark_network_dirty(record.network_key)
  end
end

local function handle_setup_blueprint(event)
  local blueprint = event.stack
  local mapping = event.mapping and event.mapping.get()
  if not blueprint or not blueprint.valid_for_read or not mapping then
    return
  end

  for blueprint_index, source_entity in pairs(mapping) do
    if requester.is_requester(source_entity) then
      local record = storage.requesters[source_entity.unit_number]
      if record then
        blueprint.set_blueprint_entity_tag(blueprint_index, constants.PRIORITY_TAG_KEY, record.priority)
      end
    end
  end
end

local function handle_settings_pasted(event)
  if not requester.is_requester(event.source) or not requester.is_requester(event.destination) then
    return
  end

  requester.track_requester(event.source)
  requester.track_requester(event.destination)

  local source = storage.requesters[event.source.unit_number]
  local destination = storage.requesters[event.destination.unit_number]
  if source and destination then
    destination.priority = source.priority
    destination.desired_filters = filters.copy_filter_definitions(source.desired_filters)
    destination.applied_filters = nil
    state.mark_network_dirty(destination.network_key)
  end
end

local function on_init_or_configuration_changed()
  state.init_globals()
  requester.register_existing_requesters()
  reconcile.reconcile_dirty_networks()
  for _, player in pairs(game.players) do
    gui.destroy_legacy_version_ui(player)
  end
end

script.on_init(on_init_or_configuration_changed)
script.on_configuration_changed(on_init_or_configuration_changed)

script.on_event(defines.events.on_player_created, function(event)
  local player = game.get_player(event.player_index)
  gui.destroy_legacy_version_ui(player)
end)

script.on_event(defines.events.on_player_joined_game, function(event)
  local player = game.get_player(event.player_index)
  gui.destroy_legacy_version_ui(player)
end)

script.on_event(defines.events.on_built_entity, handle_built)
script.on_event(defines.events.on_robot_built_entity, handle_built)
script.on_event(defines.events.script_raised_built, handle_built)
script.on_event(defines.events.on_space_platform_built_entity, handle_built)

script.on_event(defines.events.on_player_mined_entity, handle_removed)
script.on_event(defines.events.on_robot_mined_entity, handle_removed)
script.on_event(defines.events.on_space_platform_mined_entity, handle_removed)
script.on_event(defines.events.script_raised_destroy, handle_removed)
script.on_event(defines.events.on_entity_died, handle_removed)

script.on_event(defines.events.on_entity_logistic_slot_changed, handle_logistic_slot_changed)
script.on_event(defines.events.on_entity_settings_pasted, handle_settings_pasted)
script.on_event(defines.events.on_player_setup_blueprint, handle_setup_blueprint)

script.on_event(defines.events.on_gui_opened, function(event)
  local player = game.get_player(event.player_index)
  if event.entity and requester.is_requester(event.entity) then
    requester.track_requester(event.entity)
  end
  gui.create_or_update_gui(player, event.entity)
end)

script.on_event(defines.events.on_gui_closed, function(event)
  local player = game.get_player(event.player_index)
  if not player or not player.valid then
    return
  end

  gui.destroy_player_frame(player)
  storage.player_state[event.player_index] = nil
end)

script.on_event(defines.events.on_gui_selection_state_changed, function(event)
  local element = event.element
  if not element or not element.valid then
    return
  end

  if element.name ~= constants.PRIORITY_DROPDOWN then
    return
  end

  local player_state = storage.player_state[event.player_index]
  if not player_state then
    return
  end

  local priority = constants.PRIORITY_LEVELS[element.selected_index or 0]
  if priority == nil then
    return
  end

  requester.set_priority(player_state.opened_unit_number, priority)
  reconcile.reconcile_dirty_networks()
end)

script.on_event(defines.events.on_runtime_mod_setting_changed, function(event)
  if event.setting == "fpr-update-interval" then
    for network_key in pairs(storage.network_members) do
      state.mark_network_dirty(network_key)
    end
  end
end)

script.on_event(defines.events.on_tick, function(event)
  if event.tick % state.get_update_interval() ~= 0 then
    return
  end

  local unit_numbers = {}
  for unit_number in pairs(storage.requesters) do
    unit_numbers[#unit_numbers + 1] = unit_number
  end

  for _, unit_number in ipairs(unit_numbers) do
    local record = storage.requesters[unit_number]
    if record then
      if not record.entity.valid then
        requester.clean_requester(unit_number)
      else
        local current_network_key = requester.get_network_key(record.entity, record.network_key)
        if current_network_key ~= record.network_key then
          requester.track_requester(record.entity)
        else
          state.mark_network_dirty(current_network_key)
        end
      end
    end
  end

  reconcile.reconcile_dirty_networks()
end)
