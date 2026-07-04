-- Fleet Commander
-- control.lua
-- Targets Factorio 2.1 (Space Age).
--
-- Headless space-platform fleet automation. No GUI, no sprites, no player
-- interaction required. Everything here runs off event hooks so the mod
-- costs effectively nothing on ticks where nothing relevant happens.
--
-- Core idea:
--   * A platform's name is parsed into a text "prefix" and a trailing
--     integer, e.g. "Cargo 12" -> prefix "Cargo", number 12.
--   * All platforms sharing a prefix form a "fleet". The platform numbered
--     1 is the fleet's Leader; every other member is a Follower.
--   * The Leader's schedule, logistics requests, and physical build
--     (captured as a blueprint) are mirrored onto every Follower.
--   * Newly created platforms are auto-named into the default "Cargo"
--     fleet and synced to that fleet's Leader, if one exists.
--
-- PERFORMANCE DESIGN: a full fleet sync walks every platform in the
-- universe and can write a lot of state (schedule + requests + a
-- blueprint stamp) per Follower, so we never want that bunched up or
-- triggered from a high-frequency event. Instead:
--   * A brand-new platform is detected and onboarded within one second
--     (see "New platform detection" below), and being caught red-handed
--     editing a Follower (on_gui_closed) is corrected immediately -- but
--     both only ever touch that ONE platform, no fleet-wide scan.
--   * Routine "did the Leader's stuff change" propagation is handled by
--     a round-robin scheduler: once per second we sync exactly ONE
--     fleet's Leader -> Followers, then move on to the next fleet next
--     second. With N fleets, each one is refreshed roughly every N
--     seconds, but no single tick ever pays for more than one fleet's
--     worth of writes.

local util = require("util")

local DEFAULT_FLEET_PREFIX = "Cargo"
local TICK_INTERVAL = 60 -- once per second at 60 UPS

-- A generous fixed capture area for blueprinting a platform's build.
-- CAVEAT: the runtime API has no documented getter for a space platform
-- surface's actual used bounds, so this assumes every platform's build
-- fits within +/-128 tiles of its hub (the hub is placed at/near a
-- platform surface's origin when the platform is created). Verify
-- in-game with very large platforms and enlarge if entities near the
-- edge get clipped from the captured blueprint.
local PLATFORM_CAPTURE_AREA = { { -128, -128 }, { 128, 128 } }

-- The hub's logistic "requester" point, confirmed via
-- defines.logistic_member_index.space_platform_hub_requester
-- (https://lua-api.factorio.com/latest/defines.html#logistic_member_index).
local HUB_REQUESTER_INDEX = defines.logistic_member_index.space_platform_hub_requester

-- ---------------------------------------------------------------------
-- Name parsing
-- ---------------------------------------------------------------------

--- Splits a platform name into a text prefix and a trailing integer.
-- Uses a non-greedy match so "Cargo 10" and "Cargo 100" both parse
-- correctly, and tonumber() so "10" > "2" numerically (not lexically).
-- @param name string the platform's current name
-- @return string|nil prefix, number|nil trailing_number
local function parse_platform_name(name)
  if not name or name == "" then
    return nil, nil
  end

  local prefix, number_str = string.match(name, "^(.-)%s*(%d+)$")
  if not prefix or prefix == "" or not number_str then
    return nil, nil
  end

  return prefix, tonumber(number_str)
end

-- ---------------------------------------------------------------------
-- Platform iteration helpers
-- ---------------------------------------------------------------------

--- Calls fn(platform) for every valid space platform belonging to every
-- force in the game. Space platforms are owned per-force, so there is no
-- single flat "all platforms" list -- we have to walk game.forces.
local function for_each_platform(fn)
  for _, force in pairs(game.forces) do
    if force.platforms then
      for _, platform in pairs(force.platforms) do
        if platform and platform.valid then
          fn(platform)
        end
      end
    end
  end
end

--- Finds the Leader (number == 1) of the given fleet prefix, if any.
-- @param prefix string
-- @return LuaSpacePlatform|nil
local function find_leader(prefix)
  local leader = nil
  for_each_platform(function(platform)
    if not leader then
      local p_prefix, p_number = parse_platform_name(platform.name)
      if p_prefix == prefix and p_number == 1 then
        leader = platform
      end
    end
  end)
  return leader
end

--- Finds the highest follower number currently in use for a prefix.
-- Returns 0 if the fleet doesn't exist yet, so callers can safely do
-- highest + 1 to get the next available slot.
-- @param prefix string
-- @return number highest_number
local function find_highest_number(prefix)
  local highest = 0
  for_each_platform(function(platform)
    local p_prefix, p_number = parse_platform_name(platform.name)
    if p_prefix == prefix and p_number and p_number > highest then
      highest = p_number
    end
  end)
  return highest
end

-- ---------------------------------------------------------------------
-- Storage
-- ---------------------------------------------------------------------

--- Initializes persistent mod state. Safe to call multiple times.
local function init_storage()
  -- Cache of each fleet's last-known Leader schedule/requests/blueprint,
  -- keyed by prefix. This lets a Follower snap into formation even if
  -- the Leader isn't reachable at that exact moment (see Empty Fleet
  -- Protection below).
  storage.leader_schedules = storage.leader_schedules or {}
  storage.leader_requests = storage.leader_requests or {}
  storage.leader_blueprints = storage.leader_blueprints or {}

  -- Round-robin queue of fleet prefixes for the periodic sync below, plus
  -- a cursor into it. Rebuilt from scratch whenever it runs dry.
  storage.sync_queue = storage.sync_queue or {}
  storage.sync_queue_index = storage.sync_queue_index or 1

  -- Tracks which platforms this mod has already seen, so the periodic
  -- new-platform scan below only onboards each platform once.
  local first_time = storage.known_platforms == nil
  storage.known_platforms = storage.known_platforms or {}
  if first_time then
    -- Anything that already exists the first time this mod runs (e.g.
    -- it was added to an existing save) is left exactly as-is -- only
    -- platforms created AFTER this point get auto-named/onboarded. This
    -- avoids surprise mass-renames of a fleet the player already set up
    -- by hand before installing the mod.
    for_each_platform(function(platform)
      storage.known_platforms[platform.index] = true
    end)
  end
end

script.on_init(init_storage)
script.on_configuration_changed(init_storage)

--- Generic deep structural equality check via JSON round-trip, used to
-- avoid pointless re-applies (and re-triggering follow-on logic) when a
-- captured snapshot hasn't actually changed.
local function deep_equal(a, b)
  if a == nil and b == nil then
    return true
  end
  if a == nil or b == nil then
    return false
  end
  return helpers.table_to_json(a) == helpers.table_to_json(b)
end

-- ---------------------------------------------------------------------
-- Schedule sync
-- ---------------------------------------------------------------------
-- API ACCURACY NOTE: `LuaSpacePlatform.schedule` is documented as a
-- *simplified* view (just `current` + `records`) that silently drops
-- interrupts. To copy a schedule with full fidelity -- including any
-- interrupts a player has set up -- we go through `platform:get_schedule()`,
-- which returns a live `LuaSchedule` handle exposing both records and
-- interrupts via get_records()/set_records() and get_interrupts()/
-- set_interrupts().
-- Confirmed: https://lua-api.factorio.com/latest/classes/LuaSpacePlatform.html
--            https://lua-api.factorio.com/latest/classes/LuaSchedule.html

--- Snapshots a platform's full schedule (records + interrupts).
-- @param platform LuaSpacePlatform
-- @return table|nil {records = array[ScheduleRecord], interrupts = array[ScheduleInterrupt]}
local function capture_schedule(platform)
  local schedule = platform.get_schedule()
  if not schedule then
    return nil
  end
  return {
    records = util.table.deepcopy(schedule.get_records() or {}),
    interrupts = util.table.deepcopy(schedule.get_interrupts() or {}),
  }
end

--- Applies a previously captured schedule snapshot onto a platform.
-- Interrupts are set first since ScheduleInterrupt entries carry their
-- own target records independently of the main record list.
-- @param platform LuaSpacePlatform
-- @param snapshot table {records=..., interrupts=...}
local function apply_schedule(platform, snapshot)
  local schedule = platform.get_schedule()
  if not schedule or not snapshot then
    return
  end
  schedule.set_interrupts(util.table.deepcopy(snapshot.interrupts))
  schedule.set_records(util.table.deepcopy(snapshot.records))
end

-- ---------------------------------------------------------------------
-- Logistics requests sync
-- ---------------------------------------------------------------------
-- The hub's item requests (including the per-request "request from"
-- planet/platforms/all source and a specific import location) live on
-- the hub entity's requester LuaLogisticPoint, as a set of
-- LuaLogisticSection records.
-- Confirmed: https://lua-api.factorio.com/latest/classes/LuaLogisticPoint.html
--            https://lua-api.factorio.com/latest/classes/LuaLogisticSection.html
--            https://lua-api.factorio.com/latest/concepts/LogisticFilter.html
--            https://lua-api.factorio.com/latest/concepts/RequestFromLocation.html
--            https://lua-api.factorio.com/latest/defines.html#logistic_member_index

-- TODO(unconfirmed API): Factorio 2.1.9's runtime API has no read/write
-- field for the hub's "Provide items to other platforms" checkbox. It
-- only exists as `providing_to_other_platforms` on the *blueprint
-- export* format (BlueprintEntity) -- there is an open, unresolved
-- Factorio forum feature request asking Wube to expose a live
-- LuaEntity/LuaSpacePlatform field for it. Until that lands, this
-- setting cannot be read or synced from script. Verify by checking
-- https://lua-api.factorio.com/latest/classes/LuaEntity.html and
-- https://lua-api.factorio.com/latest/classes/LuaSpacePlatform.html
-- for a new field before attempting to wire this up.

--- Snapshots every logistic request section on a platform's hub.
-- @param platform LuaSpacePlatform
-- @return table|nil array of {group, active, multiplier, filters}
local function capture_requests(platform)
  local hub = platform.hub
  if not hub or not hub.valid then
    return nil
  end

  local point = hub.get_logistic_point(HUB_REQUESTER_INDEX)
  if not point then
    return nil
  end

  local sections = {}
  for i = 1, point.sections_count do
    local section = point.get_section(i)
    if section then
      table.insert(sections, {
        group = section.group,
        active = section.active,
        multiplier = section.multiplier,
        filters = util.table.deepcopy(section.filters or {}),
      })
    end
  end
  return sections
end

--- Replaces every logistic request section on a platform's hub with the
-- given snapshot. Existing sections are torn down first so requests
-- removed on the Leader also disappear from Followers.
-- @param platform LuaSpacePlatform
-- @param snapshot table array of {group, active, multiplier, filters}
local function apply_requests(platform, snapshot)
  if not snapshot then
    return
  end

  local hub = platform.hub
  if not hub or not hub.valid then
    return
  end

  local point = hub.get_logistic_point(HUB_REQUESTER_INDEX)
  if not point then
    return
  end

  for i = point.sections_count, 1, -1 do
    point.remove_section(i)
  end

  for _, section_data in ipairs(snapshot) do
    local section = point.add_section(section_data.group)
    if section then
      section.active = section_data.active
      section.multiplier = section_data.multiplier
      section.filters = util.table.deepcopy(section_data.filters)
    end
  end
end

-- ---------------------------------------------------------------------
-- Physical build ("blueprint") sync
-- ---------------------------------------------------------------------
-- There is no "hub blueprint" object in the runtime API -- platforms are
-- built from ordinary ghost entities/tiles placed on their surface, which
-- the hub auto-constructs and auto-requests materials for. To mirror a
-- Leader's physical layout onto a Follower we capture the Leader's
-- surface into a normal blueprint item, strip out the hub itself (each
-- platform already has exactly one, fixed, undeletable hub -- including
-- it would make build_blueprint try to place a second one), and stamp
-- the result onto the Follower's surface as ghosts.
-- Confirmed: https://lua-api.factorio.com/latest/classes/LuaItemStack.html
--   (create_blueprint / build_blueprint / get_blueprint_entities /
--    set_blueprint_entities / get_blueprint_tiles / set_blueprint_tiles)

--- Snapshots a platform's physical build (entities + tiles) as
-- blueprint data, using a throwaway script inventory as scratch space.
-- @param platform LuaSpacePlatform
-- @return table|nil {entities = array[BlueprintEntity], tiles = array[Tile]}
local function capture_blueprint(platform)
  local scratch = game.create_inventory(1)
  local stack = scratch[1]
  stack.set_stack({ name = "blueprint" })

  stack.create_blueprint({
    surface = platform.surface,
    force = platform.force,
    area = PLATFORM_CAPTURE_AREA,
    always_include_tiles = true,
  })

  local entities = stack.get_blueprint_entities() or {}
  local filtered_entities = {}
  for _, entity_data in pairs(entities) do
    if entity_data.name ~= "space-platform-hub" then
      table.insert(filtered_entities, entity_data)
    end
  end
  local tiles = stack.get_blueprint_tiles() or {}

  scratch.destroy()

  if #filtered_entities == 0 and #tiles == 0 then
    return nil
  end

  return {
    entities = util.table.deepcopy(filtered_entities),
    tiles = util.table.deepcopy(tiles),
  }
end

--- Stamps a previously captured blueprint snapshot onto a platform's
-- surface. Entities the platform can't yet afford are placed as ghosts,
-- which the platform's own auto-construction then requests materials
-- for and builds -- the same behavior as a player placing a blueprint.
-- @param platform LuaSpacePlatform
-- @param snapshot table {entities=..., tiles=...}
local function apply_blueprint(platform, snapshot)
  if not snapshot then
    return
  end

  local scratch = game.create_inventory(1)
  local stack = scratch[1]
  stack.set_stack({ name = "blueprint" })
  stack.set_blueprint_entities(util.table.deepcopy(snapshot.entities))
  stack.set_blueprint_tiles(util.table.deepcopy(snapshot.tiles))

  stack.build_blueprint({
    surface = platform.surface,
    force = platform.force,
    position = { 0, 0 },
    force_build = true,
  })

  scratch.destroy()
end

-- ---------------------------------------------------------------------
-- Fleet sync orchestration
-- ---------------------------------------------------------------------

--- Applies a single captured aspect (schedule/requests/blueprint) from a
-- Leader snapshot onto one Follower, but only if it actually differs.
-- @return boolean true if anything was changed on the Follower
local function sync_aspect(follower, leader_snapshot, capture_fn, apply_fn)
  if not leader_snapshot then
    return false
  end
  local follower_snapshot = capture_fn(follower)
  if deep_equal(follower_snapshot, leader_snapshot) then
    return false
  end
  apply_fn(follower, leader_snapshot)
  return true
end

--- Full fleet sync: captures the Leader's schedule/requests/blueprint,
-- caches them for the prefix, and pushes them to every Follower (number
-- > 1) sharing the prefix. This walks every platform in the universe, so
-- callers should only invoke it for one fleet at a time -- see the
-- performance note at the top of this file.
-- @param prefix string the fleet's text prefix
-- @param leader LuaSpacePlatform the fleet's Leader platform
-- @return boolean true if any Follower was actually changed
local function sync_fleet(prefix, leader)
  if not leader or not leader.valid then
    return false
  end

  local leader_schedule = capture_schedule(leader)
  local leader_requests = capture_requests(leader)
  local leader_blueprint = capture_blueprint(leader)

  storage.leader_schedules[prefix] = leader_schedule
  storage.leader_requests[prefix] = leader_requests
  storage.leader_blueprints[prefix] = leader_blueprint

  local followers_changed = 0
  for_each_platform(function(platform)
    if platform ~= leader then
      local p_prefix, p_number = parse_platform_name(platform.name)
      if p_prefix == prefix and p_number and p_number > 1 then
        local a = sync_aspect(platform, leader_schedule, capture_schedule, apply_schedule)
        local b = sync_aspect(platform, leader_requests, capture_requests, apply_requests)
        local c = sync_aspect(platform, leader_blueprint, capture_blueprint, apply_blueprint)
        if a or b or c then
          followers_changed = followers_changed + 1
        end
      end
    end
  end)

  if followers_changed > 0 then
    log(string.format(
      "[Fleet Commander] Synced fleet '%s' from leader '%s' to %d follower(s).",
      prefix, leader.name, followers_changed
    ))
  end

  return followers_changed > 0
end

--- Immediately brings ONE Follower into line, without scanning the rest
-- of the fleet. Used for a brand-new ship joining formation, and for
-- snapping a single drifted Follower back after a manual edit.
-- If a live Leader is available its current state is captured (and the
-- cache refreshed); otherwise falls back to the last cached snapshot,
-- which is what makes Empty Fleet Protection work -- a Follower created
-- before "Cargo 1" exists simply has nothing to apply and stays
-- independent.
-- @param follower LuaSpacePlatform
-- @param leader LuaSpacePlatform|nil
-- @param prefix string
-- @return boolean true if anything was changed on the Follower
local function onboard_or_correct_follower(follower, leader, prefix)
  local leader_schedule, leader_requests, leader_blueprint

  if leader and leader.valid then
    leader_schedule = capture_schedule(leader)
    leader_requests = capture_requests(leader)
    leader_blueprint = capture_blueprint(leader)
    storage.leader_schedules[prefix] = leader_schedule
    storage.leader_requests[prefix] = leader_requests
    storage.leader_blueprints[prefix] = leader_blueprint
  else
    leader_schedule = storage.leader_schedules[prefix]
    leader_requests = storage.leader_requests[prefix]
    leader_blueprint = storage.leader_blueprints[prefix]
  end

  local changed = false
  if sync_aspect(follower, leader_schedule, capture_schedule, apply_schedule) then
    changed = true
  end
  if sync_aspect(follower, leader_requests, capture_requests, apply_requests) then
    changed = true
  end
  if sync_aspect(follower, leader_blueprint, capture_blueprint, apply_blueprint) then
    changed = true
  end
  return changed
end

-- ---------------------------------------------------------------------
-- New platform detection
-- ---------------------------------------------------------------------
-- CRITICAL COMPATIBILITY NOTE: there is no dedicated "platform created"
-- event. `defines.events.on_space_platform_created` does not exist in
-- the real API (confirmed against
-- https://lua-api.factorio.com/latest/events.html) -- registering it
-- crashes the mod at load since the field is nil. An earlier version of
-- this mod tried `on_surface_created` + `LuaSurface.platform` as a
-- substitute, but that did not reliably onboard new platforms in
-- testing (most likely `.platform` isn't populated yet at the exact
-- moment that event fires during platform construction).
--
-- Instead, new platforms are detected by a plain scan: every second, as
-- part of the round-robin tick below, we check every live platform
-- against storage.known_platforms and onboard any we haven't seen
-- before. This trades instant reaction (on creation) for reliability --
-- a new platform is named/synced within one second, guaranteed, instead
-- of depending on a specific event firing at a specific point in an
-- undocumented internal sequence.

--- Scans all platforms for ones this mod hasn't seen yet, auto-names
-- them into the default fleet, and onboards them onto that fleet's
-- Leader (or the last cached Leader snapshot) if one exists.
local function detect_new_platforms()
  for_each_platform(function(platform)
    if not storage.known_platforms[platform.index] then
      storage.known_platforms[platform.index] = true

      local old_name = platform.name
      local highest = find_highest_number(DEFAULT_FLEET_PREFIX)
      local new_number = highest + 1
      platform.name = DEFAULT_FLEET_PREFIX .. " " .. new_number
      log("[Fleet Commander] New platform '" .. tostring(old_name) .. "' named '" .. platform.name .. "'.")

      -- Empty Fleet Protection: if this is "Cargo 1" (no Leader existed
      -- before), there's nothing to sync to -- it simply becomes the
      -- Leader.
      if new_number == 1 then
        log("[Fleet Commander] '" .. platform.name .. "' is the new fleet Leader.")
      else
        local leader = find_leader(DEFAULT_FLEET_PREFIX)
        if onboard_or_correct_follower(platform, leader, DEFAULT_FLEET_PREFIX) then
          log("[Fleet Commander] '" .. platform.name .. "' joined formation.")
        end
        -- If there's no live Leader and no cached snapshot either, this
        -- is silently a no-op and the platform simply operates
        -- independently until a "Cargo 1" is built or renamed into
        -- place.
      end
    end
  end)
end

-- ---------------------------------------------------------------------
-- Anti-Breakaway Logic: on_gui_closed
-- ---------------------------------------------------------------------
-- Factorio has no dedicated "space platform schedule/requests/build
-- changed" event (there is `on_train_schedule_changed` for trains, but
-- no equivalent for platforms), and `LuaPlayer` has no
-- `opened_space_platform` field -- editing a schedule from remote view
-- opens a shared `defines.gui_type.trains` GUI that on_gui_closed does
-- NOT tag with the platform/train it belongs to.
--
-- What IS reliable: when a player closes the space-platform-hub's own
-- GUI (defines.gui_type.entity), the event gives us that `entity`, and
-- `entity.surface.platform` (confirmed:
-- https://lua-api.factorio.com/latest/classes/LuaSurface.html) resolves
-- the owning LuaSpacePlatform. That covers the common case of editing
-- while docked at the hub. Edits made purely through remote view (no hub
-- GUI involved) aren't caught here -- they're caught instead by the
-- round-robin periodic sync below, at most one full cycle late.

script.on_event(defines.events.on_gui_closed, function(event)
  local entity = event.entity
  if not entity or not entity.valid or entity.type ~= "space-platform-hub" then
    return
  end

  local platform = entity.surface and entity.surface.platform
  if not platform or not platform.valid then
    return
  end

  local prefix, number = parse_platform_name(platform.name)
  if not prefix then
    return
  end

  if number == 1 then
    -- The Leader itself was edited: push the update to the whole fleet
    -- immediately.
    if sync_fleet(prefix, platform) then
      log("[Fleet Commander] Leader '" .. platform.name .. "' edited via hub GUI; pushed to fleet.")
    end
    return
  end

  -- A Follower's hub GUI was closed: check whether it still matches its
  -- Leader. If a player snuck in a manual change, stomp it and say why.
  local leader = find_leader(prefix)
  if not leader then
    -- Empty Fleet Protection: no Leader yet, so this platform is
    -- legitimately independent. Leave it alone.
    return
  end

  local changed = onboard_or_correct_follower(platform, leader, prefix)
  if changed then
    log("[Fleet Commander] Follower '" .. platform.name .. "' went off-script; reverted to match leader '" .. leader.name .. "'.")
    local player = game.get_player(event.player_index)
    if player then
      player.print(
        "[Fleet Commander] " .. platform.name ..
        " tried to go off-script. Reset to match " .. leader.name .. "."
      )
    end
  end
end)

-- ---------------------------------------------------------------------
-- Round-robin periodic tick (new-platform detection + fleet sync)
-- ---------------------------------------------------------------------
-- Fires once per second. Each firing:
--   1. Scans for and onboards any brand-new platforms (cheap: just name
--      parsing plus, at most, one onboarding write for genuinely new
--      platforms -- see detect_new_platforms above).
--   2. Advances a rotating queue of fleet prefixes by exactly one and
--      fully syncs only that one fleet -- so with N fleets, each fleet
--      is refreshed roughly every N seconds, but no single tick ever
--      pays for more than one fleet's worth of writes. This also acts
--      as the safety net for edits the on_gui_closed hook can't see
--      (remote-view schedule editing, console commands, other mods).

--- Rebuilds the round-robin queue with the current set of distinct
-- prefixes that have a live Leader right now. Cheap: just name parsing,
-- no schedule/request/blueprint work.
local function rebuild_sync_queue()
  local seen = {}
  local queue = {}
  for_each_platform(function(platform)
    local prefix, number = parse_platform_name(platform.name)
    if prefix and number == 1 and not seen[prefix] then
      seen[prefix] = true
      table.insert(queue, prefix)
    end
  end)
  storage.sync_queue = queue
  storage.sync_queue_index = 1
end

script.on_nth_tick(TICK_INTERVAL, function()
  detect_new_platforms()

  if storage.sync_queue_index > #storage.sync_queue then
    rebuild_sync_queue()
  end

  local prefix = storage.sync_queue[storage.sync_queue_index]
  storage.sync_queue_index = storage.sync_queue_index + 1

  if not prefix then
    -- No fleets with a Leader exist yet.
    return
  end

  local leader = find_leader(prefix)
  if leader then
    sync_fleet(prefix, leader)
  end
  -- If the Leader vanished since the queue was built, this prefix is
  -- simply skipped this cycle; the next rebuild will drop it entirely.
end)
