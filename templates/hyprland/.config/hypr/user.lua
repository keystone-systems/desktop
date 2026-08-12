-- Personal Hyprland overlay. This module loads after the active theme.
-- Examples:
-- hl.bind("SUPER + N", hl.dsp.exec_cmd("uwsm app -- obsidian"))
-- hl.window_rule({ name = "messaging", match = { class = "Signal" }, tag = "+messaging", no_screen_share = true })
-- The start event may perform compositor-local dispatch or configuration work.
-- Do not launch GUI applications or long-lived processes here. Keystone gates
-- those systemd services on graphical-session.target after the startup lock.
-- hl.on("hyprland.start", function() hl.dispatch(hl.dsp.focus({ workspace = 2 })) end)

return {}
