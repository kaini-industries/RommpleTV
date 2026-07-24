# RomM API integration notes

RommpleTV uses the RomM client API with `Authorization: Bearer <client-token>`.

- `GET /api/platforms` returns platform objects.
- `GET /api/roms?platform_ids=<id>&limit=<n>&offset=<n>` returns a page envelope whose `items` field contains ROM objects.
- The query parameter is `platform_ids` (plural); the ROM object field remains `platform_id` (singular).
- `GET /api/roms/{id}/content/{percent-encoded-filename}` returns content bytes.
- `path_cover_small` is an optional server-relative artwork resource path.

Consult the API documentation exposed by your RomM installation for version-specific details.
