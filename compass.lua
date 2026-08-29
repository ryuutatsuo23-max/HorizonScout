local imgui = require('imgui');

local compass = {};
local pi = math.pi;
local two_pi = pi * 2;
local force_position = true;

-- FFXI's horizontal heading convention is S=0, W=pi/2, N=pi, E=3pi/2.
local cardinals = {
    {label = 'S', angle = 0},
    {label = 'W', angle = pi / 2},
    {label = 'N', angle = pi},
    {label = 'E', angle = pi * 3 / 2},
};

local function player_heading()
    local ok, result = pcall(function()
        local memory = AshitaCore:GetMemoryManager();
        if memory == nil then
            return nil;
        end

        local party = memory:GetParty();
        local entity = memory:GetEntity();
        if party == nil or entity == nil
            or party:GetMemberIsActive(0) == 0
            or party:GetMemberServerId(0) == 0 then
            return nil;
        end

        local player_index = tonumber(party:GetMemberTargetIndex(0));
        if player_index == nil then
            return nil;
        end

        local heading = tonumber(entity:GetHeading(player_index));
        if heading == nil or heading ~= heading then
            heading = tonumber(entity:GetLocalPositionYaw(player_index));
        end
        if heading == nil or heading ~= heading then
            return nil;
        end

        -- Some entity wrappers expose the same heading as a 0-255 value.
        if math.abs(heading) > two_pi + 0.01 then
            heading = heading * two_pi / 256;
        end
        return heading % two_pi;
    end);

    return ok and result or nil;
end

local function centered_text(draw_list, x, y, color, value)
    local width, height = imgui.CalcTextSize(value);
    draw_list:AddText({x - width / 2, y - height / 2}, color, value);
end

function compass.request_position_reset()
    force_position = true;
end

function compass.draw(config, radar_entities, radar_range)
    if config.compass_enabled ~= true then
        return;
    end

    local heading = player_heading();
    if heading == nil then
        return;
    end
    local heading_offset = tonumber(config.compass_heading_offset_degrees) or -90;
    heading = (heading + heading_offset * pi / 180) % two_pi;

    local diameter = math.max(80, math.min(180, tonumber(config.compass_size) or 112));
    local window_width = diameter + 16;
    local window_height = diameter + 16;
    if force_position then
        imgui.SetNextWindowPos(
            {config.compass_position_x, config.compass_position_y},
            ImGuiCond_Always
        );
        force_position = false;
    else
        imgui.SetNextWindowPos(
            {config.compass_position_x, config.compass_position_y},
            ImGuiCond_FirstUseEver
        );
    end
    imgui.SetNextWindowSize({window_width, window_height}, ImGuiCond_Always);
    imgui.SetNextWindowBgAlpha(0.0);

    local flags = bit.bor(
        ImGuiWindowFlags_NoDecoration,
        ImGuiWindowFlags_NoNav,
        ImGuiWindowFlags_NoFocusOnAppearing,
        ImGuiWindowFlags_NoBringToFrontOnFocus,
        ImGuiWindowFlags_NoBackground
    );
    if config.compass_locked == true then
        flags = bit.bor(flags, ImGuiWindowFlags_NoMove, ImGuiWindowFlags_NoMouseInputs);
    end

    imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, {0, 0});
    if imgui.Begin('Compass##HorizonScoutCompass', true, flags) then
        imgui.Dummy({window_width, window_height});

        local window_x, window_y = imgui.GetWindowPos();
        config.compass_position_x = window_x;
        config.compass_position_y = window_y;

        local draw_list = imgui.GetWindowDrawList();
        local center_x = window_x + window_width / 2;
        local center_y = window_y + diameter / 2 + 8;
        local radius = diameter * 0.42;

        draw_list:AddCircleFilled(
            {center_x, center_y},
            radius,
            0xC0202020,
            48
        );
        draw_list:AddCircle(
            {center_x, center_y},
            radius,
            0xFFE0E0E0,
            48,
            2.0
        );

        for tick = 0, 15 do
            local angle = tick * two_pi / 16;
            local screen_angle = angle - heading - pi / 2;
            local outer_x = center_x + math.cos(screen_angle) * (radius - 3);
            local outer_y = center_y + math.sin(screen_angle) * (radius - 3);
            local tick_length = tick % 4 == 0 and 9 or 5;
            local inner_x = center_x + math.cos(screen_angle) * (radius - tick_length);
            local inner_y = center_y + math.sin(screen_angle) * (radius - tick_length);
            draw_list:AddLine(
                {inner_x, inner_y},
                {outer_x, outer_y},
                0xFFB8B8B8,
                tick % 4 == 0 and 2.0 or 1.0
            );
        end

        if config.radar_enabled == true then
            local maximum_range = math.max(1, tonumber(radar_range) or 50);
            local colors = {
                player = 0xFFFF6868,
                monster = 0xFF5050E8,
                npc = 0xFF60D060,
                interactable = 0xFF60D060,
            };
            for _, radar_entity in ipairs(radar_entities or {}) do
                local distance = tonumber(radar_entity.distance) or 0;
                if distance <= maximum_range then
                    local angle = math.atan2(
                        -radar_entity.delta_x,
                        -radar_entity.delta_y
                    ) - heading - pi / 2;
                    local pixel_distance = distance / maximum_range * (radius - 9);
                    local dot_x = center_x + math.cos(angle) * pixel_distance;
                    local dot_y = center_y + math.sin(angle) * pixel_distance;
                    local color = colors[radar_entity.kind];
                    if color ~= nil then
                        draw_list:AddCircleFilled({dot_x, dot_y}, 4, 0xD0000000, 12);
                        draw_list:AddCircleFilled({dot_x, dot_y}, 3, color, 12);
                    end
                end
            end
        end

        for _, cardinal in ipairs(cardinals) do
            local screen_angle = cardinal.angle - heading - pi / 2;
            local text_radius = radius - 18;
            local text_x = center_x + math.cos(screen_angle) * text_radius;
            local text_y = center_y + math.sin(screen_angle) * text_radius;
            local color = cardinal.label == 'N' and 0xFF5050E8 or 0xFFF0F0F0;
            centered_text(draw_list, text_x, text_y, color, cardinal.label);
        end

        -- Compact outline pointer leaves nearby radar dots visible.
        local pointer_length = math.max(10, radius * 0.20);
        local pointer_half_width = math.max(3, radius * 0.055);
        draw_list:AddTriangle(
            {center_x, center_y - pointer_length},
            {center_x - pointer_half_width, center_y + 3},
            {center_x + pointer_half_width, center_y + 3},
            0xFFF0F0F0,
            2.0
        );
    end
    imgui.End();
    imgui.PopStyleVar();
end

return compass;
