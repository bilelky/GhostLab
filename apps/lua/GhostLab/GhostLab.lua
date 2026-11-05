-- GhostLab: a ghost car of any car, recorded from a replay or from your own laps.
-- Recording: open a replay, focus the car you want, play at normal speed.
-- Driving: pick a ghost recorded on the same circuit (another version of it is aligned automatically).
-- Visual only: no collision, nothing is applied to your car.

local VERSION = '1.0.2'

local DEFAULTS = { yOffset = 0, hideDist = 4, fadeLen = 8, shadows = 1, showGhost = 1, autoOwn = 1, selected = '',
  timeAttack = 1, trackOnly = 1, carOnly = 0, style = 0, alpha = 0.30, standIn = 1, skipVersion = '', justUpdated = '', useSkins = 0, lightModel = 1 }
local cfg = {}
do
  local ok, st = pcall(ac.storage, DEFAULTS, 'GHOSTLAB_')
  if ok and st then cfg = st end
  for k, v in pairs(DEFAULTS) do if cfg[k] == nil then cfg[k] = v end end
end

-- ---------------------------------------------------------------------------
local HAS = {}
local function opt(obj, key)
  if obj == nil then return nil end
  local h = HAS[key]
  if h == false then return nil end
  if h == nil then
    local ok, v = pcall(function() return obj[key] end)
    HAS[key] = ok
    if ok then return v end
    return nil
  end
  return obj[key]
end
local function num(v, d) v = tonumber(v); if v == nil or v ~= v then return d or 0 end return v end
local function safeName(s)
  s = tostring(s or ''):gsub('[^%w%-_%.]', '_')
  if s == '' then s = 'unknown' end
  return s
end
local function fmtLap(ms)
  if not ms or ms <= 0 then return '--:--.---' end
  local s = ms / 1000
  return string.format('%d:%06.3f', math.floor(s / 60), s - math.floor(s / 60) * 60)
end
local function ghostDir() return ac.getFolder(ac.FolderID.Cfg) .. '\\apps\\GhostLab\\ghosts\\' end
local function trackKey()
  local l = ac.getTrackLayout() or ''
  return safeName(ac.getTrackID() .. (l ~= '' and ('-' .. l) or ''))
end
local function readTransform(car)
  local ok, p, l, u = pcall(function()
    local m = car.bodyTransform
    return m.position, m.look, m.up
  end)
  if ok and p then return p, l, u end
  return car.position, car.look, car.up
end

-- your own laps are saved with driver "me" ("moi" in GhostLab 1.0 to 1.3)
local OWN_DRIVER = 'me'
local function isOwnDriver(d) return d == 'me' or d == 'moi' end
-- driver name for display ("" when unknown: files from early versions could hold a technical value instead)
local function niceDriver(d)
  d = tostring(d or '')
  if d == '' or d:match('^function') or d:match('^table') or d:match('^userdata') then return '' end
  return (d:gsub('_+', ' '))
end

local function skinOf(idx)
  local ok, sk = pcall(function() return ac.getCarSkinID(idx) end)
  return ok and type(sk) == 'string' and sk or ''
end

local S = { msg = '', msgT = -10, t = 0 }

-- slowest steps (ms), shown in Ghost settings: helps find anything that could freeze the game
local clock = os.preciseClock or os.clock
local PERF = {}
local function perf(label, t0)
  local ms = (clock() - t0) * 1000
  if ms > (PERF[label] or 0) then PERF[label] = ms end
end
local function say(m) S.msg, S.msgT = m, S.t; pcall(ac.setMessage, 'GhostLab', m) end

-- ---------------------------------------------------------------------------
-- Ghost file
local HEAD = 't,pos,x,y,z,lx,ly,lz,ux,uy,uz,spd,gas,brk,gear,hg'

-- ground height under a point (ray cast down onto the track's physical surface); nil if nothing
local DOWN = nil
local function groundY(x, y, z)
  local ok, gy = pcall(function()
    DOWN = DOWN or vec3(0, -1, 0)
    local d = physics.raycastTrack(vec3(x, y + 3, z), DOWN, 12)
    if d and d >= 0 then return y + 3 - d end
    return nil
  end)
  return ok and gy or nil
end
local function heightAboveGround(p)
  local gy = groundY(p.x, p.y, p.z)
  return gy and (p.y - gy) or -99
end

local NCL = 512
function trackCenterline()
  local out = {}
  local ok = pcall(function()
    if ac.hasTrackSpline and not ac.hasTrackSpline() then error('no AI spline') end
    for i = 0, NCL - 1 do
      local v = ac.trackProgressToWorldCoordinate(i / NCL)
      out[#out + 1] = { v.x, v.y, v.z }
    end
  end)
  return ok and out or {}
end

local function saveGhost(lap, meta)
  pcall(io.createDir, ac.getFolder(ac.FolderID.Cfg) .. '\\apps\\GhostLab')
  pcall(io.createDir, ghostDir())
  local name = string.format('%s__%s__%s__%s.csv', trackKey(), safeName(meta.car), safeName(meta.driver),
    fmtLap(lap.ms):gsub('[:%.]', '-'))
  local lines = {
    '# GHOSTLAB ' .. VERSION, '# car=' .. meta.car, '# carName=' .. (meta.carName or ''), '# driver=' .. (meta.driver or ''),
    '# track=' .. ac.getTrackID(), '# layout=' .. (ac.getTrackLayout() or ''), '# lapMs=' .. math.floor(lap.ms),
    '# source=' .. meta.source, '# skin=' .. (meta.skin or ''), '# date=' .. os.date('%Y-%m-%d %H:%M') }
  -- centerline of the original track (AI spline): used to align the ghost on another version of the track
  for _, c in ipairs(trackCenterline()) do lines[#lines + 1] = string.format('S,%.2f,%.2f,%.2f', c[1], c[2], c[3]) end
  lines[#lines + 1] = HEAD
  for i = 1, lap.n do lines[#lines + 1] = lap.rows[i] end
  local ok = pcall(io.save, ghostDir() .. name, table.concat(lines, '\n'))
  return ok and name or nil
end

local function loadGhost(name)
  local ok, txt = pcall(io.load, ghostDir() .. name)
  if not ok or not txt then return nil end
  local G = { meta = {}, t = {}, pos = {}, x = {}, y = {}, z = {}, lx = {}, ly = {}, lz = {}, ux = {}, uy = {}, uz = {},
    spd = {}, gas = {}, brk = {}, gear = {}, hg = {}, n = 0, name = name }
  local lines = 0
  for line in txt:gmatch('[^\r\n]+') do
    lines = lines + 1
    if S.yielding and lines % 800 == 0 then coroutine.yield() end
    local k, v = line:match('^# (%w+)=(.*)$')
    if k then G.meta[k] = v
    elseif line:sub(1, 2) == 'S,' then
      local a, b, c = line:match('^S,([^,]+),([^,]+),([^,]+)')
      G.cl = G.cl or {}
      G.cl[#G.cl + 1] = { tonumber(a), tonumber(b), tonumber(c) }
    elseif line:match('^%-?%d') then
      local f = {}
      for x in line:gmatch('[^,]+') do f[#f + 1] = tonumber(x) end
      if #f >= 15 then
        G.n = G.n + 1
        local n = G.n
        G.t[n], G.pos[n], G.x[n], G.y[n], G.z[n] = f[1], f[2], f[3], f[4], f[5]
        G.lx[n], G.ly[n], G.lz[n], G.ux[n], G.uy[n], G.uz[n] = f[6], f[7], f[8], f[9], f[10], f[11]
        G.spd[n], G.gas[n], G.brk[n], G.gear[n] = f[12], f[13], f[14], f[15]
        G.hg[n] = (f[16] and f[16] > -50) and f[16] or nil
      end
    end
  end
  if G.n < 50 then return nil end
  G.lapMs = tonumber(G.meta.lapMs) or G.t[G.n] * 1000
  return G
end

-- file name: <track[-layout]>__<car>__<driver>__<m-ss-mmm>.csv (read from the name only: no file is opened)
local function parseGhostName(f)
  local base = f:gsub('%.csv$', '')
  local parts = {}
  for p in (base .. '__'):gmatch('(.-)__') do parts[#parts + 1] = p end
  local e = { file = f, track = parts[1] or '?', car = parts[2] or '?', driver = '?', lapMs = nil }
  if #parts >= 4 then
    local m, s, ms = parts[#parts]:match('^(%d+)%-(%d+)%-(%d+)$')
    if m then e.lapMs = tonumber(m) * 60000 + tonumber(s) * 1000 + tonumber(ms) end
    e.driver = table.concat(parts, '__', 3, #parts - 1)
  elseif #parts == 3 then
    e.driver = parts[3]
  end
  return e
end

local function listGhosts()
  local out = {}
  local ok, files = pcall(io.scanDir, ghostDir(), '*.csv')
  if ok and type(files) == 'table' then
    for _, f in ipairs(files) do out[#out + 1] = f end
  end
  local key = trackKey() .. '__'
  table.sort(out, function(a, b)
    local sa, sb = a:sub(1, #key) == key, b:sub(1, #key) == key
    if sa ~= sb then return sa end
    return a < b
  end)
  return out
end

-- ---------------------------------------------------------------------------
-- Lap recording (replay: focused car; live: your car)
local REC = { active = false, cur = nil, laps = {}, lastFrame = -1, prevPos = nil, prevT = nil, carIndex = -1 }

local function newLap() return { rows = {}, n = 0, t0 = nil } end

local function recSample(car, t)
  local p, l, u = readTransform(car)
  if not p then return end
  local pos = num(opt(car, 'splinePosition'), 0)
  -- crossing the line: exact time by interpolation
  if REC.prevPos and REC.prevPos > 0.9 and pos < 0.1 then
    local d = (1 - REC.prevPos) + pos
    local tc = REC.prevT + (t - REC.prevT) * ((1 - REC.prevPos) / math.max(d, 1e-6))
    local L = REC.cur
    if L and L.t0 and L.n > 50 then
      L.ms = (tc - L.t0) * 1000
      REC.laps[#REC.laps + 1] = L
      if #REC.laps > 30 then table.remove(REC.laps, 1) end
    end
    REC.cur = newLap()
    REC.cur.t0 = tc
  end
  local L = REC.cur
  if L and L.t0 then
    L.n = L.n + 1
    L.rows[L.n] = string.format('%.3f,%.5f,%.3f,%.3f,%.3f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.1f,%.2f,%.2f,%d,%.3f',
      t - L.t0, pos, p.x, p.y, p.z, l.x, l.y, l.z, u.x, u.y, u.z, num(opt(car, 'speedKmh')),
      num(opt(car, 'gas')), num(opt(car, 'brake')), math.floor(num(opt(car, 'gear'))), heightAboveGround(p))
  end
  REC.prevPos, REC.prevT = pos, t
end

local function recReset()
  REC.cur, REC.prevPos, REC.prevT, REC.lastFrame = newLap(), nil, nil, -1
end

local function updateReplayRecording(sim)
  if not REC.active then return end
  local idx = math.floor(num(opt(sim, 'focusedCar'), 0))
  if idx ~= REC.carIndex then REC.carIndex = idx; recReset() end
  local car = ac.getCar(idx)
  if not car then return end
  local frame = math.floor(num(opt(sim, 'replayCurrentFrame'), -1))
  if frame == REC.lastFrame then return end
  -- rewind or jump: the lap in progress is dropped
  if REC.lastFrame >= 0 and (frame < REC.lastFrame or frame - REC.lastFrame > 6) then recReset() end
  REC.lastFrame = frame
  local t = frame * num(opt(sim, 'replayFrameMs'), 16.67) / 1000
  recSample(car, t)
end

-- Replay scan: finds and records the laps of the focused car by moving the replay position
-- (ac.setReplayPosition), without playing the replay in real time.
-- coarse: one sample per second over the whole replay -> line crossings -> lap list
-- fine: one sample every ~50 ms over the chosen lap -> ghost (same recorder as live recording)
local SCAN = { phase = nil, laps = {}, car = -1 }
local function scanFrameMs(sim) return math.max(num(opt(sim, 'replayFrameMs'), 16.67), 1) end

local function scanStart(sim, phase, car, f0, f1, step, lapIndex)
  SCAN.phase, SCAN.car, SCAN.f0, SCAN.f1, SCAN.step = phase, car, math.max(0, f0), f1, math.max(1, step)
  SCAN.next, SCAN.wait, SCAN.samples, SCAN.lapIndex = SCAN.f0, 0, {}, lapIndex
  if not SCAN.home then SCAN.home = math.floor(num(opt(sim, 'replayCurrentFrame'), 0)) end
  if phase == 'fine' then recReset() end
  pcall(ac.setReplayPosition, SCAN.next, 0)
end

local function scanFinish(sim, msg)
  pcall(ac.setReplayPosition, SCAN.home or 0, 0)
  SCAN.phase, SCAN.home = nil, nil
  if msg then say(msg) end
end

local saveScannedLap   -- defined with the interface helpers

local function updateScan(sim)
  if not SCAN.phase then return end
  local cur = math.floor(num(opt(sim, 'replayCurrentFrame'), -1))
  -- the position request is applied on the next frame: wait for it (max 10 frames)
  if math.abs(cur - SCAN.next) > 1 then
    SCAN.wait = SCAN.wait + 1
    if SCAN.wait < 10 then pcall(ac.setReplayPosition, SCAN.next, 0); return end
  end
  SCAN.wait = 0
  local car = ac.getCar(SCAN.car)
  if car then
    local t = cur * scanFrameMs(sim) / 1000
    if SCAN.phase == 'coarse' then
      SCAN.samples[#SCAN.samples + 1] = { f = cur, pos = num(opt(car, 'splinePosition'), 0), pit = opt(car, 'isInPitlane') == true }
    else
      recSample(car, t)
    end
  end
  SCAN.next = SCAN.next + SCAN.step
  if SCAN.next <= SCAN.f1 then pcall(ac.setReplayPosition, SCAN.next, 0) end
  if SCAN.next > SCAN.f1 then
    if SCAN.phase == 'coarse' then
      -- line crossings -> complete laps
      local cross, S_ = {}, SCAN.samples
      for i = 2, #S_ do
        if S_[i - 1].pos > 0.9 and S_[i].pos < 0.1 and S_[i].f - S_[i - 1].f <= SCAN.step * 2 then
          local d = (1 - S_[i - 1].pos) + S_[i].pos
          cross[#cross + 1] = { f = S_[i - 1].f + (S_[i].f - S_[i - 1].f) * (1 - S_[i - 1].pos) / math.max(d, 1e-6), i = i }
        end
      end
      SCAN.laps = {}
      local fms = scanFrameMs(sim)
      for k = 2, #cross do
        local a, b = cross[k - 1], cross[k]
        local pit = false
        for i = a.i, b.i do if S_[i].pit then pit = true end end
        SCAN.laps[#SCAN.laps + 1] = { n = #SCAN.laps + 1, fa = a.f, fb = b.f, ms = (b.f - a.f) * fms, pit = pit }
      end
      scanFinish(sim, #SCAN.laps > 0 and string.format('%d complete lap(s) found', #SCAN.laps) or 'No complete lap found for this car')
    else
      local L = REC.laps[#REC.laps]
      local lap = SCAN.laps[SCAN.lapIndex]
      if L and lap and math.abs(L.ms - lap.ms) < 1500 then
        lap.rec = L
        if saveScannedLap then saveScannedLap(lap) end
        scanFinish(sim, nil)
      else
        scanFinish(sim, 'Lap could not be recorded (replay position not reached): try again or use live recording')
      end
    end
  end
end

-- Live laps of your car: your best lap is kept as a ghost automatically.
-- Time attack mode: if the lap that just ended beats the current ghost, it becomes the ghost
-- right away (at the line), without reloading any file.
local OWN = { cur = nil, best = nil, lastLap = nil }
local KEYS = { 't', 'pos', 'x', 'y', 'z', 'lx', 'ly', 'lz', 'ux', 'uy', 'uz', 'spd', 'gas', 'brk', 'gear', 'hg' }
local function newOwnLap()
  local L = { rows = {}, n = 0 }
  for _, k in ipairs(KEYS) do L[k] = {} end
  return L
end
local onOwnLap   -- defined further down (ghost switch)

local function updateOwnRecording(car)
  local lc = num(opt(car, 'lapCount'), 0)
  if OWN.lastLap == nil then OWN.lastLap = lc end
  if lc ~= OWN.lastLap then
    local L = OWN.cur
    local ms = num(opt(car, 'previousLapTimeMs'), -1)
    local valid = opt(car, 'isLastLapValid')
    -- validity: last-lap flag if available, plus isLapValid watched during the whole lap
    if lc > OWN.lastLap and L and L.n > 50 and not L.pit and not L.invalid and ms > 0 and valid ~= false then
      -- drop the samples taken after the line (position back near 0)
      while L.n > 1 and L.pos[L.n] < 0.5 do
        for _, k in ipairs(KEYS) do L[k][L.n] = nil end
        L.rows[L.n] = nil
        L.n = L.n - 1
      end
      L.ms = ms
      if onOwnLap then onOwnLap(L) end
    end
    OWN.cur = newOwnLap()
    OWN.lastLap = lc
  end
  local L = OWN.cur
  if not L then return end
  if opt(car, 'isInPitlane') then L.pit = true end
  if opt(car, 'isLapValid') == false then L.invalid = true end
  local pos = num(opt(car, 'splinePosition'), 0)
  if L.n == 0 and pos > 0.5 then return end   -- samples before the line
  local p, l, u = readTransform(car)
  local tt = num(opt(car, 'lapTimeMs')) / 1000
  local spd, gas, brk, gear = num(opt(car, 'speedKmh')), num(opt(car, 'gas')), num(opt(car, 'brake')), math.floor(num(opt(car, 'gear')))
  local hg = heightAboveGround(p)
  local n = L.n + 1
  L.n = n
  L.t[n], L.pos[n], L.x[n], L.y[n], L.z[n] = tt, pos, p.x, p.y, p.z
  L.lx[n], L.ly[n], L.lz[n], L.ux[n], L.uy[n], L.uz[n] = l.x, l.y, l.z, u.x, u.y, u.z
  L.spd[n], L.gas[n], L.brk[n], L.gear[n], L.hg[n] = spd, gas, brk, gear, (hg > -50) and hg or nil
  L.rows[n] = string.format('%.3f,%.5f,%.3f,%.3f,%.3f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.1f,%.2f,%.2f,%d,%.3f',
    tt, pos, p.x, p.y, p.z, l.x, l.y, l.z, u.x, u.y, u.z, spd, gas, brk, gear, hg)
end

-- ---------------------------------------------------------------------------
-- Ghost display
local GH = { G = nil, node = nil, model = nil, err = nil, delta = nil, idx = 1, visible = false, cache = {}, carId = nil,
  parts = {}, skin = {}, livery = {}, unique = {}, draw = nil, fade = 1, fading = false }

-- KN5 files of a car: main model and lower detail ones (LOD B, C) when present
local function findKN5(carId)
  local dir = ac.getFolder(ac.FolderID.ContentCars) .. '\\' .. carId .. '\\'
  local ok, files = pcall(io.scanDir, dir, '*.kn5')
  if not ok or type(files) ~= 'table' or #files == 0 then return nil end
  local main, best, bestSize = nil, nil, -1
  local lods = {}
  for _, f in ipairs(files) do
    local lf = f:lower()
    if lf == (carId:lower() .. '.kn5') then main = f end
    local l = lf:match('lod[_%-]?([bcd])%.kn5$')
    if l then lods[l] = dir .. f end
    if not lf:find('lod') and not lf:find('collider') then
      local sz = 0
      pcall(function() sz = io.getAttributes(dir .. f).fileSize or 0 end)
      if sz > bestSize then best, bestSize = f, sz end
    end
  end
  local pick = main or best
  if not pick then return nil end
  return dir .. pick, lods
end

-- Ghost look: 0 = full car (its own materials), 1 = see-through ghost.
-- AC's main car shader (ksPerPixelMultiMap) ignores the alpha of its textures, so a car cannot be made see-through by
-- changing its materials. GhostLab draws the see-through ghost, and the full car while it fades out near you, itself:
-- render.mesh() with its own shader on the car's meshes, which are hidden from the normal scene meanwhile.
local CAN_DRAW = (render and render.on and render.mesh and render.setBlendMode and render.setDepthMode) and true or false
local GHOST_TINT = { 0.45, 0.80, 1.00 }

local SH_GHOST = [[
float4 main(PS_IN pin) {
  float3 n = normalize(pin.NormalW);
  float3 v = normalize(-pin.PosC);
  float e = 1 - saturate(abs(dot(n, v)));
  float e2 = e * e;
  float3 c = gTint * (0.30 + 0.25 * saturate(n.y * 0.5 + 0.5) + 0.90 * e2);
  return float4(c * gWhiteRefPoint, saturate(gAlpha * (0.30 + 1.30 * e2)));
}]]
-- depth only (writes nothing visible): keeps the nearest surface of the fading car for the colour pass
local SH_DEPTH = [[
float4 main(PS_IN pin) {
  return float4(0, 0, 0, 0);
}]]
-- fading full car: lit body in the car's livery colour, nearest surface only
local SH_SOLID = [[
float4 main(PS_IN pin) {
  float3 n = normalize(pin.NormalW);
  float3 v = normalize(-pin.PosC);
  float ndv = dot(n, v);
  if (ndv < 0) { n = -n; ndv = -ndv; }
  float3 base = gColor;
  if (gHasLivery > 0.5) base = txLivery.SampleLevel(samLinearClamp, float2(0.5, 0.5), 8).rgb;
  base = toLinearColorSpace(base);
  float lambert = saturate(dot(n, -gLightDirection));
  float3 lit = base * (gAmbientColor * (0.40 + 0.15 * n.y) + gLightColor * (0.45 * lambert));
  float fres = pow(1 - saturate(ndv), 5);
  float3 sky = gAmbientColor * 0.6 + gLightColor * 0.05;
  return float4(lit + sky * (0.05 + 0.6 * fres), gAlpha);
}]]

local DRAW = nil
local function drawParams()
  if DRAW then return DRAW end
  DRAW = {
    ghost = { mesh = nil, transform = 'original', async = true, cacheKey = 160101, textures = {},
      values = { gTint = vec3(GHOST_TINT[1], GHOST_TINT[2], GHOST_TINT[3]), gAlpha = 0.3 }, shader = SH_GHOST },
    depth = { mesh = nil, transform = 'original', async = true, cacheKey = 160102, textures = {}, values = {}, shader = SH_DEPTH },
    solid = { mesh = nil, transform = 'original', async = true, cacheKey = 160103, textures = { txLivery = false },
      values = { gColor = vec3(0.55, 0.57, 0.60), gAlpha = 1, gHasLivery = 0 }, shader = SH_SOLID },
    shape = { mesh = 0, transform = nil, async = true, cacheKey = 160104, textures = {},
      values = { gTint = vec3(GHOST_TINT[1], GHOST_TINT[2], GHOST_TINT[3]), gAlpha = 0.3 }, shader = SH_GHOST },
  }
  return DRAW
end

-- meshes of a loaded model, grouped by cull mode (drawn the way the game draws them)
local function buildParts(node)
  local P = { all = nil, groups = {}, shown = true }
  local ok = pcall(function()
    P.all = node:findMeshes('?')
    local by = {}
    for i = 1, #P.all do
      local cm = tonumber(P.all:cullMode(i)) or 2
      if cm ~= 0 and cm ~= 1 then cm = 2 end
      if not by[cm] then by[cm] = ac.emptySceneReference() end
      by[cm]:append(P.all:at(i))
    end
    for _, cm in ipairs({ 0, 1, 2 }) do
      if by[cm] then P.groups[#P.groups + 1] = { ref = by[cm], cull = cm } end
    end
  end)
  if not P.all then return nil end
  if not ok or #P.groups == 0 then P.groups = { { ref = P.all, cull = 2 } } end
  return P
end

-- real meshes shown in the scene (full car) or hidden (drawn by GhostLab)
local function setMeshesShown(P, v)
  if not P or P.shown == v then return end
  pcall(function() P.all:setVisible(v, v) end)
  P.shown = v
end

-- skin of the ghost model: the one recorded with the ghost, else yours (same car), else the car's first skin
local function carDir(carId) return ac.getFolder(ac.FolderID.ContentCars) .. '\\' .. carId .. '\\' end
local function pickSkin(carId, wanted, firstOnly)
  local skins = carDir(carId) .. 'skins\\'
  local function has(sk) return sk ~= nil and sk ~= '' and io.dirExists and io.dirExists(skins .. sk) end
  if not firstOnly then
    if has(wanted) then return wanted end
    local own
    pcall(function() if ac.getCarID(0) == carId then own = ac.getCarSkinID(0) end end)
    if has(own) then return own end
  end
  local first
  pcall(function()
    io.scanDir(skins, '*', function(name, attr)
      if attr and attr.isDirectory then first = name; return true end
    end)
  end)
  return first
end

local function isNode(v) return v ~= nil and v ~= false and v ~= 'loading' end

-- Skin of the ghost model. By default the model keeps the textures built into the car's KN5 (no texture loading,
-- no freeze); with "Use the ghost's skin" on, the skin is applied (loading its textures can take a moment).
local function applyGhostSkin(carId, wanted, key)
  GH.pendingSkin = GH.pendingSkin or {}
  GH.unique = GH.unique or {}
  local useSkin = cfg.useSkins == 1
  local skin = pickSkin(carId, wanted, not useSkin)
  if skin then
    local lv = carDir(carId) .. 'skins\\' .. skin .. '\\livery.png'
    GH.livery[carId] = (io.fileExists and io.fileExists(lv)) and lv or false   -- colour of the fading full car (small file)
  end
  if not key or not useSkin or not skin then return end
  local node = GH.cache[key]
  if node == 'loading' then GH.pendingSkin[key] = wanted or '' return end   -- applied once the model is loaded
  if not isNode(node) or GH.skin[key] == skin then return end
  if not GH.unique[key] then
    local t0 = clock()
    pcall(function() node:findMeshes('?'):ensureUniqueMaterials() end)   -- the skin stays on the ghost only
    GH.unique[key] = true
    perf('materials', t0)
  end
  local t1 = clock()
  pcall(function() node:applySkin(carDir(carId) .. 'skins\\' .. skin) end)
  perf('skin', t1)
  GH.skin[key] = skin
end

local onModelReady   -- set below: called when a model finishes loading
local function modelKey(carId, textured) return carId .. (textured and '#full' or '#shape') end

-- 3D model of a car, loaded once in the background and kept hidden for later switches. Returns node, error, loading.
-- textured = true (full car look): the car with its textures (LOD B when "Light ghost model" is on).
-- textured = false (see-through look, car not in the session): a lower detail KN5 alone, no textures to load.
local function ensureModel(carId, textured)
  local key = modelKey(carId, textured)
  local c = GH.cache[key]
  GH.cacheErr = GH.cacheErr or {}
  if c == 'loading' then return nil, nil, true end
  if c ~= nil then return c or nil, c == false and (GH.cacheErr[key] or '3D model unavailable') or nil, false end
  local kn5, lods = findKN5(carId)
  if not kn5 then
    GH.cache[key] = false
    GH.cacheErr[key] = 'Car "' .. carId .. '" is not installed: delta only, no 3D model.'
    return nil, GH.cacheErr[key], false
  end
  local node
  local ok, err = pcall(function()
    local root = ac.findNodes('carsRoot:yes')
    node = root:createBoundingSphereNode('GhostLab_' .. key, 4) or root:createNode('GhostLab_' .. key, false)
    node:setVisible(false)
  end)
  if not ok or not node then
    if node then pcall(function() node:dispose() end) end
    GH.cache[key] = false
    GH.cacheErr[key] = '3D model not loaded (' .. tostring(err) .. '): delta only.'
    return nil, GH.cacheErr[key], false
  end
  GH.cache[key] = 'loading'
  GH.modelInfo = GH.modelInfo or {}
  local function done(errL, model)
    if errL or not model then
      pcall(function() node:dispose() end)
      GH.cache[key] = false
      GH.cacheErr[key] = '3D model not loaded (' .. tostring(errL or 'no model') .. '): delta only.'
    else
      pcall(function() node:setShadows(cfg.shadows == 1); node:setVisible(false) end)
      local t0 = clock()
      GH.parts = GH.parts or {}
      GH.parts[key] = buildParts(node)
      perf('model setup', t0)
      GH.cache[key] = node
      local nm = 0
      pcall(function() nm = #node:findMeshes('?') end)
      S.event, S.eventT = string.format('%s added (%s, %d meshes)', carId, GH.modelInfo[key] or 'model', nm), S.t
      if textured then
        local pending = GH.pendingSkin and GH.pendingSkin[key]
        if pending then GH.pendingSkin[key] = nil; applyGhostSkin(carId, pending ~= '' and pending or nil, key) end
      end
    end
    if onModelReady then onModelReady(key) end
  end
  local t0 = clock()
  if not textured then
    local file = lods.c or lods.b or kn5
    GH.modelInfo[key] = (file == kn5) and 'full model, no LOD' or 'low detail model'
    if node.loadKN5Async then
      local okA, errA = pcall(function() node:loadKN5Async(file, done) end)
      if not okA then done(tostring(errA), nil) end
    else
      local okS, model = pcall(function() return node:loadKN5(file) end)
      done(not okS and tostring(model) or nil, okS and model or nil)
    end
    perf('model request (see-through)', t0)
  elseif lods.b and cfg.lightModel == 1 and node.loadKN5LODAsync then
    GH.modelInfo[key] = 'light model'
    local okA, errA = pcall(function() node:loadKN5LODAsync(lods.b, kn5, done) end)
    if not okA then done(tostring(errA), nil) end
    perf('model request (full car)', t0)
  elseif node.loadKN5Async then
    GH.modelInfo[key] = 'full model'
    local okA, errA = pcall(function() node:loadKN5Async(kn5, done) end)
    if not okA then done(tostring(errA), nil) end
    perf('model request (full car)', t0)
  else
    local okS, model = pcall(function() return node:loadKN5(kn5) end)
    perf('model load (old CSP, not in background)', t0)
    done(not okS and tostring(model) or nil, okS and model or nil)
  end
  local now = GH.cache[key]
  if now == 'loading' then return nil, nil, true end
  return isNode(now) and now or nil, not isNode(now) and GH.cacheErr[key] or nil, false
end

local function unloadGhost()
  if GH.node then pcall(function() GH.node:setVisible(false) end) end
  GH.node, GH.G, GH.delta, GH.visible, GH.carId, GH.modelId, GH.draw, GH.loadingModel = nil, nil, nil, false, nil, nil, nil, nil
  GH.render, GH.shapeIdx = nil, nil
end

-- car of the session using this model (your car first): its simple shape from CSP is drawn as the see-through
-- ghost with nothing to load
local CAN_SHAPE = CAN_DRAW and ac.SimpleMesh ~= nil and ac.SimpleMesh.carShape ~= nil and mat4x4 ~= nil
local function sessionIndexOf(carId)
  local n = 1
  pcall(function() n = math.max(1, ac.getSim().carsCount or 1) end)
  for i = 0, n - 1 do
    local ok, id = pcall(ac.getCarID, i)
    if ok and id == carId then return i end
  end
  return nil
end

-- model of the current ghost: its own car, else your car as a stand-in (setting); waits for models still loading
local function attachModel()
  local G = GH.G
  if not G then return end
  local carId = G.meta.car or ''
  local ghostLook = cfg.style == 1 and CAN_DRAW
  local cars = { carId }
  if cfg.standIn == 1 then
    local own = ac.getCarID(0)
    if own and own ~= '' and own ~= carId then cars[2] = own end
  end
  local standInMsg = 'Car "' .. carId .. '" is not installed: shown with your car as a stand-in (trajectory and delta are the ghost\'s).'
  local firstErr
  GH.render, GH.shapeIdx = nil, nil
  for k, cid in ipairs(cars) do
    local standIn = k > 1
    if standIn and not firstErr then break end
    if ghostLook and CAN_SHAPE then
      local idx = sessionIndexOf(cid)
      if idx then
        if GH.node then pcall(function() GH.node:setVisible(false) end) end
        GH.loadingModel, GH.node, GH.modelId, GH.visible = nil, nil, nil, false
        GH.render, GH.shapeIdx, GH.standIn = 'shape', idx, standIn
        if standIn then GH.err = standInMsg end
        return
      end
    end
    local textured = not ghostLook
    local node, err, loading = ensureModel(cid, textured)
    if loading then
      GH.loadingModel, GH.node, GH.modelId = modelKey(cid, textured), nil, nil
      if standIn then GH.err = 'Car "' .. carId .. '" is not installed: loading your car as a stand-in...' end
      return
    end
    if node then
      GH.loadingModel = nil
      GH.render, GH.node, GH.modelId, GH.modelCar, GH.standIn, GH.visible = 'node', node, modelKey(cid, textured), cid, standIn, false
      if standIn then GH.err = standInMsg end
      if textured then applyGhostSkin(cid, (not standIn) and G.meta.skin or nil, GH.modelId)
      else applyGhostSkin(cid, nil, nil) end
      return
    end
    firstErr = firstErr or err
  end
  GH.loadingModel, GH.node, GH.modelId = nil, nil, nil
  if firstErr then GH.err = firstErr end
end

onModelReady = function(key)
  if GH.loadingModel == key then attachModel() end
end

-- installs a ghost that is already in memory (loaded file or lap that just ended)
local function useGhost(G)
  local carId = G.meta.car or ''
  local same = GH.render and GH.carId == carId
  if GH.node and not same then pcall(function() GH.node:setVisible(false) end) end
  GH.G, GH.idx, GH.delta, GH.ySm, GH.draw, GH.carId = G, 1, nil, nil, nil, carId
  if same then
    if GH.render == 'node' and not GH.standIn and GH.modelId and GH.modelId:find('#full', 1, true) then
      applyGhostSkin(GH.modelCar, G.meta.skin, GH.modelId)
    end
  else
    GH.node, GH.visible = nil, false
    attachModel()
  end
end

-- ---------------------------------------------------------------------------
-- Alignment on another version of the same circuit (Spa OSRW -> Spa Kunos, etc.)
-- 1. centerlines of both tracks (AI spline); 2. start line offset found by correlating the curvatures;
-- 3. rotation + translation (+ scale) by least squares, refined with closest points;
-- 4. local height correction; 5. ghost lap timer restarted at the current track's finish line.
local function headings(C)
  local n, h = #C, {}
  for i = 1, n do
    local a, b = C[(i - 3) % n + 1], C[(i + 1) % n + 1]
    h[i] = math.atan2(b[3] - a[3], b[1] - a[1])
  end
  local d = {}
  for i = 1, n do
    local x = h[i % n + 1] - h[i]
    while x > math.pi do x = x - 2 * math.pi end
    while x < -math.pi do x = x + 2 * math.pi end
    d[i] = x
  end
  return d
end

local function pathLen(C)
  local L = 0
  for i = 1, #C do
    local a, b = C[i], C[i % #C + 1]
    L = L + math.sqrt((b[1] - a[1]) ^ 2 + (b[3] - a[3]) ^ 2)
  end
  return L
end

local function kabsch(A, B, pairs_)
  local n = #pairs_
  local ax, az, bx, bz = 0, 0, 0, 0
  for _, p in ipairs(pairs_) do
    local a, b = A[p[1]], p[3] or B[p[2]]
    ax, az, bx, bz = ax + a[1], az + a[3], bx + b[1], bz + b[3]
  end
  ax, az, bx, bz = ax / n, az / n, bx / n, bz / n
  local sc, ss, na, nb = 0, 0, 0, 0
  for _, p in ipairs(pairs_) do
    local a, b = A[p[1]], p[3] or B[p[2]]
    local x1, z1, x2, z2 = a[1] - ax, a[3] - az, b[1] - bx, b[3] - bz
    sc = sc + x1 * x2 + z1 * z2
    ss = ss + x1 * z2 - z1 * x2
    na = na + x1 * x1 + z1 * z1
    nb = nb + x2 * x2 + z2 * z2
  end
  local th = math.atan2(ss, sc)
  local scale = na > 0 and math.sqrt(nb / na) or 1
  return { th = th, c = math.cos(th), s = math.sin(th), scale = scale, ax = ax, az = az, bx = bx, bz = bz }
end

local function applyT(T, x, z)
  local dx, dz = (x - T.ax) * T.scale, (z - T.az) * T.scale
  return T.bx + T.c * dx - T.s * dz, T.bz + T.s * dx + T.c * dz
end

local function alignGhost(G)
  local A, B = G.cl, trackCenterline()
  if (not A or #A < 64) and G.n > 200 then
    -- ghost recorded without a centerline (GhostLab 1.0): use its own path instead
    A = {}
    local j = 1
    for k = 0, NCL - 1 do
      local target = k / NCL
      while j < G.n and G.pos[j] < target do j = j + 1 end
      A[#A + 1] = { G.x[j], G.y[j], G.z[j] }
    end
  end
  if not A or #A < 64 or #B < 64 then
    return nil, 'no centerline (ghost or track without an AI spline): cannot align'
  end
  local n = #A
  local dA, dB = headings(A), headings(B)
  -- start offset: circular correlation of the heading changes
  local bestK, bestS = 0, -1e18
  for k = 0, n - 1 do
    local sum = 0
    for i = 1, n do sum = sum + dA[i] * dB[(i - 1 + k) % n + 1] end
    if sum > bestS then bestS, bestK = sum, k end
  end
  local pairs_ = {}
  for i = 1, n, 2 do pairs_[#pairs_ + 1] = { i, (i - 1 + bestK) % n + 1 } end
  local T = kabsch(A, B, pairs_)
  -- refinement: closest points
  local rms = 0
  for _ = 1, 5 do
    pairs_, rms = {}, 0
    for i = 1, n, 2 do
      local x, z = applyT(T, A[i][1], A[i][3])
      local bj, bd = 1, 1e18
      for j = 1, #B do
        local d = (B[j][1] - x) ^ 2 + (B[j][3] - z) ^ 2
        if d < bd then bd, bj = d, j end
      end
      -- projection onto the neighbouring segments (continuous point, not only a vertex)
      local best, bestD = B[bj], bd
      for _, o in ipairs({ -1, 1 }) do
        local P0, P1 = B[bj], B[(bj - 1 + o) % #B + 1]
        local sx, sz = P1[1] - P0[1], P1[3] - P0[3]
        local l2 = sx * sx + sz * sz
        if l2 > 0 then
          local f = math.max(0, math.min(1, ((x - P0[1]) * sx + (z - P0[3]) * sz) / l2))
          local qx, qz = P0[1] + sx * f, P0[3] + sz * f
          local d = (qx - x) ^ 2 + (qz - z) ^ 2
          if d < bestD then bestD, best = d, { qx, P0[2] + (P1[2] - P0[2]) * f, qz } end
        end
      end
      pairs_[#pairs_ + 1] = { i, bj, best }
      rms = rms + bestD
    end
    rms = math.sqrt(rms / #pairs_)
    T = kabsch(A, B, pairs_)
  end
  local ratio = pathLen(B) / pathLen(A)
  if math.abs(T.scale - 1) > 0.05 then T.scale = 1 end
  -- local height difference, per centerline point
  local dy = {}
  for _, p in ipairs(pairs_) do dy[p[1]] = (p[3] or B[p[2]])[2] - A[p[1]][2] end
  local function dyAt(i)
    i = (i - 1) % n + 1
    local a = dy[i] or dy[i - 1] or dy[i + 1] or 0
    return a
  end
  -- sample transformation
  local np = {}
  for i = 1, G.n do
    local x, z = applyT(T, G.x[i], G.z[i])
    local ci = math.floor((G.pos[i] % 1) * n) + 1
    G.x[i], G.z[i], G.y[i] = x, z, G.y[i] + dyAt(ci)
    local lx, lz = T.c * G.lx[i] - T.s * G.lz[i], T.s * G.lx[i] + T.c * G.lz[i]
    local ux, uz = T.c * G.ux[i] - T.s * G.uz[i], T.s * G.ux[i] + T.c * G.uz[i]
    G.lx[i], G.lz[i], G.ux[i], G.uz[i] = lx, lz, ux, uz
    local okp, p = pcall(ac.worldCoordinateToTrackProgress, vec3(x, G.y[i], z))
    np[i] = okp and p or G.pos[i]
  end
  -- finish line of the current track: the ghost's lap timer starts there
  local cut = nil
  for i = 2, G.n do
    if np[i - 1] > 0.8 and np[i] < 0.2 then cut = i; break end
  end
  if cut then
    local lap = G.lapMs / 1000
    local f = (1 - np[cut - 1]) / math.max((1 - np[cut - 1]) + np[cut], 1e-6)
    local t0 = G.t[cut - 1] + (G.t[cut] - G.t[cut - 1]) * f
    local keys = { 't', 'pos', 'x', 'y', 'z', 'lx', 'ly', 'lz', 'ux', 'uy', 'uz', 'spd', 'gas', 'brk', 'gear', 'hg' }
    local NG = {}
    for _, k in ipairs(keys) do NG[k] = {} end
    local m = 0
    for j = 0, G.n - 1 do
      local i = (cut - 1 + j) % G.n + 1
      if j == 0 or i ~= cut then
        m = m + 1
        for _, k in ipairs(keys) do NG[k][m] = G[k][i] end
        local tt = G.t[i] - t0
        if tt < 0 then tt = tt + lap end
        NG.t[m] = tt
        NG.pos[m] = np[i]
      end
    end
    -- the last sample may run past the line: cut what comes back near 0
    while m > 2 and NG.pos[m] < 0.5 do m = m - 1 end
    for _, k in ipairs(keys) do G[k] = NG[k] end
    G.n = m
  else
    for i = 1, G.n do G.pos[i] = np[i] end
  end
  G.align = { rms = rms, deg = math.deg(T.th), shift = bestK / n, ratio = ratio }
  if rms > 15 then return G.align, string.format('doubtful alignment (mean error %.0f m): tracks too different?', rms) end
  return G.align, nil
end

local function selectGhost(name)
  GH.err = nil
  local tl = clock()
  local G = loadGhost(name)
  if not S.yielding then perf('ghost file', tl) end
  if not G then GH.err = 'Unreadable ghost file: ' .. name; return end
  -- another version of the track: automatic alignment
  local sameTrack = (G.meta.track or '') == ac.getTrackID() and (G.meta.layout or '') == (ac.getTrackLayout() or '')
  if not sameTrack then
    local ta = clock()
    local okA, info, warn = pcall(alignGhost, G)
    perf('alignment', ta)
    if not okA then GH.err = 'Alignment failed: ' .. tostring(info)
    elseif warn then GH.err = warn end
  end
  cfg.selected = name
  useGhost(G)
end

-- Time attack: called on every valid lap of your car
local TA = { beaten = 0, last = nil, pendingSave = nil }

-- light/full model switch: models are loaded again
local function reloadModels()
  for _, nd in pairs(GH.cache) do if isNode(nd) then pcall(function() nd:setVisible(false); nd:dispose() end) end end
  GH.cache, GH.parts, GH.skin, GH.unique, GH.livery, GH.pendingSkin = {}, {}, {}, {}, {}, {}
  GH.node, GH.modelId, GH.loadingModel, GH.draw, GH.render, GH.shapeIdx = nil, nil, nil, nil, nil, nil
  TA.preloaded = false
  if GH.G then GH.carId = nil; useGhost(GH.G) end
end

onOwnLap = function(L)
  local meta = { car = ac.getCarID(0), carName = ac.getCarName and ac.getCarName(0) or '', driver = OWN_DRIVER, source = 'live',
    skin = skinOf(0) }
  local target = GH.G and GH.G.lapMs or nil
  local beatsGhost = cfg.timeAttack == 1 and (not target or L.ms < target)
  local beatsOwn = not OWN.best or L.ms < OWN.best
  if beatsGhost then
    -- the lap becomes the ghost right away: it starts again with you on the lap that begins
    GH.err = nil
    local G = { meta = { car = meta.car, carName = meta.carName, driver = OWN_DRIVER, source = 'live', skin = meta.skin,
      track = ac.getTrackID(), layout = ac.getTrackLayout() or '' }, n = L.n, lapMs = L.ms, name = nil }
    for _, k in ipairs(KEYS) do G[k] = L[k] end
    local gain = target and (target - L.ms) / 1000 or nil
    useGhost(G)
    TA.beaten = TA.beaten + 1
    TA.last = gain
    say(gain and string.format('Ghost beaten by %.3f s: your %s lap is the new ghost', gain, fmtLap(L.ms))
      or ('Your ' .. fmtLap(L.ms) .. ' lap is the new ghost'))
  end
  if beatsOwn or beatsGhost then
    if beatsOwn then OWN.best = L.ms end
    -- file written 2 s later (no hitch when crossing the line)
    TA.pendingSave = { L = L, meta = meta, at = S.t + 2, select = beatsGhost }
  end
end

-- ghost sample at time t (local search, time moves forward)
local function ghostAt(G, t)
  if t <= G.t[1] then return 1, 0 end
  if t >= G.t[G.n] then return G.n - 1, 1 end
  local i = GH.idx
  if i < 1 or i >= G.n or G.t[i] > t then i = 1 end
  while i < G.n - 1 and G.t[i + 1] < t do i = i + 1 end
  GH.idx = i
  local span = G.t[i + 1] - G.t[i]
  return i, span > 0 and (t - G.t[i]) / span or 0
end

-- ghost time at lap position p (for the delta)
local function ghostTimeAtPos(G, p)
  local lo, hi = 1, G.n
  if p <= G.pos[1] then return G.t[1] end
  if p >= G.pos[G.n] then return G.t[G.n] end
  while hi - lo > 1 do
    local mid = math.floor((lo + hi) / 2)
    if G.pos[mid] <= p then lo = mid else hi = mid end
  end
  local span = G.pos[hi] - G.pos[lo]
  local f = span > 0 and (p - G.pos[lo]) / span or 0
  return G.t[lo] + (G.t[hi] - G.t[lo]) * f
end

local function lerp(a, b, f) return a + (b - a) * f end

-- 1 = fully visible, 0 = gone: smooth fade between "Fade over" + "Fully hidden within" and "Fully hidden within"
local function fadeAt(d)
  local band = math.max(tonumber(cfg.fadeLen) or 0, 0)
  local hide = math.max(tonumber(cfg.hideDist) or 0, 0)
  if band < 0.5 then return d < hide and 0 or 1 end
  local x = math.min(math.max((d - hide) / band, 0), 1)
  return x * x * (3 - 2 * x)
end

local function updateGhost(car)
  local G = GH.G
  if not G then return end
  do
    local p = readTransform(car)
    local h = p and heightAboveGround(p)
    if h and h > -50 and h < 2 then GH.ownH = GH.ownH and (GH.ownH + (h - GH.ownH) * 0.05) or h end
  end
  local t = num(opt(car, 'lapTimeMs'), 0) / 1000
  local pos = num(opt(car, 'splinePosition'), 0)
  local inPit = opt(car, 'isInPitlane') or opt(car, 'isInPit')
  -- delta: your time minus the ghost's time at the same place
  if not inPit and t > 0.5 and pos > 0.002 then
    GH.delta = t - ghostTimeAtPos(G, pos)
  end
  if not GH.node and GH.render ~= 'shape' then return end
  local show = cfg.showGhost == 1 and not inPit and t > 0 and t < G.t[G.n]
  local fade = 1
  if show then
    local i, f = ghostAt(G, t)
    local p = vec3(lerp(G.x[i], G.x[i + 1], f), lerp(G.y[i], G.y[i + 1], f), lerp(G.z[i], G.z[i + 1], f))
    -- glued to the ground: ground height of the current track + recorded ride height
    -- (older ghost without that data: your own car's height above the ground)
    local gy = groundY(p.x, p.y, p.z)
    if gy then
      local hg = G.hg[i] and G.hg[i + 1] and lerp(G.hg[i], G.hg[i + 1], f) or GH.ownH
      if hg then
        local target = gy + hg
        GH.ySm = GH.ySm and (GH.ySm + (target - GH.ySm) * 0.5) or target
        if math.abs(GH.ySm - target) > 1 then GH.ySm = target end
        p.y = GH.ySm
      end
    end
    p.y = p.y + cfg.yOffset
    local look = vec3(lerp(G.lx[i], G.lx[i + 1], f), lerp(G.ly[i], G.ly[i + 1], f), lerp(G.lz[i], G.lz[i + 1], f))
    local up = vec3(lerp(G.ux[i], G.ux[i + 1], f), lerp(G.uy[i], G.uy[i + 1], f), lerp(G.uz[i], G.uz[i + 1], f))
    pcall(function() look:normalize(); up:normalize() end)
    -- fades out as it gets close to you, gone when it is on top of you (so it never fills the cockpit)
    local cp = car.position
    local dx, dy, dz = p.x - cp.x, p.y - cp.y, p.z - cp.z
    fade = fadeAt(math.sqrt(dx * dx + dy * dy + dz * dz))
    if fade <= 0.004 then show = false end
    if show then
      if GH.node then pcall(function() GH.node:setPosition(p); GH.node:setOrientation(look, up) end) end
      GH.p = p
      if GH.render == 'shape' then
        local okM, M = pcall(function()
          -- CSP's simple shape of the car is in body space: placed like the body of the session car, moved to the ghost
          local bt = ac.getCar(GH.shapeIdx or 0).bodyTransform
          return bt:mul(mat4x4.look(bt.position, bt.look, bt.up)):mulSelf(mat4x4.look(p, look, up):inverseSelf())
        end)
        GH.shapeM = okM and M or nil
      end
    end
  end
  GH.fade = show and fade or 0
  if GH.render == 'shape' then
    if show and GH.shapeM then
      local D = GH.draw or {}
      D.mode, D.alpha, D.t = 'shape', cfg.alpha * fade, S.t
      GH.draw = D
    else
      GH.draw = nil
    end
    return
  end
  local P = GH.parts[GH.modelId]
  local drawn = CAN_DRAW and P ~= nil
  local ghostLook = cfg.style == 1 and drawn
  -- full car: its own materials, swapped for the fading version inside the fade zone (with a margin, no flicker)
  if not show or ghostLook or not drawn then GH.fading = false
  elseif GH.fading then GH.fading = fade < 0.995
  else GH.fading = fade < 0.98 end
  if show and not drawn and fade < 0.5 then show = false end   -- CSP without render.mesh: hidden halfway, as before
  setMeshesShown(P, show and not ghostLook and not GH.fading)
  if show ~= GH.visible then
    pcall(function() GH.node:setVisible(show) end)
    GH.visible = show
  end
  if show and (ghostLook or GH.fading) then
    local D = GH.draw or {}
    D.mode = ghostLook and 'ghost' or 'fade'
    D.alpha = ghostLook and cfg.alpha * fade or fade
    D.t = S.t
    GH.draw = D
  else
    GH.draw = nil
  end
end

-- drawing of the see-through ghost and of the fading full car (main view; ghost look also in the mirrors)
local function drawGroups(P, params)
  for _, g in ipairs(P.groups) do
    render.setCullMode(g.cull)
    params.mesh = g.ref
    g.ref:setVisible(true, false)
    pcall(render.mesh, params)
    g.ref:setVisible(false, false)
  end
end

local function drawGhost(pass)
  local D = GH.draw
  if not D or S.t - (D.t or -10) > 0.25 then return end
  if D.mode == 'shape' then
    if not GH.shapeM or not GH.shapeIdx then return end
    local R = drawParams()
    render.setBlendMode(render.BlendMode.AlphaBlend)
    render.setDepthMode(render.DepthMode.ReadOnly)
    render.setCullMode(render.CullMode.None)
    R.shape.values.gAlpha = D.alpha
    R.shape.transform = GH.shapeM
    R.shape.mesh = ac.SimpleMesh.carShape(GH.shapeIdx, false)
    pcall(render.mesh, R.shape)
    return
  end
  if not GH.node then return end
  local P = GH.parts[GH.modelId]
  if not P then return end
  if pass == 'mirror' and D.mode ~= 'ghost' then return end
  if pass == 'main' and GH.p then
    -- entirely behind the camera: nothing to draw
    local okB, behind = pcall(function()
      local cp, cf = ac.getCameraPosition(), ac.getCameraForward()
      return (GH.p.x - cp.x) * cf.x + (GH.p.y - cp.y) * cf.y + (GH.p.z - cp.z) * cf.z < -3.5
    end)
    if okB and behind then return end
  end
  local R = drawParams()
  render.setBlendMode(render.BlendMode.AlphaBlend)
  if D.mode == 'ghost' then
    R.ghost.values.gAlpha = D.alpha
    render.setDepthMode(render.DepthMode.ReadOnly)
    drawGroups(P, R.ghost)
  else
    -- nearest surface first (depth only), then the colour on that surface: a see-through car, not an X-ray
    render.setDepthMode(render.DepthMode.Normal)
    drawGroups(P, R.depth)
    local lv = GH.livery[GH.modelCar]
    R.solid.textures.txLivery = lv or false
    R.solid.values.gHasLivery = lv and 1 or 0
    R.solid.values.gAlpha = D.alpha
    render.setDepthMode(render.DepthMode.ReadOnlyLessEqual)
    drawGroups(P, R.solid)
  end
end

GH.drawErr = nil
if CAN_DRAW then
  local function hook(event, pass)
    pcall(render.on, event, function()
      if GH.drawErr then return end
      local ok, err = pcall(drawGhost, pass)
      if not ok then GH.drawErr = tostring(err) end
    end)
  end
  hook('main.track.transparent', 'main')
  hook('mirror.root.transparent', 'mirror')
end

-- ---------------------------------------------------------------------------
local ghostList, listT = {}, -10
local started = false
local STARTUP = nil
local justUpdated = cfg.justUpdated or ''
if justUpdated ~= '' then cfg.justUpdated = '' end
function script.update(dt)
  S.t = S.t + dt
  if dt > 0.1 and S.t > 1 then
    local ms = dt * 1000
    if ms > (S.hitchMs or 0) then
      S.hitchMs = ms
      S.hitchWhat = (S.event and S.t - dt - (S.eventT or -10) < 0.5) and S.event or 'nothing from GhostLab just before'
    end
  end
  local sim = ac.getSim()
  if not sim then return end
  if not started then
    started = true
    -- your best lap already saved for this car and this track ("me", or "moi" before 1.4): from the file names only
    local prefix = trackKey() .. '__' .. safeName(ac.getCarID(0)) .. '__'
    for _, f in ipairs(listGhosts()) do
      if f:sub(1, #prefix) == prefix then
        local e = parseGhostName(f)
        if isOwnDriver(e.driver) and e.lapMs and (not OWN.best or e.lapMs < OWN.best) then OWN.best = e.lapMs end
      end
    end
    if justUpdated ~= '' then say('GhostLab updated to ' .. VERSION) end
    -- time attack: your car's model loaded now, while you are still in the start menu
    if cfg.timeAttack == 1 and cfg.style ~= 1 and not TA.preloaded then
      TA.preloaded = true
      ensureModel(ac.getCarID(0), true)
      applyGhostSkin(ac.getCarID(0), skinOf(0), modelKey(ac.getCarID(0), true))
    end
    -- last selected ghost: loaded over a few frames (no hitch when the session starts)
    if cfg.selected ~= '' then
      local okList = false
      for _, f in ipairs(listGhosts()) do if f == cfg.selected then okList = true end end
      if okList then
        local name = cfg.selected
        STARTUP = coroutine.create(function() selectGhost(name) end)
      end
    end
  end
  if STARTUP then
    S.yielding = true
    local t0 = clock()
    local okC, errC = coroutine.resume(STARTUP)
    perf('ghost loading (per frame)', t0)
    S.yielding = false
    if not okC then GH.err = 'Could not load the ghost: ' .. tostring(errC) end
    if not okC or coroutine.status(STARTUP) == 'dead' then STARTUP = nil end
  end
  if not opt(sim, 'isReplayActive') and SCAN.phase then SCAN.phase, SCAN.home = nil, nil end
  if opt(sim, 'isReplayActive') then
    if GH.node and GH.visible then pcall(function() GH.node:setVisible(false) end); GH.visible = false end
    GH.draw = nil
    if SCAN.phase then updateScan(sim) else updateReplayRecording(sim) end
    return
  end
  if TA.pendingSave and S.t >= TA.pendingSave.at then
    local P = TA.pendingSave
    TA.pendingSave = nil
    if cfg.autoOwn == 1 or P.select then
      local name = saveGhost(P.L, P.meta)
      if name then
        listT = -10
        if P.select and GH.G and GH.G.lapMs == P.L.ms then GH.G.name = name; cfg.selected = name
        else say('New best lap saved as a ghost: ' .. fmtLap(P.L.ms)) end
      end
    end
  end
  if sim.isPaused then return end
  local car = ac.getCar(0)
  if not car then return end
  if cfg.timeAttack == 1 and cfg.style ~= 1 and not TA.preloaded then
    TA.preloaded = true
    ensureModel(ac.getCarID(0), true)   -- time attack or full car look switched on later
    applyGhostSkin(ac.getCarID(0), skinOf(0), modelKey(ac.getCarID(0), true))
  end
  local t0 = clock()
  if cfg.autoOwn == 1 or cfg.timeAttack == 1 then updateOwnRecording(car) end
  perf('lap recording', t0)
  t0 = clock()
  updateGhost(car)
  perf('ghost update', t0)
end

-- ---------------------------------------------------------------------------
-- Interface
local GREEN, ORANGE, GREY = rgbm(0.3, 0.9, 0.4, 1), rgbm(1, 0.7, 0.2, 1), rgbm(0.6, 0.6, 0.6, 1)
local UI = { confirmDelete = nil, confirmT = -10, lapSort = 1 }

-- GhostLab Exchange (src/exchange.lua): shared ghosts with titles, likes, comments, filters and search
local Exchange, exchangeErr = nil, nil
do
  local ok, res = pcall(function()
    return require('src/exchange')({
      S = S, VERSION = VERSION, say = say, fmtLap = fmtLap, ghostDir = ghostDir, safeName = safeName,
      listGhosts = function() return listGhosts() end, parseGhostName = parseGhostName, isOwnDriver = isOwnDriver,
      niceDriver = niceDriver, trackKey = trackKey,
      selectGhost = function(name) listT = -10; selectGhost(name) end, refreshList = function() listT = -10 end,
      standIn = function() return cfg.standIn == 1 end,
      GREEN = GREEN, ORANGE = ORANGE, GREY = GREY,
    })
  end)
  if ok then Exchange = res else exchangeErr = tostring(res) end
end

-- update check (src/updater.lua): message + one-click install when a newer GhostLab is released
local Updater = nil
pcall(function()
  Updater = require('src/updater')({ VERSION = VERSION, cfg = cfg, say = say, GREEN = GREEN, ORANGE = ORANGE, GREY = GREY })
end)

local function ghostLabel(e, otherTrack)
  local drv = isOwnDriver(e.driver) and 'You' or niceDriver(e.driver)
  return string.format('%s   %s   %s', fmtLap(e.lapMs), e.car, drv)
end

local function ghostEntry(e, otherTrack)
  if ui.selectable(ghostLabel(e, otherTrack) .. '##' .. e.file, cfg.selected == e.file) then selectGhost(e.file) end
end

local function byLapTime(a, b)
  local ta, tb = a.lapMs or math.huge, b.lapMs or math.huge
  if ta ~= tb then return ta < tb end
  return a.file < b.file
end

local function drawGhostList()
  local cur = trackKey()
  local myCar = safeName(ac.getCarID(0))
  local groups, order, here, hiddenTracks, hiddenCars = {}, {}, {}, 0, 0
  for _, f in ipairs(ghostList) do
    local e = parseGhostName(f)
    if cfg.carOnly == 1 and e.car ~= myCar then
      hiddenCars = hiddenCars + 1
    elseif e.track == cur then
      here[#here + 1] = e
    elseif cfg.trackOnly == 1 then
      hiddenTracks = hiddenTracks + 1
    else
      if not groups[e.track] then groups[e.track] = {}; order[#order + 1] = e.track end
      table.insert(groups[e.track], e)
    end
  end
  table.sort(here, byLapTime)
  table.sort(order)
  if #here == 0 then
    ui.textColored('No ghost for this track yet.', GREY)
  end
  if cfg.trackOnly == 1 then
    for _, e in ipairs(here) do ghostEntry(e, false) end
  else
    if #order > 0 then
      ui.textColored('A ghost from another track is aligned automatically: use it only on another version of the same circuit (e.g. Spa OSRW on Spa Kunos).', GREY)
    end
    ui.treeNode(string.format('%s  (current track, %d)###cur', cur, #here), ui.TreeNodeFlags.DefaultOpen, function()
      for _, e in ipairs(here) do ghostEntry(e, false) end
    end)
    for _, tk in ipairs(order) do
      local g = groups[tk]
      table.sort(g, byLapTime)
      ui.treeNode(string.format('%s  (%d)###t_%s', tk, #g, tk), function()
        for _, e in ipairs(g) do ghostEntry(e, true) end
      end)
    end
  end
  if hiddenTracks > 0 then
    ui.textColored(string.format('%d ghost(s) on other tracks hidden', hiddenTracks), GREY)
  end
  if hiddenCars > 0 then
    ui.textColored(string.format('%d ghost(s) of other cars hidden', hiddenCars), GREY)
  end
end

local function deleteSelected()
  local f = cfg.selected
  if f == '' then return end
  local ok = pcall(io.deleteFile, ghostDir() .. f)
  ghostList, listT = listGhosts(), S.t
  local still = false
  for _, g in ipairs(ghostList) do if g == f then still = true end end
  if still or not ok then
    say('Could not delete the file: use "Open ghosts folder"')
  else
    if GH.G and GH.G.name == f then unloadGhost() end
    cfg.selected = ''
    say('Ghost deleted: ' .. f)
  end
end

local function tabGhost()
  if S.t - listT > 3 then ghostList, listT = listGhosts(), S.t end
  ui.text('Track: ' .. trackKey())
  if ui.checkbox('Current track only', cfg.trackOnly == 1) then cfg.trackOnly = cfg.trackOnly == 1 and 0 or 1 end
  ui.sameLine()
  if ui.checkbox('Current car only', cfg.carOnly == 1) then cfg.carOnly = cfg.carOnly == 1 and 0 or 1 end
  if #ghostList == 0 then
    ui.textWrapped('No ghost yet. Use the Replay tab to record one, or just drive: your best lap becomes a ghost automatically.')
  else
    drawGhostList()
  end
  ui.separator()
  if GH.G then
    local m = GH.G.meta
    local drv = isOwnDriver(m.driver) and 'You' or (niceDriver(m.driver) ~= '' and niceDriver(m.driver) or (m.sharedBy or 'unknown driver'))
    ui.text(string.format('Ghost: %s (%s), %s', (m.carName and m.carName ~= '') and m.carName or (m.car or '?'), drv, fmtLap(GH.G.lapMs)))
    if GH.G.align then
      ui.text(string.format('Aligned on this track: mean error %.1f m, rotation %.0f°, length x%.3f', GH.G.align.rms, GH.G.align.deg, GH.G.align.ratio))
    end
    if GH.delta then
      ui.textColored(string.format('Delta: %+.2f s', GH.delta), GH.delta <= 0 and GREEN or rgbm(1, 0.5, 0.2, 1))
    end
    if ui.button('Remove ghost') then unloadGhost(); cfg.selected = '' end
  end
  if cfg.selected ~= '' then
    if GH.G then ui.sameLine() end
    local armed = UI.confirmDelete == cfg.selected and S.t - UI.confirmT < 4
    if ui.button(armed and 'Click again to delete the file' or 'Delete ghost file') then
      if armed then UI.confirmDelete = nil; deleteSelected()
      else UI.confirmDelete, UI.confirmT = cfg.selected, S.t end
    end
    if Exchange then
      ui.sameLine()
      if ui.button('Share on the Exchange') then Exchange.share(cfg.selected) end
    end
  end
  if GH.err then ui.textColored(GH.err, ORANGE) end
  ui.separator()
  if ui.checkbox('Show ghost', cfg.showGhost == 1) then cfg.showGhost = cfg.showGhost == 1 and 0 or 1 end
  if cfg.showGhost ~= 1 then
    ui.textDisabled(cfg.autoOwn == 1 and 'Ghost hidden: no car on track. The delta and the saving of your best laps keep working.'
      or 'Ghost hidden: no car on track. The delta keeps working.')
  else
  ui.setNextItemWidth(180)
  ui.combo('Ghost look', cfg.style == 1 and 'See-through ghost' or 'Full car', function()
    for k, name in ipairs({ 'Full car', 'See-through ghost' }) do
      if ui.selectable(name, cfg.style == k - 1) and cfg.style ~= k - 1 then
        cfg.style = k - 1
        GH.err = nil
        if GH.G then GH.carId = nil; useGhost(GH.G) end
      end
    end
  end)
  if cfg.style == 1 and not CAN_DRAW then
    ui.textColored('This CSP version cannot draw the see-through ghost: full car shown. Update CSP.', ORANGE)
  end
  if GH.drawErr then ui.textColored('Ghost drawing stopped: ' .. GH.drawErr, ORANGE) end
  -- look settings, folded by default
  ui.treeNode('Ghost settings###ghostSettings', function()
    if cfg.style == 1 then
      ui.setNextItemWidth(180)
      local va, cha = ui.slider('##alpha', cfg.alpha * 100, 5, 70, 'Opacity: %.0f%%')
      if cha then cfg.alpha = va / 100 end
    end
    if cfg.style ~= 1 and ui.checkbox('Ghost shadow', cfg.shadows == 1) then
      cfg.shadows = cfg.shadows == 1 and 0 or 1
      for _, nd in pairs(GH.cache) do if isNode(nd) then pcall(function() nd:setShadows(cfg.shadows == 1) end) end end
    end
    ui.setNextItemWidth(180)
    local vf, chf = ui.slider('##fade', cfg.fadeLen, 0, 20, 'Fade over %.0f m')
    if chf then cfg.fadeLen = vf end
    if ui.itemHovered() then
      ui.setTooltip('Close to your car the ghost fades out, then fades back in as it pulls away. 0: no fade.')
    end
    ui.setNextItemWidth(180)
    local v, ch = ui.slider('##hide', cfg.hideDist, 0, 15, 'Fully hidden within %.0f m')
    if ch then cfg.hideDist = v end
    ui.setNextItemWidth(180)
    local vy, chy = ui.slider('##yoff', cfg.yOffset * 100, -50, 50, 'Height: %+.0f cm')
    if chy then cfg.yOffset = vy / 100 end
    if ui.checkbox('Car not installed: show my car instead', cfg.standIn == 1) then
      cfg.standIn = cfg.standIn == 1 and 0 or 1
      if GH.G then GH.err = nil; GH.carId = nil; useGhost(GH.G) end
    end
    if ui.itemHovered() then
      ui.setTooltip('A ghost of a car you do not have is drawn with your own car\'s 3D model. Off: delta only, no car shown.')
    end
    if ui.checkbox('Use the ghost\'s skin', cfg.useSkins == 1) then
      cfg.useSkins = cfg.useSkins == 1 and 0 or 1
      if GH.G and GH.render == 'node' and GH.modelCar then
        applyGhostSkin(GH.modelCar, (not GH.standIn) and GH.G.meta.skin or nil, GH.modelId)
      end
    end
    if ui.itemHovered() then
      ui.setTooltip('Off (default): the car\'s built-in look, nothing to load. On: the skin recorded with the ghost (or yours); '
        .. 'loading its textures can freeze the game for a moment when a ghost loads.')
    end
    if ui.checkbox('Light ghost model (loads faster)', cfg.lightModel == 1) then
      cfg.lightModel = cfg.lightModel == 1 and 0 or 1
      reloadModels()
    end
    if ui.itemHovered() then
      ui.setTooltip('On (default): the car\'s lower detail model (LOD B) when it has one: much quicker to load, '
        .. 'hard to tell apart a few metres away. Off: the full detail model.')
    end
    local slow = {}
    for k, v in pairs(PERF) do if v >= 5 then slow[#slow + 1] = string.format('%s %.0f ms', k, v) end end
    table.sort(slow)
    if #slow > 0 then ui.textDisabled('Slowest steps: ' .. table.concat(slow, ', ')) end
    if S.hitchMs then ui.textDisabled(string.format('Longest frame: %.0f ms (%s)', S.hitchMs, S.hitchWhat or '?')) end
  end)
  if ui.checkbox('Save my best lap as a ghost', cfg.autoOwn == 1) then cfg.autoOwn = cfg.autoOwn == 1 and 0 or 1 end
  if ui.checkbox('Time attack: the ghost is always the best lap', cfg.timeAttack == 1) then
    cfg.timeAttack = cfg.timeAttack == 1 and 0 or 1
  end
  if cfg.timeAttack == 1 then
    ui.textWrapped('As soon as you beat the ghost on a valid lap, your lap replaces it when you cross the line.')
    if TA.beaten > 0 then
      ui.text(string.format('Ghost beaten %d time(s) this session%s', TA.beaten,
        TA.last and string.format(' (last gain %.3f s)', TA.last) or ''))
    end
  end
  end
  if ui.button('Open ghosts folder') then pcall(os.showInExplorer, ghostDir()) end
end

local function driverOf(idx)
  local ok, name = pcall(ac.getDriverName, idx)
  if ok and type(name) == 'string' and name ~= '' then return name end
  return 'Driver'
end

saveScannedLap = function(lap)
  local idx = SCAN.car
  local name = saveGhost(lap.rec, { car = ac.getCarID(idx), carName = ac.getCarName and ac.getCarName(idx) or '',
    driver = driverOf(idx), source = 'replay', skin = skinOf(idx) })
  if name then lap.saved = name; listT = -10; say('Ghost saved: ' .. fmtLap(lap.rec.ms) .. ' (' .. driverOf(idx) .. ')')
  else say('Could not save the ghost file') end
end

local function tabReplay()
  local sim = ac.getSim()
  if not opt(sim, 'isReplayActive') then
    ui.textWrapped('Open the replay in AC (Content Manager > Replays, or the in-game replay). Focus the car you want, then come back here.')
    return
  end
  local idx = math.floor(num(opt(sim, 'focusedCar'), 0))
  local car = ac.getCar(idx)
  ui.text(string.format('Focused car: %s (%s)', ac.getCarName and ac.getCarName(idx) or ac.getCarID(idx), driverOf(idx)))
  ui.separator()

  -- 1. export a lap without playing the replay
  ui.text('Export a lap of the focused car')
  if SCAN.phase then
    local span = math.max(SCAN.f1 - SCAN.f0, 1)
    local pr = math.min(1, math.max(0, (SCAN.next - SCAN.f0) / span))
    ui.textColored(string.format('%s... %.0f%%  (do not touch the replay controls)',
      SCAN.phase == 'coarse' and 'Looking for laps' or ('Recording lap ' .. tostring(SCAN.lapIndex)), pr * 100), ORANGE)
    if ui.button('Cancel') then scanFinish(sim, 'Cancelled') end
  else
    if SCAN.car ~= idx then SCAN.laps, SCAN.car = {}, idx end
    if ui.button(#SCAN.laps > 0 and 'Find laps again' or 'Find laps') then
      local fms = scanFrameMs(sim)
      local total = math.floor(num(opt(sim, 'replayFrames'), 0))
      if not ac.setReplayPosition then say('This CSP version cannot move the replay: use live recording below')
      elseif total < 10 then say('Replay length unknown: use live recording below')
      else scanStart(sim, 'coarse', idx, 0, total - 1, math.floor(1000 / fms + 0.5)) end
    end
    ui.textWrapped('Scans the whole replay for this car: no need to wait for the lap or to start before the line.')
    -- order of the list: fastest first by default
    local order = {}
    for k = 1, #SCAN.laps do order[k] = k end
    if #SCAN.laps > 1 then
      local labels = { 'Sort: fastest first', 'Sort: slowest first', 'Sort: lap order' }
      if ui.button(labels[UI.lapSort] .. '##lapSort') then UI.lapSort = UI.lapSort % 3 + 1 end
      local function t(k) local l = SCAN.laps[k] return tonumber(l.rec and l.rec.ms or l.ms) or math.huge end
      if UI.lapSort == 1 then table.sort(order, function(a, b) if t(a) ~= t(b) then return t(a) < t(b) end return a < b end)
      elseif UI.lapSort == 2 then table.sort(order, function(a, b) if t(a) ~= t(b) then return t(a) > t(b) end return a < b end) end
    end
    for _, k in ipairs(order) do
      local lap = SCAN.laps[k]
      ui.text(string.format('Lap %d: %s%s', lap.n, lap.rec and fmtLap(lap.rec.ms) or ('~' .. fmtLap(lap.ms)), lap.pit and '  (pit lane)' or ''))
      ui.sameLine()
      if lap.saved then ui.textColored('saved', GREEN)
      elseif ui.button('Export as ghost##scan' .. k) then
        local fms = scanFrameMs(sim)
        local coarse = math.floor(1000 / fms + 0.5)
        scanStart(sim, 'fine', idx, math.floor(lap.fa) - coarse, math.ceil(lap.fb) + coarse, math.floor(50 / fms + 0.5), k)
      end
    end
  end
  ui.separator()

  -- 2. live recording while the replay plays (previous method, still available)
  ui.treeNode('Live recording (while the replay plays)', function()
    local rate = num(opt(sim, 'replayPlaybackRate'), 1)
    if math.abs(rate - 1) > 0.01 then ui.textColored(string.format('Playback speed x%.2f: set it to x1 for an accurate ghost.', rate), ORANGE) end
    if ui.button(REC.active and 'Stop recording' or 'Start recording') then
      REC.active = not REC.active
      recReset()
      if REC.active then REC.laps = {} end
    end
    ui.textWrapped('Start playback before the finish line: every complete lap shows up below. Do not rewind during a lap (it would be dropped).')
    for k = #REC.laps, 1, -1 do
      local L = REC.laps[k]
      ui.text(string.format('Lap %d: %s', k, fmtLap(L.ms)))
      ui.sameLine()
      if not L.saved and ui.button('Save as ghost##' .. k) then
        local name = saveGhost(L, { car = ac.getCarID(idx), carName = ac.getCarName and ac.getCarName(idx) or '',
          driver = driverOf(idx), source = 'replay', skin = skinOf(idx) })
        if name then L.saved = true; say('Ghost saved: ' .. name); listT = -10 end
      elseif L.saved then ui.textColored('saved', GREEN) end
    end
  end)
end

function script.windowMain(dt)
  if Updater then pcall(Updater.banner) end
  ui.tabBar('ghostlab', function()
    ui.tabItem('Ghost', tabGhost)
    ui.tabItem('Replay', tabReplay)
    local sel = Exchange and Exchange.selectTab
    if Exchange then Exchange.selectTab = false end
    ui.tabItem('Exchange', sel and ui.TabItemFlags.SetSelected or 0, function()
      if Exchange then Exchange.tab() else ui.textColored('Exchange unavailable: ' .. tostring(exchangeErr), ORANGE) end
    end)
  end)
  if S.t - S.msgT < 4 then ui.textColored(S.msg, GREEN) end
end

function script.windowDelta(dt)
  if not GH.G or not GH.delta then ui.text('GhostLab: no ghost') return end
  local col = GH.delta <= 0 and GREEN or rgbm(1, 0.5, 0.2, 1)
  local pushed = pcall(ui.pushFont, ui.Font.Huge)
  ui.textColored(string.format('%+.2f', GH.delta), col)
  if pushed then ui.popFont() end
end

GHOSTLAB_TEST = { S = S, REC = REC, OWN = OWN, GH = GH, TA = TA, selectGhost = selectGhost, listGhosts = listGhosts,
  saveGhost = saveGhost, parseGhostName = parseGhostName, drawGhostList = drawGhostList,
  setList = function(l) ghostList, listT = l, 1e9 end, cfg = cfg, SCAN = SCAN, Exchange = Exchange, exchangeErr = exchangeErr, Updater = Updater, PERF = PERF }
