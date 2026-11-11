---------------------------------------- world data
--[[
The Earth is an equal-area (sinusoidal) grid built by tools/build_world.py:
H rows from the north pole to the south pole, row y holds RW[y] cells around
the globe starting at longitude -180. One cell is about 20 km.

Cell byte: 0 deep ocean, 1 ocean, 2 shallow water,
           4 + class*4 + relief for land (relief 0 flat, 1 hills,
           2 mountains, 3 snowy peaks).

The rows are run-length encoded in the map memory of cart banks 1..7 and are
unpacked into one Lua string per row on start-up.
]]

W=2048
H=1024
RW={}
ROWS={}

local floor,sin,cos,pi=math.floor,math.sin,math.cos,math.pi
local byte,char,rep,concat=string.byte,string.char,string.rep,table.concat

for y=0,H-1 do
  -- multiples of 128 cells: rows of equal length scroll together
  RW[y]=128*math.max(1,floor(W*sin(pi*(y+0.5)/H)/128+0.5))
end

--- Unpack the run-length encoded rows from the map memory of banks 1..7.
-- Runs as a coroutine: sync() copies a memory section only once per frame,
-- so it yields before switching to the next bank. Byte b<192: value b&63 repeated (b>>6)+1 times; b>=192: value b&63
-- repeated (next byte)+4 times. Runs never cross rows.
function load_world()
  local bank,addr,lim=1,0x8000,0x8000+32640
  sync(4,bank)
  local function rd()
    if addr>=lim then
      bank=bank+1
      coroutine.yield(bank)
      sync(4,bank)
      addr=0x8000
    end
    local b=peek(addr)
    addr=addr+1
    return b
  end
  local CH={}
  for v=0,63 do CH[v]=char(v) end
  local y,parts,np,filled,rw=0,{},0,0,RW[0]
  while y<H do
    local b=rd()
    local n
    if b<192 then n=(b>>6)+1 else n=rd()+4 end
    np=np+1
    parts[np]=rep(CH[b&63],n)
    filled=filled+n
    if filled>=rw then
      ROWS[y]=concat(parts,"",1,np)
      y=y+1
      np,filled,rw=0,0,RW[y]
    end
  end
end

--- Cell byte at row y (clamped) and column x (wrapped around the globe).
function cell(y,x)
  if y<0 then y=0 elseif y>H-1 then y=H-1 end
  local rw=RW[y]
  return byte(ROWS[y],x%rw+1)
end

--- Row coordinate (float) of a latitude.
function lat2row(lat) return (90-lat)/180*H end
function row2lat(r) return 90-r*180/H end

--- Great-circle distance in km and initial bearing (radians, 0 = north,
-- clockwise) from (lat1,lon1) to (lat2,lon2), all in degrees.
function geo(lat1,lon1,lat2,lon2)
  local r=pi/180
  local p1,p2,dl=lat1*r,lat2*r,(lon2-lon1)*r
  local a=sin((p2-p1)/2)^2+cos(p1)*cos(p2)*sin(dl/2)^2
  local d=2*6371*math.asin(math.min(1,math.sqrt(a)))
  local b=math.atan(sin(dl)*cos(p2),cos(p1)*sin(p2)-sin(p1)*cos(p2)*cos(dl))
  return d,b
end

-- minimap colour of each land class (see build_world.py for the order)
MINI_COL={5,12,6,7,9,8,15,9,11,10,10,3,14}
MINI_WATER={1,2,3}

--- Render a 240x120 equirectangular world map into map memory (0x8000),
-- packed like the screen (two pixels per byte), for memcpy to the screen.
function make_minimap()
  for j=0,119 do
    local y=floor((j+0.5)/120*H)
    local rw=RW[y]
    local row=ROWS[y]
    local lat=90-(j+0.5)*1.5
    for i=0,238,2 do
      local c={}
      for k=0,1 do
        local v=byte(row,floor((i+k+0.5)/240*rw)+1)
        local col
        if v<4 then
          col=MINI_WATER[v+1]
        else
          local rel=(v-4)&3
          col=MINI_COL[((v-4)>>2)+1]
          if rel==3 then col=5 elseif rel==2 then col=13 end
        end
        -- graticule every 30 degrees
        if (i+k)%20==0 and j%2==0 or j%20==0 and (i+k)%2==0 then
          if v<4 then col=4 end
        end
        c[k]=col
      end
      poke(0x8000+j*120+i//2,c[0]|(c[1]<<4))
    end
  end
end
