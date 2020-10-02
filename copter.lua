-- title:  Helicopter
-- author: jahodfra
-- desc:   Flight around the world.
-- script: lua

W=1024
H=512


function table_str(o)
  if type(o) == 'table' then
    local s = '{ '
    for k,v in pairs(o) do
      if type(k) ~= 'number' then k = '"'..k..'"' end
      s = s .. '['..k..'] = ' .. table_str(v) .. ','
    end
    return s .. '} '
  else
    return tostring(o)
  end
end

function clone(t)
  local tn={}
  for i=1, #t do
    tn[i]=t[i]
  end
  return tn
end

function extend(t1,t2)
  for i=1, #t2 do
    t1[#t1+1]=t2[i]
  end
end

function loadmap()
  --[[
    Unzip data starting in map and continuing with tiles memory
  ]]
  local S=18
  local result={}
  local L=peek(0x8000)<<8 | peek(0x8001)
  local si=0x8000
  local CLEAR_CODE=0xFFFF
  local lookup={}
  local prefix={}
  for k=0,S-1 do
    lookup[k]={k}
  end
  local encoded_sum=0
  local clone=clone
  for i=1, L do
    si=si+2
    if si>=0xff80 then
      si=0x4000
    end
    local code=peek(si)<<8 | peek(si+1)
    encoded_sum=encoded_sum + code
    if code==CLEAR_CODE then
      prefix={}
      lookup = {}
      for k=0,S-1 do
        lookup[k]={k}
      end
    elseif code<=#lookup then
      local ret=lookup[code]
      if #prefix>0 then
        local newvalue=clone(prefix)
        newvalue[#newvalue+1] = ret[1]
        lookup[#lookup+1] = newvalue
      end
      prefix=ret
      extend(result,ret)
    else
      prefix=clone(prefix)
      prefix[#prefix+1] = prefix[1]
      lookup[#lookup+1] = prefix
      extend(result,prefix)
    end
  end
  if encoded_sum ~= 116563337 then
    trace("encoded sum: "..encoded_sum)
  end
  local sum=0
  for i=1, #result do
    sum=sum+result[i]
  end
  if sum ~= 1034904 then
    trace("decoded sum: "..sum)
  end
  return result
end

function compute_rows()
  local floor=math.floor
  local sin=math.sin
  local rows={}
  local starts={}
  local start=0
  for y=0, H-1 do
    local rw=floor(sin(3.14159*(y+1)/(H+2))*W)
    rows[y]=rw
    start=start+rw
    starts[y]=start
  end
  return starts,rows
end

local starts, rows
starts,rows=compute_rows()
local m=loadmap()


function quat_mul(q1, q2)
  local q1w = q1[1]
  local q1x = q1[2]
  local q1y = q1[3]
  local q1z = q1[4]
  local q2w = q2[1]
  local q2x = q2[2]
  local q2y = q2[3]
  local q2z = q2[4]
  local a = (q1w + q1x)*(q2w + q2x)
  local b = (q1z - q1y)*(q2y - q2z)
  local c = (q1w - q1x)*(q2y + q2z)
  local d = (q1y + q1z)*(q2w - q2x)
  local e = (q1x + q1z)*(q2x + q2y)
  local f = (q1x - q1z)*(q2x - q2y)
  local g = (q1w + q1y)*(q2w - q2z)
  local h = (q1w - q1y)*(q2w + q2z)
  return {
    b+(-e-f+g+h)*.5,
    a-( e+f+g+h)*.5,
    c+( e-f+g-h)*.5,
    d+( e-f-g+h)*.5
  }		
end

function quat_norm(q)
  local w=q[1]
  local x=q[2]
  local y=q[3]
  local z=q[4]
  local len=math.sqrt(w*w+x*x+y*y+z*z)
  return {w/len,x/len,y/len,z/len}
end

function quat_rot(q1,q2)
  return quat_mul(q1, quat_mul(q2, {q1[1],-q1[2],-q1[3],-q1[4]}))
end

function quat_to_matrix(q)
  local a=q[1]
  local b=q[2]
  local c=q[3]
  local d=q[4]
  return a*a+b*b-c*c-d*d,
    2*(b*c-a*d),
    2*(b*d+a*c),
    2*(b*c+a*d),
    a*a-b*b+c*c-d*d,
    2*(c*d-a*b),
    2*(b*d-a*c),
    2*(c*d+a*b),
    a*a-b*b-c*c+d*d
end

rotation=quat_norm({-0.341,-0.694,0.584,-0.248})

random_v={}
for i=0, 1000 do
  random_v[i]=math.random()
end

function srandom(i)
  return random_v[i%1000]
end

local SPR={
  2, 3, 4, 1, 1,
  1, 1, 1, 1, 1,
  1, 1, 1, 2, 1,
  5, 0,
}
local OVER={
  0, 0, 0, 0, 0,
  0, 0, 0, 0, 0,
  0, 0, 0, 0, 0,
  1, 0,
}

function draw_strip()
  local points=0
  local sin=math.sin
  local cos=math.cos
  local floor=math.floor
  local min=math.min
  local max=math.max
  local q=rotation
  local rows=rows
  local w=q[1]
  local x=q[2]
  local y=q[3]
  local z=q[3]
  local m11,m12,m13,m21,m22,m23,m31,m32,m33=quat_to_matrix(rotation)
  local pi=math.pi
  local qinv={q[1],-q[2],-q[3],-q[4]}
  local g=quat_rot(qinv,{0,0,0,-1})
  local theta=math.acos(g[4])
  local phi=math.atan2(g[3],g[2])/(2*pi)
  local my=floor(theta/pi*H)
  local R=800 --1800
  local quat_mul=quat_mul
  local view_angle=50/R
  local miny=max(1, floor(my-view_angle*H))
  local maxy=min(H-1, floor(my+view_angle*H))
  -- for polar regions the minrange needs to be larger
  local minrange=floor(W*view_angle)
  local polar_region=H*view_angle
  local oversprites={}
  local insert=table.insert
  for b=miny, maxy do
    
    local rw=rows[b]
    local ptheta=b*pi/H
    local sintheta=sin(ptheta)
    local costheta=cos(ptheta)
    local ascale=2*pi/rw
    local minx, rangex
    local start_index=starts[b]
    rangex=min(rw,max(minrange, floor(rw*view_angle)))
    minx=floor(phi*rw-rangex*0.5)%rw
    if b<polar_region or b>H-polar_region then
      rangex=rw
    end
    for a=minx, minx+rangex do
      local tcell=m[start_index+a%rw]
      local cell=SPR[tcell]
      if cell and cell>0 then
        points=points+1
        local pphi=a*ascale
        local px=sintheta*cos(pphi)
        local py=sintheta*sin(pphi)
        local pz=costheta
        local rx=px*m11+py*m12+pz*m13
        local ry=px*m21+py*m22+pz*m23
        local rz=px*m31+py*m32+pz*m33				
        if rz < 0 then
          local sx=120+rx*R
          local sy=68+ry*R
          if OVER[tcell]>0 then
            insert(oversprites,{sx,sy,cell})
          end
          spr(255+cell,sx, sy, 0)
        end
      end
    end
  end
  table.sort(oversprites, function(s1,s2) return s1[2]<s2[2] end)
  for i=1,#oversprites do
    local sprite=oversprites[i]
    spr(271+sprite[3], sprite[1], sprite[2], 0)
  end
  print(points)
end

function quat_inverse(q)
  return {q[1],-q[2],-q[3],-q[4]}
end

function rot(w,x,y,z)
  rotation=quat_norm(quat_mul({w,x,y,z},rotation))
end

function quat_str(q)
  return string.format("(%.3f,%.3f,%.3f,%.3f)",q[1],q[2],q[3],q[4])
end

speed=.01
rot_speed=.01

function TIC()
  if btn(0) then rot(1,speed,0,0)end
  if btn(1) then rot(1,-speed,0,0)end
  if btn(2) then rot(1,0,-speed,0)end
  if btn(3) then rot(1,0,speed,0)end
  if btn(4) then rot(1,0,0,-rot_speed)end
  if btn(5) then rot(1,0,0,rot_speed)end


  cls(2)
  draw_strip()
  --print(quat_str(rotation),100, 100)
end

