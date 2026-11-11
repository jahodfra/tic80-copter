---------------------------------------- terrain rendering
--[[
The Earth is a sphere. The copter has a position P.p and a heading P.h (unit
vectors, see 40_game.lua); the screen shows the plane touching the sphere
under the copter, with the heading pointing up. Turning therefore rotates
the world underneath, and flying straight follows a great circle, also over
the poles.

The ground is drawn on the "dual grid": every quad joins the centres of four
neighbouring cells (two in row y, two in row y+1 at the same longitudes) and
is filled with a textured tile through two textri() calls. Coasts and depth
changes get smooth corner masks (16 shapes per water level) on top. Near the
poles cells shrink, so several of them are merged into one wider quad.
Mountains, hills and cities stay upright and are drawn afterwards.

Tile ids (see tools/make_sprites.py):
  1 + level*2 + v       open water, level 0 deep, 1 ocean, 2 shallow
  16 + level*16 + mask  part of the tile at water level <= level
  64 + class*4 + v      land texture
  256.. hills, 272.. mountains (16x16), 304.. cities
]]

CX,CY=120,72   -- copter position on screen
local floor,sin,cos,pi=math.floor,math.sin,math.cos,math.pi
local byte=string.byte
local spr,textri=spr,textri

-- pixels per radian on the ground: one cell (2*pi/W of the equator) = 8 px
SCALE=8*W/(2*pi)
DLAT=pi/H            -- latitude step of one row
VIEW_R=150/SCALE     -- angular radius of the visible disc
local SCALE,DLAT=SCALE,DLAT

-- per-cell pseudo random numbers, stable for every place on Earth
RND={}
for i=0,4095 do RND[i]=math.random(0,255) end
local RND=RND

--- Stable random byte for world cell (y,x).
local function hash(y,x)
  return RND[(x*7919+y*104729)&4095]
end

-- relief sprite group per land class: 0 green, 1 dry, 2 rock, 3 snow
RELIEF_GROUP={[0]=3,2,1,1,0,1,0,0,0,0,0,0,2}
local RELIEF_GROUP=RELIEF_GROUP

-- ground texture base tile for each cell value, rock under snowy peaks
TEX={}
for v=4,63 do
  local cls,rel=(v-4)>>2,(v-4)&3
  TEX[v]=64+(rel==3 and cls~=0 and 1 or cls)*4
end
local TEX=TEX

-- sine/cosine of the latitude of each row's cell centres
ROW_SIN,ROW_COS={},{}
for y=0,H do
  local phi=pi/2-(y+0.5)*DLAT
  ROW_SIN[y],ROW_COS[y]=sin(phi),cos(phi)
end
-- the same for the bottom edge of the quads, a bit lower so that rows
-- overlap and no cracks show between them
ROW_SIN2,ROW_COS2={},{}
for y=0,H do
  local phi=pi/2-(y+1.6)*DLAT
  ROW_SIN2[y],ROW_COS2[y]=sin(phi),cos(phi)
end
local ROW_SIN,ROW_COS,ROW_SIN2,ROW_COS2=ROW_SIN,ROW_COS,ROW_SIN2,ROW_COS2


local E=0.6     -- keep texture lookups inside the tile (textri overshoots ~1 px)

-- texture position of every tile on the sheet
local TU,TV={},{}
for t=0,511 do TU[t]=(t%16)*8+E TV[t]=(t//16)*8+E end
local W8=8-2*E

--- What to draw for a dual cell with corner values a (top left), b (top
-- right), c (bottom left), d (bottom right) and random byte h: a list of
-- tiles (texture, then water masks) and maybe a relief sprite (field rs).
local function dual_tiles(a,b,c,d,h,h2)
  local e={}
  if a==b and a==c and a==d then
    if a>=4 then e[1]=TEX[a]+(h&3) else e[1]=1+a*2+(h<24 and 1 or 0) end
  else
    local la=a<4 and a or 3
    local lb=b<4 and b or 3
    local lc=c<4 and c or 3
    local ld=d<4 and d or 3
    local mx,mn=la,la
    if lb>mx then mx=lb end if lb<mn then mn=lb end
    if lc>mx then mx=lc end if lc<mn then mn=lc end
    if ld>mx then mx=ld end if ld<mn then mn=ld end
    if mx==3 then
      -- land texture of a random land corner: ragged class borders
      local pick=h%4
      local v
      for _=0,3 do
        v=pick==0 and a or pick==1 and b or pick==2 and c or d
        if v>=4 then break end
        pick=(pick+1)%4
      end
      e[1]=TEX[v]+((h>>2)&3)
    else
      e[1]=1+mx*2
    end
    for L=mx-1,mn,-1 do
      e[#e+1]=16+L*16+(la<=L and 1 or 0)+(lb<=L and 2 or 0)
             +(lc<=L and 4 or 0)+(ld<=L and 8 or 0)
    end
  end
  return e
end

--- Relief sprite standing on a cell of value v: id, size, offsets, flip.
local function relief_of(v,y,k,step,h)
  if v<4 then return end
  local rel=(v-4)&3
  if rel==0 or (rel>1 and (y+k//step)%2==1) then return end
  local grp=RELIEF_GROUP[(v-4)>>2]
  local dx=(h&3)-1
  if rel==1 then
    if h&4==0 then return 256+grp*2+(h>>7),1,dx-4,-6+((h>>3)&3),0 end
  elseif rel==2 and grp~=3 then
    return 272+grp*4+((h>>6)&1)*2,2,dx-8,-12+((h>>3)&3),h>>7
  else
    return 284+((h>>6)&1)*2,2,dx-8,-13+((h>>3)&3),h>>7
  end
end

--- Screen position of the unit vector (x,y,z) in the copter's view,
-- or nil when it is outside the visible disc.
function to_screen(x,y,z)
  local p,r,h=P.p,P.r,P.h
  if x*p[1]+y*p[2]+z*p[3]<VIEW.cosr then return nil end
  return CX+(x*r[1]+y*r[2]+z*r[3])*SCALE,CY-(x*h[1]+y*h[2]+z*h[3])*SCALE
end

VIEW={cosr=math.cos(VIEW_R)}

-- tiles of every dual cell seen recently: key (y,k,step) -> entry
local CACHE,NCACHE={},0

--- Clip the parameter range [0,1] of the screen segment (x0,y0)-(x1,y1)
-- to the screen plus a margin (Liang-Barsky). Returns t0,t1 or nil.
local function clip(x0,y0,x1,y1)
  local t0,t1=0,1
  local dx,dy=x1-x0,y1-y0
  local P4={-dx,dx,-dy,dy}
  local Q4={x0+24,263-x0,y0+24,159-y0}
  for i=1,4 do
    local p,q=P4[i],Q4[i]
    if p==0 then
      if q<0 then return nil end
    else
      local t=q/p
      if p<0 then
        if t>t1 then return nil elseif t>t0 then t0=t end
      else
        if t<t0 then return nil elseif t<t1 then t1=t end
      end
    end
  end
  return t0,t1
end

--- Draw the ground, then hills and mountains, around the copter.
function draw_terrain()
  local p,r,h=P.p,P.r,P.h
  local px,py,pz=p[1],p[2],p[3]
  local rx,ry,rz=r[1],r[2],r[3]
  local hx,hy,hz=h[1],h[2],h[3]
  cls(1)
  local lat=math.asin(pz)
  local lon=math.atan(py,px)
  local rowc=(pi/2-lat)/DLAT-0.5
  local nrow=VIEW_R/DLAT
  local y0=floor(rowc-nrow)-1
  local y1=floor(rowc+nrow)+1
  if y0<0 then y0=0 end
  if y1>H-2 then y1=H-2 end
  local sinr=sin(VIEW_R)
  local relief,nrel={},0
  local TX,TY,BX,BY,VT,VB={},{},{},{},{},{}
  if NCACHE>30000 then CACHE,NCACHE={},0 end
  for y=y0,y1 do
    local rw=RW[y]
    local s1,c1,s2,c2=ROW_SIN[y],ROW_COS[y],ROW_SIN2[y],ROW_COS2[y]
    local cmin=c1<c2 and c1 or c2
    local ang=2*pi/rw
    -- merge cells that are narrower than 6 px (near the poles)
    local step=1
    local cw=c1*ang*SCALE
    while step*cw<6 and step<rw//8 do step=step*2 end
    -- columns to visit: a window around the copter's longitude ...
    local k0,k1
    if cmin<=sinr*1.02 then
      k0,k1=0,rw
    else
      local dl=math.asin(sinr/cmin)*1.05
      local kc=(lon+pi)/ang-0.5
      k0=floor((kc-dl/ang)/step)*step-step
      k1=floor((kc+dl/ang)/step)*step+2*step
      if dl<0.25 then
        -- ... narrowed to the part of the row that crosses the screen
        local l=-pi+(k0+0.5)*ang
        local A,B=cos(l)*rx+sin(l)*ry,cos(l)*hx+sin(l)*hy
        local xa,ya=CX+(c1*A+s1*rz)*SCALE,CY-(c1*B+s1*hz)*SCALE
        l=-pi+(k1+0.5)*ang
        A,B=cos(l)*rx+sin(l)*ry,cos(l)*hx+sin(l)*hy
        local xb,yb=CX+(c1*A+s1*rz)*SCALE,CY-(c1*B+s1*hz)*SCALE
        local ta,tb=clip(xa,ya,xb,yb)
        if not ta then goto nextrow end
        local span=(k1-k0)/step
        k1=k0+(floor(tb*span)+2)*step
        k0=k0+(floor(ta*span)-1)*step
      end
    end
    do
      local row,row2,rw2=ROWS[y],ROWS[y+1],RW[y+1]
      local n=0
      local l=-pi+(k0+0.5)*ang
      local cl,sl=cos(l),sin(l)
      local cd,sd=cos(ang*step),sin(ang*step)
      local f=rw2/rw
      for k=k0,k1,step do
        local A=cl*rx+sl*ry
        local B=cl*hx+sl*hy
        n=n+1
        TX[n]=CX+(c1*A+s1*rz)*SCALE
        TY[n]=CY-(c1*B+s1*hz)*SCALE
        BX[n]=CX+(c2*A+s2*rz)*SCALE
        BY[n]=CY-(c2*B+s2*hz)*SCALE
        VT[n]=byte(row,k%rw+1)
        VB[n]=byte(row2,floor((k+0.5)*f)%rw2+1)
        cl,sl=cl*cd-sl*sd,sl*cd+cl*sd
      end
      local k=k0
      local kbase=(y*4096)*64+step
      for i=1,n-1 do
        local x1,yy1,x2,y2=TX[i],TY[i],TX[i+1],TY[i+1]
        local x3,y3,x4,y4=BX[i],BY[i],BX[i+1],BY[i+1]
        local minx,maxx=x1,x1
        if x2<minx then minx=x2 elseif x2>maxx then maxx=x2 end
        if x3<minx then minx=x3 elseif x3>maxx then maxx=x3 end
        if x4<minx then minx=x4 elseif x4>maxx then maxx=x4 end
        local miny,maxy=yy1,yy1
        if y2<miny then miny=y2 elseif y2>maxy then maxy=y2 end
        if y3<miny then miny=y3 elseif y3>maxy then maxy=y3 end
        if y4<miny then miny=y4 elseif y4>maxy then maxy=y4 end
        if maxx>=0 and minx<240 and maxy>=0 and miny<136 then
          local kk=k%rw
          local key=kbase+kk*64
          local e=CACHE[key]
          if not e then
            local hh=RND[(kk*7919+y*104729)&4095]
            e=dual_tiles(VT[i],VT[i+1],VB[i],VB[i+1],hh)
            local h2=RND[((kk+7)*7919+y*104729)&4095]
            e.rs,e.rw,e.rx,e.ry,e.rf=relief_of(VT[i],y,kk,step,h2)
            CACHE[key]=e
            NCACHE=NCACHE+1
          end
          -- stretch the right edge a little into the next quad (no cracks)
          local ex,ey=(x2-x1)*0.15,(y2-yy1)*0.15
          x2,y2,x4,y4=x2+ex,y2+ey,x4+ex,y4+ey
          for j=1,#e do
            local t=e[j]
            local u,v=TU[t],TV[t]
            local key0=j>1 and 0 or nil
            textri(x1,yy1,x2,y2,x3,y3,u,v,u+W8,v,u,v+W8,false,key0)
            textri(x2,y2,x4,y4,x3,y3,u+W8,v,u+W8,v+W8,u,v+W8,false,key0)
          end
          -- hills and mountains stand on the cell centres
          if e.rs and x1>-8 and x1<248 and yy1>-4 and yy1<150 then
            nrel=nrel+1
            relief[nrel]=e
            e.sx,e.sy=floor(x1),floor(yy1)
          end
        end
        k=k+step
      end
    end
    ::nextrow::
  end
  -- upright relief sprites, back to front
  table.sort(relief,function(a,b) return a.sy<b.sy end)
  for i=1,nrel do
    local e=relief[i]
    spr(e.rs,e.sx+e.rx,e.sy+e.ry,0,1,e.rf,0,e.rw,e.rw)
  end
end

--- Print text with a one pixel dark outline.
function oprint(s,x,y,c,small,oc)
  oc=oc or 0
  for dx=-1,1 do
    for dy=-1,1 do
      if dx~=0 or dy~=0 then print(s,x+dx,y+dy,oc,false,1,small) end
    end
  end
  return print(s,x,y,c,false,1,small)
end

ROTOR={328,332,384,388}         -- main rotor animation frames (32x32)
ROTOR_SHADOW={392,396,448,452}  -- the same frames as dithered shadows

local PERSP=55 -- distance of the camera in pixels: strength of the perspective

--- Draw the w x h sprite-sheet region at (u,v) pitched forward by th
-- radians (negative: nose up) around its pivot (px,py), placed at (x,y).
-- The far end shrinks and the near end grows, the length is foreshortened.
-- Drawn as horizontal strips of 8 texture rows (two textri each), so the
-- texture follows the perspective. Colour 1 is transparent.
function tilt_spr(u,v,w,h,px,py,x,y,th,flat)
  local c,s=math.cos(th),math.sin(th)
  if flat then s=0 end                 -- shadows: foreshortened, no perspective
  local ytop,stop=nil,nil
  for r=0,h,8 do
    local ly=r-py                      -- y along the body (down = to the tail)
    local sc=PERSP/(PERSP-ly*s)        -- nose down: the nose is farther away
    local sy=y+ly*c*sc
    if ytop then
      local x0l,x0r=x-px*stop,x+(w-px)*stop
      local x1l,x1r=x-px*sc,x+(w-px)*sc
      local v0,v1=v+r-8+0.01,v+r-0.01
      local yb=sy+0.5                  -- overlap the next strip: no cracks
      textri(x0l,ytop,x0r,ytop,x1l,yb,u+0.01,v0,u+w-0.01,v0,u+0.01,v1,false,1)
      textri(x0r,ytop,x1r,yb,x1l,yb,u+w-0.01,v0,u+w-0.01,v1,u+0.01,v1,false,1)
    end
    ytop,stop=sy,sc
  end
end

--- Helicopter (nose up) with its rotor hub at (x,y). ph: rotor phase;
-- bx: sideways lean of the rotor disc in turns; pitch: forward lean in
-- radians (negative leans back). shadow=true draws its dithered shadow.
function draw_copter(x,y,ph,shadow,bx,pitch)
  bx,pitch=bx or 0,pitch or 0
  -- the rotor mast leans with the body: the disc moves forward/back
  local my=-floor(7*math.sin(pitch)+0.5)
  if shadow then
    -- on the ground the leaning copter just looks shorter
    if math.abs(pitch)<0.05 then
      spr(324,x-12+bx,y-12,1,1,0,0,3,4)
    else
      tilt_spr(32,160,24,32,12,12,x+bx,y,pitch,true)
    end
    spr(ROTOR_SHADOW[ph%4+1],x-16+bx*2,y-16+my,1,1,0,0,4,4)
    return
  end
  local c,s=math.cos(pitch),math.sin(pitch)
  if math.abs(pitch)<0.02 then
    spr(320,x-12,y-12,1,1,0,0,3,4)
  else
    tilt_spr(0,160,24,32,12,12,x,y,pitch)
  end
  -- tail rotor at the end of the boom, spinning sideways
  local sc=PERSP/(PERSP-17*s)
  local ty=y+floor(17*c*sc+0.5)
  if ph%2==0 then
    line(x+2,ty-3,x+2,ty+2,13)
  else
    line(x+1,ty-1,x+4,ty,12)
  end
  local rotor=ROTOR[ph%4+1]
  if math.abs(pitch)<0.02 then
    spr(rotor,x-16+bx,y-16+my,1,1,0,0,4,4)
  else
    tilt_spr((rotor%16)*8,(rotor//16)*8,32,32,16,16,x+bx,y+my,pitch)
  end
end
