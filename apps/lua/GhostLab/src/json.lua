-- Minimal JSON encoder/decoder for GhostLab Exchange (UTF-8 strings, numbers, booleans, null -> nil, objects, arrays).
local json = {}

local escapes = { ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }
local function escapeStr(s)
  return '"' .. s:gsub('[%c"\\]', function(c) return escapes[c] or string.format('\\u%04x', c:byte()) end) .. '"'
end

local function isArray(t)
  local n = 0
  for k in pairs(t) do
    if type(k) ~= 'number' or k < 1 or k % 1 ~= 0 then return false end
    n = n + 1
  end
  for i = 1, n do if t[i] == nil then return false end end
  return true, n
end

local encodeValue
encodeValue = function(v, depth)
  local tv = type(v)
  if v == nil then return 'null'
  elseif tv == 'boolean' then return v and 'true' or 'false'
  elseif tv == 'number' then
    if v ~= v or v == math.huge or v == -math.huge then return 'null' end
    if v % 1 == 0 and math.abs(v) < 1e15 then return string.format('%d', v) end
    return string.format('%.14g', v)
  elseif tv == 'string' then return escapeStr(v)
  elseif tv == 'table' then
    if depth > 30 then error('json: nesting too deep') end
    local arr, n = isArray(v)
    local out = {}
    if arr and n > 0 then
      for i = 1, n do out[i] = encodeValue(v[i], depth + 1) end
      return '[' .. table.concat(out, ',') .. ']'
    end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    for _, k in ipairs(keys) do
      local val = v[k]
      if val == nil then val = v[tonumber(k)] end
      out[#out + 1] = escapeStr(k) .. ':' .. encodeValue(val, depth + 1)
    end
    return '{' .. table.concat(out, ',') .. '}'
  end
  return 'null'
end

function json.encode(v) return encodeValue(v, 0) end

local function utf8char(c)
  if c < 0x80 then return string.char(c)
  elseif c < 0x800 then return string.char(0xC0 + math.floor(c / 64), 0x80 + c % 64)
  elseif c < 0x10000 then return string.char(0xE0 + math.floor(c / 4096), 0x80 + math.floor(c / 64) % 64, 0x80 + c % 64)
  end
  return string.char(0xF0 + math.floor(c / 262144), 0x80 + math.floor(c / 4096) % 64, 0x80 + math.floor(c / 64) % 64, 0x80 + c % 64)
end

local function decodeError(s, i, msg) error(string.format('json: %s at %d', msg, i)) end

local decodeValue
local function skip(s, i)
  local _, e = s:find('^[ \n\r\t]*', i)
  return e + 1
end

local function decodeString(s, i)
  local out, j = {}, i + 1
  while true do
    local a = s:find('["\\]', j)
    if not a then decodeError(s, i, 'unterminated string') end
    out[#out + 1] = s:sub(j, a - 1)
    if s:sub(a, a) == '"' then return table.concat(out), a + 1 end
    local c = s:sub(a + 1, a + 1)
    if c == 'u' then
      local hex = s:sub(a + 2, a + 5)
      if not hex:match('^%x%x%x%x$') then decodeError(s, a, 'bad unicode escape') end
      local cp = tonumber(hex, 16)
      local nextJ = a + 6
      if cp >= 0xD800 and cp <= 0xDBFF and s:sub(nextJ, nextJ + 1) == '\\u' then
        local lo = tonumber(s:sub(nextJ + 2, nextJ + 5), 16)
        if lo and lo >= 0xDC00 and lo <= 0xDFFF then
          cp = 0x10000 + (cp - 0xD800) * 1024 + (lo - 0xDC00)
          nextJ = nextJ + 6
        end
      end
      out[#out + 1] = utf8char(cp)
      j = nextJ
    else
      local map = { b = '\b', f = '\f', n = '\n', r = '\r', t = '\t', ['"'] = '"', ['\\'] = '\\', ['/'] = '/' }
      if not map[c] then decodeError(s, a, 'bad escape') end
      out[#out + 1] = map[c]
      j = a + 2
    end
  end
end

decodeValue = function(s, i, depth)
  if depth > 60 then decodeError(s, i, 'nesting too deep') end
  i = skip(s, i)
  local c = s:sub(i, i)
  if c == '{' then
    local obj = {}
    i = skip(s, i + 1)
    if s:sub(i, i) == '}' then return obj, i + 1 end
    while true do
      i = skip(s, i)
      if s:sub(i, i) ~= '"' then decodeError(s, i, 'expected key') end
      local k
      k, i = decodeString(s, i)
      i = skip(s, i)
      if s:sub(i, i) ~= ':' then decodeError(s, i, 'expected ":"') end
      local v
      v, i = decodeValue(s, i + 1, depth + 1)
      obj[k] = v
      i = skip(s, i)
      local d = s:sub(i, i)
      if d == '}' then return obj, i + 1 end
      if d ~= ',' then decodeError(s, i, 'expected "," or "}"') end
      i = i + 1
    end
  elseif c == '[' then
    local arr, n = {}, 0
    i = skip(s, i + 1)
    if s:sub(i, i) == ']' then return arr, i + 1 end
    while true do
      local v
      v, i = decodeValue(s, i, depth + 1)
      n = n + 1
      arr[n] = v
      i = skip(s, i)
      local d = s:sub(i, i)
      if d == ']' then return arr, i + 1 end
      if d ~= ',' then decodeError(s, i, 'expected "," or "]"') end
      i = i + 1
    end
  elseif c == '"' then
    return decodeString(s, i)
  elseif s:sub(i, i + 3) == 'true' then return true, i + 4
  elseif s:sub(i, i + 4) == 'false' then return false, i + 5
  elseif s:sub(i, i + 3) == 'null' then return nil, i + 4
  else
    local num = s:match('^-?%d+%.?%d*[eE]?[-+]?%d*', i)
    if not num or num == '' or num == '-' then decodeError(s, i, 'unexpected character') end
    local v = tonumber(num)
    if not v then decodeError(s, i, 'bad number') end
    return v, i + #num
  end
end

function json.decode(s)
  if type(s) ~= 'string' then error('json: expected a string') end
  local v, i = decodeValue(s, 1, 0)
  i = skip(s, i)
  if i <= #s then decodeError(s, i, 'trailing characters') end
  return v
end

return json
