-- Per-machine Hyprland overlay for monitors and compositor-local setup.
-- Prefer EDID descriptions because connector names can change.
-- hl.monitor({ output = "desc:Example Corp EX2790 SERIAL123", mode = "3840x2160@60.00", position = "0x0", scale = 2 })
-- hl.monitor({ output = "", mode = "preferred", position = "auto", scale = 1 })
-- hl.config({ master = { new_status = "slave", orientation = "center" } })
-- The start event may perform compositor-local dispatch or configuration work.
-- Do not launch GUI applications or long-lived processes before the lock gate.

return {}
