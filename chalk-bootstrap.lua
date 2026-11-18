-- Portable Chalk Assist startup. Executor attachment is still required.
-- Automatic callers pass {automatic=true}; a manual run can restart after F8.
local options=(...)
options=type(options)=="table" and options or {}
local GAME_ID,PLACE_ID=10770281752,116097127629859
local MAIN_URL="https://raw.githubusercontent.com/BananaMan2006/chalk-assist/main/chalk-it-up-1v1.lua"
local CACHE_FILE="chalk-it-up-cache.lua"
local MAIN_FILE="chalk-it-up-1v1.lua"
local MARKER="__ChalkAssistAutoBoot"
local env=type(getgenv)=="function" and getgenv() or _G
local boot
local deadline=os.clock()+90
local function report(message)
    if type(writefile)=="function" then pcall(writefile,"ciu_autoload_status.txt",message) end
end
local function running()
    local api=env.ChalkDB
    if type(api)~="table" or type(api.status)~="function" then return false end
    if type(api.context)=="function" then
        local good,current=pcall(api.context)
        if good and type(current)=="table" and current.jobId and current.jobId~=game.JobId then return false end
    end
    local ok,s=pcall(api.status)
    return ok and type(s)=="table" and type(s.auto)=="table"
end
local function sameJob(value)
    return type(value)=="table" and value.gameId==game.GameId
        and value.placeId==game.PlaceId and value.jobId==game.JobId
end
local function interrupted()
    if env[MARKER]~=boot then return "superseded" end
    if boot.state=="unloaded" then return "unloaded" end
    if running() then boot.state="loaded";return "already-running" end
end
local function waitFor(read,name)
    repeat
        local value=read()
        if value then return value end
        if os.clock()>=deadline then error("Timed out waiting for "..name,0) end
        task.wait(.1)
    until false
end
local function child(parent,name)
    return waitFor(function() return parent:FindFirstChild(name) end,name)
end
local function compile(source)
    if type(source)~="string" or #source==0 or #source>2*1024*1024 then return end
    local ok,chunk=pcall(loadstring,source,"Chalk Assist")
    if ok and type(chunk)=="function" then return chunk end
end
local function download()
    local available,httpGet=pcall(function() return game.HttpGet end)
    if available and type(httpGet)=="function" then
        local ok,body=pcall(httpGet,game,MAIN_URL)
        if ok and type(body)=="string" then return body end
    end
    local send=type(request)=="function" and request
        or type(http_request)=="function" and http_request
        or type(syn)=="table" and type(syn.request)=="function" and syn.request
    if send then
        local ok,response=pcall(send,{Url=MAIN_URL,Method="GET"})
        if ok and type(response)=="table" and tonumber(response.StatusCode)==200 then return response.Body end
    end
end
local ok,result=pcall(function()
    waitFor(function() return game:IsLoaded() end,"Roblox")
    if game.GameId~=GAME_ID or game.PlaceId~=PLACE_ID then return "unsupported-game" end
    local previous=env[MARKER]
    if sameJob(previous) then
        if previous.state=="waiting" or previous.state=="starting" then return "already-starting" end
        if running() then return "already-running" end
        if options.automatic then return "already-started" end -- F8 stays unloaded in this server.
    elseif previous==nil and running() then
        env[MARKER]={gameId=game.GameId,placeId=game.PlaceId,jobId=game.JobId,state="loaded"}
        return "already-running"
    end
    boot={gameId=game.GameId,placeId=game.PlaceId,jobId=game.JobId,state="waiting"}
    env[MARKER]=boot
    local me=waitFor(function() return game:GetService("Players").LocalPlayer end,"LocalPlayer")
    child(me,"PlayerGui")
    local moves=child(child(child(me,"PlayerScripts"),"Game"),"Moves")
    assert(moves:IsA("ModuleScript"),"Game.Moves is unavailable")
    local rs=game:GetService("ReplicatedStorage")
    local shared=child(rs,"Shared")
    for _,name in ipairs({"Config","Field","DivePath"}) do child(shared,name) end
    local remotes=child(rs,"Remotes")
    child(remotes,"Match");child(remotes,"Fx")
    local field=child(child(workspace,"Fields"),"Field1")
    local lines=child(field,"Lines")
    for _,name in ipairs({"Sideline_L","Sideline_R","BackLine","EndLine","GoalLine"}) do child(lines,name) end
    child(field,"Endzone")
    local stopped=interrupted()
    if stopped then return stopped end
    assert(type(loadstring)=="function","Executor loadstring is unavailable")
    local source=download()
    local chunk=compile(source)
    local downloaded=chunk~=nil
    if not chunk and type(readfile)=="function" then
        for _,path in ipairs({CACHE_FILE,MAIN_FILE}) do
            local readOK,cached=pcall(readfile,path)
            if readOK then
                local cachedChunk=compile(cached)
                if cachedChunk then source,chunk=cached,cachedChunk;break end
            end
        end
    end
    stopped=interrupted() -- HTTP/file APIs can yield while a manual load or F8 runs.
    if stopped then return stopped end
    assert(chunk,"Public download and local cache are unavailable; try again manually")
    boot.state="starting"
    chunk()
    assert(running(),"Chalk Assist did not finish starting")
    boot.state="loaded"
    if downloaded and type(writefile)=="function" then pcall(writefile,CACHE_FILE,source) end
    report(downloaded and "Chalk Assist loaded from the public repository."
        or "Chalk Assist loaded from the local cache; the public download was unavailable.")
    return downloaded and "loaded-public" or "loaded-cache"
end)
if not ok then
    if boot and env[MARKER]==boot then env[MARKER]=nil end
    report("Chalk Assist startup failed. Try the loader again manually.")
    if type(warn)=="function" then warn("Chalk Assist startup failed: "..tostring(result)) end
    return false,tostring(result)
end
return true,result
