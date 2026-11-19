-- Screenshot at 8 s, then quit. Used by a4-check.bat.
-- The Windows build ships luajit, so this works there; the macOS prefix-vk
-- build is compiled with -Dlua=disabled and cannot load it.
local done = false
mp.observe_property("time-pos", "number", function(_, v)
    if not done and v and v >= 8.0 then
        done = true
        mp.commandv("screenshot", "video")
        mp.add_timeout(0.8, function() mp.command("quit") end)
    end
end)
