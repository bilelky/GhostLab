// GhostLab Exchange: share GhostLab ghosts (one lap of one car) with titles, likes, comments, filters and search.
// Cloudflare Worker + D1 (metadata) + R2 (ghost files, gzip). Single file, no dependencies.
//
// Bindings: DB (D1 database), BUCKET (R2 bucket).
// Variables: SALT (secret, any long random string, never change it once users exist),
//            MODERATORS (optional, comma separated user IDs, shown in GhostLab as "Your ID"),
//            GITHUB_REPO (optional, "owner/repo": the latest GitHub release is offered as an update in GhostLab),
//            or LATEST_VERSION + DOWNLOAD_URL (+ RELEASE_PAGE, RELEASE_NOTES) to announce an update by hand.
//
// Identity works like CSP's Setup Exchange: no account, no password. GhostLab signs a server challenge with Custom
// Shaders Patch's own key (shared/utils/signing), the server checks the signature with CSP's public key, so every
// session belongs to a real CSP install on one PC. Only salted hashes are stored (no Steam ID, no IP in clear).

const SERVICE = 'GhostLab Exchange';
const API_VERSION = 1;
const CSP_PUBLIC_KEY = 'MIIBoDANBgkqhkiG9w0BAQEFAAOCAY0AMIIBiAKCAYEAv255WL89kNUX4xn6oWsR6YIASm9ulWqiEmWesuRzQ+LTaaOWeN6/0AKhs7TLQOb2LF9ektX3lptLVCHUpg/RzHcbQPCn/ke7vbX8HMNZUmm5cHUvhx7VdkKjtdIuF7DWnKd81XnK2xxU8+Sh7nBaraCOb4qOw6PkP/DYsd/k1UxXzEOCWsWJ8S+LZ4P6vfcB6+PujuPhXKQ+UzQkhHo7K2wVzoMl0LGFEqby8YVPH39yAk59bQkRkOz8qVMpaPKFYB+3e4rhCbAV3+yHOKlE5QZ5PTr0L2M7mL4SlevopTen6410bFI879jgCC+lEiVLRQJRb25cUYLF2plWfmc7IhuYUyrsOieiU0p8tBLH69HrcRIxgtm22/sE9j9nAeCXYVnG5VWMwox0Pm8QyuedX2y2zRN0XdDhZ7WBIrNDDvuMDTYiB7/3NyMHKGfjZpEboZ1k7L2rRG/Plq+O6i8NBYJezZC84l2FEmMinH3JGPA8pQXYE8WsB7gDVHkHmYL9AgER';
const SIGN_FORMAT = '{UniqueMachineKeyChecksum}';

const LIMITS = {
  bodyBytes: 3 * 1024 * 1024,     // request body
  fileBytes: 4 * 1024 * 1024,     // ghost file once decompressed
  samplesMin: 100,
  samplesMax: 60000,
  title: 80,
  description: 600,
  comment: 1000,
  reason: 300,
  uploadsPerDay: 50,               // per 24 h and per user (moderators: no limit)
  commentsPerDay: 60,
  votesPerDay: 600,
  sessionsPerHourPerIP: 30,
  sessionDays: 30,
  reportsToHide: 3,
  pageMax: 50,
};

const SCHEMA = [
  `CREATE TABLE IF NOT EXISTS users (userID TEXT PRIMARY KEY, userName TEXT, createdDate INTEGER, banned INTEGER DEFAULT 0, ipHash TEXT)`,
  `CREATE UNIQUE INDEX IF NOT EXISTS idx_users_name ON users(userName COLLATE NOCASE)`,
  `CREATE TABLE IF NOT EXISTS pending (userID TEXT PRIMARY KEY, secret TEXT, ipHash TEXT, createdDate INTEGER)`,
  `CREATE TABLE IF NOT EXISTS sessions (tokenHash TEXT PRIMARY KEY, userID TEXT, ipHash TEXT, createdDate INTEGER)`,
  `CREATE INDEX IF NOT EXISTS idx_sessions_ip ON sessions(ipHash, createdDate)`,
  `CREATE TABLE IF NOT EXISTS ghosts (ghostID INTEGER PRIMARY KEY AUTOINCREMENT, createdDate INTEGER, userID TEXT, userName TEXT,
    title TEXT, description TEXT, trackID TEXT, layout TEXT, trackName TEXT, trackLengthM REAL,
    carID TEXT, carName TEXT, carBrand TEXT, carAuthor TEXT, carVersion TEXT, carUrl TEXT, carFingerprint TEXT,
    skin TEXT, driver TEXT, lapMs INTEGER, source TEXT, samples INTEGER, lapLengthM REAL, sizeBytes INTEGER, blobKey TEXT,
    cspVersion INTEGER, appVersion TEXT, statLikes INTEGER DEFAULT 0, statDislikes INTEGER DEFAULT 0,
    statDownloads INTEGER DEFAULT 0, statComments INTEGER DEFAULT 0, reports INTEGER DEFAULT 0, hidden INTEGER DEFAULT 0)`,
  `CREATE INDEX IF NOT EXISTS idx_ghosts_track ON ghosts(trackID, layout, lapMs)`,
  `CREATE INDEX IF NOT EXISTS idx_ghosts_track_car ON ghosts(trackID, layout, carID, lapMs)`,
  `CREATE INDEX IF NOT EXISTS idx_ghosts_car ON ghosts(carID, lapMs)`,
  `CREATE INDEX IF NOT EXISTS idx_ghosts_user ON ghosts(userID, createdDate)`,
  `CREATE INDEX IF NOT EXISTS idx_ghosts_length ON ghosts(trackLengthM)`,
  `CREATE INDEX IF NOT EXISTS idx_ghosts_date ON ghosts(createdDate)`,
  `CREATE TABLE IF NOT EXISTS votes (ghostID INTEGER, userID TEXT, direction INTEGER, createdDate INTEGER, PRIMARY KEY (ghostID, userID))`,
  `CREATE INDEX IF NOT EXISTS idx_votes_user ON votes(userID, createdDate)`,
  `CREATE TABLE IF NOT EXISTS comments (commentID INTEGER PRIMARY KEY AUTOINCREMENT, ghostID INTEGER, createdDate INTEGER, userID TEXT, userName TEXT, text TEXT)`,
  `CREATE INDEX IF NOT EXISTS idx_comments_ghost ON comments(ghostID, createdDate)`,
  `CREATE INDEX IF NOT EXISTS idx_comments_user ON comments(userID, createdDate)`,
  `CREATE TABLE IF NOT EXISTS reports (ghostID INTEGER, userID TEXT, reason TEXT, createdDate INTEGER, PRIMARY KEY (ghostID, userID))`,
  `CREATE TABLE IF NOT EXISTS downloads (ghostID INTEGER, who TEXT, PRIMARY KEY (ghostID, who))`,
  `CREATE TABLE IF NOT EXISTS kv (k TEXT PRIMARY KEY, v TEXT, t INTEGER)`,
];

// ---------------------------------------------------------------------------------------------------------------------
class HttpError extends Error {
  constructor(status, message) { super(message); this.status = status; }
}
const fail = (status, message) => { throw new HttpError(status, message); };
const now = () => Math.floor(Date.now() / 1000);
const DAY = 86400;

function json(data, status = 200, extra = {}) {
  return new Response(JSON.stringify(data), {
    status, headers: Object.assign({ 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' }, extra),
  });
}

function b64ToBytes(s) {
  const bin = atob(String(s).replace(/-/g, '+').replace(/_/g, '/').replace(/\s/g, ''));
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}
function bytesToB64(bytes, url) {
  let bin = '';
  for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
  const s = btoa(bin);
  return url ? s.replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '') : s;
}
async function sha256b64(...parts) {
  const data = new TextEncoder().encode(parts.join('\u0000'));
  return bytesToB64(new Uint8Array(await crypto.subtle.digest('SHA-256', data)), true);
}
function randomToken(n = 24) {
  const b = new Uint8Array(n);
  crypto.getRandomValues(b);
  return bytesToB64(b, true);
}
function concatBytes(...arrs) {
  const out = new Uint8Array(arrs.reduce((a, b) => a + b.length, 0));
  let o = 0;
  for (const a of arrs) { out.set(a, o); o += a.length; }
  return out;
}

async function streamToBytes(stream) {
  const reader = stream.getReader();
  const chunks = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.length;
    if (total > LIMITS.fileBytes) fail(413, 'Ghost file too big');
    chunks.push(value);
  }
  return concatBytes(...chunks);
}
async function gunzip(bytes) {
  return streamToBytes(new Blob([bytes]).stream().pipeThrough(new DecompressionStream('gzip')));
}
async function gzip(bytes) {
  return streamToBytes(new Blob([bytes]).stream().pipeThrough(new CompressionStream('gzip')));
}

// text field: trimmed, control characters removed, length capped
function str(v, max, fallback = '') {
  if (v == null) return fallback;
  let s = String(v).replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/g, '').trim();
  if (s.length > max) s = s.substring(0, max);
  return s;
}
function idStr(v, max = 128) {
  const s = str(v, max);
  if (s && !/^[\w.\-]+$/.test(s)) fail(400, 'Invalid identifier');
  return s;
}
function intParam(v, def, min, max) {
  const n = parseInt(v, 10);
  if (!Number.isFinite(n)) return def;
  return Math.min(Math.max(n, min), max);
}
function likeEscape(s) { return s.replace(/[\\%_]/g, m => '\\' + m); }

// ---------------------------------------------------------------------------------------------------------------------
let schemaReady = null;
function ensureSchema(env) {
  if (!schemaReady) {
    schemaReady = env.DB.batch(SCHEMA.map(q => env.DB.prepare(q))).catch(e => { schemaReady = null; throw e; });
  }
  return schemaReady;
}

let cspKeyPromise = null;
function cspKey(env) {
  if (!cspKeyPromise) {
    cspKeyPromise = crypto.subtle.importKey('spki', b64ToBytes(env.CSP_PUBLIC_KEY || CSP_PUBLIC_KEY),
      { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-1' }, false, ['verify']).catch(e => { cspKeyPromise = null; throw e; });
  }
  return cspKeyPromise;
}

function salt(env) {
  return env.SALT || 'ghostlab-exchange-default-salt-change-me';
}
async function ipHash(env, request) {
  const ip = request.headers.get('CF-Connecting-IP') || request.headers.get('X-Real-IP') || '?';
  return (await sha256b64(salt(env), 'ip', ip)).substring(0, 22);
}
function moderators(env) {
  return String(env.MODERATORS || '').split(',').map(s => s.trim()).filter(Boolean);
}

async function readJSON(request) {
  const buf = await request.arrayBuffer();
  if (buf.byteLength > LIMITS.bodyBytes) fail(413, 'Request too big');
  if (buf.byteLength === 0) return {};
  try {
    const v = JSON.parse(new TextDecoder().decode(buf));
    return v && typeof v === 'object' ? v : {};
  } catch (e) {
    fail(400, 'Invalid JSON');
  }
}

// current user from X-Session header (null when absent)
async function auth(ctx, required) {
  if (ctx.user !== undefined) {
    if (required && !ctx.user) fail(401, 'Invalid session');
    return ctx.user;
  }
  const token = ctx.request.headers.get('X-Session');
  ctx.user = null;
  if (token) {
    const row = await ctx.env.DB.prepare(
      `SELECT s.userID, s.createdDate, u.userName, u.banned FROM sessions s LEFT JOIN users u ON u.userID = s.userID WHERE s.tokenHash = ?`)
      .bind(await sha256b64('session', token)).first();
    if (row && row.createdDate > now() - LIMITS.sessionDays * DAY) {
      ctx.user = { userID: row.userID, userName: row.userName || '', banned: !!row.banned,
        moderator: moderators(ctx.env).includes(row.userID) };
    }
    if (!ctx.user) fail(401, 'Invalid session');   // expired or unknown: the client opens a new one
  }
  if (required && !ctx.user) fail(401, 'Invalid session');
  return ctx.user;
}
async function writer(ctx, needName) {
  const u = await auth(ctx, true);
  if (u.banned) fail(403, 'This account is banned');
  if (needName && !u.userName) fail(400, 'Choose a user name first');
  return u;
}
async function countSince(env, sql, userID, seconds) {
  const r = await env.DB.prepare(sql).bind(userID, now() - seconds).first();
  return r ? (r.n || 0) : 0;
}

// ---------------------------------------------------------------------------------------------------------------------
// Ghost file: header lines "# key=value", centerline "S,x,y,z", samples "t,pos,x,y,z,lx,ly,lz,ux,uy,uz,spd,gas,brk,gear,hg"
const HEADER_KEYS = ['car', 'carName', 'driver', 'track', 'layout', 'lapMs', 'source', 'skin', 'date'];

function parseGhost(text) {
  const meta = {};
  const out = [];
  const t = [], x = [], y = [], z = [], spd = [];
  let version = '', centerline = 0, columnsLine = null;
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    if (!line) continue;
    if (line.startsWith('# GHOSTLAB')) { version = line.substring(10).trim().substring(0, 16); continue; }
    if (line.startsWith('#')) {
      const m = /^# (\w+)=(.*)$/.exec(line);
      if (m && HEADER_KEYS.includes(m[1])) meta[m[1]] = str(m[2], 200);
      continue;
    }
    if (line.startsWith('S,')) {
      const f = line.split(',');
      if (f.length >= 4 && f.slice(1, 4).every(v => Number.isFinite(+v))) {
        out.push(`S,${f[1]},${f[2]},${f[3]}`);
        centerline++;
      }
      continue;
    }
    if (/^[a-z]/i.test(line)) { columnsLine = line.substring(0, 200); continue; }
    if (/^-?\d/.test(line)) {
      const f = line.split(',');
      if (f.length < 15) continue;
      const n = f.slice(0, 16).map(Number);
      if (!n.slice(0, 15).every(Number.isFinite)) fail(400, 'Ghost file: invalid number in samples');
      t.push(n[0]); x.push(n[2]); y.push(n[3]); z.push(n[4]); spd.push(n[11]);
      out.push(f.slice(0, 16).join(','));
    }
  }
  return { meta, version, centerline, columnsLine, t, x, y, z, spd, body: out };
}

// plausibility: coherent time, distance and speed. Not proof of a clean lap, only a filter for broken or forged files.
function checkGhost(g, trackLengthM) {
  const n = g.t.length;
  if (n < LIMITS.samplesMin) fail(400, 'Ghost file: not enough samples');
  if (n > LIMITS.samplesMax) fail(400, 'Ghost file: too many samples');
  if (!g.meta.car || !g.meta.track) fail(400, 'Ghost file: car or track missing');
  const lapMs = parseInt(g.meta.lapMs, 10);
  if (!Number.isFinite(lapMs) || lapMs < 15000 || lapMs > 3 * 3600 * 1000) fail(400, 'Ghost file: invalid lap time');
  let dist = 0, ratioN = 0;
  const ratios = [];
  let maxKmh = 0;
  for (let i = 1; i < n; i++) {
    const dt = g.t[i] - g.t[i - 1];
    if (dt < -1e-6) fail(400, 'Ghost file: time goes backwards');
    const d = Math.hypot(g.x[i] - g.x[i - 1], g.y[i] - g.y[i - 1], g.z[i] - g.z[i - 1]);
    if (d > 200) fail(400, 'Ghost file: position jump');
    dist += d;
    if (dt > 0.01 && g.spd[i] > 40) { ratios.push((d / dt * 3.6) / g.spd[i]); ratioN++; }
  }
  // geometric speed over ~0.5 s windows
  for (let i = 0, j = 0; i < n; i++) {
    while (j < n - 1 && g.t[j] - g.t[i] < 0.5) j++;
    const dt = g.t[j] - g.t[i];
    if (dt >= 0.45) {
      let d = 0;
      for (let k = i + 1; k <= j; k++) d += Math.hypot(g.x[k] - g.x[k - 1], g.y[k] - g.y[k - 1], g.z[k] - g.z[k - 1]);
      maxKmh = Math.max(maxKmh, d / dt * 3.6);
    }
    if (j >= n - 1 && dt < 0.45) break;
  }
  const lastT = g.t[n - 1];
  if (Math.abs(lastT * 1000 - lapMs) > 2500) fail(400, 'Ghost file: lap time does not match the samples');
  if (g.t[0] > 3) fail(400, 'Ghost file: lap does not start at the line');
  if (maxKmh > 520) fail(400, 'Ghost file: impossible speed');
  if (ratioN > 50) {
    ratios.sort((a, b) => a - b);
    const med = ratios[Math.floor(ratios.length / 2)];
    if (med < 0.75 || med > 1.33) fail(400, 'Ghost file: speed does not match the distance travelled');
  }
  if (trackLengthM > 100 && (dist < trackLengthM * 0.8 || dist > trackLengthM * 1.3)) {
    fail(400, 'Ghost file: lap length does not match the track length');
  }
  return { lapMs, samples: n, lapLengthM: Math.round(dist) };
}

function rebuildGhost(g, driver) {
  const lines = ['# GHOSTLAB ' + (g.version || '?')];
  for (const k of HEADER_KEYS) {
    if (g.meta[k] != null || k === 'driver') lines.push(`# ${k}=${k === 'driver' ? driver : g.meta[k]}`);
  }
  let headerDone = false;
  for (const l of g.body) {
    if (!headerDone && !l.startsWith('S,')) {
      lines.push(g.columnsLine || 't,pos,x,y,z,lx,ly,lz,ux,uy,uz,spd,gas,brk,gear,hg');
      headerDone = true;
    }
    lines.push(l);
  }
  return lines.join('\n') + '\n';
}

// upload: { title, description, file (base64; gzip, CSP ac.compress() output or plain text), trackName, trackLengthM,
//           carName, carBrand, carAuthor, carVersion, carUrl, carFingerprint, cspVersion, appVersion }
async function uploadGhost(ctx) {
  const u = await writer(ctx, true);
  const p = await readJSON(ctx.request);
  const title = str(p.title, LIMITS.title);
  if (title.length < 3) fail(400, 'Title too short');
  if (!u.moderator) {
    const r = await ctx.env.DB.prepare('SELECT COUNT(*) AS n, MIN(createdDate) AS first FROM ghosts WHERE userID = ? AND createdDate > ?')
      .bind(u.userID, now() - DAY).first();
    if (r && r.n >= LIMITS.uploadsPerDay) {
      const wait = Math.max(1, Math.ceil(((r.first || now()) + DAY - now()) / 3600));
      fail(429, `Upload limit reached (${LIMITS.uploadsPerDay} ghosts per 24 h), next one possible in ${wait} h`);
    }
  }

  let bytes;
  try { bytes = b64ToBytes(p.file || ''); } catch (e) { fail(400, 'Invalid file encoding'); }
  if (bytes.length < 20) fail(400, 'Ghost file missing');
  let raw;
  if (bytes[0] === 0x1f && bytes[1] === 0x8b) raw = await gunzip(bytes);
  else if (bytes.length > 7 && bytes[5] === 0x1f && bytes[6] === 0x8b) raw = await gunzip(bytes.subarray(5));  // CSP ac.compress(Gzip)
  else raw = bytes;
  if (raw.length > LIMITS.fileBytes) fail(413, 'Ghost file too big');
  const text = new TextDecoder().decode(raw);
  if (!text.includes('# GHOSTLAB')) fail(400, 'Not a GhostLab ghost file');
  const g = parseGhost(text);
  const trackLengthM = Number(p.trackLengthM) > 0 ? Math.min(Number(p.trackLengthM), 100000) : 0;
  const chk = checkGhost(g, trackLengthM);

  // a shared ghost is credited to the person who shares it, never to the original driver of a replay lap
  const driver = u.userName;
  const file = new TextEncoder().encode(rebuildGhost(g, driver));
  const gz = await gzip(file);
  const blobKey = `ghosts/${now()}-${randomToken(12)}.csv.gz`;
  await ctx.env.BUCKET.put(blobKey, gz, { httpMetadata: { contentType: 'text/csv; charset=utf-8', contentEncoding: 'gzip' } });

  const r = await ctx.env.DB.prepare(`INSERT INTO ghosts (createdDate, userID, userName, title, description, trackID, layout,
      trackName, trackLengthM, carID, carName, carBrand, carAuthor, carVersion, carUrl, carFingerprint, skin, driver, lapMs,
      source, samples, lapLengthM, sizeBytes, blobKey, cspVersion, appVersion)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) RETURNING ghostID`)
    .bind(now(), u.userID, u.userName, title, str(p.description, LIMITS.description),
      idStr(g.meta.track), idStr(g.meta.layout || ''), str(p.trackName, 100), trackLengthM,
      idStr(g.meta.car), str(p.carName || g.meta.carName, 100), str(p.carBrand, 60), str(p.carAuthor, 100),
      str(p.carVersion, 40), safeUrl(p.carUrl), str(p.carFingerprint, 64), str(g.meta.skin, 100), driver, chk.lapMs,
      g.meta.source === 'replay' ? 'replay' : 'live', chk.samples, chk.lapLengthM, gz.length, blobKey,
      intParam(p.cspVersion, 0, 0, 1e9), str(p.appVersion, 16))
    .first();
  return json({ ghostID: r.ghostID, lapMs: chk.lapMs, samples: chk.samples, lapLengthM: chk.lapLengthM, sizeBytes: gz.length });
}

function safeUrl(v) {
  const s = str(v, 300);
  return /^https?:\/\/[^\s"'<>]+$/i.test(s) ? s : '';
}

const LIST_COLUMNS = `g.ghostID, g.createdDate, g.userName, g.title, g.description, g.trackID, g.layout, g.trackName, g.trackLengthM, g.carID,
  g.carName, g.carBrand, g.carAuthor, g.carVersion, g.carUrl, g.carFingerprint, g.skin, g.driver, g.lapMs, g.source,
  g.samples, g.lapLengthM, g.sizeBytes, g.statLikes, g.statDislikes, g.statDownloads, g.statComments, g.hidden`;

function shapeItem(row, u) {
  const item = Object.assign({}, row);
  item.own = !!(u && row.userID === u.userID);
  if (!(u && u.moderator)) delete item.userID;
  if (item.myVote === null || item.myVote === undefined) item.myVote = 0;
  delete item.blobKey;
  if ('driver' in item) item.driver = item.userName || '';   // ghosts shared before: no original driver name either
  return item;
}

async function listGhosts(ctx) {
  const u = await auth(ctx, false);
  const q = ctx.url.searchParams;
  const where = [], args = [];
  const trackID = idStr(q.get('trackID') || '');
  const layout = q.has('layout') ? idStr(q.get('layout') || '') : null;
  const near = Number(q.get('near') || 0);
  if (near > 100) {
    // other versions of the same circuit: same length within 1.5 %, other track or layout
    where.push('g.trackLengthM BETWEEN ? AND ?');
    args.push(near * 0.985, near * 1.015);
    if (trackID) { where.push('NOT (g.trackID = ? AND g.layout = ?)'); args.push(trackID, layout || ''); }
  } else if (trackID) {
    where.push('g.trackID = ?'); args.push(trackID);
    if (layout !== null) { where.push('g.layout = ?'); args.push(layout); }
  }
  const carID = idStr(q.get('carID') || '');
  if (carID) { where.push('g.carID = ?'); args.push(carID); }
  const userName = str(q.get('userName'), 40);
  if (userName) { where.push('g.userName = ? COLLATE NOCASE'); args.push(userName); }
  if (q.get('mine') === '1') {
    if (!u) fail(401, 'Invalid session');
    where.push('g.userID = ?'); args.push(u.userID);
  }
  const search = str(q.get('search'), 60);
  if (search) {
    // every word must match one of: title, description, sharer name, car (name or folder), track (name or folder)
    const fields = ['g.title', 'g.description', 'g.userName', 'g.carName', 'g.carID', 'g.trackName', 'g.trackID'];
    for (const word of search.split(/\s+/).filter(Boolean).slice(0, 6)) {
      const s = '%' + likeEscape(word) + '%';
      where.push('(' + fields.map(f => `${f} LIKE ? ESCAPE '\\'`).join(' OR ') + ')');
      for (let i = 0; i < fields.length; i++) args.push(s);
    }
  }
  if (!(u && u.moderator && q.get('includeHidden') === '1')) where.push('g.hidden = 0');
  const order = {
    fastest: 'g.lapMs ASC, g.createdDate DESC',
    newest: 'g.createdDate DESC',
    liked: '(g.statLikes - g.statDislikes) DESC, g.lapMs ASC',
    downloads: 'g.statDownloads DESC, g.lapMs ASC',
    hot: `((g.statLikes * 20 + g.statDownloads + g.statComments * 2 - g.statDislikes * 30) * 1000.0 / (MAX(3600, ${now()} - g.createdDate) / 3600.0)) DESC`,
  }[q.get('orderBy') || 'fastest'] || 'g.lapMs ASC, g.createdDate DESC';
  const limit = intParam(q.get('limit'), 20, 1, LIMITS.pageMax);
  const offset = intParam(q.get('offset'), 0, 0, 1e7);
  const w = where.length ? 'WHERE ' + where.join(' AND ') : '';
  const voteJoin = u ? 'LEFT JOIN votes v ON v.ghostID = g.ghostID AND v.userID = ?' : '';
  const voteCol = u ? ', v.direction AS myVote' : '';
  const listArgs = u ? [u.userID, ...args] : args;
  const [count, rows] = await ctx.env.DB.batch([
    ctx.env.DB.prepare(`SELECT COUNT(*) AS n FROM ghosts g ${w}`).bind(...args),
    ctx.env.DB.prepare(`SELECT ${LIST_COLUMNS}, g.userID${voteCol} FROM ghosts g ${voteJoin} ${w} ORDER BY ${order} LIMIT ? OFFSET ?`)
      .bind(...listArgs, limit, offset),
  ]);
  return json({ total: count.results[0].n, offset, items: rows.results.map(r => shapeItem(r, u)) });
}

async function getGhostRow(env, id) {
  const row = await env.DB.prepare('SELECT * FROM ghosts WHERE ghostID = ?').bind(id).first();
  if (!row) fail(404, 'Ghost not found');
  return row;
}

async function getGhost(ctx, id) {
  const u = await auth(ctx, false);
  const row = await getGhostRow(ctx.env, id);
  if (row.hidden && !(u && (u.moderator || u.userID === row.userID))) fail(404, 'Ghost not found');
  if (u) {
    const v = await ctx.env.DB.prepare('SELECT direction FROM votes WHERE ghostID = ? AND userID = ?').bind(id, u.userID).first();
    row.myVote = v ? v.direction : 0;
  }
  return json(shapeItem(row, u));
}

async function downloadGhost(ctx, id) {
  const u = await auth(ctx, false);
  const row = await getGhostRow(ctx.env, id);
  if (row.hidden && !(u && (u.moderator || u.userID === row.userID))) fail(404, 'Ghost not found');
  const obj = await ctx.env.BUCKET.get(row.blobKey);
  if (!obj) fail(404, 'Ghost file missing');
  const who = u ? 'u:' + u.userID : 'ip:' + await ipHash(ctx.env, ctx.request);
  ctx.waitUntil((async () => {
    const r = await ctx.env.DB.prepare('INSERT OR IGNORE INTO downloads (ghostID, who) VALUES (?, ?)').bind(id, who).run();
    if (r.meta && r.meta.changes > 0) {
      await ctx.env.DB.prepare('UPDATE ghosts SET statDownloads = statDownloads + 1 WHERE ghostID = ?').bind(id).run();
    }
  })().catch(() => {}));
  const headers = { 'Content-Type': 'text/csv; charset=utf-8', 'Cache-Control': 'no-store', 'X-Ghost-ID': String(id) };
  if (/\bgzip\b/i.test(ctx.request.headers.get('Accept-Encoding') || '')) {
    headers['Content-Encoding'] = 'gzip';
    return new Response(obj.body, { headers, encodeBody: 'manual' });
  }
  // client without gzip support: plain text
  return new Response(obj.body.pipeThrough(new DecompressionStream('gzip')), { headers });
}

async function deleteGhost(ctx, id) {
  const u = await auth(ctx, true);
  const row = await getGhostRow(ctx.env, id);
  if (row.userID !== u.userID && !u.moderator) fail(403, 'Not your ghost');
  await ctx.env.DB.batch([
    ctx.env.DB.prepare('DELETE FROM ghosts WHERE ghostID = ?').bind(id),
    ctx.env.DB.prepare('DELETE FROM votes WHERE ghostID = ?').bind(id),
    ctx.env.DB.prepare('DELETE FROM comments WHERE ghostID = ?').bind(id),
    ctx.env.DB.prepare('DELETE FROM reports WHERE ghostID = ?').bind(id),
    ctx.env.DB.prepare('DELETE FROM downloads WHERE ghostID = ?').bind(id),
  ]);
  await ctx.env.BUCKET.delete(row.blobKey);
  return json({ deleted: id });
}

async function voteGhost(ctx, id) {
  const u = await writer(ctx, false);
  const p = await readJSON(ctx.request);
  const dir = Math.sign(Number(p.direction) || 0);
  const row = await getGhostRow(ctx.env, id);
  if (row.userID === u.userID) fail(400, 'You cannot vote for your own ghost');
  const n = await countSince(ctx.env, 'SELECT COUNT(*) AS n FROM votes WHERE userID = ? AND createdDate > ?', u.userID, DAY);
  if (n >= LIMITS.votesPerDay) fail(429, 'Too many votes today');
  const prev = await ctx.env.DB.prepare('SELECT direction FROM votes WHERE ghostID = ? AND userID = ?').bind(id, u.userID).first();
  const old = prev ? prev.direction : 0;
  if (old === dir) return json({ ghostID: id, myVote: dir, statLikes: row.statLikes, statDislikes: row.statDislikes });
  const dl = (dir === 1 ? 1 : 0) - (old === 1 ? 1 : 0);
  const dd = (dir === -1 ? 1 : 0) - (old === -1 ? 1 : 0);
  const ops = [
    dir === 0
      ? ctx.env.DB.prepare('DELETE FROM votes WHERE ghostID = ? AND userID = ?').bind(id, u.userID)
      : ctx.env.DB.prepare('INSERT OR REPLACE INTO votes (ghostID, userID, direction, createdDate) VALUES (?, ?, ?, ?)').bind(id, u.userID, dir, now()),
    ctx.env.DB.prepare('UPDATE ghosts SET statLikes = MAX(0, statLikes + ?), statDislikes = MAX(0, statDislikes + ?) WHERE ghostID = ? RETURNING statLikes, statDislikes')
      .bind(dl, dd, id),
  ];
  const res = await ctx.env.DB.batch(ops);
  const s = res[1].results[0] || {};
  return json({ ghostID: id, myVote: dir, statLikes: s.statLikes, statDislikes: s.statDislikes });
}

async function listComments(ctx, id) {
  const u = await auth(ctx, false);
  const row = await getGhostRow(ctx.env, id);
  if (row.hidden && !(u && (u.moderator || u.userID === row.userID))) fail(404, 'Ghost not found');
  const q = ctx.url.searchParams;
  const limit = intParam(q.get('limit'), 30, 1, LIMITS.pageMax);
  const offset = intParam(q.get('offset'), 0, 0, 1e7);
  const [count, rows] = await ctx.env.DB.batch([
    ctx.env.DB.prepare('SELECT COUNT(*) AS n FROM comments WHERE ghostID = ?').bind(id),
    ctx.env.DB.prepare('SELECT commentID, createdDate, userID, userName, text FROM comments WHERE ghostID = ? ORDER BY createdDate ASC, commentID ASC LIMIT ? OFFSET ?')
      .bind(id, limit, offset),
  ]);
  return json({ total: count.results[0].n, offset, items: rows.results.map(r => {
    const c = { commentID: r.commentID, createdDate: r.createdDate, userName: r.userName, text: r.text, own: !!(u && u.userID === r.userID) };
    if (u && u.moderator) c.userID = r.userID;
    return c;
  }) });
}

async function addComment(ctx, id) {
  const u = await writer(ctx, true);
  const p = await readJSON(ctx.request);
  const text = str(p.text, LIMITS.comment);
  if (!text) fail(400, 'Empty comment');
  await getGhostRow(ctx.env, id);
  const n = await countSince(ctx.env, 'SELECT COUNT(*) AS n FROM comments WHERE userID = ? AND createdDate > ?', u.userID, DAY);
  if (n >= LIMITS.commentsPerDay) fail(429, 'Too many comments today');
  const res = await ctx.env.DB.batch([
    ctx.env.DB.prepare('INSERT INTO comments (ghostID, createdDate, userID, userName, text) VALUES (?, ?, ?, ?, ?) RETURNING commentID')
      .bind(id, now(), u.userID, u.userName, text),
    ctx.env.DB.prepare('UPDATE ghosts SET statComments = statComments + 1 WHERE ghostID = ?').bind(id),
  ]);
  return json({ commentID: res[0].results[0].commentID });
}

async function deleteComment(ctx, commentID) {
  const u = await auth(ctx, true);
  const c = await ctx.env.DB.prepare('SELECT commentID, ghostID, userID FROM comments WHERE commentID = ?').bind(commentID).first();
  if (!c) fail(404, 'Comment not found');
  if (c.userID !== u.userID && !u.moderator) fail(403, 'Not your comment');
  await ctx.env.DB.batch([
    ctx.env.DB.prepare('DELETE FROM comments WHERE commentID = ?').bind(commentID),
    ctx.env.DB.prepare('UPDATE ghosts SET statComments = MAX(0, statComments - 1) WHERE ghostID = ?').bind(c.ghostID),
  ]);
  return json({ deleted: commentID });
}

async function reportGhost(ctx, id) {
  const u = await writer(ctx, false);
  const p = await readJSON(ctx.request);
  const row = await getGhostRow(ctx.env, id);
  if (row.userID === u.userID) fail(400, 'You cannot report your own ghost');
  const r = await ctx.env.DB.prepare('INSERT OR IGNORE INTO reports (ghostID, userID, reason, createdDate) VALUES (?, ?, ?, ?)')
    .bind(id, u.userID, str(p.reason, LIMITS.reason), now()).run();
  if (r.meta && r.meta.changes > 0) {
    await ctx.env.DB.prepare(`UPDATE ghosts SET reports = reports + 1, hidden = CASE WHEN reports + 1 >= ? THEN 1 ELSE hidden END WHERE ghostID = ?`)
      .bind(LIMITS.reportsToHide, id).run();
  }
  return json({ reported: id });
}

// ---------------------------------------------------------------------------------------------------------------------
// Sessions (same scheme as CSP's Setup Exchange)
async function sessionBegin(ctx) {
  const p = await readJSON(ctx.request);
  const clientID = str(p.userID, 128);
  if (!/^[A-Za-z0-9+/=_-]{16,128}$/.test(clientID)) fail(400, 'Invalid user ID');
  const ip = await ipHash(ctx.env, ctx.request);
  const recent = await ctx.env.DB.prepare('SELECT (SELECT COUNT(*) FROM sessions WHERE ipHash = ?1 AND createdDate > ?2) + (SELECT COUNT(*) FROM pending WHERE ipHash = ?1 AND createdDate > ?2) AS n')
    .bind(ip, now() - 3600).first();
  if (recent && recent.n >= LIMITS.sessionsPerHourPerIP) fail(429, 'Too many sessions, try again later');
  const secret = randomToken(24);
  await ctx.env.DB.prepare('INSERT OR REPLACE INTO pending (userID, secret, ipHash, createdDate) VALUES (?, ?, ?, ?)')
    .bind(await sha256b64(salt(ctx.env), 'pending', clientID), secret, ip, now()).run();
  return json({ key: secret });
}

async function sessionFinish(ctx) {
  const p = await readJSON(ctx.request);
  const clientID = str(p.userID, 128);
  if (!/^[A-Za-z0-9+/=_-]{16,128}$/.test(clientID)) fail(400, 'Invalid user ID');
  const pendingID = await sha256b64(salt(ctx.env), 'pending', clientID);
  const pend = await ctx.env.DB.prepare('SELECT secret, createdDate FROM pending WHERE userID = ?').bind(pendingID).first();
  if (!pend || pend.createdDate < now() - 300) fail(400, 'Session request expired, try again');
  await ctx.env.DB.prepare('DELETE FROM pending WHERE userID = ?').bind(pendingID).run();
  let header, signature;
  try { header = b64ToBytes(p.header || ''); signature = b64ToBytes(p.signature || ''); } catch (e) { fail(400, 'Invalid signature encoding'); }
  const prefix = new TextEncoder().encode(clientID);
  if (header.length < prefix.length || !prefix.every((b, i) => header[i] === b)) fail(400, 'Invalid signature header');
  const message = concatBytes(header, new TextEncoder().encode(SIGN_FORMAT), new TextEncoder().encode(pend.secret));
  let key;
  try { key = await cspKey(ctx.env); } catch (e) { fail(500, 'Server key error'); }
  const ok = await crypto.subtle.verify('RSASSA-PKCS1-v1_5', key, signature, message);
  if (!ok) fail(403, 'Signature check failed');
  const userID = await sha256b64(salt(ctx.env), 'user', clientID);
  const ip = await ipHash(ctx.env, ctx.request);
  const token = randomToken(24);
  await ctx.env.DB.batch([
    ctx.env.DB.prepare('INSERT OR IGNORE INTO users (userID, userName, createdDate, banned, ipHash) VALUES (?, NULL, ?, 0, ?)').bind(userID, now(), ip),
    ctx.env.DB.prepare('UPDATE users SET ipHash = ? WHERE userID = ?').bind(ip, userID),
    ctx.env.DB.prepare('INSERT INTO sessions (tokenHash, userID, ipHash, createdDate) VALUES (?, ?, ?, ?)').bind(await sha256b64('session', token), userID, ip, now()),
    ctx.env.DB.prepare('DELETE FROM sessions WHERE createdDate < ?').bind(now() - LIMITS.sessionDays * DAY),
    ctx.env.DB.prepare('DELETE FROM pending WHERE createdDate < ?').bind(now() - 600),
  ]);
  const user = await ctx.env.DB.prepare('SELECT userName, banned FROM users WHERE userID = ?').bind(userID).first();
  return json({ session: token, userID, userName: user.userName || '', banned: !!user.banned, moderator: moderators(ctx.env).includes(userID) });
}

async function getMe(ctx) {
  const u = await auth(ctx, true);
  return json({ userID: u.userID, userName: u.userName, banned: u.banned, moderator: u.moderator });
}

async function setName(ctx) {
  const u = await writer(ctx, false);
  const p = await readJSON(ctx.request);
  const name = str(p.userName, 24);
  if (!/^[A-Za-z0-9][A-Za-z0-9 _.\-]{1,22}[A-Za-z0-9_.\-]$/.test(name)) fail(400, 'Name: 3 to 24 letters, digits, spaces, _ . -');
  if (/^(me|moi|admin|moderator|ghostlab)$/i.test(name)) fail(400, 'This name is reserved');
  const taken = await ctx.env.DB.prepare('SELECT userID FROM users WHERE userName = ? COLLATE NOCASE').bind(name).first();
  if (taken && taken.userID !== u.userID) fail(409, 'This name is taken');
  await ctx.env.DB.batch([
    ctx.env.DB.prepare('UPDATE users SET userName = ? WHERE userID = ?').bind(name, u.userID),
    ctx.env.DB.prepare('UPDATE ghosts SET userName = ? WHERE userID = ?').bind(name, u.userID),
    ctx.env.DB.prepare('UPDATE comments SET userName = ? WHERE userID = ?').bind(name, u.userID),
  ]);
  return json({ userName: name });
}

// moderation: moderators are listed in the MODERATORS variable
async function modBan(ctx, banned) {
  const u = await auth(ctx, true);
  if (!u.moderator) fail(403, 'Moderators only');
  const p = await readJSON(ctx.request);
  const target = str(p.userID, 64);
  const ops = [ctx.env.DB.prepare('UPDATE users SET banned = ? WHERE userID = ?').bind(banned ? 1 : 0, target)];
  if (banned) {
    ops.push(ctx.env.DB.prepare('UPDATE ghosts SET hidden = 1 WHERE userID = ?').bind(target));
    ops.push(ctx.env.DB.prepare('DELETE FROM sessions WHERE userID = ?').bind(target));
  }
  await ctx.env.DB.batch(ops);
  return json({ userID: target, banned });
}
async function modHide(ctx, id) {
  const u = await auth(ctx, true);
  if (!u.moderator) fail(403, 'Moderators only');
  const p = await readJSON(ctx.request);
  await ctx.env.DB.prepare('UPDATE ghosts SET hidden = ? WHERE ghostID = ?').bind(p.hidden ? 1 : 0, id).run();
  return json({ ghostID: id, hidden: !!p.hidden });
}

async function stats(ctx) {
  const r = await ctx.env.DB.prepare(`SELECT (SELECT COUNT(*) FROM ghosts WHERE hidden = 0) AS ghosts,
    (SELECT COUNT(*) FROM users WHERE userName IS NOT NULL) AS users, (SELECT COUNT(*) FROM comments) AS comments`).first();
  return json(r, 200, { 'Cache-Control': 'public, max-age=300' });
}

// latest GhostLab version, for the update message in the app: GitHub's latest release (cached 10 min) or variables
async function latestVersion(ctx) {
  const env = ctx.env;
  let info = null;
  if (env.LATEST_VERSION) {
    info = { version: str(env.LATEST_VERSION, 20), download: safeUrl(env.DOWNLOAD_URL), page: safeUrl(env.RELEASE_PAGE),
      notes: str(env.RELEASE_NOTES, 1500) };
  } else if (env.GITHUB_REPO && /^[\w.\-]+\/[\w.\-]+$/.test(env.GITHUB_REPO)) {
    const key = 'release:' + env.GITHUB_REPO;
    const cached = await env.DB.prepare('SELECT v, t FROM kv WHERE k = ?').bind(key).first();
    if (cached && cached.t > now() - 600) {
      info = JSON.parse(cached.v);
    } else {
      try {
        const api = (env.GITHUB_API || 'https://api.github.com') + '/repos/' + env.GITHUB_REPO + '/releases/latest';
        const headers = { 'User-Agent': 'GhostLab-Exchange', 'Accept': 'application/vnd.github+json' };
        if (env.GITHUB_TOKEN) headers.Authorization = 'Bearer ' + env.GITHUB_TOKEN;
        const res = await fetch(api, { headers });
        if (!res.ok) throw new Error('GitHub ' + res.status);
        const rel = await res.json();
        const asset = (rel.assets || []).find(a => /\.zip$/i.test(a.name || '') && !/server/i.test(a.name || ''));
        info = { version: str(String(rel.tag_name || '').replace(/^v/i, ''), 20), download: asset ? safeUrl(asset.browser_download_url) : '',
          page: safeUrl(rel.html_url), notes: str(rel.body, 1500) };
        await env.DB.prepare('INSERT OR REPLACE INTO kv (k, v, t) VALUES (?, ?, ?)').bind(key, JSON.stringify(info), now()).run();
      } catch (e) {
        if (cached) info = JSON.parse(cached.v);   // GitHub unreachable or rate limited: last known release
      }
    }
  }
  return json(info || { version: '' }, 200, { 'Cache-Control': 'public, max-age=300' });
}

const PRIVACY = `<!doctype html><html lang="fr"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>GhostLab Exchange - Confidentialité</title><style>body{font:16px/1.5 system-ui,sans-serif;max-width:760px;margin:24px auto;padding:0 16px;color:#222;background:#fff}h1{font-size:1.4em}h2{font-size:1.1em;margin-top:1.6em}@media(prefers-color-scheme:dark){body{background:#151515;color:#ddd}}</style></head><body>
<h1>GhostLab Exchange : données et confidentialité / data and privacy</h1>
<h2>Ce qui est stocké</h2>
<ul>
<li>Un identifiant anonyme dérivé de ton PC : empreinte salée de la clé machine fournie par Custom Shaders Patch. Pas de Steam ID, pas d'e-mail, pas de mot de passe.</li>
<li>Le pseudo que tu choisis, tes ghosts (positions, vitesses et pédales sur un tour, voiture, circuit, temps), leurs titres et descriptions, tes commentaires, likes et signalements.</li>
<li>Une empreinte salée de ton adresse IP (jamais l'adresse elle-même), pour limiter les abus.</li>
</ul>
<h2>Utilisation</h2>
<p>Uniquement pour faire fonctionner le service : afficher et partager les ghosts, limiter le spam, modérer. Rien n'est vendu ni partagé. Hébergement : Cloudflare.</p>
<h2>Tes droits</h2>
<p>Tu peux supprimer à tout moment tes ghosts et tes commentaires depuis GhostLab. Pour supprimer toutes tes données ou pour signaler un contenu illégal, contacte l'auteur de GhostLab (page GitHub du projet). Les contenus signalés plusieurs fois sont masqués en attendant la modération.</p>
<h2>English</h2>
<p>Stored: an anonymous ID derived from your PC (salted hash of the machine key given by Custom Shaders Patch; no Steam ID, e-mail or password), the user name you choose, your ghosts with their titles and descriptions, comments, votes and reports, and a salted hash of your IP address for abuse limits. Used only to run the service. You can delete your ghosts and comments from GhostLab at any time; for full deletion or to report illegal content, contact the GhostLab author on the project's GitHub page.</p>
</body></html>`;

// ---------------------------------------------------------------------------------------------------------------------
async function route(ctx) {
  const { request, url } = ctx;
  const m = request.method;
  const parts = url.pathname.split('/').filter(Boolean);
  const id = parts[1] && /^\d{1,12}$/.test(parts[1]) ? parseInt(parts[1], 10) : null;
  const p0 = parts[0] || '';

  if (m === 'GET' && parts.length === 0) {
    return json({ service: SERVICE, api: API_VERSION, privacy: url.origin + '/privacy' }, 200, { 'Cache-Control': 'public, max-age=60' });
  }
  if (m === 'GET' && p0 === 'privacy') return new Response(PRIVACY, { headers: { 'Content-Type': 'text/html; charset=utf-8' } });
  await ensureSchema(ctx.env);
  if (p0 === 'stats' && m === 'GET') return stats(ctx);
  if (p0 === 'version' && m === 'GET') return latestVersion(ctx);
  if (p0 === 'session' && parts[1] === 'begin' && m === 'POST') return sessionBegin(ctx);
  if (p0 === 'session' && parts[1] === 'finish' && m === 'POST') return sessionFinish(ctx);
  if (p0 === 'me' && parts.length === 1) {
    if (m === 'GET') return getMe(ctx);
    if (m === 'POST') return setName(ctx);
  }
  if (p0 === 'ghosts') {
    if (parts.length === 1) {
      if (m === 'GET') return listGhosts(ctx);
      if (m === 'POST') return uploadGhost(ctx);
    }
    if (id !== null && parts.length === 2) {
      if (m === 'GET') return getGhost(ctx, id);
      if (m === 'DELETE') return deleteGhost(ctx, id);
    }
    if (id !== null && parts.length === 3) {
      if (parts[2] === 'file' && m === 'GET') return downloadGhost(ctx, id);
      if (parts[2] === 'vote' && m === 'POST') return voteGhost(ctx, id);
      if (parts[2] === 'comments' && m === 'GET') return listComments(ctx, id);
      if (parts[2] === 'comments' && m === 'POST') return addComment(ctx, id);
      if (parts[2] === 'report' && m === 'POST') return reportGhost(ctx, id);
    }
  }
  if (p0 === 'comments' && id !== null && parts.length === 2 && m === 'DELETE') return deleteComment(ctx, id);
  if (p0 === 'mod') {
    if (parts[1] === 'ban' && m === 'POST') return modBan(ctx, true);
    if (parts[1] === 'unban' && m === 'POST') return modBan(ctx, false);
    if (parts[1] === 'hide' && parts[2] && /^\d+$/.test(parts[2]) && m === 'POST') return modHide(ctx, parseInt(parts[2], 10));
  }
  fail(404, `Unknown endpoint: ${m} ${url.pathname}`);
}

// bindings: DB and BUCKET, or any D1 / R2 binding whatever its name
function resolveBindings(env) {
  let db = env.DB, bucket = env.BUCKET;
  for (const k of Object.keys(env)) {
    const v = env[k];
    if (!v || typeof v !== 'object') continue;
    if (!db && typeof v.prepare === 'function' && typeof v.batch === 'function') db = v;
    else if (!bucket && typeof v.put === 'function' && typeof v.get === 'function' && typeof v.head === 'function' && typeof v.list === 'function') bucket = v;
  }
  return { db, bucket };
}

export default {
  async fetch(request, rawEnv, execCtx) {
    const { db, bucket } = resolveBindings(rawEnv);
    const env = Object.assign({}, rawEnv, { DB: db, BUCKET: bucket });
    const ctx = { request, env, url: new URL(request.url), waitUntil: p => execCtx.waitUntil(p) };
    try {
      if (!env.DB) fail(500, 'Server not configured: add a D1 database binding to the Worker (Settings > Bindings)');
      if (!env.BUCKET) fail(500, 'Server not configured: add an R2 bucket binding to the Worker (Settings > Bindings)');
      return await route(ctx);
    } catch (e) {
      if (e instanceof HttpError) return json({ error: e.message }, e.status);
      console.error(e && e.stack || e);
      return json({ error: 'Server error' }, 500);
    }
  },
};
