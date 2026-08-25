-- Per-machine Hyprland overlay for compositor-local setup.
-- Monitor rules belong in monitors.lua so Walker can update them safely.
-- hl.config({ master = { new_status = "slave", orientation = "center" } })
-- The start event may perform compositor-local dispatch or configuration work.
-- Do not launch GUI applications or long-lived processes before the lock gate.

return {}
