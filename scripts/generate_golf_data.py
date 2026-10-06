#!/usr/bin/env python3
import csv
import json
import re
import unicodedata
import urllib.request
from collections import defaultdict
from pathlib import Path

LEADERBOARD_URL = "https://github.com/array-carpenter/golfastr/releases/download/leaderboards/leaderboards_2026.csv"
HOLES_URL = "https://github.com/array-carpenter/golfastr/releases/download/holes/holes_2026.csv"
RANKING_SOURCE = "https://www.golf-rankings.com/"
RESULT_SOURCE = "https://github.com/array-carpenter/golfastr/releases/tag/leaderboards"
RANKING_SNAPSHOT = "2026-10-04"

TOP_100 = [
(1,"Scottie Scheffler"),(2,"Rory McIlroy"),(3,"Matt Fitzpatrick"),(4,"Cameron Young"),
(5,"Wyndham Clark"),(6,"Russell Henley"),(7,"Tommy Fleetwood"),(8,"Chris Gotterup"),
(9,"Sam Burns"),(10,"Xander Schauffele"),(11,"Collin Morikawa"),(12,"J.J. Spaun"),
(13,"Viktor Hovland"),(14,"Si Woo Kim"),(15,"Jon Rahm"),(16,"Aaron Rai"),
(17,"Justin Rose"),(18,"Ludvig Aberg"),(19,"Robert MacIntyre"),(20,"Jacob Bridgeman"),
(21,"Alex Noren"),(22,"Ryan Fox"),(23,"Ryan Gerard"),(24,"Tyrrell Hatton"),
(25,"Ben Griffin"),(26,"Hideki Matsuyama"),(27,"Justin Thomas"),(28,"Patrick Cantlay"),
(29,"Patrick Reed"),(30,"Kristoffer Reitan"),(31,"Min Woo Lee"),(32,"Tom Kim"),
(33,"Michael Brennan"),(34,"Akshay Bhatia"),(35,"Joaquin Niemann"),(36,"Sepp Straka"),
(37,"Bryson DeChambeau"),(38,"J.T. Poston"),(39,"Shane Lowry"),(40,"Michael Thorbjornsen"),
(41,"Kurt Kitayama"),(42,"Gary Woodland"),(43,"Nicolai Hojgaard"),(44,"Harris English"),
(45,"Adam Scott"),(46,"Alex Smalley"),(47,"Bud Cauley"),(48,"Rickie Fowler"),
(49,"Maverick McNealy"),(50,"Jake Knapp"),(51,"Keegan Bradley"),(52,"Lucas Herbert"),
(53,"Marco Penge"),(54,"Matt Wallace"),(55,"Eugenio Chacarra"),(56,"Alex Fitzpatrick"),
(57,"Jackson Koivun"),(58,"Casey Jarvis"),(59,"Corey Conners"),(60,"Jordan Spieth"),
(61,"Sungjae Im"),(62,"John Keefer"),(63,"Nicolas Echavarria"),(64,"Michael Kim"),
(65,"Daniel Berger"),(66,"Samuel Stevens"),(67,"Austin Smotherman"),(68,"Brian Harman"),
(69,"Harry Hall"),(70,"Ryo Hisatsune"),(71,"Pierceson Coody"),(72,"Ross Steelman"),
(73,"Jordan Smith"),(74,"Jason Day"),(75,"Steven Fisk"),(76,"Keith Mitchell"),
(77,"Rasmus Neergaard-Petersen"),(78,"Max Homa"),(79,"Rasmus Hojgaard"),(80,"Matt McCarty"),
(81,"Eric Cole"),(82,"David Puig"),(83,"Ricky Castillo"),(84,"Benjamin James"),
(85,"Sami Valimaki"),(86,"Andrew Novak"),(87,"Sandy Scott"),(88,"Nick Taylor"),
(89,"Thomas Detry"),(90,"Sahith Theegala"),(91,"McClure Meissner"),(92,"Matti Schmid"),
(93,"Ben Kohles"),(94,"Aldrich Potgieter"),(95,"Max Greyserman"),(96,"Jackson Suber"),
(97,"Jayden Schaper"),(98,"Beau Hossler"),(99,"Keita Nakajima"),(100,"Jacob Skov Olesen"),
]

MAJORS = {
    "masters": "Masters Tournament",
    "pga": "PGA Championship",
    "us_open": "U.S. Open",
    "open": "The Open Championship",
}

ALIASES = {
    "nico echavarria": "Nicolas Echavarria",
    "sam stevens": "Samuel Stevens",
    "matthias schmid": "Matti Schmid",
    "rasmus neergaard petersen": "Rasmus Neergaard-Petersen",
    "michael thorbjornsen": "Michael Thorbjornsen",
}

SPECIAL = str.maketrans({
    "ø": "o", "Ø": "O", "æ": "ae", "Æ": "AE", "å": "a", "Å": "A",
    "ð": "d", "Ð": "D", "þ": "th", "Þ": "Th", "ł": "l", "Ł": "L",
})

def normalize(value):
    value = (value or "").translate(SPECIAL)
    value = unicodedata.normalize("NFKD", value)
    value = "".join(ch for ch in value if not unicodedata.combining(ch))
    value = value.lower()
    return re.sub(r"[^a-z0-9]+", " ", value).strip()

DISPLAY_BY_NORM = {normalize(name): name for _, name in TOP_100}
for alias, canonical in ALIASES.items():
    DISPLAY_BY_NORM[normalize(alias)] = canonical

def canonical_player(value):
    return DISPLAY_BY_NORM.get(normalize(value))

def major_key(name):
    n = normalize(name)
    if "masters tournament" in n or n == "masters":
        return "masters"
    if "pga championship" in n:
        return "pga"
    if "u s open" in n or n == "us open":
        return "us_open"
    if "open championship" in n and "women" not in n:
        return "open"
    return None

def numeric_position(value):
    if value is None:
        return None
    m = re.search(r"\d+", str(value))
    return int(m.group()) if m else None

def points_for(position, rounds):
    # User rule: > 2 rounds means made cut; <= 2 rounds means missed cut.
    if rounds <= 2:
        return 0
    p = numeric_position(position)
    if p is None:
        return 15
    if p == 1: return 250
    if p == 2: return 200
    if p == 3: return 175
    if 4 <= p <= 5: return 150
    if 6 <= p <= 10: return 125
    if 11 <= p <= 20: return 90
    if 21 <= p <= 30: return 60
    if 31 <= p <= 50: return 35
    return 15

def download(url, dest):
    if dest.exists() and dest.stat().st_size > 1000:
        return
    print(f"Downloading {url}")
    urllib.request.urlretrieve(url, dest)

def sql_quote(s):
    return "'" + s.replace("'", "''") + "'"

def slug(s):
    return re.sub(r"[^a-z0-9]+", "-", normalize(s)).strip("-")

def main():
    cache = Path(".cache/golf")
    cache.mkdir(parents=True, exist_ok=True)
    lb_path = cache / "leaderboards_2026.csv"
    holes_path = cache / "holes_2026.csv"
    download(LEADERBOARD_URL, lb_path)
    download(HOLES_URL, holes_path)

    rounds = defaultdict(set)
    found_major_names = defaultdict(set)
    with holes_path.open(newline="", encoding="utf-8-sig") as f:
        reader = csv.DictReader(f)
        for row in reader:
            mk = major_key(row.get("tournament_name"))
            if not mk:
                continue
            found_major_names[mk].add(row.get("tournament_name"))
            player = canonical_player(row.get("player_name"))
            if not player:
                continue
            try:
                rnd = int(float(row.get("round") or 0))
            except ValueError:
                continue
            if 1 <= rnd <= 4:
                rounds[(player, mk)].add(rnd)

    positions = {}
    with lb_path.open(newline="", encoding="utf-8-sig") as f:
        reader = csv.DictReader(f)
        for row in reader:
            mk = major_key(row.get("tournament_name"))
            if not mk:
                continue
            player = canonical_player(row.get("player_name"))
            if not player:
                continue
            positions[(player, mk)] = row.get("position")

    report = []
    for owgr, player in TOP_100:
        majors = {}
        total = 0
        for mk, label in MAJORS.items():
            played_rounds = sorted(rounds.get((player, mk), set()))
            position = positions.get((player, mk))
            pts = points_for(position, len(played_rounds)) if played_rounds else 0
            total += pts
            majors[mk] = {
                "name": label,
                "position": position,
                "rounds_played": len(played_rounds),
                "rounds": played_rounds,
                "made_cut": len(played_rounds) > 2,
                "points": pts,
            }
        report.append({
            "owgr_rank": owgr,
            "player": player,
            "points": total,
            "majors": majors,
        })

    ranked = sorted(report, key=lambda r: (-r["points"], r["player"]))
    for index, row in enumerate(ranked, start=1):
        row["sport_rank"] = index

    asset_values = []
    stat_values = []
    for row in report:
        player = row["player"]
        asset_values.append(
            f"('Golf',{sql_quote(slug(player))},{sql_quote(player)},'GOLFER',true,"
            f"jsonb_build_object('ranking_snapshot',{sql_quote(RANKING_SNAPSHOT)},'owgr_rank',{row['owgr_rank']}))"
        )
        breakdown_pairs = [
            "'owgr_rank'", str(row["owgr_rank"]),
        ]
        for mk in MAJORS:
            m = row["majors"][mk]
            breakdown_pairs.extend([
                sql_quote(mk + "_position"), "null" if m["position"] is None else sql_quote(str(m["position"])),
                sql_quote(mk + "_rounds"), str(m["rounds_played"]),
                sql_quote(mk + "_made_cut"), "true" if m["made_cut"] else "false",
                sql_quote(mk + "_points"), str(m["points"]),
            ])
        breakdown = "jsonb_build_object(" + ",".join(breakdown_pairs) + ")"
        stat_values.append(
            f"((select id from public.assets where sport='Golf' and external_key={sql_quote(slug(player))}),"
            f"'2026','v1.2',{row['points']},{row['sport_rank']},{sql_quote(RESULT_SOURCE)},{breakdown})"
        )

    sql = f"""-- 031_golf_top100_and_2026_major_history.sql
-- Generated from OWGR Top 100 snapshot (2026-10-04) and 2026 major results.
-- Cut rule: >2 rounds played = made cut; <=2 rounds = missed cut.

update public.assets set active=false where sport='Golf';

insert into public.assets(sport,external_key,name,asset_type,active,metadata)
values
{",\n".join(asset_values)}
on conflict (sport,external_key) do update
set name=excluded.name,asset_type='GOLFER',active=true,metadata=excluded.metadata;

insert into public.competition_editions(sport,label,status,source_ref,starts_on,ends_on)
values(
  'Golf','2026-27','ACTIVE',{sql_quote(RANKING_SOURCE)},'2026-10-04','2027-09-30'
)
on conflict (sport,label) do update
set status='ACTIVE',source_ref=excluded.source_ref,starts_on=excluded.starts_on,ends_on=excluded.ends_on;

insert into public.competition_entries(edition_id,asset_id,draftable,entry_status,source_ref)
select e.id,a.id,true,'CONFIRMED',e.source_ref
from public.competition_editions e
join public.assets a on a.sport='Golf' and a.active=true
where e.sport='Golf' and e.label='2026-27'
on conflict (edition_id,asset_id) do update
set draftable=true,entry_status='CONFIRMED',source_ref=excluded.source_ref;

insert into public.asset_season_stats(
  asset_id,season_label,scoring_version,points,rank,source_ref,breakdown
)
values
{",\n".join(stat_values)}
on conflict (asset_id,season_label,scoring_version) do update
set points=excluded.points,rank=excluded.rank,source_ref=excluded.source_ref,
    breakdown=excluded.breakdown,updated_at=now();
"""

    out_sql = Path("db/migrations/031_golf_top100_and_2026_major_history.sql")
    out_report = Path("docs/GOLF_2026_IMPORT_REPORT.json")
    out_sql.write_text(sql, encoding="utf-8")
    out_report.write_text(json.dumps({
        "ranking_snapshot": RANKING_SNAPSHOT,
        "ranking_source": RANKING_SOURCE,
        "results_source": RESULT_SOURCE,
        "cut_rule": ">2 rounds = made cut; <=2 rounds = missed cut",
        "detected_tournament_names": {k: sorted(v) for k, v in found_major_names.items()},
        "golfers": ranked,
    }, indent=2), encoding="utf-8")

    print("Detected majors:", {k: sorted(v) for k, v in found_major_names.items()})
    print("Generated", out_sql, "and", out_report)
    print("Top historical scores:")
    for row in ranked[:10]:
        print(row["sport_rank"], row["player"], row["points"])

if __name__ == "__main__":
    main()
