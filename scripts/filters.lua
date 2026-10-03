-- Helpers for working with requester logistic filter definitions: normalizing
-- data read from the game, comparing/copying definitions, and computing supply.
local filters = {}

filters.LEGACY_CIRCUIT_OFFSET_GROUP = "priority-requests:circuit-offset"
filters.OFFSET_GROUP_PREFIX = "priority-requests:offset:"

function filters.get_offset_group_name(unit_number)
  return string.format("%s%d", filters.OFFSET_GROUP_PREFIX, unit_number or 0)
end

function filters.is_offset_group_name(group)
  if not group then
    return false
  end

  return group == filters.LEGACY_CIRCUIT_OFFSET_GROUP
    or string.sub(group, 1, #filters.OFFSET_GROUP_PREFIX) == filters.OFFSET_GROUP_PREFIX
end

function filters.cleanup_unused_logistic_group(force, group_name)
  if not force or not force.valid or not group_name or group_name == "" then
    return false
  end

  local group = force.get_logistic_group(group_name, defines.logistic_group_type.with_trash)
  if not group then
    return false
  end

  if #(group.members or {}) > 0 then
    return false
  end

  force.delete_logistic_group(group_name, defines.logistic_group_type.with_trash)
  return true
end

function filters.cleanup_offset_sections_for_entity(entity, unit_number)
  if not entity or not entity.valid or not entity.get_requester_point then
    return
  end

  local point = entity:get_requester_point()
  if not point or not point.valid then
    return
  end

  local groups_to_cleanup = {}
  local primary_group = filters.get_offset_group_name(unit_number or entity.unit_number)
  groups_to_cleanup[primary_group] = true
  groups_to_cleanup[filters.LEGACY_CIRCUIT_OFFSET_GROUP] = true

  local section_indexes = {}
  for _, section in pairs(point.sections or {}) do
    if section.valid and section.is_manual and groups_to_cleanup[section.group] then
      section_indexes[#section_indexes + 1] = section.index
    end
  end

  table.sort(section_indexes, function(left, right)
    return left > right
  end)

  for _, section_index in ipairs(section_indexes) do
    local removed = point.remove_section(section_index)
    if not removed then
      local section = point.get_section(section_index)
      if section and section.valid and section.is_manual then
        section.filters = {}
        section.group = ""
      end
    end
  end

  local force = point.force
  for group_name in pairs(groups_to_cleanup) do
    filters.cleanup_unused_logistic_group(force, group_name)
  end
end

function filters.cleanup_orphaned_offset_groups()
  for _, force in pairs(game.forces or {}) do
    local groups = force.get_logistic_groups(defines.logistic_group_type.with_trash) or {}
    for _, group_name in ipairs(groups) do
      if filters.is_offset_group_name(group_name) then
        filters.cleanup_unused_logistic_group(force, group_name)
      end
    end
  end
end

function filters.get_supply_for_filter(network, filter_def)
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

function filters.normalize_filter_definition(filter)
  if not filter then
    return nil
  end

  local value = filter.value or filter
  local filter_name = filter.name or value.name
  if not filter_name then
    return nil
  end

  local filter_type = filter.type or value.type or "item"
  if filter_type ~= "item" then
    return nil
  end

  local count = math.max(0, math.floor(filter.count or filter.min or 0))
  local normalized_value = {
    type = "item",
    name = filter_name
  }
  if filter.quality or value.quality then
    normalized_value.quality = filter.quality or value.quality
  end
  if filter.comparator or value.comparator then
    normalized_value.comparator = filter.comparator or value.comparator
  end

  return {
    value = normalized_value,
    count = count,
    minimum_delivery_count = filter.minimum_delivery_count,
    request_from = filter.request_from
  }
end

function filters.get_point_filter_definitions(point)
  local definitions = {}
  if not point or not point.valid then
    return definitions
  end

  local compiled = point.filters or {}
  table.sort(compiled, function(left, right)
    return (left.index or 0) < (right.index or 0)
  end)

  for _, filter in ipairs(compiled) do
    local definition = filters.normalize_filter_definition(filter)
    if definition then
      definitions[#definitions + 1] = definition
    end
  end

  return definitions
end

function filters.copy_filter_definitions(source)
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

function filters.get_filter_definition_key(filter)
  local value = filter and filter.value or {}
  return table.concat({
    value.type or "",
    value.name or "",
    value.quality or "",
    value.comparator or "",
    filter.request_from or ""
  }, "|")
end

function filters.filter_definitions_equal(left, right)
  left = left or {}
  right = right or {}

  if #left ~= #right then
    return false
  end

  for index = 1, #left do
    local left_filter = left[index]
    local right_filter = right[index]
    if filters.get_filter_definition_key(left_filter) ~= filters.get_filter_definition_key(right_filter) then
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

function filters.get_entity_count_for_filter(entity, filter_def)
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

function filters.get_targeted_count_for_filter(point, filter_def)
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

function filters.legacy_counts_to_filter_definitions(counts)
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

function filters.find_manual_sections(point)
  local sections = {}
  if not point or not point.valid then
    return sections
  end

  local total_sections = 0
  for _, section in pairs(point.sections or {}) do
    total_sections = total_sections + 1
    -- Exclude our own circuit-offset section: it's manual too, but it's not the section
    -- the player edits in the GUI. Including it here could pick it as the "primary"
    -- section to write effective requests into (leaving the player's real section
    -- untouched), or double-count filters additively across both sections.
    if section.valid and section.is_manual and not filters.is_offset_group_name(section.group) then
      sections[#sections + 1] = section
    end
  end

  -- Only auto-create a section when the point has none at all. If it already has a
  -- non-manual (circuit-controlled) section, adding a manual one alongside it would
  -- request items on top of what the circuit network is already requesting instead
  -- of replacing it, since circuit-controlled sections can't be written to or removed.
  if #sections == 0 and total_sections == 0 then
    local ok, created = pcall(function() return point.add_section() end)
    if ok and created and created.valid and created.is_manual then
      sections[1] = created
    end
  end

  return sections
end

-- Whether this logistic point has at least one circuit-controlled section. A point can
-- have several sections/groups at once, some manual and some circuit-controlled (e.g. the
-- player left the default manual group empty but enabled circuit control on another
-- group), so this can't require ALL sections to be non-manual -- that would miss any
-- point that also happens to have a real (player-configured) manual section alongside a
-- circuit-controlled one. Circuit-controlled sections' filters are read-only, so effective
-- (priority-capped) counts can't be written to them the way they can for manual sections.
function filters.has_circuit_controlled_section(point)
  if not point or not point.valid then
    return false
  end

  for _, section in pairs(point.sections or {}) do
    -- Our own offset section is manual, so it never matches "not section.is_manual" here
    -- and doesn't need to be explicitly excluded.
    if section.valid and not section.is_manual then
      return true
    end
  end

  return false
end

-- Group name for the dedicated manual section this mod uses to throttle circuit-controlled
-- requester points. Logistic sections combine additively per item, and LogisticFilter.min
-- accepts negative values, so writing a negative min here offsets (reduces) the amount the
-- circuit network is requesting for that item without touching the read-only circuit section.
function filters.find_offset_section(point, offset_group, create)
  if not point or not point.valid then
    return nil
  end

  offset_group = offset_group or filters.LEGACY_CIRCUIT_OFFSET_GROUP
  local empty_manual_section = nil
  local has_circuit_controlled = false
  for _, section in pairs(point.sections or {}) do
    if section.valid and section.is_manual then
      if section.group == offset_group then
        return section
      end
      if section.group == filters.LEGACY_CIRCUIT_OFFSET_GROUP then
        section.group = offset_group
        return section
      end
      if not empty_manual_section and section.filters_count == 0 then
        empty_manual_section = section
      end
    elseif section.valid and not section.is_manual then
      has_circuit_controlled = true
    end
  end

  if not create then
    return nil
  end

  -- Some points with circuit-controlled sections appear to cap section count and can
  -- reject add_section() once existing sections are present. For those, reuse an empty
  -- manual section if available. For normal manual requesters, never hijack an existing
  -- empty manual section: always create a dedicated new section.
  if has_circuit_controlled and empty_manual_section then
    empty_manual_section.group = offset_group
    return empty_manual_section
  end

  local ok, created = pcall(function() return point.add_section() end)
  if ok and created and created.valid and created.is_manual then
    created.group = offset_group
    return created
  end

  return nil
end

function filters.get_desired_filter_definitions(point, unit_number)
  if not point or not point.valid then
    return {}
  end

  local offset_group = filters.get_offset_group_name(unit_number)
  local definitions = {}
  local section_count = 0

  for _, section in pairs(point.sections or {}) do
    if section and section.valid then
      section_count = section_count + 1
      if section.group ~= offset_group and not filters.is_offset_group_name(section.group) then
        local section_filters = section.filters or {}
        table.sort(section_filters, function(left, right)
          return (left.index or 0) < (right.index or 0)
        end)

        for _, filter in ipairs(section_filters) do
          local definition = filters.normalize_filter_definition(filter)
          if definition then
            definitions[#definitions + 1] = definition
          end
        end
      end
    end
  end

  if section_count == 0 then
    return filters.get_point_filter_definitions(point)
  end

  return definitions
end

function filters.apply_circuit_offsets(record, effective_filters, offset_filters)
  if not record or not record.entity.valid then
    return false
  end

  -- Unlike apply_effective_requests, this always rewrites: reconcile.lua clears the
  -- offset section every pass before recomputing (to read the raw circuit-driven
  -- demand), so skipping the write here based on a stale "already applied" comparison
  -- would leave the section empty instead of restoring the correct offset.
  local point = record.entity:get_requester_point()
  if not point or not point.valid then
    return false
  end

  local offset_group = filters.get_offset_group_name(record.entity.unit_number)
  local has_offsets = offset_filters and #offset_filters > 0
  local section = filters.find_offset_section(point, offset_group, has_offsets)
  if not section and has_offsets then
    return false
  end

  local logistic_filters = {}
  for _, offset in ipairs(offset_filters or {}) do
    logistic_filters[#logistic_filters + 1] = {
      value = {
        type = offset.value.type,
        name = offset.value.name,
        quality = offset.value.quality,
        comparator = offset.value.comparator
      },
      min = offset.min
    }
  end

  local applied_filters = {}
  for _, filter_def in ipairs(effective_filters or {}) do
    applied_filters[#applied_filters + 1] = {
      value = {
        type = filter_def.value.type,
        name = filter_def.value.name,
        quality = filter_def.value.quality,
        comparator = filter_def.value.comparator
      },
      count = filter_def.count,
      minimum_delivery_count = filter_def.minimum_delivery_count,
      request_from = filter_def.request_from
    }
  end
  -- Update record.applied_filters before performing the actual write below: the write can
  -- synchronously raise on_entity_logistic_slot_changed (fired for script-driven changes
  -- too), and that handler compares the point's current filters against applied_filters to
  -- tell our own writes apart from real edits. Updating applied_filters first ensures that
  -- comparison sees the new value already in place instead of a stale one.
  record.applied_filters = applied_filters

  if section then
    section.filters = logistic_filters
  end

  return true
end

function filters.apply_effective_requests(record, effective_filters)
  if not record or not record.entity.valid then
    return false
  end

  local point = record.entity:get_requester_point()
  if not point or not point.valid then
    return false
  end

  local effective_by_key = {}
  for _, filter_def in ipairs(effective_filters or {}) do
    local key = filters.get_filter_definition_key(filter_def)
    effective_by_key[key] = math.max(0, math.floor(filter_def.count or 0))
  end

  local offset_filters = {}
  for _, desired_filter in ipairs(record.desired_filters or {}) do
    local desired_count = math.max(0, math.floor(desired_filter.count or 0))
    if desired_count > 0 then
      local key = filters.get_filter_definition_key(desired_filter)
      local effective_count = effective_by_key[key] or 0
      if effective_count < desired_count then
        offset_filters[#offset_filters + 1] = {
          value = {
            type = desired_filter.value.type,
            name = desired_filter.value.name,
            quality = desired_filter.value.quality,
            comparator = desired_filter.value.comparator
          },
          min = effective_count - desired_count
        }
      end
    end
  end

  local offset_group = filters.get_offset_group_name(record.entity.unit_number)
  local has_offsets = #offset_filters > 0
  local section = filters.find_offset_section(point, offset_group, true)
  if not section and has_offsets then
    return false
  end

  local logistic_filters = {}
  local applied_filters = {}
  for _, filter_def in ipairs(effective_filters or {}) do
    local count = math.max(0, math.floor(filter_def.count or 0))
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

  for _, offset in ipairs(offset_filters) do
    logistic_filters[#logistic_filters + 1] = {
      value = {
        type = offset.value.type,
        name = offset.value.name,
        quality = offset.value.quality,
        comparator = offset.value.comparator
      },
      min = offset.min
    }
  end

  record.applied_filters = applied_filters
  if section then
    section.filters = logistic_filters
  end

  return true
end

function filters.has_targeted_deliveries(point)
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

function filters.sum_filter_counts(filter_list)
  local total = 0
  for _, filter in ipairs(filter_list or {}) do
    total = total + math.max(0, math.floor(filter.count or 0))
  end
  return total
end

return filters
