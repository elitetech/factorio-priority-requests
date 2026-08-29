local GUI_ROOT = "fpr_priority_frame"
local PRIORITY_DROPDOWN = "fpr_priority_dropdown"
local PRIORITY_TAG_KEY = "fpr_priority"
local STATUS_VALUE = "fpr_status_value"
local REQUESTS_LIST = "fpr_requests_list"
local PANEL_WIDTH = 175
local DROPDOWN_WIDTH = 60
local PRIORITY_LEVELS = {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10}
local create_or_update_gui
local sum_filter_counts
local track_requester

local function get_priority_index_for_value(priority)
  local target = math.max(0, math.floor(priority or 0))
  local nearest_index = 1
  local nearest_distance = math.huge

  for index, level in ipairs(PRIORITY_LEVELS) do
    local distance = math.abs(level - target)
    if distance < nearest_distance then
      nearest_distance = distance
      nearest_index = index
    end
  end

  return nearest_index
end

local function init_globals()
  storage.requesters = storage.requesters or {}
  storage.network_members = storage.network_members or {}
  storage.dirty_networks = storage.dirty_networks or {}
  storage.player_state = storage.player_state or {}
end

local function get_update_interval()
  local setting = settings.global["fpr-update-interval"]
  if not setting then
    return 60
  end

  return math.max(1, setting.value)
end

local function is_requester(entity)
  return entity
    and entity.valid
    and entity.unit_number
    and entity.get_requester_point
    and entity:get_requester_point() ~= nil
end

local function get_network_key(entity, fallback_key)
  if not is_requester(entity) then
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

  if fallback_key then
    return fallback_key
  end

  return string.format("pending:%d:%d", entity.surface_index, entity.unit_number)
end

local function mark_network_dirty(network_key)
  if network_key then
    storage.dirty_networks[network_key] = true
  end
end

local function remove_member_from_network(network_key, unit_number)
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

local function add_member_to_network(network_key, unit_number)
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

local function set_requester_status(record, status)
  if record then
    record.status = status
  end
end

local function find_player_frame(player)
  return player.gui.relative[GUI_ROOT] or player.gui.left[GUI_ROOT]
end

local function destroy_player_frame(player)
  local frame = find_player_frame(player)
  if frame then
    frame.destroy()
  end
end

local function destroy_legacy_version_ui(player)
  if not player or not player.valid then
    return
  end

  local top_label = player.gui.top[VERSION_LABEL_NAME]
  if top_label and top_label.valid then
    top_label.destroy()
  end

  local frame = player.gui.left[VERSION_FRAME_NAME]
  if frame and frame.valid then
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

local function summarize_filter_counts(filters)
  local summary = {}
  for _, filter in ipairs(filters or {}) do
    local value = filter and filter.value or {}
    local name = value.name
    if name then
      local count = math.max(0, math.floor(filter.count or 0))
      summary[name] = (summary[name] or 0) + count
    end
  end
  return summary
end

local function get_logistic_delivery_metrics(entity, item_name)
  local on_the_way = 0
  local storage_count = 0

  if entity and entity.valid and is_requester(entity) then
    local requester_point = entity:get_requester_point()
    if requester_point and requester_point.valid then
      for _, delivery in ipairs(requester_point.targeted_items_deliver or {}) do
        if delivery.name == item_name then
          on_the_way = on_the_way + (delivery.count or 0)
        end
      end
    end

    local network = entity.logistic_network
    if network and network.valid then
      storage_count = network.get_item_count(item_name, "storage") or 0
    end
  end

  return on_the_way, storage_count
end

local function rebuild_request_tiles(frame, entity, desired_filters, applied_filters)
  local existing = frame[REQUESTS_LIST]
  if existing and existing.valid then
    existing.destroy()
  end

  local desired_summary = summarize_filter_counts(desired_filters)
  local applied_summary = summarize_filter_counts(applied_filters)
  local item_names = {}
  for item_name in pairs(desired_summary) do
    item_names[#item_names + 1] = item_name
  end
  for item_name in pairs(applied_summary) do
    if not desired_summary[item_name] then
      item_names[#item_names + 1] = item_name
    end
  end
  table.sort(item_names)

  local list = frame.add({type = "flow", name = REQUESTS_LIST, direction = "horizontal"})
  list.style.horizontally_stretchable = false
  list.style.vertically_stretchable = false

  for _, item_name in ipairs(item_names) do
    local desired_count = desired_summary[item_name] or 0
    local current_count = (entity and entity.valid) and entity.get_item_count(item_name) or 0
    local on_the_way, storage_count = get_logistic_delivery_metrics(entity, item_name)
    local prototype = prototypes.item[item_name]
    local item_title = prototype and prototype.localised_name or item_name
    local tile_size = 40
    local tile = list.add({
      type = "sprite-button",
      sprite = "item/" .. item_name,
      elem_tooltip = {type = "item", name = item_name},
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

local function update_player_gui(player)
  if not player or not player.valid then
    return
  end

  local player_state = storage.player_state[player.index]
  if not player_state then
    return
  end

  local frame = find_player_frame(player)
  if not frame then
    return
  end

  local record = storage.requesters[player_state.opened_unit_number]
  if not record or not record.entity.valid then
    frame.destroy()
    storage.player_state[player.index] = nil
    return
  end

  local priority_dropdown = find_descendant_by_name(frame, PRIORITY_DROPDOWN)
  local status_value = find_descendant_by_name(frame, STATUS_VALUE)
  if not priority_dropdown or not status_value then
    destroy_player_frame(player)
    create_or_update_gui(player, record.entity)
    frame = find_player_frame(player)
    if not frame then
      return
    end

    priority_dropdown = find_descendant_by_name(frame, PRIORITY_DROPDOWN)
    status_value = find_descendant_by_name(frame, STATUS_VALUE)
    if not priority_dropdown or not status_value then
      return
    end
  end

  local selected_index = get_priority_index_for_value(record.priority)
  if priority_dropdown.selected_index ~= selected_index then
    priority_dropdown.selected_index = selected_index
  end
  status_value.caption = {"fpr.status_" .. (record.status or "unknown")}
  rebuild_request_tiles(frame, record.entity, record.desired_filters, record.applied_filters)
end

local function update_all_open_guis()
  for player_index in pairs(storage.player_state) do
    update_player_gui(game.get_player(player_index))
  end
end

sum_filter_counts = function(filters)
  local total = 0
  for _, filter in ipairs(filters or {}) do
    total = total + math.max(0, math.floor(filter.count or 0))
  end
  return total
end

create_or_update_gui = function(player, entity)
  if not player or not player.valid then
    return
  end

  destroy_player_frame(player)

  if not is_requester(entity) then
    storage.player_state[player.index] = nil
    return
  end

  -- Ensure the opened chest is registered so update_player_gui does not tear down the frame.
  track_requester(entity)

  local frame = nil
  local anchored = pcall(function()
    frame = player.gui.relative.add({
      type = "frame",
      name = GUI_ROOT,
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
      name = GUI_ROOT,
      direction = "vertical",
      caption = {"fpr.frame_title"}
    })
  end

  frame.style.vertically_stretchable = false
  frame.style.horizontally_stretchable = false
  frame.style.minimal_width = PANEL_WIDTH
  frame.style.maximal_width = PANEL_WIDTH

  local priority_flow = frame.add({type = "flow", direction = "horizontal"})
  priority_flow.style.vertical_align = "center"
  priority_flow.add({type = "label", caption = {"fpr.priority_label"}})
  local dropdown_items = {}
  for _, level in ipairs(PRIORITY_LEVELS) do
    dropdown_items[#dropdown_items + 1] = tostring(level)
  end
  local priority_dropdown = priority_flow.add({
    type = "drop-down",
    name = PRIORITY_DROPDOWN,
    items = dropdown_items,
    selected_index = get_priority_index_for_value(5)
  })
  priority_dropdown.style.minimal_width = DROPDOWN_WIDTH
  priority_dropdown.style.maximal_width = DROPDOWN_WIDTH

  frame.add({type = "flow", name = REQUESTS_LIST, direction = "horizontal"})

  frame.add({type = "label", name = STATUS_VALUE, caption = {"fpr.status_unknown"}})

  storage.player_state[player.index] = {
    opened_unit_number = entity.unit_number
  }

  update_player_gui(player)
end

local function set_requester_enabled(entity, enabled)
  if not is_requester(entity) then
    return
  end

  local point = entity:get_requester_point()
  if point and point.valid then
    for _, section in pairs(point.sections or {}) do
      if section.valid and section.is_manual then
        if section.active ~= enabled then
          section.active = enabled
        end
      end
    end

    if point.enabled ~= enabled then
      point.enabled = enabled
    end
  end
end

local function get_supply_for_filter(network, filter_def)
  if not network or not network.valid then
    return 0
  end

  local value = filter_def and filter_def.value or nil
  if not value or value.type ~= "item" or not value.name then
    return 0
  end

  local item = {name = value.name}
  if value.quality then
    item.quality = value.quality
  end
  if value.comparator then
    item.comparator = value.comparator
  end

  local counts = network.get_supply_counts(item)
  if not counts then
    return 0
  end

  return (counts.storage or 0)
    + (counts["passive-provider"] or 0)
    + (counts.buffer or 0)
    + (counts["active-provider"] or 0)
end

local function normalize_filter_definition(filter)
  if not filter or not filter.name then
    return nil
  end

  local filter_type = filter.type or "item"
  if filter_type ~= "item" then
    return nil
  end

  local count = math.max(0, math.floor(filter.count or filter.min or 0))
  local value = {
    type = "item",
    name = filter.name
  }
  if filter.quality then
    value.quality = filter.quality
  end
  if filter.comparator then
    value.comparator = filter.comparator
  end

  return {
    value = value,
    count = count,
    minimum_delivery_count = filter.minimum_delivery_count,
    request_from = filter.request_from
  }
end

local function get_point_filter_definitions(point)
  local definitions = {}
  if not point or not point.valid then
    return definitions
  end

  local compiled = point.filters or {}
  table.sort(compiled, function(left, right)
    return (left.index or 0) < (right.index or 0)
  end)

  for _, filter in ipairs(compiled) do
    local definition = normalize_filter_definition(filter)
    if definition then
      definitions[#definitions + 1] = definition
    end
  end

  return definitions
end

local function copy_filter_definitions(source)
  local copy = {}
  for index, filter in ipairs(source or {}) do
    copy[index] = {
      value = {
        type = filter.value.type,
        name = filter.value.name,
        quality = filter.value.quality,
        comparator = filter.value.comparator
      },
      count = filter.count,
      minimum_delivery_count = filter.minimum_delivery_count,
      request_from = filter.request_from
    }
  end
  return copy
end

local function get_filter_definition_key(filter)
  local value = filter and filter.value or {}
  return table.concat({
    value.type or "",
    value.name or "",
    value.quality or "",
    value.comparator or "",
    filter.request_from or ""
  }, "|")
end

local function filter_definitions_equal(left, right)
  left = left or {}
  right = right or {}

  if #left ~= #right then
    return false
  end

  for index = 1, #left do
    local left_filter = left[index]
    local right_filter = right[index]
    if get_filter_definition_key(left_filter) ~= get_filter_definition_key(right_filter) then
      return false
    end
    if (left_filter.count or 0) ~= (right_filter.count or 0) then
      return false
    end
    if left_filter.minimum_delivery_count ~= right_filter.minimum_delivery_count then
      return false
    end
    if left_filter.request_from ~= right_filter.request_from then
      return false
    end
  end

  return true
end

local function get_entity_count_for_filter(entity, filter_def)
  local value = filter_def and filter_def.value or nil
  if not value or value.type ~= "item" or not value.name then
    return 0
  end

  if value.quality or value.comparator then
    local item = {
      name = value.name,
      quality = value.quality,
      comparator = value.comparator
    }
    return entity.get_item_count(item)
  end

  return entity.get_item_count(value.name)
end

local function get_targeted_count_for_filter(point, filter_def)
  if not point or not point.valid then
    return 0
  end

  local value = filter_def and filter_def.value or nil
  if not value or value.type ~= "item" or not value.name then
    return 0
  end

  local count = 0
  for _, stack in pairs(point.targeted_items_deliver or {}) do
    if stack.name == value.name then
      if not value.quality or stack.quality == value.quality then
        count = count + (stack.count or 0)
      end
    end
  end

  return count
end

local function legacy_counts_to_filter_definitions(counts)
  local definitions = {}
  local names = {}
  for name, count in pairs(counts or {}) do
    if count and count > 0 then
      names[#names + 1] = name
    end
  end

  table.sort(names)
  for _, name in ipairs(names) do
    definitions[#definitions + 1] = {
      value = {type = "item", name = name},
      count = math.max(0, math.floor(counts[name] or 0))
    }
  end

  return definitions
end

local function find_manual_sections(point)
  local sections = {}
  if not point or not point.valid then
    return sections
  end

  for _, section in pairs(point.sections or {}) do
    if section.valid and section.is_manual then
      sections[#sections + 1] = section
    end
  end

  if #sections == 0 and point.add_section then
    local created = point:add_section()
    if created and created.valid and created.is_manual then
      sections[1] = created
    end
  end

  return sections
end

local function apply_effective_requests(record, effective_filters)
  if not record or not record.entity.valid then
    return false
  end

  if filter_definitions_equal(record.applied_filters, effective_filters) then
    return true
  end

  local point = record.entity:get_requester_point()
  if not point or not point.valid then
    return false
  end

  local sections = find_manual_sections(point)
  if #sections == 0 then
    return false
  end

  local primary = sections[1]
  local filters = {}
  local applied_filters = {}
  for _, filter_def in ipairs(effective_filters or {}) do
    local count = math.max(0, math.floor(filter_def.count or 0))
    local logistic_filter = {
      value = {
        type = filter_def.value.type,
        name = filter_def.value.name,
        quality = filter_def.value.quality,
        comparator = filter_def.value.comparator
      },
      min = count,
      minimum_delivery_count = filter_def.minimum_delivery_count,
      request_from = filter_def.request_from
    }
    filters[#filters + 1] = logistic_filter
    applied_filters[#applied_filters + 1] = {
      value = {
        type = filter_def.value.type,
        name = filter_def.value.name,
        quality = filter_def.value.quality,
        comparator = filter_def.value.comparator
      },
      count = count,
      minimum_delivery_count = filter_def.minimum_delivery_count,
      request_from = filter_def.request_from
    }
  end

  record.applied_filters = applied_filters
  primary.filters = filters
  for index = 2, #sections do
    sections[index].filters = {}
  end

  return true
end

local function has_targeted_deliveries(point)
  if not point or not point.valid then
    return false
  end

  for _, stack in pairs(point.targeted_items_deliver or {}) do
    if stack.count and stack.count > 0 then
      return true
    end
  end

  return false
end

local function clean_requester(unit_number)
  local record = storage.requesters[unit_number]
  if not record then
    return
  end

  remove_member_from_network(record.network_key, unit_number)
  mark_network_dirty(record.network_key)
  storage.requesters[unit_number] = nil

  for player_index, player_state in pairs(storage.player_state) do
    if player_state.opened_unit_number == unit_number then
      local player = game.get_player(player_index)
      if player and player.valid then
        destroy_player_frame(player)
      end
      storage.player_state[player_index] = nil
    end
  end
end

track_requester = function(entity)
  if not is_requester(entity) then
    return
  end

  local unit_number = entity.unit_number
  local record = storage.requesters[unit_number]
  local previous_network_key = record and record.network_key or nil
  local network_key = get_network_key(entity, previous_network_key)

  if not record then
    local point = entity:get_requester_point()
    record = {
      entity = entity,
      priority = 5,
      enabled = true,
      status = "unknown",
      network_key = network_key,
      desired_filters = get_point_filter_definitions(point),
      applied_filters = nil
    }
    storage.requesters[unit_number] = record
  else
    record.entity = entity
    record.network_key = network_key
    if not record.desired_filters then
      if record.desired_requests then
        record.desired_filters = legacy_counts_to_filter_definitions(record.desired_requests)
        record.desired_requests = nil
      else
        local point = entity:get_requester_point()
        record.desired_filters = get_point_filter_definitions(point)
      end
    end

    if not record.applied_filters and record.applied_requests then
      record.applied_filters = legacy_counts_to_filter_definitions(record.applied_requests)
      record.applied_requests = nil
    end
  end

  if previous_network_key ~= network_key then
    remove_member_from_network(previous_network_key, unit_number)
    add_member_to_network(network_key, unit_number)
    mark_network_dirty(previous_network_key)
  end

  add_member_to_network(network_key, unit_number)
  mark_network_dirty(network_key)
end

local function adjust_priority(unit_number, delta)
  local record = storage.requesters[unit_number]
  if not record then
    return
  end

  record.priority = math.max(0, record.priority + delta)
  mark_network_dirty(record.network_key)
end

local function set_priority(unit_number, priority)
  local record = storage.requesters[unit_number]
  if not record then
    return
  end

  record.priority = math.max(0, math.floor(priority or 0))
  mark_network_dirty(record.network_key)
end

local function sort_records(records)
  table.sort(records, function(left, right)
    if left.priority == right.priority then
      return left.entity.unit_number < right.entity.unit_number
    end
    return left.priority > right.priority
  end)
end

local function reconcile_network(network_key)
  local members = storage.network_members[network_key]
  if not members then
    storage.dirty_networks[network_key] = nil
    return
  end

  local records = {}
  local network = nil
  local unit_numbers = {}

  for unit_number in pairs(members) do
    unit_numbers[#unit_numbers + 1] = unit_number
  end

  for _, unit_number in ipairs(unit_numbers) do
    local record = storage.requesters[unit_number]
    if not record or not record.entity.valid then
      clean_requester(unit_number)
    else
      local current_network_key = get_network_key(record.entity, record.network_key)
      if current_network_key ~= record.network_key then
        track_requester(record.entity)
      else
        table.insert(records, record)
        if not network then
          local point = record.entity:get_requester_point()
          if point and point.valid then
            network = point.logistic_network
          end
        end
      end
    end
  end

  if #records == 0 then
    storage.dirty_networks[network_key] = nil
    storage.network_members[network_key] = nil
    return
  end

  sort_records(records)
  local highest_priority = records[1] and records[1].priority or 0
  local remaining_supply = {}

  for _, record in ipairs(records) do
    local point = record.entity:get_requester_point()
    local desired_filters = record.desired_filters or {}
    local effective_filters = {}

    local has_any_desired = false
    local has_gross_missing = false
    local has_unallocated = false

    for _, desired_filter in ipairs(desired_filters) do
      local desired_count = math.max(0, math.floor(desired_filter.count or 0))
      if desired_count > 0 then
        has_any_desired = true

        local current = get_entity_count_for_filter(record.entity, desired_filter)
        local incoming = get_targeted_count_for_filter(point, desired_filter)
        local gross_missing = math.max(0, desired_count - current)
        local open_missing = math.max(0, gross_missing - incoming)

        if gross_missing > 0 then
          has_gross_missing = true
        end

        local key = get_filter_definition_key(desired_filter)
        if remaining_supply[key] == nil then
          remaining_supply[key] = get_supply_for_filter(network, desired_filter)
        end

        local available = remaining_supply[key] or 0
        local reserved_for_record = math.min(open_missing, available)
        remaining_supply[key] = math.max(0, available - reserved_for_record)

        local effective_count = desired_count
        if record.priority < highest_priority then
          effective_count = math.min(desired_count, current + incoming + reserved_for_record)
        end

        effective_filters[#effective_filters + 1] = {
          value = {
            type = desired_filter.value.type,
            name = desired_filter.value.name,
            quality = desired_filter.value.quality,
            comparator = desired_filter.value.comparator
          },
          count = effective_count,
          minimum_delivery_count = desired_filter.minimum_delivery_count,
          request_from = desired_filter.request_from
        }

        if effective_count < desired_count then
          has_unallocated = true
        end
      end
    end

    set_requester_enabled(record.entity, true)
    record.enabled = true
    apply_effective_requests(record, effective_filters)

    if not has_any_desired then
      set_requester_status(record, "no_requests")
    elseif not has_gross_missing then
      set_requester_status(record, "satisfied")
    elseif has_unallocated and not has_targeted_deliveries(point) then
      set_requester_status(record, "deferred")
    else
      set_requester_status(record, "active")
    end
  end

  storage.dirty_networks[network_key] = nil
end

local function reconcile_dirty_networks()
  for network_key in pairs(storage.dirty_networks) do
    reconcile_network(network_key)
  end

  update_all_open_guis()
end

local function register_existing_requesters()
  local existing_requesters = storage.requesters or {}

  storage.requesters = {}
  storage.network_members = {}
  storage.dirty_networks = {}

  for _, surface in pairs(game.surfaces) do
    for _, entity in pairs(surface.find_entities_filtered({type = "logistic-container"})) do
      if is_requester(entity) then
        track_requester(entity)

        local record = storage.requesters[entity.unit_number]
        local existing = existing_requesters[entity.unit_number]
        if record and existing then
          record.priority = existing.priority or record.priority
          if existing.desired_filters then
            record.desired_filters = copy_filter_definitions(existing.desired_filters)
          elseif existing.desired_requests then
            record.desired_filters = legacy_counts_to_filter_definitions(existing.desired_requests)
          end

          if existing.applied_filters then
            record.applied_filters = copy_filter_definitions(existing.applied_filters)
          elseif existing.applied_requests then
            record.applied_filters = legacy_counts_to_filter_definitions(existing.applied_requests)
          end
        end
      end
    end
  end
end

local function handle_built(event)
  track_requester(event.entity)

  local tags = event.tags
  local priority = tags and tags[PRIORITY_TAG_KEY]
  if priority ~= nil then
    local record = storage.requesters[event.entity.unit_number]
    if record then
      record.priority = math.max(0, math.floor(priority))
      mark_network_dirty(record.network_key)
    end
  end
end

local function handle_removed(event)
  if event.entity and event.entity.unit_number then
    clean_requester(event.entity.unit_number)
  end
end

local function handle_logistic_slot_changed(event)
  if not is_requester(event.entity) then
    return
  end

  local unit_number = event.entity.unit_number
  track_requester(event.entity)
  local record = storage.requesters[unit_number]
  if record then
    local point = event.entity:get_requester_point()
    local current_filters = get_point_filter_definitions(point)
    if filter_definitions_equal(current_filters, record.applied_filters) then
      return
    end

    record.desired_filters = current_filters
    record.applied_filters = nil
    mark_network_dirty(record.network_key)
  end
end

local function handle_setup_blueprint(event)
  local blueprint = event.stack
  local mapping = event.mapping and event.mapping.get()
  if not blueprint or not blueprint.valid_for_read or not mapping then
    return
  end

  for blueprint_index, source_entity in pairs(mapping) do
    if is_requester(source_entity) then
      local record = storage.requesters[source_entity.unit_number]
      if record then
        blueprint.set_blueprint_entity_tag(blueprint_index, PRIORITY_TAG_KEY, record.priority)
      end
    end
  end
end

local function handle_settings_pasted(event)
  if not is_requester(event.source) or not is_requester(event.destination) then
    return
  end

  track_requester(event.source)
  track_requester(event.destination)

  local source = storage.requesters[event.source.unit_number]
  local destination = storage.requesters[event.destination.unit_number]
  if source and destination then
    destination.priority = source.priority
    destination.desired_filters = copy_filter_definitions(source.desired_filters)
    destination.applied_filters = nil
    mark_network_dirty(destination.network_key)
  end
end

script.on_init(function()
  init_globals()
  register_existing_requesters()
  reconcile_dirty_networks()
  for _, player in pairs(game.players) do
    destroy_legacy_version_ui(player)
  end
end)

script.on_configuration_changed(function()
  init_globals()
  register_existing_requesters()
  reconcile_dirty_networks()
  for _, player in pairs(game.players) do
    destroy_legacy_version_ui(player)
  end
end)

script.on_event(defines.events.on_player_created, function(event)
  local player = game.get_player(event.player_index)
  destroy_legacy_version_ui(player)
end)

script.on_event(defines.events.on_player_joined_game, function(event)
  local player = game.get_player(event.player_index)
  destroy_legacy_version_ui(player)
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
  if event.entity and is_requester(event.entity) then
    track_requester(event.entity)
  end
  create_or_update_gui(player, event.entity)
end)

script.on_event(defines.events.on_gui_closed, function(event)
  local player = game.get_player(event.player_index)
  if not player or not player.valid then
    return
  end

  destroy_player_frame(player)
  storage.player_state[event.player_index] = nil
end)

script.on_event(defines.events.on_gui_selection_state_changed, function(event)
  local element = event.element
  if not element or not element.valid then
    return
  end

  if element.name ~= PRIORITY_DROPDOWN then
    return
  end

  local player_state = storage.player_state[event.player_index]
  if not player_state then
    return
  end

  local priority = PRIORITY_LEVELS[element.selected_index or 0]
  if priority == nil then
    return
  end

  set_priority(player_state.opened_unit_number, priority)
  reconcile_dirty_networks()
end)

script.on_event(defines.events.on_runtime_mod_setting_changed, function(event)
  if event.setting == "fpr-update-interval" then
    for network_key in pairs(storage.network_members) do
      mark_network_dirty(network_key)
    end
  end
end)

script.on_event(defines.events.on_tick, function(event)
  if event.tick % get_update_interval() ~= 0 then
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
        clean_requester(unit_number)
      else
        local current_network_key = get_network_key(record.entity, record.network_key)
        if current_network_key ~= record.network_key then
          track_requester(record.entity)
        else
          mark_network_dirty(current_network_key)
        end
      end
    end
  end

  reconcile_dirty_networks()
end)