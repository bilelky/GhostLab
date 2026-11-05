-- GhostLab Exchange client: browse, download and share ghosts (titles, likes, comments, filters, search).
-- Server: GhostLab Exchange (Cloudflare Worker), address in ExchangeConfig.lua.
-- Identity like CSP's Setup Exchange: the server sends a challenge, CSP signs it (shared/utils/signing), no account.

local json = require('src/json')

return function(G)
  local X = { selectTab = false }

  -- configuration -----------------------------------------------------------------------------------------------------
  local endpoint = ''
  do
    local ok, C = pcall(require, 'ExchangeConfig')
    if ok and type(C) == 'table' and type(C.endpoint) == 'string' then
      endpoint = C.endpoint:gsub('%s', ''):gsub('/+$', '')
    end
  end
  local configured = endpoint:match('^https?://[%w%.%-:]+') ~= nil
  local patch = 0
  pcall(function() patch = ac.getPatchVersionCode() end)
  local canSign = patch >= 3050

  local ST = {
    session = nil, me = nil, sessionBusy = false, sessionErr = nil, sessionT = -100,
    nameInput = '', nameMsg = nil,
    f = { track = 1, myCar = false, installedOnly = false, search = '', orderBy = 1, mine = false },
    list = { items = {}, total = 0, loading = false, err = nil, gen = 0, loaded = false },
    open = {}, comments = {}, confirm = {}, busy = {},
    share = { file = nil, title = '', description = '', busy = false, msg = nil, msgOk = false },
    started = false,
  }
  local ORDERS = { { 'fastest', 'Fastest' }, { 'newest', 'Newest' }, { 'liked', 'Most liked' }, { 'downloads', 'Most downloaded' }, { 'hot', 'Trending' } }
  local TRACKS = { 'This track', 'Other versions of this track', 'All tracks' }

  local function now() return G.S.t end

  -- base64 (CSP's ac.encodeBase64 when available) ---------------------------------------------------------------------
  local B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
  local function b64(data)
    if ac.encodeBase64 then
      local ok, r = pcall(ac.encodeBase64, data)
      if ok and type(r) == 'string' then return r end
    end
    local out, n = {}, #data
    for i = 1, n, 3 do
      local a, b, c = data:byte(i, i + 2)
      local v = a * 65536 + (b or 0) * 256 + (c or 0)
      local s1, s2, s3, s4 = math.floor(v / 262144) % 64, math.floor(v / 4096) % 64, math.floor(v / 64) % 64, v % 64
      out[#out + 1] = B64:sub(s1 + 1, s1 + 1) .. B64:sub(s2 + 1, s2 + 1) ..
        (b and B64:sub(s3 + 1, s3 + 1) or '=') .. (c and B64:sub(s4 + 1, s4 + 1) or '=')
    end
    return table.concat(out)
  end

  local function urlEncode(s)
    return (tostring(s):gsub('[^%w%-%._~]', function(c) return string.format('%%%02X', c:byte()) end))
  end

  -- HTTP: at most 2 requests at once (CSP limit) ----------------------------------------------------------------------
  local queue, inflight = {}, 0
  local startSession
  local function pump()
    while inflight < 2 and #queue > 0 do
      local q = table.remove(queue, 1)
      inflight = inflight + 1
      local okR, errR = pcall(web.request, q.method, endpoint .. '/' .. q.path, q.headers, q.body, function(err, response)
        inflight = inflight - 1
        local ok, e = pcall(q.done, err, response)
        if not ok then pcall(ac.log, 'GhostLab Exchange: ' .. tostring(e)) end
        pump()
      end)
      if not okR then
        inflight = inflight - 1
        pcall(q.done, tostring(errR), nil)
      end
    end
  end

  -- callback(err, data): data is decoded JSON, or the raw body when raw = true
  local function api(method, path, body, callback, raw)
    if not configured then callback('Exchange server not configured') return end
    local headers = { ['Content-Type'] = 'application/json', ['Accept'] = raw and 'text/csv' or 'application/json' }
    if ST.session then headers['X-Session'] = ST.session end
    queue[#queue + 1] = {
      method = method, path = path, headers = headers, body = body ~= nil and json.encode(body) or nil,
      done = function(err, response)
        if err and err ~= '' or not response then callback(tostring(err ~= '' and err or 'No response')) return end
        local status = tonumber(response.status) or 0
        local text = response.body or ''
        if status >= 400 or status == 0 then
          local ok, parsed = pcall(json.decode, text)
          local msg = ok and type(parsed) == 'table' and parsed.error or ('HTTP ' .. status)
          if status == 401 and ST.session then
            ST.session, ST.me, ST.retryAt = nil, nil, 0
            startSession()
          end
          callback(tostring(msg))
          return
        end
        if raw then callback(nil, text) return end
        local ok, parsed = pcall(json.decode, text)
        if not ok then callback('Invalid server response') return end
        callback(nil, parsed)
      end,
    }
    pump()
  end

  -- session ---------------------------------------------------------------------------------------------------------
  startSession = function()
    if ST.sessionBusy or ST.session or not configured then return end
    if not canSign then
      ST.sessionErr = 'Sharing, likes and comments need a newer Custom Shaders Patch (build 3050 or newer). Browsing and downloading work.'
      return
    end
    if now() - ST.sessionT < 5 then return end
    ST.sessionBusy, ST.sessionT, ST.sessionErr = true, now(), nil
    local function fail(e) ST.sessionBusy, ST.sessionErr, ST.retryAt = false, 'Could not connect: ' .. tostring(e), now() + 30 end
    local okK, errK = pcall(ac.uniqueMachineKeyAsync, function(err, key)
      if err or not key then fail(err or 'no machine key') return end
      local clientID = ac.checksumSHA256('LB83XurHhTPhpmTc' .. key)
      api('POST', 'session/begin', { userID = clientID }, function(e1, r1)
        if e1 then fail(e1) return end
        local okS, signing = pcall(require, 'shared/utils/signing')
        if not okS or not signing then fail('CSP signing unavailable') return end
        signing.blob('{UniqueMachineKeyChecksum}', r1.key, function(signature, header)
          api('POST', 'session/finish', { userID = clientID, header = b64(header), signature = b64(signature) }, function(e2, r2)
            if e2 then fail(e2) return end
            ST.session, ST.me, ST.sessionBusy = r2.session, r2, false
            ST.nameInput = r2.userName or ''
            X.refresh()
          end)
        end)
      end)
    end)
    if not okK then fail(errK) end
  end

  -- local data ------------------------------------------------------------------------------------------------------
  local function carDir(id) return ac.getFolder(ac.FolderID.ContentCars) .. '\\' .. id .. '\\' end
  local carCache = {}
  local function carInfo(id)
    local c = carCache[id]
    if c then return c end
    c = { installed = false, name = '', brand = '', author = '', version = '', url = '', fingerprint = '' }
    pcall(function()
      c.installed = io.dirExists(carDir(id)) and true or false
      if not c.installed then return end
      local txt = io.load(carDir(id) .. 'ui\\ui_car.json') or ''
      local function field(k) return (txt:match('"' .. k .. '"%s*:%s*"(.-)"') or ''):sub(1, 200) end
      c.name, c.brand, c.author, c.version, c.url = field('name'), field('brand'), field('author'), field('version'), field('url')
      local acd = io.load(carDir(id) .. 'data.acd')   -- fingerprint of the file as it is (not decrypted, not read)
      if acd and #acd > 0 then c.fingerprint = tostring(ac.checksumSHA256(acd) or ''):sub(1, 16) end
    end)
    carCache[id] = c
    return c
  end

  local function indexFile() return ac.getFolder(ac.FolderID.Cfg) .. '\\apps\\GhostLab\\exchange_downloads.txt' end
  local downloaded = nil
  local function loadIndex()
    if downloaded then return downloaded end
    downloaded = {}
    local ok, txt = pcall(io.load, indexFile())
    if ok and txt then
      for id, f in txt:gmatch('(%d+)=([^\r\n]+)') do downloaded[tonumber(id)] = f end
    end
    return downloaded
  end
  local function saveIndex()
    local lines = {}
    for id, f in pairs(downloaded or {}) do lines[#lines + 1] = id .. '=' .. f end
    pcall(io.save, indexFile(), table.concat(lines, '\n'))
  end
  local function localFileOf(id)
    local f = loadIndex()[id]
    if f and io.fileExists(G.ghostDir() .. f) then return f end
    return nil
  end

  local function currentTrack() return ac.getTrackID(), ac.getTrackLayout() or '' end
  local function trackLength()
    local len = 0
    pcall(function() len = ac.getSim().trackLengthM or 0 end)
    return len
  end
  local function isCurrentTrack(item)
    local t, l = currentTrack()
    return item.trackID == t and (item.layout or '') == l
  end

  -- list ------------------------------------------------------------------------------------------------------------
  function X.refresh(append)
    if not configured then return end
    local L = ST.list
    L.gen = L.gen + 1
    local gen = L.gen
    L.loading, L.err = true, nil
    if not append then L.items, L.total = {}, 0 end
    local t, l = currentTrack()
    local p = { 'orderBy=' .. ORDERS[ST.f.orderBy][1], 'limit=20', 'offset=' .. (append and #L.items or 0) }
    if ST.f.track == 1 then
      p[#p + 1] = 'trackID=' .. urlEncode(t); p[#p + 1] = 'layout=' .. urlEncode(l)
    elseif ST.f.track == 2 then
      p[#p + 1] = 'trackID=' .. urlEncode(t); p[#p + 1] = 'layout=' .. urlEncode(l)
      p[#p + 1] = 'near=' .. string.format('%.1f', math.max(trackLength(), 101))
    end
    if ST.f.myCar then p[#p + 1] = 'carID=' .. urlEncode(ac.getCarID(0)) end
    if ST.f.search ~= '' then p[#p + 1] = 'search=' .. urlEncode(ST.f.search) end
    if ST.f.mine then p[#p + 1] = 'mine=1' end
    api('GET', 'ghosts?' .. table.concat(p, '&'), nil, function(err, r)
      if gen ~= L.gen then return end
      L.loading, L.loaded = false, true
      if err then L.err = err return end
      for _, it in ipairs(r.items or {}) do L.items[#L.items + 1] = it end
      L.total = r.total or #L.items
    end)
  end

  -- download --------------------------------------------------------------------------------------------------------
  local function gunzipFallback(body)
    -- body still gzip-compressed (server or proxy did not decode it): CSP format = type byte + size + data
    local s = body:sub(-4)
    local okD, out = pcall(ac.decompress, string.char(3) .. s .. body)
    if okD and type(out) == 'string' then return out end
    return nil
  end

  local function download(item, andSelect)
    ST.busy[item.ghostID] = 'Downloading...'
    api('GET', 'ghosts/' .. item.ghostID .. '/file', nil, function(err, body)
      ST.busy[item.ghostID] = nil
      if err then G.say('Download failed: ' .. err) return end
      if body:sub(1, 2) == '\31\139' then body = gunzipFallback(body) or '' end
      if not body:find('# GHOSTLAB', 1, true) then G.say('Download failed: invalid ghost file') return end
      body = body:gsub('\n', '\n# exchangeID=' .. item.ghostID .. '\n# sharedBy=' .. (item.userName or ''):gsub('[\r\n]', '') .. '\n', 1)
      local track = item.trackID .. ((item.layout or '') ~= '' and ('-' .. item.layout) or '')
      local base = G.safeName(track) .. '__' .. G.safeName(item.carID) .. '__'
      local tail = '__' .. G.fmtLap(item.lapMs):gsub('[:%.]', '-') .. '.csv'
      local driver = G.safeName(item.driver ~= '' and item.driver or item.userName)
      if G.isOwnDriver(driver) then driver = G.safeName(item.userName) end
      local name = base .. driver .. tail
      local idx = loadIndex()
      if io.fileExists(G.ghostDir() .. name) and idx[item.ghostID] ~= name then name = base .. driver .. '_x' .. item.ghostID .. tail end
      pcall(io.createDir, ac.getFolder(ac.FolderID.Cfg) .. '\\apps\\GhostLab')
      pcall(io.createDir, G.ghostDir())
      local ok = pcall(io.save, G.ghostDir() .. name, body)
      if not ok then G.say('Download failed: could not write the file') return end
      idx[item.ghostID] = name
      saveIndex()
      item.statDownloads = (item.statDownloads or 0) + 1
      G.refreshList()
      if andSelect then
        G.selectGhost(name)
        G.say('Ghost ready: ' .. G.fmtLap(item.lapMs) .. ' (' .. (item.driver or '') .. ')')
      else
        G.say('Ghost downloaded: ' .. name)
      end
    end, true)
  end

  local function vote(item, dir)
    if not ST.session then startSession() return end
    local target = (item.myVote == dir) and 0 or dir
    ST.busy[item.ghostID] = '...'
    api('POST', 'ghosts/' .. item.ghostID .. '/vote', { direction = target }, function(err, r)
      ST.busy[item.ghostID] = nil
      if err then G.say(err) return end
      item.myVote, item.statLikes, item.statDislikes = r.myVote, r.statLikes, r.statDislikes
    end)
  end

  local function loadComments(item)
    local C = ST.comments[item.ghostID] or { items = {}, input = '', loading = false }
    ST.comments[item.ghostID] = C
    C.loading = true
    api('GET', 'ghosts/' .. item.ghostID .. '/comments?limit=50', nil, function(err, r)
      C.loading = false
      if err then C.err = err return end
      C.items, C.total, C.err = r.items or {}, r.total or 0, nil
      item.statComments = C.total
    end)
  end

  local function sendComment(item, C)
    local text = C.input:gsub('^%s+', ''):gsub('%s+$', '')
    if text == '' then return end
    C.sending = true
    api('POST', 'ghosts/' .. item.ghostID .. '/comments', { text = text }, function(err)
      C.sending = false
      if err then C.err = err return end
      C.input = ''
      loadComments(item)
    end)
  end

  local function removeGhost(item)
    api('DELETE', 'ghosts/' .. item.ghostID, nil, function(err)
      if err then G.say('Delete failed: ' .. err) return end
      for i, it in ipairs(ST.list.items) do if it == item then table.remove(ST.list.items, i) break end end
      ST.list.total = math.max(0, ST.list.total - 1)
      G.say('Ghost removed from the Exchange')
    end)
  end

  local function report(item)
    api('POST', 'ghosts/' .. item.ghostID .. '/report', { reason = 'reported from GhostLab' }, function(err)
      if err then G.say(err) return end
      item.reported = true
      G.say('Thanks, the ghost has been reported')
    end)
  end

  -- share -----------------------------------------------------------------------------------------------------------
  local function readMeta(txt)
    local m = {}
    for k, v in txt:gmatch('# (%w+)=([^\r\n]*)') do if m[k] == nil then m[k] = v end end
    return m
  end

  -- the file as shared: your laps get your Exchange name as driver, samples thinned to 20 per second
  local function prepareUpload(txt, userName)
    local out, lastT, pendingLast = {}, nil, nil
    local sx, sy, sz, fx, fy, fz, perimeter = nil, nil, nil, nil, nil, nil, 0
    for line in txt:gmatch('[^\r\n]+') do
      if line:sub(1, 9) == '# driver=' then
        if G.isOwnDriver(line:sub(10)) then line = '# driver=' .. userName end
        out[#out + 1] = line
      elseif line:sub(1, 13) == '# exchangeID=' or line:sub(1, 11) == '# sharedBy=' then
        -- local information only
      elseif line:sub(1, 2) == 'S,' then
        local x, y, z = line:match('^S,([^,]+),([^,]+),([^,]+)')
        x, y, z = tonumber(x), tonumber(y), tonumber(z)
        if x then
          if sx then perimeter = perimeter + math.sqrt((x - sx) ^ 2 + (y - sy) ^ 2 + (z - sz) ^ 2) else fx, fy, fz = x, y, z end
          sx, sy, sz = x, y, z
        end
        out[#out + 1] = line
      elseif line:match('^%-?%d') then
        local t = tonumber(line:match('^([^,]+)'))
        if t and (not lastT or t - lastT >= 0.045) then
          out[#out + 1] = line
          lastT, pendingLast = t, nil
        else
          pendingLast = line
        end
      else
        out[#out + 1] = line
      end
    end
    if pendingLast then out[#out + 1] = pendingLast end
    if sx and fx then perimeter = perimeter + math.sqrt((fx - sx) ^ 2 + (fy - sy) ^ 2 + (fz - sz) ^ 2) end
    return table.concat(out, '\n') .. '\n', perimeter
  end

  local function startShare(file)
    local S = ST.share
    S.file, S.msg, S.msgOk = file, nil, false
    local e = G.parseGhostName(file)
    local info = carInfo(e.car)
    S.title = string.format('%s %s', (info.name ~= '' and info.name or e.car), e.lapMs and G.fmtLap(e.lapMs) or '')
    S.description = ''
  end

  function X.share(file)
    startShare(file)
    X.selectTab = true
  end

  local function doShare()
    local S = ST.share
    if not ST.session or not ST.me then startSession() return end
    if (ST.me.userName or '') == '' then S.msg, S.msgOk = 'Choose your Exchange name first (Account section).', false return end
    local okL, txt = pcall(io.load, G.ghostDir() .. S.file)
    if not okL or not txt then S.msg, S.msgOk = 'Could not read the ghost file', false return end
    local meta = readMeta(txt)
    local text, perimeter = prepareUpload(txt, ST.me.userName)
    local t, l = currentTrack()
    local sameTrack = meta.track == t and (meta.layout or '') == l
    local len = perimeter > 100 and perimeter or (sameTrack and trackLength() or 0)
    local trackName = ''
    pcall(function()
      trackName = sameTrack and ac.getTrackName() or ac.getTrackNameByID(meta.track or '')
    end)
    trackName = tostring(trackName or ''):gsub('^"(.*)"$', '%1')
    local info = carInfo(meta.car or '')
    local packed = nil
    pcall(function() packed = ac.compress(text, ac.CompressionType.Gzip, 9) end)
    S.busy, S.msg = true, 'Uploading...'
    api('POST', 'ghosts', {
      title = S.title, description = S.description, file = b64(packed or text),
      trackName = trackName, trackLengthM = math.floor(len + 0.5),
      carName = info.name ~= '' and info.name or (meta.carName or ''), carBrand = info.brand, carAuthor = info.author,
      carVersion = info.version, carUrl = info.url, carFingerprint = info.fingerprint,
      cspVersion = patch, appVersion = G.VERSION,
    }, function(err, r)
      S.busy = false
      if err then S.msg, S.msgOk = 'Not shared: ' .. err, false return end
      S.msg, S.msgOk = string.format('Shared (%s, %d KB). Thanks!', G.fmtLap(r.lapMs), math.floor((r.sizeBytes or 0) / 1024 + 0.5)), true
      S.file = nil
      ST.f.mine = false
      X.refresh()
    end)
  end

  -- interface -------------------------------------------------------------------------------------------------------
  local function confirmButton(key, label, confirmLabel)
    local armed = ST.confirm[key] and now() - ST.confirm[key] < 4
    if ui.button(armed and confirmLabel or label) then
      if armed then ST.confirm[key] = nil return true end
      ST.confirm[key] = now()
    end
    return false
  end

  local function drawAccount()
    if not ST.me then
      if ST.sessionErr then ui.textColored(ST.sessionErr, G.ORANGE)
      elseif ST.sessionBusy then ui.textColored('Connecting...', G.GREY) end
      if ST.sessionErr and canSign and ui.button('Retry') then ST.sessionT = -100; startSession() end
      return
    end
    if (ST.me.userName or '') == '' then
      ui.textColored('Choose your Exchange name (shown on your ghosts and comments):', G.ORANGE)
    end
    ui.treeNode((ST.me.userName ~= '' and ('Account: ' .. ST.me.userName) or 'Account') .. '###xAccount', function()
      ui.setNextItemWidth(180)
      ST.nameInput = ui.inputText('##xname', ST.nameInput)
      ui.sameLine()
      if ui.button('Save name') then
        ST.nameMsg = nil
        api('POST', 'me', { userName = ST.nameInput }, function(err, r)
          if err then ST.nameMsg = err return end
          ST.me.userName = r.userName
          ST.nameMsg = 'Saved'
        end)
      end
      if ST.nameMsg then ui.textColored(ST.nameMsg, ST.nameMsg == 'Saved' and G.GREEN or G.ORANGE) end
      ui.textDisabled('Your ID: ' .. tostring(ST.me.userID))
      ui.sameLine()
      if ui.smallButton('Copy##xid') then ui.setClipboardText(tostring(ST.me.userID)) end
      if ST.me.moderator then ui.textColored('Moderator', G.GREEN) end
      if ui.smallButton('Privacy') then os.openURL(endpoint .. '/privacy') end
    end)
    if (ST.me.userName or '') == '' then
      ui.setNextItemWidth(180)
      ST.nameInput = ui.inputText('##xname0', ST.nameInput)
      ui.sameLine()
      if ui.button('Save##xname0') then
        ST.nameMsg = nil
        api('POST', 'me', { userName = ST.nameInput }, function(err, r)
          if err then ST.nameMsg = err return end
          ST.me.userName = r.userName
          ST.nameMsg = 'Saved'
        end)
      end
      if ST.nameMsg then ui.textColored(ST.nameMsg, ST.nameMsg == 'Saved' and G.GREEN or G.ORANGE) end
    end
  end

  local function shareLabel(e)
    return string.format('%s  %s  %s  (%s)', e.lapMs and G.fmtLap(e.lapMs) or '?', e.car, G.isOwnDriver(e.driver) and 'You' or e.driver, e.track)
  end

  local function drawShareForm()
    local S = ST.share
    local cur = G.parseGhostName(S.file)
    ui.textColored('Share: ' .. shareLabel(cur), G.GREEN)
    ui.setNextItemWidth(math.max(200, ui.availableSpaceX() - 50))
    S.title = ui.inputText('Title##xtitle', S.title)
    S.description = ui.inputText('##xdesc', S.description, 0, vec2(math.max(200, ui.availableSpaceX()), 60))
    ui.textDisabled('Description (optional): setup, conditions, tips...')
    local info = carInfo(cur.car)
    if not info.installed then ui.textColored('This car is not installed here: shared without car details.', G.ORANGE) end
    if ST.me and (ST.me.userName or '') == '' then ui.textColored('Choose your Exchange name first.', G.ORANGE) end
    if S.busy then
      ui.textColored('Uploading...', G.GREY)
    else
      if ui.button('Share on the Exchange') then doShare() end
      ui.sameLine()
      if ui.button('Cancel##xshare') then S.file, S.msg = nil, nil end
    end
    if S.msg and not S.busy then ui.textColored(S.msg, S.msgOk and G.GREEN or G.ORANGE) end
  end

  local function drawShare()
    local S = ST.share
    if S.file then drawShareForm() return end
    if S.msg then ui.textColored(S.msg, S.msgOk and G.GREEN or G.ORANGE) end
    ui.treeNode('Share a ghost###xShare', function()
      ui.setNextItemWidth(math.max(200, ui.availableSpaceX()))
      ui.combo('##xshareFile', 'Pick one of your ghosts', function()
        for _, f in ipairs(G.listGhosts()) do
          if ui.selectable(shareLabel(G.parseGhostName(f)) .. '##xs' .. f, false) then startShare(f) end
        end
      end)
    end)
  end

  local function drawFilters()
    local changed = false
    ui.setNextItemWidth(200)
    ui.combo('##xtrack', TRACKS[ST.f.track], function()
      for i, n in ipairs(TRACKS) do
        if ui.selectable(n, ST.f.track == i) and ST.f.track ~= i then ST.f.track = i; changed = true end
      end
    end)
    ui.sameLine()
    ui.setNextItemWidth(140)
    ui.combo('##xorder', ORDERS[ST.f.orderBy][2], function()
      for i, o in ipairs(ORDERS) do
        if ui.selectable(o[2], ST.f.orderBy == i) and ST.f.orderBy ~= i then ST.f.orderBy = i; changed = true end
      end
    end)
    if ui.checkbox('My car only', ST.f.myCar) then ST.f.myCar = not ST.f.myCar; changed = true end
    ui.sameLine()
    if ui.checkbox('Cars I have', ST.f.installedOnly) then ST.f.installedOnly = not ST.f.installedOnly end
    ui.sameLine()
    if ui.checkbox('My ghosts', ST.f.mine) then
      ST.f.mine = not ST.f.mine
      if ST.f.mine and not ST.session then startSession() end
      changed = true
    end
    ui.setNextItemWidth(200)
    local s, _, enter = ui.inputText('##xsearch', ST.f.search)
    ST.f.search = s
    ui.sameLine()
    if ui.button('Search') or enter then changed = true end
    ui.sameLine()
    if ui.button('Refresh') then changed = true end
    if changed then X.refresh() end
  end

  local function drawItem(item)
    ui.pushID(item.ghostID)
    local info = carInfo(item.carID)
    ui.textColored(G.fmtLap(item.lapMs), G.GREEN)
    ui.sameLine()
    ui.text(item.title or '')
    local who = item.driver or ''
    if item.userName and item.userName ~= '' and item.userName ~= who then who = who .. ' (shared by ' .. item.userName .. ')' end
    ui.textDisabled(string.format('%s  |  %s  |  %s', item.carName ~= '' and item.carName or item.carID, who,
      os.date('%Y-%m-%d', item.createdDate or 0)))
    if not isCurrentTrack(item) then
      ui.textColored('Track: ' .. (item.trackName ~= '' and item.trackName or item.trackID) .. ' (other version: aligned automatically)', G.GREY)
    end
    if not info.installed then
      ui.textColored(G.standIn() and 'Car not installed: shown with your car as a stand-in.' or 'Car not installed: delta only, no 3D model.', G.ORANGE)
      if item.carUrl and item.carUrl ~= '' then
        ui.sameLine()
        if ui.smallButton('Get the car') then os.openURL(item.carUrl) end
      end
    elseif info.fingerprint ~= '' and (item.carFingerprint or '') ~= '' and info.fingerprint ~= item.carFingerprint then
      ui.textColored('Other version of this car than yours: times not directly comparable.', G.ORANGE)
    end
    if item.hidden == 1 or item.hidden == true then ui.textColored('Hidden (reported), waiting for moderation', G.ORANGE) end
    if item.description and item.description ~= '' and ST.open[item.ghostID] then ui.textWrapped(item.description) end

    local file = localFileOf(item.ghostID)
    local busy = ST.busy[item.ghostID]
    if busy then
      ui.textColored(busy, G.GREY)
    elseif file then
      if ui.button('Drive against it') then
        G.selectGhost(file)
        G.say('Ghost selected: ' .. G.fmtLap(item.lapMs))
      end
    elseif ui.button('Download') then
      download(item, isCurrentTrack(item) or ST.f.track == 2)
    end
    ui.sameLine()
    if ui.button(string.format('%sLike %d###xl', item.myVote == 1 and '[x] ' or '', item.statLikes or 0)) then vote(item, 1) end
    ui.sameLine()
    if ui.button(string.format('%sDislike %d###xd', item.myVote == -1 and '[x] ' or '', item.statDislikes or 0)) then vote(item, -1) end
    ui.sameLine()
    if ui.button(string.format('Comments %d###xc', item.statComments or 0)) then
      ST.open[item.ghostID] = not ST.open[item.ghostID]
      if ST.open[item.ghostID] then loadComments(item) end
    end
    ui.sameLine()
    ui.textDisabled(string.format('%d downloads', item.statDownloads or 0))
    if item.own then
      ui.sameLine()
      if confirmButton('del' .. item.ghostID, 'Remove', 'Click again to remove') then removeGhost(item) end
    elseif ST.session and not item.reported then
      ui.sameLine()
      if confirmButton('rep' .. item.ghostID, 'Report', 'Click again to report') then report(item) end
    end

    if ST.open[item.ghostID] then
      local C = ST.comments[item.ghostID]
      if C then
        if C.loading then ui.textColored('Loading comments...', G.GREY) end
        if C.err then ui.textColored(C.err, G.ORANGE) end
        for _, c in ipairs(C.items or {}) do
          ui.pushID(c.commentID)
          ui.textColored(c.userName or '?', G.GREEN)
          ui.sameLine()
          ui.textDisabled(os.date('%Y-%m-%d', c.createdDate or 0))
          if c.own then
            ui.sameLine()
            if ui.smallButton('Delete') then
              api('DELETE', 'comments/' .. c.commentID, nil, function(err)
                if err then C.err = err else loadComments(item) end
              end)
            end
          end
          ui.textWrapped(c.text or '')
          ui.popID()
        end
        if ST.session and ST.me and (ST.me.userName or '') ~= '' then
          ui.setNextItemWidth(math.max(160, ui.availableSpaceX() - 60))
          local s, _, enter = ui.inputText('##xcomment', C.input)
          C.input = s
          ui.sameLine()
          if (ui.button('Send') or enter) and not C.sending then sendComment(item, C) end
        elseif not ST.session then
          ui.textDisabled('Connect to comment.')
        else
          ui.textDisabled('Choose your Exchange name to comment.')
        end
      end
    end
    ui.separator()
    ui.popID()
  end

  function X.tab()
    if not configured then
      ui.textWrapped('GhostLab Exchange is not configured: put the server address in apps/lua/GhostLab/ExchangeConfig.lua.')
      return
    end
    if not ST.started then
      ST.started = true
      startSession()
      if not ST.list.loaded and not ST.list.loading then X.refresh() end
    elseif not ST.session and not ST.sessionBusy and canSign and now() >= (ST.retryAt or 0) then
      startSession()   -- reconnect (expired session, network back)
    end
    drawAccount()
    drawShare()
    ui.separator()
    drawFilters()
    local L = ST.list
    if L.err then ui.textColored('Exchange: ' .. L.err, G.ORANGE) end
    local shown, hidden = 0, 0
    for _, item in ipairs(L.items) do
      if ST.f.installedOnly and not carInfo(item.carID).installed then
        hidden = hidden + 1
      else
        shown = shown + 1
        drawItem(item)
      end
    end
    if L.loading then ui.textColored('Loading...', G.GREY)
    elseif L.loaded and #L.items == 0 then
      ui.textWrapped(ST.f.track == 1 and 'No ghost shared on this track yet with these filters. Share yours!' or 'No ghost found with these filters.')
    end
    if hidden > 0 then ui.textDisabled(string.format('%d ghost(s) of cars you do not have hidden', hidden)) end
    if not L.loading and #L.items < (L.total or 0) then
      if ui.button(string.format('Load more (%d of %d)', #L.items, L.total)) then X.refresh(true) end
    end
  end

  X._state = ST   -- tests
  X._prepareUpload = prepareUpload
  return X
end
