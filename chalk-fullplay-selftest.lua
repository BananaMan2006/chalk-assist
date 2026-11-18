-- Actual saved RouteMath, with explicit numeric geometry and service fixtures.
-- No Roblox physics, network outcome, GUI input, or opponent behavior is simulated.
return function(Policy,create,routeSource,policySource)
    local report={total=0,passed=0,failed=0,results={}}
    local oldVector2,oldTypeof=Vector2,typeof
    local M,V={},{}
    local function vec(x,y) return setmetatable({X=x,Y=y},M) end
    function V.Dot(a,b) return a.X*b.X+a.Y*b.Y end
    function V.Lerp(a,b,t) return a+(b-a)*t end
    M.__index=function(a,k)
        if k=="Magnitude" then return math.sqrt(a.X*a.X+a.Y*a.Y) end
        if k=="Unit" then return a/a.Magnitude end
        return V[k]
    end
    M.__add=function(a,b) return vec(a.X+b.X,a.Y+b.Y) end
    M.__sub=function(a,b) return vec(a.X-b.X,a.Y-b.Y) end
    M.__mul=function(a,b) return type(a)=="number" and vec(a*b.X,a*b.Y) or vec(a.X*b,a.Y*b) end
    M.__div=function(a,b) return vec(a.X/b,a.Y/b) end
    Vector2={new=vec,zero=vec(0,0)}
    typeof=function(value) return getmetatable(value)==M and "Vector2" or oldTypeof(value) end
    local Config={RunSpeed=20,SprintSpeed=27,Stamina=100,SprintDrain=25,HikeTime=3,PreSnapDBSpeed=12,
        MinPointGapYards=.5,SidelineMarginYards=2,RouteEdgeMargin=1,BehindLOSYards=3,
        MaxInkYards=30,MaxPoints=200,DefaultGoYards=25,SimplifyTolerance=.6,
        CornerMinAngle=45,CornerMaxAngle=135,CornerMaxPenalty=.25,
        FillSpeed=24,MinLaunch=.4,ReleaseHeight=6,CatchHeight=3.5,QBBackYards=7,
        HandUpOffset=3.5,JumpHeight=6,CatchRadius=3.75,
        Moves={Dive={Yards=3,Time=.35},Juke={Cost=20}},
        Pass={Bullet={Flight=1.05,Apex=6},Floater={Flight=3.1,Apex=42,Lead=4}},
        ReleaseDefs={LegalRelease={}}}
    local Field={MinX=-30,MaxX=30,MidX=0,BackZ=0,LOSZ=15,GoalZ=120,EndZ=150,YD=3,TurfY=0}
    local env=setmetatable({script={Parent={Config="config",Field="field"}},
        require=function(module)
            assert(module=="config" or module=="field","unexpected native module dependency")
            return module=="config" and Config or Field
        end},{__index=_G})
    local RouteMath=assert(load(routeSource,"native RouteMath","t",env))()
    local function test(name,body)
        report.total=report.total+1
        local ok,reason=pcall(body)
        report[ok and "passed" or "failed"]=report[ok and "passed" or "failed"]+1
        report.results[#report.results+1]={name=name,passed=ok,error=not ok and tostring(reason) or nil}
    end
    local function near(a,b) assert(math.abs(a-b)<1e-7,tostring(a).." differs from "..tostring(b)) end
    local function input(extra)
        local value={mode="1v1",LOS=15,offset=Vector3.zero,position=Vector3.new(0,3,15),
            opponentPosition=Vector3.new(3,3,25),opponentVelocity=Vector3.zero,
            stamina=100,role="WR",phase="Live",elapsed=0}
        for k,v in pairs(extra or {}) do value[k]=v end
        return value
    end
    local function choose(value) return assert(Policy.chooseRoute(value,Config,Field,RouteMath)) end
    local function move(value) return Policy.movement(value,Config,Field,RouteMath) end
    local function inBounds(target,offset)
        offset=offset or Vector3.zero
        assert(target.X>=Field.MinX+offset.X+2.25-1e-6 and target.X<=Field.MaxX+offset.X-2.25+1e-6)
        assert(target.Z>=Field.BackZ+offset.Z+2.25-1e-6 and target.Z<=Field.EndZ+offset.Z-2.25+1e-6)
    end
    test("route payload obeys native sanitizer bounds and ink budget",function()
        for _,los in ipairs({15,75,115}) do
            local chosen=choose(input({LOS=los}));local p=chosen.payload
            assert(p.Pass=="Bullet" or p.Pass=="Floater")
            assert(p.StartX>=-24 and p.StartX<=24 and #p.Points>=2 and #p.Points<=201)
            near(p.Points[1].X,p.StartX);near(p.Points[1].Y,los)
            assert(RouteMath.Length(p.Points)<=Config.MaxInkYards*Field.YD+1e-6)
            for _,point in ipairs(p.Points) do
                assert(typeof(point)=="Vector2")
                assert(point.X>=-29 and point.X<=29 and point.Y>=math.max(1,los-9) and point.Y<=149)
            end
            for key in pairs(p) do assert(key=="Points" or key=="StartX" or key=="Pass" or key=="Release") end
            local expected=RouteMath.Plan(p.Points,p.Pass)
            near(chosen.plan.Launch,expected.Launch);near(chosen.plan.Arrival,expected.Arrival)
        end
    end)
    test("route choice is invariant under field translation",function()
        local a=input();local b=input({offset=Vector3.new(300,0,-400)})
        b.position=a.position+b.offset;b.opponentPosition=a.opponentPosition+b.offset
        local x,y=choose(a),choose(b)
        assert(x.payload.Pass==y.payload.Pass);near(x.payload.StartX,y.payload.StartX)
        for i,p in ipairs(x.payload.Points) do near(p.X,y.payload.Points[i].X);near(p.Y,y.payload.Points[i].Y) end
        near(x.estimatedSeparation,y.estimatedSeparation)
    end)
    test("missing opponent and exhausted stamina produce finite route diagnostics",function()
        local i=input({stamina=0});i.opponentPosition=nil;i.opponentVelocity=nil
        local c=choose(i)
        assert(c.score==c.score and math.abs(c.score)<math.huge and c.runTime>0)
        assert(c.estimatedSeparation==0)
    end)
    test("only valid owned-release names supplied by caller survive schema",function()
        assert(choose(input({release="LegalRelease"})).payload.Release=="LegalRelease")
        assert(choose(input({release="Nonexistent"})).payload.Release==nil)
    end)
    test("route is refused for team mode and invalid field",function()
        assert(Policy.chooseRoute(input({mode="Team"}),Config,Field,RouteMath)==nil)
        local broken=table.clone(Field);broken.YD=0
        assert(Policy.chooseRoute(input(),Config,broken,RouteMath)==nil)
    end)
    test("failed long Floater family is not immediately repeated on either side",function()
        local fresh=input();fresh.opponentPosition=nil;fresh.opponentVelocity=nil
        local deep=choose(fresh)
        assert(deep.payload.Pass=="Floater" and deep.depth>=22,"fixture must exercise a long Floater")
        local failed={pass=deep.payload.Pass,depth=deep.depth,shape=deep.shape,side=deep.side,
            family=deep.family,signature=deep.signature,success=false,contested=true,
            result="Swatted",time=1,roundKey="failed-1"}
        fresh.recentRoutes={failed}
        local changed=choose(fresh)
        assert(changed.family~=deep.family,"failed family repeated, possibly mirrored")
        fresh.opponentPosition=Vector3.new(deep.side<0 and -25 or 25,3,20)
        local mirroredPressure=choose(fresh)
        assert(mirroredPressure.family~=deep.family,"mirroring evaded failed-family avoidance")
        assert(changed.recentFailureCount>=1 and changed.adaptationPenalty>=0)
    end)
    test("successful history retains a legal deep option",function()
        local fresh=input();fresh.opponentPosition=nil;fresh.opponentVelocity=nil
        local deep=choose(fresh)
        fresh.recentRoutes={{pass=deep.payload.Pass,depth=deep.depth,shape=deep.shape,side=deep.side,
            family=deep.family,signature=deep.signature,success=true,contested=false,
            result="Catch",time=1,roundKey="caught-1"}}
        local after=choose(fresh)
        assert(after.depth>=22,"successful deep route was globally removed")
        assert(after.recentFailureCount==0)
        assert(RouteMath.Length(after.payload.Points)<=Config.MaxInkYards*Field.YD+1e-6)
        for _,point in ipairs(after.payload.Points) do
            assert(point.X>=-29 and point.X<=29 and point.Y>=6 and point.Y<=149)
        end
    end)
    test("repeated offensive selections vary shape and depth within the quality envelope",function()
        local p=input();p.opponentPosition=nil;p.opponentVelocity=nil
        local history,shapes,depths,families={},{},{},{}
        local baseline=choose(p)
        for i=1,12 do
            p.recentSelections=history;p.selectionIndex=i-1
            local c=choose(p)
            assert(c.reachable and c.runTime<=c.plan.Arrival+.05,
                "variety selected an unreachable route")
            assert(c.baseScore>=baseline.baseScore-5-1e-6 and c.qualityGap<=5+1e-6,
                "variety sacrificed more than its bounded quality allowance")
            assert(c.defenderEnvelopeMargin>=baseline.defenderEnvelopeMargin-2*Field.YD-1e-6)
            shapes[c.shape]=true;depths[math.floor(c.depth+.5)]=true;families[c.family]=true
            history[#history+1]={pass=c.payload.Pass,shape=c.shape,depth=c.depth,side=c.side,
                family=c.family,signature=c.signature,roundKey=tostring(i)}
            while #history>6 do table.remove(history,1) end
        end
        local function count(t) local n=0;for _ in pairs(t) do n=n+1 end;return n end
        assert(count(shapes)>1,"twelve selections repeated one route shape")
        assert(count(depths)>1,"twelve selections changed only side/shape, never depth")
        assert(count(families)>1,"mirroring was the only offensive variation")
    end)
    test("ordinary offensive variety preserves native route legality and stamina reachability",function()
        for _,stamina in ipairs({0,15,50,100}) do
            local p=input({stamina=stamina,opponentPosition=Vector3.new(-10,3,40),adaptiveRoutes=false})
            local baseline=choose(p);local history={}
            for i=1,8 do
                p.recentSelections=history;p.selectionIndex=i-1
                local c=choose(p)
                local length=RouteMath.Length(c.payload.Points)
                local distance=length+(c.plan.LeadTime or 0)*Config.FillSpeed
                local sprintDistance=Config.SprintSpeed*stamina/Config.SprintDrain
                local ownTime=math.min(distance,sprintDistance)/Config.SprintSpeed
                    +math.max(0,distance-sprintDistance)/Config.RunSpeed
                near(c.runTime,ownTime)
                assert(ownTime<=c.plan.Arrival+.05,"variety exceeded fixture movement budget")
                assert(length<=Config.MaxInkYards*Field.YD+1e-6)
                assert(c.baseScore>=baseline.baseScore-5-1e-6)
                assert(c.defenderEnvelopeMargin>=baseline.defenderEnvelopeMargin-2*Field.YD-1e-6)
                for _,point in ipairs(c.payload.Points) do
                    assert(point.X>=-29 and point.X<=29 and point.Y>=6 and point.Y<=149)
                end
                history[#history+1]={pass=c.payload.Pass,shape=c.shape,depth=c.depth,side=c.side,
                    family=c.family,signature=c.signature,roundKey=tostring(i)}
                while #history>6 do table.remove(history,1) end
            end
        end
    end)
    local function pressureFixture()
        -- Explicit reconstructed dimensions from the recorded pressure study;
        -- this is not a claim that live Field values or server reach are verified.
        local f={MinX=-30.2121302485466,MaxX=67.99998158216476,MidX=18.8939256668,
            BackZ=-44.012135207653046,EndZ=152.4120985865593,LOSZ=-19.45910851670435,
            GoalZ=103.3060463,YD=4.9106056,TurfY=1.63686865568161}
        local e=setmetatable({script={Parent={Config="config",Field="field"}},
            require=function(module)
                assert(module=="config" or module=="field")
                return module=="config" and Config or f
            end},{__index=_G})
        -- Native RouteMath captures dimensions at load; use a separate module.
        local r=assert(load(routeSource,"pressure fixture native RouteMath","t",e))()
        local p=input({LOS=f.LOSZ,position=Vector3.new(f.MidX,4.636868,f.LOSZ),
            opponentPosition=Vector3.new(f.MidX,4.636868,19.825737),middleStemDeep=false})
        -- The older numerical pressure/trial fixtures exercise the retained
        -- fallback strategy. New middle-stem tests explicitly use the default.
        return f,r,p
    end
    local function assertLongPass(c,f,los)
        if c.adaptiveUnderneath then
            assert(c.payload.Pass=="Bullet" and c.depth>=8-1e-5 and c.depth<=16+1e-5)
            assert(c.observedDefenderDepthYards>=14 and c.depth<=c.underneathDepthLimit+1e-5)
            assert(c.requireDive==false and c.estimatedCatchStamina>=10+.12*Config.SprintDrain)
        elseif c.payload.Pass=="Bullet" then
            assert(c.depth>=16-1e-5 and c.depth<=22+1e-5,"short/overlong Bullet selected")
            assert(math.abs(c.payload.Points[#c.payload.Points].X-c.payload.StartX)>=3*f.YD-1e-5,
                "Bullet route is not genuinely slanted")
            assert(c.plan.Target.Y<=f.GoalZ-2*f.YD+1e-5,"Bullet goes all the way to goal")
        else
            local available=(f.EndZ-math.max(Config.RouteEdgeMargin,1.5)-los)/f.YD
            assert(c.depth>=math.min(16,available)-1e-5,"unnecessarily short Floater selected")
        end
    end
    local function defaultMiddleFixture()
        local f,r,p=pressureFixture();p.middleStemDeep=nil
        return f,r,p
    end
    test("observed deep defender selects a reachable underneath catch with carry stamina",function()
        local f,r,p=defaultMiddleFixture()
        p.opponentPosition=Vector3.new(f.MidX,4.636868,p.LOS+18*f.YD)
        local c=assert(Policy.chooseRoute(p,Config,f,r))
        assert(c.adaptiveUnderneath and c.routeStrategy=="underneath" and c.payload.Pass=="Bullet")
        assert(c.depth>=8 and c.depth<=14+1e-5 and c.requireDive==false and not c.middleStemDeep)
        assert(c.plan.Target.Y<=p.opponentPosition.Z-4*f.YD+1e-5)
        assert(c.reachable and c.uprightCatchReachable and c.runTime+.12<=c.plan.Arrival)
        near(c.estimatedCatchStamina,p.stamina-c.plan.Arrival*Config.SprintDrain)
        assert(c.carryMoveReady and c.estimatedCatchStamina>=Config.Moves.Juke.Cost+10+.12*Config.SprintDrain)
        near(c.carryReserve,Config.Moves.Juke.Cost+10)
        local native=r.Plan(c.payload.Points,c.payload.Pass)
        near(native.Launch,c.plan.Launch);near(native.Arrival,c.plan.Arrival)
        assert(r.Length(c.payload.Points)<=Config.MaxInkYards*f.YD)
    end)
    test("underneath strategy requires observed depth and does not carry over to a shallow defender",function()
        local f,r,p=defaultMiddleFixture()
        p.opponentPosition=Vector3.new(f.MidX,4.636868,p.LOS+14*f.YD)
        local deep=assert(Policy.chooseRoute(p,Config,f,r));assert(deep.adaptiveUnderneath)
        p.recentRoutes={{pass=deep.payload.Pass,shape=deep.shape,depth=deep.depth,side=deep.side,
            signature=deep.signature,success=true,adaptiveUnderneath=true}}
        p.opponentPosition=Vector3.new(f.MidX,4.636868,p.LOS+13.99*f.YD)
        local shallow=assert(Policy.chooseRoute(p,Config,f,r));assert(not shallow.adaptiveUnderneath)
        p.opponentPosition=nil;p.opponentVelocity=nil
        assert(not assert(Policy.chooseRoute(p,Config,f,r)).adaptiveUnderneath,
            "missing defender observation reused a previous deep-camp assumption")
        p.mode="Team";assert(Policy.chooseRoute(p,Config,f,r)==nil)
    end)
    test("underneath routes vary legal families and sides without using the deep end-zone strategy",function()
        local f,r,p=defaultMiddleFixture();p.opponentPosition=Vector3.new(f.MidX,4.636868,f.GoalZ)
        local history,families,sides={},{},{}
        for i=1,12 do
            p.recentSelections=history;p.selectionIndex=i-1
            local c=assert(Policy.chooseRoute(p,Config,f,r));assert(c.adaptiveUnderneath and c.reachable)
            families[c.family]=true;sides[c.side]=true
            history[#history+1]={pass=c.payload.Pass,shape=c.shape,depth=c.depth,side=c.side,
                signature=c.signature,family=c.family,cutCount=c.cutCount,roundKey=tostring(i)}
            while #history>6 do table.remove(history,1) end
        end
        local count=0;for _ in pairs(families) do count=count+1 end
        assert(count>1 and sides[-1] and sides[1],"deep-defender offense repeated the same family or side")
    end)
    test("underneath selection respects current LOS field translation and available stamina",function()
        local f,r,p=defaultMiddleFixture()
        for _,los in ipairs({f.LOSZ,10,30}) do
            p.LOS=los;p.position=Vector3.new(f.MidX,4.636868,los)
            p.opponentPosition=Vector3.new(f.MidX,4.636868,los+18*f.YD)
            for _,stamina in ipairs({0,30,50,75,100}) do
                p.stamina=stamina
                local c=assert(Policy.chooseRoute(p,Config,f,r))
                if c.adaptiveUnderneath then
                    assert(c.reachable and c.estimatedCatchStamina>=10+.12*Config.SprintDrain)
                    assert(c.plan.Target.Y<=p.opponentPosition.Z-4*f.YD+1e-5)
                    for _,point in ipairs(c.payload.Points) do
                        assert(point.X>=f.MinX+1 and point.X<=f.MaxX-1
                            and point.Y>=math.max(f.BackZ+1,los-3*f.YD) and point.Y<=f.EndZ-1)
                    end
                    local offset=Vector3.new(300,0,-250)
                    p.offset=offset;p.position=p.position+offset;p.opponentPosition=p.opponentPosition+offset
                    local shifted=assert(Policy.chooseRoute(p,Config,f,r))
                    assert(shifted.signature==c.signature and shifted.adaptiveUnderneath)
                    near(shifted.plan.Target.X,c.plan.Target.X);near(shifted.plan.Target.Y,c.plan.Target.Y)
                    p.position=p.position-offset;p.opponentPosition=p.opponentPosition-offset;p.offset=Vector3.zero
                end
            end
        end
    end)
    test("shallow coverage mixes a paced long slant after a deep Floater while retaining native carry reserve",function()
        local f,r,p=defaultMiddleFixture()
        local first=assert(Policy.chooseRoute(p,Config,f,r));assert(first.payload.Pass=="Floater")
        p.recentSelections={{pass=first.payload.Pass,shape=first.shape,depth=first.depth,
            side=first.side,family=first.family,signature=first.signature}}
        local c=assert(Policy.chooseRoute(p,Config,f,r))
        assert(c.pacedSlant and c.payload.Pass=="Bullet" and c.routeStrategy=="long-slant-mix")
        assert(c.experimentalAttempt=="bounded-pass-mix" and c.pressureMode=="contested")
        assert(c.depth>=16 and c.depth<=18 and c.shape=="slant" and #c.plan.Points==2)
        assert(c.requireDive==false and c.carryMoveReady and c.estimatedCatchStamina>=33)
        assert(math.abs(c.plan.Target.X-c.payload.StartX)>=3*f.YD)
        local length=r.Length(c.payload.Points)
        near(c.slantWalkUntil*Config.RunSpeed+(c.plan.Arrival-.12-c.slantWalkUntil)*Config.SprintSpeed,length)
        near(c.estimatedCatchStamina,p.stamina-(c.plan.Arrival-c.slantWalkUntil)*Config.SprintDrain)
        assert(c.slantWalkUntil>=.15 and c.slantWalkUntil<c.plan.Launch-.12)
        local native=r.Plan(c.payload.Points,c.payload.Pass)
        near(native.Arrival,c.plan.Arrival);near(native.Launch,c.plan.Launch)
        p.recentSelections[#p.recentSelections+1]={pass=c.payload.Pass,shape=c.shape,depth=c.depth,
            side=c.side,family=c.family,signature=c.signature}
        assert(not assert(Policy.chooseRoute(p,Config,f,r)).pacedSlant,"slant experiment repeated on consecutive plays")
    end)
    test("long-slant mix rejects known failed family low stamina missing depth and safe ordinary alternatives",function()
        local f,r,p=defaultMiddleFixture()
        p.recentSelections={{pass="Floater",shape="sideline",depth=26,side=1}}
        local c=assert(Policy.chooseRoute(p,Config,f,r));assert(c.pacedSlant)
        p.recentRoutes={{pass="Bullet",shape="slant",depth=c.depth,side=-c.side,
            family=c.family,signature=c.signature,success=false,result="Swatted"}}
        assert(not assert(Policy.chooseRoute(p,Config,f,r)).pacedSlant,"failed mirrored slant family was blindly retried")
        p.recentRoutes=nil
        for _,stamina in ipairs({0,30,50,75}) do
            p.stamina=stamina;assert(not assert(Policy.chooseRoute(p,Config,f,r)).pacedSlant)
        end
        p.stamina=100;p.opponentPosition=nil
        assert(not assert(Policy.chooseRoute(p,Config,f,r)).pacedSlant)
        p.opponentPosition=Vector3.new(f.MidX,3,p.LOS+18*f.YD)
        assert(assert(Policy.chooseRoute(p,Config,f,r)).adaptiveUnderneath,"deep observation was overridden by pass rotation")
        p.opponentPosition=Vector3.new(f.MidX+500,3,p.LOS+5*f.YD)
        local clear=assert(Policy.chooseRoute(p,Config,f,r))
        assert(clear.pressureMode=="clearance" and not clear.pacedSlant,"mix displaced a positive-clearance option")
    end)
    test("paced long-slant movement walks first then commits sprint with field translation and throw handoff",function()
        local f,r,p=defaultMiddleFixture();p.recentSelections={{pass="Floater",shape="sideline",depth=26,side=1}}
        local c=assert(Policy.chooseRoute(p,Config,f,r));assert(c.pacedSlant)
        p.role="WR";p.phase="Live";p.routePlan=c.plan;p.pacedSlant=true;p.slantWalkUntil=c.slantWalkUntil
        p.position=Vector3.new(c.payload.StartX,3,p.LOS);p.elapsed=c.slantWalkUntil-.01
        local before=assert(Policy.movement(p,Config,f,r))
        assert(not before.sprint and not before.finalSprintCommitted);near(before.moveSpeed,Config.RunSpeed)
        p.elapsed=c.slantWalkUntil
        local after=assert(Policy.movement(p,Config,f,r))
        assert(after.sprint and after.finalSprintCommitted);near(after.moveSpeed,Config.SprintSpeed)
        p.finalSprintCommitted=true;p.elapsed=c.slantWalkUntil-.02
        assert(Policy.movement(p,Config,f,r).sprint,"committed route dropped sprint because of clock jitter")
        p.offset=Vector3.new(200,0,-300);p.position=p.position+p.offset
        local translated=assert(Policy.movement(p,Config,f,r))
        near(translated.target.X,after.target.X+p.offset.X);near(translated.target.Z,after.target.Z+p.offset.Z)
        p.ballActive=true;assert(Policy.movement(p,Config,f,r)==nil)
        p.ballActive=false;p.passStarted=true;assert(Policy.movement(p,Config,f,r)==nil)
    end)
    test("default offense runs a real middle stem before a timed deep end-zone cut",function()
        local f,r,p=defaultMiddleFixture();local c=assert(Policy.chooseRoute(p,Config,f,r))
        assert(c.middleStemDeep and c.payload.Pass=="Floater" and c.routeStrategy=="sideline-dive")
        local points=c.payload.Points;assert(#points==3 and c.cutCount==1)
        near(c.payload.StartX,f.MidX);near(points[1].X,f.MidX);near(points[2].X,f.MidX)
        assert(points[2].Y>points[1].Y+4*f.YD and points[3].Y>points[2].Y)
        assert((points[3].X-f.MidX)*c.side>0 and math.abs(points[3].X-f.MidX)>=5*f.YD-1e-6)
        assert(c.depth>=24 and c.depth<=28 and c.estimatedFinishZ>=f.GoalZ+f.YD)
        local native=r.Plan(points,c.payload.Pass)
        near(c.plan.Launch,native.Launch);near(c.lastCutAt,(points[2]-points[1]).Magnitude/Config.RunSpeed)
        near(c.slowStemTime,c.lastCutAt);near(c.startSprintAt,c.lastCutAt)
        assert(c.lastCutAt>native.Times[2] and c.slowStem and c.requireDive and c.finalSprint)
        assert(native.Launch-c.lastCutAt>=.13 and native.Launch-c.lastCutAt<=.5)
        assert(c.finalSprintStamina>=10 and c.finalSprintDuration<=(p.stamina-10)/Config.SprintDrain)
        assert(r.Length(points)<=Config.MaxInkYards*f.YD+1e-6)
    end)
    test("repeated middle-stem selections vary finish side and actual turn timing",function()
        local f,r,p=defaultMiddleFixture();local history,sides,stems={},{},{}
        p.adaptiveRoutes=false
        for i=1,12 do
            p.recentSelections=history;p.selectionIndex=i-1
            local c=assert(Policy.chooseRoute(p,Config,f,r));assert(c.middleStemDeep and c.finishReachable)
            sides[c.side]=true;stems[math.floor(c.stemYards*100+.5)]=true
            history[#history+1]={pass=c.payload.Pass,shape=c.shape,depth=c.depth,side=c.side,
                family=c.family,signature=c.signature,cutCount=c.cutCount,roundKey=tostring(i)}
            while #history>6 do table.remove(history,1) end
        end
        local variants=0;for _ in pairs(stems) do variants=variants+1 end
        assert(sides[-1] and sides[1],"middle offense kept attacking only one side")
        assert(variants>1,"route variety never changed when the middle stem turned")
    end)
    test("sideline dive finish preserves ten stamina after a walking stem and bounded continuous sprint",function()
        local oldFill=Config.FillSpeed
        local ok,reason=pcall(function()
            for _,fill in ipairs({16,24}) do
                Config.FillSpeed=fill
                local f,r,p=defaultMiddleFixture();local seen=false
                for _,stamina in ipairs({0,15,30,50,75,100}) do
                    p.stamina=stamina
                    local c=assert(Policy.chooseRoute(p,Config,f,r))
                    if c.middleStemDeep then
                        seen=true
                        local stem,finish=c.plan.Points[2],c.plan.Points[3]
                        local cutAt=(stem-c.plan.Points[1]).Magnitude/Config.RunSpeed
                        near(c.slowStemTime,cutAt)
                        local launch=stem+(finish-stem).Unit*math.min((finish-stem).Magnitude,
                            Config.SprintSpeed*math.max(0,c.plan.Launch-cutAt-c.slowStemStartupSlack))
                        local launchStamina=math.max(0,stamina-math.max(0,c.plan.Launch-cutAt)*Config.SprintDrain)
                        near(c.estimatedLaunchStamina,launchStamina)
                        near(c.estimatedLaunchX,launch.X);near(c.estimatedLaunchZ,launch.Y)
                        local origin=Vector2.new(f.MidX,p.LOS-Config.QBBackYards*f.YD)
                        local ball=origin:Lerp(c.plan.Target,.98)
                        local distance=(ball-launch).Magnitude
                        near(c.finishDistance,distance);near(c.finishWindow,c.plan.Flight*.98)
                        near(c.fullRouteDistance,r.Length(c.payload.Points)+(c.plan.Target-c.payload.Points[#c.payload.Points]).Magnitude)
                        local budget=c.plan.Flight*.98-.12
                        assert(c.finishTravelTime+.12<=c.finishWindow+1e-7)
                        assert(c.finishMode=="jumpDive" and c.requireDive and c.forceDiveFinish)
                        assert(distance<=Config.SprintSpeed*(budget-Config.Moves.Dive.Time)+Config.Moves.Dive.Yards*f.YD+1e-7,
                            "deep finish exceeded the native movement and dive budget")
                        local final=stamina-(c.plan.Arrival-cutAt+.12)*Config.SprintDrain
                        assert(final>=10 and c.finalSprintReserve==10)
                        near(c.finalSprintStamina,final)
                    end
                end
                if fill==24 then assert(seen,"native fixture never exercised the reserved sideline finish") end
            end
        end)
        Config.FillSpeed=oldFill;assert(ok,reason)
    end)
    test("middle strategy respects translated fields and falls back instead of forcing exhausted or short-field routes",function()
        local f,r,p=defaultMiddleFixture();local a=assert(Policy.chooseRoute(p,Config,f,r))
        local offset=Vector3.new(250,0,-350);p.offset=offset
        p.position=p.position+offset;p.opponentPosition=p.opponentPosition+offset
        local b=assert(Policy.chooseRoute(p,Config,f,r));assert(b.middleStemDeep and a.side==b.side)
        for i,point in ipairs(a.payload.Points) do near(point.X,b.payload.Points[i].X);near(point.Y,b.payload.Points[i].Y) end
        near(a.estimatedFinishZ,b.estimatedFinishZ)
        p.stamina=0;assert(not assert(Policy.chooseRoute(p,Config,f,r)).middleStemDeep)
        p.stamina=100;p.LOS=f.GoalZ-f.YD
        p.position=Vector3.new(f.MidX,3,p.LOS)+offset
        local short=assert(Policy.chooseRoute(p,Config,f,r));assert(not short.middleStemDeep)
        for _,point in ipairs(short.payload.Points) do assert(point.Y<=f.EndZ-1 and point.Y>=p.LOS-3*f.YD) end
    end)
    test("middle-stem navigation immediately turns after reaching the cut and yields at the throw",function()
        local f,r,p=defaultMiddleFixture();local c=assert(Policy.chooseRoute(p,Config,f,r))
        local stem=c.plan.Points[2]
        p.routePlan=c.plan;p.routeWaypoint=2;p.elapsed=c.lastCutAt;p.phase="Live"
        p.position=Vector3.new(stem.X,3,stem.Y)
        local d=assert(Policy.movement(p,Config,f,r))
        assert(d.kind=="route" and d.routeWaypoint==3 and (d.target.X-p.position.X)*c.side>0)
        assert((d.target-p.position).Magnitude>d.stopDistance,"WR stopped on the reached middle cut")
        p.ballActive=true;assert(Policy.movement(p,Config,f,r)==nil)
        p.ballActive=false;p.passStarted=true;assert(Policy.movement(p,Config,f,r)==nil)
    end)
    test("middle prethrow pacing follows native 16 and 24 timelines without cutting early or camping",function()
        local oldFill=Config.FillSpeed
        local ok,reason=pcall(function()
            for _,fill in ipairs({16,24}) do
                Config.FillSpeed=fill
                local points={Vector2.new(0,15),Vector2.new(0,63),Vector2.new(18,105)}
                local plan=RouteMath.Plan(points,"Floater")
                local p=input({middleStemDeep=true,routePlan=plan,routeWaypoint=2,elapsed=0,
                    position=Vector3.new(0,3,15)})
                local first=assert(move(p))
                assert(first.moveSpeed>fill*.95 and first.moveSpeed<=fill and first.sprint==(fill>Config.RunSpeed))
                near(first.moveScale,first.moveSpeed/(first.sprint and Config.SprintSpeed or Config.RunSpeed))
                near(first.routeDeadline,plan.Times[2])
                local dt=.025
                while p.elapsed<plan.Times[2] do
                    local d=assert(move(p));local delta=(d.target-p.position)*Vector3.new(1,0,1)
                    assert(d.routeWaypoint==2 and math.abs(delta.X)<1e-7 and delta.Z>0,
                        "middle pacing took the cut early, stopped, or reversed")
                    assert(d.moveSpeed>0 and d.moveSpeed<=Config.SprintSpeed)
                    if p.elapsed<plan.Times[2]-.3 then
                        assert(p.position.Z<points[2].Y-1.5,"runner camped at the cut before its deadline")
                    end
                    p.position=p.position+delta.Unit*math.min(delta.Magnitude,d.moveSpeed*dt)
                    p.elapsed=p.elapsed+dt
                end
                local turning=assert(move(p))
                assert(turning.routeWaypoint==3 and turning.target.X>p.position.X,
                    "runner did not turn after physically reaching its timed cut")
            end
        end)
        Config.FillSpeed=oldFill;assert(ok,reason)
    end)
    test("early two-to-four stud stem overrun never reverses or takes the cut before its deadline",function()
        local plan=RouteMath.Plan({Vector2.new(0,15),Vector2.new(0,63),Vector2.new(18,105)},"Floater")
        for _,ahead in ipairs({2,4}) do
            local p=input({middleStemDeep=true,routePlan=plan,routeWaypoint=2,
                elapsed=plan.Times[2]-.5,position=Vector3.new(0,3,63+ahead)})
            for _=1,12 do
                local d=assert(move(p));local delta=(d.target-p.position)*Vector3.new(1,0,1)
                assert(d.routeWaypoint==2 and delta.Z>0 and math.abs(delta.X)<1e-7,
                    "early overrun began backward/sideways oscillation")
                assert(d.moveSpeed>0 and d.moveScale>0 and not d.sprint)
                p.position=p.position+delta.Unit*d.moveSpeed*.025;p.elapsed=p.elapsed+.025
            end
            p.elapsed=plan.Times[2]
            local turn=assert(move(p));assert(turn.routeWaypoint==3 and turn.target.X>p.position.X)
        end
    end)
    test("late jammed middle runner catches up at native sprint and never skips an unreached cut",function()
        local plan=RouteMath.Plan({Vector2.new(0,15),Vector2.new(0,63),Vector2.new(18,105)},"Floater")
        local p=input({middleStemDeep=true,routePlan=plan,routeWaypoint=2,
            elapsed=plan.Times[2]+.5,position=Vector3.new(0,3,15)})
        local d=assert(move(p));assert(d.routeWaypoint==2 and d.sprint)
        near(d.moveSpeed,Config.SprintSpeed);near(d.moveScale,1)
        near(d.target.X,0);near(d.target.Z,63)
        p.middleStemDeep=false;assert(move(p).moveSpeed==nil,"pacing changed an ordinary route")
        p.middleStemDeep=true;p.ballActive=true;assert(move(p)==nil)
        p.ballActive=false;p.passStarted=true;assert(move(p)==nil)
    end)
    test("middle route endpoint continues gently along the final leg until the real throw",function()
        local plan=RouteMath.Plan({Vector2.new(0,15),Vector2.new(0,63),Vector2.new(18,105)},"Floater")
        local p=input({middleStemDeep=true,routePlan=plan,routeWaypoint=3,
            elapsed=plan.Times[3]-.2,position=Vector3.new(18,3,105)})
        local d=assert(move(p))
        assert(d.target.X>p.position.X and d.target.Z>p.position.Z and d.moveSpeed>0 and not d.sprint)
        p.elapsed=plan.Times[3]+1;assert(move(p).moveSpeed>0)
        inBounds(d.target)
    end)
    test("slow stem conserves sprint until actual walking deadline then sprints continuously through the cut",function()
        local plan=RouteMath.Plan({Vector2.new(0,15),Vector2.new(0,63),Vector2.new(18,105)},"Floater")
        local p=input({middleStemDeep=true,slowStem=true,slowStemTime=48/Config.RunSpeed,
            routePlan=plan,routeWaypoint=2,elapsed=0,position=Vector3.new(0,3,15)})
        local dt=.025
        while p.elapsed<p.slowStemTime do
            local d=assert(move(p));local delta=(d.target-p.position)*Vector3.new(1,0,1)
            assert(not d.sprint and not d.finalSprintCommitted and d.routeWaypoint==2)
            assert(d.moveSpeed>0 and d.moveSpeed<=Config.RunSpeed and delta.Z>0 and math.abs(delta.X)<1e-7)
            near(d.routeDeadline,p.slowStemTime)
            p.position=p.position+delta.Unit*d.moveSpeed*dt;p.elapsed=p.elapsed+dt
        end
        local committed=assert(move(p))
        assert(committed.routeWaypoint==3 and committed.finalSprintCommitted and committed.sprint)
        p.routeWaypoint=committed.routeWaypoint;p.finalSprintCommitted=true
        for _=1,12 do
            local d=assert(move(p));near(d.moveSpeed,Config.SprintSpeed)
            assert(d.sprint and d.finalSprintCommitted,"final leg resumed retiming or dropped sprint")
            local delta=(d.target-p.position)*Vector3.new(1,0,1)
            p.position=p.position+delta.Unit*d.moveSpeed*dt;p.elapsed=p.elapsed+dt
        end
        p.ballActive=true;assert(move(p)==nil)
    end)
    test("slow stem commits at the scheduled cut despite delay but never before that time",function()
        local plan=RouteMath.Plan({Vector2.new(0,15),Vector2.new(0,63),Vector2.new(18,105)},"Floater")
        local p=input({middleStemDeep=true,slowStem=true,slowStemTime=2.4,routePlan=plan,
            routeWaypoint=2,elapsed=3.5,position=Vector3.new(0,3,15)})
        local d=assert(move(p));assert(d.routeWaypoint==3 and d.sprint and d.finalSprintCommitted)
        near(d.moveSpeed,Config.SprintSpeed)
        p.position=Vector3.new(0,3,65);p.elapsed=2.3
        d=assert(move(p));assert(d.routeWaypoint==2 and not d.sprint and d.target.Z>p.position.Z)
        p.elapsed=2.4;d=assert(move(p));assert(d.routeWaypoint==3 and d.sprint and d.finalSprintCommitted)
    end)
    test("recorded WR detour and jam delays cut from current position on either side with offsets",function()
        local f,r=pressureFixture()
        for _,case in ipairs({
            {side=1,depth=26.5,stemZ=46.83407974243164,cutAt=3.3146591186523438,x=16.28,z=35.08},
            {side=-1,depth=25,stemZ=44.37877655029297,cutAt=3.1918941497802735,x=19.94,z=29.69}}) do
            local edge=case.side>0 and f.MaxX-1 or f.MinX+1
            local plan=r.Plan({Vector2.new(f.MidX,f.LOSZ),Vector2.new(f.MidX,case.stemZ),
                Vector2.new(edge,f.LOSZ+case.depth*f.YD)},"Floater")
            local p=input({middleStemDeep=true,slowStem=true,slowStemTime=case.cutAt,
                routePlan=plan,routeWaypoint=2,elapsed=case.cutAt-.001,
                position=Vector3.new(case.x,4.636868,case.z),stamina=10})
            local before=Policy.movement(p,Config,f,r)
            assert(before.routeWaypoint==2 and not before.finalSprintCommitted and not before.sprint)
            p.elapsed=case.cutAt;p.stamina=100
            local after=Policy.movement(p,Config,f,r)
            assert(after.routeWaypoint==3 and after.finalSprintCommitted and after.sprint)
            assert((after.target.X-p.position.X)*case.side>0 and after.target.Z>p.position.Z,
                "delayed stem still targets its missed waypoint instead of the final diagonal")
            near(after.moveSpeed,Config.SprintSpeed)
            local offset=Vector3.new(123,0,-250);p.offset=offset;p.position=p.position+offset
            local shifted=Policy.movement(p,Config,f,r)
            near(shifted.target.X,after.target.X+offset.X);near(shifted.target.Z,after.target.Z+offset.Z)
            assert(shifted.finalSprintCommitted and shifted.sprint)
        end
    end)
    test("scheduled late cut keeps reserve and yields to actual ball while ordinary routes retain waypoints",function()
        local plan=RouteMath.Plan({Vector2.new(0,15),Vector2.new(0,63),Vector2.new(18,105)},"Floater")
        local p=input({middleStemDeep=true,slowStem=true,slowStemTime=2.4,routePlan=plan,
            routeWaypoint=2,elapsed=2.4,position=Vector3.new(0,3,48),stamina=10})
        for _,stamina in ipairs({0,10,12.5}) do
            p.stamina=stamina;local d=assert(move(p))
            assert(d.finalSprintCommitted and d.routeWaypoint==3 and not d.sprint)
            near(d.moveSpeed,Config.RunSpeed)
        end
        p.stamina=13;assert(move(p).sprint)
        p.ballActive=true;assert(move(p)==nil)
        p.ballActive=false;p.passStarted=true;assert(move(p)==nil)
        p.passStarted=false;p.middleStemDeep=false
        local ordinary=assert(move(p));assert(ordinary.routeWaypoint==2 and not ordinary.finalSprintCommitted)
        near(ordinary.target.X,0);near(ordinary.target.Z,63)
    end)
    test("recorded9445 delayed stem spends only its current funded early-cut interval",function()
        local f,r=pressureFixture()
        local cutAt=3.1918941497802735
        local plan=r.Plan({Vector2.new(f.MidX,f.LOSZ),Vector2.new(f.MidX,44.37877655029297),
            Vector2.new(f.MaxX-1,f.LOSZ+25*f.YD)},"Floater")
        -- Interpolated from navigation9444.743593 and9444.959773, before the
        -- original cut. The preceding native speed-nine jam lost this ground.
        local p=input({middleStemDeep=true,slowStem=true,slowStemTime=cutAt,routePlan=plan,
            routeWaypoint=2,position=Vector3.new(17.457731316476945,4.636868,23.842377447875705),stamina=100})
        local earliest=plan.Arrival+.12-(p.stamina-10)/Config.SprintDrain
        assert(cutAt-earliest>.20 and cutAt-earliest<.21)
        p.elapsed=earliest-.00001
        assert(not Policy.movement(p,Config,f,r).finalSprintCommitted,"unfunded sprint began before its reserve boundary")
        p.elapsed=earliest+.00001
        local d=Policy.movement(p,Config,f,r)
        assert(d.routeWaypoint==3 and d.finalSprintCommitted and d.sprint)
        assert(p.stamina-(plan.Arrival-p.elapsed+.12)*Config.SprintDrain>=10,
            "early cut spent the final reserve or omitted dispatch allowance")
        p.stamina=99
        assert(not Policy.movement(p,Config,f,r).finalSprintCommitted,"selection-time stamina replaced current stamina")
        p.elapsed=plan.Arrival+.12-(p.stamina-10)/Config.SprintDrain+.00001
        assert(Policy.movement(p,Config,f,r).finalSprintCommitted)
        p.stamina=90;p.elapsed=cutAt-.00001
        assert(not Policy.movement(p,Config,f,r).finalSprintCommitted)
        p.elapsed=cutAt;assert(Policy.movement(p,Config,f,r).finalSprintCommitted,
            "insufficient optional early budget disabled the ordinary scheduled cut")
    end)
    test("early recovery does not alter on-schedule small-lag crossed or ordinary routes",function()
        local plan=RouteMath.Plan({Vector2.new(0,15),Vector2.new(0,63),Vector2.new(18,105)},"Floater")
        local p=input({middleStemDeep=true,slowStem=true,slowStemTime=2.4,routePlan=plan,
            routeWaypoint=2,elapsed=2.2,stamina=100})
        for _,z in ipairs({59,57,63,65}) do
            p.position=Vector3.new(0,3,z)
            local d=move(p);assert(d.routeWaypoint==2 and not d.finalSprintCommitted and not d.sprint,
                "on-schedule or ordinary startup slack caused an early cut")
        end
        p.position=Vector3.new(0,3,40);p.elapsed=2.4-.211
        assert(not move(p).finalSprintCommitted,"early recovery exceeded the .21-second cap")
        p.elapsed=2.4-.20;assert(move(p).finalSprintCommitted)
        p.middleStemDeep=false
        local ordinary=move(p);assert(ordinary.routeWaypoint==2 and not ordinary.finalSprintCommitted)
        p.middleStemDeep=true;p.slowStem=false
        assert(not move(p).finalSprintCommitted)
    end)
    test("budgeted early cuts mirror translate and remain latched through flight ownership",function()
        local f,r=pressureFixture()
        for _,side in ipairs({-1,1}) do
            local edge=side<0 and f.MinX+1 or f.MaxX-1
            local plan=r.Plan({Vector2.new(f.MidX,f.LOSZ),Vector2.new(f.MidX,44.37877655029297),
                Vector2.new(edge,f.LOSZ+25*f.YD)},"Floater")
            local p=input({middleStemDeep=true,slowStem=true,slowStemTime=3.1918941497802735,
                routePlan=plan,routeWaypoint=2,elapsed=plan.Arrival+.12-3.6+.00001,
                position=Vector3.new(f.MidX+side,4.636868,23.84),stamina=100})
            local d=Policy.movement(p,Config,f,r)
            assert(d.finalSprintCommitted and d.sprint and (d.target.X-p.position.X)*side>0)
            local offset=Vector3.new(-300,0,500);p.offset=offset;p.position=p.position+offset
            local shifted=Policy.movement(p,Config,f,r)
            assert(shifted.finalSprintCommitted);near(shifted.target.X,d.target.X+offset.X)
            near(shifted.target.Z,d.target.Z+offset.Z)
            p.finalSprintCommitted=true;p.routeWaypoint=2;p.stamina=80
            assert(Policy.movement(p,Config,f,r).finalSprintCommitted,
                "already-committed cut was re-evaluated against a falling stamina budget")
            p.ballActive=true;assert(Policy.movement(p,Config,f,r)==nil)
            p.ballActive=false;p.passStarted=true;assert(Policy.movement(p,Config,f,r)==nil)
        end
    end)
    test("final sprint latch survives waypoint refresh and retains the emergency stamina floor",function()
        local plan=RouteMath.Plan({Vector2.new(0,15),Vector2.new(0,63),Vector2.new(18,105)},"Floater")
        local p=input({middleStemDeep=true,slowStem=true,slowStemTime=2.4,routePlan=plan,
            routeWaypoint=2,finalSprintCommitted=true,elapsed=2.5,position=Vector3.new(4,3,72)})
        local d=assert(move(p));assert(d.routeWaypoint==3 and d.sprint and d.finalSprintCommitted)
        near(d.moveSpeed,Config.SprintSpeed)
        p.stamina=10;d=assert(move(p));assert(not d.sprint and d.finalSprintCommitted)
        near(d.moveSpeed,Config.RunSpeed)
        p.stamina=13;assert(move(p).sprint)
    end)
    local function assertPressureBound(c,f)
        local tolerance=c.goalClearanceToleranceUsed or 0
        local trialGap=c.experimentalClearanceGap or 0
        assert(tolerance>=0 and tolerance<=.5+1e-6)
        assert(trialGap>=0 and trialGap<=4+1e-6)
        if c.reachable and c.goalReferenceScore then
            assert(c.baseScore>=c.goalReferenceScore-5-1e-6,
                "goal filtering and variety compounded their original quality allowance")
        end
        if c.pressureMode=="clearance" then
            assert(c.defenderEnvelopeMargin>0 and tolerance==0 and trialGap==0,
                "contested route entered the positive-clearance group")
        elseif c.pressureMode=="contested" then
            assert(c.defenderEnvelopeMargin>=c.bestDefenderEnvelopeMargin-2*f.YD-tolerance-trialGap-1e-6)
        end
        if c.experimentalAttempt then
            assert(c.experimentalAttempt=="late-bend" and c.shape=="late_bend"
                and c.trialTrigger and c.cutCount==1 and c.plan.Launch-c.lastCutAt>=.2)
        end
        if tolerance>0 then
            assert(c.payload.Pass=="Floater" and c.estimatedCatchZ>=f.GoalZ
                and c.uprightCatchReachable and c.reachable and c.insideGoalFloaterAvailable)
            assert(c.baseScore>=c.goalReferenceScore-5-1e-6,
                "goal tolerance admitted an inferior route")
        end
    end
    test("actual selector cannot compound goal filtering and ordinary Bullet variety allowances",function()
        assert(type(policySource)=="string","exact selector regression requires policy source")
        local first=assert(policySource:find("    if best then\n        local bestClearance=",1,true))
        local last=assert(policySource:find('    return nil,"No legal forward route"',first,true))
        local block=policySource:sub(first,last-1)
        local selector=assert(load("return function(candidates) local best=candidates[1]; "
            .."local INF=math.huge; local opponent={}; local yd=5; local Field={GoalZ=100}; "
            .."local input={}; local function repetition(_,c) return c.penalty or 0,0,0 end "
            ..block.." end","actual fullplay selector","t",_G))()
        local selected=selector({
            {id="reference",score=100,reachable=true,payload={Pass="Floater"},
                uprightCatchReachable=true,estimatedCatchZ=99,estimatedRACDistance=1,
                defenderEnvelopeMargin=-5},
            {id="inside_goal",score=95.1,reachable=true,payload={Pass="Floater"},
                uprightCatchReachable=true,estimatedCatchZ=101,estimatedRACDistance=0,
                defenderEnvelopeMargin=-15.3,penalty=6},
            {id="ordinary_bullet",score=91,reachable=true,payload={Pass="Bullet"},
                defenderEnvelopeMargin=-14},
        })
        assert(selected.id=="inside_goal" and selected.goalReferenceScore==100,
            "ordinary Bullet spent a second quality allowance after the goal filter")
        assert(selected.baseScore>=selected.goalReferenceScore-5)
        local fallback=selector({{id="unreachable",score=1,reachable=false,payload={Pass="Bullet"},
            defenderEnvelopeMargin=-20}})
        assert(fallback.id=="unreachable" and not fallback.reachable,
            "original all-unreachable fallback was removed")
    end)
    test("native opponent and selection histories retain one original quality floor",function()
        for _,x in ipairs({-20,18.893842697143555,60}) do
            for _,z in ipairs({-20,19.825010299682617,65}) do
                local f,r,p=pressureFixture();p.opponentPosition=Vector3.new(x,3,z)
                p.recentRoutes={{pass="Floater",shape="go",depth=22,side=1,success=true}}
                p.recentSelections={}
                for j=1,6 do
                    p.recentSelections[j]={pass="Floater",shape="go",depth=24,
                        side=j%2==0 and 1 or -1,cutCount=0}
                end
                for j=1,4 do
                    p.selectionIndex=j+5
                    local c=assert(Policy.chooseRoute(p,Config,f,r))
                    assertPressureBound(c,f);assertLongPass(c,f,p.LOS)
                    p.recentSelections[#p.recentSelections+1]={pass=c.payload.Pass,
                        shape=c.shape,depth=c.depth,side=c.side,cutCount=c.cutCount}
                    table.remove(p.recentSelections,1)
                end
            end
        end
    end)
    test("central DB pressure respects explicit long slanted Bullet or Floater restriction",function()
        local f,r,p=pressureFixture()
        local c=assert(Policy.chooseRoute(p,Config,f,r))
        assertLongPass(c,f,p.LOS)
        assert(c.reachable and c.pressureMode=="contested")
        assertPressureBound(c,f)
        assert(c.hikeTime==3 and c.setupDefenderReach==36)
        p.opponentPosition=nil;p.opponentVelocity=nil
        local unknown=assert(Policy.chooseRoute(p,Config,f,r))
        assert(unknown.pressureMode=="unobserved" and unknown.depth>=22)
    end)
    test("success and variety history cannot reintroduce forbidden short passes",function()
        local f,r,p=pressureFixture()
        p.recentRoutes={{pass="Bullet",shape="go",depth=6,side=1,success=true}}
        p.recentSelections={}
        for i=1,12 do
            p.selectionIndex=i
            local c=assert(Policy.chooseRoute(p,Config,f,r))
            assertLongPass(c,f,p.LOS)
            assert(c.reachable);assertPressureBound(c,f)
            p.recentSelections[#p.recentSelections+1]={pass=c.payload.Pass,shape=c.shape,
                depth=c.depth,side=c.side,cutCount=c.cutCount}
            while #p.recentSelections>6 do table.remove(p.recentSelections,1) end
        end
    end)
    test("known Hike preparation adds exactly native defender reposition budget",function()
        local f,r,p=pressureFixture()
        local noSetup=table.clone(Config);noSetup.HikeTime=0
        local before=assert(Policy.chooseRoute(p,noSetup,f,r))
        local after=assert(Policy.chooseRoute(p,Config,f,r))
        near(before.bestDefenderEnvelopeMargin-after.bestDefenderEnvelopeMargin,
            Config.HikeTime*Config.PreSnapDBSpeed)
    end)
    test("near goal with no long Bullet room uses longest legal Floater space",function()
        local f,r,p=pressureFixture();p.LOS=f.GoalZ-f.YD
        local c=assert(Policy.chooseRoute(p,Config,f,r))
        assert(c.payload.Pass=="Floater");assertLongPass(c,f,p.LOS)
        assert(c.plan.Target.Y<=f.EndZ-Config.RouteEdgeMargin+1e-5)
    end)
    test("recorded shallow Floater variation cannot add avoidable run after catch",function()
        local f,r,p=pressureFixture()
        p.recentRoutes={{pass="Floater",shape="go",depth=22,side=1,success=true}}
        p.recentSelections={{pass="Floater",shape="go",depth=22,side=1,cutCount=0}}
        for i=1,12 do
            p.selectionIndex=i
            local c=assert(Policy.chooseRoute(p,Config,f,r))
            assertLongPass(c,f,p.LOS)
            assert(c.nearGoalFloaterAvailable and c.reachable)
            if c.payload.Pass=="Floater" then
                assert(c.uprightCatchReachable and c.estimatedRACDistance<=f.YD,
                    "variety reverted to the20yd Floater that needed16studs ofRAC")
                assert(c.runTime<=c.estimatedCatchAt+.05,
                    "shorter catch-distance estimate admitted a late native route")
                assert(c.depth>=23-1e-5 and c.estimatedCatchZ>=f.GoalZ-f.YD)
            end
            assertPressureBound(c,f)
            p.recentSelections[#p.recentSelections+1]={pass=c.payload.Pass,shape=c.shape,
                depth=c.depth,side=c.side,cutCount=c.cutCount}
            while #p.recentSelections>6 do table.remove(p.recentSelections,1) end
        end
    end)
    test("upright catch estimate follows the descending native arc rather than landing point",function()
        local f,r,p=pressureFixture();local c=assert(Policy.chooseRoute(p,Config,f,r))
        assert(c.payload.Pass=="Floater")
        local height=3+Config.HandUpOffset+Config.JumpHeight+Config.CatchRadius-.4
        local a=4*c.plan.Apex
        local b=a+Config.CatchHeight-Config.ReleaseHeight
        local u=(b+math.sqrt(b*b+4*a*(Config.ReleaseHeight-height)))/(2*a)
        local originZ=p.LOS-Config.QBBackYards*f.YD
        local expectedZ=originZ+(c.plan.Target.Y-originZ)*u
        assert(math.abs(c.estimatedCatchZ-expectedZ)<1e-4)
        assert(c.estimatedCatchZ<c.plan.Target.Y-5,"landing target was mistaken for first upright touch")
        assert(c.estimatedCatchStamina>=0 and c.estimatedCatchStamina<=p.stamina)
    end)
    test("goal-catch preference uses current LOS and never invents exhausted reach",function()
        local f,r,p=pressureFixture();p.LOS=p.LOS+35
        p.opponentPosition=p.opponentPosition+Vector3.new(0,0,35)
        local c=assert(Policy.chooseRoute(p,Config,f,r))
        assert(c.nearGoalFloaterAvailable and c.estimatedRACDistance<=f.YD)
        assert(c.depth<23,"goal preference incorrectly imposed a fixed route depth after first down")
        p.stamina=0
        local tired=assert(Policy.chooseRoute(p,Config,f,r))
        assert(not tired.nearGoalFloaterAvailable,"unreachable goal catch activated the preference")
        assertLongPass(tired,f,p.LOS)
    end)
    test("failed near-goal family cannot force a large quality loss",function()
        local f,r,p=pressureFixture()
        p.recentRoutes={{pass="Floater",shape="go",depth=23,side=1,success=false,
            family="Floater:go:23",signature="Floater:go:23:1",result="Swatted"},
            {pass="Floater",shape="go",depth=24,side=1,success=false,
                family="Floater:go:24",signature="Floater:go:24:1",result="Swatted"}}
        local c=assert(Policy.chooseRoute(p,Config,f,r))
        assert(not c.nearGoalFloaterAvailable or c.experimentalAttempt=="late-bend",
            "heavily failed near-goal route bypassed quality comparison")
        assert(c.family~="Floater:go:23" and c.family~="Floater:go:24" and c.reachable)
        assertLongPass(c,f,p.LOS);assertPressureBound(c,f)
    end)
    local function repeatedStraightFailures()
        return {{pass="Floater",shape="go",depth=24,side=1,success=false,
            result="Swatted",roundKey="failed24",cutCount=0},
            {pass="Floater",shape="go",depth=23,side=-1,success=false,
                result="Intercepted",roundKey="failed23",cutCount=0}}
    end
    test("two observed straight contests permit one bounded native late-bend trial",function()
        local f,r,p=pressureFixture();p.recentRoutes=repeatedStraightFailures()
        local c=assert(Policy.chooseRoute(p,Config,f,r))
        assert(c.experimentalAttempt=="late-bend" and c.shape=="late_bend" and math.abs(c.depth-24)<1e-6)
        assert(c.reachable and c.uprightCatchReachable and c.estimatedCatchZ>=f.GoalZ)
        assert(math.abs(c.payload.Points[2].Y-(p.LOS+11*f.YD))<1e-5)
        assert(c.cutCount==1 and c.plan.Launch-c.lastCutAt>=.2)
        assert(c.experimentalClearanceGap>3 and c.experimentalClearanceGap<4)
        assert(c.runTime<=c.estimatedCatchAt+.05)
        assertLongPass(c,f,p.LOS);assertPressureBound(c,f)
        p.lastLateBendTrialTrigger=c.trialTrigger
        assert(not Policy.chooseRoute(p,Config,f,r).experimentalAttempt,"consumed trigger retried")
        p.lastLateBendTrialTrigger=nil;p.recentSelections={{trialTrigger=c.trialTrigger}}
        assert(not Policy.chooseRoute(p,Config,f,r).experimentalAttempt,"selection history retried trigger")
    end)
    test("late-bend trial requires two relevant failures after a straight success or previous trial",function()
        local f,r,p=pressureFixture()
        local cases={{},{repeatedStraightFailures()[1]},repeatedStraightFailures(),
            repeatedStraightFailures(),repeatedStraightFailures()}
        cases[3][2].result="Incomplete"
        cases[4][3]={pass="Floater",shape="go",depth=23,success=true,cutCount=0,result="Catch"}
        cases[5][3]={pass="Floater",shape="late_bend",depth=24,success=false,result="Swatted",cutCount=1}
        for _,history in ipairs(cases) do
            p.recentRoutes=history
            assert(not Policy.chooseRoute(p,Config,f,r).experimentalAttempt,"irrelevant history triggered trial")
        end
        p.recentRoutes=repeatedStraightFailures();p.recentRoutes[2].result="Catch"
        p.recentRoutes[2].terminalResult="Tackled"
        assert(not Policy.chooseRoute(p,Config,f,r).experimentalAttempt,"RAC tackle counted as a swat")
    end)
    test("missing trial outcome still requires two fresh failures before another trial",function()
        local f,r,p=pressureFixture();p.recentRoutes=repeatedStraightFailures()
        local first=assert(Policy.chooseRoute(p,Config,f,r))
        assert(first.experimentalAttempt)
        p.lastLateBendTrialTrigger=first.trialTrigger
        p.recentRoutes[#p.recentRoutes+1]={pass="Floater",shape="go",depth=24,side=-1,
            success=false,result="Swatted",roundKey="fresh-one",cutCount=0}
        assert(not Policy.chooseRoute(p,Config,f,r).experimentalAttempt,"one consumed failure was reused")
        p.lastLateBendTrialTrigger=nil;p.recentSelections={{trialTrigger=first.trialTrigger}}
        assert(not Policy.chooseRoute(p,Config,f,r).experimentalAttempt,"selection guard reused one failure")
        p.recentRoutes[#p.recentRoutes+1]={pass="Floater",shape="go",depth=23,side=1,
            success=false,result="Intercepted",roundKey="fresh-two",cutCount=0}
        local second=assert(Policy.chooseRoute(p,Config,f,r))
        assert(second.experimentalAttempt and second.trialTrigger~=first.trialTrigger,
            "two fresh failures could not request a new bounded experiment")
        assertPressureBound(second,f)
    end)
    test("late-bend trial cannot replace normal strategy without reach or inside-goal clearance bounds",function()
        for _,kind in ipairs({"exhausted","positive","gap","no-opponent","short-goal"}) do
            local f,r,p=pressureFixture();p.recentRoutes=repeatedStraightFailures()
            if kind=="exhausted" then p.stamina=95
            elseif kind=="positive" then p.opponentPosition=Vector3.new(f.MidX,3,-65)
            elseif kind=="gap" then p.opponentPosition=Vector3.new(f.MidX,3,35)
            elseif kind=="no-opponent" then p.opponentPosition=nil
            elseif kind=="short-goal" then f.GoalZ=105 end
            local c=assert(Policy.chooseRoute(p,Config,f,r))
            assert(not c.experimentalAttempt,kind.." improperly admitted experimental route")
            assertPressureBound(c,f);assertLongPass(c,f,p.LOS)
        end
    end)
    test("actual experimental selector enforces original score and four-stud additional gap",function()
        local first=assert(policySource:find("    if best then\n        local bestClearance=",1,true))
        local last=assert(policySource:find('    return nil,"No legal forward route"',first,true))
        local block=policySource:sub(first,last-1)
        local selector=assert(load("return function(trial) local candidates={{score=100,reachable=true,"
            .."payload={Pass='Bullet'},defenderEnvelopeMargin=-5}}; local best=candidates[1]; "
            .."local INF=math.huge; local opponent={}; local yd=5; local Field={GoalZ=100}; "
            .."local trialTrigger='test'; local trialCandidates={trial}; local input={}; "
            .."local function repetition() return 0,0,0 end "..block.." end","actual trial selector","t",_G))()
        local function candidate(score,margin)
            return {score=score,reachable=true,payload={Pass="Floater"},uprightCatchReachable=true,
                estimatedCatchZ=101,estimatedRACDistance=0,defenderEnvelopeMargin=margin}
        end
        assert(selector(candidate(95,-19.5)).experimentalAttempt=="late-bend")
        assert(not selector(candidate(94.99,-19.5)).experimentalAttempt,"quality floor widened")
        assert(not selector(candidate(95,-19.5001)).experimentalAttempt,"clearance budget widened")
        local c=candidate(95,-19.5);c.uprightCatchReachable=false
        assert(not selector(c).experimentalAttempt,"unreachable jump admitted")
        c=candidate(95,-19.5);c.estimatedCatchZ=99
        assert(not selector(c).experimentalAttempt,"non-goal experiment admitted")
    end)
    test("8127 catch-zone fixture prefers reachable inside-goal catch with bounded tolerance",function()
        local f,r,p=pressureFixture()
        p.opponentPosition=Vector3.new(18.893842697143555,4.636789321899414,19.825010299682617)
        local c=assert(Policy.chooseRoute(p,Config,f,r))
        assert(c.payload.Pass=="Floater" and math.abs(c.depth-24)<1e-6)
        assert(c.goalCatchPreference=="inside" and c.insideGoalFloaterAvailable)
        assert(c.estimatedCatchZ>=f.GoalZ and c.estimatedRACDistance==0)
        assert(math.abs(c.estimatedCatchZ-104.53718584586339)<1e-5)
        assert(math.abs(c.goalClearanceToleranceUsed-.29215831770229)<1e-4)
        assert(c.runTime<=c.estimatedCatchAt+.05)
        assertPressureBound(c,f);assertLongPass(c,f,p.LOS)
    end)
    test("inside-goal tolerance never admits contested routes into a positive-clearance group",function()
        local f,r,p=pressureFixture();p.opponentPosition=Vector3.new(f.MidX,3,-65)
        local c=assert(Policy.chooseRoute(p,Config,f,r))
        assert(c.pressureMode=="clearance" and c.bestDefenderEnvelopeMargin>0)
        assert(not c.insideGoalFloaterAvailable and c.goalClearanceToleranceUsed==0)
        assertPressureBound(c,f)
    end)
    test("goal clearance exception cannot be spent on a catch short of the goal",function()
        local f,r,p=pressureFixture();f.GoalZ=105
        local c=assert(Policy.chooseRoute(p,Config,f,r))
        assert(not c.insideGoalFloaterAvailable and c.goalClearanceToleranceUsed==0)
        assertPressureBound(c,f)
    end)
    test("failed inside-goal option retains the near-goal quality fallback",function()
        local f,r,p=pressureFixture()
        p.recentRoutes={{pass="Floater",shape="go",depth=24,side=1,success=false,
            family="Floater:go:24",signature="Floater:go:24:1",result="Swatted"}}
        local c=assert(Policy.chooseRoute(p,Config,f,r))
        assert(not c.insideGoalFloaterAvailable and c.goalClearanceToleranceUsed==0)
        assert(c.family~="Floater:go:24" and c.reachable)
        assertPressureBound(c,f)
    end)
    test("inside-goal tolerance cannot override insufficient catch-window stamina",function()
        local f,r,p=pressureFixture();p.stamina=95
        local c=assert(Policy.chooseRoute(p,Config,f,r))
        assert(not c.insideGoalFloaterAvailable and c.goalClearanceToleranceUsed==0)
        assert(c.payload.Pass=="Floater" and math.abs(c.depth-23)<1e-6)
        assert(c.reachable and c.uprightCatchReachable);assertPressureBound(c,f)
    end)
    test("inside-goal clearance tolerance does not expand past half a stud",function()
        local f,r,p=pressureFixture();p.opponentPosition=Vector3.new(f.MidX,3,35)
        local c=assert(Policy.chooseRoute(p,Config,f,r))
        assert(not c.insideGoalFloaterAvailable and c.goalClearanceToleranceUsed==0)
        assertPressureBound(c,f)
    end)
    test("native multi-leg choices retain timed cuts and vary real route shapes",function()
        local p=input();p.opponentPosition=nil;p.opponentVelocity=nil
        local history,seen={},{}
        for i=1,12 do
            p.recentSelections=history;p.selectionIndex=i-1
            local c=choose(p)
            assert(c.reachable and c.runTime<=c.plan.Arrival+.05)
            assert(RouteMath.Length(c.payload.Points)<=Config.MaxInkYards*Field.YD+1e-6)
            if c.shape=="corner" or c.shape=="cross" or c.shape=="double" then
                seen[c.shape]=true
                assert(#c.payload.Points>=3 and c.cutCount==#c.payload.Points-2)
                for j=2,#c.payload.Points-1 do
                    local a=c.payload.Points[j]-c.payload.Points[j-1]
                    local b=c.payload.Points[j+1]-c.payload.Points[j]
                    local turn=math.deg(math.acos(math.clamp(a.Unit:Dot(b.Unit),-1,1)))
                    assert(turn>=20 and c.plan.Times[j]+.12<=c.plan.Launch,
                        "cut candidate turns only after catch controller takes over")
                end
            end
            history[#history+1]={pass=c.payload.Pass,shape=c.shape,depth=c.depth,
                side=c.side,cutCount=c.cutCount}
            while #history>6 do table.remove(history,1) end
        end
        assert(seen.corner and seen.cross and seen.double,"real multi-leg route types never selected")
    end)
    test("late route clock cannot skip an unreached cut waypoint",function()
        local plan=RouteMath.Plan({Vector2.new(0,15),Vector2.new(8,15),
            Vector2.new(8,30),Vector2.new(-4,45)},"Bullet")
        local offset=Vector3.new(100,0,200)
        local target,index=Policy.routeTarget(plan,10,offset,3,RouteMath,Vector3.new(100,3,215),2)
        near(target.X,108);near(target.Z,215);assert(index==2)
        target,index=Policy.routeTarget(plan,10,offset,3,RouteMath,Vector3.new(108,3,215),index)
        near(target.X,108);near(target.Z,230);assert(index==3)
        target,index=Policy.routeTarget(plan,10,offset,3,RouteMath,Vector3.new(108,3,230),index)
        near(target.X,96);near(target.Z,245);assert(index==4)
    end)
    test("prethrow WR target progresses along native timeline with offset",function()
        local points={Vector2.new(-10,15),Vector2.new(-10,60)}
        local plan=RouteMath.Plan(points,"Bullet")
        local offset=Vector3.new(200,0,300)
        local a=move(input({routePlan=plan,elapsed=0,offset=offset}))
        local b=move(input({routePlan=plan,elapsed=1,offset=offset}))
        assert(a.kind=="route" and a.sprint and b.target.Z>a.target.Z)
        near(a.target.X,190);near(a.target.Z,315+.18*24);inBounds(a.target,offset)
    end)
    test("missing snap timing does not steer a midplay reload to route start",function()
        local p=input({routePlan=RouteMath.Plan({Vector2.new(0,15),Vector2.new(0,60)},"Bullet")})
        p.elapsed=nil
        assert(move(p)==nil)
    end)
    test("DB presnap stays one to three yards on the goal side instead of crossing the receiver",function()
            for _,gap in ipairs({-8,-5,-4,-3,-2,-1,0,1,2,3,4,10}) do
                local p=input({role="DB",phase="PreSnap",position=Vector3.new(0,3,30+gap*Field.YD),
                    opponentPosition=Vector3.new(0,3,30),opponentVelocity=Vector3.zero,stamina=100})
                local d=move(p)
                assert(d and d.kind=="shadow" and not d.sprint)
                local actual=(d.target.Z-30)/Field.YD
                assert(actual>=1 and actual<=3,"opening target crossed the receiver or erased legal space")
                near(actual,gap>=1 and gap<=3 and gap or 2)
                inBounds(d.target)
            end
    end)
    test("DB presnap respects goal cap while learned deep-pass bias remains bounded",function()
        for _,z in ipairs({60,72,84,90,96,102,110}) do
            local p=input({role="DB",phase="PreSnap",position=Vector3.new(0,3,z+30),
                opponentPosition=Vector3.new(0,3,z)})
            local d=move(p);local depth=(d.target.Z-z)/Field.YD
            assert(not d.sprint and depth>=1 and depth<=3)
            assert(d.target.Z<=Field.GoalZ+Field.YD);inBounds(d.target)
        end
        local targets={}
        for i,bias in ipairs({0,1.25,2.5,20}) do
            local p=input({role="DB",phase="PreSnap",position=Vector3.new(0,3,115),
                opponentPosition=Vector3.new(0,3,90),defenseProfile={depthBiasYards=bias}})
            local d=move(p);targets[i]=d.target.Z;assert(not d.sprint)
            local offset=Vector3.new(100,0,-70)
            p.offset=offset;p.position=p.position+offset;p.opponentPosition=p.opponentPosition+offset
            near(move(p).target.Z,d.target.Z+offset.Z)
        end
        assert(targets[1]>90 and targets[2]>targets[1] and targets[3]>targets[2])
        near(targets[3],90+4.5*Field.YD)
        near(targets[3],targets[4])
    end)
    test("DB intentional opening gap and ordinary receiver movement do not spend sprint",function()
        for _,speed in ipairs({0,12,20,27}) do
            for _,gap in ipairs({-5,-4.5,-4,-3,0,4}) do
                for _,active in ipairs({false,true}) do
                    local p=input({role="DB",phase="Live",position=Vector3.new(0,3,30+gap*Field.YD),
                        opponentPosition=Vector3.new(0,3,30),opponentVelocity=Vector3.new(0,0,speed),
                        stamina=100,sprintOn=active})
                    local d=move(p)
                    assert(not d.sprint,"ordinary opening coverage borrowed final-play reserve")
                    inBounds(d.target)
                end
            end
        end
    end)
    test("recorded DB presnap stall requests free goal-side space and honors shifted LOS",function()
        local f,r=pressureFixture()
        local p=input({role="DB",phase="PreSnap",LOS=-19.459,
            position=Vector3.new(14.592,4.636868,-18.253),
            opponentPosition=Vector3.new(18.893,4.636868,-20.978),opponentVelocity=Vector3.zero})
        local d=Policy.movement(p,Config,f,r)
        assert(d.target.Z>p.position.Z+f.YD and d.target.Z>p.LOS+f.YD,
            "recorded pinned DB was still sent into WR/LOS")
        assert(not d.sprint);near(d.target.X,p.position.X)
        local offset=Vector3.new(100,0,47.3)
        p.offset=offset;p.position=p.position+offset;p.opponentPosition=p.opponentPosition+offset
        local shifted=Policy.movement(p,Config,f,r)
        near(shifted.target.X,d.target.X+offset.X);near(shifted.target.Z,d.target.Z+offset.Z)
        p.phase="Live";p.position=shifted.target;p.elapsed=0
        for _,velocity in ipairs({Vector3.zero,Vector3.new(0,0,2)}) do
            p.opponentVelocity=velocity
            local live=Policy.movement(p,Config,f,r)
            assert(live.target.Z>=p.position.Z and not live.sprint,
                "hike or stale velocity erased the opening cushion")
        end
        p.opponentVelocity=nil;p.elapsed=nil
        assert(Policy.movement(p,Config,f,r).target.Z>=p.position.Z)
    end)
    test("recorded WR setback preserves DB opening band through hike without extending later coverage",function()
        local f,r=pressureFixture()
        for _,bias in ipairs({0,2.5}) do
            for _,offset in ipairs({Vector3.zero,Vector3.new(100,0,47.3)}) do
                local p=input({role="DB",phase="Live",LOS=-19.45910851670435,offset=offset,
                    elapsed=0,position=Vector3.new(18.893924713134766,4.636868,
                        7.4953413009643555-(2.5-bias)*f.YD)+offset,
                    opponentPosition=Vector3.new(18.893842697143555,4.636868,-21.42708396911621)+offset,
                    opponentVelocity=Vector3.zero,defenseProfile={depthBiasYards=bias}})
                for _,elapsed in ipairs({0,.109,.399}) do
                    p.elapsed=elapsed;local d=Policy.movement(p,Config,f,r)
                    near(d.target.Z,p.position.Z);assert(not d.sprint)
                end
                p.elapsed=.4;local later=Policy.movement(p,Config,f,r)
                assert(later.target.Z<p.position.Z-f.YD and not later.sprint,
                    "temporary LOS alignment changed established live coverage")
                p.elapsed=nil
                near(Policy.movement(p,Config,f,r).target.Z,later.target.Z)
                p.elapsed=.1;p.opponentPosition=Vector3.new(p.opponentPosition.X,p.opponentPosition.Y,
                    p.LOS+offset.Z+f.YD)
                local forward=Policy.movement(p,Config,f,r)
                p.elapsed=.4
                near(Policy.movement(p,Config,f,r).target.Z,forward.target.Z)
            end
        end
    end)
    test("DB deep-run forecast starts before recorded late recovery and retains normal reserve",function()
        local f,r=pressureFixture()
        local p=input({role="DB",phase="Live",elapsed=.502,LOS=-19.459,
            position=Vector3.new(22.530,4.636868,-22.277),
            opponentPosition=Vector3.new(26.383,4.636868,-9.471),
            opponentVelocity=Vector3.new(0,0,26.995)})
        for _,case in ipairs({{84,false,false},{85,false,true},{71,true,true},{70,true,false}}) do
            p.stamina=case[1];p.sprintOn=case[2]
            assert(Policy.movement(p,Config,f,r).sprint==case[3],"early recovery spent normal reserve")
        end
        p.stamina=100;p.sprintOn=false
        for _,elapsed in ipairs({0,.399}) do
            p.elapsed=elapsed;assert(not Policy.movement(p,Config,f,r).sprint)
        end
        p.elapsed=nil;assert(not Policy.movement(p,Config,f,r).sprint)
        p.elapsed=.502;p.opponentVelocity=Vector3.new(0,0,20)
        assert(not Policy.movement(p,Config,f,r).sprint,"ordinary walk became an early sprint")
        p.opponentVelocity=Vector3.new(0,0,27);p.sprintOn=true
        p.position=Vector3.new(p.position.X,p.position.Y,p.opponentPosition.Z-2*f.YD)
        assert(not Policy.movement(p,Config,f,r).sprint,"recovery burst became body press")
        p.phase="PreSnap";assert(not Policy.movement(p,Config,f,r).sprint)
    end)
    test("DB gap forecast hysteresis does not toggle on every small velocity or position sample",function()
        local p=input({role="DB",phase="Live",elapsed=1,position=Vector3.new(0,3,30-2.5*Field.YD),
            opponentPosition=Vector3.new(0,3,30),opponentVelocity=Vector3.new(0,0,27)})
        assert(move(p).sprint)
        p.sprintOn=true;p.stamina=80
        for _,speed in ipairs({23,22,21,20}) do
            p.opponentVelocity=Vector3.new(0,0,speed)
            assert(move(p).sprint,"small velocity reduction interrupted active recovery")
        end
        p.position=Vector3.new(0,3,30-2*Field.YD);assert(not move(p).sprint)
        p.sprintOn=false;p.opponentVelocity=Vector3.new(0,0,27)
        for _,gap in ipairs({2,2.01,2.02}) do
            p.position=Vector3.new(0,3,30-gap*Field.YD)
            assert(not move(p).sprint,"release edge immediately restarted recovery")
        end
    end)
    test("DB advancing receiver does not manufacture more trail from level or shallow position",function()
        for _,gap in ipairs({0,-.25,-1,-2,-4}) do
            for _,speed in ipairs({10.01,20,27}) do
                local p=input({role="DB",phase="Live",position=Vector3.new(0,3,30+gap*Field.YD),
                    opponentPosition=Vector3.new(0,3,30),opponentVelocity=Vector3.new(0,0,speed),
                    elapsed=.2,stamina=100})
                local d=move(p)
                assert(d.target.Z>p.position.Z+d.stopDistance,
                    "opening cushion sent an already-shallow DB backward or left it stationary")
                assert(not d.sprint,"walking with ordinary progress requested sprint")
            end
        end
    end)
    test("DB live opening retains nearby goal-side space until forward movement is visible",function()
        local p=input({role="DB",phase="Live",position=Vector3.new(0,3,30),
            opponentPosition=Vector3.new(0,3,30),elapsed=.2,stamina=100})
        for _,speed in ipairs({-20,0,2,10}) do
            p.opponentVelocity=Vector3.new(0,0,speed)
            local d=move(p)
            near(d.target.Z,30);assert(not d.sprint)
        end
        p.opponentVelocity=Vector3.new(0,0,20);p.phase="PreSnap"
        near(move(p).target.Z,30+2*Field.YD)
        p.phase="Live";p.position=Vector3.new(0,3,30.01)
        assert(move(p).target.Z>p.position.Z)
        p.position=Vector3.new(0,3,30+Field.YD+.01)
        near(move(p).target.Z,p.position.Z)
        p.position=Vector3.new(0,3,30)
        assert(move(p).target.Z>p.position.Z)
    end)
    test("DB recorded opening retreat is corrected symmetrically and under field offset",function()
        local f,r=pressureFixture()
        for _,side in ipairs({-1,1}) do
            local p=input({role="DB",phase="Live",position=Vector3.new(f.MidX+side*2,4.636868,-23.407),
                opponentPosition=Vector3.new(f.MidX+side*4,4.636868,-19.786),
                opponentVelocity=Vector3.new(side*1,0,17.22),elapsed=.17,stamina=100,
                defenseProfile={depthBiasYards=1.25}})
            local d=Policy.movement(p,Config,f,r)
            assert(d.target.Z>p.position.Z+d.stopDistance and not d.sprint,
                "recorded 4882.894 advancing receiver still causes an opening retreat")
            near(d.target.X,p.position.X)
            local offset=Vector3.new(200,0,-300)
            p.offset=offset;p.position=p.position+offset;p.opponentPosition=p.opponentPosition+offset
            local shifted=Policy.movement(p,Config,f,r)
            near(shifted.target.X,d.target.X+offset.X);near(shifted.target.Z,d.target.Z+offset.Z)
            assert(shifted.sprint==d.sprint)
        end
    end)
    test("DB forward progress retains near-goal cap and native sprint reserve thresholds",function()
        local p=input({role="DB",phase="Live",position=Vector3.new(0,3,105),
            opponentPosition=Vector3.new(0,3,110),opponentVelocity=Vector3.new(0,0,20),
            elapsed=.2,stamina=75})
        local urgent=move(p);assert(urgent.sprint and urgent.target.Z>p.position.Z)
        for _,stamina in ipairs({0,40,43,59,60}) do
            p.stamina=stamina;p.sprintOn=true
            local d=move(p);assert(not d.sprint and d.target.Z>p.position.Z)
        end
        p.position=Vector3.new(0,3,122);p.opponentPosition=Vector3.new(0,3,125)
        local capped=move(p);assert(capped.target.Z<=Field.GoalZ+Field.YD)
        p.position=Vector3.new(0,3,105);p.opponentPosition=Vector3.new(0,3,110)
        p.opponentVelocity=Vector3.new(0,0,-20)
        assert(move(p).target.Z<=p.position.Z and not move(p).sprint)
    end)
    test("DB time taper preserves opening space then walks closer without inventing sprint urgency",function()
        local p=input({role="DB",phase="Live",position=Vector3.new(0,3,18),
            opponentPosition=Vector3.new(0,3,30),opponentVelocity=Vector3.new(0,0,20),
            stamina=100,elapsed=0})
        local early=move(p)
        for _,elapsed in ipairs({.4,.8}) do
            p.elapsed=elapsed;local d=move(p)
            near(d.target.Z,early.target.Z);assert(not d.sprint)
        end
        p.elapsed=1.55;local middle=move(p)
        p.elapsed=2.3;local late=move(p)
        assert(middle.target.Z>early.target.Z and late.target.Z>middle.target.Z)
        assert(not middle.sprint and not late.sprint,"target taper spent the final-play reserve")
        near(late.target.Z,30-.75*Field.YD+20*.25)
        p.elapsed=20;near(move(p).target.Z,late.target.Z)
        p.phase="PreSnap";local presnap=move(p);p.elapsed=0
        near(move(p).target.Z,presnap.target.Z)
    end)
    test("DB unknown snap timing leaves geometric spacing unchanged",function()
        local p=input({role="DB",phase="Live",position=Vector3.new(0,3,18),
            opponentPosition=Vector3.new(0,3,30),opponentVelocity=Vector3.new(0,0,20)})
        local before=move(p)
        p.elapsed=nil;near(move(p).target.Z,before.target.Z)
        p.elapsed=0/0;near(move(p).target.Z,before.target.Z)
        p.elapsed=math.huge;near(move(p).target.Z,before.target.Z)
    end)
    test("DB taper retains original urgent lateral and near-goal sprint thresholds",function()
        for _,case in ipairs({
            {position=Vector3.new(0,3,5),opponentPosition=Vector3.new(0,3,30),
                opponentVelocity=Vector3.new(0,0,20),stamina=75},
            {position=Vector3.new(0,3,18),opponentPosition=Vector3.new(25,3,30),
                opponentVelocity=Vector3.new(0,0,0),stamina=85},
            {position=Vector3.new(0,3,98),opponentPosition=Vector3.new(0,3,110),
                opponentVelocity=Vector3.new(0,0,20),stamina=75}}) do
            case.role="DB";case.phase="Live";case.elapsed=0
            local p=input(case);local early=move(p);assert(early.sprint)
            p.elapsed=3;assert(move(p).sprint==early.sprint)
            p.stamina=59;p.sprintOn=true;assert(not move(p).sprint)
        end
    end)
    test("DB follows equal-speed movement while retaining opening room",function()
        local p=input({role="DB",phase="Live",position=Vector3.new(0,3,30-2*Field.YD),
            opponentPosition=Vector3.new(0,3,30),opponentVelocity=Vector3.new(0,0,20),stamina=100})
        local dt=.02
        for _=1,60 do
            local d=move(p);assert(not d.sprint)
            local delta=(d.target-p.position)*Vector3.new(1,0,1)
            if delta.Magnitude>d.stopDistance then p.position=p.position+delta.Unit*math.min(delta.Magnitude,20*dt) end
            p.opponentPosition=p.opponentPosition+p.opponentVelocity*dt
        end
        local gap=(p.position.Z-p.opponentPosition.Z)/Field.YD
        assert(gap>=-3 and gap<=-1,"walking either lost the WR or erased opening space")
    end)
    test("DB ordinary recovery uses85/70 hysteresis and urgent recovery uses75/60",function()
        local p=input({role="DB",phase="Live",position=Vector3.new(0,3,10),
            opponentPosition=Vector3.new(0,3,30),opponentVelocity=Vector3.new(0,0,20)})
        for _,case in ipairs({{84,false,false},{85,false,true},{71,true,true},{70,true,false},{74,false,false}}) do
            p.stamina=case[1];p.sprintOn=case[2]
            assert(move(p).sprint==case[3],"ordinary reserve boundary "..case[1])
        end
        p.position=Vector3.new(0,3,5)
        for _,case in ipairs({{74,false,false},{75,false,true},{61,true,true},{60,true,false},{0,true,false}}) do
            p.stamina=case[1];p.sprintOn=case[2]
            assert(move(p).sprint==case[3],"urgent reserve boundary "..case[1])
        end
        p.stamina=100;p.sprintOn=true;p.phase="PreSnap";assert(not move(p).sprint)
    end)
    test("DB sprint consumption stops with sixty percent remaining even during persistent urgency",function()
        local p=input({role="DB",phase="Live",position=Vector3.new(0,3,5),
            opponentPosition=Vector3.new(0,3,30),opponentVelocity=Vector3.new(0,0,27),stamina=100})
        for _=1,40 do
            local d=move(p)
            if d.sprint then p.stamina=p.stamina-Config.SprintDrain*.1 end
            p.sprintOn=d.sprint
        end
        assert(p.stamina>=60 and not move(p).sprint,"coverage exhausted the finishing reserve")
    end)
    test("DB downfield recovery only starts beyond meaningful separation and releases before closing tightly",function()
        local p=input({role="DB",phase="Live",position=Vector3.new(0,3,79.5),
            opponentPosition=Vector3.new(0,3,90),opponentVelocity=Vector3.new(0,0,20),stamina=100})
        assert(move(p).sprint)
        p.position=Vector3.new(0,3,82);p.sprintOn=false;assert(not move(p).sprint)
        p.sprintOn=true;assert(move(p).sprint)
        p.position=Vector3.new(0,3,83);assert(not move(p).sprint)
        p.stamina=60;p.position=Vector3.new(0,3,65);assert(not move(p).sprint)
    end)
    test("DB wider lateral buffer ignores small feints on both sides",function()
        for _,side in ipairs({-1,1}) do
            for _,gap in ipairs({.25,.75,1,1.49,1.5}) do
                local p=input({role="DB",phase="Live",position=Vector3.new(0,3,18),
                    opponentPosition=Vector3.new(side*gap*Field.YD,3,30),
                    opponentVelocity=Vector3.new(side*27,0,0),stamina=100,sprintOn=true})
                local d=move(p);near(d.target.X,0);assert(not d.sprint)
            end
            local p=input({role="DB",phase="Live",position=Vector3.new(0,3,18),
                opponentPosition=Vector3.new(side*1.9*Field.YD,3,30),opponentVelocity=Vector3.zero})
            near(move(p).target.X,0)
        end
    end)
    test("DB clear lateral crossings walk with space rather than sprinting to body-press",function()
        for _,side in ipairs({-1,1}) do
            local p=input({role="DB",phase="Live",position=Vector3.new(0,3,18),
                opponentPosition=Vector3.new(side*1.75*Field.YD,3,30),
                opponentVelocity=Vector3.new(side*20,0,0),stamina=100})
            local d=move(p)
            assert((d.target.X-p.position.X)*side>0 and not d.sprint)
            p.opponentVelocity=Vector3.new(-side*20,0,0);near(move(p).target.X,0)
            p.opponentVelocity=Vector3.zero;near(move(p).target.X,0)
            p.phase="PreSnap";p.opponentVelocity=Vector3.new(side*27,0,0);near(move(p).target.X,0)
            p.opponentPosition=Vector3.new(side*3*Field.YD,3,30)
            near(move(p).target.X,side*Field.YD)
        end
    end)
    test("DB recorded small crossing now stays inside the deliberately widened buffer",function()
        local f={MinX=-30.2121302485466,MaxX=67.99998158216476,MidX=18.8939256668,
            BackZ=-44.012135207653046,EndZ=152.4120985865593,LOSZ=-19.45910851670435,
            GoalZ=103.3060463,YD=4.9106056,TurfY=1.63686865568161}
        local p=input({role="DB",phase="Live",position=Vector3.new(11.273431777954102,4.636868,60.57362365722656),
            opponentPosition=Vector3.new(16.146072387695312,4.636789,59.03019714355469),
            opponentVelocity=Vector3.new(24.345457077026367,0,-.009150903671979904),stamina=100})
        local d=Policy.movement(p,Config,f,RouteMath)
        near(d.target.X,p.position.X);assert(not d.sprint)
    end)
    test("DB retreating receivers cannot trigger sprint or forward near-goal restoration",function()
        local p=input({role="DB",phase="Live",position=Vector3.new(0,3,105),
            opponentPosition=Vector3.new(0,3,110),opponentVelocity=Vector3.new(0,0,-12),stamina=100,sprintOn=true})
        local d=move(p);near(d.target.Z,p.position.Z);assert(not d.sprint)
        p.opponentVelocity=Vector3.new(0,0,12);p.stamina=60
        d=move(p);assert(d.target.Z>p.position.Z and not d.sprint,"goal proximity spent protected reserve")
        p.stamina=75;assert(move(p).sprint)
        p.phase="PreSnap";assert(not move(p).sprint)
        for _,side in ipairs({-1,1}) do
            p=input({role="DB",phase="Live",position=Vector3.new(side*22,3,114),
                opponentPosition=Vector3.new(side*26,3,110),opponentVelocity=Vector3.new(side*27,0,-3),stamina=100})
            d=move(p);inBounds(d.target);assert(d.target.Z<=p.position.Z and not d.sprint)
        end
    end)
    test("DB coverage reserves do not replace ball ownership and pursuit preserves forty",function()
        local p=input({role="DB",phase="Live",position=Vector3.new(0,3,0),
            opponentPosition=Vector3.new(0,3,30),stamina=100,defenseProfile={depthBiasYards=2.5}})
        p.ballActive=true;assert(move(p)==nil)
        p.ballActive=false;p.passStarted=true;assert(move(p)==nil)
        p.phase="RAC";p.enemyCarrier=true
        for _,stamina in ipairs({0,39,40,43}) do p.stamina=stamina;assert(not move(p).sprint) end
        p.stamina=44;assert(move(p).kind=="pursue" and move(p).sprint)
    end)
    test("Throw to BallStop decision gap cannot restart live route or shadow",function()
        for _,role in ipairs({"WR","DB"}) do
            local p=input({role=role,phase="Live",passStarted=true,ballActive=false,
                routePlan=RouteMath.Plan({Vector2.new(0,15),Vector2.new(0,60)},"Bullet")})
            assert(move(p)==nil,"prethrow navigation restarted after BallStop for "..role)
        end
        local p=input({role="DB",phase="RAC",passStarted=true,enemyCarrier=true})
        assert(move(p).kind=="pursue","confirmed RAC carrier pursuit must still resume")
    end)
    test("carrier chase has bounded lead even with implausible observed velocity",function()
        local p=input({role="DB",phase="RAC",enemyCarrier=true,
            opponentPosition=Vector3.new(5,3,60),opponentVelocity=Vector3.new(10000,0,0)})
        local c=move(p);assert(c.kind=="pursue" and c.sprint);inBounds(c.target)
        assert(c.target.X-p.opponentPosition.X<=27*.65+1e-6)
    end)
    test("carry lane remains sticky and bounded when defender moves across center",function()
        local p=input({phase="RAC",carrierIsMe=true,position=Vector3.new(0,3,80),
            opponentPosition=Vector3.new(0,3,90)})
        local a=move(p);assert(a.kind=="carry" and a.target.Z>p.position.Z and a.laneSide)
        p.laneSide=a.laneSide;p.priorTarget=a.target;p.dt=.05
        p.opponentPosition=Vector3.new(1,3,90)
        local b=move(p);assert(b.laneSide==a.laneSide)
        assert(math.abs(b.target.X-a.target.X)<=27*.05*.8+1e-6);inBounds(b.target)
    end)
    test("carry continues past goal plane pending server result",function()
        local p=input({phase="RAC",carrierIsMe=true,position=Vector3.new(27,3,122)})
        p.opponentPosition=nil
        local c=move(p);assert(c.target.Z>122 and c.sprint);inBounds(c.target)
    end)
    test("flight team unsupported phases and unconfirmed possession yield control",function()
        for _,p in ipairs({input({ballActive=true}),input({mode="Team"}),input({phase="Hike"}),
            input({phase="Result"}),input({phase="Lobby"}),input({phase="RAC"}),input({role="QB"})}) do
            assert(move(p)==nil)
        end
        assert(move(input())==nil,"WR without a known route must not invent one")
    end)

    local function harness(options)
        options=options or {}
        local h={time=options.time or options.previousState and options.previousState.routeMemory
                and options.previousState.routeMemory.savedAt or 0,
            boardOpen=true,submits={},attempts=0,closes=0,releases=0,assist=true,
            attrs={Stamina=100},listeners={},saved=options.saved,events={},memoryDisk=options.memoryDisk,
            memoryWrites=0,memoryWriteAttempts=0,writeError=options.writeError,
            accountId=options.accountId,lookupError=options.lookupError}
        local function copyData(value)
            if type(value)~="table" then return value end
            local result={};for k,v in pairs(value) do result[k]=copyData(v) end
            return result
        end
        h.root={Position=Vector3.new(0,3,15),AssemblyLinearVelocity=Vector3.zero}
        h.opponentRoot={Position=Vector3.new(3,3,25),AssemblyLinearVelocity=Vector3.zero}
        h.character={Name="fixture-player",FindFirstChild=function(_,name) return name=="HumanoidRootPart" and h.root or nil end}
        h.opponent={Name=options.opponentName or "fixture-opponent",FindFirstChild=function(_,name) return name=="HumanoidRootPart" and h.opponentRoot or nil end}
        h.player={Character=h.character,GetAttribute=function(_,name) return h.attrs[name] end}
        h.humanoid={WalkSpeed=20,PlatformStand=false}
        h.snapshot={enabled=true,mode="1v1",phase="PreSnap",role="WR",LOS=15,offset=Vector3.zero,
            opponent=h.opponent,preSnapEnds=15}
        h.gui={MenuIsOpen=false}
        local signal={}
        function signal:Connect(callback)
            local c={callback=callback,connected=true}
            function c:Disconnect() self.connected=false end
            h.listeners[#h.listeners+1]=c;return c
        end
        local fakeHttp={}
        function fakeHttp:JSONEncode(value)
            if value.kind then h.events[#h.events+1]=table.clone(value) end
            if value.schema==1 then return copyData(value) end
            return value.version and (value.enabled and "on" or "off") or "event"
        end
        function fakeHttp:JSONDecode(value)
            if type(value)=="table" then return copyData(value) end
            assert(value=="on" or value=="off","bad saved fixture")
            return {version=1,enabled=value=="on"}
        end
        h.services={player=h.player,world={GetServerTimeNow=function() return h.time end},rs={},jobId=options.jobId or "job-a",
            Config=Config,Field=Field,RouteMath=RouteMath,guiService=h.gui,http=fakeHttp,
            players={GetPlayerFromCharacter=function(_,character)
                if h.lookupError then error(h.lookupError) end
                assert(character==h.opponent)
                return h.accountId and {UserId=h.accountId} or nil
            end},
            uis={GetFocusedTextBox=function() return h.focused end},runService={Heartbeat=signal},
            board={IsOpen=function() return h.boardOpen end,Close=function()
                h.closes=h.closes+1;if h.closeError then error(h.closeError) end;h.boardOpen=false
            end},
            submit=function(payload)
                h.attempts=h.attempts+1;if h.submitError then error(h.submitError) end
                h.submits[#h.submits+1]=payload
            end,
            read=function(file)
                if file=="ciu_fullplay_route_memory.json" then
                    if h.memoryDisk==nil then error("no saved learning") end;return h.memoryDisk
                end
                if h.saved==nil then error("no saved setting") end;return h.saved
            end,
            write=function(file,value)
                if file=="ciu_fullplay_route_memory.json" then h.memoryWriteAttempts=h.memoryWriteAttempts+1 end
                if h.writeError then error(h.writeError) end
                if file=="ciu_fullplay_route_memory.json" then
                    h.memoryDisk=copyData(value);h.memoryWrites=h.memoryWrites+1
                else h.saved=value end
            end,
            append=function() end}
        h.ctx={snapshot=function() return h.snapshot end,previousState=options.previousState,
            assistEnabled=function() return h.assist end,release=function() h.releases=h.releases+1 end}
        function h:load() self.api=create(self.ctx,Policy,self.services);return self.api end
        function h:tick(dt)
            self.time=self.time+(dt or .2)
            for _,c in ipairs(self.listeners) do if c.connected then c.callback(dt or .2) end end
        end
        function h:settle() for _=1,8 do self:tick(.2) end end
        function h:navigate() return self.api.navigate(self.snapshot,self.root,self.humanoid,self.time,.05) end
        h:load();return h
    end
    local function observedDefenseThrow(h,options)
        options=options or {};h.time=h.time+1
        local s=h.snapshot
        s.role=options.role or "DB";s.mode=options.mode or "1v1"
        if options.nativeMode then s.mode=nil end
        s.testing=options.testing==true;s.phase="PreSnap";s.preSnapEnds=h.time+15
        s.carrier=nil;s.enemyCarrier=false;s.arc=nil;s.launchAt=nil
        h.api.onMatch({Phase="PreSnap"})
        local offset=options.offset or Vector3.zero;s.offset=offset
        h.root.Position=Vector3.new(0,3,30+(options.depthAtThrow or 0)*Field.YD)+offset
        h.opponentRoot.Position=Vector3.new(0,3,30)+offset
        s.phase="Live";s.passType=options.pass or "Floater"
        local data={Type="Throw",Pass=s.passType,LaunchAt=h.time,
            Arc={P0=Vector3.new(0,6,Field.LOSZ-7*Field.YD)+offset,
                P1=Vector3.new(0,3.5,options.targetZ or Field.GoalZ)+offset,Flight=3.1,Apex=42}}
        if options.arcPass then
            data.Arc.Flight=Config.Pass[options.arcPass].Flight
            data.Arc.Apex=Config.Pass[options.arcPass].Apex
        end
        if options.arc then data.Arc=options.arc end
        if options.noPass then data.Pass=nil;s.passType=nil end
        if options.noPayloadPass then data.Pass=nil end
        if options.contextPass then s.passType=options.contextPass end
        if options.noArc then data.Arc=nil end
        h.api.onFx(data)
        return data
    end
    test("unlabelled native arcs populate defensive learning using unique configured flight and apex",function()
        for _,pass in ipairs({"Bullet","Floater"}) do
            local h=harness();h.api.setEnabled(true)
            observedDefenseThrow(h,{noPass=true,nativeMode=true,arcPass=pass})
            assert(h.api.status().activeDefense.pass==pass)
            h.api.onMatch({Phase="Result",Result="Touchdown",Point="Opp"})
            local state=h.api.status()
            assert(state.defenseProfile.samples==1,"native unlabelled throw was not learned")
            near(state.defenseProfile.depthBiasYards,pass=="Floater" and 1.25 or 0)
        end
    end)
    test("unknown ambiguous and malformed unlabelled arcs do not create defensive evidence",function()
        local function rejected(arc)
            local h=harness();h.api.setEnabled(true)
            observedDefenseThrow(h,{noPass=true,arc=arc})
            assert(h.api.status().activeDefense==nil)
            h.api.onMatch({Phase="Result",Result="Touchdown",Point="Opp"})
            assert(h.api.status().defenseProfile.samples==0)
        end
        local valid={P0=Vector3.new(0,6,-6),P1=Vector3.new(0,3.5,120),Flight=3.1,Apex=42}
        for _,bad in ipairs({{Flight=3.100001},{Apex=42.001},{Flight=0},{Flight=0/0},
            {Apex=math.huge},{P0=Vector3.new(0/0,6,0)},{P1="missing"}}) do
            local arc=table.clone(valid);for key,value in pairs(bad) do arc[key]=value end
            rejected(arc)
        end
        local previous=Config.Pass.Bullet
        Config.Pass.Bullet={Flight=3.1,Apex=42}
        local ok,reason=pcall(rejected,valid)
        Config.Pass.Bullet=previous
        assert(ok,reason)
    end)
    test("known packet pass takes precedence and known context pass survives an omitted label",function()
        local explicit=harness();explicit.api.setEnabled(true)
        observedDefenseThrow(explicit,{pass="Bullet",contextPass="Floater"})
        assert(explicit.api.status().activeDefense.pass=="Bullet")
        local context=harness();context.api.setEnabled(true)
        observedDefenseThrow(context,{pass="Bullet",noPayloadPass=true})
        assert(context.api.status().activeDefense.pass=="Bullet")
    end)
    test("DB profile learns only confirmed shallow deep-Floater losses and deduplicates terminal evidence",function()
        local h=harness({accountId=123});h.api.setEnabled(true)
        local thrown=observedDefenseThrow(h,{nativeMode=true,offset=Vector3.new(100,0,-40)})
        assert(h.api.status().activeDefense and h.api.status().defenseProfile.samples==0)
        h.api.onFx({Type="BallResult",Result="Catch"})
        assert(h.api.status().defenseProfile.samples==0,"missing catcher was treated as confirmed enemy possession")
        h.api.onFx({Type="BallResult",Result="Catch",Catcher=h.opponent})
        local s=h.api.status();near(s.defenseProfile.depthBiasYards,1.25)
        assert(s.defenseProfile.samples==1 and s.defenseProfile.deepFloaterLosses==1)
        h.api.onFx(thrown);h.api.onFx({Type="BallResult",Result="Catch",Catcher=h.opponent})
        h.api.onMatch({Phase="Result",Result="Touchdown",Point="Opp"})
        assert(h.api.status().defenseProfile.samples==1,"duplicate throw/catch/TD counted twice")
        observedDefenseThrow(h,{depthAtThrow=.5})
        h.api.onMatch({Phase="Result",Result="Touchdown",Point="Them"})
        s=h.api.status();near(s.defenseProfile.depthBiasYards,2.5);assert(s.defenseProfile.samples==2)
        observedDefenseThrow(h);h.api.onFx({Type="BallResult",Result="Catch",Catcher=h.opponent})
        near(h.api.status().defenseProfile.depthBiasYards,2.5)
    end)
    test("incomplete is neutral while confirmed deep stops and short-Bullet losses adjust the profile",function()
        local h=harness();h.api.setEnabled(true)
        observedDefenseThrow(h);h.api.onFx({Type="BallResult",Result="Catch",Catcher=h.opponent})
        observedDefenseThrow(h);h.api.onFx({Type="BallResult",Result="Incomplete"})
        near(h.api.status().defenseProfile.depthBiasYards,1.25)
        observedDefenseThrow(h);h.api.onFx({Type="BallResult",Result="Swatted"})
        near(h.api.status().defenseProfile.depthBiasYards,1)
        observedDefenseThrow(h,{pass="Bullet",targetZ=Field.LOSZ+5*Field.YD})
        h.api.onFx({Type="BallResult",Result="Catch",Catcher=h.opponent})
        near(h.api.status().defenseProfile.depthBiasYards,.5)
        local alreadyDeep=harness();alreadyDeep.api.setEnabled(true)
        observedDefenseThrow(alreadyDeep,{depthAtThrow=.51})
        alreadyDeep.api.onFx({Type="BallResult",Result="Catch",Catcher=alreadyDeep.opponent})
        near(alreadyDeep.api.status().defenseProfile.depthBiasYards,0)
    end)
    test("defense learning rejects missing arcs WR Team testing and outcomes from a later round",function()
        for _,options in ipairs({{noArc=true},{role="WR"},{mode="Team"},{testing=true}}) do
            local h=harness();h.api.setEnabled(true);observedDefenseThrow(h,options)
            h.api.onFx({Type="BallResult",Result="Catch",Catcher=h.opponent})
            assert(h.api.status().defenseProfile.samples==0)
        end
        local h=harness();observedDefenseThrow(h)
        h.api.onFx({Type="BallResult",Result="Catch",Catcher=h.opponent})
        assert(h.api.status().defenseProfile.samples==0,"disabled full auto captured defensive learning")
        h.api.setEnabled(true);observedDefenseThrow(h)
        h.snapshot.phase="PreSnap";h.snapshot.preSnapEnds=h.snapshot.preSnapEnds+20
        h.api.onMatch({Phase="PreSnap"});h.api.onFx({Type="BallResult",Result="Catch",Catcher=h.opponent})
        assert(h.api.status().defenseProfile.samples==0,"new round inherited the old pending throw")
    end)
    test("defense history is bounded and restores only fresh matching-opponent evidence across servers",function()
        local h=harness({time=100,accountId=123});h.api.setEnabled(true)
        observedDefenseThrow(h);h.api.onFx({Type="BallResult",Result="Catch",Catcher=h.opponent})
        local saved=h.memoryDisk
        local nextGame=harness({time=200,accountId=123,jobId="job-b",memoryDisk=saved})
        near(nextGame.api.status().defenseProfile.depthBiasYards,1.25)
        assert(nextGame.api.status().activeDefense==nil,"disk restored an active throw")
        local expired=harness({time=saved.savedAt+1801,accountId=123,memoryDisk=saved})
        assert(expired.api.status().defenseProfile.samples==0)
        nextGame.accountId=456;assert(nextGame.api.status().defenseProfile.samples==0)
        for _=1,8 do observedDefenseThrow(h);h.api.onFx({Type="BallResult",Result="Incomplete"}) end
        assert(#h.api.status().routeMemory.recentDefense==6 and #h.memoryDisk.recentDefense==6)
    end)
    test("learned DB profile reaches navigation rather than remaining only stored diagnostics",function()
        local h=harness();h.api.setEnabled(true)
        h.snapshot.role="DB";h.snapshot.phase="PreSnap"
        h.root.Position=Vector3.new(0,3,30);h.opponentRoot.Position=Vector3.new(0,3,30)
        observedDefenseThrow(h);h.api.onFx({Type="BallResult",Result="Catch",Catcher=h.opponent})
        observedDefenseThrow(h);h.api.onFx({Type="BallResult",Result="Catch",Catcher=h.opponent})
        h.snapshot.phase="PreSnap";h.snapshot.passStarted=false;h.snapshot.arc=nil
        h.root.Position=Vector3.new(0,3,90);h.opponentRoot.Position=Vector3.new(0,3,90)
        local d=assert(h:navigate())
        assert(d.direction.Z>0 and not d.sprint,"observed repeated deep catches did not deepen the walking target")
    end)
    test("deep-catch intent is pure and available only after an enabled successful route submission",function()
        local original=Policy.chooseRoute
        Policy.chooseRoute=function(...)
            local c=assert(original(...));c.middleStemDeep=true;return c
        end
        local ok,reason=pcall(function()
            local h=harness();assert(h.api.catchIntent()==nil)
            h.api.setEnabled(true);assert(h.api.catchIntent()==nil);h:settle()
            local intent=assert(h.api.catchIntent())
            assert(intent.deepFinish and typeof(intent.waypoint)=="Vector2")
            near(intent.goalZ,Field.GoalZ);near(intent.endZ,Field.EndZ)
            h.ctx.snapshot=function() error("intent must not recurse into core context") end
            assert(h.api.catchIntent().deepFinish)
            h.api.setEnabled(false);assert(h.api.catchIntent()==nil)
            h.api.unload();assert(h.api.catchIntent()==nil)
        end)
        Policy.chooseRoute=original
        assert(ok,reason)
    end)
    test("controller forwards middle pacing and scales input against actual native walk speed",function()
        local original,oldFill=Policy.chooseRoute,Config.FillSpeed
        Config.FillSpeed=16
        local points={Vector2.new(0,15),Vector2.new(0,63),Vector2.new(18,105)}
        local plan=RouteMath.Plan(points,"Floater")
        Config.FillSpeed=oldFill
        Policy.chooseRoute=function(...)
            local c=assert(original(...))
            c.middleStemDeep=true;c.payload={Points=points,StartX=0,Pass="Floater"};c.plan=plan
            return c
        end
        local ok,reason=pcall(function()
            local h=harness();h.api.setEnabled(true);h:settle()
            h.snapshot.phase="Live";h.snapshot.snapAt=h.time;h.snapshot.route=nil
            h.root.Position=Vector3.new(0,3,15)
            local expectedSpeed=48/(plan.Times[2]+.05)
            for _,actualSpeed in ipairs({27,20,12}) do
                h.humanoid.WalkSpeed=actualSpeed
                local d=assert(h:navigate())
                assert(not d.sprint and d.direction.Z>0 and math.abs(d.direction.X)<1e-7)
                near(d.direction.Magnitude*actualSpeed,math.min(actualSpeed,expectedSpeed))
                assert(d.direction.Magnitude<=1,"pacing attempted to exceed native movement speed")
            end
            h.snapshot.arc={};assert(h:navigate()==nil)
        end)
        Policy.chooseRoute=original;Config.FillSpeed=oldFill
        assert(ok,reason)
    end)
    test("full auto budget and fallback dive intent are pure and never leak into manual play",function()
        local original=Policy.chooseRoute
        Policy.chooseRoute=function(...)
            local c=assert(original(...));c.middleStemDeep=false;return c
        end
        local ok,reason=pcall(function()
            local h=harness();assert(h.api.movementBudget()==nil and h.api.catchIntent()==nil)
            h.api.setEnabled(true);local budget=assert(h.api.movementBudget())
            assert(budget.dbReserve==40 and budget.wrReserve==10)
            budget.dbReserve=0;assert(h.api.movementBudget().dbReserve==40)
            h:settle();local intent=assert(h.api.catchIntent())
            assert(intent.requireDive and not intent.deepFinish and not intent.finalSprint)
            h.ctx.snapshot=function() error("pure full-auto APIs must not recurse") end
            assert(h.api.catchIntent().requireDive and h.api.movementBudget().wrReserve==10)
            h.api.setEnabled(false);assert(h.api.catchIntent()==nil and h.api.movementBudget()==nil)
            h.api.unload();assert(h.api.movementBudget()==nil)
        end)
        Policy.chooseRoute=original;assert(ok,reason)
    end)
    test("controller latches final sprint through flight and clears it after the catch or next round",function()
        local original=Policy.chooseRoute
        local points={Vector2.new(0,15),Vector2.new(0,63),Vector2.new(18,105)}
        local plan=RouteMath.Plan(points,"Floater")
        Policy.chooseRoute=function(...)
            local c=assert(original(...));c.middleStemDeep=true;c.slowStem=true;c.slowStemTime=2.4
            c.requireDive=true;c.finalSprint=true;c.payload={Points=points,StartX=0,Pass="Floater"};c.plan=plan
            return c
        end
        local ok,reason=pcall(function()
            local h=harness();h.api.setEnabled(true);h:settle()
            h.snapshot.phase="Live";h.snapshot.snapAt=h.time;h.snapshot.route=nil
            local snap=h.time;h.root.Position=Vector3.new(0,3,15)
            assert(not h:navigate().sprint and not h.api.catchIntent().finalSprint)
            h.time=snap+2.18;h.root.Position=Vector3.new(0,3,48)
            assert(not h:navigate().sprint and not h.api.status().finalSprintCommitted)
            h.time=snap+2.4;local d=assert(h:navigate())
            assert(d.sprint and h.api.status().finalSprintCommitted)
            local intent=assert(h.api.catchIntent());assert(intent.requireDive and intent.finalSprint and intent.continuousSprint)
            h.snapshot.arc={};assert(h:navigate()==nil and h.api.catchIntent().continuousSprint)
            local previous=h.api.status()
            local same=harness({saved="on",previousState=previous,time=h.time})
            same.snapshot.phase="Live";same.snapshot.snapAt=snap;same.snapshot.arc={}
            assert(same.api.status().finalSprintCommitted and same.api.catchIntent().continuousSprint,
                "same-job live reload lost its owned final sprint")
            local other=harness({saved="on",previousState=previous,time=h.time,jobId="other-job"})
            other.snapshot.phase="Live";other.snapshot.snapAt=snap
            assert(not other.api.status().finalSprintCommitted and other.api.catchIntent()==nil,
                "another server inherited an active cut or dive request")
            h.snapshot.arc=nil;h.api.onFx({Type="BallResult",Result="Catch",Catcher=h.character})
            assert(h.api.catchIntent()==nil and not h.api.status().finalSprintCommitted)
            h.snapshot.phase="PreSnap";h.snapshot.preSnapEnds=30;h.boardOpen=true;h:settle()
            assert(not h.api.status().finalSprintCommitted and not h.api.catchIntent().continuousSprint)
        end)
        Policy.chooseRoute=original;assert(ok,reason)
    end)
    test("controller off by default and one submission per pre-snap",function()
        local h=harness();h:tick();assert(#h.submits==0)
        h.api.setEnabled(true);h:settle();assert(#h.submits==1 and h.closes==1)
        h.boardOpen=true
        for i=1,20 do h:tick() end
        assert(#h.submits==1 and h.api.status().submitted)
        h.snapshot.phase="Hike";h:tick();h.snapshot.phase="PreSnap";h.snapshot.preSnapEnds=30;h:settle()
        assert(#h.submits==2)
    end)
    test("closed or manually submitted board is not overwritten",function()
        local h=harness();h.boardOpen=false;h.api.setEnabled(true)
        for i=1,10 do h:tick() end
        assert(h.attempts==0 and h.closes==0)
    end)
    test("pre-snap observes for one second and still submits only once",function()
        local h=harness();h.api.setEnabled(true);h:tick(.2)
        assert(h.attempts==0)
        for _=1,4 do h:tick(.2) end
        assert(h.attempts==0,"submitted before one-second observation elapsed")
        h:tick(.25);assert(#h.submits==1)
        h.boardOpen=true
        for _=1,15 do h:tick(.2) end
        assert(h.attempts==1,"delayed setup duplicated an accepted request")
    end)
    test("near-deadline pre-snap bypasses the observation delay",function()
        local h=harness();h.api.setEnabled(true);h.snapshot.preSnapEnds=.6;h:tick(.2)
        assert(#h.submits==1,"close deadline was lost waiting for observation")
    end)
    test("visibly retreating defender extends observation only until deep threshold or three seconds",function()
        local h=harness();h.api.setEnabled(true)
        h.opponentRoot.Position=Vector3.new(3,3,15+8*Field.YD)
        h.opponentRoot.AssemblyLinearVelocity=Vector3.new(0,0,12)
        for _=1,8 do h:tick(.2) end
        assert(h.attempts==0,"moving-deep defender was submitted against after only one second")
        h.opponentRoot.Position=Vector3.new(3,3,15+14*Field.YD)
        h:tick(.2);assert(#h.submits==1 and h.api.status().activeRoute.adaptiveUnderneath)
        local bounded=harness();bounded.api.setEnabled(true)
        bounded.opponentRoot.AssemblyLinearVelocity=Vector3.new(0,0,12)
        for _=1,15 do bounded:tick(.2) end
        assert(bounded.attempts==0)
        bounded:tick(.25);assert(#bounded.submits==1,"observation exceeded its three-second bound")
        local stopped=harness();stopped.api.setEnabled(true)
        stopped.opponentRoot.AssemblyLinearVelocity=Vector3.new(0,0,12)
        for _=1,8 do stopped:tick(.2) end
        stopped.opponentRoot.AssemblyLinearVelocity=Vector3.zero
        stopped:tick(.2);assert(#stopped.submits==1,"stopped defender retained a future-depth assumption")
        local urgent=harness();urgent.api.setEnabled(true)
        urgent.opponentRoot.AssemblyLinearVelocity=Vector3.new(0,0,12)
        urgent.snapshot.preSnapEnds=.6;urgent:tick(.2)
        assert(#urgent.submits==1,"moving defender observation missed the native deadline")
    end)
    test("underneath upright intent survives same-round reload and hands off only on confirmed possession",function()
        local h=harness();h.api.setEnabled(true)
        h.opponentRoot.Position=Vector3.new(3,3,15+18*Field.YD)
        h:settle();local state=h.api.status()
        assert(state.activeRoute.adaptiveUnderneath and state.activeRoute.requireDive==false)
        assert(state.activeRoute.carryMoveReady and state.activeRoute.estimatedCatchStamina>=33)
        assert(not h.api.catchIntent().requireDive and not h.api.catchIntent().deepFinish)
        h:tick(.2);assert(h.api.status().message=="Full auto · Underneath: defender deep")
        h.snapshot.phase="Live";h.snapshot.snapAt=h.time;h.snapshot.route=nil
        h:navigate();assert(h.api.status().message=="Full auto · Underneath: defender deep")
        local same=harness({saved="on",previousState=h.api.status(),time=h.time})
        same.snapshot.phase="Live";same.snapshot.snapAt=h.time
        same.api.status()
        local intent=assert(same.api.catchIntent())
        assert(not intent.requireDive and not intent.deepFinish and not intent.continuousSprint)
        local other=harness({saved="on",previousState=state,time=h.time,jobId="different-job"})
        assert(other.api.catchIntent()==nil,"a new server inherited active underneath catch intent")
        h.snapshot.arc={};h.snapshot.passStarted=true
        assert(h:navigate()==nil,"route navigation continued after throw")
        h.api.onFx({Type="BallResult",Result="Catch",Catcher=h.character})
        assert(h.api.catchIntent()==nil,"completed catch retained forced catch intent")
        h.snapshot.arc=nil;h.snapshot.phase="RAC";h.snapshot.carrier=h.character
        local carry=assert(h:navigate());assert(carry.message=="Full auto · carry" and carry.direction.Z>=0)
        h.api.setEnabled(false);assert(h.api.catchIntent()==nil and h:navigate()==nil)
    end)
    test("paced slant submission preserves upright intent and native sprint timing across reload",function()
        local h=harness();h.api.setEnabled(true);h:settle()
        assert(h.api.status().activeRoute.pass=="Floater")
        h.api.onFx({Type="BallResult",Result="Swatted"})
        h.snapshot.preSnapEnds=30;h.boardOpen=true;h.api.onMatch({Phase="PreSnap"});h:settle()
        local selected=assert(h.api.status().activeRoute)
        assert(selected.pacedSlant and selected.requireDive==false and selected.carryMoveReady)
        assert(h.api.catchIntent().requireDive==false and not h.api.catchIntent().continuousSprint)
        h.snapshot.phase="Live";h.snapshot.snapAt=h.time
        local snap=h.time
        h.root.Position=Vector3.new(h.submits[2].StartX,3,15)
        h.time=snap+selected.slantWalkUntil-.01
        assert(not h:navigate().sprint)
        h.time=snap+selected.slantWalkUntil
        assert(h:navigate().sprint and h.api.catchIntent().continuousSprint)
        h.snapshot.arc={};local old=h.api.status()
        local same=harness({saved="on",previousState=old,time=h.time})
        same.snapshot.preSnapEnds=30;same.snapshot.phase="Live";same.snapshot.snapAt=snap;same.snapshot.arc={}
        same.api.status()
        local intent=assert(same.api.catchIntent())
        assert(intent.requireDive==false and intent.continuousSprint)
        same.api.setEnabled(false);assert(same.api.catchIntent()==nil)
        local other=harness({saved="on",previousState=old,time=h.time,jobId="another-job"})
        other.snapshot.preSnapEnds=30;other.snapshot.phase="Live";other.api.status()
        assert(other.api.catchIntent()==nil,"cross-server history restored a sprinting slant")
    end)
    test("B V menu text testing and team gates block setup and navigation",function()
        for _,gate in ipairs({"B","V","menu","text","test","team"}) do
            local h=harness();h.api.setEnabled(true)
            if gate=="B" then h.snapshot.enabled=false elseif gate=="V" then h.assist=false
            elseif gate=="menu" then h.gui.MenuIsOpen=true elseif gate=="text" then h.focused={}
            elseif gate=="test" then h.snapshot.testing=true else h.snapshot.mode="Team" end
            h:tick();assert(h.attempts==0,gate.." submitted")
            h.snapshot.role="DB";assert(h:navigate()==nil,gate.." navigated")
        end
    end)
    test("submission errors are bounded and recover on a later round",function()
        local h=harness();h.api.setEnabled(true);h.submitError="fixture rejection"
        for i=1,40 do h:tick(.25) end
        assert(h.attempts==3 and #h.submits==0 and h.api.status().error)
        h.submitError=nil;h.snapshot.phase="Result";h:tick()
        h.snapshot.phase="PreSnap";h.snapshot.preSnapEnds=50;h:settle()
        assert(h.attempts==4 and #h.submits==1 and not h.api.status().error)
    end)
    test("closing board failure does not duplicate a successful submit",function()
        local h=harness();h.api.setEnabled(true);h.closeError="fixture close failure";h:settle()
        for i=1,20 do h:tick() end
        assert(#h.submits==1 and h.api.status().error)
    end)
    test("release selection requires actual ownership",function()
        for _,owned in ipairs({false,true}) do
            local h=harness();h.attrs.EquippedRelease="LegalRelease";h.attrs.Owned_LegalRelease=owned
            h.api.setEnabled(true);h:settle()
            assert(h.submits[1].Release==(owned and "LegalRelease" or nil))
        end
    end)
    test("toggle persistence restores off and on and reports save failure",function()
        local h=harness({saved="on"});assert(h.api.status().enabled)
        h.api.setEnabled(false);assert(h.saved=="off" and h.releases==1)
        h.api.unload();h:load();assert(not h.api.status().enabled)
        h.api.setEnabled(true);assert(h.saved=="on")
        h.writeError="fixture disk error";h.api.setEnabled(false)
        assert(not h.api.status().enabled and h.api.status().saveError)
    end)
    test("unload disconnects listener and stale callback cannot submit or navigate",function()
        local h=harness();h.api.setEnabled(true)
        local old=h.listeners[1].callback;h.api.unload();h.api.unload()
        old(1);h:tick();assert(h.attempts==0 and h.releases==1 and not h.listeners[1].connected)
        h.snapshot.role="DB";assert(h:navigate()==nil)
    end)
    test("live route and confirmed carrier use one bounded native movement request",function()
        local h=harness();h.api.setEnabled(true);h:settle()
        h.snapshot.phase="Live";h.snapshot.snapAt=0;h.time=1
        h.snapshot.route={Vector2.new(0,15),Vector2.new(0,60)};h.snapshot.passType="Bullet"
        local d=h:navigate();assert(d and d.sprint and d.direction.Z>0 and d.direction.Magnitude<=1)
        h.snapshot.arc={};assert(h:navigate()==nil);h.snapshot.arc=nil
        h.snapshot.passStarted=true;assert(h:navigate()==nil,"controller failed to forward pass latch")
        h.snapshot.phase="RAC";h.snapshot.route=nil;assert(h:navigate()==nil)
        h.snapshot.carrier=h.character;assert(h:navigate())
        h.humanoid.PlatformStand=true;assert(h:navigate()==nil)
    end)
    test("controller uses current native sprint state for DB reserve hysteresis",function()
        local h=harness();h.api.setEnabled(true)
        h.snapshot.role="DB";h.snapshot.phase="Live"
        h.root.Position=Vector3.new(0,3,10);h.opponentRoot.Position=Vector3.new(0,3,30)
        h.opponentRoot.AssemblyLinearVelocity=Vector3.new(0,0,20)
        h.attrs.Stamina=80;h.attrs.SprintOn=false
        local walking=h:navigate();assert(walking and not walking.sprint)
        h.attrs.SprintOn=true
        local keeping=h:navigate();assert(keeping and keeping.sprint,
            "controller omitted the actual active sprint state")
        h.attrs.Stamina=70;assert(not h:navigate().sprint)
        h.attrs.Stamina=80;h.attrs.SprintOn=false;assert(not h:navigate().sprint)
        h.attrs.Stamina=85;assert(h:navigate().sprint)
        h.snapshot.arc={};assert(h:navigate()==nil)
    end)
    test("first carry escape starts at catch position rather than stale route target",function()
        -- Shift the fixture field so world x43..60 is legal. A prethrow route
        -- points right toward x60, while a later catch needs a leftward escape.
        -- Actual flight handling may skip fullplay.navigate entirely.
        for _,observeFlight in ipairs({false,true}) do
            local h=harness();h.api.setEnabled(true)
            h.snapshot.phase="Live";h.snapshot.snapAt=0;h.time=.2
            h.snapshot.offset=Vector3.new(40,0,-40)
            h.snapshot.route={Vector2.new(20,15),Vector2.new(20,70)}
            h.snapshot.passType="Bullet"
            h.root.Position=Vector3.new(58,3,-21)
            assert(h:navigate().direction.X>0,"fixture route must initially steer right")
            h.snapshot.arc={};h.snapshot.passStarted=true;h:tick(.2)
            if observeFlight then assert(h:navigate()==nil) end
            h.snapshot.arc=nil;h.snapshot.phase="RAC";h.snapshot.route=nil
            h.snapshot.carrier=h.character
            h.root.Position=Vector3.new(43,3,-16)
            h.opponentRoot.Position=Vector3.new(50,3,4)
            h.opponentRoot.AssemblyLinearVelocity=Vector3.zero
            local first=h:navigate()
            assert(first and first.direction.X<0,"stale route target pulled first carry toward defender/right")
            local a=h.events[#h.events]
            assert(a.action=="carry" and a.laneSide==-1 and a.targetX<43)
            h.opponentRoot.Position=Vector3.new(60,3,-3);h.time=h.time+.25
            assert(h:navigate())
            local b=h.events[#h.events]
            assert(b.action=="carry" and b.laneSide==-1)
            assert(math.abs(b.targetX-a.targetX)<=Config.SprintSpeed*.05*.8+1e-6,
                "subsequent carry target lost its normal smoothing")
        end
    end)
    test("controller remembers reached cuts across same-round reload only",function()
        local points={Vector2.new(0,15),Vector2.new(8,15),Vector2.new(8,30),Vector2.new(-4,45)}
        local h=harness();h.api.setEnabled(true)
        h.snapshot.phase="Live";h.snapshot.snapAt=-10;h.snapshot.route=points;h.snapshot.passType="Bullet"
        h:tick();h.root.Position=Vector3.new(0,3,15)
        local first=h:navigate();assert(first.direction.X>0 and math.abs(first.direction.Z)<1e-7)
        h.root.Position=Vector3.new(8,3,15)
        local second=h:navigate();assert(second.direction.Z>0 and math.abs(second.direction.X)<1e-7)
        assert(h.api.status().routeWaypoint==3)
        local old=h.api.status();h.api.unload()
        local same=harness({saved="on",previousState=old})
        same.snapshot.phase="Live";same.snapshot.snapAt=-10;same.snapshot.route=points;same.snapshot.passType="Bullet"
        same.root.Position=Vector3.new(8,3,22);same:tick()
        local restored=same:navigate();assert(restored.direction.Z>0 and same.api.status().routeWaypoint==3)
        same.snapshot.arc={};assert(same:navigate()==nil,"route waypoint stole ball-flight movement")
        same.snapshot.arc=nil;same.snapshot.phase="PreSnap";same.snapshot.preSnapEnds=30;same:tick()
        assert(same.api.status().routeWaypoint==2,"new round reused old completed cuts")
    end)
    test("navigation policy errors remain local and recover without disabling assist",function()
        local h=harness();h.api.setEnabled(true);h.snapshot.role="DB"
        local previous=Policy.movement
        Policy.movement=function() error("fixture navigation failure") end
        local ok,directive=pcall(function() return h:navigate() end)
        Policy.movement=previous
        assert(ok and directive==nil and h.api.status().error)
        assert(h.assist and h.api.status().enabled)
        assert(h:navigate(),"later valid navigation should recover")
    end)
    local function finishWR(h,result,catcher)
        h.snapshot.phase="Live";h.snapshot.role="WR";h:tick()
        h.api.onFx({Type="BallResult",Result=result,Catcher=catcher})
    end
    local function newWR(h)
        h.snapshot.phase="Result";h:tick()
        h.snapshot.phase="PreSnap";h.snapshot.role="WR"
        h.snapshot.preSnapEnds=h.time+15;h.boardOpen=true;h:settle()
    end
    test("selection memory is bounded without results and survives only the matching scope",function()
        local h=harness();h.api.setEnabled(true);h:settle()
        for _=1,7 do newWR(h) end
        local memory=h.api.status().routeMemory
        assert(#h.submits==8 and #memory.recentSelections==6 and memory.selectionIndex==8)
        assert(#memory.recentRoutes==0,"unconfirmed submissions became successful outcomes")
        for i,item in ipairs(memory.recentSelections) do
            assert(item.family and item.signature and item.success==nil)
            if i>1 then assert(item.roundKey~=memory.recentSelections[i-1].roundKey) end
        end
        h.boardOpen=true;h:settle()
        assert(h.api.status().routeMemory.selectionIndex==8,"duplicate setup advanced variety state")
        local old=h.api.status();h.api.unload()
        local same=harness({saved="on",previousState=old});same.boardOpen=false;same:tick()
        local restored=same.api.status().routeMemory
        assert(#restored.recentSelections==6 and restored.selectionIndex==8,
            "same-opponent reload lost selection diversity memory")
        assert(restored.recentSelections[6].signature==memory.recentSelections[6].signature)
        local other=harness({saved="on",previousState=old,jobId="job-b"})
        other.boardOpen=false;other:tick()
        assert(#other.api.status().routeMemory.recentSelections==6
            and other.api.status().routeMemory.selectionIndex==8,"same opponent lost fresh cross-job variety state")
        same.opponent.Name="another-opponent";same:tick()
        assert(#same.api.status().routeMemory.recentSelections==0
            and same.api.status().routeMemory.selectionIndex==0,"new opponent inherited variety state")
    end)
    test("failed submission attempts do not advance selection variety",function()
        local h=harness();h.api.setEnabled(true);h.submitError="fixture submission failure"
        for _=1,40 do h:tick(.25) end
        local memory=h.api.status().routeMemory
        assert(h.attempts==3 and #h.submits==0)
        assert(memory.selectionIndex==0 and #memory.recentSelections==0,
            "rejected local submit attempt was remembered as a played route")
        h.submitError=nil;newWR(h)
        assert(h.api.status().routeMemory.selectionIndex==1
            and #h.api.status().routeMemory.recentSelections==1)
    end)
    test("feedback records only own submitted WR plays once with authoritative result",function()
        local h=harness();h.api.setEnabled(true);h:settle()
        finishWR(h,"Swatted")
        local memory=h.api.status().routeMemory
        assert(#memory.recentRoutes==1 and not memory.recentRoutes[1].success)
        assert(memory.recentRoutes[1].result=="Swatted" and memory.recentRoutes[1].family)
        h.api.onFx({Type="BallResult",Result="Swatted"})
        assert(#h.api.status().routeMemory.recentRoutes==1,"same WR result counted twice")
        h.snapshot.role="DB"
        h.api.onFx({Type="BallResult",Result="Intercepted",Catcher=h.character})
        assert(#h.api.status().routeMemory.recentRoutes==1,"DB outcome polluted offense history")
        newWR(h);finishWR(h,"Catch",h.opponent)
        local recent=h.api.status().routeMemory.recentRoutes
        assert(#recent==2 and not recent[#recent].success,"opponent catch was treated as success")
    end)
    test("caught WR route losing the point updates the same outcome once",function()
        local h=harness();h.api.setEnabled(true);h:settle();finishWR(h,"Catch",h.character)
        local before=h.api.status().routeMemory.recentRoutes
        assert(#before==1 and before[1].success)
        local key=before[1].roundKey
        h.snapshot.phase="Result"
        h.api.onMatch({Phase="Result",Result="Tackled",Point="Opp",Role="WR"})
        local recent=h.api.status().routeMemory.recentRoutes
        assert(#recent==1 and recent[1].roundKey==key,"terminal point made a duplicate route outcome")
        assert(recent[1].success==false and recent[1].catchSuccess==true,
            "lost point must retain catch evidence but stop rewarding route success")
        assert(recent[1].result=="Catch" and recent[1].terminalResult=="Tackled"
            and recent[1].terminalAt==h.time,"catch and terminal evidence were not kept separately")
        h.api.onMatch({Phase="Result",Result="Tackled",Point="Opp",Role="WR"})
        assert(#h.api.status().routeMemory.recentRoutes==1,"duplicate terminal packet added another outcome")
    end)
    test("first-down tackle preserves catch evidence but fails the touchdown objective",function()
        local h=harness();h.api.setEnabled(true);h:settle();finishWR(h,"Catch",h.character)
        h.snapshot.phase="Result"
        h.api.onMatch({Phase="Result",Result="Tackled",Role="WR"})
        local recent=h.api.status().routeMemory.recentRoutes
        assert(#recent==1 and recent[1].success==false and recent[1].catchSuccess==true
            and recent[1].terminalResult=="Tackled",
            "a first-down tackle incorrectly rewarded the touchdown objective")
    end)
    test("tackle without BallResult records possession and failure exactly once",function()
        local h=harness();h.api.setEnabled(true);h:settle()
        local key=h.api.status().activeRoute.roundKey
        h.snapshot.phase="Result"
        h.api.onMatch({Phase="Result",Result="Tackled",Role="WR"})
        local first=h.api.status().routeMemory.recentRoutes
        assert(#first==1 and first[1].roundKey==key and first[1].result=="Catch"
            and first[1].catchSuccess==true and first[1].success==false
            and first[1].terminalResult=="Tackled","missing BallResult lost terminal feedback")
        local terminalAt=first[1].terminalAt
        h:tick(.2);h.api.onMatch({Phase="Result",Result="Tackled",Role="WR"})
        h.api.onFx({Type="BallResult",Result="Catch",Catcher=h.character})
        local recent=h.api.status().routeMemory.recentRoutes
        assert(#recent==1 and recent[1].success==false and recent[1].terminalAt==terminalAt,
            "duplicate or delayed catch packet rewrote terminal failure")
    end)
    test("team and testing tackles cannot rewrite own 1v1 catch feedback",function()
        for _,gate in ipairs({"team","testing"}) do
            local h=harness();h.api.setEnabled(true);h:settle();finishWR(h,"Catch",h.character)
            h.snapshot.phase="Result"
            if gate=="team" then h.snapshot.mode="Team" else h.snapshot.testing=true end
            h.api.onMatch({Phase="Result",Result="Tackled",Role="WR"})
            local recent=h.api.status().routeMemory.recentRoutes
            assert(#recent==1 and recent[1].success==true and recent[1].terminalResult==nil,
                gate.." tackle polluted 1v1 route feedback")
        end
    end)
    test("late-bend trial token commits only after submit and survives only its scope",function()
        local original=Policy.chooseRoute
        local seen={}
        Policy.chooseRoute=function(p,...)
            seen[#seen+1]=p.lastLateBendTrialTrigger or "none"
            local c=original(p,...)
            c.experimentalAttempt="late-bend";c.trialTrigger="fixture-trial-token"
            c.experimentalClearanceGap=3.4
            return c
        end
        local ok,err=pcall(function()
            local h=harness();h.api.setEnabled(true);h.submitError="fixture rejection";h:settle()
            assert(h.attempts==1 and h.api.status().routeMemory.lastLateBendTrialTrigger==nil,
                "failed submit consumed trial token")
            h.submitError=nil;h:settle();assert(#h.submits==1)
            local pending=h.api.status()
            local function trial(item)
                assert(item and item.experimentalAttempt=="late-bend"
                    and item.trialTrigger=="fixture-trial-token"
                    and item.experimentalClearanceGap==3.4,"trial descriptor fields were lost")
            end
            trial(pending.activeRoute);trial(pending.routeMemory.recentSelections[1])
            assert(pending.routeMemory.lastLateBendTrialTrigger=="fixture-trial-token")
            h.api.unload()
            local same=harness({saved="on",previousState=pending});same.boardOpen=false;same:tick()
            trial(same.api.status().activeRoute)
            assert(same.api.status().routeMemory.lastLateBendTrialTrigger=="fixture-trial-token")
            finishWR(same,"Swatted");trial(same.api.status().routeMemory.recentRoutes[1])
            newWR(same)
            assert(seen[#seen]=="fixture-trial-token","policy did not receive consumed trial token")
            local old=same.api.status();same.api.unload()
            local other=harness({saved="on",previousState=old,jobId="job-b"})
            other.boardOpen=false;other:tick()
            assert(other.api.status().routeMemory.lastLateBendTrialTrigger=="fixture-trial-token",
                "same opponent lost its consumed trial token across jobs")
            local changed=harness({saved="on",previousState=old});changed.boardOpen=false;changed:tick()
            changed.opponent.Name="another-opponent";changed:tick()
            assert(changed.api.status().routeMemory.lastLateBendTrialTrigger==nil,
                "different opponent inherited trial token")
        end)
        Policy.chooseRoute=original
        assert(ok,err)
    end)
    test("DB and later unrelated WR round results cannot rewrite a previous catch",function()
        local h=harness();h.api.setEnabled(true);h:settle();finishWR(h,"Catch",h.character)
        local key=h.api.status().routeMemory.recentRoutes[1].roundKey
        h.snapshot.phase="Result";h.snapshot.role="DB"
        h.api.onMatch({Phase="Result",Result="Tackled",Point="Opp",Role="DB"})
        assert(h.api.status().routeMemory.recentRoutes[1].success==true,"DB point rewrote WR route")
        h.snapshot.role="WR";h.snapshot.phase="PreSnap";h.snapshot.preSnapEnds=100
        h.boardOpen=false;h:settle()
        h.snapshot.phase="Result"
        h.api.onMatch({Phase="Result",Result="Tackled",Point="Opp",Role="WR"})
        local recent=h.api.status().routeMemory.recentRoutes
        assert(#recent==1 and recent[1].roundKey==key and recent[1].success==true,
            "unrelated unsubmitted WR round rewrote the old route")
    end)
    test("native nil-mode 1v1 tackle updates catch feedback and disk without admitting other modes",function()
        for _,mode in ipairs({"native-nil","1v1","Team","unsupported"}) do
            local h=harness();h.api.setEnabled(true);h:settle();finishWR(h,"Catch",h.character)
            h.snapshot.mode=mode=="native-nil" and nil or mode
            if mode=="native-nil" then h.snapshot.mode=nil end
            h.snapshot.phase="Result"
            h.api.onMatch({Phase="Result",Result="Tackled",Role="WR",Point="Opp"})
            local item=h.api.status().routeMemory.recentRoutes[1]
            local expected=mode=="native-nil" or mode=="1v1"
            assert((item.success==false)==expected,"native mode feedback gate mismatched "..mode)
            assert(item.catchSuccess and (not expected or item.terminalResult=="Tackled"))
            assert(h.memoryDisk.recentRoutes[1].success==item.success,"terminal revision was not saved")
        end
    end)
    test("manual route results do not enter automatic route history",function()
        local h=harness();h.api.setEnabled(true);h.boardOpen=false;h:settle()
        finishWR(h,"Incomplete")
        assert(#h.api.status().routeMemory.recentRoutes==0)
    end)
    test("route history is bounded across repeated WR rounds",function()
        local h=harness();h.api.setEnabled(true);h:settle()
        for i=1,8 do
            finishWR(h,i%2==0 and "Catch" or "Incomplete",i%2==0 and h.character or nil)
            if i<8 then newWR(h) end
        end
        local recent=h.api.status().routeMemory.recentRoutes
        assert(#recent==6,"route history must retain only the latest six outcomes")
        assert(recent[#recent].result=="Catch" and recent[#recent].success)
    end)
    test("fresh opponent learning survives job changes while opponent changes clear it",function()
        local h=harness();h.api.setEnabled(true);h:settle();finishWR(h,"Incomplete")
        local old=h.api.status();h.api.unload()
        local same=harness({saved="on",previousState=old});same.boardOpen=false;same:tick()
        assert(#same.api.status().routeMemory.recentRoutes==1,"valid reload lost route memory")
        local otherJob=harness({saved="on",previousState=old,jobId="job-b"});otherJob.boardOpen=false;otherJob:tick()
        assert(#otherJob.api.status().routeMemory.recentRoutes==1,"same opponent lost fresh cross-job route memory")
        same.opponent.Name="another-opponent";same:tick()
        assert(#same.api.status().routeMemory.recentRoutes==0,"another opponent inherited route memory")
    end)
    local function memoryFixture(extra)
        local record={schema=1,jobId="old-job",opponentKey="fixture-opponent",savedAt=100,
            selectionIndex=1,lastLateBendTrialTrigger="consumed-failures",
            recentRoutes={{pass="Floater",shape="go",depth=24,side=1,success=false,
                result="Swatted",cutCount=0,roundKey="old-round",time=99}},
            recentSelections={{pass="Floater",shape="go",depth=24,side=1,cutCount=0,
                roundKey="old-round",time=98}}}
        for key,value in pairs(extra or {}) do record[key]=value end
        return record
    end
    test("disk learning crosses servers without restoring active play or manufacturing feedback",function()
        local h=harness({time=100,accountId=123});h.api.setEnabled(true);h:settle()
        finishWR(h,"Swatted");newWR(h)
        local saved=h.memoryDisk
        assert(saved.schema==1 and saved.opponentUserId==123 and #saved.recentRoutes==1
            and #saved.recentSelections==2 and saved.selectionIndex==2)
        assert(saved.activeRoute==nil and saved.routeWaypoint==nil and saved.routeRoundKey==nil
            and saved.submitted==nil and saved.enabled==nil,"disk contained active play state")
        -- Even untrusted extra play fields in a disk record must be ignored.
        saved.activeRoute=h.api.status().activeRoute;saved.routeWaypoint=9;saved.submitted=true
        local nextGame=harness({time=200,accountId=123,jobId="new-job",memoryDisk=saved})
        nextGame.boardOpen=false;nextGame:tick()
        local status=nextGame.api.status()
        assert(#status.routeMemory.recentRoutes==1 and #status.routeMemory.recentSelections==2)
        assert(not status.activeRoute and status.routeWaypoint==2 and not status.submitted)
        assert(not status.enabled,"learning file silently enabled full auto")
        finishWR(nextGame,"Swatted")
        assert(#nextGame.api.status().routeMemory.recentRoutes==1,"historical route became an active result")
    end)
    test("disk learning expires after thirty minutes and rejects future or malformed timestamps",function()
        for _,case in ipairs({{age=1800,keep=true},{age=1800.001},{age=-1},{at="100"},{at=-1}}) do
            local record=memoryFixture()
            local now=case.age and 100+case.age or 200
            if case.at~=nil then record.savedAt=case.at end
            local h=harness({time=now,memoryDisk=record});h.boardOpen=false;h:tick(.001)
            -- At the exact boundary, inspect status before advancing time.
            if case.age==1800 then
                h=harness({time=now,memoryDisk=record});h.boardOpen=false
            end
            assert((#h.api.status().routeMemory.recentRoutes==1)==(case.keep==true),
                "TTL fixture admitted or expired the wrong record")
        end
        for _,record in ipairs({"invalid-json",memoryFixture({schema=2})}) do
            local h=harness({time=101,memoryDisk=record});h.boardOpen=false;h:tick()
            assert(#h.api.status().routeMemory.recentRoutes==0)
        end
    end)
    test("opponent identity prefers UserId with protected exact-name fallback",function()
        local cases={{id=123,name="renamed-opponent",storedId=123,keep=true},
            {id=456,name="fixture-opponent",storedId=123},
            {name="fixture-opponent",storedId=123,lookupError="streaming lookup unavailable",keep=true},
            {name="other-opponent",lookupError="lookup unavailable"}}
        for _,case in ipairs(cases) do
            local h=harness({time=101,memoryDisk=memoryFixture({opponentUserId=case.storedId}),
                accountId=case.id,opponentName=case.name,lookupError=case.lookupError})
            h.boardOpen=false;h:tick()
            assert((#h.api.status().routeMemory.recentRoutes==1)==(case.keep==true),
                "identity fixture inherited or lost the wrong opponent")
        end
        local streamed=harness({time=101,memoryDisk=memoryFixture({opponentUserId=123}),
            lookupError="temporarily unavailable"})
        streamed.boardOpen=false;streamed:tick()
        assert(streamed.api.status().routeMemory.opponentUserId==123,"fallback lost known account identity")
        streamed.lookupError=nil;streamed.accountId=456;streamed:tick()
        assert(#streamed.api.status().routeMemory.recentRoutes==0,
            "later mismatching account identity failed to invalidate name fallback")
    end)
    test("disk histories are bounded validated and preserve consumed trial tokens",function()
        local record=memoryFixture({selectionIndex=1e100})
        for i=2,10 do
            record.recentRoutes[i]={pass="Floater",shape="go",depth=24,success=false,result="Swatted",roundKey=tostring(i)}
            record.recentSelections[i]={pass="Floater",shape="go",depth=24,roundKey=tostring(i)}
        end
        record.recentRoutes[10].terminalAt={untrusted=true}
        local h=harness({time=101,memoryDisk=record});h.boardOpen=false;h:tick()
        local m=h.api.status().routeMemory
        assert(#m.recentRoutes==6 and #m.recentSelections==6 and m.recentRoutes[1].roundKey=="5")
        assert(m.selectionIndex==6 and m.lastLateBendTrialTrigger=="consumed-failures")
        assert(m.recentRoutes[6].terminalAt==nil,"nested untrusted descriptor survived")
        h.opponent.Name="new-opponent";h:tick()
        assert(#h.api.status().routeMemory.recentRoutes==0 and h.memoryDisk.opponentKey=="new-opponent"
            and h.memoryDisk.lastLateBendTrialTrigger==nil,"different opponent kept previous learning")
    end)
    test("learning saves only changes and write failure does not interrupt local play",function()
        local h=harness({time=100});h.api.setEnabled(true);h:settle()
        local writes=h.memoryWrites
        for _=1,25 do h:tick();h.api.status() end
        assert(h.memoryWrites==writes,"unchanged heartbeat repeatedly wrote learning")
        finishWR(h,"Catch",h.character);assert(h.memoryWrites==writes+1)
        h.api.onFx({Type="BallResult",Result="Catch",Catcher=h.character})
        assert(h.memoryWrites==writes+1,"duplicate catch rewrote learning")
        h.snapshot.phase="Result";h.api.onMatch({Phase="Result",Result="Tackled"})
        assert(h.memoryWrites==writes+2 and h.memoryDisk.recentRoutes[1].success==false)
        h.api.onMatch({Phase="Result",Result="Tackled"});assert(h.memoryWrites==writes+2)
        h.writeError="fixture disk failure";newWR(h);finishWR(h,"Swatted")
        assert(h.api.status().memorySaveError and h.api.status().enabled
            and #h.api.status().routeMemory.recentRoutes==2,"disk failure interrupted local learning")
    end)
    test("legacy prior state may restore learning only within its original job",function()
        local prior={routeMemory=memoryFixture()};prior.routeMemory.savedAt=nil
        prior.routeMemory.jobId="job-a"
        local same=harness({time=101,previousState=prior});same.boardOpen=false;same:tick()
        assert(#same.api.status().routeMemory.recentRoutes==1)
        local other=harness({time=101,jobId="job-b",previousState=prior});other.boardOpen=false;other:tick()
        assert(#other.api.status().routeMemory.recentRoutes==0,"undated legacy history crossed servers")
    end)
    test("failed learning save retries once on reload and remains visible until recovered",function()
        local h=harness({time=100});h.api.setEnabled(true);h:settle()
        h.writeError="still unwritable";finishWR(h,"Swatted")
        local old=h.api.status();assert(old.memorySaveError)
        local same=harness({time=110,previousState=old,memoryDisk=h.memoryDisk,writeError="still unwritable"})
        same.boardOpen=false;same:tick()
        assert(same.api.status().memorySaveError and same.memoryWriteAttempts==1)
        for _=1,10 do same:tick();same.api.status() end
        assert(same.memoryWriteAttempts==1,"persistent failure created a heartbeat write loop")
        local recovered=harness({time=120,previousState=same.api.status(),memoryDisk=h.memoryDisk})
        recovered.boardOpen=false;recovered:tick()
        assert(not recovered.api.status().memorySaveError and recovered.memoryWrites==1
            and #recovered.memoryDisk.recentRoutes==1,"reload failed to recover unsaved learning")
    end)
    report.fixture="Saved native RouteMath; fixture geometry YD=3, MinX=-30, MaxX=30, GoalZ=120. No server outcome claims."
    Vector2,typeof=oldVector2,oldTypeof
    return report
end
