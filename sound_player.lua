local bit = require('bit');
local ffi = require('ffi');

-- Other loaded addons may already declare these WinMM types and functions.
-- Define only what is missing so their global FFI namespace remains compatible.
if not pcall(ffi.typeof, 'HWAVEOUT') then
    ffi.cdef[[typedef void* HWAVEOUT;]];
end
if not pcall(ffi.typeof, 'WAVEFORMATEX') then
    ffi.cdef[[
        typedef struct {
            unsigned short wFormatTag;
            unsigned short nChannels;
            unsigned long nSamplesPerSec;
            unsigned long nAvgBytesPerSec;
            unsigned short nBlockAlign;
            unsigned short wBitsPerSample;
            unsigned short cbSize;
        } WAVEFORMATEX;
    ]];
end
if not pcall(ffi.typeof, 'WAVEHDR') then
    ffi.cdef[[
        typedef struct {
            char* lpData;
            unsigned long dwBufferLength;
            unsigned long dwBytesRecorded;
            void* dwUser;
            unsigned long dwFlags;
            unsigned long dwLoops;
            void* lpNext;
            unsigned long reserved;
        } WAVEHDR;
    ]];
end
pcall(function()
    ffi.cdef[[
        long waveOutOpen(HWAVEOUT* output, unsigned int device_id,
            const WAVEFORMATEX* format, unsigned long long callback,
            unsigned long long instance, unsigned long flags);
        long waveOutPrepareHeader(HWAVEOUT output, WAVEHDR* header,
            unsigned int size);
        long waveOutWrite(HWAVEOUT output, WAVEHDR* header, unsigned int size);
        long waveOutUnprepareHeader(HWAVEOUT output, WAVEHDR* header,
            unsigned int size);
        long waveOutReset(HWAVEOUT output);
        long waveOutClose(HWAVEOUT output);
    ]];
end);

local sound_player = {};
local winmm = ffi.load('winmm');
local wave_mapper = 0xFFFFFFFF;
local wave_format_pcm = 1;
local wave_header_done = 0x00000001;
local active = nil;

local function stop_active()
    if active == nil then
        return;
    end

    if active.output ~= nil then
        winmm.waveOutReset(active.output);
        if active.header ~= nil then
            winmm.waveOutUnprepareHeader(
                active.output,
                active.header,
                ffi.sizeof('WAVEHDR')
            );
        end
        winmm.waveOutClose(active.output);
    end
    active = nil;
end

local function read_u16(data, offset)
    local low = data:byte(offset) or 0;
    local high = data:byte(offset + 1) or 0;
    return bit.bor(low, bit.lshift(high, 8));
end

local function read_u32(data, offset)
    local byte_1 = data:byte(offset) or 0;
    local byte_2 = data:byte(offset + 1) or 0;
    local byte_3 = data:byte(offset + 2) or 0;
    local byte_4 = data:byte(offset + 3) or 0;
    return byte_1
        + bit.lshift(byte_2, 8)
        + bit.lshift(byte_3, 16)
        + bit.lshift(byte_4, 24);
end

local function read_pcm16_wav(path)
    local file = io.open(path, 'rb');
    if file == nil then
        return nil, nil, 'file could not be opened';
    end
    local data = file:read('*all');
    file:close();

    if data == nil or #data < 44
        or data:sub(1, 4) ~= 'RIFF'
        or data:sub(9, 12) ~= 'WAVE' then
        return nil, nil, 'file is not a RIFF/WAVE file';
    end

    local format = nil;
    local pcm = nil;
    local position = 13;
    while position + 8 <= #data do
        local chunk_id = data:sub(position, position + 3);
        local chunk_size = read_u32(data, position + 4);
        local chunk_start = position + 8;
        if chunk_size < 0 or chunk_start + chunk_size - 1 > #data then
            return nil, nil, 'WAV chunk is invalid';
        end

        if chunk_id == 'fmt ' and chunk_size >= 16 then
            format = {
                format_tag = read_u16(data, chunk_start),
                channels = read_u16(data, chunk_start + 2),
                samples_per_second = read_u32(data, chunk_start + 4),
                average_bytes_per_second = read_u32(data, chunk_start + 8),
                block_alignment = read_u16(data, chunk_start + 12),
                bits_per_sample = read_u16(data, chunk_start + 14),
            };
        elseif chunk_id == 'data' then
            pcm = data:sub(chunk_start, chunk_start + chunk_size - 1);
        end

        position = chunk_start + chunk_size + (chunk_size % 2);
    end

    if format == nil or pcm == nil then
        return nil, nil, 'WAV format or data chunk is missing';
    end
    if format.format_tag ~= wave_format_pcm or format.bits_per_sample ~= 16 then
        return nil, nil, 'only 16-bit PCM WAV files support volume scaling';
    end
    return format, pcm, nil;
end

local function scaled_pcm_buffer(pcm, multiplier)
    local output = ffi.new('char[?]', #pcm);
    local sample_count = math.floor(#pcm / 2);
    for sample_index = 0, sample_count - 1 do
        local source_offset = sample_index * 2 + 1;
        local sample = bit.bor(
            pcm:byte(source_offset) or 0,
            bit.lshift(pcm:byte(source_offset + 1) or 0, 8)
        );
        if sample >= 32768 then
            sample = sample - 65536;
        end

        sample = math.floor(sample * multiplier + (sample >= 0 and 0.5 or -0.5));
        sample = math.max(-32768, math.min(32767, sample));
        local unsigned = sample >= 0 and sample or sample + 65536;
        output[sample_index * 2] = bit.band(unsigned, 0xFF);
        output[sample_index * 2 + 1] = bit.band(bit.rshift(unsigned, 8), 0xFF);
    end
    return output, #pcm;
end

local function play_scaled(path, volume_percent)
    local format, pcm, parse_error = read_pcm16_wav(path);
    if format == nil then
        return false, parse_error;
    end

    stop_active();
    local buffer, buffer_length = scaled_pcm_buffer(pcm, volume_percent / 100);
    local wave_format = ffi.new('WAVEFORMATEX');
    wave_format.wFormatTag = format.format_tag;
    wave_format.nChannels = format.channels;
    wave_format.nSamplesPerSec = format.samples_per_second;
    wave_format.nAvgBytesPerSec = format.average_bytes_per_second;
    wave_format.nBlockAlign = format.block_alignment;
    wave_format.wBitsPerSample = format.bits_per_sample;
    wave_format.cbSize = 0;

    local output = ffi.new('HWAVEOUT[1]');
    local result = winmm.waveOutOpen(output, wave_mapper, wave_format, 0, 0, 0);
    if result ~= 0 then
        return false, 'waveOutOpen failed with code ' .. tostring(result);
    end

    local header = ffi.new('WAVEHDR');
    header.lpData = buffer;
    header.dwBufferLength = buffer_length;
    header.dwFlags = 0;
    header.dwLoops = 0;

    result = winmm.waveOutPrepareHeader(output[0], header, ffi.sizeof('WAVEHDR'));
    if result ~= 0 then
        winmm.waveOutClose(output[0]);
        return false, 'waveOutPrepareHeader failed with code ' .. tostring(result);
    end

    result = winmm.waveOutWrite(output[0], header, ffi.sizeof('WAVEHDR'));
    if result ~= 0 then
        winmm.waveOutUnprepareHeader(output[0], header, ffi.sizeof('WAVEHDR'));
        winmm.waveOutClose(output[0]);
        return false, 'waveOutWrite failed with code ' .. tostring(result);
    end

    active = {
        output = output[0],
        header = header,
        buffer = buffer,
    };
    return true, nil;
end

function sound_player.play(path, volume_percent)
    local volume = math.max(0, math.min(150, tonumber(volume_percent) or 100));
    if volume == 0 then
        stop_active();
        return true, nil;
    end
    if volume == 100 then
        stop_active();
        ashita.misc.play_sound(path);
        return true, nil;
    end
    return play_scaled(path, volume);
end

function sound_player.tick()
    if active ~= nil and active.header ~= nil
        and bit.band(active.header.dwFlags, wave_header_done) ~= 0 then
        stop_active();
    end
end

function sound_player.shutdown()
    stop_active();
end

return sound_player;
