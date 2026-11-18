-- Explicit geometry and native-action fixtures, not server tackle/physics tests.
return function(create)
    local report={total=0,passed=0,failed=0,results={}}
    local Config={SprintSpeed=27,Moves={Juke={Cost=20,Cooldown=.9,Speed=42,Time=.18}},
        Tackle={GrabRange=3.5,GrabSlack=2}}
    local Field={MinX=-30,MaxX=30,BackZ=0,EndZ=140,GoalZ=120,YD=3}
    local function test(name,body)
        report.total=report.total+1
        local ok,err=pcall(body)
        report[ok and "passed" or "failed"]=report[ok and "passed" or "failed"]+1
        report.results[#report.results+1]={name=name,passed=ok,error=not ok and tostring(err) or nil}
    end
    local function input(extra)
        local p={mode="1v1",role="WR",phase="RAC",carrierIsMe=true,upright=true,
            grounded=true,healthy=true,now=10,stamina=100,
            position=Vector3.new(0,3,40),velocity=Vector3.new(0,0,20),rightDirection=Vector3.new(1,0,0),
            opponentPosition=Vector3.new(2,3,52),opponentVelocity=Vector3.new(0,0,-10)}
        for k,v in pairs(extra or {}) do p[k]=v end
        return p
    end
    local policy=create({Config=Config,Field=Field,Moves={}})
    local function decide(p) return policy.decide(p) end
    test("near closing defender selects native juke away from pressure",function()
        local c=assert(decide(input()))
        assert(c.action=="juke" and c.sign==-1 and c.endpoint.X<0)
        assert(c.duration==.18 and c.cooldown==.9 and c.contactIn<=.45)
        assert(math.abs(c.endpoint.X+42*.18)<1e-9)
        assert(math.abs(c.endpoint.Z-(40+20*.6000000238418579*.18))<1e-9)
        assert(c.minClearance>5.75)
    end)
    test("distant separating and harmless crossing defenders do not cause a juke",function()
        assert(not decide(input({opponentPosition=Vector3.new(0,3,80)})))
        assert(not decide(input({opponentVelocity=Vector3.new(0,0,30)})))
        assert(not decide(input({opponentPosition=Vector3.new(10,3,52)})))
        assert(not decide(input({opponentPosition=Vector3.new(2,10,52)})))
    end)
    test("possession phase health air and team gates never request offensive moves",function()
        for _,change in ipairs({{carrierIsMe=false},{enemyCarrier=true},{role="DB"},{phase="Live"},
            {phase="Run"},{mode="Team"},{upright=false},{grounded=false},{healthy=false},
            {ballActive=true},{testing=true},{enabled=false}}) do
            assert(not decide(input(change)))
        end
    end)
    test("stamina retains ten units after native cost and cooldown blocks retries",function()
        assert(not decide(input({stamina=29})))
        assert(decide(input({stamina=30})))
        assert(not decide(input({nextAttempt=10.01})))
        assert(decide(input({nextAttempt=10})))
    end)
    test("sideline choice uses the open side and rejects unsafe starting space",function()
        local p=input({position=Vector3.new(27,3,40),opponentPosition=Vector3.new(29,3,52)})
        local c=assert(decide(p))
        assert(c.sign==-1 and c.endpoint.X<27)
        p.position=Vector3.new(29,3,40)
        assert(not decide(p))
    end)
    test("blocked preferred path chooses clear alternative and both blocked yields none",function()
        local p=input({clipDistance=function(_,direction,distance)
            return direction.X<0 and 0 or distance
        end})
        assert(assert(decide(p)).sign==1)
        p.clipDistance=function() return 0 end
        assert(not decide(p))
        p.clipDistance=function() error("fixture raycast failure") end
        assert(not decide(p))
    end)
    test("field translation preserves decision and world geometry overrides base bounds",function()
        local p=input();local a=assert(decide(p));local offset=Vector3.new(100,0,-200)
        p.position=p.position+offset;p.opponentPosition=p.opponentPosition+offset;p.offset=offset
        local b=assert(decide(p))
        assert(a.sign==b.sign and (b.endpoint-a.endpoint-offset).Magnitude<1e-8)
        p.offset=nil;p.geo={MinX=70,MaxX=130,BackZ=-200,EndZ=-60}
        assert(assert(decide(p)).sign==a.sign)
    end)
    test("invalid vectors and another burst speed fail closed",function()
        assert(not decide(input({velocity=Vector3.new(0,0,100)})))
        assert(not decide(input({rightDirection=Vector3.zero})))
        assert(not decide(input({position=Vector3.new(0/0,3,40)})))
        assert(not decide(input({now=0/0})))
    end)
    local function harness(behavior)
        local h={calls={},logs={},stamina=100,upright=true}
        h.root={Position=Vector3.new(0,3,40),AssemblyLinearVelocity=Vector3.new(0,0,20),
            CFrame={RightVector=Vector3.new(1,0,0)}}
        function h.root:FindFirstChild(name) return name=="Burst" and self.burst or nil end
        h.humanoid={Health=100,WalkSpeed=27,PlatformStand=false,FloorMaterial=Enum.Material.Grass}
        h.character={}
        h.enemyRoot={Position=Vector3.new(2,3,52),AssemblyLinearVelocity=Vector3.new(0,0,-10)}
        h.enemyHum={Health=100,PlatformStand=false}
        h.enemy={FindFirstChild=function(_,name) return name=="HumanoidRootPart" and h.enemyRoot end,
            FindFirstChildOfClass=function(_,name) return name=="Humanoid" and h.enemyHum end}
        h.player={Character=h.character,GetAttribute=function(_,name) return name=="Stamina" and h.stamina end}
        h.snapshot={enabled=true,mode="1v1",phase="RAC",role="WR",carrier=h.character,opponent=h.enemy}
        h.runtime={Config=Config,Field=Field,player=h.player,Moves={Upright=function() return h.upright end},
            clippedDistance=function(_,_,distance) return distance end,
            log=function(kind,data) h.logs[#h.logs+1]={kind=kind,data=data} end}
        if behavior~="unavailable" then
            h.runtime.nativeJuke=function(sign)
                h.calls[#h.calls+1]=sign
                if behavior=="error" then error("fixture native rejection") end
                if behavior~="unconfirmed" then h.root.burst={} end
                return nil
            end
        end
        h.api=create(h.runtime)
        function h:update(now) return self.api.update(self.snapshot,self.root,self.humanoid,now or 10) end
        return h
    end
    test("only an observed native burst owns movement for a bounded duration",function()
        local h=harness()
        local position,velocity,speed=h.root.Position,h.root.AssemblyLinearVelocity,h.humanoid.WalkSpeed
        assert(h:update(10));assert(#h.calls==1 and h.calls[1]==-1)
        local requested=h.logs[#h.logs].data
        assert(requested.staminaBefore==100 and requested.staminaAfter==100 and requested.staminaAfterImmediate)
        assert(h:update(10.1) and #h.calls==1)
        h.stamina=80
        assert(not h:update(10.23) and #h.calls==1)
        assert(h.logs[#h.logs].kind=="carrierMoveEnd" and h.logs[#h.logs].data.staminaBefore==100
            and h.logs[#h.logs].data.staminaAfter==80,"post-burst telemetry lost observed stamina change")
        assert(h.api.status().observedBursts==1 and h.api.status().lastOutcome=="burstObserved")
        assert(h.root.Position==position and h.root.AssemblyLinearVelocity==velocity and h.humanoid.WalkSpeed==speed,
            "helper wrote movement directly instead of invoking native action")
    end)
    test("native nil without Burst is unconfirmed and never holds movement",function()
        local h=harness("unconfirmed")
        assert(not h:update(10) and #h.calls==1)
        assert(not h:update(10.2) and #h.calls==1)
        assert(h.api.status().lastOutcome=="unconfirmed" and h.api.status().observedBursts==0)
        assert(not h:update(11.01) and #h.calls==2)
    end)
    test("native error is isolated and rate limited while navigation can continue",function()
        local h=harness("error")
        assert(not h:update(10) and #h.calls==1)
        assert(h.api.status().error and not h:update(10.5) and #h.calls==1)
    end)
    test("missing native action or existing unrelated burst never invokes juke",function()
        local h=harness("unavailable")
        assert(not h:update() and not h.api.status().available)
        h=harness();h.root.burst={}
        assert(not h:update() and #h.calls==0)
    end)
    test("native one-on-one context without Mode still permits confirmed WR RAC",function()
        local h=harness();h.snapshot.mode=nil
        assert(h:update() and #h.calls==1)
        for _,change in ipairs({{mode="Team"},{role="TWR"},{phase="Run"}}) do
            local blocked=harness();blocked.snapshot.mode=nil
            for key,value in pairs(change) do blocked.snapshot[key]=value end
            assert(not blocked:update() and #blocked.calls==0)
        end
    end)
    test("confirmed carrier and native upright gates are checked before action",function()
        for _,gate in ipairs({"otherCarrier","missingCarrier","air","fallen","nativeHold","defenderDead","disabled"}) do
            local h=harness()
            if gate=="otherCarrier" then h.snapshot.carrier=h.enemy
            elseif gate=="missingCarrier" then h.snapshot.carrier=nil
            elseif gate=="air" then h.humanoid.FloorMaterial=Enum.Material.Air
            elseif gate=="fallen" then h.humanoid.PlatformStand=true
            elseif gate=="nativeHold" then h.upright=false
            elseif gate=="defenderDead" then h.enemyHum.Health=0
            else h.snapshot.enabled=false end
            assert(not h:update() and #h.calls==0,gate.." invoked native action")
        end
    end)
    test("moving diving tackler remains a threat despite PlatformStand",function()
        local h=harness();h.enemyHum.PlatformStand=true
        h.enemyRoot.AssemblyLinearVelocity=Vector3.new(0,0,-35)
        assert(h:update() and #h.calls==1,"native dive's PlatformStand suppressed evasion")
        local event=h.logs[#h.logs].data
        assert(event.opponentPlatformStand==true and event.opponentVelocity.z==-35)
        local away=harness();away.enemyHum.PlatformStand=true
        away.enemyRoot.AssemblyLinearVelocity=Vector3.new(0,0,35)
        assert(not away:update() and #away.calls==0,"separating dive caused unnecessary evasion")
        local down=harness();down.enemyHum.PlatformStand=true
        down.enemyRoot.AssemblyLinearVelocity=Vector3.zero
        assert(not down:update() and #down.calls==0,"stationary downed defender spent evasion stamina")
    end)
    test("possession loss missing burst cancel and unload release ownership without resetting cooldown",function()
        local h=harness();assert(h:update(10))
        h.snapshot.carrier=nil;assert(not h:update(10.05) and not h.api.status().active)
        h.snapshot.carrier=h.character;h.root.burst=nil
        assert(not h:update(10.2) and #h.calls==1)
        assert(h:update(11.01) and #h.calls==2)
        h.root.burst=nil;assert(not h:update(11.05))
        h.api.cancel();assert(not h:update(11.2) and #h.calls==2)
        h.api.unload();assert(not h:update(15) and #h.calls==2)
    end)
    report.fixture="Native Juke numeric configuration with explicit positions; no server acceptance, collision physics, or tackle outcome simulation."
    return report
end
