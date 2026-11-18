from pathlib import Path

root = Path(__file__).resolve().parent
core = (root / "chalk-overlay-core.lua").read_text()
planner = (root / "chalk-intercept-planner.lua").read_text()
controller = (root / "chalk-intercept-controller.lua").read_text()
tackle = (root / "chalk-tackle-controller.lua").read_text()
approach = (root / "chalk-wr-approach.lua").read_text()
motion = (root / "chalk-character-motion.lua").read_text()
carrier_moves = (root / "chalk-carrier-moves.lua").read_text()
autoplay_policy = (root / "chalk-autoplay-policy.lua").read_text()
autoplay_controller = (root / "chalk-autoplay-controller.lua").read_text()
wr_repeat = (root / "chalk-wr-repeat-controller.lua").read_text()
idle_guard = (root / "chalk-idle-guard.lua").read_text()
fullplay_policy = (root / "chalk-fullplay-policy.lua").read_text()
fullplay_controller = (root / "chalk-fullplay-controller.lua").read_text()
match_skip_controller = (root / "chalk-match-skip-controller.lua").read_text()
bundle = """local Planner = (function()
%s
end)()
local createTackle = (function()
%s
end)()
local WRApproach = (function()
%s
end)()
local Motion = (function()
%s
end)()
local createCarrierMoves = (function()
%s
end)()
local createAssist = (function()
%s
end)()
assist = createAssist({snapshot=api.context,fullplay=function(s,root,h,now,dt)
    if fullplay then return fullplay.navigate(s,root,h,now,dt) end
end},Planner,createTackle,WRApproach,Motion,createCarrierMoves)
if previousState then
    api.setEnabled(previousState.enabled~=false)
    if previousState.auto then assist.setEnabled(previousState.auto.enabled~=false) end
end
local AutoplayPolicy = (function()
%s
end)()
local createAutoplay = (function()
%s
end)()
autoplay = createAutoplay({snapshot=api.context,previousState=previousState and previousState.autoplay},AutoplayPolicy)
local createWRRepeat = (function()
%s
end)()
repeatWR = createWRRepeat({snapshot=api.context,previousState=previousState and previousState.wrRepeat,
    autoplay=function() return autoplay.status() end,
    disableAutoplay=function() return api.setAutoplay(false) end})
local createIdleGuard = (function()
%s
end)()
idleGuard = createIdleGuard()
local FullplayPolicy = (function()
%s
end)()
local createFullplay = (function()
%s
end)()
fullplay = createFullplay({snapshot=api.context,previousState=previousState and previousState.fullplay,
    assistEnabled=function() return assist.status().enabled end,
    release=function() if assist.releaseFullplay then assist.releaseFullplay() end end},FullplayPolicy)
local createMatchSkip = (function()
%s
end)()
matchSkip = createMatchSkip({snapshot=api.context,previousState=previousState and previousState.matchSkip})
""" % (planner, tackle, approach, motion, carrier_moves, controller, autoplay_policy, autoplay_controller, wr_repeat, idle_guard, fullplay_policy, fullplay_controller, match_skip_controller)
assert core.count("-- BUNDLED_INTERCEPT_INIT") == 1
(root / "chalk-it-up-1v1.lua").write_text(core.replace("-- BUNDLED_INTERCEPT_INIT", bundle))
print("Built chalk-it-up-1v1.lua")
