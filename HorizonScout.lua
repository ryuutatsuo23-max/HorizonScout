addon.name = 'HorizonScout';
addon.author = 'DragoHorse';
addon.version = '0.16.1';
addon.desc = 'Nearby alerts, aggression warnings, compass radar, map position, and targeting.';
addon.link = '';

require('common');

local chat = require('chat');
local aggro_database = require('aggro_database');
local compass = require('compass');
local fonts = require('fonts');
local imgui = require('imgui');
local map_grid = require('map_grid');
local scaling = require('scaling');
local settings = require('settings');
local sound_player = require('sound_player');
local time_library_ok, time_library = pcall(require, 'ffxi.time');
if not time_library_ok then
    time_library = nil;
end

local maximum_entity_index = 0x08FF;
local scan_interval_seconds = 0.50;
local minimum_range = 1;
local maximum_range = 50;
local minimum_aggressive_alert_range = 1;
local maximum_aggressive_alert_range = 50;
local maximum_aggressive_sound_cooldown_seconds = 60;
local maximum_compass_size = 240;
-- Ordinary chocobos and other mounts have distinct entity statuses:
-- https://github.com/Windower/Resources/blob/master/resources_data/statuses.lua
local chocobo_server_status = 5;
local mounted_server_status = 85;
local visible_render_flag = 0x0200;
local hidden_render_flag = 0x4000;
local monster_spawn_flag = 0x0010;
local npc_spawn_flag = 0x0002;
local player_spawn_flag = 0x0001;
local environment_spawn_flag = 0x0020;
local monster_sound_path = addon.path .. '\\mobalert.wav';
local npc_sound_path = addon.path .. '\\npcalert.wav';
local interactable_sound_path = addon.path .. '\\interactablealert.wav';
local aggressive_sound_path = addon.path .. '\\aggressivealert.wav';
local overlay_settings_icon = type(ICON_FA_GEAR) == 'string'
    and ICON_FA_GEAR
    or 'Settings';
local overlay_collapse_icon = type(ICON_FA_COMPRESS) == 'string'
    and ICON_FA_COMPRESS
    or '-';
local overlay_expand_icon = type(ICON_FA_EXPAND) == 'string'
    and ICON_FA_EXPAND
    or '+';

local default_settings = T{
    enabled = true,
    display_enabled = true,
    overlay_locked = false,
    overlay_compact_mode = false,
    position_enabled = true,
    height_hint_enabled = true,
    height_hint_threshold_yalms = 4,
    sound_enabled = true,
    npc_sound_enabled = true,
    interactable_sound_enabled = true,
    aggressive_sound_enabled = true,
    aggressive_alert_range = 18,
    aggressive_sound_cooldown_seconds = 10,
    aggressive_suppress_on_chocobo = true,
    aggressive_level_filter_enabled = true,
    aggressive_level_gap = 15,
    sound_volume_percent = 100,
    chat_notifications_enabled = false,
    compass_enabled = true,
    compass_locked = false,
    radar_enabled = true,
    radar_players_enabled = true,
    radar_monsters_enabled = true,
    radar_only_aggressive_monsters = false,
    radar_npcs_enabled = true,
    radar_objects_enabled = true,
    radar_hover_details_enabled = false,
    radar_north_up = false,
    radar_notorious_markers_enabled = true,
    notorious_notification_enabled = false,
    radar_highlight_tracked = true,
    radar_highlight_target = true,
    overlay_scale_percent = 100,
    compass_size = scaling.scale_f(112),
    compass_heading_offset_degrees = -90,
    compass_position_x = scaling.scale_w(80),
    compass_position_y = scaling.scale_h(80),
    range = 50,
    watch_names = T{},
    npc_watch_names = T{},
    interactable_watch_names = T{},
    tracking_presets = T{},
    active_preset_name = 'Default',
    fallback_preset_name = 'Default',
    zone_preset_assignments = T{},
    legacy_default_migrated = false,
    font = T{
        visible = true,
        font_family = 'Arial',
        font_height = scaling.scale_f(14),
        color = 0xFFFFFFFF,
        bold = true,
        position_x = scaling.scale_w(24),
        position_y = scaling.scale_h(240),
        background = T{
            visible = true,
            color = 0xA0000000,
        },
    },
};

local state = T{
    settings = settings.load(default_settings),
    font = nil,
    watch_lookup = T{},
    npc_watch_lookup = T{},
    interactable_watch_lookup = T{},
    active_ids = T{},
    aggressive_active_ids = T{},
    notorious_active_ids = T{},
    aggressive_nearby_count = 0,
    last_aggressive_sound_at = nil,
    aggressive_suppressed_on_chocobo = false,
    player_main_job_level = 0,
    matches = T{},
    radar_entities = T{},
    map_position = '?-?',
    last_scan_at = 0,
    zone_id = nil,
    overlay_force_position = true,
};

local settings_ui = T{
    is_open = {false},
    name_input = {''},
    npc_name_input = {''},
    interactable_name_input = {''},
    preset_name_input = {''},
    feedback = '',
    show_help = false,
    pending_overlay_target = nil,
};

local function tick_seconds()
    return ashita.time.tick64() / 1000;
end

local function aggressive_sound_cooldown_remaining(now)
    if state.last_aggressive_sound_at == nil then
        return 0;
    end

    local cooldown = state.settings.aggressive_sound_cooldown_seconds;
    return math.max(0, cooldown - (now - state.last_aggressive_sound_at));
end

local function normalize_name(value)
    if value == nil then
        return '';
    end

    return tostring(value)
        :gsub('^\171', '')
        :gsub('%s+', ' ')
        :gsub('^%s+', '')
        :gsub('%s+$', '')
        :lower();
end

local function display_name(value)
    if value == nil then
        return '';
    end

    return tostring(value)
        :gsub('^\171', '')
        :gsub('%s+', ' ')
        :gsub('^%s+', '')
        :gsub('%s+$', '');
end

local function notification_message(value, force)
    if force == true or state.settings.chat_notifications_enabled == true then
        print(chat.header(addon.name):append(chat.message(value)));
    end
end

local function error_message(value)
    print(chat.header(addon.name):append(chat.error(value)));
end

local function sound_file_exists(path)
    local file = io.open(path, 'rb');
    if file == nil then
        return false;
    end

    file:close();
    return true;
end

local function play_alert_sound(path, label, volume_percent)
    if not sound_file_exists(path) then
        error_message(label .. ' sound file is missing: ' .. path);
        return false;
    end

    local call_ok, played, reason = pcall(
        sound_player.play,
        path,
        volume_percent
    );
    if not call_ok then
        reason = played;
        played = false;
    end
    if not played then
        error_message(('Unable to play the %s sound: %s'):fmt(label, tostring(reason)));
        return false;
    end

    return true;
end

local function rebuild_watch_lookup()
    state.watch_lookup = T{};
    state.npc_watch_lookup = T{};
    state.interactable_watch_lookup = T{};
    for _, name in ipairs(state.settings.watch_names or T{}) do
        local normalized = normalize_name(name);
        if normalized ~= '' then
            state.watch_lookup[normalized] = display_name(name);
        end
    end
    for _, name in ipairs(state.settings.npc_watch_names or T{}) do
        local normalized = normalize_name(name);
        if normalized ~= '' then
            state.npc_watch_lookup[normalized] = display_name(name);
        end
    end
    for _, name in ipairs(state.settings.interactable_watch_names or T{}) do
        local normalized = normalize_name(name);
        if normalized ~= '' then
            state.interactable_watch_lookup[normalized] = display_name(name);
        end
    end
end

local function copy_name_list(names)
    local result = T{};
    for _, name in ipairs(names or T{}) do
        local cleaned = display_name(name);
        if cleaned ~= '' then
            result:append(cleaned);
        end
    end
    return result;
end

local function find_tracking_preset(name)
    local wanted = normalize_name(name);
    for index, preset in ipairs(state.settings.tracking_presets or T{}) do
        if normalize_name(preset.name) == wanted then
            return preset, index;
        end
    end
    return nil;
end

local function normalize_tracking_presets(
    legacy_monsters,
    legacy_npcs,
    legacy_objects
)
    local presets = state.settings.tracking_presets;
    if type(presets) ~= 'table' or #presets == 0 then
        presets = T{
            T{
                name = 'Default',
                watch_names = copy_name_list(legacy_monsters),
                npc_watch_names = copy_name_list(legacy_npcs),
                interactable_watch_names = copy_name_list(legacy_objects),
            },
        };
    end

    local cleaned_presets = T{};
    local seen_names = T{};
    for _, preset in ipairs(presets) do
        local preset_name = display_name(preset.name);
        local normalized = normalize_name(preset_name);
        if normalized ~= '' and seen_names[normalized] ~= true then
            seen_names[normalized] = true;
            cleaned_presets:append(T{
                name = preset_name,
                watch_names = copy_name_list(preset.watch_names),
                npc_watch_names = copy_name_list(preset.npc_watch_names),
                interactable_watch_names = copy_name_list(
                    preset.interactable_watch_names
                ),
            });
        end
    end
    if #cleaned_presets == 0 then
        cleaned_presets:append(T{
            name = 'Default',
            watch_names = T{},
            npc_watch_names = T{},
            interactable_watch_names = T{},
        });
    end
    state.settings.tracking_presets = cleaned_presets;

    local active = find_tracking_preset(state.settings.active_preset_name)
        or cleaned_presets[1];
    state.settings.active_preset_name = active.name;
    local fallback = find_tracking_preset(state.settings.fallback_preset_name)
        or active;
    state.settings.fallback_preset_name = fallback.name;
    state.settings.zone_preset_assignments = state.settings.zone_preset_assignments
        or T{};
    for zone_key, preset_name in pairs(state.settings.zone_preset_assignments) do
        local assigned = find_tracking_preset(preset_name);
        if assigned == nil then
            state.settings.zone_preset_assignments[zone_key] = nil;
        else
            state.settings.zone_preset_assignments[zone_key] = assigned.name;
        end
    end
end

local function bind_active_tracking_preset()
    local preset = find_tracking_preset(state.settings.active_preset_name)
        or state.settings.tracking_presets[1];
    state.settings.active_preset_name = preset.name;
    state.settings.watch_names = preset.watch_names;
    state.settings.npc_watch_names = preset.npc_watch_names;
    state.settings.interactable_watch_names = preset.interactable_watch_names;
    return preset;
end

local function clear_observation_state()
    state.active_ids = T{};
    state.aggressive_active_ids = T{};
    state.notorious_active_ids = T{};
    state.aggressive_nearby_count = 0;
    state.last_aggressive_sound_at = nil;
    state.aggressive_suppressed_on_chocobo = false;
    state.player_main_job_level = 0;
    state.matches = T{};
    state.radar_entities = T{};
end

local function update_settings(new_settings)
    if new_settings ~= nil then
        state.settings = new_settings;
    end

    state.settings.range = math.max(
        minimum_range,
        math.min(maximum_range, tonumber(state.settings.range) or 50)
    );
    local legacy_monsters = state.settings.watch_names or T{};
    local legacy_npcs = state.settings.npc_watch_names or T{};
    local legacy_objects = state.settings.interactable_watch_names or T{};
    normalize_tracking_presets(legacy_monsters, legacy_npcs, legacy_objects);
    bind_active_tracking_preset();
    if state.settings.compass_enabled == nil then
        state.settings.compass_enabled = true;
    end
    if state.settings.compass_locked == nil then
        state.settings.compass_locked = false;
    end
    -- Category filters replace the former single radar-dots checkbox. Keep the
    -- internal master enabled so an older saved `false` cannot make every new
    -- category checkbox appear ineffective.
    state.settings.radar_enabled = true;
    if state.settings.overlay_locked == nil then
        state.settings.overlay_locked = false;
    end
    if state.settings.overlay_compact_mode == nil then
        state.settings.overlay_compact_mode = false;
    end
    if state.settings.radar_players_enabled == nil then
        state.settings.radar_players_enabled = true;
    end
    if state.settings.radar_monsters_enabled == nil then
        state.settings.radar_monsters_enabled = true;
    end
    if state.settings.radar_only_aggressive_monsters == nil then
        state.settings.radar_only_aggressive_monsters = false;
    end
    if state.settings.radar_npcs_enabled == nil then
        state.settings.radar_npcs_enabled = true;
    end
    if state.settings.radar_objects_enabled == nil then
        state.settings.radar_objects_enabled = true;
    end
    if state.settings.radar_hover_details_enabled == nil then
        state.settings.radar_hover_details_enabled = false;
    end
    if state.settings.radar_north_up == nil then
        state.settings.radar_north_up = false;
    end
    if state.settings.radar_notorious_markers_enabled == nil then
        state.settings.radar_notorious_markers_enabled = true;
    end
    if state.settings.notorious_notification_enabled == nil then
        state.settings.notorious_notification_enabled = false;
    end
    if state.settings.height_hint_enabled == nil then
        state.settings.height_hint_enabled = true;
    end
    state.settings.height_hint_threshold_yalms = math.max(
        1,
        math.min(20, tonumber(state.settings.height_hint_threshold_yalms) or 4)
    );
    if state.settings.radar_highlight_tracked == nil then
        state.settings.radar_highlight_tracked = true;
    end
    if state.settings.radar_highlight_target == nil then
        state.settings.radar_highlight_target = true;
    end
    state.settings.overlay_scale_percent = math.max(
        50,
        math.min(200, tonumber(state.settings.overlay_scale_percent) or 100)
    );
    if state.settings.chat_notifications_enabled == nil then
        state.settings.chat_notifications_enabled = false;
    end
    if state.settings.interactable_sound_enabled == nil then
        state.settings.interactable_sound_enabled = true;
    end
    if state.settings.aggressive_sound_enabled == nil then
        state.settings.aggressive_sound_enabled = true;
    end
    state.settings.aggressive_alert_range = math.max(
        minimum_aggressive_alert_range,
        math.min(
            maximum_aggressive_alert_range,
            tonumber(state.settings.aggressive_alert_range) or 18
        )
    );
    state.settings.aggressive_sound_cooldown_seconds = math.max(
        0,
        math.min(
            maximum_aggressive_sound_cooldown_seconds,
            tonumber(state.settings.aggressive_sound_cooldown_seconds) or 10
        )
    );
    if state.settings.aggressive_suppress_on_chocobo == nil then
        state.settings.aggressive_suppress_on_chocobo = true;
    end
    if state.settings.aggressive_level_filter_enabled == nil then
        state.settings.aggressive_level_filter_enabled = true;
    end
    state.settings.aggressive_level_gap = math.max(
        1,
        math.min(99, tonumber(state.settings.aggressive_level_gap) or 15)
    );
    state.settings.sound_volume_percent = math.max(
        0,
        math.min(150, tonumber(state.settings.sound_volume_percent) or 100)
    );
    state.settings.compass_size = math.max(
        80,
        math.min(
            maximum_compass_size,
            tonumber(state.settings.compass_size) or scaling.scale_f(112)
        )
    );
    state.settings.compass_position_x = tonumber(state.settings.compass_position_x)
        or scaling.scale_w(80);
    state.settings.compass_position_y = tonumber(state.settings.compass_position_y)
        or scaling.scale_h(80);
    state.settings.compass_heading_offset_degrees = math.max(
        -180,
        math.min(
            180,
            tonumber(state.settings.compass_heading_offset_degrees) or -90
        )
    );

    -- Version 0.1 seeded Sand Bat automatically. Remove only that legacy
    -- seed once while preserving any other names the player added.
    if state.settings.legacy_default_migrated ~= true then
        local migrated_names = T{};
        for _, name in ipairs(state.settings.watch_names) do
            if normalize_name(name) ~= 'sand bat' then
                migrated_names:append(display_name(name));
            end
        end
        local active_preset = find_tracking_preset(
            state.settings.active_preset_name
        );
        active_preset.watch_names = migrated_names;
        bind_active_tracking_preset();
        state.settings.legacy_default_migrated = true;
    end

    rebuild_watch_lookup();
    clear_observation_state();

    if state.font ~= nil then
        state.font:apply(state.settings.font);
    end

    state.overlay_force_position = true;
    compass.request_position_reset();
    settings.save();
end

settings.register('settings', 'HorizonScout_SettingsUpdate', update_settings);
update_settings();

local function lookup_count(lookup)
    local count = 0;
    for _ in pairs(lookup) do
        count = count + 1;
    end
    return count;
end

local function watched_name_count()
    return lookup_count(state.watch_lookup)
        + lookup_count(state.npc_watch_lookup)
        + lookup_count(state.interactable_watch_lookup);
end

local function activate_tracking_preset(name, make_fallback)
    local preset = find_tracking_preset(name);
    if preset == nil then
        return false, 'That tracking preset no longer exists.';
    end

    local changed = normalize_name(state.settings.active_preset_name)
        ~= normalize_name(preset.name);
    state.settings.active_preset_name = preset.name;
    if make_fallback == true then
        state.settings.fallback_preset_name = preset.name;
    end
    bind_active_tracking_preset();
    rebuild_watch_lookup();
    if changed then
        clear_observation_state();
        state.last_scan_at = 0;
    end
    settings.save();
    return true, ('Active tracking preset: %s'):fmt(preset.name);
end

local function apply_zone_tracking_preset(zone_id)
    local assigned_name = state.settings.zone_preset_assignments[tostring(zone_id)];
    local desired_name = assigned_name or state.settings.fallback_preset_name;
    if normalize_name(desired_name) == normalize_name(
        state.settings.active_preset_name
    ) then
        return false;
    end
    local ok = activate_tracking_preset(desired_name, false);
    return ok;
end

local function set_fallback_tracking_preset(name)
    local preset = find_tracking_preset(name);
    if preset == nil then
        return false, 'That tracking preset no longer exists.';
    end
    state.settings.fallback_preset_name = preset.name;
    local assigned = state.zone_id ~= nil
        and state.settings.zone_preset_assignments[tostring(state.zone_id)]
        or nil;
    if assigned == nil then
        return activate_tracking_preset(preset.name, false);
    end
    settings.save();
    return true, ('Fallback preset: %s; this zone remains assigned to %s.'):fmt(
        preset.name,
        assigned
    );
end

local function create_tracking_preset(name, copy_active)
    name = display_name(name);
    if name == '' then
        return false, 'Enter a preset name first.';
    end
    if #name > 40 then
        return false, 'Preset names can use at most 40 characters.';
    end
    if find_tracking_preset(name) ~= nil then
        return false, name .. ' already exists.';
    end

    local active = bind_active_tracking_preset();
    local preset = T{
        name = name,
        watch_names = copy_active and copy_name_list(active.watch_names) or T{},
        npc_watch_names = copy_active and copy_name_list(active.npc_watch_names) or T{},
        interactable_watch_names = copy_active
            and copy_name_list(active.interactable_watch_names)
            or T{},
    };
    state.settings.tracking_presets:append(preset);
    local ok, feedback = set_fallback_tracking_preset(name);
    return ok, ('Created %s. %s'):fmt(name, feedback);
end

local function delete_tracking_preset(name)
    local preset, index = find_tracking_preset(name);
    if preset == nil then
        return false, 'That tracking preset no longer exists.';
    end
    if normalize_name(preset.name) == 'default' then
        return false, 'The Default preset is retained for compatibility.';
    end

    table.remove(state.settings.tracking_presets, index);
    for zone_key, preset_name in pairs(state.settings.zone_preset_assignments) do
        if normalize_name(preset_name) == normalize_name(preset.name) then
            state.settings.zone_preset_assignments[zone_key] = nil;
        end
    end
    if normalize_name(state.settings.fallback_preset_name)
        == normalize_name(preset.name) then
        state.settings.fallback_preset_name = 'Default';
    end
    if normalize_name(state.settings.active_preset_name)
        == normalize_name(preset.name) then
        state.settings.active_preset_name = state.settings.fallback_preset_name;
    end
    bind_active_tracking_preset();
    rebuild_watch_lookup();
    clear_observation_state();
    state.last_scan_at = 0;
    settings.save();
    return true, 'Deleted tracking preset: ' .. preset.name;
end

local function assign_current_zone_to_preset(name)
    if state.zone_id == nil or tonumber(state.zone_id) == nil then
        return false, 'Current zone information is unavailable.';
    end
    local preset = find_tracking_preset(name);
    if preset == nil then
        return false, 'That tracking preset no longer exists.';
    end
    state.settings.zone_preset_assignments[tostring(state.zone_id)] = preset.name;
    activate_tracking_preset(preset.name, false);
    return true, ('Assigned this zone to preset: %s'):fmt(preset.name);
end

local function unassign_current_zone_preset()
    if state.zone_id == nil then
        return false, 'Current zone information is unavailable.';
    end
    local zone_key = tostring(state.zone_id);
    if state.settings.zone_preset_assignments[zone_key] == nil then
        return false, 'This zone has no preset assignment.';
    end
    state.settings.zone_preset_assignments[zone_key] = nil;
    activate_tracking_preset(state.settings.fallback_preset_name, false);
    return true, 'Removed this zone preset assignment.';
end

local function is_matching_entity(entity, index, maximum_distance_squared)
    local server_id = tonumber(entity:GetServerId(index)) or 0;
    if server_id == 0 then
        return nil;
    end

    local render_flags = tonumber(entity:GetRenderFlags0(index)) or 0;
    if bit.band(render_flags, visible_render_flag) ~= visible_render_flag
        or bit.band(render_flags, hidden_render_flag) ~= 0 then
        return nil;
    end

    local spawn_flags = tonumber(entity:GetSpawnFlags(index)) or 0;
    local distance_squared = tonumber(entity:GetDistance(index));
    if distance_squared == nil or distance_squared < 0
        or distance_squared > maximum_distance_squared then
        return nil;
    end

    local name = display_name(entity:GetName(index));
    local normalized_name = normalize_name(name);
    local kind = nil;
    local configured_name = nil;
    local configured_interactable = state.interactable_watch_lookup[normalized_name];
    if configured_interactable ~= nil
        and bit.band(spawn_flags, npc_spawn_flag) ~= 0 then
        -- Horizon can expose targetable world objects as ordinary NPC-class
        -- entities without the environment bit. An exact object-list entry is
        -- therefore authoritative within the NPC class.
        kind = 'interactable';
        configured_name = configured_interactable;
    elseif bit.band(spawn_flags, monster_spawn_flag) ~= 0
        and (tonumber(entity:GetHPPercent(index)) or 0) > 0 then
        kind = 'monster';
        configured_name = state.watch_lookup[normalized_name];
    elseif bit.band(spawn_flags, npc_spawn_flag) ~= 0 then
        if bit.band(spawn_flags, environment_spawn_flag) ~= 0 then
            kind = 'interactable';
            configured_name = configured_interactable;
        else
            kind = 'npc';
            configured_name = state.npc_watch_lookup[normalized_name];
        end
    end
    if configured_name == nil then
        return nil;
    end

    return T{
        id = server_id,
        index = index,
        name = name,
        kind = kind,
        key = kind .. ':' .. tostring(server_id),
        configured_name = configured_name,
        distance = math.sqrt(distance_squared),
    };
end

local function get_radar_entity(
    entity,
    index,
    zone_id,
    player_x,
    player_y,
    maximum_distance_squared
)
    local server_id = tonumber(entity:GetServerId(index)) or 0;
    if server_id == 0 then
        return nil;
    end

    local render_flags = tonumber(entity:GetRenderFlags0(index)) or 0;
    if bit.band(render_flags, visible_render_flag) ~= visible_render_flag
        or bit.band(render_flags, hidden_render_flag) ~= 0 then
        return nil;
    end

    if (tonumber(entity:GetTrustOwnerTargetIndex(index)) or 0) ~= 0 then
        return nil;
    end

    local name = display_name(entity:GetName(index));
    local spawn_flags = tonumber(entity:GetSpawnFlags(index)) or 0;
    local entity_type = tonumber(entity:GetType(index)) or -1;
    local kind = nil;
    if bit.band(spawn_flags, monster_spawn_flag) ~= 0
        and (tonumber(entity:GetHPPercent(index)) or 0) > 0 then
        kind = 'monster';
    elseif entity_type == 0 and bit.band(spawn_flags, player_spawn_flag) ~= 0 then
        kind = 'player';
    elseif bit.band(spawn_flags, npc_spawn_flag) ~= 0 then
        -- Environment targets use the NPC bit plus 0x20 (spawn value 34).
        -- Keep them green on the radar, but distinguish them for their own alert.
        kind = (bit.band(spawn_flags, environment_spawn_flag) ~= 0
                or state.interactable_watch_lookup[normalize_name(name)] ~= nil)
            and 'interactable'
            or 'npc';
    end
    if kind == nil then
        return nil;
    end
    local monster_info = nil;
    if kind == 'monster'
        and (state.settings.radar_only_aggressive_monsters == true
            or state.settings.radar_notorious_markers_enabled == true
            or state.settings.notorious_notification_enabled == true) then
        monster_info = aggro_database.get_monster_info(zone_id, index, name);
    end
    if kind == 'player' and state.settings.radar_players_enabled ~= true then
        return nil;
    elseif kind == 'monster' then
        if state.settings.radar_monsters_enabled ~= true then
            return nil;
        end
        if state.settings.radar_only_aggressive_monsters == true then
            if monster_info == nil or monster_info.Aggro ~= true then
                return nil;
            end
        end
    elseif kind == 'npc' and state.settings.radar_npcs_enabled ~= true then
        return nil;
    elseif kind == 'interactable' and state.settings.radar_objects_enabled ~= true then
        return nil;
    end

    local entity_x = tonumber(entity:GetLocalPositionX(index));
    local entity_y = tonumber(entity:GetLocalPositionY(index));
    if entity_x == nil or entity_y == nil then
        return nil;
    end

    local delta_x = entity_x - player_x;
    local delta_y = entity_y - player_y;
    local distance_squared = delta_x * delta_x + delta_y * delta_y;
    if distance_squared > maximum_distance_squared then
        return nil;
    end

    return T{
        id = server_id,
        index = index,
        name = name,
        kind = kind,
        delta_x = delta_x,
        delta_y = delta_y,
        distance = math.sqrt(distance_squared),
        notorious = monster_info ~= nil and monster_info.Notorious == true,
        aggressive = monster_info ~= nil and monster_info.Aggro == true,
        -- Reuse exact-name/category matching, including NPC-class objects.
        tracked = state.settings.radar_highlight_tracked == true
            and is_matching_entity(entity, index, maximum_distance_squared) ~= nil,
    };
end

local function read_entity_height(entity, index)
    if index == nil or index <= 0 or index > maximum_entity_index then
        return nil;
    end
    local ok, height = pcall(function()
        return tonumber(entity:GetLocalPositionZ(index));
    end);
    if ok and height ~= nil and height == height and math.abs(height) < math.huge then
        return height;
    end
    return nil;
end

local function get_aggressive_monster(entity, index, zone_id, player_main_job_level)
    local server_id = tonumber(entity:GetServerId(index)) or 0;
    if server_id == 0 then
        return nil;
    end

    local render_flags = tonumber(entity:GetRenderFlags0(index)) or 0;
    if bit.band(render_flags, visible_render_flag) ~= visible_render_flag
        or bit.band(render_flags, hidden_render_flag) ~= 0 then
        return nil;
    end
    if (tonumber(entity:GetTrustOwnerTargetIndex(index)) or 0) ~= 0 then
        return nil;
    end

    local spawn_flags = tonumber(entity:GetSpawnFlags(index)) or 0;
    if bit.band(spawn_flags, monster_spawn_flag) == 0
        or (tonumber(entity:GetHPPercent(index)) or 0) <= 0 then
        return nil;
    end

    local distance_squared = tonumber(entity:GetDistance(index));
    local aggressive_alert_range = state.settings.aggressive_alert_range;
    local maximum_distance_squared = aggressive_alert_range * aggressive_alert_range;
    if distance_squared == nil or distance_squared < 0
        or distance_squared > maximum_distance_squared then
        return nil;
    end

    local name = display_name(entity:GetName(index));
    local monster_info = aggro_database.get_monster_info(zone_id, index, name);
    if monster_info == nil or monster_info.Aggro ~= true then
        return nil;
    end

    local maximum_monster_level = tonumber(monster_info.MaxLevel) or 0;
    local level_gap = state.settings.aggressive_level_gap;
    if state.settings.aggressive_level_filter_enabled
        and player_main_job_level > 0
        and maximum_monster_level > 0
        and (player_main_job_level - maximum_monster_level) >= level_gap then
        return nil;
    end

    return T{
        id = server_id,
        index = index,
        name = name,
        distance = math.sqrt(distance_squared),
        maximum_level = maximum_monster_level,
    };
end

local function scan_entities()
    local alert_scanning = state.settings.enabled and watched_name_count() > 0;
    local aggressive_scanning = state.settings.enabled
        and state.settings.aggressive_sound_enabled;
    local radar_scanning = state.settings.compass_enabled
        and state.settings.radar_enabled;
    local memory = AshitaCore:GetMemoryManager();
    if memory == nil then
        clear_observation_state();
        return;
    end

    local party = memory:GetParty();
    if party == nil or party:GetMemberIsActive(0) == 0
        or party:GetMemberServerId(0) == 0 then
        clear_observation_state();
        state.zone_id = nil;
        aggro_database.reset();
        return;
    end

    local current_zone_id = tonumber(party:GetMemberZone(0));
    if state.zone_id ~= current_zone_id then
        clear_observation_state();
        state.zone_id = current_zone_id;
        aggro_database.reset();
        if current_zone_id ~= nil then
            apply_zone_tracking_preset(current_zone_id);
        end
        alert_scanning = state.settings.enabled and watched_name_count() > 0;
    end
    if not alert_scanning and not aggressive_scanning and not radar_scanning then
        clear_observation_state();
        return;
    end
    local entity = memory:GetEntity();
    if entity == nil then
        clear_observation_state();
        return;
    end

    local next_active_ids = T{};
    local next_matches = T{};
    local new_monsters = T{};
    local new_npcs = T{};
    local new_interactables = T{};
    local aggressive_candidates = T{};
    local radar_candidates = T{};
    local pet_indices = T{};
    local maximum_distance_squared = state.settings.range * state.settings.range;
    local player_index = tonumber(party:GetMemberTargetIndex(0));
    local player_main_job_level = tonumber(party:GetMemberMainJobLevel(0)) or 0;
    state.player_main_job_level = player_main_job_level;
    state.aggressive_suppressed_on_chocobo = false;
    if aggressive_scanning and player_index ~= nil
        and state.settings.aggressive_suppress_on_chocobo then
        local player_status = tonumber(entity:GetStatusServer(player_index));
        if player_status == chocobo_server_status or player_status == mounted_server_status then
            aggressive_scanning = false;
            state.aggressive_suppressed_on_chocobo = true;
            state.aggressive_active_ids = T{};
            state.aggressive_nearby_count = 0;
        end
    end
    local radar_requires_mobdb = radar_scanning
        and state.settings.radar_monsters_enabled
        and (state.settings.radar_only_aggressive_monsters
            or state.settings.radar_notorious_markers_enabled
            or state.settings.notorious_notification_enabled);
    if aggressive_scanning or radar_requires_mobdb then
        aggro_database.load_zone(current_zone_id);
    end
    local player_x = nil;
    local player_y = nil;
    if radar_scanning and player_index ~= nil then
        player_x = tonumber(entity:GetLocalPositionX(player_index));
        player_y = tonumber(entity:GetLocalPositionY(player_index));
    end
    if player_index == nil or player_x == nil or player_y == nil then
        radar_scanning = false;
    end
    local player_z = nil;
    if state.settings.height_hint_enabled
        and (alert_scanning
            or (radar_scanning and state.settings.radar_hover_details_enabled)) then
        player_z = read_entity_height(entity, player_index);
    end

    for index = 0, maximum_entity_index do
        if radar_scanning or aggressive_scanning then
            if (tonumber(entity:GetServerId(index)) or 0) ~= 0 then
                local pet_index = tonumber(entity:GetPetTargetIndex(index)) or 0;
                if pet_index ~= 0 then
                    pet_indices[pet_index] = true;
                end

                if radar_scanning and index ~= player_index then
                    local radar_entity = get_radar_entity(
                        entity,
                        index,
                        current_zone_id,
                        player_x,
                        player_y,
                        maximum_distance_squared
                    );
                    if radar_entity ~= nil then
                        if player_z ~= nil then
                            local entity_z = read_entity_height(entity, index);
                            if entity_z ~= nil then
                                radar_entity.height_difference = player_z - entity_z;
                            end
                        end
                        radar_candidates:append(radar_entity);
                    end
                end
                if aggressive_scanning and index ~= player_index then
                    local aggressive_monster = get_aggressive_monster(
                        entity,
                        index,
                        current_zone_id,
                        player_main_job_level
                    );
                    if aggressive_monster ~= nil then
                        aggressive_candidates:append(aggressive_monster);
                    end
                end
            end
        end

        if alert_scanning then
            local match = is_matching_entity(entity, index, maximum_distance_squared);
            if match ~= nil then
                if player_z ~= nil then
                    local match_z = read_entity_height(entity, index);
                    if match_z ~= nil then
                        -- FFXI Z increases downwards; positive here means above us.
                        match.height_difference = player_z - match_z;
                    end
                end
                next_active_ids[match.key] = true;
                next_matches:append(match);
                if not state.active_ids[match.key] then
                    if match.kind == 'npc' then
                        new_npcs:append(match);
                    elseif match.kind == 'interactable' then
                        new_interactables:append(match);
                    else
                        new_monsters:append(match);
                    end
                end
            end
        end
    end

    local next_radar_entities = T{};
    for _, radar_entity in ipairs(radar_candidates) do
        if not pet_indices[radar_entity.index] then
            next_radar_entities:append(radar_entity);
        end
    end
    next_radar_entities:sort(function(left, right)
        return left.distance > right.distance;
    end);

    local next_notorious_ids = T{};
    for _, radar_entity in ipairs(next_radar_entities) do
        if radar_entity.kind == 'monster' and radar_entity.notorious == true then
            next_notorious_ids[radar_entity.id] = true;
            if state.settings.notorious_notification_enabled == true
                and state.notorious_active_ids[radar_entity.id] ~= true then
                notification_message(
                    ('Notorious Monster %s detected at %.1f yalms.'):fmt(
                        radar_entity.name,
                        radar_entity.distance
                    ),
                    true
                );
            end
        end
    end

    local next_aggressive_ids = T{};
    local next_aggressive_monsters = T{};
    local new_aggressive_monsters = T{};
    for _, aggressive_monster in ipairs(aggressive_candidates) do
        if not pet_indices[aggressive_monster.index] then
            next_aggressive_ids[aggressive_monster.id] = true;
            next_aggressive_monsters:append(aggressive_monster);
            if not state.aggressive_active_ids[aggressive_monster.id] then
                new_aggressive_monsters:append(aggressive_monster);
            end
        end
    end
    next_aggressive_monsters:sort(function(left, right)
        return left.distance < right.distance;
    end);

    next_matches:sort(function(left, right)
        if left.distance == right.distance then
            return left.name < right.name;
        end
        return left.distance < right.distance;
    end);

    state.active_ids = next_active_ids;
    state.aggressive_active_ids = next_aggressive_ids;
    state.notorious_active_ids = next_notorious_ids;
    state.aggressive_nearby_count = #next_aggressive_monsters;
    state.matches = next_matches;
    state.radar_entities = next_radar_entities;

    for _, match in ipairs(new_monsters) do
        notification_message(('Monster %s detected at %.1f yalms.'):fmt(
            match.name,
            match.distance
        ));
    end
    for _, match in ipairs(new_npcs) do
        notification_message(('NPC %s detected at %.1f yalms.'):fmt(
            match.name,
            match.distance
        ));
    end
    for _, interactable in ipairs(new_interactables) do
        local name = interactable.name ~= '' and interactable.name or 'object';
        notification_message(('Interactable %s detected at %.1f yalms.'):fmt(
            name,
            interactable.distance
        ));
    end
    for _, aggressive_monster in ipairs(new_aggressive_monsters) do
        notification_message(('Aggressive monster %s entered %.1f yalms.'):fmt(
            aggressive_monster.name,
            aggressive_monster.distance
        ));
    end

    if #new_monsters > 0 and state.settings.sound_enabled then
        play_alert_sound(
            monster_sound_path,
            'monster alert',
            state.settings.sound_volume_percent
        );
    end
    if #new_npcs > 0 and state.settings.npc_sound_enabled
        and sound_file_exists(npc_sound_path) then
        play_alert_sound(
            npc_sound_path,
            'NPC alert',
            state.settings.sound_volume_percent
        );
    end
    if #new_interactables > 0 and state.settings.interactable_sound_enabled
        and sound_file_exists(interactable_sound_path) then
        play_alert_sound(
            interactable_sound_path,
            'interactable-object alert',
            state.settings.sound_volume_percent
        );
    end
    local aggressive_sound_now = tick_seconds();
    if #new_aggressive_monsters > 0 and state.settings.aggressive_sound_enabled
        and aggressive_sound_cooldown_remaining(aggressive_sound_now) <= 0 then
        local played = play_alert_sound(
            aggressive_sound_path,
            'aggressive-monster warning',
            state.settings.sound_volume_percent
        );
        if played and state.settings.sound_volume_percent > 0 then
            state.last_aggressive_sound_at = aggressive_sound_now;
        end
    end
end

local function update_display()
    -- The former font overlay cannot host buttons. Keep its persisted settings
    -- for position compatibility, but render the visible panel with ImGui.
    if state.font ~= nil then
        state.font.text = '';
    end
end

local function joined_argument(args, start_index)
    local parts = T{};
    for index = start_index, #args do
        parts:append(args[index]);
    end
    return display_name(parts:concat(' '));
end

local function watch_names_for_kind(kind)
    if kind == 'npc' then
        return state.settings.npc_watch_names;
    elseif kind == 'interactable' then
        return state.settings.interactable_watch_names;
    end
    return state.settings.watch_names;
end

local function kind_label(kind)
    if kind == 'npc' then
        return 'NPC';
    elseif kind == 'interactable' then
        return 'interactable object';
    end
    return 'monster';
end

local function find_watch_index(name, kind)
    local normalized = normalize_name(name);
    for index, existing in ipairs(watch_names_for_kind(kind)) do
        if normalize_name(existing) == normalized then
            return index;
        end
    end
    return nil;
end

local function add_watch_name(name, kind)
    local label = kind_label(kind);
    name = display_name(name);
    if name == '' then
        local article = (kind == 'npc' or kind == 'interactable') and 'an' or 'a';
        return false, ('Enter %s %s name first.'):fmt(article, label);
    end
    if find_watch_index(name, kind) ~= nil then
        return false, name .. ' is already in the ' .. label .. ' list.';
    end

    table.insert(watch_names_for_kind(kind), name);
    update_settings();
    state.last_scan_at = 0;
    return true, ('Now watching %s exact name: %s'):fmt(label, name);
end

local function read_current_target()
    local ok, target_info, validation_error = pcall(function()
        local memory = AshitaCore:GetMemoryManager();
        local entity = memory ~= nil and memory:GetEntity() or nil;
        local target = memory ~= nil and memory:GetTarget() or nil;
        if entity == nil or target == nil then
            return nil, 'The entity or target manager is unavailable.';
        end

        local slot = target:GetIsSubTargetActive() == 1 and 1 or 0;
        if target:GetIsActive(slot) == 0 then
            return nil, 'Select a target first.';
        end
        local index = tonumber(target:GetTargetIndex(slot));
        local target_id = tonumber(target:GetServerId(slot)) or 0;
        if index == nil or index <= 0 or target_id == 0
            or (tonumber(entity:GetServerId(index)) or 0) ~= target_id then
            return nil, 'The selected target is no longer valid.';
        end

        local name = display_name(entity:GetName(index));
        if name == '' then
            return nil, 'The selected target has no usable name.';
        end
        return T{
            name = name,
            index = index,
            id = target_id,
            spawn_flags = tonumber(entity:GetSpawnFlags(index)) or 0,
            hp_percent = tonumber(entity:GetHPPercent(index)) or 0,
        };
    end);
    if not ok then
        return nil, 'Unable to read the selected target: ' .. tostring(target_info);
    end
    if target_info == nil then
        return nil, validation_error or 'The selected target is unavailable.';
    end
    return target_info;
end

local function add_current_target(kind)
    local target_info, validation_error = read_current_target();
    if target_info == nil then
        return false, validation_error;
    end

    local spawn_flags = target_info.spawn_flags;
    local valid = kind == 'monster'
        and bit.band(spawn_flags, monster_spawn_flag) ~= 0
        and target_info.hp_percent > 0
        or (kind == 'npc' or kind == 'interactable')
        and bit.band(spawn_flags, npc_spawn_flag) ~= 0;
    if not valid then
        return false, ('The selected target is not %s.'):fmt(kind_label(kind));
    end
    return add_watch_name(target_info.name, kind);
end

local function add_overlay_current_target()
    local target_info, validation_error = read_current_target();
    if target_info == nil then
        settings_ui.pending_overlay_target = nil;
        return false, validation_error;
    end

    if bit.band(target_info.spawn_flags, monster_spawn_flag) ~= 0
        and target_info.hp_percent > 0 then
        settings_ui.pending_overlay_target = nil;
        return add_watch_name(target_info.name, 'monster');
    end
    if bit.band(target_info.spawn_flags, npc_spawn_flag) == 0 then
        settings_ui.pending_overlay_target = nil;
        return false, 'The selected target is not a monster, NPC, or object.';
    end
    if bit.band(target_info.spawn_flags, environment_spawn_flag) ~= 0 then
        settings_ui.pending_overlay_target = nil;
        return add_watch_name(target_info.name, 'interactable');
    end

    -- Horizon exposes some world objects as ordinary NPC-class entities. Ask
    -- for the destination instead of silently putting an object in the NPC list.
    settings_ui.pending_overlay_target = target_info;
    return true, ('Choose NPC or Object for: %s'):fmt(target_info.name);
end

local function add_pending_overlay_target(kind)
    local pending = settings_ui.pending_overlay_target;
    if pending == nil then
        return false, 'Select a target again.';
    end
    settings_ui.pending_overlay_target = nil;
    return add_watch_name(pending.name, kind);
end

local function remove_watch_index(index, kind)
    local names = watch_names_for_kind(kind);
    if index == nil or names[index] == nil then
        return false, 'That ' .. kind_label(kind) .. ' name is not being watched.';
    end

    local removed = table.remove(names, index);
    update_settings();
    state.last_scan_at = 0;
    return true, 'Stopped watching: ' .. display_name(removed);
end

local function clear_watch_names(kind)
    local preset = bind_active_tracking_preset();
    if kind == 'npc' then
        preset.npc_watch_names = T{};
    elseif kind == 'interactable' then
        preset.interactable_watch_names = T{};
    else
        preset.watch_names = T{};
    end
    bind_active_tracking_preset();
    update_settings();
    state.last_scan_at = 0;
end

local function select_match_target(match)
    if match == nil then
        return false, 'That detected entity is no longer available.';
    end

    local memory = AshitaCore:GetMemoryManager();
    if memory == nil then
        return false, 'The game memory manager is unavailable.';
    end

    local entity = memory:GetEntity();
    local target = memory:GetTarget();
    if entity == nil or target == nil then
        return false, 'The entity or target manager is unavailable.';
    end

    local check_ok, current = pcall(function()
        return is_matching_entity(
            entity,
            match.index,
            state.settings.range * state.settings.range
        );
    end);
    if not check_ok or current == nil
        or current.index ~= match.index
        or current.id ~= match.id
        or current.kind ~= match.kind
        or normalize_name(current.name) ~= normalize_name(match.name) then
        return false, match.name .. ' is no longer a valid nearby match.';
    end

    local target_ok, target_error = pcall(function()
        target:SetTarget(current.index, false);
    end);
    if not target_ok then
        return false, ('Unable to target %s: %s'):fmt(match.name, tostring(target_error));
    end

    local label = current.kind == 'npc'
        and 'NPC'
        or (current.kind == 'interactable' and 'interactable object' or 'monster');
    return true, ('Selected %s: %s'):fmt(label, current.name);
end

local function match_display_label(kind)
    if kind == 'npc' then
        return 'NPC';
    elseif kind == 'interactable' then
        return 'Interactable';
    end
    return 'Monster';
end

local function remove_match_watch(match)
    if match == nil then
        return false, 'That detected entity is no longer available.';
    end

    local index = find_watch_index(match.name, match.kind);
    if index == nil then
        return false, match.name .. ' is no longer in the watched-name list.';
    end
    return remove_watch_index(index, match.kind);
end

local function apply_overlay_font_scale(scale)
    if imgui.SetWindowFontScale then
        imgui.SetWindowFontScale(scale);
        return false;
    end

    imgui.PushFont(imgui.GetFont(), imgui.GetFontSize() * scale);
    return true;
end

local function get_current_area_name()
    -- Read independently of scanning so the area stays current while paused.
    local ok, name = pcall(function()
        local memory = AshitaCore:GetMemoryManager();
        local resources = AshitaCore:GetResourceManager();
        if memory == nil or resources == nil then
            return nil;
        end

        local party = memory:GetParty();
        if party == nil or party:GetMemberIsActive(0) == 0
            or party:GetMemberServerId(0) == 0 then
            return nil;
        end

        local zone_id = tonumber(party:GetMemberZone(0)) or 0;
        if zone_id <= 0 then
            return nil;
        end
        return resources:GetString('zones.names', zone_id);
    end);

    if ok and type(name) == 'string' and name:match('%S') then
        return name;
    end
    return 'Unknown';
end

local function get_vanadiel_time()
    if time_library == nil then
        return '--:--';
    end
    local ok, hour, minute = pcall(function()
        local raw_time = time_library.get_game_time_raw();
        return tonumber(time_library.get_game_hours(raw_time)),
            tonumber(time_library.get_game_minutes(raw_time));
    end);
    if not ok or hour == nil or minute == nil then
        return '--:--';
    end
    return ('%02d:%02d'):fmt(hour % 24, minute % 60);
end

local function transparent_icon_button(label)
    imgui.PushStyleColor(ImGuiCol_Button, {0, 0, 0, 0});
    imgui.PushStyleColor(ImGuiCol_ButtonHovered, {1, 1, 1, 0.14});
    imgui.PushStyleColor(ImGuiCol_ButtonActive, {1, 1, 1, 0.24});
    local clicked = imgui.SmallButton(label);
    imgui.PopStyleColor(3);
    return clicked;
end

local function match_height_suffix(match)
    if not state.settings.height_hint_enabled or match.height_difference == nil then
        return '';
    end
    local threshold = state.settings.height_hint_threshold_yalms;
    if match.height_difference >= threshold then
        return ' [Above]';
    elseif match.height_difference <= -threshold then
        return ' [Below]';
    end
    return '';
end

local function draw_match_overlay()
    if state.settings.display_enabled ~= true then
        return;
    end

    if state.overlay_force_position then
        imgui.SetNextWindowPos(
            {state.settings.font.position_x, state.settings.font.position_y},
            ImGuiCond_Always
        );
        state.overlay_force_position = false;
    end
    local overlay_scale = state.settings.overlay_scale_percent / 100;
    imgui.SetNextWindowBgAlpha(
        state.settings.font.background.visible == true and 0.63 or 0.0
    );

    local flags = bit.bor(
        ImGuiWindowFlags_NoDecoration,
        ImGuiWindowFlags_AlwaysAutoResize,
        ImGuiWindowFlags_NoSavedSettings,
        ImGuiWindowFlags_NoNav,
        ImGuiWindowFlags_NoFocusOnAppearing
    );
    if state.settings.overlay_locked == true then
        flags = bit.bor(flags, ImGuiWindowFlags_NoMove);
    end
    imgui.PushStyleVar(
        ImGuiStyleVar_WindowPadding,
        {6 * overlay_scale, 4 * overlay_scale}
    );
    if imgui.Begin('HorizonScout##HorizonScoutMatchOverlay', true, flags) then
        local used_push_font = apply_overlay_font_scale(overlay_scale);
        local window_x, window_y = imgui.GetWindowPos();
        state.settings.font.position_x = window_x;
        state.settings.font.position_y = window_y;

        local compact = state.settings.overlay_compact_mode == true;
        local area_text = ('Area: %s | %s'):fmt(
            get_current_area_name(),
            get_vanadiel_time()
        );
        if compact and state.settings.position_enabled then
            area_text = area_text .. ' | ' .. state.map_position;
        end
        if compact and not state.settings.enabled then
            area_text = area_text .. ' | Paused';
        end
        imgui.Text(area_text);
        local window_width = select(1, imgui.GetWindowSize());
        local collapse_icon = compact and overlay_expand_icon or overlay_collapse_icon;
        local controls_width = imgui.CalcTextSize(collapse_icon)
            + imgui.CalcTextSize(overlay_settings_icon)
            + 28 * overlay_scale;
        local controls_x = math.max(
            imgui.CalcTextSize(area_text) + 16 * overlay_scale,
            window_width - controls_width - 6 * overlay_scale
        );
        imgui.SameLine(controls_x);
        if transparent_icon_button(
            collapse_icon .. '##HorizonScoutOverlayCompact'
        ) then
            state.settings.overlay_compact_mode = not compact;
            settings.save();
        end
        if imgui.IsItemHovered() then
            imgui.BeginTooltip();
            imgui.Text(compact and 'Expand overlay' or 'Compact overlay');
            imgui.EndTooltip();
        end
        imgui.SameLine();
        if transparent_icon_button(
            overlay_settings_icon .. '##HorizonScoutOverlaySettings'
        ) then
            settings_ui.is_open[1] = not settings_ui.is_open[1];
        end
        if imgui.IsItemHovered() then
            imgui.BeginTooltip();
            imgui.Text(settings_ui.is_open[1] and 'Close settings' or 'Open settings');
            imgui.EndTooltip();
        end
        if not compact and state.settings.position_enabled then
            imgui.Text('Position: ' .. state.map_position);
        end

        if not compact and not state.settings.enabled then
            imgui.Text('Paused');
        elseif not compact and watched_name_count() == 0 then
            imgui.Text('No monster, NPC, or object names configured');
        elseif not compact and #state.matches > 0 then
            local maximum_lines = 10;
            local rows = T{};
            local maximum_text_width = 0;
            for index, match in ipairs(state.matches) do
                if index > maximum_lines then
                    break
                end
                local row_text = ('%s: %s - %.1fy'):fmt(
                    match_display_label(match.kind),
                    match.name,
                    match.distance
                ) .. match_height_suffix(match);
                local text_width = imgui.CalcTextSize(row_text);
                maximum_text_width = math.max(maximum_text_width, text_width);
                rows:append(T{text = row_text, match = match});
            end

            local target_column = math.max(
                190 * overlay_scale,
                maximum_text_width + 14 * overlay_scale
            );
            for _, row in ipairs(rows) do
                imgui.Text(row.text);
                imgui.SameLine(target_column);
                local button_id = ('Target##HorizonScoutOverlayTarget_%s_%s'):fmt(
                    row.match.kind,
                    tostring(row.match.id)
                );
                if imgui.SmallButton(button_id) then
                    local ok, feedback = select_match_target(row.match);
                    settings_ui.feedback = feedback;
                    if not ok then
                        error_message(feedback);
                    else
                        notification_message(feedback);
                    end
                end
                imgui.SameLine();
                local remove_button_id = ('Remove##HorizonScoutOverlayRemove_%s_%s'):fmt(
                    row.match.kind,
                    tostring(row.match.id)
                );
                if imgui.SmallButton(remove_button_id) then
                    local _, feedback = remove_match_watch(row.match);
                    settings_ui.feedback = feedback;
                end
            end
            if #state.matches > maximum_lines then
                imgui.Text(('...and %d more'):fmt(#state.matches - maximum_lines));
            end
        end

        if not compact and imgui.Button(
            'Add current target##HorizonScoutOverlayAddTarget'
        ) then
            local _, feedback = add_overlay_current_target();
            settings_ui.feedback = feedback;
        end
        local pending = settings_ui.pending_overlay_target;
        if not compact and pending ~= nil then
            imgui.Text(('Add %s as:'):fmt(pending.name));
            if imgui.SmallButton('NPC##HorizonScoutOverlayAddNpc') then
                local _, feedback = add_pending_overlay_target('npc');
                settings_ui.feedback = feedback;
            end
            imgui.SameLine();
            if imgui.SmallButton('Object##HorizonScoutOverlayAddObject') then
                local _, feedback = add_pending_overlay_target('interactable');
                settings_ui.feedback = feedback;
            end
        end
        if used_push_font then
            imgui.PopFont();
        end
    end
    imgui.End();
    imgui.PopStyleVar();
end

local function draw_name_editor(kind, title, input, id_prefix)
    local names = watch_names_for_kind(kind);
    imgui.Text(title);
    imgui.SameLine();
    imgui.TextDisabled('Preset: ' .. state.settings.active_preset_name);
    imgui.Separator();
    imgui.TextDisabled('Names match exactly; capitalization does not matter.');

    imgui.SetNextItemWidth(330);
    imgui.InputText('##' .. id_prefix .. 'NameInput', input, 128);
    imgui.SameLine();
    if imgui.Button('Add##' .. id_prefix .. 'AddName') then
        local ok, feedback = add_watch_name(input[1], kind);
        settings_ui.feedback = feedback;
        if ok then
            input[1] = '';
        end
    end
    if imgui.Button('Add current target##' .. id_prefix .. 'AddTarget') then
        local ok, feedback = add_current_target(kind);
        settings_ui.feedback = feedback;
        if ok then
            input[1] = '';
        end
    end

    if #names == 0 then
        imgui.TextDisabled('No ' .. kind_label(kind) .. ' names configured.');
    else
        for _, name in ipairs(names) do
            imgui.Text(display_name(name));
        end
    end

    if #names > 0 and imgui.Button('Clear names##' .. id_prefix .. 'ClearNames') then
        clear_watch_names(kind);
        settings_ui.feedback = 'Cleared all watched ' .. kind_label(kind) .. ' names.';
    end
end

local function draw_command_help()
    if not settings_ui.show_help then
        return;
    end

    imgui.Spacing();
    imgui.Separator();
    imgui.Text('Command help');
    imgui.TextWrapped('/horizonscout - open or close this window');
    imgui.TextWrapped('/horizonscout add|remove <monster name>');
    imgui.TextWrapped('/horizonscout addnpc|removenpc <NPC name>');
    imgui.TextWrapped('/horizonscout addobject|removeobject <object name>');
    imgui.TextWrapped('/horizonscout on|off - pause or resume alert scanning');
    imgui.TextWrapped('/horizonscout show|hide - match overlay');
    imgui.TextWrapped('/horizonscout compass on|off - compass and radar');
    imgui.TextWrapped('/horizonscout sound|npcsound|objectsound on|off|test');
    imgui.TextWrapped('/horizonscout aggrosound on|off|test - aggressive warning');
    imgui.TextWrapped(('/horizonscout aggrorange <%d-%d> - aggressive warning range'):fmt(
        minimum_aggressive_alert_range,
        maximum_aggressive_alert_range
    ));
    imgui.TextWrapped(('/horizonscout aggrocooldown <0-%d> - sound cooldown in seconds'):fmt(
        maximum_aggressive_sound_cooldown_seconds
    ));
    imgui.TextWrapped(('/horizonscout range <%d-%d> - alert and radar range'):fmt(
        minimum_range,
        maximum_range
    ));
    imgui.TextWrapped('/horizonscout list - show current status in this window');
    imgui.TextDisabled('Short alias: /hs. Legacy /mobalert is also accepted.');
end

local function restart_aggressive_scan()
    state.aggressive_active_ids = T{};
    state.aggressive_nearby_count = 0;
    state.last_scan_at = 0;
end

local function draw_sound_setting(
    setting_key,
    label,
    button_id,
    sound_path,
    sound_label,
    success_message,
    muted_message,
    failure_message
)
    local sound_enabled = {state.settings[setting_key]};
    if imgui.Checkbox(label, sound_enabled) then
        state.settings[setting_key] = sound_enabled[1];
        settings.save();
        state.last_scan_at = 0;
    end
    imgui.SameLine();
    if imgui.SmallButton('Test##' .. button_id) then
        if play_alert_sound(
            sound_path,
            sound_label,
            state.settings.sound_volume_percent
        ) then
            settings_ui.feedback = state.settings.sound_volume_percent == 0
                and muted_message
                or success_message;
        else
            settings_ui.feedback = failure_message;
        end
    end
end

local function draw_main_settings_tab()
    local enabled = {state.settings.enabled};
    if imgui.Checkbox('Enable scanning', enabled) then
        state.settings.enabled = enabled[1];
        update_settings();
        state.last_scan_at = 0;
    end

    local chat_notifications = {state.settings.chat_notifications_enabled};
    if imgui.Checkbox('Print routine notices in chat', chat_notifications) then
        state.settings.chat_notifications_enabled = chat_notifications[1];
        settings.save();
    end
    imgui.SameLine();
    imgui.TextDisabled('Off by default; errors remain visible');

    local display_enabled = {state.settings.display_enabled};
    if imgui.Checkbox('Show overlay', display_enabled) then
        state.settings.display_enabled = display_enabled[1];
        settings.save();
        update_display();
    end

    local overlay_locked = {state.settings.overlay_locked};
    if imgui.Checkbox('Lock overlay position', overlay_locked) then
        state.settings.overlay_locked = overlay_locked[1];
        settings.save();
    end

    local overlay_compact = {state.settings.overlay_compact_mode};
    if imgui.Checkbox('Use compact overlay mode', overlay_compact) then
        state.settings.overlay_compact_mode = overlay_compact[1];
        settings.save();
    end

    imgui.Text('Size Overlay UI');
    imgui.SameLine();
    imgui.SetNextItemWidth(190);
    local overlay_scale = {math.floor(state.settings.overlay_scale_percent)};
    if imgui.SliderInt(
        '##HorizonScoutOverlayScale',
        overlay_scale,
        50,
        200,
        '%d%%',
        ImGuiSliderFlags_AlwaysClamp
    ) then
        state.settings.overlay_scale_percent = overlay_scale[1];
        settings.save();
    end
    imgui.SameLine();
    if imgui.SmallButton('Reset##HorizonScoutOverlayScaleReset') then
        state.settings.overlay_scale_percent = 100;
        settings.save();
    end

    local position_enabled = {state.settings.position_enabled};
    if imgui.Checkbox('Show Position in Overlay', position_enabled) then
        state.settings.position_enabled = position_enabled[1];
        settings.save();
        update_display();
    end
    imgui.SameLine();
    imgui.TextDisabled('Current: ' .. state.map_position);

    local height_hint_enabled = {state.settings.height_hint_enabled};
    if imgui.Checkbox('Show above/below hints in nearby matches', height_hint_enabled) then
        state.settings.height_hint_enabled = height_hint_enabled[1];
        settings.save();
        state.last_scan_at = 0;
    end
    imgui.Text('Above/below threshold');
    imgui.SameLine();
    imgui.SetNextItemWidth(80);
    local height_threshold = {
        math.floor(state.settings.height_hint_threshold_yalms)
    };
    if imgui.InputInt('##HorizonScoutHeightThreshold', height_threshold, 1, 2) then
        state.settings.height_hint_threshold_yalms = math.max(
            1,
            math.min(20, height_threshold[1])
        );
        settings.save();
        state.last_scan_at = 0;
    end
    imgui.SameLine();
    imgui.Text('yalms');
    imgui.TextDisabled('Relative height only; not a floor number. Default: 4 yalms.');

    local compass_enabled = {state.settings.compass_enabled};
    if imgui.Checkbox('Show radar', compass_enabled) then
        state.settings.compass_enabled = compass_enabled[1];
        settings.save();
    end

    local compass_locked = {state.settings.compass_locked};
    if imgui.Checkbox('Lock radar position', compass_locked) then
        state.settings.compass_locked = compass_locked[1];
        settings.save();
    end

    local radar_north_up = {state.settings.radar_north_up};
    if imgui.Checkbox('Keep radar north-up (stop rotating)', radar_north_up) then
        state.settings.radar_north_up = radar_north_up[1];
        settings.save();
    end

    local radar_players_enabled = {state.settings.radar_players_enabled};
    if imgui.Checkbox('Show players on radar', radar_players_enabled) then
        state.settings.radar_players_enabled = radar_players_enabled[1];
        settings.save();
        state.last_scan_at = 0;
    end

    local highlight_tracked = {state.settings.radar_highlight_tracked};
    if imgui.Checkbox('Highlight tracked radar dots (gold ring)', highlight_tracked) then
        state.settings.radar_highlight_tracked = highlight_tracked[1];
        settings.save();
        state.last_scan_at = 0;
    end
    local highlight_target = {state.settings.radar_highlight_target};
    if imgui.Checkbox('Highlight selected radar target (white diamond)', highlight_target) then
        state.settings.radar_highlight_target = highlight_target[1];
        settings.save();
    end
    local hover_details = {state.settings.radar_hover_details_enabled};
    if imgui.Checkbox('Show radar details while hovering dots', hover_details) then
        state.settings.radar_hover_details_enabled = hover_details[1];
        settings.save();
    end
    imgui.TextDisabled('Hover details do not capture game clicks while the radar is locked.');

    imgui.Text('Fix player arrow heading');
    imgui.SameLine();
    imgui.SetNextItemWidth(190);
    local heading_offset = {math.floor(state.settings.compass_heading_offset_degrees)};
    if imgui.SliderInt(
        '##HorizonScoutHeadingOffset',
        heading_offset,
        -180,
        180,
        '%d deg',
        ImGuiSliderFlags_AlwaysClamp
    ) then
        state.settings.compass_heading_offset_degrees = heading_offset[1];
        settings.save();
    end
    imgui.SameLine();
    if imgui.SmallButton('Screenshot default##HorizonScoutHeadingReset') then
        state.settings.compass_heading_offset_degrees = -90;
        settings.save();
    end

    imgui.Text('Radar size');
    imgui.SameLine();
    imgui.SetNextItemWidth(190);
    local compass_size = {math.floor(state.settings.compass_size)};
    if imgui.SliderInt(
        '##HorizonScoutCompassSize',
        compass_size,
        80,
        maximum_compass_size,
        '%d px',
        ImGuiSliderFlags_AlwaysClamp
    ) then
        state.settings.compass_size = compass_size[1];
        settings.save();
    end
    imgui.SameLine();
    if imgui.SmallButton('Reset position##HorizonScoutCompassReset') then
        state.settings.compass_position_x = scaling.scale_w(80);
        state.settings.compass_position_y = scaling.scale_h(80);
        compass.request_position_reset();
        settings.save();
    end

    imgui.Text('Alert volume');
    imgui.SameLine();
    imgui.SetNextItemWidth(220);
    local sound_volume = {math.floor(state.settings.sound_volume_percent)};
    if imgui.SliderInt(
        '##HorizonScoutSoundVolume',
        sound_volume,
        0,
        150,
        '%d%%',
        ImGuiSliderFlags_AlwaysClamp
    ) then
        state.settings.sound_volume_percent = sound_volume[1];
        settings.save();
    end

    imgui.Text('Tracked-name / radar range');
    imgui.SameLine();
    imgui.SetNextItemWidth(190);
    local range = {math.floor(state.settings.range)};
    if imgui.SliderInt(
        '##HorizonScoutRange',
        range,
        minimum_range,
        maximum_range,
        '%d yalms',
        ImGuiSliderFlags_AlwaysClamp
    ) then
        state.settings.range = range[1];
        update_settings();
        state.last_scan_at = 0;
    end

    imgui.Spacing();
    local help_button_label = settings_ui.show_help
        and 'Hide command help##HorizonScoutHelp'
        or 'Show command help##HorizonScoutHelp';
    if imgui.Button(help_button_label) then
        settings_ui.show_help = not settings_ui.show_help;
    end
    draw_command_help();
end

local function draw_monsters_tab()
    local show_monsters = {state.settings.radar_monsters_enabled};
    if imgui.Checkbox('Show monsters on radar', show_monsters) then
        state.settings.radar_monsters_enabled = show_monsters[1];
        settings.save();
        state.last_scan_at = 0;
    end
    local aggressive_only = {state.settings.radar_only_aggressive_monsters};
    if imgui.Checkbox('Show only aggressive monsters on radar', aggressive_only) then
        state.settings.radar_only_aggressive_monsters = aggressive_only[1];
        settings.save();
        state.last_scan_at = 0;
    end
    imgui.TextDisabled('Aggressive-only radar filtering uses the local MobDB database.');

    local notorious_markers = {state.settings.radar_notorious_markers_enabled};
    if imgui.Checkbox('Show Notorious Monster star markers', notorious_markers) then
        state.settings.radar_notorious_markers_enabled = notorious_markers[1];
        settings.save();
        state.last_scan_at = 0;
    end
    local notorious_notification = {state.settings.notorious_notification_enabled};
    if imgui.Checkbox('Notify in chat when an NM appears on radar', notorious_notification) then
        state.settings.notorious_notification_enabled = notorious_notification[1];
        state.notorious_active_ids = T{};
        settings.save();
        state.last_scan_at = 0;
    end
    imgui.TextDisabled(
        'NM identification uses local MobDB Notorious data; unknown entries are not guessed.'
    );
    imgui.Spacing();
    draw_sound_setting(
        'sound_enabled',
        'Play tracked-monster detection sound',
        'HorizonScoutMonsterSoundTest',
        monster_sound_path,
        'monster alert',
        'Played mobalert.wav at the configured volume.',
        'Monster sound is muted at 0%.',
        'The monster sound test failed; see chat.'
    );
    draw_sound_setting(
        'aggressive_sound_enabled',
        'Play aggressive-monster warning',
        'HorizonScoutAggressiveSoundTest',
        aggressive_sound_path,
        'aggressive-monster warning',
        'Played aggressivealert.wav at the configured volume.',
        'Aggressive-monster warning is muted at 0%.',
        'The aggressive-monster sound test failed; see chat.'
    );

    imgui.Text('Aggressive warning range');
    imgui.SameLine();
    imgui.SetNextItemWidth(90);
    local aggressive_range = {math.floor(state.settings.aggressive_alert_range)};
    if imgui.InputInt('##HorizonScoutAggressiveRange', aggressive_range, 1, 5) then
        state.settings.aggressive_alert_range = math.max(
            minimum_aggressive_alert_range,
            math.min(maximum_aggressive_alert_range, aggressive_range[1])
        );
        settings.save();
        restart_aggressive_scan();
    end
    imgui.SameLine();
    imgui.Text('yalms');

    imgui.Text('Aggressive sound cooldown');
    imgui.SameLine();
    imgui.SetNextItemWidth(90);
    local aggressive_cooldown = {
        math.floor(state.settings.aggressive_sound_cooldown_seconds)
    };
    if imgui.InputInt('##HorizonScoutAggressiveCooldown', aggressive_cooldown, 1, 5) then
        state.settings.aggressive_sound_cooldown_seconds = math.max(
            0,
            math.min(
                maximum_aggressive_sound_cooldown_seconds,
                aggressive_cooldown[1]
            )
        );
        settings.save();
    end
    imgui.SameLine();
    imgui.Text('seconds');
    imgui.TextDisabled('Automatic warning only; 0 disables the cooldown.');

    local suppress_on_chocobo = {state.settings.aggressive_suppress_on_chocobo};
    if imgui.Checkbox('Suppress aggressive warning while on a chocobo', suppress_on_chocobo) then
        state.settings.aggressive_suppress_on_chocobo = suppress_on_chocobo[1];
        settings.save();
        restart_aggressive_scan();
    end

    local level_filter = {state.settings.aggressive_level_filter_enabled};
    if imgui.Checkbox('Ignore aggressive monsters far below your level', level_filter) then
        state.settings.aggressive_level_filter_enabled = level_filter[1];
        settings.save();
        restart_aggressive_scan();
    end
    imgui.Text('Ignore when at least');
    imgui.SameLine();
    imgui.SetNextItemWidth(70);
    local level_gap = {math.floor(state.settings.aggressive_level_gap)};
    if imgui.InputInt('##HorizonScoutAggressiveLevelGap', level_gap, 1, 5) then
        state.settings.aggressive_level_gap = math.max(1, math.min(99, level_gap[1]));
        settings.save();
        restart_aggressive_scan();
    end
    imgui.SameLine();
    imgui.Text('levels below your main job');
    imgui.TextDisabled('Uses the monster maximum spawn level; unknown levels still alert.');

    local aggression_status = state.aggressive_suppressed_on_chocobo
        and 'suppressed on chocobo'
        or ('nearby: %d'):fmt(state.aggressive_nearby_count);
    imgui.TextDisabled(
        ('Database: %s | main level: %d | %s'):fmt(
            aggro_database.get_status(),
            state.player_main_job_level,
            aggression_status
        )
    );
    local cooldown_remaining = aggressive_sound_cooldown_remaining(tick_seconds());
    if cooldown_remaining > 0 then
        imgui.TextDisabled(('Sound cooldown: %.1f seconds remaining'):fmt(cooldown_remaining));
    else
        imgui.TextDisabled('Sound cooldown: ready');
    end

    imgui.Spacing();
    draw_name_editor('monster', 'Monster names', settings_ui.name_input, 'HorizonScoutMonster');
end

local function draw_npcs_tab()
    local show_npcs = {state.settings.radar_npcs_enabled};
    if imgui.Checkbox("Show NPC's on radar", show_npcs) then
        state.settings.radar_npcs_enabled = show_npcs[1];
        settings.save();
        state.last_scan_at = 0;
    end
    imgui.Spacing();
    draw_sound_setting(
        'npc_sound_enabled',
        'Play NPC detection sound',
        'HorizonScoutNpcSoundTest',
        npc_sound_path,
        'NPC alert',
        'Played npcalert.wav at the configured volume.',
        'NPC sound is muted at 0%.',
        'The NPC sound test failed; see chat.'
    );
    imgui.Spacing();
    draw_name_editor('npc', 'NPC names', settings_ui.npc_name_input, 'HorizonScoutNpc');
end

local function draw_objects_tab()
    local show_objects = {state.settings.radar_objects_enabled};
    if imgui.Checkbox('Show objects on radar', show_objects) then
        state.settings.radar_objects_enabled = show_objects[1];
        settings.save();
        state.last_scan_at = 0;
    end
    imgui.Spacing();
    draw_sound_setting(
        'interactable_sound_enabled',
        'Play interactable-object detection sound',
        'HorizonScoutInteractableSoundTest',
        interactable_sound_path,
        'interactable-object alert',
        'Played interactablealert.wav at the configured volume.',
        'Interactable-object sound is muted at 0%.',
        'The interactable-object sound test failed; see chat.'
    );
    imgui.Spacing();
    draw_name_editor(
        'interactable',
        'Interactable object names',
        settings_ui.interactable_name_input,
        'HorizonScoutInteractable'
    );
end

local function draw_presets_tab()
    imgui.Text('Named tracking presets');
    imgui.TextDisabled(
        'Monster, NPC, and object exact-name lists belong to the active preset.'
    );
    imgui.Text('Active: ' .. state.settings.active_preset_name);
    imgui.Text('Fallback for unassigned zones: ' .. state.settings.fallback_preset_name);

    local zone_key = state.zone_id ~= nil and tostring(state.zone_id) or nil;
    local zone_assignment = zone_key ~= nil
        and state.settings.zone_preset_assignments[zone_key]
        or nil;
    imgui.Text('Current area: ' .. get_current_area_name());
    if zone_assignment ~= nil then
        imgui.Text('Automatic preset: ' .. zone_assignment);
        if imgui.SmallButton('Remove area assignment##HorizonScoutPresetUnassign') then
            local _, feedback = unassign_current_zone_preset();
            settings_ui.feedback = feedback;
        end
    else
        imgui.TextDisabled('No area assignment; the fallback preset is active.');
    end

    imgui.Spacing();
    imgui.Separator();
    imgui.Text('Create preset');
    imgui.SetNextItemWidth(260);
    imgui.InputText('##HorizonScoutPresetName', settings_ui.preset_name_input, 40);
    if imgui.Button('Create empty##HorizonScoutPresetCreateEmpty') then
        local ok, feedback = create_tracking_preset(
            settings_ui.preset_name_input[1],
            false
        );
        settings_ui.feedback = feedback;
        if ok then
            settings_ui.preset_name_input[1] = '';
        end
    end
    imgui.SameLine();
    if imgui.Button('Copy active##HorizonScoutPresetCreateCopy') then
        local ok, feedback = create_tracking_preset(
            settings_ui.preset_name_input[1],
            true
        );
        settings_ui.feedback = feedback;
        if ok then
            settings_ui.preset_name_input[1] = '';
        end
    end

    imgui.Spacing();
    imgui.Separator();
    for index, preset in ipairs(state.settings.tracking_presets) do
        local is_active = normalize_name(preset.name)
            == normalize_name(state.settings.active_preset_name);
        imgui.Text(('%s%s  (M:%d  NPC:%d  Obj:%d)'):fmt(
            is_active and '> ' or '',
            preset.name,
            #preset.watch_names,
            #preset.npc_watch_names,
            #preset.interactable_watch_names
        ));
        if imgui.SmallButton(
            'Use as fallback##HorizonScoutPresetUse' .. tostring(index)
        ) then
            local _, feedback = set_fallback_tracking_preset(preset.name);
            settings_ui.feedback = feedback;
        end
        imgui.SameLine();
        if imgui.SmallButton(
            'Assign current area##HorizonScoutPresetAssign' .. tostring(index)
        ) then
            local _, feedback = assign_current_zone_to_preset(preset.name);
            settings_ui.feedback = feedback;
        end
        if normalize_name(preset.name) ~= 'default' then
            imgui.SameLine();
            if imgui.SmallButton(
                'Delete##HorizonScoutPresetDelete' .. tostring(index)
            ) then
                local _, feedback = delete_tracking_preset(preset.name);
                settings_ui.feedback = feedback;
                return;
            end
        end
    end
end

local function draw_settings_ui()
    if not settings_ui.is_open[1] then
        return;
    end

    imgui.SetNextWindowSize({460, 0}, ImGuiCond_FirstUseEver);
    if imgui.Begin(
        'HorizonScout Settings##HorizonScoutSettings',
        settings_ui.is_open,
        ImGuiWindowFlags_AlwaysAutoResize
    ) then
        if imgui.BeginTabBar('##HorizonScoutSettingsTabs') then
            if imgui.BeginTabItem('Settings') then
                draw_main_settings_tab();
                imgui.EndTabItem();
            end
            if imgui.BeginTabItem('Monsters') then
                draw_monsters_tab();
                imgui.EndTabItem();
            end
            if imgui.BeginTabItem("NPC's") then
                draw_npcs_tab();
                imgui.EndTabItem();
            end
            if imgui.BeginTabItem('Objects') then
                draw_objects_tab();
                imgui.EndTabItem();
            end
            if imgui.BeginTabItem('Presets') then
                draw_presets_tab();
                imgui.EndTabItem();
            end
            imgui.EndTabBar();
        end

        imgui.Spacing();
        imgui.Separator();
        imgui.Text(('Detected nearby: %d'):fmt(#state.matches));
        if #state.matches == 0 then
            imgui.TextDisabled('No current matches to target.');
        else
            imgui.TextDisabled('Target and Remove buttons are shown in the nearby-match overlay.');
        end
        if settings_ui.feedback ~= '' then
            imgui.TextDisabled(settings_ui.feedback);
        end
    end
    imgui.End();
end

local function show_status()
    settings_ui.is_open[1] = true;
    settings_ui.feedback = ('Status: %s | overlay %s | radar %s | range %.0fy'):fmt(
        state.settings.enabled and 'running' or 'paused',
        state.settings.display_enabled and 'shown' or 'hidden',
        state.settings.compass_enabled and 'shown' or 'hidden',
        state.settings.range
    );
end

local function show_help(feedback)
    settings_ui.is_open[1] = true;
    settings_ui.show_help = true;
    settings_ui.feedback = feedback or 'Command help opened below.';
end

ashita.events.register('load', 'HorizonScout_Load', function()
    map_grid.init();
    state.font = fonts.new(state.settings.font);
    state.last_scan_at = 0;
    rebuild_watch_lookup();

    if not sound_file_exists(monster_sound_path) then
        error_message('mobalert.wav is missing from the addon folder.');
    end
    if not sound_file_exists(npc_sound_path) then
        error_message('npcalert.wav is missing; NPC alerts will be visual and chat-only.');
    end
    if not sound_file_exists(interactable_sound_path) then
        error_message(
            'interactablealert.wav is missing; object alerts will remain visible on the radar.'
        );
    end
    if not sound_file_exists(aggressive_sound_path) then
        error_message(
            'aggressivealert.wav is missing; aggressive-monster warnings are disabled.'
        );
    end
    notification_message(
        'Loaded. Detection and radar are read-only; targeting requires a button click.'
    );
end);

ashita.events.register('command', 'HorizonScout_Command', function(e)
    local args = e.command:args();
    if #args == 0 or not args[1]:any('/horizonscout', '/hs', '/mobalert') then
        return;
    end

    e.blocked = true;
    local command = #args >= 2 and normalize_name(args[2]):lower() or '';
    if command == '' then
        settings_ui.is_open[1] = not settings_ui.is_open[1];
        return;
    end

    if command == 'config' or command == 'settings' or command == 'ui' then
        settings_ui.is_open[1] = true;
        return;
    end

    if command == 'help' then
        show_help();
        return;
    end

    if command == 'list' or command == 'status' then
        show_status();
        return;
    end

    if command == 'add' then
        local name = joined_argument(args, 3);
        local ok, feedback = add_watch_name(name, 'monster');
        if ok then
            notification_message(feedback);
        else
            error_message(feedback);
        end
        return;
    end

    if command == 'addnpc' or command == 'npcadd' then
        local name = joined_argument(args, 3);
        local ok, feedback = add_watch_name(name, 'npc');
        if ok then
            notification_message(feedback);
        else
            error_message(feedback);
        end
        return;
    end

    if command == 'addobject' or command == 'objectadd' then
        local name = joined_argument(args, 3);
        local ok, feedback = add_watch_name(name, 'interactable');
        if ok then
            notification_message(feedback);
        else
            error_message(feedback);
        end
        return;
    end

    if command == 'remove' or command == 'delete' then
        local name = joined_argument(args, 3);
        local index = find_watch_index(name, 'monster');
        if index == nil then
            error_message(name ~= '' and (name .. ' is not being watched.')
                or 'Use: /horizonscout remove <monster name>');
            return;
        end
        local _, feedback = remove_watch_index(index, 'monster');
        notification_message(feedback);
        return;
    end

    if command == 'removenpc' or command == 'deletenpc' or command == 'npcremove' then
        local name = joined_argument(args, 3);
        local index = find_watch_index(name, 'npc');
        if index == nil then
            error_message(name ~= '' and (name .. ' is not in the NPC list.')
                or 'Use: /horizonscout removenpc <NPC name>');
            return;
        end
        local _, feedback = remove_watch_index(index, 'npc');
        notification_message(feedback);
        return;
    end

    if command == 'removeobject' or command == 'deleteobject'
        or command == 'objectremove' then
        local name = joined_argument(args, 3);
        local index = find_watch_index(name, 'interactable');
        if index == nil then
            error_message(name ~= '' and (name .. ' is not in the interactable object list.')
                or 'Use: /horizonscout removeobject <object name>');
            return;
        end
        local _, feedback = remove_watch_index(index, 'interactable');
        notification_message(feedback);
        return;
    end

    if command == 'clear' then
        clear_watch_names('monster');
        notification_message('Cleared all watched monster names.');
        return;
    end

    if command == 'clearnpcs' then
        clear_watch_names('npc');
        notification_message('Cleared all watched NPC names.');
        return;
    end

    if command == 'clearobjects' then
        clear_watch_names('interactable');
        notification_message('Cleared all watched interactable object names.');
        return;
    end

    if command == 'on' or command == 'off' then
        state.settings.enabled = command == 'on';
        update_settings();
        state.last_scan_at = 0;
        notification_message(
            state.settings.enabled and 'Scanning resumed.' or 'Scanning paused.'
        );
        return;
    end

    if command == 'show' or command == 'hide' then
        state.settings.display_enabled = command == 'show';
        settings.save();
        update_display();
        notification_message(
            state.settings.display_enabled and 'Overlay shown.' or 'Overlay hidden.'
        );
        return;
    end

    if command == 'compass' and #args == 3 then
        local option = args[3]:lower();
        if option == 'on' or option == 'off' then
            state.settings.compass_enabled = option == 'on';
            settings.save();
            notification_message(
                state.settings.compass_enabled and 'Compass shown.' or 'Compass hidden.'
            );
            return;
        end
    end

    if command == 'sound' and #args == 3 then
        local option = args[3]:lower();
        if option == 'test' then
            if play_alert_sound(
                monster_sound_path,
                'monster alert',
                state.settings.sound_volume_percent
            ) then
                notification_message('Played the monster alert sound.');
            end
            return;
        end
        if option == 'on' or option == 'off' then
            state.settings.sound_enabled = option == 'on';
            settings.save();
            notification_message(state.settings.sound_enabled and 'Sound alerts enabled.'
                or 'Sound alerts disabled.');
            return;
        end
    end

    if command == 'npcsound' and #args == 3 then
        local option = args[3]:lower();
        if option == 'test' then
            if play_alert_sound(
                npc_sound_path,
                'NPC alert',
                state.settings.sound_volume_percent
            ) then
                notification_message('Played the NPC alert sound.');
            end
            return;
        end
        if option == 'on' or option == 'off' then
            state.settings.npc_sound_enabled = option == 'on';
            settings.save();
            notification_message(state.settings.npc_sound_enabled and 'NPC sound alerts enabled.'
                or 'NPC sound alerts disabled.');
            return;
        end
    end

    if (command == 'objectsound' or command == 'interactablesound') and #args == 3 then
        local option = args[3]:lower();
        if option == 'test' then
            if play_alert_sound(
                interactable_sound_path,
                'interactable-object alert',
                state.settings.sound_volume_percent
            ) then
                notification_message('Played the interactable-object alert sound.');
            end
            return;
        end
        if option == 'on' or option == 'off' then
            state.settings.interactable_sound_enabled = option == 'on';
            settings.save();
            state.last_scan_at = 0;
            notification_message(
                state.settings.interactable_sound_enabled
                    and 'Interactable-object sound alerts enabled.'
                    or 'Interactable-object sound alerts disabled.'
            );
            return;
        end
    end

    if (command == 'aggrosound' or command == 'aggressivesound') and #args == 3 then
        local option = args[3]:lower();
        if option == 'test' then
            if play_alert_sound(
                aggressive_sound_path,
                'aggressive-monster warning',
                state.settings.sound_volume_percent
            ) then
                notification_message('Played the aggressive-monster warning sound.');
            end
            return;
        end
        if option == 'on' or option == 'off' then
            state.settings.aggressive_sound_enabled = option == 'on';
            settings.save();
            state.last_scan_at = 0;
            notification_message(
                state.settings.aggressive_sound_enabled
                    and 'Aggressive-monster warnings enabled.'
                    or 'Aggressive-monster warnings disabled.'
            );
            return;
        end
    end

    if (command == 'aggrorange' or command == 'aggressiverange') and #args == 3 then
        local requested = tonumber(args[3]);
        if requested == nil or requested < minimum_aggressive_alert_range
            or requested > maximum_aggressive_alert_range then
            error_message(('Aggressive warning range must be between %d and %d yalms.'):fmt(
                minimum_aggressive_alert_range,
                maximum_aggressive_alert_range
            ));
            return;
        end
        state.settings.aggressive_alert_range = requested;
        settings.save();
        restart_aggressive_scan();
        notification_message(('Aggressive warning range set to %.0f yalms.'):fmt(requested));
        return;
    end

    if (command == 'aggrocooldown' or command == 'aggressivecooldown') and #args == 3 then
        local requested = tonumber(args[3]);
        if requested == nil or requested < 0
            or requested > maximum_aggressive_sound_cooldown_seconds then
            error_message(('Aggressive sound cooldown must be between 0 and %d seconds.'):fmt(
                maximum_aggressive_sound_cooldown_seconds
            ));
            return;
        end
        state.settings.aggressive_sound_cooldown_seconds = requested;
        settings.save();
        notification_message(('Aggressive sound cooldown set to %.0f seconds.'):fmt(requested));
        return;
    end

    if command == 'range' and #args == 3 then
        local requested = tonumber(args[3]);
        if requested == nil or requested < minimum_range or requested > maximum_range then
            error_message(('Range must be between %d and %d yalms.'):fmt(
                minimum_range,
                maximum_range
            ));
            return;
        end
        state.settings.range = requested;
        update_settings();
        state.last_scan_at = 0;
        notification_message(('Detection range set to %.0f yalms.'):fmt(requested));
        return;
    end

    show_help('Unknown command: ' .. command);
end);

ashita.events.register('d3d_present', 'HorizonScout_Present', function()
    local now = tick_seconds();
    if state.last_scan_at == 0 or (now - state.last_scan_at) >= scan_interval_seconds then
        state.last_scan_at = now;
        scan_entities();
    end
    state.map_position = map_grid.get_position();
    update_display();
    draw_match_overlay();
    compass.draw(
        state.settings,
        state.radar_entities,
        state.settings.range
    );
    sound_player.tick();
    draw_settings_ui();
end);

ashita.events.register('unload', 'HorizonScout_Unload', function()
    sound_player.shutdown();
    aggro_database.reset();
    settings.save();
    map_grid.reset();
    settings_ui.is_open[1] = false;
    if state.font ~= nil then
        state.font:destroy();
        state.font = nil;
    end
    clear_observation_state();
end);
