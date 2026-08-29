-- All GUI construction/update logic for the per-chest priority panel.
local constants = require("scripts.constants")
local requester = require("scripts.requester")
local filters = require("scripts.filters")

local gui = {}

-- Forward declaration: update_player_gui rebuilds the frame via create_or_update_gui
-- when expected child elements are missing.
local create_or_update_gui

function gui.get_priority_index_for_value(priority)
  local target = math.max(0, math.floor(priority or 0))
  local nearest_index = 1
  local nearest_distance = math.huge

  for index, level in ipairs(constants.PRIORITY_LEVELS) do
    local distance = math.abs(level - target)
    if distance < nearest_distance then
      nearest_distance = distance
      nearest_index = index
    end
  end

  return nearest_index
end

function gui.find_player_frame(player)
  return player.gui.relative[constants.GUI_ROOT] or player.gui.left[constants.GUI_ROOT]
end

function gui.destroy_player_frame(player)
  local frame = gui.find_player_frame(player)
  if frame then
    frame.destroy()
  end
end

local function find_descendant_by_name(root, target_name)
  if not root or not root.valid then
    return nil
  end

  local direct_child = root[target_name]
  if direct_child and direct_child.valid then
    return direct_child
  end

  for _, child in pairs(root.children) do
    local nested = find_descendant_by_name(child, target_name)
    if nested then
      return nested
    end
  end

  return nil
end

local function summarize_filter_counts(filter_list)
  local summary = {}
  for _, filter in ipairs(filter_list or {}) do
    local value = filter and filter.value or {}
    local name = value.name
    if name then
      -- Key on the full filter definition, not just the item name: two filters for
      -- the same item with different quality/comparator/request_from represent
      -- distinct requests and must not be merged into one tile's count.
      local key = filters.get_filter_definition_key(filter)
      local entry = summary[key]
      if not entry then
        entry = {
          name = name,
          quality = value.quality,
          comparator = value.comparator,
          request_from = filter.request_from,
          count = 0
        }
        summary[key] = entry
      end
      entry.count = entry.count + math.max(0, math.floor(filter.count or 0))
    end
  end
  return summary
end

local function get_logistic_delivery_metrics(entity, point, filter_def)
  local on_the_way = filters.get_targeted_count_for_filter(point, filter_def)
  local storage_count = 0

  if entity and entity.valid then
    local network = entity.logistic_network
    if network and network.valid then
      local value = filter_def.value
      if value.quality then
        storage_count = network.get_item_count({name = value.name, quality = value.quality}, "storage") or 0
      else
        storage_count = network.get_item_count(value.name, "storage") or 0
      end
    end
  end

  return on_the_way, storage_count
end

local function rebuild_request_tiles(frame, entity, desired_filters, applied_filters)
  local existing = frame[constants.REQUESTS_LIST]
  if existing and existing.valid then
    existing.destroy()
  end

  local desired_summary = summarize_filter_counts(desired_filters)
  local applied_summary = summarize_filter_counts(applied_filters)
  local keys = {}
  for key in pairs(desired_summary) do
    keys[#keys + 1] = key
  end
  for key in pairs(applied_summary) do
    if not desired_summary[key] then
      keys[#keys + 1] = key
    end
  end
  table.sort(keys)

  local point = (entity and entity.valid) and entity:get_requester_point() or nil

  local list = frame.add({type = "flow", name = constants.REQUESTS_LIST, direction = "horizontal"})
  list.style.horizontally_stretchable = false
  list.style.vertically_stretchable = false

  for _, key in ipairs(keys) do
    local entry = desired_summary[key] or applied_summary[key]
    local desired_count = desired_summary[key] and desired_summary[key].count or 0
    local filter_def = {
      value = {type = "item", name = entry.name, quality = entry.quality, comparator = entry.comparator},
      request_from = entry.request_from
    }
    local current_count = (entity and entity.valid) and filters.get_entity_count_for_filter(entity, filter_def) or 0
    local on_the_way, storage_count = get_logistic_delivery_metrics(entity, point, filter_def)
    local prototype = prototypes.item[entry.name]
    local item_title = prototype and prototype.localised_name or entry.name
    local tile_size = 40
    local tile = list.add({
      type = "sprite-button",
      sprite = "item/" .. entry.name,
      elem_tooltip = {type = "item", name = entry.name},
      tooltip = {
        "",
        {"fpr.item_tooltip_title", item_title},
        "\n",
        {"fpr.item_tooltip_satisfaction", current_count, desired_count},
        "\n",
        {"fpr.item_tooltip_on_the_way", on_the_way},
        "\n",
        {"fpr.item_tooltip_storage", storage_count}
      },
      number = desired_count,
      style = "slot_sized_button"
    })
    tile.style.padding = 2
    tile.style.margin = 0
    tile.style.minimal_width = tile_size
    tile.style.maximal_width = tile_size
    tile.style.minimal_height = tile_size
    tile.style.maximal_height = tile_size
    tile.style.horizontally_stretchable = false
    tile.style.vertically_stretchable = false
    tile.style.font = "default-small-bold"
    tile.style.font_color = {r = 1, g = 1, b = 1}
  end
end

function gui.update_player_gui(player)
  if not player or not player.valid then
    return
  end

  local player_state = storage.player_state[player.index]
  if not player_state then
    return
  end

  local frame = gui.find_player_frame(player)
  if not frame then
    return
  end

  local record = storage.requesters[player_state.opened_unit_number]
  if not record or not record.entity.valid then
    frame.destroy()
    storage.player_state[player.index] = nil
    return
  end

  local priority_dropdown = find_descendant_by_name(frame, constants.PRIORITY_DROPDOWN)
  local status_value = find_descendant_by_name(frame, constants.STATUS_VALUE)
  if not priority_dropdown or not status_value then
    gui.destroy_player_frame(player)
    create_or_update_gui(player, record.entity)
    frame = gui.find_player_frame(player)
    if not frame then
      return
    end

    priority_dropdown = find_descendant_by_name(frame, constants.PRIORITY_DROPDOWN)
    status_value = find_descendant_by_name(frame, constants.STATUS_VALUE)
    if not priority_dropdown or not status_value then
      return
    end
  end

  local selected_index = gui.get_priority_index_for_value(record.priority)
  if priority_dropdown.selected_index ~= selected_index then
    priority_dropdown.selected_index = selected_index
  end
  status_value.caption = {"fpr.status_" .. (record.status or "unknown")}
  rebuild_request_tiles(frame, record.entity, record.desired_filters, record.applied_filters)
end

function gui.update_all_open_guis()
  for player_index in pairs(storage.player_state) do
    gui.update_player_gui(game.get_player(player_index))
  end
end

create_or_update_gui = function(player, entity)
  if not player or not player.valid then
    return
  end

  gui.destroy_player_frame(player)

  if not requester.is_requester(entity) then
    storage.player_state[player.index] = nil
    return
  end

  -- Ensure the opened chest is registered so update_player_gui does not tear down the frame.
  requester.track_requester(entity)

  local frame = nil
  local anchored = pcall(function()
    frame = player.gui.relative.add({
      type = "frame",
      name = constants.GUI_ROOT,
      direction = "vertical",
      caption = {"fpr.frame_title"},
      anchor = {
        gui = defines.relative_gui_type.container_gui,
        position = defines.relative_gui_position.right
      }
    })
  end)

  if not anchored or not frame then
    frame = player.gui.left.add({
      type = "frame",
      name = constants.GUI_ROOT,
      direction = "vertical",
      caption = {"fpr.frame_title"}
    })
  end

  frame.style.vertically_stretchable = false
  frame.style.horizontally_stretchable = false
  frame.style.minimal_width = constants.PANEL_WIDTH
  frame.style.maximal_width = constants.PANEL_WIDTH

  local priority_flow = frame.add({type = "flow", direction = "horizontal"})
  priority_flow.style.vertical_align = "center"
  priority_flow.add({type = "label", caption = {"fpr.priority_label"}})
  local dropdown_items = {}
  for _, level in ipairs(constants.PRIORITY_LEVELS) do
    dropdown_items[#dropdown_items + 1] = tostring(level)
  end
  local priority_dropdown = priority_flow.add({
    type = "drop-down",
    name = constants.PRIORITY_DROPDOWN,
    items = dropdown_items,
    selected_index = gui.get_priority_index_for_value(5)
  })
  priority_dropdown.style.minimal_width = constants.DROPDOWN_WIDTH
  priority_dropdown.style.maximal_width = constants.DROPDOWN_WIDTH

  frame.add({type = "flow", name = constants.REQUESTS_LIST, direction = "horizontal"})

  frame.add({type = "label", name = constants.STATUS_VALUE, caption = {"fpr.status_unknown"}})

  storage.player_state[player.index] = {
    opened_unit_number = entity.unit_number
  }

  gui.update_player_gui(player)
end

gui.create_or_update_gui = create_or_update_gui

function gui.close_frames_for_unit(unit_number)
  for player_index, player_state in pairs(storage.player_state) do
    if player_state.opened_unit_number == unit_number then
      local player = game.get_player(player_index)
      if player and player.valid then
        gui.destroy_player_frame(player)
      end
      storage.player_state[player_index] = nil
    end
  end
end

return gui
