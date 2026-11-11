---------------------------------------- game
--[[
Find the city: every round names a real city. Fly there (the world map on X
helps), hover over it and land with Z. Faster means more points; the compass
hint (A) costs points.

Buttons: up fly forward, down brake/reverse, left/right turn (the world
         rotates under the copter), Z (btn 4) land, X (btn 5) world map,
         A (btn 6) compass hint, S (btn 7) hold for turbo.

The copter flies on a unit sphere: P.p is its position, P.h its heading
(unit tangent vector) and P.r = h x p points to the right of the screen.
]]

ROUNDS=10
SPEED,TURBO=1.6,5   -- pixels per frame
TURN=0.035          -- radians per frame

local floor,abs=math.floor,math.abs

-- G: game state; P: the copter
G={mode="boot",t=0}
P={p={1,0,0},h={0,0,1},r={0,1,0},v=0,turn=0,pitch=0,ph=0}

--- Parse CITY_DATA into CITIES: name, country, lat, lon, fame, kind,
-- row coordinate r and longitude fraction lx.
function load_cities()
  CITIES={}
  for line in CITY_DATA:gmatch("[^\n]+") do
    local name,ci,lat,lon,fame,kind=line:match("^(.-);(%d+);([-%d.]+);([-%d.]+);(%d);(%d)$")
    if name then
      lat,lon=tonumber(lat),tonumber(lon)
      local x,y,z=lat2vec(lat,lon)
      CITIES[#CITIES+1]={name=name,country=COUNTRIES[tonumber(ci)],lat=lat,lon=lon,
        fame=tonumber(fame),kind=tonumber(kind),x=x,y=y,z=z}
    end
  end
end

--- Unit vector of a latitude/longitude in degrees.
function lat2vec(lat,lon)
  local a,b=math.rad(lat),math.rad(lon)
  return math.cos(a)*math.cos(b),math.cos(a)*math.sin(b),math.sin(a)
end

--- Latitude/longitude of the copter in degrees.
function copter_pos()
  local p=P.p
  return math.deg(math.asin(math.max(-1,math.min(1,p[3])))),math.deg(math.atan(p[2],p[1]))
end

--- Right vector r = h x p, the screen's x axis.
local function update_right()
  local p,h=P.p,P.h
  P.r={h[2]*p[3]-h[3]*p[2],h[3]*p[1]-h[1]*p[3],h[1]*p[2]-h[2]*p[1]}
end

--- Put the copter above a city, facing north.
function place_at(c)
  local a,b=math.rad(c.lat),math.rad(c.lon)
  P.p={c.x,c.y,c.z}
  P.h={-math.sin(a)*math.cos(b),-math.sin(a)*math.sin(b),math.cos(a)}
  P.v,P.turn,P.pitch=0,0,0
  update_right()
end

--- Pick the next target: famous cities first, harder ones in later rounds,
-- never one visited this game or closer than 800 km.
function next_target()
  local maxfame=G.round<=3 and 0 or G.round<=7 and 1 or 2
  local lat,lon=copter_pos()
  local pool={}
  for _,c in ipairs(CITIES) do
    if c.fame<=maxfame and not G.used[c] and geo(lat,lon,c.lat,c.lon)>800 then
      pool[#pool+1]=c
    end
  end
  local c=pool[math.random(#pool)]
  G.used[c]=true
  G.target=c
  G.rtime=0
  G.hints=0
  G.hint_t=0
  msg("Find "..c.name..", "..c.country.."!",240)
end

function msg(s,t)
  G.msg=s
  G.msg_t=t or 150
end

function new_game()
  -- TIC-80 starts Lua's random generator with a fixed seed: mix in the
  -- clock and the time spent on the title screen. (The terrain's texture
  -- pattern RND was made at load time and stays the same between runs.)
  math.randomseed((tstamp and floor(tstamp()) or 0)+floor(time()))
  G.round=1
  G.score=0
  G.used={}
  local famous={}
  for _,c in ipairs(CITIES) do
    if c.fame==0 then famous[#famous+1]=c end
  end
  local start=famous[math.random(#famous)]
  G.used[start]=true
  place_at(start)
  G.mode="fly"
  next_target()
end

--- City under the copter (within a few pixels), or nil.
function city_below()
  local best,bd=nil,7*7
  for _,c in ipairs(VISIBLE) do
    local dx,dy=c.sx-CX,c.sy-CY
    local d=dx*dx+dy*dy
    if d<bd then best,bd=c,d end
  end
  return best
end

--- Advance the copter: turn the heading around p, then fly d radians
-- along the great circle in the heading direction.
function move(turn,d)
  local p,h,r=P.p,P.h,P.r
  local c,s=math.cos(turn),math.sin(turn)
  h={h[1]*c+r[1]*s,h[2]*c+r[2]*s,h[3]*c+r[3]*s}
  c,s=math.cos(d),math.sin(d)
  local np={p[1]*c+h[1]*s,p[2]*c+h[2]*s,p[3]*c+h[3]*s}
  local nh={h[1]*c-p[1]*s,h[2]*c-p[2]*s,h[3]*c-p[3]*s}
  -- keep them unit length and perpendicular despite rounding
  local l=math.sqrt(np[1]^2+np[2]^2+np[3]^2)
  np={np[1]/l,np[2]/l,np[3]/l}
  local dp=nh[1]*np[1]+nh[2]*np[2]+nh[3]*np[3]
  nh={nh[1]-dp*np[1],nh[2]-dp*np[2],nh[3]-dp*np[3]}
  l=math.sqrt(nh[1]^2+nh[2]^2+nh[3]^2)
  P.p,P.h=np,{nh[1]/l,nh[2]/l,nh[3]/l}
  update_right()
end

--- Fly from the arrow keys: up/down speed, left/right turn, with inertia.
function fly()
  local want=0
  if btn(0) then want=btn(7) and TURBO or SPEED
  elseif btn(1) then want=-SPEED*0.4 end
  local dv=(want-P.v)*0.05
  P.v=P.v+dv
  -- lean forward when speeding up and at speed, back when braking
  local lean=0.07*P.v+3.5*dv
  if lean>0.45 then lean=0.45 elseif lean<-0.35 then lean=-0.35 end
  P.pitch=P.pitch+(lean-P.pitch)*0.08
  local tr=0
  if btn(2) then tr=-1 end
  if btn(3) then tr=1 end
  P.turn=P.turn+(tr*TURN-P.turn)*0.2
  move(P.turn,P.v/SCALE)
  P.ph=P.ph+1
end

--- Cities on screen this frame, with screen positions.
function collect_cities()
  VISIBLE={}
  for _,c in ipairs(CITIES) do
    local sx,sy=to_screen(c.x,c.y,c.z)
    if sx and sx>-40 and sx<280 and sy>-8 and sy<144 then
      c.sx,c.sy=sx,sy
      VISIBLE[#VISIBLE+1]=c
    end
  end
  -- most important first, so their labels win
  table.sort(VISIBLE,function(a,b)
    if a.fame~=b.fame then return a.fame<b.fame end
    return a.kind>b.kind end)
end

--- City sprites and non-overlapping name labels.
function draw_cities()
  for i=#VISIBLE,1,-1 do
    local c=VISIBLE[i]
    local id=c.kind==1 and 305 or c.kind==2 and 306 or 304
    spr(id,floor(c.sx)-4,floor(c.sy)-6,0)
  end
  local boxes={}
  for _,c in ipairs(VISIBLE) do
    local w=#c.name*4
    local x,y=floor(c.sx)+5,floor(c.sy)-3
    local ok=x>0 and x+w<240 and y>9 and y<120
    for _,b in ipairs(boxes) do
      if ok and x<b[1]+b[3]+2 and b[1]<x+w+2 and y<b[2]+7 and b[2]<y+7 then ok=false end
    end
    if ok then
      boxes[#boxes+1]={x,y,w}
      oprint(c.name,x,y,c==G.target and G.found and 15 or 5,true)
    end
  end
end

--- Format degrees as e.g. 48.9N.
function fmt_deg(v,pos,neg)
  return string.format("%.1f%s",abs(v),v>=0 and pos or neg)
end

function draw_hud()
  rect(0,0,240,9,0)
  local t=G.target
  print("FIND: "..t.name..", "..t.country,2,2,15,false,1,false)
  local r=G.round.."/"..ROUNDS
  print(r,238-#r*6,2,5)
  rect(0,128,240,8,0)
  local lat,lon=copter_pos()
  print(fmt_deg(lat,"N","S").." "..fmt_deg(lon,"E","W"),2,130,4,false,1,true)
  local s="SCORE "..G.score
  print(s,238-#s*4,130,5,false,1,true)
  local tm=string.format("%d:%02d",G.rtime//3600,G.rtime//60%60)
  print(tm,108,130,5,false,1,true)
  local c=city_below()
  if c and G.mode=="fly" then
    local s=c.name..", "..c.country
    local w=print(s,0,-20,0,false,1,true)
    rect(118-w//2,110,w+5,9,0)
    print(s,120-w//2,112,c==t and 15 or 5,false,1,true)
  end
  draw_north()
  if G.msg_t>0 then
    local w=print(G.msg,0,-20)
    local x=120-w//2
    rect(x-3,12,w+6,11,0)
    rectb(x-3,12,w+6,11,15)
    print(G.msg,x,15,5)
  end
end

--- Screen direction (unit dx,dy) of the great circle towards vector v.
function screen_dir(x,y,z)
  local r,h=P.r,P.h
  local dx=x*r[1]+y*r[2]+z*r[3]
  local dy=-(x*h[1]+y*h[2]+z*h[3])
  local l=math.sqrt(dx*dx+dy*dy)
  if l<1e-9 then return 0,-1 end
  return dx/l,dy/l
end

--- Small compass needle pointing north (the map rotates with the copter).
function draw_north()
  local x,y=224,26
  local dx,dy=screen_dir(0,0,1)
  circ(x,y,11,0)
  circb(x,y,11,13)
  tri(x+dx*7,y+dy*7,x-dy*2,y+dx*2,x+dy*2,y-dx*2,14)
  tri(x-dx*7,y-dy*7,x-dy*2,y+dx*2,x+dy*2,y-dx*2,5)
  print("N",floor(x+dx*9+0.5)-1,floor(y+dy*9+0.5)-2,15,false,1,true)
end

--- Compass arrow towards the target with the distance.
function draw_hint()
  local lat,lon=copter_pos()
  local t=G.target
  local d=geo(lat,lon,t.lat,t.lon)
  local s,c=screen_dir(t.x,t.y,t.z)
  local x,y=CX+s*22,CY+c*22
  local px,py=-c,s
  tri(CX+s*30,CY+c*30,x+px*4,y+py*4,x-px*4,y-py*4,15)
  local txt=floor(d).." km"
  oprint(txt,floor(CX+s*36)-#txt*2,floor(CY+c*36)-3,15,true)
end

function draw_world_map()
  cls(0)
  memcpy(8*120,0x8000,120*120)
  local lat,lon=copter_pos()
  local x=floor((lon+180)/360*240)
  local y=floor((90-lat)/180*120)+8
  if G.t%30<20 then
    circb(x,y,3,14)
    pix(x,y,14)
  end
  -- heading: north and east components of P.h
  local h=P.h
  local lr=math.rad(lon)
  local hn=h[3]
  local he=-h[1]*math.sin(lr)+h[2]*math.cos(lr)
  local l=math.sqrt(hn*hn+he*he)
  if l>0 then line(x,y,x+he/l*7,y-hn/l*7,15) end
  if G.hint_t>0 then
    local t=G.target
    local tx,ty=floor((t.lon+180)/360*240),floor((90-t.lat)/180*120)+8
    if G.t%20<14 then
      circb(tx,ty,4,0)
      circb(tx,ty,3,15)
      pix(tx,ty,15)
    end
  end
  local t=G.target
  print("FIND: "..t.name..", "..t.country,2,1,15)
  print("X: back   A: compass hint (-150)",2,129,5,false,1,true)
end

function title_screen()
  cls(0)
  memcpy(8*120,0x8000,120*120)
  rect(30,30,180,62,0)
  rectb(30,30,180,62,15)
  print("COPTER QUEST",56,36,15,false,2)
  print("Fly around the Earth and find",44,54,5,false,1,true)
  print("real cities as fast as you can.",42,61,5,false,1,true)
  print("up fly  left/right turn  S turbo",40,72,4,false,1,true)
  print("Z land  X world map  A compass hint",36,79,4,false,1,true)
  if G.t%40<28 then print("press Z to start",74,98,15,false,1,false) end
  local hi=pmem(0)
  if hi>0 then
    local s="best: "..hi
    rect(118-#s*2,111,#s*4+5,8,0)
    print(s,120-#s*2,112,5,false,1,true)
  end
  if btnp(4) then new_game() end
end

function game_over()
  draw_terrain()
  collect_cities()
  draw_cities()
  rect(40,40,160,52,0)
  rectb(40,40,160,52,15)
  print("TRIP COMPLETE",64,46,15,false,1)
  print("score "..G.score,80,60,5)
  if G.score>pmem(0) then pmem(0,G.score) end
  print("best "..pmem(0),80,70,4,false,1,true)
  if G.t%40<28 then print("press Z",100,82,15,false,1,true) end
  if btnp(4) then G.mode="title" end
end

--- One frame of flying.
function play()
  if btnp(5) then G.mode="map" return end
  if btnp(6) then
    G.hints=G.hints+1
    G.hint_t=360
  end
  fly()
  G.rtime=G.rtime+1
  draw_terrain()
  collect_cities()
  draw_cities()
  -- shadow first, then the copter hovering above it; the rotor disc leans
  -- into turns, the whole copter forward/back with acceleration and speed
  local bx=floor(P.turn/TURN*2+0.5)
  draw_copter(CX+10,CY+16,P.ph,true,bx,P.pitch)
  draw_copter(CX,CY,P.ph,false,bx,P.pitch)
  if G.hint_t>0 then
    G.hint_t=G.hint_t-1
    draw_hint()
  end
  if btnp(4) then
    local c=city_below()
    if c==G.target then
      local pts=math.max(50,1000-(G.rtime//60)*5-G.hints*150)
      G.score=G.score+pts
      G.found=true
      msg("Found "..c.name.."! +"..pts,150)
      G.mode="found"
      G.found_t=150
    elseif c then
      msg("This is "..c.name..", not "..G.target.name,150)
    else
      msg("No city here",90)
    end
  end
  draw_hud()
end

--- Landed on the target: show it for a while, then the next round.
function found()
  P.v=P.v*0.9
  move(0,P.v/SCALE)
  draw_terrain()
  collect_cities()
  draw_cities()
  -- landing: the shadow moves under the copter
  P.pitch=P.pitch*0.92
  draw_copter(CX+floor(10*G.found_t/150),CY+floor(16*G.found_t/150),P.ph,true,0,P.pitch)
  draw_copter(CX,CY,P.ph,false,0,P.pitch)
  P.ph=P.ph+(G.found_t>40 and 1 or 0)
  draw_hud()
  G.found_t=G.found_t-1
  if G.found_t<=0 then
    G.found=false
    if G.round>=ROUNDS then
      G.mode="over"
    else
      G.round=G.round+1
      next_target()
      G.mode="fly"
    end
  end
end

function TIC()
  if G.mode=="boot" then
    -- unpack the world over a few frames (one cart bank per frame)
    G.loader=G.loader or coroutine.create(load_world)
    local ok,bank=coroutine.resume(G.loader)
    if not ok then error(bank) end
    cls(0)
    print("COPTER QUEST",56,50,15,false,2)
    if coroutine.status(G.loader)~="dead" then
      print("unpacking the planet "..string.rep(".",bank),60,80,5,false,1,true)
      return
    end
    make_minimap()
    load_cities()
    G.mode="title"
    G.msg_t=0
  end
  G.t=G.t+1
  if G.msg_t>0 then G.msg_t=G.msg_t-1 end
  if G.mode=="title" then title_screen()
  elseif G.mode=="fly" then play()
  elseif G.mode=="found" then found()
  elseif G.mode=="map" then
    draw_world_map()
    if G.hint_t>0 then G.hint_t=G.hint_t-1 end
    if btnp(5) then G.mode="fly" end
    if btnp(6) then
      G.hints=G.hints+1
      G.hint_t=360
    end
  elseif G.mode=="over" then game_over()
  end
end
