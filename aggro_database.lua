local aggro_database = {};

local state = {
    zone_id = nil,
    names = {},
    normalized_names = {},
    indices = {},
    available = false,
    source_label = nil,
    status = 'Not loaded yet',
};

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

local function file_exists(path)
    local file = io.open(path, 'rb');
    if file == nil then
        return false;
    end
    file:close();
    return true;
end

local function clear_loaded_data(zone_id)
    state.zone_id = zone_id;
    state.names = {};
    state.normalized_names = {};
    state.indices = {};
    state.available = false;
    state.source_label = nil;
end

local function candidate_paths(zone_id)
    local root = AshitaCore:GetInstallPath();
    local filename = tostring(zone_id) .. '.lua';
    return {
        {
            path = root .. 'addons\\mobdb\\data\\' .. filename,
            label = 'MobDB',
        },
        {
            path = root
                .. 'addons\\XIUI\\submodules\\mobdb\\addons\\mobdb\\data\\'
                .. filename,
            label = 'XIUI MobDB',
        },
    };
end

local function accept_zone_data(result, source_label)
    if type(result) ~= 'table'
        or type(result.Names) ~= 'table'
        or type(result.Indices) ~= 'table' then
        return false;
    end

    state.names = result.Names;
    state.indices = result.Indices;
    for name, resource in pairs(result.Names) do
        state.normalized_names[normalize_name(name)] = resource;
    end
    state.available = true;
    state.source_label = source_label;
    state.status = 'Ready: ' .. source_label;
    return true;
end

function aggro_database.load_zone(zone_id)
    zone_id = tonumber(zone_id) or 0;
    if state.zone_id == zone_id then
        return state.available;
    end

    clear_loaded_data(zone_id);
    if zone_id <= 0 then
        state.status = 'Waiting for a valid zone';
        return false;
    end

    local found_file = false;
    for _, candidate in ipairs(candidate_paths(zone_id)) do
        if file_exists(candidate.path) then
            found_file = true;
            local chunk, load_error = loadfile(candidate.path);
            if chunk ~= nil then
                local ok, result = pcall(chunk);
                if ok and accept_zone_data(result, candidate.label) then
                    return true;
                end
            elseif load_error ~= nil then
                state.status = 'The local aggression data could not be loaded';
            end
        end
    end

    if found_file then
        state.status = 'The local aggression data is invalid for this zone';
    else
        state.status = 'Unavailable: install MobDB or XIUI zone data';
    end
    return false;
end

function aggro_database.get_monster_info(zone_id, entity_index, entity_name)
    if not aggro_database.load_zone(zone_id) then
        return nil;
    end

    local resource = state.indices[tonumber(entity_index)];
    if resource == nil then
        resource = state.names[entity_name];
    end
    if resource == nil then
        resource = state.normalized_names[normalize_name(entity_name)];
    end
    return type(resource) == 'table' and resource or nil;
end

function aggro_database.is_aggressive(zone_id, entity_index, entity_name)
    local resource = aggro_database.get_monster_info(
        zone_id,
        entity_index,
        entity_name
    );
    return resource ~= nil and resource.Aggro == true;
end

function aggro_database.get_status()
    return state.status;
end

function aggro_database.reset()
    clear_loaded_data(nil);
    state.status = 'Not loaded yet';
end

return aggro_database;
