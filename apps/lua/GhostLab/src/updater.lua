-- GhostLab update check: the first time the main window is opened, asks the Exchange server (one small request,
-- in the background) for the latest version (GitHub's latest release). Only when it is newer, a message offers
-- "Install update": the release zip is downloaded, checked, its apps/lua/GhostLab files are written over this app
-- (read straight from the zip in memory, the way CSP's AppShelf installs apps), and GhostLab reloads itself in game.

local json = require('src/json')

return function(G)
  local U = { state = 'idle', info = nil, msg = nil, checked = false, hiddenThisSession = false }

  local endpoint = ''
  do
    local ok, C = pcall(require, 'ExchangeConfig')
    if ok and type(C) == 'table' and type(C.endpoint) == 'string' then
      endpoint = C.endpoint:gsub('%s', ''):gsub('/+$', '')
    end
  end

  local function parts(v)
    local t = {}
    for n in tostring(v or ''):gmatch('%d+') do t[#t + 1] = tonumber(n) end
    return t
  end
  -- true when version a is newer than version b
  function U.newer(a, b)
    local x, y = parts(a), parts(b)
    if #x == 0 then return false end
    for i = 1, math.max(#x, #y) do
      local p, q = x[i] or 0, y[i] or 0
      if p ~= q then return p > q end
    end
    return false
  end

  local function trusted(url)
    return type(url) == 'string' and (url:match('^https://github%.com/') or url:match('^https://objects%.githubusercontent%.com/')
      or (endpoint ~= '' and url:sub(1, #endpoint + 1) == endpoint .. '/')) and true or false
  end

  function U.check()
    if U.checked or endpoint == '' or not web or not web.get then return end
    U.checked = true
    web.get(endpoint .. '/version', function(err, response)
      if err and err ~= '' or not response or (tonumber(response.status) or 0) >= 400 then return end
      local ok, info = pcall(json.decode, response.body or '')
      if not ok or type(info) ~= 'table' or not info.version or info.version == '' then return end
      if U.newer(info.version, G.VERSION) then
        U.info = info
        U.state = 'available'
      end
    end)
  end

  -- files -------------------------------------------------------------------------------------------------------------
  local function slash(p) return (p:gsub('[/\\]+$', '')) .. '\\' end

  local function listDir(dir)
    local files, dirs = {}, {}
    pcall(io.scanDir, dir, '*', function(name, attr)
      if attr and attr.isDirectory then dirs[#dirs + 1] = name else files[#files + 1] = name end
    end)
    table.sort(files)
    table.sort(dirs)
    return files, dirs
  end

  local function removeTree(dir)
    local files, dirs = listDir(dir)
    for _, f in ipairs(files) do pcall(io.deleteFile, dir .. f) end
    for _, d in ipairs(dirs) do removeTree(dir .. d .. '\\') end
    pcall(io.deleteDir, dir)
  end

  -- copies every file of src into dst (subfolders too); GhostLab.lua and manifest.ini last
  local function copyTree(src, dst, failed, last)
    pcall(io.createDir, dst)
    local files, dirs = listDir(src)
    for _, f in ipairs(files) do
      local lf = f:lower()
      if last and (lf == 'ghostlab.lua' or lf == 'manifest.ini') then
        last[#last + 1] = { src .. f, dst .. f }
      elseif not io.copyFile(src .. f, dst .. f, false) then
        failed[#failed + 1] = f
      end
    end
    for _, d in ipairs(dirs) do copyTree(src .. d .. '\\', dst .. d .. '\\', failed, nil) end
  end

  local function findAppRoot(tmp)
    for _, p in ipairs({ 'apps\\lua\\GhostLab\\', 'GhostLab\\', '' }) do
      if io.fileExists(tmp .. p .. 'manifest.ini') and io.fileExists(tmp .. p .. 'GhostLab.lua') then return tmp .. p end
    end
    return nil
  end

  local function fail(msg)
    U.state, U.msg = 'available', msg
  end

  local function finish(v)
    U.state, U.msg, U.installed = 'installed', nil, v
    G.say('GhostLab ' .. v .. ' installed, reloading...')
    G.cfg.justUpdated = v
    U.restartIn = 3   -- reload a few frames later, once this frame is done
  end

  local MANUAL = ': click "Release page" and install the zip by hand.'

  -- reads the zip in memory and writes the files one by one, like CSP's own app installer (AppShelf):
  -- no temporary extraction; GhostLab.lua then manifest.ini written last
  local function installFromMemory(body, info)
    local entries = io.scanZip(body)
    if type(entries) ~= 'table' or #entries == 0 then fail('Install failed: the zip is empty or damaged' .. MANUAL) return end
    local set = {}
    for _, e in ipairs(entries) do set[e:lower()] = e end
    local root = nil
    for _, prefix in ipairs({ 'apps/lua/ghostlab/', 'ghostlab/', '' }) do
      if set[prefix .. 'manifest.ini'] and set[prefix .. 'ghostlab.lua'] then root = prefix break end
    end
    if not root then fail('Install failed: GhostLab not found in the zip' .. MANUAL) return end
    local manifestKey, mainKey = set[root .. 'manifest.ini'], set[root .. 'ghostlab.lua']
    local manifest = io.loadFromZip(body, manifestKey) or ''
    local main = io.loadFromZip(body, mainKey) or ''
    local v = manifest:match('VERSION%s*=%s*([%w%.%-]+)')
    if not v or not U.newer(v, G.VERSION) then fail('Install failed: the zip is not a newer GhostLab') return end
    if not main:find('GhostLab', 1, true) then fail('Install failed: the zip is damaged' .. MANUAL) return end
    local dst = slash(ac.getFolder(ac.FolderID.ScriptOrigin))
    local failed = {}
    local function put(rel, data)
      local target = dst .. rel:gsub('/', '\\')
      pcall(io.createFileDir, target)
      local ok, res = pcall(io.save, target, data, true)
      if not ok or res == false then failed[#failed + 1] = rel end
    end
    for _, e in ipairs(entries) do
      local rel = e:sub(#root + 1)
      if e:lower():sub(1, #root) == root and e ~= manifestKey and e ~= mainKey and rel ~= '' and rel:sub(-1) ~= '/'
        and not rel:find('..', 1, true) and not rel:find(':', 1, true) and rel:sub(1, 1) ~= '/' then
        local data = io.loadFromZip(body, e)
        if data then put(rel, data) end
      end
    end
    put(mainKey:sub(#root + 1), main)
    put(manifestKey:sub(#root + 1), manifest)
    if #failed > 0 then
      fail('Install incomplete (' .. table.concat(failed, ', ') .. ')' .. MANUAL)
      return
    end
    finish(v)
  end

  -- older CSP builds without io.scanZip: extraction into a temporary folder, then copy
  local function installByExtraction(body, info)
    local tmp = slash(ac.getFolder(ac.FolderID.ExtCache)) .. 'lua_apps\\GhostLab\\update_' .. tostring(info.version):gsub('[^%w%.]', '_') .. '\\'
    removeTree(tmp)
    io.extractFromZipAsync(body, tmp, nil, function(errZ)
      if errZ then fail('Install failed: ' .. tostring(errZ) .. MANUAL) return end
      local root = findAppRoot(tmp)
      if not root then removeTree(tmp) fail('Install failed: GhostLab not found in the zip' .. MANUAL) return end
      local manifest = io.load(root .. 'manifest.ini') or ''
      local v = manifest:match('VERSION%s*=%s*([%w%.%-]+)')
      if not v or not U.newer(v, G.VERSION) then removeTree(tmp) fail('Install failed: the zip is not a newer GhostLab') return end
      local dst = slash(ac.getFolder(ac.FolderID.ScriptOrigin))
      local failed, last = {}, {}
      copyTree(root, dst, failed, last)
      for _, pair in ipairs(last) do
        if not io.copyFile(pair[1], pair[2], false) then failed[#failed + 1] = pair[1]:match('[^\\]+$') end
      end
      removeTree(tmp)
      if #failed > 0 then fail('Install incomplete (' .. table.concat(failed, ', ') .. ')' .. MANUAL) return end
      finish(v)
    end)
  end

  function U.install()
    local info = U.info
    if not info or U.state == 'installing' then return end
    if not trusted(info.download) then fail('No download for this version: open the release page.') return end
    U.state, U.msg = 'installing', 'Downloading...'
    web.get(info.download, function(err, response)
      if err and err ~= '' or not response or (tonumber(response.status) or 0) >= 400 then
        fail('Download failed: ' .. tostring(err ~= '' and err or (response and response.status) or '?')) return
      end
      local body = response.body or ''
      if body:sub(1, 2) ~= 'PK' then fail('Download failed: not a zip file') return end
      U.msg = 'Installing...'
      local ok, e
      if io.scanZip and io.loadFromZip then
        ok, e = pcall(installFromMemory, body, info)
      else
        ok, e = pcall(installByExtraction, body, info)
      end
      if not ok then fail('Install failed: ' .. tostring(e) .. MANUAL) end
    end)
  end

  -- banner at the top of the main window --------------------------------------------------------------------------------
  function U.banner()
    U.check()
    if U.restartIn then
      U.restartIn = U.restartIn - 1
      if U.restartIn <= 0 then
        U.restartIn = nil
        if not pcall(ac.restartApp) then U.restartFailed = true end
      end
    end
    if U.state == 'idle' or U.hiddenThisSession then return end
    local info = U.info
    if U.state == 'installed' then
      if U.restartFailed then
        ui.textColored('GhostLab ' .. tostring(U.installed) .. ' installed: restart Assetto Corsa to use it.', G.GREEN)
      else
        ui.textColored('GhostLab ' .. tostring(U.installed) .. ' installed, reloading...', G.GREEN)
      end
      ui.separator()
      return
    end
    if G.cfg.skipVersion == info.version then return end
    ui.textColored('New version available: GhostLab ' .. tostring(info.version) .. ' (you have ' .. G.VERSION .. ')', G.GREEN)
    if info.notes and info.notes ~= '' then
      local notes = info.notes:gsub('\r', ''):sub(1, 400)
      ui.textWrapped(notes)
    end
    if U.state == 'installing' then
      ui.textColored(U.msg or 'Installing...', G.GREY)
    else
      if trusted(info.download) and ui.button('Install update') then U.install() end
      if info.page and info.page ~= '' then
        ui.sameLine()
        if ui.button('Release page') then os.openURL(info.page) end
      end
      ui.sameLine()
      if ui.button('Later') then U.hiddenThisSession = true end
      ui.sameLine()
      if ui.button('Skip this version') then G.cfg.skipVersion = info.version end
      if U.msg then ui.textColored(U.msg, G.ORANGE) end
    end
    ui.separator()
  end

  return U
end
