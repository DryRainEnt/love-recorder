# love-recorder

Frame-exact gameplay video recording for [LÖVE](https://love2d.org) 11.x games, with the game's own audio.

- **Smooth fixed-rate video.** While recording, the game clock advances exactly `1/fps` per frame. Every frame is piped from a worker thread into ffmpeg (H.264, on the GPU encoder when there is one). If encoding falls behind, the game waits; it never drops a frame. The game is paced to real time, so it doesn't speed up on high-refresh screens.
- **Only this game's sound.** On Windows 10 2004+ a small helper records exactly what your game process plays, using WASAPI process loopback (the API behind OBS "Application Audio Capture"). Discord, music players and other programs are not captured.
- **Untouched audio.** The capture (48 kHz float, the Windows mix format) goes into the clip as recorded: never resampled, stretched or re-timed. It is placed by the time stamp of its first sample, so it lines up as long as the game keeps real time while recording. The GPU encoder is there to make sure it does, and the result reports any lag.
- **Falls back to a re-mix.** Every `love.audio` Source is tracked (play / stop / pause / seek / volume / pitch / looping / master volume). If loopback isn't available, the same sound files are re-mixed on the video clock instead.

## Requirements

- LÖVE 11.x (LuaJIT; the FFI is used for the Windows parts)
- [ffmpeg](https://ffmpeg.org/download.html) on `PATH`. You can also set the `FFMPEG` environment variable or `config.ffmpeg`.
- For loopback audio: Windows 10 version 2004 (build 19041) or later. A prebuilt `recorder/bin/loopback.exe` is included.

## Quick start

Copy the `recorder/` folder into your game, then:

```lua
local recorder = require("recorder")   -- require early: Sources created after this are tracked

function love.load()
    -- ... your setup ...
    recorder.attach()                    -- call last: wraps love.update / love.draw / love.keypressed
end
```

Press **F9** to start or stop recording. A small `REC` status is shown in the window but is not recorded. Clips are saved to `<save directory>/recordings/rec_YYYYMMDD_HHMMSS.mp4`.

`attach()` renders your `love.draw` into a window-sized canvas, captures it, and then shows it.

## Manual control

Use this if your game already renders to its own canvas (for example a fixed logical resolution):

```lua
local recorder = require("recorder")
recorder.setup({ fps = 60 })

function love.update(dt)
    recorder.update()                    -- polls the encoder
    dt = recorder.frameDt(dt)            -- fixed step + real-time pacing while recording
    -- ...
end

function love.draw()
    -- ... draw the frame into gameCanvas ...
    love.graphics.setCanvas()
    recorder.capture(gameCanvas)         -- before window-only overlays
    love.graphics.draw(gameCanvas, 0, 0, 0, scale, scale)
    recorder.drawStatus()                -- optional
end

-- start / stop from a key, a debug menu or a script:
recorder.start(gameCanvas, "my_clip")    -- name optional
recorder.stop()                          -- returns immediately; recorder.message has the result
recorder.stop(true)                      -- waits and returns "done|<path>|<frames>|<audio note>"
```

Scripted captures (automated trailers) also work. Call `recorder.capture()` once per simulated frame and `recorder.stop(true)` at the end.

If such a script drives frames itself (calling `love.update` / `love.draw` in a loop instead of `love.run`), end each frame with `love.graphics.present()` as `love.run` does. Without it the graphics driver keeps queueing every frame's commands and memory climbs by gigabytes over a long capture.

## Configuration

`recorder.setup{...}` or `recorder.attach{...}`:

| key | default | meaning |
|---|---|---|
| `fps` | `60` | video frame rate and fixed simulation step |
| `audio` | `"auto"` | `"auto"`, `"loopback"`, `"events"` or `"none"`. `"auto"` uses loopback when it is available and the event re-mix otherwise |
| `ffmpeg` | `"ffmpeg"` | ffmpeg executable (`FFMPEG` env var also works) |
| `encoder` | `"auto"` | `"auto"` (first working of `h264_nvenc`, `h264_amf`, `h264_qsv`, else libx264), `"libx264"` or an encoder name |
| `crf`, `preset` | `18`, `"veryfast"` | x264 quality / speed (hardware encoders use matching presets) |
| `outDir` | `"recordings"` | output folder inside the save directory |
| `key` | `"f9"` | toggle key for `attach()` (`nil` disables it) |
| `pace` | `true` | sleep while recording so the game never runs faster than real time |
| `overlay` | `true` | `attach()` draws the REC status |
| `trackAudio` | `true` | track Sources for the re-mix fallback |

## How the audio works

| mode | what you get | limits |
|---|---|---|
| **loopback** | Exactly what the game played, untouched: mixing, effects and volume changes included | Windows 10 2004+. In sync while the game keeps real time; if it fell behind, the note says by how much (cut the audio there to re-align) |
| **events** | A re-mix of every tracked Source on the video clock, frame-exact even if encoding made the game lag | Only Sources created from files (`love.audio.newSource(path, ...)`). Procedural audio (SoundData / queueable sources) is not re-mixed |

Placement: `loopback.exe` stamps the QueryPerformanceCounter time of its first sample, which puts the WAV on the video clock. Nothing else is done to the audio. Sounds reach the capture after the engine's output buffering, a constant few tens of milliseconds.

The recorder writes a status line like `done|.../clip.mp4|180|loopback, h264_amf`. If the game fell behind real time while recording it reads `loopback (WARNING: recording ran 1.65 s behind real time), ...`: that much audio drift by the end of the clip. The demo's `--selftest auto --slow` records at about half speed to show the warning.

## Demo

This repository is itself a small LÖVE demo: bouncing balls with sound.

```
love .                          # play, F9 records
love . --selftest [mode]        # record 3 s automatically and quit (mode: auto|loopback|events|none)
love . --selftest auto --slow   # the same, slower than real time (shows the lag warning)
love . --selftest auto --keep   # 20 s, keeps the raw loopback WAV next to the clip
```

## Building loopback.exe

`loopback/build.bat` builds it with the Visual Studio 2022 C++ toolset (x64) and writes `recorder/bin/loopback.exe`.

```
loopback.exe <pid> <out.wav>
```

The helper records 48 kHz 32-bit float stereo from `<pid>` and its child processes. It stops when `<out.wav>.stop` appears or a line arrives on stdin, then writes `<out.wav>.start` with the first sample's QPC time. Silent gaps are filled using the packets' QPC positions, so the track keeps wall-clock time.

## License

MIT. See [LICENSE](LICENSE). `loopback/loopback.cpp` is based on Microsoft's ApplicationLoopback sample (MIT). See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
