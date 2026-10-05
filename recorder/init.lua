------------------------------------------------------------
-- love-recorder  -  frame-exact video recording for LÖVE 11.x
--
--   local recorder = require("recorder")
--   function love.load() ... recorder.attach() end      -- F9 toggles
--
-- Video: while recording the game clock advances exactly 1/fps per frame
-- and every frame is piped (from a worker thread) into ffmpeg, so the clip
-- is a smooth fixed-rate video whatever the machine does. The game is also
-- paced to real time, so it doesn't run fast on high-refresh screens.
--
-- Audio (in order of preference):
--   "loopback" Windows 10 2004+: bin/loopback.exe records exactly what this
--              process plays (WASAPI process loopback, like OBS Application
--              Audio Capture). Used when the recording kept real time.
--   "events"   every love.audio Source is tracked (play / stop / pause /
--              seek / volume / pitch / looping / master volume) and the same
--              files are re-mixed on the video clock. Frame-exact even when
--              encoding made the game lag; only file-based sources.
--   "auto"     loopback when possible, events otherwise (default).
-- Needs ffmpeg on PATH (or config.ffmpeg / the FFMPEG environment variable).
-- MIT License.
------------------------------------------------------------
local R = {}

local MOD = ...
local DIR = (MOD or "recorder"):gsub("%.init$", ""):gsub("%.", "/")

R.config = {
    fps = 60,
    audio = "auto",          -- "auto" | "loopback" | "events" | "none"
    ffmpeg = os.getenv("FFMPEG") or "ffmpeg",
    crf = 18,
    preset = "veryfast",
    outDir = "recordings",   -- inside the save directory
    maxDrift = 0.1,          -- loopback only if video and wall clock ended within 0.1 s
                             -- (a paced recording that fell behind real time has
                             -- stretched audio; the event re-mix stays in sync)
    key = "f9",              -- attach(): toggle key (nil = none)
    trackAudio = true,       -- track Sources for the "events" fallback
    pace = true,             -- never run faster than real time while recording
    overlay = true,          -- attach(): small REC status in the window
    latency = 0.09,          -- loopback output latency (s) used when it can't be measured
}

R.active, R.busy, R.message = false, false, nil

local thread, inCh, outCh
local frame, startQpc, startTime = 0, 0, 0
local lbWav, lbExe

------------------------------------------------------------
-- Clocks
------------------------------------------------------------
local ffi, qpcFreq
if jit and love.system.getOS() == "Windows" then
    local ok, f = pcall(require, "ffi")
    if ok then
        ffi = f
        pcall(ffi.cdef, [[
            int QueryPerformanceCounter(int64_t *c);
            int QueryPerformanceFrequency(int64_t *f);
            unsigned long GetCurrentProcessId(void);
        ]])
        local b = ffi.new("int64_t[1]")
        ffi.C.QueryPerformanceFrequency(b)
        qpcFreq = tonumber(b[0])
    end
end
-- seconds on the QueryPerformanceCounter clock (the clock loopback.exe stamps)
local function qpcNow()
    if not qpcFreq then return love.timer.getTime() end
    local b = ffi.new("int64_t[1]")
    ffi.C.QueryPerformanceCounter(b)
    return tonumber(b[0]) / qpcFreq
end

local function videoTime() return frame / R.config.fps end
R.time = videoTime

------------------------------------------------------------
-- Source tracking ("events" audio)
------------------------------------------------------------
local tracked = setmetatable({}, { __mode = "k" })   -- Source -> state
local events = {}
local hooked = false

local function master() return love.audio.getVolume() end

local function modelPos(st)
    local ev = st.ev
    if not ev then return st.pos end
    local p = ev.offset + (videoTime() - ev.t0) * ev.pitch
    if ev.loop and st.dur and st.dur > 0 then p = p % st.dur end
    return p
end

local function isOpen(st)
    if not st.ev then return false end
    if not st.ev.loop and st.dur and modelPos(st) >= st.dur then
        st.ev.t1 = st.ev.t0 + (st.dur - st.ev.offset) / st.ev.pitch
        st.ev, st.pos = nil, 0
        return false
    end
    return true
end

local function open(src, st)
    if not R.active or not st.path then return end
    st.ev = { path = st.path, t0 = videoTime(), offset = st.pos or 0, pitch = src:getPitch(),
              vol = src:getVolume() * master(), loop = src:isLooping() }
    events[#events + 1] = st.ev
end

local function close(st, keepPos)
    if st.ev then
        local p = modelPos(st)
        st.ev.t1 = videoTime()
        st.ev = nil
        st.pos = keepPos and p or 0
    end
end

-- re-open the running segment with new settings (volume / pitch / looping)
local function split(src, st)
    if isOpen(st) then
        close(st, true)
        open(src, st)
    end
end

local function hookAudio()
    if hooked then return end
    hooked = true
    local newSource = love.audio.newSource
    love.audio.newSource = function(a, ...)
        local s = newSource(a, ...)
        if type(a) == "string" then
            tracked[s] = { path = a, pos = 0, dur = s:getDuration() }
        end
        return s
    end
    local probe = newSource(love.sound.newSoundData(16, 44100, 16, 1), "static")
    local mt = getmetatable(probe)
    local M = type(mt.__index) == "table" and mt.__index or mt
    local function wrap(name, f) local orig = M[name]; M[name] = function(self, ...) return f(orig, self, ...) end end

    wrap("play", function(orig, self, ...)
        local st = tracked[self]
        if st and not isOpen(st) then open(self, st) end
        return orig(self, ...)
    end)
    wrap("stop", function(orig, self, ...)
        local st = tracked[self]
        if st then close(st, false); st.pos = 0 end
        return orig(self, ...)
    end)
    wrap("pause", function(orig, self, ...)
        local st = tracked[self]
        if st and isOpen(st) then close(st, true) end
        return orig(self, ...)
    end)
    wrap("seek", function(orig, self, pos, unit)
        local st = tracked[self]
        local r = orig(self, pos, unit)
        if st then
            local p = (unit == "samples") and self:tell("seconds") or pos
            if isOpen(st) then close(st, true); st.pos = p; open(self, st) else st.pos = p end
        end
        return r
    end)
    for _, n in ipairs({ "setVolume", "setPitch", "setLooping" }) do
        wrap(n, function(orig, self, ...)
            local r = orig(self, ...)
            local st = tracked[self]
            if st then split(self, st) end
            return r
        end)
    end
    wrap("clone", function(orig, self, ...)
        local c = orig(self, ...)
        local st = tracked[self]
        if st then tracked[c] = { path = st.path, pos = 0, dur = st.dur } end
        return c
    end)
    -- love.audio.* helpers and the master volume
    local aPlay, aStop, aPause, aSetVol = love.audio.play, love.audio.stop, love.audio.pause, love.audio.setVolume
    love.audio.play = function(...)
        for _, s in ipairs({ ... }) do if type(s) == "userdata" then s:play() end end
        return aPlay(...)
    end
    love.audio.stop = function(...)
        if select("#", ...) == 0 then
            for _, st in pairs(tracked) do close(st, false) end
        else
            for _, s in ipairs({ ... }) do local st = tracked[s]; if st then close(st, false) end end
        end
        return aStop(...)
    end
    love.audio.pause = function(...)
        if select("#", ...) == 0 then
            for _, st in pairs(tracked) do if isOpen(st) then close(st, true) end end
        else
            for _, s in ipairs({ ... }) do local st = tracked[s]; if st and isOpen(st) then close(st, true) end end
        end
        return aPause(...)
    end
    love.audio.setVolume = function(v)
        local r = aSetVol(v)
        for s, st in pairs(tracked) do split(s, st) end
        return r
    end
end

-- sources already playing when recording starts
local function openPlaying()
    for s, st in pairs(tracked) do
        st.ev = nil
        if s:isPlaying() then
            st.pos = s:tell("seconds")
            open(s, st)
        end
    end
end

------------------------------------------------------------
-- Loopback helper
------------------------------------------------------------
local function loopbackAvailable()
    return ffi ~= nil and love.filesystem.getInfo(DIR .. "/bin/loopback.exe") ~= nil
end

-- the exe can't run from inside a .love / fused build: copy it out once
local function loopbackExe()
    if lbExe then return lbExe end
    local data = love.filesystem.read(DIR .. "/bin/loopback.exe")
    if not data then return nil end
    love.filesystem.createDirectory("recorder_bin")
    local info = love.filesystem.getInfo("recorder_bin/loopback.exe")
    if not info or info.size ~= #data then love.filesystem.write("recorder_bin/loopback.exe", data) end
    lbExe = (love.filesystem.getSaveDirectory() .. "/recorder_bin/loopback.exe"):gsub("/", "\\")
    return lbExe
end

------------------------------------------------------------
-- Control
------------------------------------------------------------
function R.setup(opts)
    for k, v in pairs(opts or {}) do R.config[k] = v end
    if R.config.trackAudio and R.config.audio ~= "none" then hookAudio() end
end

function R.start(canvas, name)
    if R.active or R.busy then return false end
    local cfg = R.config
    if cfg.trackAudio and cfg.audio ~= "none" then hookAudio() end
    love.filesystem.createDirectory(cfg.outDir)
    name = name or ("rec_" .. os.date("%Y%m%d_%H%M%S"))
    local dir = (love.filesystem.getSaveDirectory() .. "/" .. cfg.outDir):gsub("\\", "/")
    local w, h = canvas:getDimensions()

    inCh, outCh = love.thread.getChannel("love_recorder_in"), love.thread.getChannel("love_recorder_out")
    inCh:clear(); outCh:clear()
    thread = love.thread.newThread(DIR .. "/worker.lua")
    thread:start()
    inCh:push({ dir = dir, name = name, w = w, h = h, fps = cfg.fps, ffmpeg = cfg.ffmpeg,
                crf = cfg.crf, preset = cfg.preset, latency = cfg.latency })

    frame, events = 0, {}
    R.active, R.message = true, nil
    openPlaying()
    startQpc, startTime = qpcNow(), love.timer.getTime()

    lbWav = nil
    if (cfg.audio == "auto" or cfg.audio == "loopback") and loopbackAvailable() then
        local exe = loopbackExe()
        if exe then
            lbWav = (dir .. "/" .. name .. "_loopback.wav"):gsub("/", "\\")
            os.remove(lbWav .. ".start"); os.remove(lbWav .. ".stop")
            os.execute('start "" /B "' .. exe .. '" ' .. tonumber(ffi.C.GetCurrentProcessId()) ..
                ' "' .. lbWav .. '" 2>NUL')
        end
    end
    return true
end

-- dt the game should use this frame (fixed while recording; paces to real time)
function R.frameDt(dt)
    if not R.active then return dt end
    if R.config.pace then
        local ahead = (startTime + frame / R.config.fps) - love.timer.getTime()
        if ahead > 0 and ahead < 0.25 then love.timer.sleep(ahead) end
    end
    return 1 / R.config.fps
end

-- Call once per frame with the finished canvas (before window overlays)
function R.capture(canvas)
    if not R.active then return end
    -- supply() waits for the worker: frames are never dropped. Release our
    -- handle right away: the GC can't see the 8 MB behind each ImageData, so
    -- leaving it to the collector piles up gigabytes on a long recording.
    local img = canvas:newImageData()
    inCh:supply(img)
    img:release()
    frame = frame + 1
end

function R.stop(wait)
    if not R.active then return end
    local cfg = R.config
    R.active = false
    local vt = videoTime()
    for _, ev in ipairs(events) do if not ev.t1 then ev.t1 = vt end end
    for _, st in pairs(tracked) do st.ev = nil end

    local real = qpcNow() - startQpc
    local drift = math.abs(real - vt)                 -- seconds the wall clock ran ahead
    local lag = vt > 0 and drift / vt or 0
    local msg = { stop = true, startQpc = startQpc, duration = vt }
    if lbWav then
        local f = io.open(lbWav .. ".stop", "w"); if f then f:close() end
    end
    local lines = {}
    for _, ev in ipairs(events) do
        lines[#lines + 1] = table.concat({ ev.path, ev.t0, ev.t1, ev.pitch, ev.vol,
            ev.loop and 1 or 0, ev.offset }, "\t")
    end
    msg.events = table.concat(lines, "\n")   -- also used to measure loopback latency
    if lbWav and (cfg.audio == "loopback" or drift <= cfg.maxDrift) then
        msg.audio, msg.wav = "loopback", lbWav:gsub("\\", "/")
        msg.note = "loopback"
    elseif cfg.audio ~= "none" and #events > 0 then
        msg.audio = "events"
        msg.note = lbWav and string.format("events (wall clock %.1f s ahead, %.1f%%)", drift, lag * 100) or "events"
        msg.dropWav = lbWav and lbWav:gsub("\\", "/") or nil
    else
        msg.audio, msg.note = "none", "no audio"
    end
    inCh:push(msg)
    R.busy, R.message = true, "encoding..."
    if wait then
        local res = outCh:demand(900)
        R.busy, R.message = false, res
        return res
    end
end

-- Poll the worker (call every frame; attach() does it)
function R.update()
    if R.busy and outCh then
        local res = outCh:pop()
        if res then R.busy, R.message = false, res end
        local err = thread and thread:getError()
        if err then R.busy, R.message = false, "error|" .. err end
    end
end

function R.toggle(canvas)
    if R.active then R.stop() else R.start(canvas) end
end

-- Status line (window space, after the frame was captured)
function R.drawStatus()
    local text
    if R.active then
        if math.floor(love.timer.getTime() * 2) % 2 == 0 then
            love.graphics.setColor(1, 0.2, 0.2, 1)
            love.graphics.circle("fill", 22, 22, 8)
        end
        text = string.format("REC %05.1fs", videoTime())
    elseif R.busy then
        text = "REC encoding..."
    elseif R.message then
        text = R.message:gsub("|", "  ")
    end
    if text then
        local font = love.graphics.getFont()
        love.graphics.setColor(0, 0, 0, 0.6)
        love.graphics.rectangle("fill", 34, 10, font:getWidth(text) + 12, font:getHeight() + 8)
        love.graphics.setColor(1, 1, 1, 1)
        love.graphics.print(text, 40, 14)
    end
end

------------------------------------------------------------
-- Drop-in: wrap the game's callbacks (call at the end of love.load)
------------------------------------------------------------
function R.attach(opts)
    R.setup(opts)
    local canvas
    local update, draw, keypressed = love.update, love.draw, love.keypressed
    love.update = function(dt)
        R.update()
        if update then update(R.frameDt(dt)) end
    end
    love.draw = function()
        local w, h = love.graphics.getDimensions()
        if not canvas or canvas:getWidth() ~= w or canvas:getHeight() ~= h then
            canvas = love.graphics.newCanvas(w, h)
        end
        love.graphics.push("all")
        love.graphics.setCanvas({ canvas, stencil = true })
        love.graphics.clear(love.graphics.getBackgroundColor())
        if draw then draw() end
        love.graphics.pop()
        R.capture(canvas)
        love.graphics.setColor(1, 1, 1, 1)
        love.graphics.draw(canvas)
        if R.config.overlay then R.drawStatus() end
    end
    love.keypressed = function(key, ...)
        if R.config.key and key == R.config.key then
            local w, h = love.graphics.getDimensions()
            canvas = canvas or love.graphics.newCanvas(w, h)
            R.toggle(canvas)
            return
        end
        if keypressed then return keypressed(key, ...) end
    end
end

-- Track sources from the moment the module is required, so sources the
-- game creates before attach() / start() are known too
if R.config.trackAudio then hookAudio() end

return R
