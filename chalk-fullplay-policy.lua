-- Pure 1v1 decisions. Every opponent forecast uses observed position/velocity;
-- scores are heuristics, never claims about an opponent's hidden selected route.
local Policy={}
local FLAT=Vector3.new(1,0,1)
local INF=math.huge
local function finite(n) return type(n)=="number" and n==n and math.abs(n)<INF end
local function vec(v) return typeof(v)=="Vector3" and finite(v.X) and finite(v.Y) and finite(v.Z) end
local function clamp(n,a,b) return math.max(a,math.min(b,n)) end
local function flatDistance(a,b) return ((a-b)*FLAT).Magnitude end
local function offsetOf(input) return vec(input.offset) and input.offset or Vector3.zero end
local function boundedVelocity(v,maxSpeed)
    if not vec(v) then return Vector3.zero end
    v=v*FLAT
    return v.Magnitude>maxSpeed and v.Unit*maxSpeed or v
end
local function projectedOpponent(input,Config,seconds)
    if not vec(input.opponentPosition) then return nil end
    return input.opponentPosition+boundedVelocity(input.opponentVelocity,Config.SprintSpeed)*math.min(seconds,.25)
end
local function worldPoint(p,offset,y) return Vector3.new(p.X+offset.X,y,p.Y+offset.Z) end
local function validField(Field)
    return type(Field)=="table" and finite(Field.MinX) and finite(Field.MaxX)
        and finite(Field.BackZ) and finite(Field.EndZ) and finite(Field.GoalZ)
        and finite(Field.LOSZ) and finite(Field.YD) and Field.YD>0
        and Field.MinX<Field.MaxX and Field.BackZ<Field.EndZ
end
local function worldBounds(Field,offset,margin)
    local minX,maxX=Field.MinX+offset.X+margin,Field.MaxX+offset.X-margin
    local minZ,maxZ=Field.BackZ+offset.Z+margin,Field.EndZ+offset.Z-margin
    return minX,maxX,minZ,maxZ
end
local function clampWorld(point,Field,offset,margin,y)
    local minX,maxX,minZ,maxZ=worldBounds(Field,offset,margin)
    return Vector3.new(clamp(point.X,minX,maxX),y,clamp(point.Z,minZ,maxZ))
end
local function travelTime(distance,Config,stamina)
    local run=math.max(1,Config.RunSpeed)
    local sprint=math.max(run,Config.SprintSpeed)
    local seconds=math.max(0,stamina)/(math.max(.01,Config.SprintDrain))
    local sprintDistance=sprint*seconds
    return math.min(distance,sprintDistance)/sprint+math.max(0,distance-sprintDistance)/run
end
local function uprightFloaterWindow(plan,los,receiverDistance,Config,Field,stamina)
    if plan.Pass~="Floater" then return nil end
    local height=3+(Config.HandUpOffset or 3.5)+(Config.JumpHeight or 6)
        +(Config.CatchRadius or 3.75)-.4
    local low,high=.5,1
    for _=1,24 do
        local u=(low+high)*.5
        local y=Config.ReleaseHeight+(Config.CatchHeight-Config.ReleaseHeight)*u+4*plan.Apex*u*(1-u)
        if y>height then low=u else high=u end
    end
    local origin=Vector2.new((Field.MinX+Field.MaxX)*.5,los-Config.QBBackYards*Field.YD)
    local point=origin:Lerp(plan.Target,high)
    -- Approximate distance already covered along the submitted route. The
    -- final ball-to-target segment is not distance the receiver must still run.
    local distance=math.max(0,receiverDistance-(plan.Target-point).Magnitude)
    local at=plan.Launch+plan.Flight*high
    local remainingStamina=math.max(0,stamina-math.min(distance/Config.SprintSpeed,
        stamina/math.max(.01,Config.SprintDrain))*Config.SprintDrain)
    -- Eligibility uses the entire native path plus lead, not the shorter
    -- distance estimate used only for the remaining-stamina diagnostic.
    return {point=point,at=at,reachable=travelTime(receiverDistance,Config,stamina)<=at+.05,
        remaining=math.max(0,Field.GoalZ-point.Y),stamina=remainingStamina}
end
local function routeKeys(pass,shape,depth,side)
    local family=pass..":"..shape..":"..tostring(math.floor(depth+.5))
    return family,family..":"..tostring(side)
end
local function adaptation(input,pass,shape,depth,side,arrival)
    local history=type(input.recentRoutes)=="table" and input.recentRoutes or {}
    local family,signature=routeKeys(pass,shape,depth,side)
    local penalty,failures=0,0
    -- Only the latest outcome for a family applies: a later successful catch
    -- clears an earlier failure of that family. Mirroring never clears it.
    local seen={}
    for i=#history,math.max(1,#history-5),-1 do
        local old=history[i]
        if type(old)=="table" and (old.pass=="Bullet" or old.pass=="Floater")
            and type(old.shape)=="string" and finite(old.depth) then
            local oldFamily=routeKeys(old.pass,old.shape,old.depth,old.side or 1)
            if not seen[oldFamily] then
                seen[oldFamily]=true
                local weight=.85^(#history-i)
                if old.success==false then
                    failures=failures+1
                    if oldFamily==family then penalty=penalty+36*weight end
                    if old.signature==signature then penalty=penalty+5*weight end
                    -- A nearby defender beat the old long descending window.
                    -- Prefer trying a different flight/shape, rather than the
                    -- identical long floater on the opposite sideline.
                    if old.pass=="Floater" and old.depth>=16
                        and pass=="Floater" and arrival>=4 then
                        penalty=penalty+8*weight
                    end
                elseif old.success==true and oldFamily==family then
                    penalty=penalty-2*weight
                end
            end
        end
    end
    return penalty,failures,family,signature
end
local function repetition(input,candidate)
    local history=type(input.recentSelections)=="table" and input.recentSelections
        or type(input.recentRoutes)=="table" and input.recentRoutes or {}
    local penalty,straightRecent=0,0
    for i=#history,math.max(1,#history-5),-1 do
        local old=history[i]
        if type(old)=="table" and (old.pass=="Bullet" or old.pass=="Floater")
            and type(old.shape)=="string" and finite(old.depth) then
            local family,signature=routeKeys(old.pass,old.shape,old.depth,old.side or 1)
            local weight=.65^(#history-i)
            if old.cutCount==0 or old.cutCount==nil and (old.shape=="go" or old.shape=="slant") then
                straightRecent=straightRecent+weight
            end
            penalty=penalty+weight*((family==candidate.family and 2.6 or 0)
                +(signature==candidate.signature and 1.4 or 0)
                +(math.abs(old.depth-candidate.depth)<1 and 1.5 or 0)
                +(old.shape==candidate.shape and .6 or 0)
                +(old.pass==candidate.payload.Pass and .25 or 0)
                +(old.side==candidate.side and .3 or 0))
        end
    end
    -- A small, reproducible tie-break varies equivalent choices. Selection is
    -- still limited to reachable routes near the best observed quality below.
    local sequence=finite(input.selectionIndex) and math.max(0,math.floor(input.selectionIndex)) or #history
    local hash=sequence*37
    for i=1,#candidate.signature do hash=(hash*17+string.byte(candidate.signature,i))%101 end
    local cutBonus=(candidate.cutCount or 0)>0 and 1.25+math.min(1.5,straightRecent) or 0
    return math.min(8.5,penalty),#history>0 and hash/100*.35 or 0,cutBonus
end
local function lateBendTrigger(input)
    local history=type(input.recentRoutes)=="table" and input.recentRoutes or {}
    local failures={}
    for i=#history,math.max(1,#history-5),-1 do
        local old=history[i]
        if type(old)=="table" then
            if old.shape=="late_bend" or old.experimentalAttempt=="late-bend" then break end
            local straight=old.pass=="Floater" and (old.cutCount==0
                or old.cutCount==nil and (old.shape=="go" or old.shape=="slant"))
            if straight and old.success==true then break end
            if straight and old.success==false
                and (old.result=="Swatted" or old.result=="Intercepted") then
                failures[#failures+1]=tostring(old.roundKey or old.time or i)..":"
                    ..tostring(old.signature or old.family or old.shape)..":"..old.result
                if #failures==2 then break end
            end
        end
    end
    if #failures<2 then return nil end
    local token=failures[2].."|"..failures[1]
    local function consumedFailure(previous)
        if type(previous)~="string" then return false end
        local marked="|"..previous.."|"
        return marked:find("|"..failures[1].."|",1,true)
            or marked:find("|"..failures[2].."|",1,true)
    end
    -- Missing result packets must not recycle one of the two failures that
    -- already bought a trial. Both qualifying failures must be fresh.
    if consumedFailure(input.lastLateBendTrialTrigger) then return nil end
    for _,old in ipairs(type(input.recentSelections)=="table" and input.recentSelections or {}) do
        if consumedFailure(old.trialTrigger) then return nil end
    end
    return token
end

-- input: LOS (field coordinates), world position/opponentPosition, offset,
-- opponentVelocity, stamina, release (already checked owned by the caller).
-- result.payload exactly matches the native RouteBoard submission schema.
function Policy.chooseRoute(input,Config,Field,RouteMath)
    input=input or {}
    if not validField(Field) then return nil,"Invalid 1v1 field" end
    if type(RouteMath)~="table" or type(RouteMath.Sanitize)~="function"
        or type(RouteMath.Plan)~="function" then return nil,"Route math unavailable" end
    if input.mode=="Team" then return nil,"1v1 route policy only" end
    local offset=offsetOf(input)
    local yd=Field.YD
    local los=finite(input.LOS) and input.LOS or Field.LOSZ
    los=clamp(los,Field.BackZ+1,Field.GoalZ-yd)
    local edge=math.max(Config.RouteEdgeMargin or 1,1.5)
    local startMargin=Config.SidelineMarginYards*yd
    local minStart,maxStart=Field.MinX+startMargin,Field.MaxX-startMargin
    local mid=(Field.MinX+Field.MaxX)*.5
    local opponent=projectedOpponent(input,Config,.2)
    local opponentX=opponent and opponent.X-offset.X or mid
    local favored=opponentX>=mid and -1 or 1
    local stamina=finite(input.stamina) and input.stamina or Config.Stamina
    local hikeTime=math.max(0,tonumber(Config.HikeTime) or 0)
    local setupReach=hikeTime*math.max(0,tonumber(Config.PreSnapDBSpeed) or 0)
    local floaterMinimum=math.min(16,math.max(0,(Field.EndZ-edge-los)/yd))
    local trialTrigger=lateBendTrigger(input)
    local shapes={"go","bend","slant","corner","cross","double"}
    if trialTrigger then shapes[#shapes+1]="late_bend" end
    local best,candidates,trialCandidates=nil,{},{}
    for _,side in ipairs({favored,-favored}) do
        local startX=side<0 and minStart or maxStart
        local outside=side<0 and Field.MinX+edge+yd or Field.MaxX-edge-yd
        for _,depth in ipairs({16,18,20,22,23,24,27}) do
            local z=math.min(los+depth*yd,Field.EndZ-edge)
            if z>los+yd then
                for shape,shapeName in ipairs(shapes) do
                    local raw={Vector2.new(startX,los)}
                    if shape==2 then
                        -- One shallow inside break, then return to the outside.
                        raw[#raw+1]=Vector2.new(clamp(startX-side*3*yd,minStart,maxStart),
                            math.min(z-yd,los+5*yd))
                    end
                    local endpointX=outside
                    if shape==3 then
                        -- A legal inside slant offers a quicker Bullet flight;
                        -- the pass constraints below retain the requested depth.
                        endpointX=clamp(startX-side*math.min(7,depth*.5)*yd,
                            Field.MinX+edge,Field.MaxX-edge)
                    elseif shape==4 then
                        -- Step inside first, then make an actual outside turn.
                        -- The early lateral leg can complete before short throws.
                        raw[#raw+1]=Vector2.new(startX-side*.6*yd,los)
                    elseif shape==5 then
                        raw[#raw+1]=Vector2.new(startX,los+.8*yd)
                        raw[#raw+1]=Vector2.new(startX-side*3*yd,los+1.5*yd)
                        endpointX=clamp(startX-side*math.min(9,depth*.6)*yd,
                            Field.MinX+edge,Field.MaxX-edge)
                    elseif shape==6 then
                        raw[#raw+1]=Vector2.new(startX-side*1.2*yd,los+.6*yd)
                        raw[#raw+1]=Vector2.new(startX+side*.3*yd,los+1.5*yd)
                        endpointX=clamp(startX-side*math.min(4,depth*.5)*yd,
                            Field.MinX+edge,Field.MaxX-edge)
                    elseif shape==7 then
                        -- A bounded trial moves the existing inside break later;
                        -- it does not assume the defender follows that first leg.
                        raw[#raw+1]=Vector2.new(clamp(startX-side*3*yd,minStart,maxStart),
                            math.min(z-yd,los+11*yd))
                    end
                    raw[#raw+1]=Vector2.new(endpointX,z)
                    local points=RouteMath.Sanitize(raw,startX,los)
                    local length=RouteMath.Length(points)
                    local actualDepth=(points[#points].Y-los)/yd
                    for _,pass in ipairs({"Bullet","Floater"}) do
                        local plan=RouteMath.Plan(points,pass)
                        local arrival=plan.Arrival
                        local cutCount,lastCutAt=0,nil
                        for index=2,#points-1 do
                            local incoming=points[index]-points[index-1]
                            local outgoing=points[index+1]-points[index]
                            local turn=math.deg(math.acos(clamp(incoming.Unit:Dot(outgoing.Unit),-1,1)))
                            if turn>=20 and plan.Times[index]+.12<=plan.Launch then
                                cutCount=cutCount+1;lastCutAt=plan.Times[index]
                            end
                        end
                        local receiverDistance=length+(plan.LeadTime or 0)*Config.FillSpeed
                        local ownTime=travelTime(receiverDistance,Config,stamina)
                        local reachable=ownTime<=arrival+.05
                        local catchWindow=uprightFloaterWindow(plan,los,receiverDistance,Config,Field,stamina)
                        local target=worldPoint(plan.Target,offset,0)
                        local endpointDistance=opponent and flatDistance(target,opponent) or 0
                        local worstMargin=0
                        if opponent then
                            worstMargin=INF
                            local p0=Vector3.new(mid+offset.X,Config.ReleaseHeight,
                                los-Config.QBBackYards*yd+offset.Z)
                            local p1=Vector3.new(target.X,Config.CatchHeight,target.Z)
                            -- Conservative envelope, sampled only where a normal
                            -- jump could reach the ball. This is not a prediction
                            -- of a defender committing to a particular direction.
                            local jumpReach=3+(Config.HandUpOffset or 3.5)
                                +(Config.JumpHeight or 6)+(Config.CatchRadius or 3.75)
                            for sample=1,10 do
                                local u=sample/10
                                local at=p0:Lerp(p1,u)+Vector3.new(0,4*plan.Apex*u*(1-u),0)
                                if at.Y<=jumpReach then
                                    local elapsed=plan.Launch+plan.Flight*u
                                    local reach=setupReach+Config.SprintSpeed*math.max(0,elapsed-.15)
                                        +(Config.CatchRadius or 3.75)
                                    worstMargin=math.min(worstMargin,flatDistance(at,opponent)-reach)
                                end
                            end
                            if worstMargin==INF then worstMargin=0 end
                        end
                        local progress=(math.min(plan.Target.Y,Field.GoalZ+yd)-los)/yd
                        local score=progress+clamp(worstMargin/yd,-20,10)*1.7
                            +clamp(endpointDistance/yd,0,30)*.15
                            -plan.Flight*.55-math.max(0,#points-2)*.25-(shape==3 and .5 or 0)
                            +(side==favored and .15 or 0)
                            -(reachable and 0 or 100+math.max(0,ownTime-arrival)*20)
                        local penalty,failures,family,signature=adaptation(input,pass,shapeName,
                            actualDepth,side,arrival)
                        score=score-penalty
                        local release=type(input.release)=="string" and input.release~=""
                            and Config.ReleaseDefs and Config.ReleaseDefs[input.release] and input.release or nil
                        local candidate={payload={Points=points,StartX=startX,Pass=pass,Release=release},
                                plan=plan,score=score,reachable=reachable,runTime=ownTime,
                                estimatedSeparation=endpointDistance,defenderEnvelopeMargin=worstMargin,
                                side=side,depth=actualDepth,shape=shapeName,family=family,signature=signature,
                                cutCount=cutCount,lastCutAt=lastCutAt,
                                hikeTime=hikeTime,setupDefenderReach=setupReach,
                                estimatedCatchZ=catchWindow and catchWindow.point.Y,
                                estimatedCatchAt=catchWindow and catchWindow.at,
                                estimatedRACDistance=catchWindow and catchWindow.remaining,
                                estimatedCatchStamina=catchWindow and catchWindow.stamina,
                                uprightCatchReachable=catchWindow and catchWindow.reachable,
                                adaptationPenalty=penalty,recentFailureCount=failures,
                                model="observed-opponent-envelope"}
                        -- New cut routes must retain every real turn before the
                        -- native throw; after Throw the catch controller owns input.
                        local passAllowed=pass=="Bullet" and actualDepth>=16-1e-5 and actualDepth<=22+1e-5
                            and math.abs(points[#points].X-startX)>=3*yd-1e-5
                            and plan.Target.Y<=Field.GoalZ-2*yd+1e-5
                            or pass=="Floater" and actualDepth>=floaterMinimum-1e-5
                        if shape==7 then
                            if trialTrigger and depth==24 and math.abs(actualDepth-24)<1e-5
                                and pass=="Floater" and passAllowed and cutCount==1
                                and #points==3 and lastCutAt and plan.Launch-lastCutAt>=.2 then
                                trialCandidates[#trialCandidates+1]=candidate
                            end
                        elseif passAllowed and (shape<=3 or cutCount>0 and cutCount==#points-2) then
                            candidates[#candidates+1]=candidate
                            if not best or reachable and not best.reachable
                                or reachable==best.reachable and score>best.score then best=candidate end
                        end
                    end
                end
            end
        end
    end
    if best then
        local bestClearance=-INF
        local hasClearance=false
        for _,candidate in ipairs(candidates) do
            if candidate.reachable then
                bestClearance=math.max(bestClearance,candidate.defenderEnvelopeMargin)
                if candidate.defenderEnvelopeMargin>0 then hasClearance=true end
            end
        end
        local pressureMode=not opponent and "unobserved"
            or hasClearance and "clearance" or "contested"
        local function pressureEligible(candidate)
            if not candidate.reachable then return false end
            if not opponent then return true end
            if hasClearance then return candidate.defenderEnvelopeMargin>0 end
            return candidate.defenderEnvelopeMargin>=bestClearance-2*yd
        end
        local referenceScore=-INF
        for _,candidate in ipairs(candidates) do
            if pressureEligible(candidate) then referenceScore=math.max(referenceScore,candidate.score) end
        end
        local function insideGoalEligible(candidate)
            if not candidate.reachable or candidate.payload.Pass~="Floater"
                or not candidate.uprightCatchReachable or candidate.estimatedCatchZ<Field.GoalZ
                or candidate.score<referenceScore-5 then return false end
            if pressureEligible(candidate) then return true end
            -- Only an upright catch already across the goal may use this small
            -- geometric tolerance. A contested route never enters a positive-
            -- clearance group, and ordinary routes retain the original bound.
            return opponent~=nil and not hasClearance
                and candidate.defenderEnvelopeMargin>=bestClearance-2*yd-.5
        end
        local insideGoalFloater=false
        for _,candidate in ipairs(candidates) do
            if insideGoalEligible(candidate) then insideGoalFloater=true;break end
        end
        local nearGoalFloater=false
        for _,candidate in ipairs(candidates) do
            if pressureEligible(candidate) and candidate.payload.Pass=="Floater"
                and candidate.uprightCatchReachable and candidate.estimatedRACDistance<=yd
                and candidate.score>=referenceScore-5 then
                nearGoalFloater=true;break
            end
        end
        local function scoringEligible(candidate)
            if referenceScore>-INF and candidate.score<referenceScore-5 then return false end
            if insideGoalFloater and candidate.payload.Pass=="Floater" then
                return insideGoalEligible(candidate)
            end
            return pressureEligible(candidate) and (not nearGoalFloater
                or candidate.payload.Pass~="Floater"
                or candidate.uprightCatchReachable and candidate.estimatedRACDistance<=yd
                    and candidate.score>=referenceScore-5)
        end
        local pressureBest,eligibleCount=nil,0
        for _,candidate in ipairs(candidates) do
            if scoringEligible(candidate) then
                eligibleCount=eligibleCount+1
                if not pressureBest or candidate.score>pressureBest.score then pressureBest=candidate end
            end
        end
        -- Progress and previous successes cannot cancel a defender's estimated
        -- access to the catch. First choose the better-clearance group, then
        -- rank legal routes inside it. This is a conservative geometry estimate,
        -- not a promise about the defender's decisions or the server's result.
        if pressureBest then best=pressureBest end
        local choice=best
        local bestSelection=-INF
        for _,candidate in ipairs(candidates) do
            local gap=best.score-candidate.score
            -- Variety never justifies an unreachable route or a large drop in
            -- the estimated quality/clearance. If every route is unreachable,
            -- keep the best original fallback rather than rotating blindly.
            if candidate==best or scoringEligible(candidate) and best.reachable and gap<=5
                and candidate.defenderEnvelopeMargin>=best.defenderEnvelopeMargin-2*yd then
                local repeatPenalty,mixBonus,cutBonus=repetition(input,candidate)
                local selectionScore=candidate.score-repeatPenalty+mixBonus+cutBonus
                candidate.baseScore=candidate.score
                candidate.repeatPenalty=repeatPenalty;candidate.mixBonus=mixBonus
                candidate.cutBonus=cutBonus
                candidate.selectionScore=selectionScore;candidate.qualityGap=math.max(0,gap)
                if selectionScore>bestSelection then choice=candidate;bestSelection=selectionScore end
            end
        end
        choice.pressureMode=pressureMode
        choice.bestDefenderEnvelopeMargin=bestClearance>-INF and bestClearance or nil
        choice.eligibleRouteCount=eligibleCount
        choice.nearGoalFloaterAvailable=nearGoalFloater or insideGoalFloater
        choice.insideGoalFloaterAvailable=insideGoalFloater
        choice.goalCatchPreference=insideGoalFloater and "inside" or nearGoalFloater and "near" or "none"
        choice.goalReferenceScore=referenceScore>-INF and referenceScore or nil
        choice.goalClearanceToleranceUsed=insideGoalEligible(choice) and not pressureEligible(choice)
            and math.max(0,bestClearance-2*yd-choice.defenderEnvelopeMargin) or 0
        if trialTrigger and opponent and not hasClearance and referenceScore>-INF then
            local trial
            for _,candidate in ipairs(trialCandidates or {}) do
                if candidate.reachable and candidate.uprightCatchReachable
                    and candidate.estimatedCatchZ>=Field.GoalZ and candidate.score>=referenceScore-5
                    and candidate.defenderEnvelopeMargin>=bestClearance-2*yd-.5-4
                    and (not trial or candidate.score>trial.score) then trial=candidate end
            end
            if trial then
                -- Explicit, one-off model tradeoff after repeated straight-route
                -- contests. The ordinary strategy supplies every comparison bound.
                trial.baseScore=trial.score;trial.selectionScore=trial.score
                trial.qualityGap=math.max(0,referenceScore-trial.score)
                trial.repeatPenalty=0;trial.mixBonus=0;trial.cutBonus=0
                trial.pressureMode=pressureMode;trial.bestDefenderEnvelopeMargin=bestClearance
                trial.eligibleRouteCount=eligibleCount
                trial.nearGoalFloaterAvailable=true;trial.insideGoalFloaterAvailable=true
                trial.goalCatchPreference="inside";trial.goalReferenceScore=referenceScore
                trial.goalClearanceToleranceUsed=math.min(.5,
                    math.max(0,bestClearance-2*yd-trial.defenderEnvelopeMargin))
                trial.experimentalAttempt="late-bend";trial.trialTrigger=trialTrigger
                trial.experimentalClearanceGap=math.max(0,
                    bestClearance-2*yd-.5-trial.defenderEnvelopeMargin)
                choice=trial
            end
        end
        return choice
    end
    return nil,"No legal forward route"
end

function Policy.routeTarget(plan,elapsed,offset,rootY,RouteMath,position,nextWaypoint)
    if type(plan)~="table" or type(plan.Points)~="table" or #plan.Points<2
        or type(RouteMath)~="table" or type(RouteMath.PointAt)~="function" then return nil end
    offset=vec(offset) and offset or Vector3.zero
    elapsed=finite(elapsed) and math.max(0,elapsed) or 0
    if #plan.Points>=3 and vec(position) then
        local index=clamp(finite(nextWaypoint) and math.floor(nextWaypoint) or 2,2,#plan.Points)
        -- A late frame or a slower runner must visit a cut before steering to
        -- its outgoing leg. Elapsed time alone is not proof it was reached.
        while index<#plan.Points and flatDistance(position,worldPoint(plan.Points[index],offset,rootY or 0))<=1.5 do
            index=index+1
        end
        return worldPoint(plan.Points[index],offset,rootY or 0),index
    end
    -- Short look-ahead follows the polyline; the flight controller takes over
    -- when the real Throw event arrives, rather than assuming a hidden launch.
    local point=RouteMath.PointAt(plan,elapsed+.18)
    return point and worldPoint(point,offset,rootY or 0) or nil
end

-- Movement is a target request only. Caller owns input, smoothing, actual speed,
-- collision handling, and arbitration with the catch/tackle controllers.
function Policy.movement(input,Config,Field,RouteMath)
    if type(input)~="table" or not vec(input.position) or not validField(Field)
        or input.mode=="Team" or input.ballActive
        or input.phase=="Live" and input.passStarted==true then return nil end
    local position=input.position
    local offset=offsetOf(input)
    local yd=Field.YD
    local opponent=projectedOpponent(input,Config,.2)
    local margin=math.max(2,yd*.75)
    local phase,role=input.phase,input.role
    local function result(target,kind,sprint,stop,lane)
        return {target=clampWorld(target,Field,offset,margin,position.Y),kind=kind,
            sprint=sprint,stopDistance=stop,laneSide=lane}
    end
    if input.enemyCarrier and opponent and (phase=="RAC" or phase=="Live" or phase=="Run") then
        local distance=flatDistance(position,opponent)
        local lead=math.min(.45,distance/math.max(1,Config.SprintSpeed)*.3)
        local target=opponent+boundedVelocity(input.opponentVelocity,Config.SprintSpeed)*lead
        return result(target,"pursue",true,.8)
    end
    if role=="WR" and input.carrierIsMe and (phase=="RAC" or phase=="Run") then
        local minX,maxX=worldBounds(Field,offset,margin)
        local x=position.X
        local lane=input.laneSide
        local threat=opponent and opponent.Z>position.Z-2
            and opponent.Z-position.Z<math.max(18,7*yd)
            and flatDistance(position,opponent)<math.max(24,10*yd)
        if threat then
            if lane~=-1 and lane~=1 then
                local left,right=opponent.X-minX,maxX-opponent.X
                if math.abs(position.X-opponent.X)>2 then lane=position.X<opponent.X and -1 or 1
                else lane=left>=right and -1 or 1 end
            end
            x=clamp(opponent.X+lane*math.max(8,3*yd),minX,maxX)
        else lane=nil end
        if vec(input.priorTarget) then
            local dt=clamp(finite(input.dt) and input.dt or .05,.001,.15)
            local step=Config.SprintSpeed*dt*.8
            x=clamp(x,input.priorTarget.X-step,input.priorTarget.X+step)
        end
        -- Keep advancing even after crossing the goal line, until the server
        -- sends Result. Never stop at an estimated scoring threshold.
        local advance=position.Z+math.max(12,5*yd)
        local targetZ=math.min(Field.EndZ+offset.Z-margin,
            threat and advance or math.max(advance,Field.GoalZ+offset.Z+2*yd))
        return result(Vector3.new(x,position.Y,targetZ),"carry",true,.25,lane)
    end
    if role=="WR" and phase=="Live" then
        -- A reload may not know this play's snap time. Await the real ball
        -- instead of treating an already-running route as newly snapped.
        if not finite(input.elapsed) then return nil end
        local target,waypoint=Policy.routeTarget(input.routePlan,input.elapsed,offset,position.Y,
            RouteMath,position,input.routeWaypoint)
        local request=target and result(target,"route",true,.7) or nil
        if request then request.routeWaypoint=waypoint end
        return request
    end
    if role=="DB" and opponent and (phase=="PreSnap" or phase=="Live") then
        local goal=Field.GoalZ+offset.Z
        local observed=vec(input.opponentPosition) and input.opponentPosition or opponent
        local observedDepth=position.Z-observed.Z
        local nearGoal=goal-observed.Z<=6*yd
        local minDepth,maxDepth=nearGoal and yd or -yd,nearGoal and 3*yd or 5*yd
        local targetZ=position.Z
        if observedDepth<minDepth then targetZ=observed.Z+(nearGoal and yd or 0)
        elseif observedDepth>maxDepth then targetZ=observed.Z+maxDepth end
        local lateralDelta=position.X-observed.X
        local lateral=math.abs(lateralDelta)
        local targetX=position.X
        if lateral>yd then
            targetX=observed.X+(lateralDelta>0 and yd or -yd)
        end
        local velocity=boundedVelocity(input.opponentVelocity,Config.SprintSpeed)
        -- A clear crossing can leave the receiver inside the lateral deadband
        -- just as forward motion stops. Walk toward the observed crossing's
        -- short lead instead of freezing until a full yard has opened.
        if phase=="Live" and velocity.X*(observed.X-position.X)>0
            and math.abs(velocity.X)>Config.RunSpeed*.5 and lateral>.5*yd then
            targetX=observed.X+velocity.X*.25
        end
        -- Start walking as an advancing receiver comes level. Waiting for the
        -- full trailing allowance creates a persistent gap at equal run speed.
        -- A short velocity lead follows motion without restoring a fixed lead.
        if phase=="Live" and not nearGoal and velocity.Z>2 and observedDepth<yd then
            targetZ=math.max(targetZ,observed.Z+velocity.Z*.25)
        end
        -- A retreating receiver is leaving the goal. Do not walk farther
        -- downfield merely to restore the goal-side guard during that retreat.
        if phase=="Live" and nearGoal and velocity.Z < -2 then
            targetZ=math.min(targetZ,position.Z)
        end
        local target=Vector3.new(targetX,position.Y,math.min(goal+yd,targetZ))
        local urgent=velocity.Z>2 and (observedDepth < -3*yd
            or nearGoal and observedDepth<yd)
        local forwardThreat=velocity.Z>Config.RunSpeed*.5 and observedDepth < -2*yd
        local lateralThreat=lateral>4*yd and observedDepth<3*yd and velocity.Z>=-2
        local downfieldRecovery=not nearGoal and goal-observed.Z<=12*yd
            and velocity.Z>Config.RunSpeed*.5
            and observedDepth<(input.sprintOn==true and .5*yd or 0)
        local retreatingSafe=velocity.Z < -2
        -- Allow a brief trail or a modest lead without restoring fixed spacing.
        -- Use observed positions so projection does not erase that free band.
        -- Walk routine recovery; save sprint for real separation or a goal-line
        -- threat, retaining a lateral buffer instead of copying every cut.
        local needsSprint=phase=="Live" and not retreatingSafe
            and (urgent or forwardThreat or lateralThreat or downfieldRecovery)
        local stamina=finite(input.stamina) and math.max(0,input.stamina) or 0
        local startAt,stopAt=urgent and 50 or 75,urgent and 35 or 60
        local sprint=needsSprint and (input.sprintOn==true and stamina>stopAt
            or input.sprintOn~=true and stamina>=startAt)
        return result(target,"shadow",sprint,1.5)
    end
    return nil
end

return Policy
