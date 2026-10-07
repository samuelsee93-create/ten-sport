#!/usr/bin/env python3
import json
from pathlib import Path

app_path = Path('src/App.jsx')
styles_path = Path('src/styles.css')
pkg_path = Path('package.json')

app = app_path.read_text(encoding='utf-8')

import_old = "import { signIn, signOut, signUp } from './services/authService.js';\n"
import_new = import_old + "import { loadAssetWatchlist, setAssetWatched } from './services/watchlistService.js';\n"
if "./services/watchlistService.js" not in app:
    if import_old not in app:
        raise SystemExit('Could not find authService import')
    app = app.replace(import_old, import_new, 1)

state_old = "  const [availability, setAvailability] = useState('ALL');\n  const [sort, setSort] = useState({ key: 'POINTS', direction: 'DESC' });"
state_new = "  const [availability, setAvailability] = useState('ALL');\n  const [watchFilter, setWatchFilter] = useState('ALL');\n  const [watchListIds, setWatchListIds] = useState([]);\n  const [watchError, setWatchError] = useState('');\n  const [sort, setSort] = useState({ key: 'POINTS', direction: 'DESC' });"
if state_old in app:
    app = app.replace(state_old, state_new, 1)
elif "const [watchFilter, setWatchFilter]" not in app:
    raise SystemExit('Could not find Assets state block')

ownership_old = "  const ownershipByAsset = Object.fromEntries(\n    state.rosterMemberships.map((membership) => [membership.assetId, membership.teamId])\n  );\n"
ownership_new = ownership_old + "\n  const watchedSet = useMemo(() => new Set(watchListIds), [watchListIds]);\n\n  useEffect(() => {\n    let cancelled = false;\n    setWatchError('');\n    loadAssetWatchlist({ leagueId: state.league.id, userId: state.currentUserId })\n      .then((assetIds) => {\n        if (!cancelled) setWatchListIds(assetIds);\n      })\n      .catch((error) => {\n        if (!cancelled) setWatchError(error.message || 'Unable to load watch list.');\n      });\n    return () => { cancelled = true; };\n  }, [state.league.id, state.currentUserId]);\n"
if "const watchedSet = useMemo" not in app:
    if ownership_old not in app:
        raise SystemExit('Could not find ownership block')
    app = app.replace(ownership_old, ownership_new, 1)

map_old = "        sportRank: rankedAssets.sportRankById[asset.id] ?? Number.MAX_SAFE_INTEGER,\n        status: owner ? 'ROSTERED' : 'AVAILABLE',"
map_new = "        sportRank: rankedAssets.sportRankById[asset.id] ?? Number.MAX_SAFE_INTEGER,\n        watched: watchedSet.has(asset.id),\n        status: owner ? 'ROSTERED' : 'AVAILABLE',"
if map_old in app:
    app = app.replace(map_old, map_new, 1)

filter_old = "    .filter(({ asset, owner }) => {\n      const matchesQuery = !query.trim()\n        || asset.name.toLowerCase().includes(query.trim().toLowerCase());\n      const matchesSport = sport === 'ALL' || asset.sport === sport;\n      const matchesAvailability = availability === 'ALL'\n        || (availability === 'AVAILABLE' && !owner)\n        || (availability === 'ROSTERED' && !!owner);\n      return matchesQuery && matchesSport && matchesAvailability;\n    })"
filter_new = "    .filter(({ asset, owner, watched }) => {\n      const matchesQuery = !query.trim()\n        || asset.name.toLowerCase().includes(query.trim().toLowerCase());\n      const matchesSport = sport === 'ALL' || asset.sport === sport;\n      const matchesAvailability = availability === 'ALL'\n        || (availability === 'AVAILABLE' && !owner)\n        || (availability === 'ROSTERED' && !!owner);\n      const matchesWatch = watchFilter === 'ALL' || watched;\n      return matchesQuery && matchesSport && matchesAvailability && matchesWatch;\n    })"
if filter_old in app:
    app = app.replace(filter_old, filter_new, 1)

sort_old = "      } else if (sort.key === 'STATUS') {\n        comparison = a.status.localeCompare(b.status)\n          || (a.owner?.name ?? '').localeCompare(b.owner?.name ?? '')\n          || a.asset.name.localeCompare(b.asset.name);\n      }"
sort_new = "      } else if (sort.key === 'STATUS') {\n        comparison = a.status.localeCompare(b.status)\n          || (a.owner?.name ?? '').localeCompare(b.owner?.name ?? '')\n          || a.asset.name.localeCompare(b.asset.name);\n      } else if (sort.key === 'WATCH') {\n        comparison = Number(a.watched) - Number(b.watched)\n          || b.previousPoints - a.previousPoints\n          || a.asset.name.localeCompare(b.asset.name);\n      }"
if sort_old in app:
    app = app.replace(sort_old, sort_new, 1)

indicator_anchor = "  const direction = sort.direction === 'ASC' ? 1 : -1;\n"
toggle_block = indicator_anchor + "\n  const toggleWatch = async (assetId) => {\n    const wasWatched = watchedSet.has(assetId);\n    const optimistic = wasWatched\n      ? watchListIds.filter((id) => id !== assetId)\n      : [...watchListIds, assetId];\n    setWatchListIds(optimistic);\n    setWatchError('');\n    try {\n      const next = await setAssetWatched({\n        leagueId: state.league.id,\n        userId: state.currentUserId,\n        assetId,\n        watched: !wasWatched,\n      });\n      setWatchListIds(next);\n    } catch (error) {\n      setWatchListIds(watchListIds);\n      setWatchError(error.message || 'Unable to update watch list.');\n    }\n  };\n"
if "const toggleWatch = async" not in app:
    if indicator_anchor not in app:
        raise SystemExit('Could not find sort direction anchor')
    app = app.replace(indicator_anchor, toggle_block, 1)

card_old = "    <Card title=\"Draftable Assets\" icon={List} action={<Badge>{state.assets.length} assets</Badge>}>"
card_new = "    <Card title=\"Draftable Assets\" icon={List} action={<div className=\"inline\"><Badge>{state.assets.length} assets</Badge><Badge tone=\"warn\">{watchListIds.length} watched</Badge></div>}>"
if card_old in app:
    app = app.replace(card_old, card_new, 1)

app = app.replace('      <div className="asset-toolbar asset-toolbar-compact">', '      <div className="asset-toolbar asset-toolbar-compact asset-toolbar-watch">', 1)

availability_block = "        <select value={availability} onChange={(e) => setAvailability(e.target.value)}>\n          <option value=\"ALL\">All statuses</option>\n          <option value=\"AVAILABLE\">Available only</option>\n          <option value=\"ROSTERED\">Rostered only</option>\n        </select>"
watch_select = availability_block + "\n\n        <select value={watchFilter} onChange={(e) => setWatchFilter(e.target.value)}>\n          <option value=\"ALL\">All watch statuses</option>\n          <option value=\"WATCHED\">My Watch List only</option>\n        </select>"
if "My Watch List only" not in app:
    if availability_block not in app:
        raise SystemExit('Could not find availability select')
    app = app.replace(availability_block, watch_select, 1)

error_anchor = "      </div>\n\n      {state.assets.length === 0 ? ("
error_replacement = "      </div>\n\n      {watchError && <div className=\"error\">{watchError}</div>}\n\n      {state.assets.length === 0 ? ("
if "{watchError &&" not in app:
    if error_anchor not in app:
        raise SystemExit('Could not find watch error anchor')
    app = app.replace(error_anchor, error_replacement, 1)

header_old = "              <tr>\n                <SortHeader sortKey=\"NAME\">Asset</SortHeader>"
header_new = "              <tr>\n                <SortHeader sortKey=\"WATCH\" defaultDirection=\"DESC\">Watch</SortHeader>\n                <SortHeader sortKey=\"NAME\">Asset</SortHeader>"
if 'sortKey="WATCH"' not in app:
    if header_old not in app:
        raise SystemExit('Could not find asset header')
    app = app.replace(header_old, header_new, 1)

rows_old = "              {rows.map(({ asset, previous, owner, previousPoints, overallRank, sportRank }) => (\n                <tr key={asset.id}>\n                  <td><b>{asset.name}</b></td>"
rows_new = "              {rows.map(({ asset, previous, owner, previousPoints, overallRank, sportRank, watched }) => (\n                <tr key={asset.id}>\n                  <td>\n                    <button\n                      className={`favorite-button ${watched ? 'active' : ''}`}\n                      title={watched ? 'Remove from Watch List' : 'Add to Watch List'}\n                      onClick={() => toggleWatch(asset.id)}\n                    >\n                      <Star size={17} fill={watched ? 'currentColor' : 'none'} />\n                    </button>\n                  </td>\n                  <td><b>{asset.name}</b></td>"
if "Remove from Watch List" not in app:
    if rows_old not in app:
        raise SystemExit('Could not find asset row mapping')
    app = app.replace(rows_old, rows_new, 1)

app = app.replace("'v0.11 LIVE'", "'v0.12 LIVE'")
app_path.write_text(app, encoding='utf-8')

styles = styles_path.read_text(encoding='utf-8')
marker = '/* v0.12 asset watch list */'
if marker not in styles:
    styles += """\n\n/* v0.12 asset watch list */\n.asset-toolbar-watch{grid-template-columns:minmax(240px,1fr) repeat(3,minmax(150px,210px))}\n@media(max-width:900px){.asset-toolbar-watch{grid-template-columns:repeat(2,minmax(0,1fr))}}\n@media(max-width:620px){.asset-toolbar-watch{grid-template-columns:1fr}}\n"""
styles_path.write_text(styles, encoding='utf-8')

pkg = json.loads(pkg_path.read_text(encoding='utf-8'))
pkg['version'] = '0.12.0'
pkg_path.write_text(json.dumps(pkg, indent=2) + '\n', encoding='utf-8')

print('Applied persistent asset watch-list UI and bumped v0.12')
