------------------------------------------------------------
-- love-recorder worker thread
--
-- in : config table, then ImageData frames, then a stop table
-- out: "done|<mp4 path>|<frames>|<audio note>" or "error|<message>"
--
-- Frames are piped raw (RGBA) into ffmpeg. On stop the audio track is
-- either the loopback WAV or a re-mix of the tracked Source events on the
-- video clock, then ffmpeg muxes video + audio.
--
-- Loopback: loopback.exe stamps the QPC time of its first sample, which
-- places the track on the video clock. Nothing else is done to it.
------------------------------------------------------------
require("love.image")
require("love.sound")
require("love.filesystem")
require("love.timer")
local ffi = require("ffi")

local inCh = love.thread.getChannel("love_recorder_in")
local outCh = love.thread.getChannel("love_recorder_out")
local cfg = inCh:demand()

local function q(s) return '"' .. s .. '"' end
local isWin = package.config:sub(1, 1) == "\\"
local function sh(cmd) return isWin and ('"' .. cmd .. '"') or cmd end   -- cmd.exe quoting

------------------------------------------------------------
-- Encoder
------------------------------------------------------------
local ENC_ARGS = {
    h264_nvenc = "-c:v h264_nvenc -preset p5 -rc vbr -cq 19 -b:v 0",
    h264_amf   = "-c:v h264_amf -usage transcoding -quality quality -rc cqp -qp_i 18 -qp_p 18 -qp_b 20",
    h264_qsv   = "-c:v h264_qsv -global_quality 20",
}
local function encoderWorks(enc)
    local cmd = q(cfg.ffmpeg) .. " -hide_banner -loglevel error -f lavfi -i color=c=black:s=256x256:r=30:d=0.2" ..
        " -pix_fmt yuv420p " .. ENC_ARGS[enc] .. " -f null - " .. (isWin and ">NUL 2>&1" or ">/dev/null 2>&1")
    local r = os.execute(sh(cmd))
    return r == 0 or r == true
end
local encoder = cfg.encoder or "libx264"
if encoder == "auto" then
    encoder = "libx264"
    for _, e in ipairs({ "h264_nvenc", "h264_amf", "h264_qsv" }) do
        if encoderWorks(e) then encoder = e; break end
    end
end
local vargs = ENC_ARGS[encoder] or ("-c:v libx264 -preset " .. cfg.preset .. " -crf " .. cfg.crf)

local videoPath = cfg.dir .. "/" .. cfg.name .. "_video.mp4"
local pipe = io.popen(sh(q(cfg.ffmpeg) ..
    " -y -loglevel error -f rawvideo -pix_fmt rgba -s " .. cfg.w .. "x" .. cfg.h ..
    " -r " .. cfg.fps .. " -i - -pix_fmt yuv420p " .. vargs .. " " .. q(videoPath)), isWin and "wb" or "w")
if not pipe then outCh:push("error|ffmpeg could not be started (" .. cfg.ffmpeg .. ")"); return end
-- the caller starts its clock only now, so encoder probing / ffmpeg start-up
-- never counts as lag
outCh:push("ready|" .. encoder)

local frames, stop = 0, nil
while true do
    local msg = inCh:demand()
    if type(msg) == "table" then stop = msg; break end
    pipe:write(msg:getString())
    msg:release()
    frames = frames + 1
end
pipe:close()
local duration = frames / cfg.fps
local RATE = 44100

local function exists(p) local f = io.open(p, "rb"); if f then f:close() return true end return false end

------------------------------------------------------------
-- Event re-mix (stereo float buffer on the video clock)
------------------------------------------------------------
local function buildMix(eventsStr)
    if not eventsStr or eventsStr == "" then return nil end
    local total = math.max(1, math.floor(duration * RATE))
    local mix = ffi.new("float[?]", total * 2)
    local cache = {}
    local function load(path)
        if cache[path] ~= nil then return cache[path] end
        local ok, sd = pcall(love.sound.newSoundData, path)
        if not ok then cache[path] = false; return false end
        local info = { sd = sd, rate = sd:getSampleRate(), ch = sd:getChannelCount(),
                       n = sd:getSampleCount(), bits = sd:getBitDepth() }
        info.ptr = ffi.cast(info.bits == 16 and "int16_t*" or "uint8_t*", sd:getFFIPointer())
        cache[path] = info
        return info
    end
    local function sample(info, fr, c)
        local idx = fr * info.ch + ((info.ch == 2) and c or 0)
        if info.bits == 16 then return info.ptr[idx] / 32768 end
        return (info.ptr[idx] - 128) / 128
    end
    local function add(ev)
        local info = load(ev.path)
        if not info then return end
        local i0 = math.max(0, math.floor(ev.t0 * RATE))
        local i1 = math.min(total, math.floor((ev.t1 or duration) * RATE))
        local step = (ev.pitch or 1) * info.rate / RATE
        local pos = (ev.offset or 0) * info.rate
        local n, vol = info.n, ev.vol or 1
        for i = i0, i1 - 1 do
            local p = pos + (i - i0) * step
            if ev.loop then p = p % n elseif p >= n - 1 then break end
            local fl = math.floor(p)
            local fr = p - fl
            local f2 = fl + 1
            if f2 >= n then f2 = ev.loop and 0 or fl end
            for c = 0, 1 do
                local a, b = sample(info, fl, c), sample(info, f2, c)
                mix[i * 2 + c] = mix[i * 2 + c] + (a + (b - a) * fr) * vol
            end
        end
    end
    for line in eventsStr:gmatch("[^\n]+") do
        local f = {}
        for v in (line .. "\t"):gmatch("([^\t]*)\t") do f[#f + 1] = v end
        add({ path = f[1], t0 = tonumber(f[2]), t1 = tonumber(f[3]), pitch = tonumber(f[4]),
              vol = tonumber(f[5]), loop = f[6] == "1", offset = tonumber(f[7]) })
    end
    return mix, total
end

local function writeWav(path, mix, total)
    local pcm = ffi.new("int16_t[?]", total * 2)
    for i = 0, total * 2 - 1 do
        local x = mix[i]
        if x > 1 or x < -1 then x = (x > 0 and 1 or -1) * (2 - 2 / (1 + math.abs(x))) end
        if x > 1 then x = 1 elseif x < -1 then x = -1 end
        pcm[i] = math.floor(x * 32767)
    end
    local function u32(v) return string.char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256) end
    local function u16(v) return string.char(v % 256, math.floor(v / 256) % 256) end
    local bytes = total * 4
    local f = io.open(path, "wb")
    f:write("RIFF", u32(36 + bytes), "WAVE", "fmt ", u32(16), u16(1), u16(2), u32(RATE),
        u32(RATE * 4), u16(4), u16(16), "data", u32(bytes))
    f:write(ffi.string(pcm, bytes))
    f:close()
end

------------------------------------------------------------
-- Audio
------------------------------------------------------------
local audioPath, audioFilter, note = nil, nil, stop.note or ""

local function waitStart(wav)
    local t = 0
    while not exists(wav .. ".start") and t < 10 do love.timer.sleep(0.05); t = t + 0.05 end
    local f = io.open(wav .. ".start", "r")
    local v = f and tonumber(f:read("*l")) or nil
    if f then f:close() end
    return v
end

if stop.audio == "loopback" then
    -- The capture is used exactly as recorded: placed on the video clock by
    -- the QPC stamp of its first sample, never resampled or re-timed. If the
    -- game fell behind real time while recording, the note says by how much
    -- (that much audio drift by the end of the clip).
    local lbStart = waitStart(stop.wav)
    if lbStart and exists(stop.wav) then
        audioPath = stop.wav
        local offset = lbStart - stop.startQpc
        if offset >= 0 then
            audioFilter = string.format("adelay=%d:all=1,apad", math.floor(offset * 1000 + 0.5))
        else
            audioFilter = string.format("atrim=start=%.4f,asetpts=PTS-STARTPTS,apad", -offset)
        end
        local drift = stop.drift or 0
        note = "loopback" .. (math.abs(drift) > 0.05 and
            string.format(" (WARNING: recording ran %.2f s behind real time)", drift) or "")
    else
        note = "loopback failed, no audio"
    end
elseif stop.audio == "events" then
    local mix, total = buildMix(stop.events)
    if mix then
        audioPath = cfg.dir .. "/" .. cfg.name .. "_events.wav"
        writeWav(audioPath, mix, total)
        audioFilter = "apad"
    else
        note = "no tracked sounds, no audio"
    end
    if stop.dropWav then
        -- an unused loopback track: wait for it to finish, then remove it
        waitStart(stop.dropWav)
        os.remove(stop.dropWav); os.remove(stop.dropWav .. ".start")
    end
end

------------------------------------------------------------
-- Mux
------------------------------------------------------------
local outPath = cfg.dir .. "/" .. cfg.name .. ".mp4"
local cmd
if audioPath then
    cmd = q(cfg.ffmpeg) .. " -y -loglevel error -i " .. q(videoPath) .. " -i " .. q(audioPath) ..
        ' -filter_complex "[1:a]' .. audioFilter .. '[a]" -map 0:v -map "[a]" -c:v copy -c:a aac -b:a 192k -t ' ..
        string.format("%.4f", duration) .. " " .. q(outPath)
else
    cmd = q(cfg.ffmpeg) .. " -y -loglevel error -i " .. q(videoPath) .. " -c:v copy " .. q(outPath)
end
local ok = os.execute(sh(cmd))
if ok == 0 or ok == true then
    os.remove(videoPath)
    if audioPath and not cfg.keepAudio then
        os.remove(audioPath); os.remove(audioPath .. ".start")
    end
    outCh:push("done|" .. outPath .. "|" .. frames .. "|" .. note .. ", " .. encoder)
else
    outCh:push("error|mux failed (video kept at " .. videoPath .. ")")
end
