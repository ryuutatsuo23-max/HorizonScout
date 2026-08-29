-- Read-only FFXI world-coordinate to map-grid conversion.
-- Uses the same per-zone map-table approach as the locally installed
-- FancyCompass grid module, which was adapted from boussole/src/map.lua.

local map_grid = {};

local map_table_signature = '8A0D????????5333C05684C95774??8A5424188B7424148B7C2410B9';
local map_entry_size = 0x0E;
local map_table_address = 0;
local zone_cache = T{
    id = -1,
    scale = nil,
    offset_x = 0,
    offset_y = 0,
};

local function signed_byte(value)
    return value >= 0x80 and (value - 0x100) or value;
end

local function signed_word(value)
    return value >= 0x8000 and (value - 0x10000) or value;
end

function map_grid.init()
    map_table_address = 0;
    local ok, signature_address = pcall(function()
        return ashita.memory.find('FFXiMain.dll', 0, map_table_signature, 0, 0);
    end);
    if not ok or signature_address == nil or signature_address == 0 then
        return false;
    end

    local pointer_ok, pointer = pcall(function()
        return ashita.memory.read_uint32(signature_address + 0x1C);
    end);
    if not pointer_ok or pointer == nil or pointer == 0 then
        return false;
    end

    map_table_address = pointer;
    return true;
end

local function get_zone_entry(zone_id)
    if zone_id == zone_cache.id then
        return zone_cache.scale, zone_cache.offset_x, zone_cache.offset_y;
    end

    zone_cache.id = zone_id;
    zone_cache.scale = nil;
    zone_cache.offset_x = 0;
    zone_cache.offset_y = 0;
    if map_table_address == 0 then
        return nil;
    end

    local ok, scale, offset_x, offset_y = pcall(function()
        for index = 0, 999 do
            local base = map_table_address + (index * map_entry_size);
            if ashita.memory.read_uint16(base) == zone_id then
                return signed_byte(ashita.memory.read_uint8(base + 0x05)),
                    signed_word(ashita.memory.read_uint16(base + 0x0A)),
                    signed_word(ashita.memory.read_uint16(base + 0x0C));
            end
        end
        return nil;
    end);
    if not ok or scale == nil then
        return nil;
    end

    zone_cache.scale = scale;
    zone_cache.offset_x = offset_x;
    zone_cache.offset_y = offset_y;
    return scale, offset_x, offset_y;
end

function map_grid.get_position()
    local ok, result = pcall(function()
        local memory = AshitaCore:GetMemoryManager();
        if memory == nil then
            return '?-?';
        end

        local party = memory:GetParty();
        local entity = memory:GetEntity();
        if party == nil or entity == nil or party:GetMemberIsActive(0) == 0 then
            return '?-?';
        end

        local zone_id = tonumber(party:GetMemberZone(0)) or 0;
        local player_index = tonumber(party:GetMemberTargetIndex(0)) or 0;
        if zone_id == 0 or player_index == 0 then
            return '?-?';
        end

        local scale, offset_x, offset_y = get_zone_entry(zone_id);
        if scale == nil or scale == 0 then
            return '?-?';
        end

        local player_x = tonumber(entity:GetLocalPositionX(player_index));
        local player_y = tonumber(entity:GetLocalPositionY(player_index));
        if player_x == nil or player_y == nil then
            return '?-?';
        end

        local map_scale = math.abs(scale) / 2560.0;
        local map_x = math.floor((player_x * map_scale * 512) + 0.5);
        local map_y = -math.floor((player_y * map_scale * 512) + 0.5);
        map_x = signed_word(bit.band(map_x, 0xFFFF));
        map_y = signed_word(bit.band(map_y, 0xFFFF));

        local grid_x = math.floor((map_x - offset_x - 16) / 32);
        local grid_y = math.floor((map_y - offset_y - 16) / 32) + 1;
        grid_x = math.max(0, math.min(25, grid_x));
        return string.char(string.byte('A') + grid_x) .. '-' .. tostring(grid_y);
    end);

    return ok and result or '?-?';
end

function map_grid.reset()
    map_table_address = 0;
    zone_cache.id = -1;
    zone_cache.scale = nil;
    zone_cache.offset_x = 0;
    zone_cache.offset_y = 0;
end

return map_grid;
