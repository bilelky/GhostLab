# GhostLab Exchange server

Backend of the Exchange tab of [GhostLab](../README.md): shared ghosts with titles, likes, comments, reports, filters and search.

One Cloudflare Worker file (`src/worker.js`, no dependencies), a D1 database for metadata and an R2 bucket for ghost files (gzip, about 35 KB each). Tables are created automatically on the first request.

Identity works like CSP's Setup Exchange: no account, no password. GhostLab asks for a challenge, Custom Shaders Patch signs it with its own key (`shared/utils/signing`), and the Worker checks the signature with CSP's public key. Only salted hashes are stored (no Steam ID, no IP address in clear).

## Deploy from the Cloudflare dashboard

1. **Storage & databases > D1 SQL database > Create**: name `ghostlab-exchange`.
2. **R2 object storage > Create bucket**: name `ghostlab-ghosts`.
3. **Workers & Pages > Create > Worker > Start with Hello World**: name `ghostlab-exchange`, **Deploy**.
4. **Edit code**: replace everything with `src/worker.js`, **Deploy**.
5. Worker **Settings > Bindings > Add binding**:
   - D1 database: variable name `DB`, database `ghostlab-exchange`;
   - R2 bucket: variable name `BUCKET`, bucket `ghostlab-ghosts`.
6. Worker **Settings > Variables and Secrets > Add**: type **Secret**, name `SALT`, value a long random string (never change it afterwards: user IDs depend on it).
7. Open `https://ghostlab-exchange.<your-subdomain>.workers.dev/stats`: `{"ghosts":0,"users":0,"comments":0}` means it works.
8. Put that address (without `/stats`) in `apps/lua/GhostLab/ExchangeConfig.lua`.

Moderators: connect once from GhostLab, copy "Your ID" in the Exchange tab (Account), then add a plain text variable `MODERATORS` (comma separated IDs) to the Worker. Moderators can remove any ghost or comment, see hidden ghosts and use `POST /mod/ban`, `/mod/unban` (`{"userID": "..."}`) and `/mod/hide/<ghostID>` (`{"hidden": 1}`).

## Deploy with Wrangler (alternative)

```sh
npx wrangler login
npx wrangler d1 create ghostlab-exchange        # copy the database_id into wrangler.toml
npx wrangler r2 bucket create ghostlab-ghosts
npx wrangler secret put SALT
npx wrangler deploy
```

## API

All responses are JSON (`{"error": "..."}` with a 4xx status on failure). Authenticated calls send `X-Session: <token>`.

| Method and path | Use |
|---|---|
| `POST /session/begin` `{userID}` | Challenge for CSP's signature (`{key}`). |
| `POST /session/finish` `{userID, header, signature}` | Checks the signature, returns `{session, userID, userName, moderator}`. |
| `GET /me`, `POST /me` `{userName}` | Current user, choose a name (3 to 24 characters, unique). |
| `GET /ghosts` | List: `trackID`, `layout`, `near` (track length in m: other versions of the circuit), `carID`, `userName`, `mine=1`, `search`, `orderBy` (`fastest`, `newest`, `liked`, `downloads`, `hot`), `offset`, `limit` (max 50). Returns `{total, items}`. |
| `POST /ghosts` | Share: `{title, description, file (base64, gzip or CSP ac.compress output), trackName, trackLengthM, carName, carBrand, carAuthor, carVersion, carUrl, carFingerprint, cspVersion, appVersion}`. The file is checked (time, speed and distance coherence, lap length). |
| `GET /ghosts/<id>`, `DELETE /ghosts/<id>` | Details; remove (owner or moderator). |
| `GET /ghosts/<id>/file` | Ghost file (CSV). |
| `POST /ghosts/<id>/vote` `{direction: 1, -1 or 0}` | Like, dislike, remove the vote. |
| `GET/POST /ghosts/<id>/comments`, `DELETE /comments/<id>` | Comments (`{text}`, up to 1000 characters). |
| `POST /ghosts/<id>/report` `{reason}` | Report. Hidden after 3 reports from different users. |
| `GET /stats`, `GET /privacy` | Counters; privacy page. |

Limits per user and per day: 15 ghosts, 60 comments, 600 votes. 30 new sessions per hour per IP address.

## License

MIT, see [LICENSE](../LICENSE). The session scheme follows CSP's Setup Exchange server (CC0).
