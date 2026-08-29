-- Helpers for working with requester logistic filter definitions: normalizing
-- data read from the game, comparing/copying definitions, and computing supply.
local filters = {}

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

function filters.apply_effective_requests(record, effective_filters)
  if not record or not record.entity.valid then
    return false
  end

  if filters.filter_definitions_equal(record.applied_filters, effective_filters) then
    return true
  end

  local point = record.entity:get_requester_point()
  if not point or not point.valid then
    return false
  end

  local sections = filters.find_manual_sections(point)
  if #sections == 0 then
    return false
  end

  local primary = sections[1]
  local logistic_filters = {}
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
    logistic_filters[#logistic_filters + 1] = logistic_filter
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
  primary.filters = logistic_filters
  for index = 2, #sections do
    sections[index].filters = {}
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
