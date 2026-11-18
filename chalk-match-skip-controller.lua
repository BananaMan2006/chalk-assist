-- Rejoin the verified public place only for an exact, current enemy account.
-- Queue cancellation cannot leave a match; this controller owns no queue remote.
return function(ctx,services)
    services=services or {}
    local Players=services.players or game:GetService("Players")
    local player=services.player or Players.LocalPlayer
    local TeleportService=services.teleportService or game:GetService("TeleportService")
    local RunService=services.runService or game:GetService("RunService")
    local Http=services.http or game:GetService("HttpService")
    local now=services.now or function() return workspace:GetServerTimeNow() end
    local gameId=services.gameId or game.GameId
    local placeId=services.placeId or game.PlaceId
    local jobId=services.jobId or game.JobId
    local function optional(key,fallback)
        if services[key]~=nil then return services[key] end
        return fallback
    end
    local read,write,exists=optional("read",readfile),optional("write",writefile),optional("exists",isfile)
    local SettingsFile="ciu_match_skip_settings.json"
    local GameId,PlaceId=10770281752,116097127629859
    local activePhases={Pick=true,PreSnap=true,Hike=true,Live=true,RAC=true,Run=true}
    local roles={WR=true,DB=true,QB=true}
    local alive,editing=true,false
    local connections={}
    local enabled,username=false,""
    local saveError,loadError,lastSaved,message,lastError
    local requestState,attempts="idle",0
    local pendingSince,nextRetryAt,requestedUsername,matchedUsername,matchedUserId,blockedReason
    local api={}

    local function cleanUsername(value)
        if type(value)~="string" then return nil,"Enter a Roblox username" end
        value=string.match(value,"^%s*(.-)%s*$")
        if string.sub(value,1,1)=="@" then value=string.sub(value,2) end
        if value=="" then return "" end
        if #value<3 or #value>20 or not string.match(value,"^[A-Za-z0-9_]+$") then
            return nil,"Use 3–20 letters, numbers, or underscores"
        end
        return value
    end
    local function validSettings(value)
        if type(value)~="table" or value.version~=1 or type(value.enabled)~="boolean" then return nil end
        local name=cleanUsername(value.username)
        if name==nil then return nil end
        return {enabled=value.enabled,username=name}
    end
    local previous=type(ctx.previousState)=="table" and ctx.previousState or nil
    local sameJob=previous and previous.jobId==jobId
    local previousSettings=previous and validSettings({version=1,enabled=previous.enabled,username=previous.username})
    local function save()
        local fingerprint=tostring(enabled)..":"..username
        if lastSaved==fingerprint and not saveError then return true end
        if type(write)~="function" then saveError="Saving match skip settings is unavailable";return false end
        local ok,err=pcall(function()
            write(SettingsFile,Http:JSONEncode({version=1,enabled=enabled,username=username}))
            if type(read)=="function" then
                local saved=validSettings(Http:JSONDecode(read(SettingsFile)))
                assert(saved and saved.enabled==enabled and saved.username==username,"Settings readback did not match")
            end
        end)
        if not ok then saveError=tostring(err);return false end
        lastSaved,saveError,loadError=fingerprint,nil,nil
        return true
    end
    local missing=false
    local settings
    if type(exists)=="function" then
        local ok,present=pcall(exists,SettingsFile)
        if ok and present==false then missing=true
        elseif not ok then loadError="Could not check saved match skip settings: "..tostring(present) end
    end
    if not missing and not loadError then
        if type(read)~="function" then loadError="Reading match skip settings is unavailable"
        else
            local ok,value=pcall(function() return Http:JSONDecode(read(SettingsFile)) end)
            if ok then
                settings=validSettings(value)
                if not settings then loadError="Saved match skip settings are invalid" end
            elseif type(exists)~="function" and (string.find(string.lower(tostring(value)),"no such file",1,true)
                or string.find(string.lower(tostring(value)),"file not found",1,true)
                or string.find(string.lower(tostring(value)),"does not exist",1,true)) then
                missing=true
            else loadError="Could not read match skip settings: "..tostring(value) end
        end
    end
    -- A failed prior save must retain the user's current choice across a reload.
    -- Corrupt/unreadable preferences never silently enable the initial target.
    if sameJob and previousSettings and type(previous.saveError)=="string" then
        enabled,username=previousSettings.enabled,previousSettings.username
        saveError=previous.saveError
        save()
    elseif settings then
        enabled,username=settings.enabled,settings.username
        lastSaved=tostring(enabled)..":"..username
    elseif sameJob and previousSettings then
        enabled,username=previousSettings.enabled,previousSettings.username
        saveError=loadError
        if missing then save() end
    elseif missing then
        enabled,username=true,"stupieddaniel"
        save()
    else saveError=loadError end

    local function finite(value)
        return type(value)=="number" and value==value and math.abs(value)<math.huge
    end
    if sameJob then
        attempts=finite(previous.attempts) and math.max(0,math.min(3,math.floor(previous.attempts))) or 0
        if attempts>0 then
            requestedUsername=cleanUsername(previous.requestedUsername)
            matchedUsername=type(previous.matchedUsername)=="string" and previous.matchedUsername or nil
            matchedUserId=type(previous.matchedUserId)=="number" and previous.matchedUserId or nil
            lastError=type(previous.error)=="string" and previous.error or nil
            blockedReason=type(previous.blockedReason)=="string" and previous.blockedReason or nil
            if previous.requestState=="pending" and finite(previous.pendingSince) then
                requestState,pendingSince="pending",previous.pendingSince
            elseif previous.requestState=="retry" and attempts<3 and finite(previous.nextRetryAt) then
                requestState,nextRetryAt="retry",previous.nextRetryAt
            else
                requestState="blocked"
                blockedReason=blockedReason or "Previous rejoin request already handled"
            end
        end
    end

    local function match(s)
        if gameId~=GameId or placeId~=PlaceId then return nil,"Available in the verified Chalk It Up place only" end
        if not enabled then return nil,"Match skip off" end
        if username=="" then return nil,"Enter a username to skip" end
        if editing then return nil,"Editing match skip username" end
        if type(s)~="table" or s.alive==false then return nil,"Waiting for the match" end
        if s.enabled==false then return nil,"Match skip · assist is off" end
        if s.testing then return nil,"Match skip · paused for test" end
        if s.mode~=nil and s.mode~="1v1" and s.mode~="Team" then return nil,"Waiting for a supported match" end
        local activeRole=roles[s.role] or s.mode=="Team" and s.role=="O"
        if not activePhases[s.phase] or not activeRole then return nil,"Waiting for an active match" end
        if s.matchIdentityVerified~=true or s.modeSource=="unconfirmed" or s.modeSource=="lobby" then
            return nil,"Waiting for a verified opponent"
        end
        local wanted=string.lower(username)
        local function resolve(character)
            if not character or character==player.Character then return nil end
            local ok,enemy=pcall(function() return Players:GetPlayerFromCharacter(character) end)
            if not ok or not enemy or enemy==player or enemy.Character~=character then return nil end
            if type(enemy.Name)=="string" and string.lower(enemy.Name)==wanted then return enemy end
        end
        -- Team opponents is the trusted enemy roster; its cached single
        -- receiver can belong to an earlier play and must never be a fallback.
        if type(s.opponents)=="table" then
            for _,character in ipairs(s.opponents) do
                local enemy=resolve(character)
                if enemy then return enemy end
            end
        end
        if s.mode~="Team" then
            local enemy=resolve(s.opponent)
            if enemy then return enemy end
        end
        return nil,"Waiting for @"..username
    end
    local function block(reason)
        requestState,blockedReason="blocked",reason
        pendingSince,nextRetryAt=nil,nil
        message="Match skip · "..reason
    end
    local function failed(reason)
        if not alive or requestState~="pending" then return end
        lastError=tostring(reason)
        pendingSince=nil
        if not enabled then block("Rejoin failed; retries stopped while off")
        elseif attempts>=3 then block("Rejoin failed after 3 attempts")
        else
            requestState="retry"
            nextRetryAt=now()+(attempts==1 and 5 or 10)
            message="Rejoin failed · retry "..(attempts+1).." of 3 scheduled"
        end
    end
    local function request(enemy)
        if not alive or requestState=="pending" or attempts>=3 then return end
        attempts=attempts+1
        requestedUsername=requestedUsername or string.lower(username)
        matchedUsername,matchedUserId=enemy.Name,enemy.UserId
        requestState,pendingSince,nextRetryAt="pending",now(),nil
        blockedReason,lastError=nil,nil
        message="Skipping @"..enemy.Name.." · rejoining public lobby"
        -- Mark pending first: synchronous failure callbacks cannot double-send.
        local ok,err=pcall(function() TeleportService:Teleport(PlaceId,player) end)
        if not ok then failed(err) end
    end
    local function tick()
        if not alive then return end
        if requestState=="pending" then
            if now()-pendingSince>=20 then block("Rejoin timed out; no duplicate request sent") end
            return
        end
        if requestState=="blocked" then
            message="Match skip · "..(blockedReason or "Rejoin already requested")
            return
        end
        local enemy,reason=match(ctx.snapshot())
        if requestState=="retry" then
            if not enabled then block("Retries stopped while off");return end
            if string.lower(username)~=requestedUsername then block("Username changed; retry cancelled");return end
            if editing then message=reason;return end
            if now()<nextRetryAt then return end
            if not enemy or (matchedUserId and enemy.UserId~=matchedUserId) then
                block("Opponent or match changed; retry cancelled")
                return
            end
        end
        if enemy then request(enemy) else message=reason end
    end
    function api.status()
        return {enabled=enabled,username=username,editing=editing,alive=alive,message=message,
            saveError=saveError,loadError=loadError,error=lastError,attempts=attempts,jobId=jobId,
            placeId=PlaceId,requestState=requestState,pending=requestState=="pending",
            pendingSince=pendingSince,nextRetryAt=nextRetryAt,requestedUsername=requestedUsername,
            matchedUsername=matchedUsername,matchedUserId=matchedUserId,blockedReason=blockedReason}
    end
    function api.setEnabled(value)
        if not alive then return false,"Match skip is unloaded" end
        if type(value)~="boolean" then return false,"Enabled must be true or false" end
        enabled=value
        if not enabled and requestState=="retry" then block("Retries stopped while off") end
        if requestState=="idle" then message=enabled and "Waiting for an active match" or "Match skip off" end
        save()
        return true,saveError
    end
    function api.setUsername(value)
        if not alive then return false,"Match skip is unloaded" end
        local cleaned,reason=cleanUsername(value)
        if cleaned==nil then return false,reason end
        username=cleaned
        if requestState=="retry" and string.lower(username)~=requestedUsername then
            block("Username changed; retry cancelled")
        end
        if requestState=="idle" then message=username=="" and "Enter a username to skip" or "Waiting for @"..username end
        save()
        return true,saveError
    end
    function api.setEditing(value)
        if not alive then return false,"Match skip is unloaded" end
        if type(value)~="boolean" then return false,"Editing must be true or false" end
        editing=value
        if editing and requestState=="idle" then message="Editing match skip username" end
        return true
    end
    function api.unload()
        if not alive then return end
        alive=false
        for _,connection in ipairs(connections) do connection:Disconnect() end
        -- Do not clear dedupe: status is the same-job reload handoff.
    end
    connections[#connections+1]=TeleportService.TeleportInitFailed:Connect(function(failedPlayer,result,reason,placeId)
        if alive and failedPlayer==player and placeId==PlaceId then
            failed(tostring(result)..": "..tostring(reason))
        end
    end)
    local accumulator=0
    connections[#connections+1]=RunService.Heartbeat:Connect(function(dt)
        if not alive then return end
        accumulator=accumulator+dt
        if accumulator<0.25 then return end
        accumulator=0
        local ok,err=pcall(tick)
        if not ok then lastError=tostring(err);message="Match skip paused · "..lastError end
    end)
    message=requestState=="pending" and "Rejoin already requested · waiting"
        or requestState=="retry" and "Rejoin retry scheduled"
        or requestState=="blocked" and ("Match skip · "..blockedReason)
        or not enabled and "Match skip off"
        or username=="" and "Enter a username to skip" or "Waiting for @"..username
    return api
end
