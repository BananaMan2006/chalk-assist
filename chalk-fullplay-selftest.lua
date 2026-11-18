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
    test("offensive variety preserves native route legality and stamina reachability",function()
        for _,stamina in ipairs({0,15,50,100}) do
            local p=input({stamina=stamina,opponentPosition=Vector3.new(-10,3,40)})
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
            opponentPosition=Vector3.new(f.MidX,4.636868,19.825737)})
        return f,r,p
    end
    local function assertLongPass(c,f,los)
        if c.payload.Pass=="Bullet" then
            assert(c.depth>=16-1e-5 and c.depth<=22+1e-5,"short/overlong Bullet selected")
            assert(math.abs(c.payload.Points[#c.payload.Points].X-c.payload.StartX)>=3*f.YD-1e-5,
                "Bullet route is not genuinely slanted")
            assert(c.plan.Target.Y<=f.GoalZ-2*f.YD+1e-5,"Bullet goes all the way to goal")
        else
            local available=(f.EndZ-math.max(Config.RouteEdgeMargin,1.5)-los)/f.YD
            assert(c.depth>=math.min(16,available)-1e-5,"unnecessarily short Floater selected")
        end
    end
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
    test("DB shadow permits a brief trail and variable lead without a fixed spacing leash",function()
        for _,phase in ipairs({"PreSnap","Live"}) do
            for _,z in ipairs({24,26,27,28.5,30,32,42,43.5,45,70}) do
                local p=input({role="DB",phase=phase,position=Vector3.new(0,3,z),
                    opponentPosition=Vector3.new(0,3,30)})
                local d=move(p)
                assert(d and d.kind=="shadow")
                local gap=d.target.Z-p.opponentPosition.Z
                assert(gap>=-Field.YD-1e-6 and gap<=5*Field.YD+1e-6,
                    "DB left the flexible coverage band in "..phase)
                if z>=27 and z<=45 then near(d.target.Z,z)
                elseif z<27 then near(d.target.Z,30) end
                assert(not d.sprint,"stationary or pre-snap coverage burned sprint")
                inBounds(d.target)
            end
        end
    end)
    test("DB closes excessive native spawn cushion by walking and can reverse laterally",function()
        local p=input({role="DB",phase="Live",offset=Vector3.new(0,0,-40),
            position=Vector3.new(18.89393,4.63687,19.82446),
            opponentPosition=Vector3.new(18.89391,4.63679,-20.95496)})
        local d=move(p)
        near(d.target.Z,p.opponentPosition.Z+5*Field.YD)
        assert(d.target.Z<p.position.Z and not d.sprint,"deep native gap should close at normal speed")
        p=input({role="DB",phase="Live",position=Vector3.new(0,3,43),
            opponentPosition=Vector3.new(6,3,30),opponentVelocity=Vector3.new(27,0,0)})
        local right=move(p)
        p.opponentPosition=Vector3.new(-6,3,30);p.opponentVelocity=Vector3.new(-27,0,0)
        p.priorTarget=right.target
        local left=move(p)
        assert(right.target.X>0 and left.target.X<0,"coverage retained the old lateral direction")
        near(right.target.Z,43);near(left.target.Z,43)
        p.opponentPosition=Vector3.new(24,3,20);p.opponentVelocity=Vector3.new(0,0,-20)
        assert(not move(p).sprint,"retreating WR drained sprint while DB closed excessive depth")
    end)
    test("DB lets an advancing WR enter the flexible band without spending sprint",function()
        for _,speed in ipairs({12,20,27}) do
            for _,gap in ipairs({-1,-.5,0,1,2,4,4.5,5}) do
                for _,activeSprint in ipairs({false,true}) do
                    local p=input({role="DB",phase="Live",position=Vector3.new(0,3,30+gap*Field.YD),
                        opponentPosition=Vector3.new(0,3,30),opponentVelocity=Vector3.new(0,0,speed),
                        stamina=100,sprintOn=activeSprint})
                    local d=move(p)
                    assert(d and not d.sprint,"routine "..gap.."yd coverage sprinted at WR speed "..speed)
                    if gap<1 then near(d.target.Z,math.max(p.position.Z,30+speed*.25))
                    else near(d.target.Z,p.position.Z) end
                    inBounds(d.target)
                end
            end
        end
    end)
    test("DB follows an advancing WR with a short motion lead while walking",function()
        for _,gap in ipairs({-1.01,-1.5,-2}) do
            local p=input({role="DB",phase="Live",position=Vector3.new(0,3,30+gap*Field.YD),
                opponentPosition=Vector3.new(0,3,30),opponentVelocity=Vector3.new(0,0,27),
                stamina=100,sprintOn=true})
            local d=move(p)
            near(d.target.Z,p.opponentPosition.Z+27*.25)
            assert(not d.sprint,"a modest trail spent sprint merely to restore spacing")
        end
    end)
    test("DB walks with equal-speed downfield motion instead of waiting for a persistent trail",function()
        local p=input({role="DB",phase="Live",position=Vector3.new(0,3,45),
            opponentPosition=Vector3.new(0,3,30),opponentVelocity=Vector3.new(0,0,20),
            stamina=100,sprintOn=false})
        local dt=.02
        for _=1,150 do
            local d=move(p)
            assert(not d.sprint,"ordinary equal-speed following burned sprint")
            local delta=(d.target-p.position)*Vector3.new(1,0,1)
            if delta.Magnitude>d.stopDistance then
                p.position=p.position+delta.Unit*math.min(delta.Magnitude,Config.RunSpeed*dt)
            end
            p.opponentPosition=p.opponentPosition+p.opponentVelocity*dt
        end
        local gap=p.position.Z-p.opponentPosition.Z
        assert(gap>=-.25*Field.YD and gap<=Field.YD,
            "walk-follow retained the full trailing allowance or imposed a large lead")
    end)
    test("DB downfield recovery uses normal reserve and releases after regaining half a yard",function()
        local p=input({role="DB",phase="Live",position=Vector3.new(0,3,89),
            opponentPosition=Vector3.new(0,3,90),opponentVelocity=Vector3.new(0,0,20)})
        for _,case in ipairs({{74,false,false},{75,false,true},{61,true,true},{60,true,false}}) do
            p.stamina=case[1];p.sprintOn=case[2]
            assert(move(p).sprint==case[3],"downfield recovery bypassed normal stamina reserve")
        end
        p.stamina=100;p.position=Vector3.new(0,3,90);p.sprintOn=false
        assert(not move(p).sprint,"level DB began an unnecessary recovery burst")
        p.sprintOn=true
        assert(move(p).sprint,"active recovery stopped at level without its small hysteresis band")
        p.position=Vector3.new(0,3,91.5)
        assert(not move(p).sprint,"downfield recovery kept sprinting beyond its release threshold")
        p.position=Vector3.new(0,3,83);p.opponentPosition=Vector3.new(0,3,84);p.sprintOn=false
        assert(move(p).sprint,"recovery missed the last-twelve-yard boundary")
        p.position=Vector3.new(0,3,82.9);p.opponentPosition=Vector3.new(0,3,83.9)
        assert(not move(p).sprint,"late-field recovery leaked into the early loose band")
    end)
    test("DB walk-follow and downfield recovery ignore retreating feints and yield to the throw",function()
        local p=input({role="DB",phase="Live",position=Vector3.new(0,3,89),
            opponentPosition=Vector3.new(0,3,90),sprintOn=true})
        for _,velocity in ipairs({Vector3.zero,Vector3.new(20,0,0),Vector3.new(0,0,-20)}) do
            p.opponentVelocity=velocity
            local d=move(p)
            near(d.target.Z,p.position.Z)
            assert(not d.sprint,"stationary/lateral/retreating motion spent downfield reserve")
        end
        p.opponentVelocity=Vector3.new(0,0,20);p.phase="PreSnap"
        near(move(p).target.Z,p.position.Z);assert(not move(p).sprint)
        p.phase="Live";p.ballActive=true;assert(move(p)==nil)
        p.ballActive=false;p.passStarted=true;assert(move(p)==nil)
    end)
    test("DB lateral deadband avoids copying small WR feints but follows a real crossing",function()
        local p=input({role="DB",phase="Live",position=Vector3.new(0,3,43.5),sprintOn=true})
        for _,x in ipairs({-2.9,-1,1,2.9}) do
            p.opponentPosition=Vector3.new(x,3,30)
            local d=move(p);near(d.target.X,0)
            assert(not d.sprint,"small lateral fake restarted sprint")
        end
        p.opponentPosition=Vector3.new(12,3,30)
        local right=move(p)
        assert(right.target.X>0 and right.target.X<12,"real crossing did not retain lateral space")
        p.opponentPosition=Vector3.new(-12,3,30)
        local left=move(p)
        assert(left.target.X<0 and left.target.X>-12,"opposite crossing retained the old direction")
    end)
    test("DB walks toward a clear lateral crossing on either side without spending reserve",function()
        for _,side in ipairs({-1,1}) do
            for _,stamina in ipairs({0,60,74,100}) do
                local p=input({role="DB",phase="Live",position=Vector3.new(0,3,31),
                    opponentPosition=Vector3.new(side*.75*Field.YD,3,30),
                    opponentVelocity=Vector3.new(side*20,0,0),stamina=stamina})
                local d=move(p)
                near(d.target.X,p.opponentPosition.X+side*20*.25)
                near(d.target.Z,p.position.Z)
                assert(not d.sprint,"lateral walking borrowed sprint reserve")
                assert((d.target-p.position).Magnitude>d.stopDistance,"observed crossing froze inside old deadband")
            end
        end
    end)
    test("DB lateral lead ignores tiny feints returning receivers and stopped motion",function()
        for _,side in ipairs({-1,1}) do
            local p=input({role="DB",phase="Live",position=Vector3.new(0,3,31),
                opponentVelocity=Vector3.new(side*27,0,0)})
            for _,gap in ipairs({.1,.49,.5}) do
                p.opponentPosition=Vector3.new(side*gap*Field.YD,3,30)
                near(move(p).target.X,0)
            end
            p.opponentPosition=Vector3.new(side*.75*Field.YD,3,30)
            for _,speed in ipairs({-27,0,10}) do
                p.opponentVelocity=Vector3.new(side*speed,0,0)
                near(move(p).target.X,0)
            end
            p.opponentVelocity=Vector3.new(side*27,0,0);p.phase="PreSnap"
            near(move(p).target.X,0)
            p.phase="Live";p.ballActive=true;assert(move(p)==nil)
        end
    end)
    test("DB lateral walking follows native-speed crossings without stop-start or reversal",function()
        for _,side in ipairs({-1,1}) do
            for _,speed in ipairs({20,27}) do
                local p=input({role="DB",phase="Live",position=Vector3.new(0,3,31),
                    opponentPosition=Vector3.new(side*.75*Field.YD,3,30),
                    opponentVelocity=Vector3.new(side*speed,0,0),stamina=100})
                local dt=.01
                for _=1,60 do
                    local d=move(p)
                    local delta=(d.target-p.position)*Vector3.new(1,0,1)
                    assert(delta.Magnitude>d.stopDistance and delta.X*side>0,
                        "steady native crossing stopped or reversed lateral movement")
                    assert(not d.sprint,"brief native crossing unnecessarily sprinted")
                    p.position=p.position+delta.Unit*Config.RunSpeed*dt
                    p.opponentPosition=p.opponentPosition+p.opponentVelocity*dt
                end
            end
        end
    end)
    test("DB lateral lead retains field clamps goal guard and retreat-safe sprint behavior",function()
        for _,side in ipairs({-1,1}) do
            local p=input({role="DB",phase="Live",position=Vector3.new(side*22,3,114),
                opponentPosition=Vector3.new(side*26,3,110),
                opponentVelocity=Vector3.new(side*20,0,-3),stamina=100,sprintOn=true})
            local d=move(p)
            inBounds(d.target)
            near(d.target.X,side*(Field.MaxX-Field.YD*.75))
            near(d.target.Z,p.position.Z)
            assert(not d.sprint,"retreating lateral crossing bypassed sprint conservation")
        end
    end)
    test("recorded 9173 cut begins walking before the old full-yard gap opens",function()
        local f={MinX=-30.2121302485466,MaxX=67.99998158216476,MidX=18.8939256668,
            BackZ=-44.012135207653046,EndZ=152.4120985865593,LOSZ=-19.45910851670435,
            GoalZ=103.3060463,YD=4.9106056,TurfY=1.63686865568161}
        local p=input({role="DB",phase="Live",position=Vector3.new(11.273431777954102,4.636868,60.57362365722656),
            opponentPosition=Vector3.new(16.146072387695312,4.636789,59.03019714355469),
            opponentVelocity=Vector3.new(24.345457077026367,0,-.009150903671979904),stamina=100})
        assert(p.opponentPosition.X-p.position.X<f.YD,"fixture must stay inside old deadband")
        local d=Policy.movement(p,Config,f,RouteMath)
        assert(d.target.X>p.opponentPosition.X and (d.target-p.position).Magnitude>d.stopDistance)
        near(d.target.Z,p.position.Z);assert(not d.sprint)
    end)
    test("DB recovery reserves use separate start and stop thresholds",function()
        local p=input({role="DB",phase="Live",position=Vector3.new(0,3,23),
            opponentPosition=Vector3.new(0,3,30),opponentVelocity=Vector3.new(0,0,12)})
        for _,case in ipairs({{74,false,false},{75,false,true},{61,true,true},
            {60,true,false},{70,false,false},{75,false,true}}) do
            p.stamina=case[1];p.sprintOn=case[2]
            assert(move(p).sprint==case[3],"routine reserve boundary failed at "..case[1])
        end
        p.position=Vector3.new(0,3,20)
        for _,case in ipairs({{49,false,false},{50,false,true},{36,true,true},
            {35,true,false},{0,true,false}}) do
            p.stamina=case[1];p.sprintOn=case[2]
            assert(move(p).sprint==case[3],"urgent reserve boundary failed at "..case[1])
        end
        p.position=Vector3.new(0,3,29);p.stamina=100;p.sprintOn=false
        assert(not move(p).sprint,"briefly trailing DB requested a needless recovery burst")
        p.position=Vector3.new(0,3,20);p.opponentVelocity=Vector3.new(0,0,-10)
        assert(not move(p).sprint,"retreating WR triggered sprint while returning toward the DB")
        p.opponentVelocity=Vector3.new(0,0,12)
        p.stamina=100;p.sprintOn=true;p.phase="PreSnap"
        assert(not move(p).sprint,"urgent geometry bypassed pre-snap walking")
        p.phase="Live";p.ballActive=true;assert(move(p)==nil,"prethrow reserve policy took flight control")
        p.ballActive=false;p.phase="RAC";p.enemyCarrier=true;p.stamina=0
        assert(move(p).kind=="pursue" and move(p).sprint,
            "prethrow reserve restriction leaked into confirmed carrier pursuit")
    end)
    test("DB protects the last six yards to goal with a smaller goal-side guard",function()
        for _,offset in ipairs({Vector3.zero,Vector3.new(0,0,-40)}) do
            for _,z in ipairs({108,110,111,113,117,119}) do
                local p=input({role="DB",phase="Live",offset=offset,
                    position=Vector3.new(0,3,z)+offset,
                    opponentPosition=Vector3.new(0,3,110)+offset,
                    opponentVelocity=Vector3.new(0,0,12),stamina=50})
                local d=move(p)
                local gap=d.target.Z-p.opponentPosition.Z
                assert(gap>=Field.YD and gap<=3*Field.YD,"goal-line guard lost safe bounds")
                if z<113 then assert(d.sprint,"imminent goal-line bypass failed to use reserved sprint")
                else assert(not d.sprint,"comfortable goal-line guard wasted sprint") end
                inBounds(d.target,offset)
                p.phase="PreSnap";assert(not move(p).sprint,"goal-line urgency bypassed pre-snap walking")
            end
        end
    end)
    test("recorded late-field retreats do not make DB walk farther from the receiver",function()
        local f={MinX=-30.2121302485466,MaxX=67.99998158216476,MidX=18.8939256668,
            BackZ=-44.012135207653046,EndZ=152.4120985865593,LOSZ=-19.45910851670435,
            GoalZ=103.3060463,YD=4.9106056,TurfY=1.63686865568161}
        for _,row in ipairs({
            {x=16.967350006103516,z=89.7415542602539,ox=21.2724609375,oz=87.54505157470703,
                vx=27.544052124023438,vz=-18.06834602355957,stamina=51},
            {x=21.878170013427734,z=89.45246887207031,ox=17.80388069152832,oz=87.48826599121094,
                vx=-26.572818756103516,vz=-4.813174247741699,stamina=45}}) do
            local p=input({role="DB",phase="Live",position=Vector3.new(row.x,4.636868,row.z),
                opponentPosition=Vector3.new(row.ox,4.636789,row.oz),
                opponentVelocity=Vector3.new(row.vx,0,row.vz),stamina=row.stamina,sprintOn=true})
            local d=Policy.movement(p,Config,f,RouteMath)
            near(d.target.Z,p.position.Z)
            assert(not d.sprint,"retreat started sprint")
            assert((d.target.X-p.position.X)*row.vx>0,"retreat guard suppressed lateral coverage")
        end
    end)
    test("retreat guard preserves advancing urgency normal coverage and phase priority",function()
        local p=input({role="DB",phase="Live",position=Vector3.new(0,3,111),
            opponentPosition=Vector3.new(0,3,110),stamina=50})
        p.opponentVelocity=Vector3.new(0,0,-2.001)
        near(move(p).target.Z,111);assert(not move(p).sprint)
        p.opponentVelocity=Vector3.new(0,0,-2)
        near(move(p).target.Z,113)
        p.opponentVelocity=Vector3.new(0,0,12)
        near(move(p).target.Z,113);assert(move(p).sprint,"advancing goal threat lost reserve protection")
        p.opponentVelocity=Vector3.new(0,0,-12);p.phase="PreSnap"
        near(move(p).target.Z,113);assert(not move(p).sprint)
        p.phase="Live";p.position=Vector3.new(0,3,145)
        near(move(p).target.Z,119);assert(not move(p).sprint,"closing excess depth spent sprint")
        p.position=Vector3.new(0,3,25);p.opponentPosition=Vector3.new(0,3,30)
        near(move(p).target.Z,30)
        p.ballActive=true;assert(move(p)==nil)
        p.ballActive=false;p.passStarted=true;assert(move(p)==nil)
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
        h.root.Position=Vector3.new(0,3,23);h.opponentRoot.Position=Vector3.new(0,3,30)
        h.opponentRoot.AssemblyLinearVelocity=Vector3.new(0,0,12)
        h.attrs.Stamina=65;h.attrs.SprintOn=false
        local walking=h:navigate();assert(walking and not walking.sprint)
        h.attrs.SprintOn=true
        local keeping=h:navigate();assert(keeping and keeping.sprint,
            "controller omitted the actual active sprint state")
        h.attrs.Stamina=60;assert(not h:navigate().sprint)
        h.attrs.Stamina=65;h.attrs.SprintOn=false;assert(not h:navigate().sprint)
        h.attrs.Stamina=75;assert(h:navigate().sprint)
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
