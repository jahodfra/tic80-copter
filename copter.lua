-- title:  Helicopter
-- author: jahodfra
-- desc:   Flight around the world.
-- script: lua

W=2048
H=1024

function loadmap()
  local m={}
  local i=0
  local s=0
  while i<W*H do
    local x=peek(0x8000+s)
    s=s+1
    local ch=(x&0x80)>>7
    local count=(x&0x7f)+1
    for j=0, count do
      m[i+j]=ch
    end
    i=i+count
  end
  return m
end

function compress(m)
  local nm={}
  local y=0
  local floor=math.floor
  local rows={}
  for y=1, H-1 do
    local rw=floor(math.sin(3.14159*y/H)*W)
    rows[y]=rw
    local row={}
    for x=0, rw do
      row[x]=m[floor(x*W/rw)+y*W]
    end
    nm[y]=row
  end
  return nm,rows
end


m=loadmap()
m,rows=compress(m)


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

function draw_strip2()
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
  local R=600 --1800
  local quat_mul=quat_mul
  local view_angle=50/R
  local miny=max(1, floor(my-view_angle*H))
  local maxy=min(H-1, floor(my+view_angle*H))
  -- for polar regions the minrange needs to be larger
  local minrange=floor(W*view_angle)
  local polar_region=H*view_angle
  for b=miny, maxy do
    
    local rw=rows[b]
    local ptheta=b*pi/H
    local sintheta=sin(ptheta)
    local costheta=cos(ptheta)
    local ascale=2*pi/rw
    local minx, rangex
    rangex=min(rw,max(minrange, floor(rw*view_angle)))
    minx=floor(phi*rw-rangex*0.5)%rw
    if b<polar_region or b>H-polar_region then
      rangex=rw
    end
    for a=minx, minx+rangex do
      local cell=m[b][a%rw]
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
          --spr(32,120+rx*R, 68+ry*R, 0)
          pix(120+rx*R, 68+ry*R, 14)
        end
      end
    end
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
  draw_strip2()
  --print(quat_str(rotation),100, 100)
end

