-- Full 1v1 play setup/navigation. Catch and tackle execution keep movement priority.
return function(ctx,Policy,services)
    services=services or {}
    local player=services.player or game:GetService("Players").LocalPlayer
    local world=services.world or workspace
    local rs=services.rs or game:GetService("ReplicatedStorage")
    local Config=services.Config or require(rs.Shared.Config)
    local Field=services.Field or require(rs.Shared.Field)
    local RouteMath=services.RouteMath or require(rs.Shared.RouteMath)
    local board=services.board or require(player.PlayerScripts.Game.RouteBoard)
    local submit=services.submit or function(payload) rs.Remotes.Submit:FireServer(payload) end
    local uis=services.uis or game:GetService("UserInputService")
    local guiService=services.guiService or game:GetService("GuiService")
    local run=services.runService or game:GetService("RunService")
    local http=services.http or game:GetService("HttpService")
    local read=services.read or readfile
    local write=services.write or writefile
    local append=services.append or appendfile
    local jobId=services.jobId or (game and game.JobId) or ""
    local settingsFile="ciu_fullplay_settings.json"
    local memoryFile="ciu_fullplay_route_memory.json"
    local storedMemory
    local enabled=ctx.previousState and ctx.previousState.enabled==true or false
    if type(read)=="function" then
        local ok,saved=pcall(function() return http:JSONDecode(read(settingsFile)) end)
        if ok and type(saved)=="table" and type(saved.enabled)=="boolean" then enabled=saved.enabled end
        local readOk,record=pcall(function() return http:JSONDecode(read(memoryFile)) end)
        if readOk and type(record)=="table" and record.schema==1 then storedMemory=record end
    end
    local alive=true
    local selected,routePlan,routeSource,planPass
    local routeWaypoint=2
    local lastLoggedWaypoint
    local roundKey,submitted,nextSubmit,submitTries=nil,false,0,0
    local laneSide,priorTarget,lastPhase,lastKind,lastSample=nil,nil,nil,nil,0
    local finalSprintCommitted=false
    local message,errorMessage,saveError="Full auto off",nil,nil
    local navigationError
    local recentRoutes,memoryOpponent,activeRoute={},nil,nil
    local recentDefense,activeDefense={},nil
    local memoryOpponentId,memorySavedAt,memorySaveError
    local recentSelections,selectionIndex={},0
    local lastLateBendTrialTrigger
    local observationStarted
    local counters={routeRequests=0,rounds=0,pointsWon=0,pointsLost=0}
    local api={}
    local function log(kind,data)
        if type(append)~="function" then return end
        data=data or {};data.kind=kind;data.time=world:GetServerTimeNow();data.version="2.43"
        pcall(function() append("ciu_fullplay_events.jsonl",http:JSONEncode(data)..string.char(10)) end)
    end
    local function pauseReason(s)
        if not alive or not enabled then return "Full auto off" end
        if not s.enabled or ctx.assistEnabled and not ctx.assistEnabled() then return "Full auto paused · assist off" end
        if s.testing then return "Full auto paused · local test" end
        if s.mode=="Team" or (s.mode and s.mode~="1v1") then return "Full auto · 1v1 only" end
        if uis:GetFocusedTextBox() or guiService.MenuIsOpen then return "Full auto paused · menu or text input" end
    end
    local function rootOf(character)
        return character and character:FindFirstChild("HumanoidRootPart")
    end
    local function coordinates(point)
        if typeof(point)=="Vector3" then return {x=point.X,y=point.Y,z=point.Z} end
    end
    local function descriptor(value)
        if type(value)~="table" or (value.pass~="Bullet" and value.pass~="Floater")
            or type(value.shape)~="string" or #value.shape>32 or type(value.depth)~="number"
            or value.depth~=value.depth or value.depth<0 or value.depth>100 then return nil end
        local out={}
        for _,key in ipairs({"pass","side","depth","shape","family","signature","success",
            "contested","result","time","roundKey","arrival","catchSuccess",
            "terminalResult","terminalAt","cutCount","lastCutAt","experimentalAttempt",
            "trialTrigger","experimentalClearanceGap","middleStemDeep","stemYards","cutLeadTime",
            "finishMode","estimatedFinishAt","estimatedFinishZ","finishReachable","finishDistance",
            "finishTravelTime","finishReserve","finishFraction","routeStrategy","slowStem",
            "slowStemTime","slowStemSpeed","slowStemStartupSlack","cutAt","startSprintAt","forceDiveFinish",
            "requireDive","finalSprint","finalSprintDuration","finalSprintReserve","finalSprintStamina",
            "sidelineInset","sidelineFallback","sidelineFallbackReason","diveWitnessElapsed",
            "diveWitnessX","diveWitnessZ","diveWitnessMargin"}) do
            local v=value[key]
            if type(v)=="boolean" or type(v)=="string" and #v<=512
                or type(v)=="number" and v==v and math.abs(v)<math.huge then out[key]=v end
        end
        return out
    end
    local function copyRecent()
        local result={}
        for _,item in ipairs(recentRoutes) do result[#result+1]=descriptor(item) end
        return result
    end
    local function copySelections()
        local result={}
        for _,item in ipairs(recentSelections) do result[#result+1]=descriptor(item) end
        return result
    end
    local function finite(value)
        return type(value)=="number" and value==value and math.abs(value)<math.huge
    end
    local function defenseDescriptor(value)
        if type(value)~="table" or (value.pass~="Bullet" and value.pass~="Floater")
            or not finite(value.launchAt) or not finite(value.depthAtThrow)
            or not finite(value.targetDepthYards) or not finite(value.goalDistanceYards)
            or type(value.deepEndzone)~="boolean" or type(value.playKey)~="string"
            or #value.playKey>256 then return nil end
        local out={}
        for _,key in ipairs({"pass","launchAt","depthAtThrow","targetDepthYards","goalDistanceYards",
            "deepEndzone","playKey","roundKey","result","opponentCaught","time"}) do
            local v=value[key]
            if type(v)=="boolean" or type(v)=="string" and #v<=256 or finite(v) then out[key]=v end
        end
        return out
    end
    local function copyDefense()
        local result={}
        for _,item in ipairs(recentDefense) do result[#result+1]=defenseDescriptor(item) end
        return result
    end
    local function defenseProfile()
        local bias,losses=0,0
        for _,item in ipairs(recentDefense) do
            if item.pass=="Floater" and item.deepEndzone then
                if item.opponentCaught and item.depthAtThrow<=.5 then
                    bias=math.min(2.5,bias+1.25);losses=losses+1
                elseif item.result=="Swatted" or item.result=="Intercepted" then
                    bias=math.max(0,bias-.25)
                end
            elseif item.pass=="Bullet" and not item.deepEndzone and item.opponentCaught then
                bias=math.max(0,bias-.5)
            end
        end
        return {depthBiasYards=bias,samples=#recentDefense,deepFloaterLosses=losses}
    end
    local function validId(value)
        return type(value)=="number" and value==value and value>0 and value<math.huge
            and value==math.floor(value)
    end
    local function opponentIdentity(s)
        local key=s.opponent and s.opponent.Name
        if type(key)~="string" or key=="" or #key>128 then return nil end
        local ok,id=pcall(function()
            local players=services.players or game:GetService("Players")
            local account=players:GetPlayerFromCharacter(s.opponent)
            return account and account.UserId
        end)
        return key,ok and validId(id) and id or nil
    end
    local function sameOpponent(memory,key,id)
        if type(memory)~="table" then return false end
        if validId(memory.opponentUserId) and validId(id) then return memory.opponentUserId==id end
        return memory.opponentKey==key
    end
    local function fresh(memory,now)
        local at=type(memory)=="table" and memory.savedAt
        return type(at)=="number" and at==at and at>=0 and at<=now and now-at<=1800
    end
    local function learningRecord()
        return {schema=1,jobId=jobId,opponentKey=memoryOpponent,opponentUserId=memoryOpponentId,
            savedAt=memorySavedAt,recentRoutes=copyRecent(),recentSelections=copySelections(),
            recentDefense=copyDefense(),selectionIndex=selectionIndex,lastLateBendTrialTrigger=lastLateBendTrialTrigger}
    end
    local function saveMemory()
        if not memoryOpponent then return end
        memorySavedAt=world:GetServerTimeNow()
        local record=learningRecord()
        storedMemory=record
        if type(write)~="function" then memorySaveError="Saving route learning is unavailable";return end
        local ok,err=pcall(function() write(memoryFile,http:JSONEncode(record)) end)
        memorySaveError=not ok and tostring(err) or nil
    end
    local function syncOpponent(s)
        local key,id=opponentIdentity(s)
        if not key then return end
        if memoryOpponent and sameOpponent({opponentKey=memoryOpponent,opponentUserId=memoryOpponentId},key,id) then
            memoryOpponent=key;memoryOpponentId=id or memoryOpponentId
            return
        end
        local initial=memoryOpponent==nil
        recentRoutes,activeRoute={},nil
        finalSprintCommitted=false
        recentDefense,activeDefense={},nil
        recentSelections,selectionIndex={},0
        lastLateBendTrialTrigger=nil
        routeWaypoint=2
        lastLoggedWaypoint=nil
        local now=world:GetServerTimeNow()
        local old=initial and ctx.previousState or nil
        local previous=old and old.routeMemory
        local sameJob=type(previous)=="table" and previous.jobId==jobId and sameOpponent(previous,key,id)
        local memory
        if type(previous)=="table" and sameOpponent(previous,key,id)
            and (fresh(previous,now) or sameJob and previous.savedAt==nil) then memory=previous end
        if sameOpponent(storedMemory,key,id) and fresh(storedMemory,now)
            and (not memory or (storedMemory.savedAt or 0)>(memory.savedAt or 0)) then memory=storedMemory end
        if memory then
                lastLateBendTrialTrigger=type(memory.lastLateBendTrialTrigger)=="string"
                    and #memory.lastLateBendTrialTrigger<=1024 and memory.lastLateBendTrialTrigger or nil
                local items=type(memory.recentRoutes)=="table" and memory.recentRoutes or {}
                for i=math.max(1,#items-5),#items do
                    local item=descriptor(items[i])
                    if item and type(item.success)=="boolean" then recentRoutes[#recentRoutes+1]=item end
                end
                local choices=type(memory.recentSelections)=="table" and memory.recentSelections or items
                for i=math.max(1,#choices-5),#choices do
                    local item=descriptor(choices[i])
                    if item then recentSelections[#recentSelections+1]=item end
                end
                local savedIndex=tonumber(memory.selectionIndex)
                selectionIndex=savedIndex and savedIndex==savedIndex and savedIndex>=0
                    and savedIndex<1e9 and math.floor(savedIndex) or #recentSelections
                local defense=type(memory.recentDefense)=="table" and memory.recentDefense or {}
                for i=math.max(1,#defense-5),#defense do
                    local item=defenseDescriptor(defense[i])
                    if item and type(item.opponentCaught)=="boolean" then recentDefense[#recentDefense+1]=item end
                end
        end
        -- Only an in-process reload in the same server may restore a pending
        -- play. Disk/cross-server history never supplies active round state.
        if sameJob then
                local pending=descriptor(old.activeRoute)
                if pending and s.role=="WR" and s.phase~="Lobby" and s.phase~="Result"
                    and pending.roundKey==tostring(s.preSnapEnds or "current") then
                    activeRoute=pending;submitted=true;roundKey=pending.roundKey
                    finalSprintCommitted=old.finalSprintCommitted==true and pending.slowStem==true
                end
                if old.routeRoundKey==tostring(s.preSnapEnds or "current")
                    and type(old.routeWaypoint)=="number" and old.routeWaypoint==old.routeWaypoint
                    and old.routeWaypoint>=2 and old.routeWaypoint<math.huge then
                    routeWaypoint=math.floor(old.routeWaypoint)
                end
                local defending=defenseDescriptor(old.activeDefense)
                if defending and s.role=="DB" and not s.testing and (s.mode==nil or s.mode=="1v1")
                    and (s.phase=="Live" or s.phase=="RAC" or s.phase=="Run")
                    and defending.roundKey==tostring(s.preSnapEnds or "current") then activeDefense=defending end
        end
        memoryOpponent=key
        memoryOpponentId=id or memory and validId(memory.opponentUserId) and memory.opponentUserId or nil
        memorySavedAt=memory and memory.savedAt or now
        if not memory or memory.savedAt==nil
            or memory==previous and old and type(old.memorySaveError)=="string" then saveMemory() end
    end
    local function recordOutcome(result,success)
        if not activeRoute then return end
        local item=descriptor(activeRoute)
        activeRoute=nil
        finalSprintCommitted=false
        if not item then return end
        item.success=success;item.contested=result=="Swatted" or result=="Intercepted"
        if result=="Catch" and success then item.catchSuccess=true end
        item.result=result;item.time=world:GetServerTimeNow()
        recentRoutes[#recentRoutes+1]=item
        while #recentRoutes>6 do table.remove(recentRoutes,1) end
        saveMemory()
        log("routeOutcome",item)
    end
    local function defenseContext(s)
        return s.role=="DB" and (s.mode==nil or s.mode=="1v1") and not s.testing and s.alive~=false
    end
    local function observeDefenseThrow(s,data)
        if not enabled or not defenseContext(s) or not memoryOpponent
            or (s.phase~="Live" and s.phase~="Hike") then return end
        local arc=type(data.Arc)=="table" and data.Arc or s.arc
        local pass=(data.Pass=="Bullet" or data.Pass=="Floater") and data.Pass
            or (s.passType=="Bullet" or s.passType=="Floater") and s.passType or nil
        local launch=finite(data.LaunchAt) and data.LaunchAt or s.launchAt
        if type(arc)~="table"
            or typeof(arc.P0)~="Vector3" or typeof(arc.P1)~="Vector3"
            or not finite(arc.P0.X) or not finite(arc.P0.Y) or not finite(arc.P0.Z)
            or not finite(arc.P1.X) or not finite(arc.P1.Y) or not finite(arc.P1.Z)
            or not finite(arc.Flight) or arc.Flight<=0
            or not finite(arc.Apex) or arc.Apex<0 or not finite(launch) then return end
        if not pass then
            -- Native Throw packets can omit the pass label. Classify only an
            -- exact, unique match to the visible configured arc; unknown or
            -- ambiguous arcs must not manufacture defensive learning.
            for _,name in ipairs({"Bullet","Floater"}) do
                local definition=type(Config.Pass)=="table" and Config.Pass[name]
                if type(definition)=="table" and finite(definition.Flight) and finite(definition.Apex)
                    and arc.Flight==definition.Flight and arc.Apex==definition.Apex then
                    if pass then return end
                    pass=name
                end
            end
            if not pass then return end
        end
        local root,opponent=rootOf(player.Character),rootOf(s.opponent)
        if not root or not opponent or not finite(root.Position.Z) or not finite(opponent.Position.Z) then return end
        local playKey=jobId..":"..tostring(launch)
        if activeDefense and activeDefense.playKey==playKey then return end
        for _,item in ipairs(recentDefense) do if item.playKey==playKey then return end end
        local offset=typeof(s.offset)=="Vector3" and s.offset or Vector3.zero
        local los=finite(s.LOS) and s.LOS or Field.LOSZ
        local remaining=(Field.GoalZ+offset.Z-arc.P1.Z)/Field.YD
        local depth=(arc.P1.Z-offset.Z-los)/Field.YD
        activeDefense=defenseDescriptor({pass=pass,launchAt=launch,playKey=playKey,
            roundKey=tostring(s.preSnapEnds or "current"),
            depthAtThrow=(root.Position.Z-opponent.Position.Z)/Field.YD,
            targetDepthYards=depth,goalDistanceYards=remaining,
            deepEndzone=depth>=12 and remaining<=3 and arc.P1.Z<=Field.EndZ+offset.Z,
            time=world:GetServerTimeNow()})
    end
    local function recordDefense(result,opponentCaught)
        if not activeDefense then return end
        local item=defenseDescriptor(activeDefense);activeDefense=nil
        if not item then return end
        item.result=result;item.opponentCaught=opponentCaught==true;item.time=world:GetServerTimeNow()
        recentDefense[#recentDefense+1]=item
        while #recentDefense>6 do table.remove(recentDefense,1) end
        saveMemory()
        local profile=defenseProfile()
        log("defenseOutcome",{pass=item.pass,result=result,opponentCaught=item.opponentCaught,
            deepEndzone=item.deepEndzone,depthAtThrow=item.depthAtThrow,targetDepthYards=item.targetDepthYards,
            goalDistanceYards=item.goalDistanceYards,depthBiasYards=profile.depthBiasYards,
            samples=profile.samples,playKey=item.playKey})
    end
    local function enemyCaught(s,catcher)
        if catcher==player or catcher==player.Character then return false end
        if catcher~=nil then
            if catcher==s.opponent then return true end
            local ok,character=pcall(function() return catcher.Character end)
            if ok and character~=nil and character==s.opponent then return true end
            return false
        end
        return s.enemyCarrier==true and s.carrier==s.opponent
    end
    local function inputFor(s,root)
        local opponent=rootOf(s.enemyCarrier and s.carrier or s.opponent)
        local choice=selected or activeRoute
        return {LOS=s.LOS,offset=s.offset or Vector3.zero,position=root.Position,
            opponentPosition=opponent and opponent.Position,
            opponentVelocity=opponent and opponent.AssemblyLinearVelocity,
            stamina=tonumber(player:GetAttribute("Stamina")) or 0,
            sprintOn=player:GetAttribute("SprintOn")==true,
            role=s.role,phase=s.phase,mode=s.mode,ballActive=s.arc~=nil,passStarted=s.passStarted==true,
            carrierIsMe=s.carrier~=nil and s.carrier==player.Character,
            enemyCarrier=s.enemyCarrier==true,routePlan=routePlan,
            elapsed=s.snapAt and math.max(0,world:GetServerTimeNow()-s.snapAt) or nil,
            laneSide=laneSide,priorTarget=priorTarget,recentRoutes=recentRoutes,
            recentSelections=recentSelections,selectionIndex=selectionIndex,routeWaypoint=routeWaypoint,
            lastLateBendTrialTrigger=lastLateBendTrialTrigger,defenseProfile=defenseProfile(),
            middleStemDeep=choice and choice.middleStemDeep==true,
            slowStem=choice and choice.slowStem==true,slowStemTime=choice and choice.slowStemTime,
            finalSprintCommitted=finalSprintCommitted}
    end
    local function resetRound(key)
        local pending=activeRoute and activeRoute.roundKey==key and activeRoute or nil
        roundKey=key;submitted=pending~=nil;nextSubmit=0;submitTries=0
        observationStarted=world:GetServerTimeNow()
        activeRoute=pending
        if not pending then finalSprintCommitted=false end
        if not activeDefense or activeDefense.roundKey~=key then activeDefense=nil end
        routeWaypoint=2
        selected,routePlan,routeSource,planPass=nil,nil,nil,nil
        laneSide,priorTarget,lastKind=nil,nil,nil
        errorMessage=nil
    end
    local function setup()
        local s=ctx.snapshot()
        syncOpponent(s)
        if s.phase~=lastPhase then
            if s.phase=="PreSnap" then resetRound(tostring(s.preSnapEnds or "current")) end
            if s.phase=="Lobby" or s.phase=="Result" then
                laneSide,priorTarget,lastKind=nil,nil,nil
            end
            lastPhase=s.phase
        end
        local paused=pauseReason(s)
        if paused then message=paused;return end
        if s.phase=="Lobby" then message="Full auto · waiting for match";return end
        if s.phase=="Result" then message="Full auto · waiting for next round";return end
        if s.arc then message="Full auto · catch/intercept assist";return end
        if s.phase~="PreSnap" or s.role~="WR" then return end
        local key=tostring(s.preSnapEnds or "current")
        if key~=roundKey then resetRound(key) end
        if submitted then message="Full auto · route submitted";return end
        local now=world:GetServerTimeNow()
        if submitTries>=3 or now<nextSubmit then return end
        -- Do not submit over an already closed/manual-submitted board.
        if not board.IsOpen() then message="Full auto · waiting for route board";return end
        local remaining=type(s.preSnapEnds)=="number" and s.preSnapEnds-now or math.huge
        if now-(observationStarted or now)<1 and remaining>.5 then
            message="Full auto · reading defender position";return
        end
        local root=rootOf(player.Character)
        if not root then message="Full auto · waiting for character";return end
        submitTries=submitTries+1;nextSubmit=now+1
        local input=inputFor(s,root)
        local equipped=player:GetAttribute("EquippedRelease")
        if type(equipped)=="string" and equipped~="" and player:GetAttribute("Owned_"..equipped)==true then
            input.release=equipped
        end
        local chosen=Policy.chooseRoute(input,Config,Field,RouteMath)
        assert(chosen and chosen.payload and chosen.plan,"No legal route available")
        submit(chosen.payload)
        selected,routePlan=chosen,chosen.plan
        activeRoute=descriptor({pass=chosen.payload.Pass,side=chosen.side,depth=chosen.depth,
            shape=chosen.shape,family=chosen.family,signature=chosen.signature,
            roundKey=roundKey,time=now,arrival=chosen.plan.Arrival,cutCount=chosen.cutCount,lastCutAt=chosen.lastCutAt,
            experimentalAttempt=chosen.experimentalAttempt,trialTrigger=chosen.trialTrigger,
            experimentalClearanceGap=chosen.experimentalClearanceGap,middleStemDeep=chosen.middleStemDeep,
            stemYards=chosen.stemYards,cutLeadTime=chosen.cutLeadTime,finishMode=chosen.finishMode,
            estimatedFinishAt=chosen.estimatedFinishAt,estimatedFinishZ=chosen.estimatedFinishZ,
            finishReachable=chosen.finishReachable,finishDistance=chosen.finishDistance,
            finishTravelTime=chosen.finishTravelTime,finishReserve=chosen.finishReserve,
            finishFraction=chosen.finishFraction,routeStrategy=chosen.routeStrategy,
            slowStem=chosen.slowStem,slowStemTime=chosen.slowStemTime,cutAt=chosen.cutAt,
            slowStemStartupSlack=chosen.slowStemStartupSlack,
            startSprintAt=chosen.startSprintAt,forceDiveFinish=chosen.forceDiveFinish,
            requireDive=chosen.requireDive,finalSprint=chosen.finalSprint,slowStemSpeed=chosen.slowStemSpeed,
            finalSprintDuration=chosen.finalSprintDuration,finalSprintReserve=chosen.finalSprintReserve,
            finalSprintStamina=chosen.finalSprintStamina,sidelineInset=chosen.sidelineInset,
            sidelineFallback=chosen.sidelineFallback,sidelineFallbackReason=chosen.sidelineFallbackReason,
            diveWitnessElapsed=chosen.diveWitnessElapsed,diveWitnessX=chosen.diveWitnessX,
            diveWitnessZ=chosen.diveWitnessZ,diveWitnessMargin=chosen.diveWitnessMargin})
        if chosen.trialTrigger then lastLateBendTrialTrigger=chosen.trialTrigger end
        routeWaypoint=2
        recentSelections[#recentSelections+1]=descriptor(activeRoute)
        while #recentSelections>6 do table.remove(recentSelections,1) end
        selectionIndex=selectionIndex+1
        saveMemory()
        submitted=true;counters.routeRequests=counters.routeRequests+1
        -- Same close operation used when the normal route menu finishes.
        local closed,closeError=pcall(board.Close)
        errorMessage=not closed and tostring(closeError) or nil
        message="Full auto · "..chosen.payload.Pass.." route submitted"
        log("routeRequested",{pass=chosen.payload.Pass,startX=chosen.payload.StartX,
            points=#chosen.payload.Points,arrival=chosen.plan.Arrival,launch=chosen.plan.Launch,
            estimatedSeparation=chosen.estimatedSeparation,estimateOnly=true,
            shape=chosen.shape,depth=chosen.depth,family=chosen.family,signature=chosen.signature,
            adaptationPenalty=chosen.adaptationPenalty,recentFailureCount=chosen.recentFailureCount,
            repeatPenalty=chosen.repeatPenalty,mixBonus=chosen.mixBonus,baseScore=chosen.baseScore,
            selectionScore=chosen.selectionScore,qualityGap=chosen.qualityGap,selectionIndex=selectionIndex,
            cutCount=chosen.cutCount,lastCutAt=chosen.lastCutAt,cutBonus=chosen.cutBonus,
            experimentalAttempt=chosen.experimentalAttempt,trialTrigger=chosen.trialTrigger,
            experimentalClearanceGap=chosen.experimentalClearanceGap,
            middleStemDeep=chosen.middleStemDeep,stemYards=chosen.stemYards,cutLeadTime=chosen.cutLeadTime,
            finishMode=chosen.finishMode,estimatedFinishAt=chosen.estimatedFinishAt,
            estimatedFinishZ=chosen.estimatedFinishZ,finishReachable=chosen.finishReachable,
            finishDistance=chosen.finishDistance,finishTravelTime=chosen.finishTravelTime,
            finishReserve=chosen.finishReserve,finishFraction=chosen.finishFraction,routeStrategy=chosen.routeStrategy,
            slowStem=chosen.slowStem,slowStemTime=chosen.slowStemTime,cutAt=chosen.cutAt,
            slowStemStartupSlack=chosen.slowStemStartupSlack,
            startSprintAt=chosen.startSprintAt,requireDive=chosen.requireDive,
            slowStemSpeed=chosen.slowStemSpeed,finalSprintDuration=chosen.finalSprintDuration,
            finalSprintReserve=chosen.finalSprintReserve,finalSprintStamina=chosen.finalSprintStamina,
            sidelineInset=chosen.sidelineInset,sidelineFallback=chosen.sidelineFallback,
            sidelineFallbackReason=chosen.sidelineFallbackReason,
            diveWitnessElapsed=chosen.diveWitnessElapsed,diveWitnessX=chosen.diveWitnessX,
            diveWitnessZ=chosen.diveWitnessZ,diveWitnessMargin=chosen.diveWitnessMargin,
            hikeTime=chosen.hikeTime,setupDefenderReach=chosen.setupDefenderReach,
            estimatedCatchZ=chosen.estimatedCatchZ,estimatedCatchAt=chosen.estimatedCatchAt,
            estimatedRACDistance=chosen.estimatedRACDistance,estimatedCatchStamina=chosen.estimatedCatchStamina,
            uprightCatchReachable=chosen.uprightCatchReachable,
            nearGoalFloaterAvailable=chosen.nearGoalFloaterAvailable,
            insideGoalFloaterAvailable=chosen.insideGoalFloaterAvailable,
            goalCatchPreference=chosen.goalCatchPreference,goalReferenceScore=chosen.goalReferenceScore,
            goalClearanceToleranceUsed=chosen.goalClearanceToleranceUsed,
            pressureMode=chosen.pressureMode,eligibleRouteCount=chosen.eligibleRouteCount,
            defenderEnvelopeMargin=chosen.defenderEnvelopeMargin,
            bestDefenderEnvelopeMargin=chosen.bestDefenderEnvelopeMargin,
            position=coordinates(input.position),opponentPosition=coordinates(input.opponentPosition),
            opponentVelocity=coordinates(input.opponentVelocity),offset=coordinates(input.offset),
            LOS=input.LOS,stamina=input.stamina})
    end
    local accumulator=0
    local connection=run.Heartbeat:Connect(function(dt)
        accumulator=accumulator+dt
        if accumulator<.15 then return end
        accumulator=0
        local ok,err=pcall(setup)
        if not ok then errorMessage=tostring(err);message="Full auto · "..errorMessage end
    end)
    local function navigate(s,root,h,now,dt)
        if pauseReason(s) or not root or not h or h.PlatformStand then return nil end
        if s.route and #s.route>=2 and (routeSource~=s.route or planPass~=s.passType) then
            if routeSource~=nil then routeWaypoint=2 end
            routePlan=RouteMath.Plan(s.route,s.passType or selected and selected.payload.Pass or "Bullet")
            routeSource,planPass=s.route,s.passType
        end
        local input=inputFor(s,root);input.dt=dt
        if input.role=="WR" and input.carrierIsMe
            and (input.phase=="RAC" or input.phase=="Run") and lastKind~="carry" then
            -- Catch steering may finish far from the pre-throw route target.
            -- Start carry smoothing at the actual catch position, then retain
            -- only the subsequent carry targets and chosen escape side.
            input.priorTarget=root.Position
            input.laneSide=nil
        end
        local choice=Policy.movement(input,Config,Field,RouteMath)
        if not choice then return nil end
        if choice.routeWaypoint then routeWaypoint=choice.routeWaypoint end
        if choice.finalSprintCommitted==true then finalSprintCommitted=true end
        laneSide,priorTarget=choice.laneSide,choice.target
        local delta=(choice.target-root.Position)*Vector3.new(1,0,1)
        local distance=delta.Magnitude
        local moving=distance>(choice.stopDistance or .8)
        local direction=moving and delta.Unit or Vector3.zero
        if moving then
            -- Native movement only; taper close to a target at low frame rates.
            direction=direction*math.min(1,distance/math.max(1,h.WalkSpeed*math.max(dt,.016)))
            if type(choice.moveSpeed)=="number" then
                -- Account for native sprint on/off replication delay without
                -- changing WalkSpeed or moving faster than the current speed.
                direction=direction*math.min(1,math.max(0,choice.moveSpeed)/math.max(1,h.WalkSpeed))
            elseif type(choice.moveScale)=="number" then
                direction=direction*math.max(0,math.min(1,choice.moveScale))
            end
        end
        message="Full auto · "..choice.kind
        local sampleInterval=.2
        if lastKind~=choice.kind or choice.routeWaypoint~=lastLoggedWaypoint or now-lastSample>=sampleInterval then
            lastKind,lastSample=choice.kind,now
            lastLoggedWaypoint=choice.routeWaypoint
            local opponent,velocity=input.opponentPosition,input.opponentVelocity
            local localVelocity=root.AssemblyLinearVelocity
            log("navigate",{action=choice.kind,phase=s.phase,role=s.role,elapsed=input.elapsed,
                x=root.Position.X,z=root.Position.Z,targetX=choice.target.X,targetZ=choice.target.Z,
                velocityX=localVelocity and localVelocity.X,velocityZ=localVelocity and localVelocity.Z,
                directionX=direction.X,directionZ=direction.Z,
                sprintOn=input.sprintOn,requestedSprint=moving and choice.sprint==true,
                opponentX=opponent and opponent.X,opponentZ=opponent and opponent.Z,
                opponentVelocityX=velocity and velocity.X,opponentVelocityZ=velocity and velocity.Z,
                opponentDistance=opponent and ((opponent-root.Position)*Vector3.new(1,0,1)).Magnitude,
                stamina=input.stamina,laneSide=laneSide,speed=h.WalkSpeed,moving=moving,
                routeWaypoint=choice.routeWaypoint,defenseDepthBiasYards=input.defenseProfile.depthBiasYards,
                defenseSamples=input.defenseProfile.samples,routeMoveSpeed=choice.moveSpeed,
                routeDeadline=choice.routeDeadline,finalSprintCommitted=finalSprintCommitted})
        end
        return {direction=direction,sprint=moving and choice.sprint==true,message=message,
            preserveDepth=choice.kind=="shadow"}
    end
    function api.navigate(s,root,h,now,dt)
        local ok,result=pcall(navigate,s,root,h,now,dt)
        if not ok then
            navigationError=tostring(result)
            errorMessage=navigationError
            message="Full auto navigation paused"
            return nil
        end
        if navigationError then
            if errorMessage==navigationError then errorMessage=nil end
            navigationError=nil
        end
        return result
    end
    function api.setEnabled(value)
        enabled=value==true
        errorMessage=nil
        laneSide,priorTarget,lastKind=nil,nil,nil
        if not enabled then finalSprintCommitted=false end
        if not enabled and ctx.release then ctx.release() end
        message=enabled and "Full auto · ready" or "Full auto off"
        if type(write)=="function" then
            local ok,err=pcall(function() write(settingsFile,http:JSONEncode({version=1,enabled=enabled})) end)
            saveError=not ok and tostring(err) or nil
        else saveError="Saving full auto setting is unavailable" end
        log("enabled",{enabled=enabled})
        return true,saveError
    end
    function api.onMatch(data)
        if not alive or type(data)~="table" then return end
        local s=ctx.snapshot();syncOpponent(s)
        if defenseContext(s) then
            if data.Phase=="Result" and data.Result=="Touchdown"
                and (data.Point=="Opp" or data.Point=="Them" or data.ScorerIsYou==false) then
                recordDefense("Touchdown",true)
            elseif data.Phase=="Result" and (data.Result=="Swatted" or data.Result=="Intercepted"
                or data.Result=="Incomplete") then recordDefense(data.Result,false)
            elseif (data.Phase=="RAC" or data.Phase=="Run") and enemyCaught(s,data.Carrier) then
                recordDefense("Catch",true)
            end
        end
        if data.Phase=="PreSnap" or data.Phase=="Pick" or data.Phase=="Lobby" then activeDefense=nil end
        if activeRoute and s.role=="WR" and data.Phase=="Result" then
            -- Fallback when the server's terminal round packet arrives without
            -- the matching BallResult. A later duplicate cannot add twice.
            if data.Result=="Swatted" or data.Result=="Intercepted" or data.Result=="Incomplete" then
                recordOutcome(data.Result,false)
            elseif data.Result=="Touchdown" and (data.Point=="You" or data.ScorerIsYou==true) then
                recordOutcome("Catch",true)
            end
        end
        if s.role=="WR" and (s.mode==nil or s.mode=="1v1") and not s.testing and data.Phase=="Result"
            and data.Result=="Tackled" then
            local key=tostring(s.preSnapEnds or roundKey or "current")
            -- The offense objective is a touchdown on this down. Any own-WR
            -- tackle misses it, even when the first down awards no point.
            -- Preserve possession evidence and revise one same-round record.
            if activeRoute and activeRoute.roundKey==key then recordOutcome("Catch",true) end
            for i=#recentRoutes,1,-1 do
                local item=recentRoutes[i]
                if item.roundKey==key and (item.catchSuccess==true or item.result=="Catch" and item.success) then
                    if item.terminalResult~="Tackled" or item.success~=false then
                        item.catchSuccess=true;item.success=false
                        item.terminalResult="Tackled";item.terminalAt=world:GetServerTimeNow()
                        saveMemory()
                        log("routeOutcomeUpdated",descriptor(item))
                    end
                    break
                end
            end
        end
        if data.Phase=="Hike" then counters.rounds=counters.rounds+1 end
        if enabled and data.Phase=="Result" then
            if data.Point=="You" or data.ScorerIsYou==true then counters.pointsWon=counters.pointsWon+1
            elseif data.Point=="Them" or data.Point=="Opp" or data.ScorerIsYou==false then counters.pointsLost=counters.pointsLost+1 end
            log("result",{result=data.Result,point=data.Point,matchOver=data.MatchOver,
                scorerIsYou=data.ScorerIsYou})
        end
    end
    function api.onFx(data)
        if not alive or type(data)~="table" or (data.Type~="BallResult" and data.Type~="Throw") then return end
        local s=ctx.snapshot();syncOpponent(s)
        if data.Type=="Throw" then observeDefenseThrow(s,data);return end
        if defenseContext(s) then
            if data.Result=="Catch" and enemyCaught(s,data.Catcher) then recordDefense("Catch",true)
            elseif data.Result=="Swatted" or data.Result=="Intercepted" or data.Result=="Incomplete" then
                recordDefense(data.Result,false)
            end
        end
        if not activeRoute or s.role~="WR" or s.mode=="Team" or s.testing then return end
        local result=data.Result
        if result=="Catch" then
            local mine=data.Catcher==nil or data.Catcher==player or data.Catcher==player.Character
            recordOutcome(result,mine)
        elseif result=="Swatted" or result=="Intercepted" or result=="Incomplete" then
            recordOutcome(result,false)
        end
    end
    function api.status()
        syncOpponent(ctx.snapshot())
        return {enabled=enabled,message=message,error=errorMessage,saveError=saveError,memorySaveError=memorySaveError,
            supportedMode="1v1",submitted=submitted,
            pass=selected and selected.payload.Pass or nil,counters=table.clone(counters),
            routeMemory=learningRecord(),
            defenseProfile=defenseProfile(),activeDefense=defenseDescriptor(activeDefense),
            finalSprintCommitted=finalSprintCommitted,
            routeWaypoint=routeWaypoint,routeRoundKey=tostring(ctx.snapshot().preSnapEnds or "current"),
            activeRoute=descriptor(activeRoute)}
    end
    function api.catchIntent()
        -- Core context calls this; never recurse through ctx.snapshot/status.
        local choice=selected or activeRoute
        if not alive or not enabled or not submitted or not activeRoute or not choice then return nil end
        local point=routePlan and type(routePlan.Points)=="table" and routePlan.Points[routeWaypoint]
        if typeof(point)~="Vector2" or not finite(point.X) or not finite(point.Y) then point=nil end
        return {deepFinish=choice.middleStemDeep==true,side=choice.side,waypoint=point,goalZ=Field.GoalZ,endZ=Field.EndZ,
            requireDive=true,
            continuousSprint=finalSprintCommitted,finalSprint=finalSprintCommitted}
    end
    function api.movementBudget()
        if not alive or not enabled then return nil end
        return {dbReserve=40,wrReserve=10}
    end
    function api.unload()
        if not alive then return end
        alive=false;connection:Disconnect()
        if ctx.release then ctx.release() end
    end
    return api
end
