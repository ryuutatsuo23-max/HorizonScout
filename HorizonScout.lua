addon.name = 'HorizonScout';
addon.author = 'Horizon Assist contributors';
addon.version = '0.10.2';
addon.desc = 'Nearby alerts, object-aware compass radar, map position, and explicit user targeting.';
addon.link = '';

require('common');

local chat = require('chat');
local compass = require('compass');
local fonts = require('fonts');
local imgui = require('imgui');
local map_grid = require('map_grid');
local scaling = require('scaling');
local settings = require('settings');
local sound_player = require('sound_player');

local maximum_entity_index = 0x08FF;
local scan_interval_seconds = 0.50;
local minimum_range = 1;
local maximum_range = 50;
local visible_render_flag = 0x0200;
local hidden_render_flag = 0x4000;
local monster_spawn_flag = 0x0010;
local npc_spawn_flag = 0x0002;
local player_spawn_flag = 0x0001;
local environment_spawn_flag = 0x0020;
local monster_sound_path = addon.path .. '\\mobalert.wav';
local npc_sound_path = addon.path .. '\\npcalert.wav';
local interactable_sound_path = addon.path .. '\\interactablealert.wav';

local default_settings = T{
    enabled = true,
    display_enabled = true,
    position_enabled = true,
    sound_enabled = true,
    npc_sound_enabled = true,
    interactable_sound_enabled = true,
    sound_volume_percent = 100,
    chat_notifications_enabled = false,
    compass_enabled = true,
    compass_locked = false,
    radar_enabled = true,
    overlay_scale_percent = 100,
    compass_size = scaling.scale_f(112),
    compass_heading_offset_degrees = -90,
    compass_position_x = scaling.scale_w(80),
    compass_position_y = scaling.scale_h(80),
    range = 50,
    watch_names = T{},
    npc_watch_names = T{},
    interactable_watch_names = T{},
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
    feedback = '',
    show_help = false,
};

local function tick_seconds()
    return ashita.time.tick64() / 1000;
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

local function notification_message(value)
    if state.settings.chat_notifications_enabled == true then
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

local function clear_observation_state()
    state.active_ids = T{};
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
    state.settings.watch_names = state.settings.watch_names or T{};
    state.settings.npc_watch_names = state.settings.npc_watch_names or T{};
    state.settings.interactable_watch_names = state.settings.interactable_watch_names or T{};
    if state.settings.compass_enabled == nil then
        state.settings.compass_enabled = true;
    end
    if state.settings.compass_locked == nil then
        state.settings.compass_locked = false;
    end
    if state.settings.radar_enabled == nil then
        state.settings.radar_enabled = true;
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
    state.settings.sound_volume_percent = math.max(
        0,
        math.min(150, tonumber(state.settings.sound_volume_percent) or 100)
    );
    state.settings.compass_size = math.max(
        80,
        math.min(180, tonumber(state.settings.compass_size) or scaling.scale_f(112))
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
        state.settings.watch_names = migrated_names;
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
        kind = bit.band(spawn_flags, environment_spawn_flag) ~= 0
            and 'interactable'
            or 'npc';
    end
    if kind == nil then
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
        name = display_name(entity:GetName(index)),
        kind = kind,
        delta_x = delta_x,
        delta_y = delta_y,
        distance = math.sqrt(distance_squared),
    };
end

local function scan_entities()
    local alert_scanning = state.settings.enabled and watched_name_count() > 0;
    local radar_scanning = state.settings.compass_enabled
        and state.settings.radar_enabled;
    if not alert_scanning and not radar_scanning then
        clear_observation_state();
        return;
    end

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
        return;
    end

    local current_zone_id = tonumber(party:GetMemberZone(0));
    if state.zone_id ~= current_zone_id then
        clear_observation_state();
        state.zone_id = current_zone_id;
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
    local radar_candidates = T{};
    local pet_indices = T{};
    local maximum_distance_squared = state.settings.range * state.settings.range;
    local player_index = tonumber(party:GetMemberTargetIndex(0));
    local player_x = nil;
    local player_y = nil;
    if radar_scanning and player_index ~= nil then
        player_x = tonumber(entity:GetLocalPositionX(player_index));
        player_y = tonumber(entity:GetLocalPositionY(player_index));
    end
    if player_index == nil or player_x == nil or player_y == nil then
        radar_scanning = false;
    end

    for index = 0, maximum_entity_index do
        if radar_scanning then
            if (tonumber(entity:GetServerId(index)) or 0) ~= 0 then
                local pet_index = tonumber(entity:GetPetTargetIndex(index)) or 0;
                if pet_index ~= 0 then
                    pet_indices[pet_index] = true;
                end

                if index ~= player_index then
                    local radar_entity = get_radar_entity(
                        entity,
                        index,
                        player_x,
                        player_y,
                        maximum_distance_squared
                    );
                    if radar_entity ~= nil then
                        radar_candidates:append(radar_entity);
                    end
                end
            end
        end

        if alert_scanning then
            local match = is_matching_entity(entity, index, maximum_distance_squared);
            if match ~= nil then
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

    next_matches:sort(function(left, right)
        if left.distance == right.distance then
            return left.name < right.name;
        end
        return left.distance < right.distance;
    end);

    state.active_ids = next_active_ids;
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
    if kind == 'npc' then
        state.settings.npc_watch_names = T{};
    elseif kind == 'interactable' then
        state.settings.interactable_watch_names = T{};
    else
        state.settings.watch_names = T{};
    end
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
    imgui.PushStyleVar(
        ImGuiStyleVar_WindowPadding,
        {6 * overlay_scale, 4 * overlay_scale}
    );
    if imgui.Begin('HorizonScout##HorizonScoutMatchOverlay', true, flags) then
        local used_push_font = apply_overlay_font_scale(overlay_scale);
        local window_x, window_y = imgui.GetWindowPos();
        state.settings.font.position_x = window_x;
        state.settings.font.position_y = window_y;

        imgui.Text('HorizonScout');
        if state.settings.position_enabled then
            imgui.Text('Position: ' .. state.map_position);
        end

        if not state.settings.enabled then
            imgui.Text('Paused');
        elseif watched_name_count() == 0 then
            imgui.Text('No monster, NPC, or object names configured');
        elseif #state.matches == 0 then
            imgui.Text(('No matches within %.0f yalms'):fmt(state.settings.range));
        else
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
                );
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
    imgui.TextWrapped(('/horizonscout range <%d-%d> - alert and radar range'):fmt(
        minimum_range,
        maximum_range
    ));
    imgui.TextWrapped('/horizonscout list - show current status in this window');
    imgui.TextDisabled('Short alias: /hs. Legacy /mobalert is also accepted.');
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
        imgui.Text('Detection');
        imgui.Separator();

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
        if imgui.Checkbox('Show nearby-match overlay', display_enabled) then
            state.settings.display_enabled = display_enabled[1];
            settings.save();
            update_display();
        end

        imgui.Text('Small UI scale');
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
        if imgui.Checkbox('Show map-grid position in overlay', position_enabled) then
            state.settings.position_enabled = position_enabled[1];
            settings.save();
            update_display();
        end
        imgui.SameLine();
        imgui.TextDisabled('Current: ' .. state.map_position);

        local compass_enabled = {state.settings.compass_enabled};
        if imgui.Checkbox('Show player-facing compass', compass_enabled) then
            state.settings.compass_enabled = compass_enabled[1];
            settings.save();
        end

        local compass_locked = {state.settings.compass_locked};
        if imgui.Checkbox('Lock compass position', compass_locked) then
            state.settings.compass_locked = compass_locked[1];
            settings.save();
        end

        local radar_enabled = {state.settings.radar_enabled};
        if imgui.Checkbox('Show nearby dots on compass', radar_enabled) then
            state.settings.radar_enabled = radar_enabled[1];
            settings.save();
            state.last_scan_at = 0;
        end
        imgui.SameLine();
        imgui.TextDisabled('Blue players | red monsters | green NPCs / objects');

        imgui.Text('Heading correction');
        imgui.SameLine();
        imgui.SetNextItemWidth(190);
        local heading_offset = {
            math.floor(state.settings.compass_heading_offset_degrees)
        };
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

        imgui.Text('Compass size');
        imgui.SameLine();
        imgui.SetNextItemWidth(190);
        local compass_size = {math.floor(state.settings.compass_size)};
        if imgui.SliderInt(
            '##HorizonScoutCompassSize',
            compass_size,
            80,
            180,
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

        local sound_enabled = {state.settings.sound_enabled};
        if imgui.Checkbox('Play monster detection sound', sound_enabled) then
            state.settings.sound_enabled = sound_enabled[1];
            settings.save();
        end
        imgui.SameLine();
        if imgui.SmallButton('Test##HorizonScoutMonsterSoundTest') then
            if play_alert_sound(
                monster_sound_path,
                'monster alert',
                state.settings.sound_volume_percent
            ) then
                settings_ui.feedback = state.settings.sound_volume_percent == 0
                    and 'Monster sound is muted at 0%.'
                    or 'Played mobalert.wav at the configured volume.';
            else
                settings_ui.feedback = 'The monster sound test failed; see chat.';
            end
        end

        local npc_sound_enabled = {state.settings.npc_sound_enabled};
        if imgui.Checkbox('Play NPC detection sound', npc_sound_enabled) then
            state.settings.npc_sound_enabled = npc_sound_enabled[1];
            settings.save();
        end
        imgui.SameLine();
        if imgui.SmallButton('Test##HorizonScoutNpcSoundTest') then
            if play_alert_sound(
                npc_sound_path,
                'NPC alert',
                state.settings.sound_volume_percent
            ) then
                settings_ui.feedback = state.settings.sound_volume_percent == 0
                    and 'NPC sound is muted at 0%.'
                    or 'Played npcalert.wav at the configured volume.';
            else
                settings_ui.feedback = 'The NPC sound test failed; see chat.';
            end
        end

        local interactable_sound_enabled = {state.settings.interactable_sound_enabled};
        if imgui.Checkbox(
            'Play interactable-object detection sound',
            interactable_sound_enabled
        ) then
            state.settings.interactable_sound_enabled = interactable_sound_enabled[1];
            settings.save();
            state.last_scan_at = 0;
        end
        imgui.SameLine();
        if imgui.SmallButton('Test##HorizonScoutInteractableSoundTest') then
            if play_alert_sound(
                interactable_sound_path,
                'interactable-object alert',
                state.settings.sound_volume_percent
            ) then
                settings_ui.feedback = state.settings.sound_volume_percent == 0
                    and 'Interactable-object sound is muted at 0%.'
                    or 'Played interactablealert.wav at the configured volume.';
            else
                settings_ui.feedback = 'The interactable-object sound test failed; see chat.';
            end
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

        imgui.Text('Detection range');
        imgui.SameLine();
        imgui.SetNextItemWidth(220);
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
        draw_name_editor('monster', 'Monster names', settings_ui.name_input, 'HorizonScoutMonster');
        imgui.Spacing();
        draw_name_editor('npc', 'NPC names', settings_ui.npc_name_input, 'HorizonScoutNpc');
        imgui.Spacing();
        draw_name_editor(
            'interactable',
            'Interactable object names',
            settings_ui.interactable_name_input,
            'HorizonScoutInteractable'
        );

        imgui.Spacing();
        local help_button_label = settings_ui.show_help
            and 'Hide command help##HorizonScoutHelp'
            or 'Show command help##HorizonScoutHelp';
        if imgui.Button(help_button_label) then
            settings_ui.show_help = not settings_ui.show_help;
        end
        draw_command_help();

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
    settings_ui.feedback = ('Status: %s | overlay %s | compass %s | radar %s | range %.0fy'):fmt(
        state.settings.enabled and 'running' or 'paused',
        state.settings.display_enabled and 'shown' or 'hidden',
        state.settings.compass_enabled and 'shown' or 'hidden',
        state.settings.radar_enabled and 'on' or 'off',
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
    settings.save();
    map_grid.reset();
    settings_ui.is_open[1] = false;
    if state.font ~= nil then
        state.font:destroy();
        state.font = nil;
    end
    clear_observation_state();
end);
