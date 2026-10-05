-- love-recorder demo: bouncing balls with sound. F9 records.
--   love .                         play; F9 toggles recording
--   love . --selftest [audio]      record 3 s automatically and quit
--                                  (audio = auto | loopback | events | none)
--   love . --selftest auto --slow  the same, with frames slower than real
--                                  time (checks the audio stays in sync)
--   ... --encoder auto             try a hardware encoder (nvenc / amf / qsv)
local recorder = require("recorder")

local balls, blip, hum = {}, nil, nil
local t = 0
local selftest, selfAudio, slow, encoder

function love.load(args)
    for i, a in ipairs(args or {}) do
        if a == "--selftest" then selftest = true; selfAudio = args[i + 1] end
        if a == "--slow" then slow = true end
        if a == "--encoder" then encoder = args[i + 1] end
    end
    love.graphics.setBackgroundColor(0.08, 0.09, 0.16)
    blip = love.audio.newSource("example/sounds/blip.wav", "static")
    hum = love.audio.newSource("example/sounds/hum.wav", "static")
    hum:setLooping(true)
    hum:setVolume(0.5)
    hum:play()
    for i = 1, 6 do
        balls[i] = { x = 100 + i * 90, y = 80 + i * 30, vx = 220 + i * 25, vy = 0, r = 14 + i * 2,
                     c = { 0.4 + i * 0.1, 0.8 - i * 0.08, 1 } }
    end
    recorder.attach({ audio = selfAudio or "auto", encoder = encoder })
    if selftest then recorder.start(love.graphics.newCanvas(love.graphics.getDimensions()), "selftest") end
end

function love.update(dt)
    t = t + dt
    local w, h = love.graphics.getDimensions()
    for _, b in ipairs(balls) do
        b.vy = b.vy + 900 * dt
        b.x, b.y = b.x + b.vx * dt, b.y + b.vy * dt
        if b.y > h - b.r then
            b.y, b.vy = h - b.r, -math.abs(b.vy) * 0.92
            local s = blip:clone()
            s:setPitch(0.7 + b.r / 40)
            s:play()
        end
        if b.x < b.r or b.x > w - b.r then b.vx = -b.vx end
    end
    -- exercise the tracker: master volume and hum pitch change mid-clip
    if t > 1.5 and t - dt <= 1.5 then love.audio.setVolume(0.6); hum:setPitch(1.25) end
    if selftest and recorder.active and recorder.time() >= 3 then
        local res = recorder.stop(true)
        print(res)
        love.filesystem.write("selftest_result.txt", tostring(res))
        love.event.quit()
    end
end

function love.draw()
    if slow and recorder.active then love.timer.sleep(0.03) end   -- ~33 fps of 60
    for _, b in ipairs(balls) do
        love.graphics.setColor(b.c)
        love.graphics.circle("fill", b.x, b.y, b.r)
    end
    love.graphics.setColor(1, 1, 1, 0.6)
    love.graphics.print("love-recorder demo  -  F9: start / stop recording", 10, love.graphics.getHeight() - 24)
end
