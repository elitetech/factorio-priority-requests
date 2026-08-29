-- Per-network reconciliation: decides how much of each chest's request is currently
-- "effective" based on priority order and remaining shared logistic supply.
local filters = require("scripts.filters")
local requester = require("scripts.requester")
local gui = require("scripts.gui")

local reconcile = {}

local function set_requester_status(record, status)
  if record then
    record.status = status
  end
end

local function sort_records(records)
  table.sort(records, function(left, right)
    if left.priority == right.priority then
      return left.entity.unit_number < right.entity.unit_number
    end
    return left.priority > right.priority
  end)
end

function reconcile.reconcile_network(network_key)
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
      requester.clean_requester(unit_number)
    else
      local current_network_key = requester.get_network_key(record.entity, record.network_key)
      if current_network_key ~= record.network_key then
        requester.track_requester(record.entity)
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

        local current = filters.get_entity_count_for_filter(record.entity, desired_filter)
        local incoming = filters.get_targeted_count_for_filter(point, desired_filter)
        local gross_missing = math.max(0, desired_count - current)
        local open_missing = math.max(0, gross_missing - incoming)

        if gross_missing > 0 then
          has_gross_missing = true
        end

        local key = filters.get_filter_definition_key(desired_filter)
        if remaining_supply[key] == nil then
          remaining_supply[key] = filters.get_supply_for_filter(network, desired_filter)
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

    filters.apply_effective_requests(record, effective_filters)

    if not has_any_desired then
      set_requester_status(record, "no_requests")
    elseif not has_gross_missing then
      set_requester_status(record, "satisfied")
    elseif has_unallocated and not filters.has_targeted_deliveries(point) then
      set_requester_status(record, "deferred")
    else
      set_requester_status(record, "active")
    end
  end

  storage.dirty_networks[network_key] = nil
end

function reconcile.reconcile_dirty_networks()
  -- Snapshot the dirty keys before reconciling: reconcile_network() can mark other
  -- networks dirty again (e.g. via track_requester when a chest's network changes),
  -- and inserting new keys into a table while pairs() is traversing it is undefined
  -- behavior in Lua. Any network dirtied as a side effect here is picked up on the
  -- next pass (direct event or periodic on_tick re-mark).
  local network_keys = {}
  for network_key in pairs(storage.dirty_networks) do
    network_keys[#network_keys + 1] = network_key
  end

  for _, network_key in ipairs(network_keys) do
    reconcile.reconcile_network(network_key)
  end

  gui.update_all_open_guis()
end

return reconcile
