-- Native WR juke requests after confirmed possession. Geometry is an estimate;
-- only the game decides whether a move is accepted and avoids a tackle.
return function(runtime)
    local Config,Field,Moves=runtime.Config,runtime.Field,runtime.Moves
    local player=runtime.player
    local FLAT=Vector3.new(1,0,1)
    local alive,active,nextAttempt=true,nil,0
    local attempts,observedBursts,lastOutcome,lastError=0,0,nil,nil
    local function finite(n) return type(n)=="number" and n==n and math.abs(n)<math.huge end
    local function vector(v)
        return typeof(v)=="Vector3" and finite(v.X) and finite(v.Y) and finite(v.Z)
    end
    local function flat(v) return v*FLAT end
    local function xyz(v) return {x=v.X,y=v.Y,z=v.Z} end
    local function log(kind,data)
        if type(runtime.log)=="function" then pcall(runtime.log,kind,data) end
    end
    local function namedUpvalue(fn,name)
        local getUps=(debug and debug.getupvalues) or getupvalues
        if type(fn)~="function" or type(getUps)~="function" then return nil end
        local ok,values=pcall(getUps,fn)
        if not ok or type(values)~="table" then return nil end
        for _,value in pairs(values) do
            if type(value)=="function" and debug and type(debug.info)=="function" then
                local good,actual=pcall(debug.info,value,"n")
                if good and actual==name then return value end
            end
        end
    end
    local nativeJuke=runtime.nativeJuke or namedUpvalue(Moves and Moves.SetPhase,"juke")
    local function bounds(input)
        local g=input.geo
        local offset=vector(input.offset) and input.offset or Vector3.zero
        local b={minX=g and g.MinX or Field.MinX+offset.X,
            maxX=g and g.MaxX or Field.MaxX+offset.X,
            minZ=g and g.BackZ or Field.BackZ+offset.Z,
            maxZ=g and g.EndZ or Field.EndZ+offset.Z}
        if not finite(b.minX) or not finite(b.maxX) or not finite(b.minZ) or not finite(b.maxZ)
            or b.minX>=b.maxX or b.minZ>=b.maxZ then return nil end
        return b
    end
    local function room(p,b)
        return math.min(p.X-b.minX,b.maxX-p.X,p.Z-b.minZ,b.maxZ-p.Z)
    end
    local function decide(input)
        if type(input)~="table" or input.role~="WR" or input.phase~="RAC"
            or input.mode~=nil and input.mode~="1v1" or input.carrierIsMe~=true or input.upright~=true
            or input.grounded~=true or input.healthy~=true or input.enemyCarrier==true
            or input.ballActive or input.testing or input.enabled==false
            or not finite(input.now) or input.now<(input.nextAttempt or 0)
            or not vector(input.position) or not vector(input.velocity)
            or not vector(input.rightDirection) or not vector(input.opponentPosition)
            or not vector(input.opponentVelocity) then return nil end
        local juke=Config.Moves and Config.Moves.Juke
        if type(juke)~="table" or not finite(juke.Cost) or not finite(juke.Speed)
            or not finite(juke.Time) or not finite(juke.Cooldown)
            or juke.Speed<=0 or juke.Time<=0 or juke.Cooldown<=0 then return nil end
        -- Retain a small sprint reserve instead of spending the final stamina.
        if not finite(input.stamina) or input.stamina<juke.Cost+10 then return nil end
        local ownVelocity,enemyVelocity=flat(input.velocity),flat(input.opponentVelocity)
        if ownVelocity.Magnitude>Config.SprintSpeed*1.5 then return nil end
        if enemyVelocity.Magnitude>80 then enemyVelocity=enemyVelocity.Unit*80 end
        local right=flat(input.rightDirection)
        if right.Magnitude<.9 or right.Magnitude>1.01 then return nil end
        local delta=flat(input.opponentPosition-input.position)
        local distance=delta.Magnitude
        if distance<2 or distance>18 or math.abs(input.opponentPosition.Y-input.position.Y)>4 then return nil end
        local relative=enemyVelocity-ownVelocity
        local closing=-relative:Dot(delta.Unit)
        if closing<6 then return nil end
        local tackle=Config.Tackle or {}
        local contactRange=(tackle.GrabRange or 3.5)+math.min(tackle.GrabSlack or 2,2)
        local contactIn=math.max(0,distance-contactRange)/closing
        if contactIn>.45 then return nil end
        local closestTime=math.max(0,math.min(.5,-delta:Dot(relative)/math.max(.001,relative:Dot(relative))))
        if (delta+relative*closestTime).Magnitude>contactRange+1 then return nil end
        local b=bounds(input)
        if not b then return nil end
        local pad=math.max(1.5,(Field.YD or 3)*.4)
        if room(input.position,b)<pad then return nil end
        local best,bestScore
        for _,sign in ipairs({-1,1}) do
            -- This is the native Juke expression, used only to reject unsafe
            -- paths. The native function alone applies the actual movement.
            local burstVelocity=right*(sign*juke.Speed)+ownVelocity*.6000000238418579
            local displacement=burstVelocity*juke.Time
            local endpoint=input.position+displacement
            local paddedEnd=input.position+burstVelocity*(juke.Time+.04)
            local clear=room(paddedEnd,b)>=pad and endpoint.Z>=input.position.Z-2
            if clear and type(input.clipDistance)=="function" and displacement.Magnitude>.001 then
                local ok,available=pcall(input.clipDistance,input.position,displacement.Unit,
                    burstVelocity.Magnitude*(juke.Time+.04))
                clear=ok and finite(available) and available>=burstVelocity.Magnitude*(juke.Time+.04)-.01
            end
            if clear then
                local minimum=math.huge
                for step=1,6 do
                    local t=juke.Time*step/6
                    minimum=math.min(minimum,(delta+(enemyVelocity-burstVelocity)*t).Magnitude)
                end
                local endSeparation=flat(input.opponentPosition+enemyVelocity*juke.Time-endpoint).Magnitude
                local normalSeparation=(delta+relative*juke.Time).Magnitude
                if minimum>contactRange+.25 and endSeparation>normalSeparation+1 then
                    local score=minimum*2+endSeparation*.4+(endpoint.Z-input.position.Z)*.15+room(paddedEnd,b)*.03
                    if not best or score>bestScore then
                        bestScore=score
                        best={action="juke",sign=sign,duration=juke.Time,cooldown=juke.Cooldown,
                            endpoint=endpoint,direction=displacement.Unit,distance=distance,closing=closing,
                            contactIn=contactIn,minClearance=minimum,estimatedSeparation=endSeparation}
                    end
                end
            end
        end
        return best
    end
    local function burstOf(root)
        if not root or type(root.FindFirstChild)~="function" then return nil end
        local ok,burst=pcall(root.FindFirstChild,root,"Burst")
        return ok and burst or nil
    end
    local function cancel() active=nil end
    local function eligible(s,root,h)
        return alive and type(s)=="table" and s.enabled~=false and not s.testing and not s.arc
            and (s.mode==nil or s.mode=="1v1") and s.role=="WR" and s.phase=="RAC"
            and player and player.Character and s.carrier==player.Character
            and s.enemyCarrier~=true and root and h and h.Health>0 and not h.PlatformStand
    end
    local api={decide=decide,cancel=cancel}
    local function update(s,root,h,now)
        if not finite(now) or not eligible(s,root,h) then cancel();return false end
        if active then
            if active.root==root and now<active.expires and burstOf(root)==active.marker then
                return true,active.message
            end
            log("carrierMoveEnd",{action="juke",age=now-active.started,
                staminaBefore=active.staminaBefore,staminaAfter=tonumber(player:GetAttribute("Stamina")),
                reason=now>=active.expires and "duration" or "burstEnded"})
            active=nil
        end
        if now<nextAttempt or type(nativeJuke)~="function" or burstOf(root)
            or h.FloorMaterial==Enum.Material.Air or h.WalkSpeed<=0 then return false end
        if not Moves or type(Moves.Upright)~="function" or Moves.Upright()~=true then return false end
        local opponent=s.opponent
        if not opponent or opponent==player.Character then return false end
        local otherRoot=opponent:FindFirstChild("HumanoidRootPart")
        local otherHum=opponent:FindFirstChildOfClass("Humanoid")
        if not otherRoot or not otherHum or otherHum.Health<=0 then return false end
        -- Native DivePath sets PlatformStand while DB/RAC dive tackles remain
        -- active. A moving diver is a threat; only ignore a downed defender
        -- who is effectively stationary. Closing/path checks still apply.
        if otherHum.PlatformStand and flat(otherRoot.AssemblyLinearVelocity).Magnitude<6 then return false end
        local staminaBefore=tonumber(player:GetAttribute("Stamina"))
        local choice=decide({role=s.role,phase=s.phase,mode=s.mode or "1v1",carrierIsMe=true,upright=true,
            grounded=true,healthy=true,now=now,nextAttempt=nextAttempt,position=root.Position,
            velocity=root.AssemblyLinearVelocity,rightDirection=root.CFrame.RightVector,
            opponentPosition=otherRoot.Position,opponentVelocity=otherRoot.AssemblyLinearVelocity,
            stamina=staminaBefore,geo=s.geo,offset=s.offset,
            clipDistance=runtime.clippedDistance})
        if not choice then return false end
        attempts=attempts+1
        -- Even a rejected native request is rate limited. Never call can() as
        -- a probe: it consumes the game's own cooldown before the real action.
        nextAttempt=now+choice.cooldown+.1
        local ok,err=pcall(nativeJuke,choice.sign)
        local marker=ok and burstOf(root) or nil
        lastOutcome=not ok and "error" or marker and "burstObserved" or "unconfirmed"
        lastError=not ok and tostring(err) or nil
        log("carrierMove",{action="juke",sign=choice.sign,outcome=lastOutcome,error=lastError,
            position=xyz(root.Position),opponentPosition=xyz(otherRoot.Position),
            velocity=xyz(root.AssemblyLinearVelocity),opponentVelocity=xyz(otherRoot.AssemblyLinearVelocity),
            opponentPlatformStand=otherHum.PlatformStand==true,
            distance=choice.distance,closing=choice.closing,contactIn=choice.contactIn,
            minClearance=choice.minClearance,estimatedSeparation=choice.estimatedSeparation,
            stamina=staminaBefore,staminaBefore=staminaBefore,
            staminaAfter=tonumber(player:GetAttribute("Stamina")),staminaAfterImmediate=true,estimateOnly=true})
        if not marker then return false end
        observedBursts=observedBursts+1
        active={root=root,marker=marker,started=now,staminaBefore=staminaBefore,expires=now+choice.duration+.04,
            message="Full auto · juke "..(choice.sign<0 and "left" or "right")}
        return true,active.message
    end
    function api.update(s,root,h,now)
        local ok,taken,message=pcall(update,s,root,h,now)
        if not ok then
            active=nil;lastError=tostring(taken);lastOutcome="error"
            if finite(now) then nextAttempt=math.max(nextAttempt,now+1) end
            log("carrierMoveError",{error=lastError})
            return false
        end
        return taken,message
    end
    function api.status()
        return {available=type(nativeJuke)=="function",active=active~=nil,attempts=attempts,
            observedBursts=observedBursts,lastOutcome=lastOutcome,error=lastError,nextAttempt=nextAttempt}
    end
    function api.unload() alive=false;cancel() end
    return api
end
