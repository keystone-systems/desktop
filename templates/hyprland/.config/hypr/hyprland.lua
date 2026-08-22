-- Keystone Hyprland v0.56 configuration.
-- UWSM owns environment setup and persistent background services.

local mod = "SUPER"
local app = "uwsm app -- "

hl.config({
  animations = { enabled = true },
  cursor = { no_hardware_cursors = 1 },
  decoration = {
    rounding = 4,
    blur = { enabled = true, passes = 2, size = 5, vibrancy = 0.1696 },
    shadow = { color = "rgba(00000045)", enabled = false, range = 30, render_power = 3 },
  },
  dwindle = { force_split = 2, preserve_split = true },
  ecosystem = { no_update_news = true },
  general = { layout = "master" },
  input = {
    follow_mouse = 1,
    kb_layout = "us",
    kb_options = "ctrl:nocaps,altwin:swap_alt_win",
    scroll_factor = 0.4,
    sensitivity = 0,
    touchpad = { drag_lock = 0, natural_scroll = true },
  },
  master = { new_status = "master" },
  misc = {
    disable_hyprland_logo = true,
    disable_splash_rendering = true,
    disable_watchdog_warning = true,
    force_default_wallpaper = 0,
    -- These settings are the only DPMS-off recovery path that does not depend
    -- on hypridle's on-resume hook or the lid-open bind below. A wedged connector
    -- still needs keystone-dpms-wake; input alone cannot re-enable it.
    key_press_enables_dpms = true,
    mouse_move_enables_dpms = true,
  },
  xwayland = { force_zero_scaling = true },
})

hl.curve("easeOutQuint", { type = "bezier", points = { { 0.23, 1 }, { 0.32, 1 } } })
hl.curve("easeInOutCubic", { type = "bezier", points = { { 0.65, 0.05 }, { 0.36, 1 } } })
hl.curve("linear", { type = "bezier", points = { { 0, 0 }, { 1, 1 } } })
hl.curve("almostLinear", { type = "bezier", points = { { 0.5, 0.5 }, { 0.75, 1 } } })
hl.curve("quick", { type = "bezier", points = { { 0.15, 0 }, { 0.1, 1 } } })

hl.animation({ leaf = "global", enabled = true, speed = 10, bezier = "default" })
hl.animation({ leaf = "border", enabled = true, speed = 5.39, bezier = "easeOutQuint" })
hl.animation({ leaf = "windows", enabled = true, speed = 4.79, bezier = "easeOutQuint" })
hl.animation({ leaf = "windowsIn", enabled = true, speed = 4.1, bezier = "easeOutQuint", style = "popin 87%" })
hl.animation({ leaf = "windowsOut", enabled = true, speed = 1.49, bezier = "linear", style = "popin 87%" })
hl.animation({ leaf = "fadeIn", enabled = true, speed = 1.73, bezier = "almostLinear" })
hl.animation({ leaf = "fadeOut", enabled = true, speed = 1.46, bezier = "almostLinear" })
hl.animation({ leaf = "fade", enabled = true, speed = 3.03, bezier = "quick" })
hl.animation({ leaf = "layers", enabled = true, speed = 3.81, bezier = "easeOutQuint" })
hl.animation({ leaf = "layersIn", enabled = true, speed = 4, bezier = "easeOutQuint", style = "fade" })
hl.animation({ leaf = "layersOut", enabled = true, speed = 1.5, bezier = "linear", style = "fade" })
hl.animation({ leaf = "fadeLayersIn", enabled = true, speed = 1.79, bezier = "almostLinear" })
hl.animation({ leaf = "fadeLayersOut", enabled = true, speed = 1.39, bezier = "almostLinear" })
hl.animation({ leaf = "workspaces", enabled = false, speed = 0, bezier = "default" })

local function bind(keys, dispatcher, options)
  hl.bind(keys, dispatcher, options or {})
end

bind(mod .. " + Return", hl.dsp.exec_cmd(app .. "ghostty"))
bind(mod .. " + Space", hl.dsp.exec_cmd(app .. "wofi --show drun"))
bind(mod .. " + B", hl.dsp.exec_cmd(app .. "chromium --new-window --ozone-platform=wayland"))
bind(mod .. " + E", hl.dsp.exec_cmd(app .. "nautilus --new-window"))
bind(mod .. " + Escape", hl.dsp.exec_cmd(app .. "keystone-menu system"))
bind(mod .. " + K", hl.dsp.exec_cmd(app .. "keystone-menu-keybindings"))
bind(mod .. " + W", hl.dsp.window.close())
bind("CTRL + ALT + DELETE", hl.dsp.window.close({ window = "address:.*" }))
bind(mod .. " + SHIFT + V", hl.dsp.window.float({ action = "toggle" }))
bind(mod .. " + P", hl.dsp.window.pseudo())
bind(mod .. " + H", hl.dsp.focus({ direction = "left" }))
bind(mod .. " + L", hl.dsp.focus({ direction = "right" }))
bind(mod .. " + T", hl.dsp.layout("togglesplit"))

for _, direction in ipairs({ "left", "right", "up", "down" }) do
  bind(mod .. " + " .. direction, hl.dsp.focus({ direction = direction }))
  bind(mod .. " + SHIFT + " .. direction, hl.dsp.window.swap({ direction = direction }))
end

for workspace = 1, 10 do
  local key = workspace % 10
  bind(mod .. " + " .. key, hl.dsp.focus({ workspace = workspace }))
  bind(mod .. " + SHIFT + " .. key, hl.dsp.window.move({ workspace = workspace }))
end

bind(mod .. " + TAB", hl.dsp.focus({ workspace = "e+1" }))
bind(mod .. " + SHIFT + TAB", hl.dsp.focus({ workspace = "e-1" }))
bind(mod .. " + CTRL + TAB", hl.dsp.focus({ workspace = "previous" }))
bind(mod .. " + comma", hl.dsp.focus({ workspace = "-1" }))
bind(mod .. " + period", hl.dsp.focus({ workspace = "+1" }))
bind(mod .. " + SHIFT + comma", hl.dsp.window.move({ workspace = "-1" }))
bind(mod .. " + SHIFT + period", hl.dsp.window.move({ workspace = "+1" }))
bind(mod .. " + mouse_down", hl.dsp.focus({ workspace = "e+1" }))
bind(mod .. " + mouse_up", hl.dsp.focus({ workspace = "e-1" }))
bind("ALT + TAB", hl.dsp.window.cycle_next({ next = true }))
bind("ALT + SHIFT + TAB", hl.dsp.window.cycle_next({ next = false }))
bind("ALT + TAB", hl.dsp.window.bring_to_top())
bind("ALT + SHIFT + TAB", hl.dsp.window.bring_to_top())
bind(mod .. " + S", hl.dsp.workspace.toggle_special("magic"))
bind(mod .. " + SHIFT + S", hl.dsp.window.move({ workspace = "special:magic" }))
bind(mod .. " + F", hl.dsp.window.fullscreen())
bind("SHIFT + F11", hl.dsp.window.fullscreen({ mode = "fullscreen" }))
bind("ALT + F11", hl.dsp.window.fullscreen({ mode = "maximized" }))
bind(mod .. " + SHIFT + T", hl.dsp.layout("togglesplit"))
bind(mod .. " + minus", hl.dsp.window.resize({ x = -100, y = 0, relative = true }))
bind(mod .. " + equal", hl.dsp.window.resize({ x = 100, y = 0, relative = true }))
bind(mod .. " + SHIFT + minus", hl.dsp.window.resize({ x = 0, y = -100, relative = true }))
bind(mod .. " + SHIFT + equal", hl.dsp.window.resize({ x = 0, y = 100, relative = true }))
bind(mod .. " + C", hl.dsp.send_shortcut({ mods = "CTRL", key = "Insert" }))
bind(mod .. " + V", hl.dsp.send_shortcut({ mods = "SHIFT", key = "Insert" }))
bind(mod .. " + X", hl.dsp.send_shortcut({ mods = "CTRL", key = "X" }))
bind(mod .. " + CTRL + V", hl.dsp.exec_cmd(app .. "ghostty --class clipse -e clipse"))
bind(mod .. " + CTRL + E", hl.dsp.exec_cmd(app .. "walker -m symbols"))
bind(mod .. " + SHIFT + Space", hl.dsp.exec_cmd("killall -SIGUSR1 waybar"))
bind(mod .. " + Backspace", hl.dsp.window.set_prop({ prop = "opaque", value = "toggle" }))
bind(mod .. " + SHIFT + N", hl.dsp.exec_cmd("makoctl dismiss"))
bind(mod .. " + ALT + N", hl.dsp.exec_cmd("makoctl dismiss --all"))
bind(mod .. " + CTRL + SHIFT + N", hl.dsp.exec_cmd("makoctl mode -t do-not-disturb"))
bind("Print", hl.dsp.exec_cmd(app .. "keystone-screenshot"))
bind("SHIFT + Print", hl.dsp.exec_cmd(app .. "keystone-screenshot smart clipboard"))
bind(mod .. " + Print", hl.dsp.exec_cmd(app .. "hyprpicker -a"))
bind(mod .. " + CTRL + I", hl.dsp.exec_cmd("keystone-idle-toggle"))
bind(mod .. " + CTRL + N", hl.dsp.exec_cmd("keystone-nightlight-toggle"))

local repeat_locked = { locked = true, repeating = true }
bind("XF86AudioRaiseVolume", hl.dsp.exec_cmd("wpctl set-volume -l 1 @DEFAULT_AUDIO_SINK@ 5%+"), repeat_locked)
bind("XF86AudioLowerVolume", hl.dsp.exec_cmd("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-"), repeat_locked)
bind("XF86AudioMute", hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"), repeat_locked)
bind("XF86AudioMicMute", hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle"), repeat_locked)
bind("XF86MonBrightnessUp", hl.dsp.exec_cmd("brightnessctl -e4 -n2 set 5%+"), repeat_locked)
bind("XF86MonBrightnessDown", hl.dsp.exec_cmd("brightnessctl -e4 -n2 set 5%-"), repeat_locked)
for key, command in pairs({
  XF86AudioNext = "playerctl next",
  XF86AudioPause = "playerctl play-pause",
  XF86AudioPlay = "playerctl play-pause",
  XF86AudioPrev = "playerctl previous",
}) do
  bind(key, hl.dsp.exec_cmd(command), { locked = true })
end
bind("XF86PowerOff", hl.dsp.exec_cmd(app .. "keystone-menu system"), { locked = true })
-- A failed lock requests session termination and deliberately blocks suspend.
bind("switch:on:Lid Switch", hl.dsp.exec_cmd("keystone-lock --fail-closed && systemctl suspend"), { locked = true })
bind("switch:off:Lid Switch", function()
  -- Hyprland 0.56 advises deferring DPMS from key and switch handlers so
  -- the dispatch runs after input processing completes.
  hl.timer(function()
    hl.dispatch(hl.dsp.dpms({ action = "on" }))
  end, { timeout = 500, type = "oneshot" })
end, { locked = true })
bind(mod .. " + mouse:272", hl.dsp.window.drag(), { mouse = true })
bind(mod .. " + mouse:273", hl.dsp.window.resize(), { mouse = true })

hl.layer_rule({ name = "slurp-no-animation", match = { namespace = "slurp" }, no_anim = true })

local function window_rule(name, match, effects)
  effects.name = name
  effects.match = match
  hl.window_rule(effects)
end

window_rule("chromium-tile", { class = "^(chromium)$" }, { tile = true })
window_rule("settings-float", { class = "^(org.pulseaudio.pavucontrol|.blueman-manager-wrapped|blueman-manager)$" }, { float = true })
window_rule("default-opacity", { class = ".*" }, { opacity = "0.97 0.9" })
window_rule("youtube-opacity", { class = "^(chromium|google-chrome|google-chrome-unstable)$", title = ".*Youtube.*" }, { opacity = "1 1" })
window_rule("browser-opacity", { class = "^(chromium|google-chrome|google-chrome-unstable)$" }, { opacity = "1 0.97" })
window_rule("chrome-app-opacity", { class = "^(chrome-.*-Default)$" }, { opacity = "0.97 0.9" })
window_rule("youtube-app-opacity", { class = "^(chrome-youtube.*-Default)$" }, { opacity = "1 1" })
window_rule("media-opacity", { class = "^(zoom|vlc|org.kde.kdenlive|com.obsproject.Studio)$" }, { opacity = "1 1" })
window_rule("game-opacity", { class = "^(com.libretro.RetroArch|steam)$" }, { opacity = "1 1" })
window_rule("clipse-float", { class = "(clipse)" }, { float = true, size = { 622, 652 } })
window_rule("notes-inbox", { class = "^(com.mitchellh.ghostty)$", title = "^(keystone-notes-inbox)$" }, { float = true, center = true, size = { 1000, 700 } })
window_rule("authentication", { class = "^$", title = "^(Authentication required)$" }, {
  float = true, center = true, size = { 486, 246 }, pin = true, opacity = "0.85 0.78", rounding = 12,
})

local function load_active_theme()
  local home = os.getenv("HOME")
  if not home then return end
  local chunk, load_error = loadfile(home .. "/.config/themes/current/hyprland.lua")
  if not chunk then
    print("Keystone theme load failed: " .. tostring(load_error))
    return
  end
  local ok, runtime_error = pcall(chunk)
  if not ok then print("Keystone theme failed: " .. tostring(runtime_error)) end
end

local function load_overlay(module)
  local ok, module_error = pcall(require, module)
  if not ok then print(module .. " overlay load failed: " .. tostring(module_error)) end
end

load_active_theme()
load_overlay("user")
load_overlay("host")
