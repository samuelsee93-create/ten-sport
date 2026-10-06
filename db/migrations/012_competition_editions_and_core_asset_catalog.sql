-- 012_competition_editions_and_core_asset_catalog.sql
alter table public.assets
  add column if not exists asset_type text not null default 'TEAM',
  add column if not exists metadata jsonb not null default '{}'::jsonb;
alter table public.assets drop constraint if exists assets_asset_type_check;
alter table public.assets add constraint assets_asset_type_check
  check (asset_type in ('TEAM','DRIVER','GOLFER','TENNIS_PLAYER','CONSTRUCTOR'));

create table if not exists public.competition_editions (
  id uuid primary key default gen_random_uuid(),
  sport text not null,
  label text not null,
  status text not null default 'UPCOMING' check (status in ('UPCOMING','ACTIVE','COMPLETE')),
  source_ref text,
  starts_on date,
  ends_on date,
  created_at timestamptz not null default now(),
  unique (sport,label)
);
create table if not exists public.competition_entries (
  edition_id uuid not null references public.competition_editions(id) on delete cascade,
  asset_id uuid not null references public.assets(id) on delete cascade,
  draftable boolean not null default true,
  entry_status text not null default 'CONFIRMED' check (entry_status in ('CONFIRMED','PROVISIONAL','HISTORICAL')),
  source_ref text,
  metadata jsonb not null default '{}'::jsonb,
  primary key (edition_id,asset_id)
);
create index if not exists competition_entries_asset_idx on public.competition_entries(asset_id);
create index if not exists competition_editions_sport_status_idx on public.competition_editions(sport,status);
alter table public.competition_editions enable row level security;
alter table public.competition_entries enable row level security;
revoke all on table public.competition_editions from anon;
revoke all on table public.competition_entries from anon;
revoke all on table public.competition_editions from authenticated;
revoke all on table public.competition_entries from authenticated;
grant select on table public.competition_editions to authenticated;
grant select on table public.competition_entries to authenticated;
drop policy if exists competition_editions_authenticated_read on public.competition_editions;
create policy competition_editions_authenticated_read on public.competition_editions for select to authenticated using (true);
drop policy if exists competition_entries_authenticated_read on public.competition_entries;
create policy competition_entries_authenticated_read on public.competition_entries for select to authenticated using (true);

insert into public.assets(sport,external_key,name,asset_type,active)
values
('NHL','anaheim-ducks','Anaheim Ducks','TEAM',true),
('NHL','boston-bruins','Boston Bruins','TEAM',true),
('NHL','buffalo-sabres','Buffalo Sabres','TEAM',true),
('NHL','calgary-flames','Calgary Flames','TEAM',true),
('NHL','carolina-hurricanes','Carolina Hurricanes','TEAM',true),
('NHL','chicago-blackhawks','Chicago Blackhawks','TEAM',true),
('NHL','colorado-avalanche','Colorado Avalanche','TEAM',true),
('NHL','columbus-blue-jackets','Columbus Blue Jackets','TEAM',true),
('NHL','dallas-stars','Dallas Stars','TEAM',true),
('NHL','detroit-red-wings','Detroit Red Wings','TEAM',true),
('NHL','edmonton-oilers','Edmonton Oilers','TEAM',true),
('NHL','florida-panthers','Florida Panthers','TEAM',true),
('NHL','los-angeles-kings','Los Angeles Kings','TEAM',true),
('NHL','minnesota-wild','Minnesota Wild','TEAM',true),
('NHL','montreal-canadiens','Montréal Canadiens','TEAM',true),
('NHL','nashville-predators','Nashville Predators','TEAM',true),
('NHL','new-jersey-devils','New Jersey Devils','TEAM',true),
('NHL','new-york-islanders','New York Islanders','TEAM',true),
('NHL','new-york-rangers','New York Rangers','TEAM',true),
('NHL','ottawa-senators','Ottawa Senators','TEAM',true),
('NHL','philadelphia-flyers','Philadelphia Flyers','TEAM',true),
('NHL','pittsburgh-penguins','Pittsburgh Penguins','TEAM',true),
('NHL','san-jose-sharks','San Jose Sharks','TEAM',true),
('NHL','seattle-kraken','Seattle Kraken','TEAM',true),
('NHL','st-louis-blues','St. Louis Blues','TEAM',true),
('NHL','tampa-bay-lightning','Tampa Bay Lightning','TEAM',true),
('NHL','toronto-maple-leafs','Toronto Maple Leafs','TEAM',true),
('NHL','utah-mammoth','Utah Mammoth','TEAM',true),
('NHL','vancouver-canucks','Vancouver Canucks','TEAM',true),
('NHL','vegas-golden-knights','Vegas Golden Knights','TEAM',true),
('NHL','washington-capitals','Washington Capitals','TEAM',true),
('NHL','winnipeg-jets','Winnipeg Jets','TEAM',true),
('NFL','arizona-cardinals','Arizona Cardinals','TEAM',true),
('NFL','atlanta-falcons','Atlanta Falcons','TEAM',true),
('NFL','baltimore-ravens','Baltimore Ravens','TEAM',true),
('NFL','buffalo-bills','Buffalo Bills','TEAM',true),
('NFL','carolina-panthers','Carolina Panthers','TEAM',true),
('NFL','chicago-bears','Chicago Bears','TEAM',true),
('NFL','cincinnati-bengals','Cincinnati Bengals','TEAM',true),
('NFL','cleveland-browns','Cleveland Browns','TEAM',true),
('NFL','dallas-cowboys','Dallas Cowboys','TEAM',true),
('NFL','denver-broncos','Denver Broncos','TEAM',true),
('NFL','detroit-lions','Detroit Lions','TEAM',true),
('NFL','green-bay-packers','Green Bay Packers','TEAM',true),
('NFL','houston-texans','Houston Texans','TEAM',true),
('NFL','indianapolis-colts','Indianapolis Colts','TEAM',true),
('NFL','jacksonville-jaguars','Jacksonville Jaguars','TEAM',true),
('NFL','kansas-city-chiefs','Kansas City Chiefs','TEAM',true),
('NFL','las-vegas-raiders','Las Vegas Raiders','TEAM',true),
('NFL','los-angeles-chargers','Los Angeles Chargers','TEAM',true),
('NFL','los-angeles-rams','Los Angeles Rams','TEAM',true),
('NFL','miami-dolphins','Miami Dolphins','TEAM',true),
('NFL','minnesota-vikings','Minnesota Vikings','TEAM',true),
('NFL','new-england-patriots','New England Patriots','TEAM',true),
('NFL','new-orleans-saints','New Orleans Saints','TEAM',true),
('NFL','new-york-giants','New York Giants','TEAM',true),
('NFL','new-york-jets','New York Jets','TEAM',true),
('NFL','philadelphia-eagles','Philadelphia Eagles','TEAM',true),
('NFL','pittsburgh-steelers','Pittsburgh Steelers','TEAM',true),
('NFL','san-francisco-49ers','San Francisco 49ers','TEAM',true),
('NFL','seattle-seahawks','Seattle Seahawks','TEAM',true),
('NFL','tampa-bay-buccaneers','Tampa Bay Buccaneers','TEAM',true),
('NFL','tennessee-titans','Tennessee Titans','TEAM',true),
('NFL','washington-commanders','Washington Commanders','TEAM',true),
('NBA','atlanta-hawks','Atlanta Hawks','TEAM',true),
('NBA','boston-celtics','Boston Celtics','TEAM',true),
('NBA','brooklyn-nets','Brooklyn Nets','TEAM',true),
('NBA','charlotte-hornets','Charlotte Hornets','TEAM',true),
('NBA','chicago-bulls','Chicago Bulls','TEAM',true),
('NBA','cleveland-cavaliers','Cleveland Cavaliers','TEAM',true),
('NBA','dallas-mavericks','Dallas Mavericks','TEAM',true),
('NBA','denver-nuggets','Denver Nuggets','TEAM',true),
('NBA','detroit-pistons','Detroit Pistons','TEAM',true),
('NBA','golden-state-warriors','Golden State Warriors','TEAM',true),
('NBA','houston-rockets','Houston Rockets','TEAM',true),
('NBA','indiana-pacers','Indiana Pacers','TEAM',true),
('NBA','la-clippers','LA Clippers','TEAM',true),
('NBA','los-angeles-lakers','Los Angeles Lakers','TEAM',true),
('NBA','memphis-grizzlies','Memphis Grizzlies','TEAM',true),
('NBA','miami-heat','Miami Heat','TEAM',true),
('NBA','milwaukee-bucks','Milwaukee Bucks','TEAM',true),
('NBA','minnesota-timberwolves','Minnesota Timberwolves','TEAM',true),
('NBA','new-orleans-pelicans','New Orleans Pelicans','TEAM',true),
('NBA','new-york-knicks','New York Knicks','TEAM',true),
('NBA','oklahoma-city-thunder','Oklahoma City Thunder','TEAM',true),
('NBA','orlando-magic','Orlando Magic','TEAM',true),
('NBA','philadelphia-76ers','Philadelphia 76ers','TEAM',true),
('NBA','phoenix-suns','Phoenix Suns','TEAM',true),
('NBA','portland-trail-blazers','Portland Trail Blazers','TEAM',true),
('NBA','sacramento-kings','Sacramento Kings','TEAM',true),
('NBA','san-antonio-spurs','San Antonio Spurs','TEAM',true),
('NBA','toronto-raptors','Toronto Raptors','TEAM',true),
('NBA','utah-jazz','Utah Jazz','TEAM',true),
('NBA','washington-wizards','Washington Wizards','TEAM',true),
('MLB','arizona-diamondbacks','Arizona Diamondbacks','TEAM',true),
('MLB','atlanta-braves','Atlanta Braves','TEAM',true),
('MLB','baltimore-orioles','Baltimore Orioles','TEAM',true),
('MLB','boston-red-sox','Boston Red Sox','TEAM',true),
('MLB','chicago-cubs','Chicago Cubs','TEAM',true),
('MLB','chicago-white-sox','Chicago White Sox','TEAM',true),
('MLB','cincinnati-reds','Cincinnati Reds','TEAM',true),
('MLB','cleveland-guardians','Cleveland Guardians','TEAM',true),
('MLB','colorado-rockies','Colorado Rockies','TEAM',true),
('MLB','detroit-tigers','Detroit Tigers','TEAM',true),
('MLB','houston-astros','Houston Astros','TEAM',true),
('MLB','kansas-city-royals','Kansas City Royals','TEAM',true),
('MLB','los-angeles-angels','Los Angeles Angels','TEAM',true),
('MLB','los-angeles-dodgers','Los Angeles Dodgers','TEAM',true),
('MLB','miami-marlins','Miami Marlins','TEAM',true),
('MLB','milwaukee-brewers','Milwaukee Brewers','TEAM',true),
('MLB','minnesota-twins','Minnesota Twins','TEAM',true),
('MLB','new-york-mets','New York Mets','TEAM',true),
('MLB','new-york-yankees','New York Yankees','TEAM',true),
('MLB','athletics','Athletics','TEAM',true),
('MLB','philadelphia-phillies','Philadelphia Phillies','TEAM',true),
('MLB','pittsburgh-pirates','Pittsburgh Pirates','TEAM',true),
('MLB','san-diego-padres','San Diego Padres','TEAM',true),
('MLB','san-francisco-giants','San Francisco Giants','TEAM',true),
('MLB','seattle-mariners','Seattle Mariners','TEAM',true),
('MLB','st-louis-cardinals','St. Louis Cardinals','TEAM',true),
('MLB','tampa-bay-rays','Tampa Bay Rays','TEAM',true),
('MLB','texas-rangers','Texas Rangers','TEAM',true),
('MLB','toronto-blue-jays','Toronto Blue Jays','TEAM',true),
('MLB','washington-nationals','Washington Nationals','TEAM',true),
('6 Nations','england','England','TEAM',true),
('6 Nations','france','France','TEAM',true),
('6 Nations','ireland','Ireland','TEAM',true),
('6 Nations','italy','Italy','TEAM',true),
('6 Nations','scotland','Scotland','TEAM',true),
('6 Nations','wales','Wales','TEAM',true),
('F1','lando-norris','Lando Norris','DRIVER',true),
('F1','oscar-piastri','Oscar Piastri','DRIVER',true),
('F1','george-russell','George Russell','DRIVER',true),
('F1','kimi-antonelli','Kimi Antonelli','DRIVER',true),
('F1','max-verstappen','Max Verstappen','DRIVER',true),
('F1','isack-hadjar','Isack Hadjar','DRIVER',true),
('F1','charles-leclerc','Charles Leclerc','DRIVER',true),
('F1','lewis-hamilton','Lewis Hamilton','DRIVER',true),
('F1','alex-albon','Alex Albon','DRIVER',true),
('F1','carlos-sainz','Carlos Sainz','DRIVER',true),
('F1','liam-lawson','Liam Lawson','DRIVER',true),
('F1','arvid-lindblad','Arvid Lindblad','DRIVER',true),
('F1','fernando-alonso','Fernando Alonso','DRIVER',true),
('F1','lance-stroll','Lance Stroll','DRIVER',true),
('F1','esteban-ocon','Esteban Ocon','DRIVER',true),
('F1','oliver-bearman','Oliver Bearman','DRIVER',true),
('F1','nico-hulkenberg','Nico Hülkenberg','DRIVER',true),
('F1','gabriel-bortoleto','Gabriel Bortoleto','DRIVER',true),
('F1','pierre-gasly','Pierre Gasly','DRIVER',true),
('F1','franco-colapinto','Franco Colapinto','DRIVER',true),
('F1','valtteri-bottas','Valtteri Bottas','DRIVER',true),
('F1','sergio-perez','Sergio Pérez','DRIVER',true),
('F1','yuki-tsunoda','Yuki Tsunoda','DRIVER',false),
('F1','jack-doohan','Jack Doohan','DRIVER',false),
('UCL','aek-athens','AEK Athens','TEAM',true),
('UCL','arsenal','Arsenal','TEAM',true),
('UCL','aston-villa','Aston Villa','TEAM',true),
('UCL','atletico-madrid','Atlético Madrid','TEAM',true),
('UCL','barcelona','Barcelona','TEAM',true),
('UCL','bayern-munich','Bayern Munich','TEAM',true),
('UCL','bod-glimt','Bodø/Glimt','TEAM',true),
('UCL','borussia-dortmund','Borussia Dortmund','TEAM',true),
('UCL','club-brugge','Club Brugge','TEAM',true),
('UCL','como','Como','TEAM',true),
('UCL','fenerbahce','Fenerbahçe','TEAM',true),
('UCL','feyenoord','Feyenoord','TEAM',true),
('UCL','galatasaray','Galatasaray','TEAM',true),
('UCL','inter-milan','Inter Milan','TEAM',true),
('UCL','lask','LASK','TEAM',true),
('UCL','rb-leipzig','RB Leipzig','TEAM',true),
('UCL','lens','Lens','TEAM',true),
('UCL','lille','Lille','TEAM',true),
('UCL','liverpool','Liverpool','TEAM',true),
('UCL','manchester-city','Manchester City','TEAM',true),
('UCL','manchester-united','Manchester United','TEAM',true),
('UCL','napoli','Napoli','TEAM',true),
('UCL','paris-saint-germain','Paris Saint-Germain','TEAM',true),
('UCL','porto','Porto','TEAM',true),
('UCL','psv-eindhoven','PSV Eindhoven','TEAM',true),
('UCL','real-betis','Real Betis','TEAM',true),
('UCL','real-madrid','Real Madrid','TEAM',true),
('UCL','roma','Roma','TEAM',true),
('UCL','sabah','Sabah','TEAM',true),
('UCL','shakhtar-donetsk','Shakhtar Donetsk','TEAM',true),
('UCL','slavia-prague','Slavia Prague','TEAM',true),
('UCL','slovan-bratislava','Slovan Bratislava','TEAM',true),
('UCL','sporting-cp','Sporting CP','TEAM',true),
('UCL','vfb-stuttgart','VfB Stuttgart','TEAM',true),
('UCL','viking','Viking','TEAM',true),
('UCL','villarreal','Villarreal','TEAM',true),
('UCL','ajax','Ajax','TEAM',false),
('UCL','atalanta','Atalanta','TEAM',false),
('UCL','athletic-club','Athletic Club','TEAM',false),
('UCL','benfica','Benfica','TEAM',false),
('UCL','chelsea','Chelsea','TEAM',false),
('UCL','copenhagen','Copenhagen','TEAM',false),
('UCL','eintracht-frankfurt','Eintracht Frankfurt','TEAM',false),
('UCL','juventus','Juventus','TEAM',false),
('UCL','kairat-almaty','Kairat Almaty','TEAM',false),
('UCL','bayer-leverkusen','Bayer Leverkusen','TEAM',false),
('UCL','marseille','Marseille','TEAM',false),
('UCL','monaco','Monaco','TEAM',false),
('UCL','newcastle-united','Newcastle United','TEAM',false),
('UCL','olympiacos','Olympiacos','TEAM',false),
('UCL','pafos','Pafos','TEAM',false),
('UCL','qarabag','Qarabağ','TEAM',false),
('UCL','tottenham-hotspur','Tottenham Hotspur','TEAM',false),
('UCL','union-saint-gilloise','Union Saint-Gilloise','TEAM',false)
on conflict (sport,external_key) do update
set name=excluded.name,asset_type=excluded.asset_type,active=excluded.active;

insert into public.competition_editions(sport,label,status,source_ref,starts_on,ends_on)
values
('NHL','2026-27','ACTIVE','https://www.nhl.com/info/teams/','2026-09-29','2027-06-30'),
('NFL','2026','ACTIVE','https://www.nfl.com/teams/','2026-09-01','2027-02-28'),
('NBA','2026-27','UPCOMING','https://www.nba.com/2026-27-season-preview','2026-10-01','2027-06-30'),
('MLB','2026','ACTIVE','https://www.mlb.com/','2026-03-01','2026-11-30'),
('F1','2026','ACTIVE','https://www.formula1.com/en/latest/article/who-are-the-2026-formula-1-drivers.3mVj9UTWK7Puz2QuScnzuz','2026-03-01','2026-12-31'),
('UCL','2026-27','ACTIVE','https://www.uefa.com/uefachampionsleague/news/02a8-2171a88881a0-c70193b972c6-1000--meet-the-2026-27-champions-league-league-phase-teams/','2026-09-08','2027-06-05'),
('6 Nations','2027','UPCOMING','https://www.sixnationsrugby.com/en/m6n/news/everything-you-need-to-know-about-the-2027-guinness-mens-six-nations','2027-02-05','2027-03-13'),
('F1','2025','COMPLETE','https://www.formula1.com/en/results/2025/drivers','2025-03-01','2025-12-31'),
('UCL','2025-26','COMPLETE','https://www.uefa.com/uefachampionsleague/news/029d-1ea2e7e3e5d8-c5227ee0ab3c-1000--meet-the-2025-26-champions-league-league-phase-teams/','2025-09-16','2026-05-30')
on conflict (sport,label) do update
set status=excluded.status,source_ref=excluded.source_ref,starts_on=excluded.starts_on,ends_on=excluded.ends_on;

insert into public.competition_entries(edition_id,asset_id,draftable,entry_status,source_ref)
select e.id,a.id,true,'CONFIRMED',e.source_ref
from public.competition_editions e join public.assets a on a.sport=e.sport and a.active=true
where (e.sport,e.label) in (('NHL','2026-27'),('NFL','2026'),('NBA','2026-27'),('MLB','2026'),('F1','2026'),('UCL','2026-27'),('6 Nations','2027'))
on conflict (edition_id,asset_id) do update set draftable=true,entry_status='CONFIRMED',source_ref=excluded.source_ref;

insert into public.competition_entries(edition_id,asset_id,draftable,entry_status,source_ref)
select e.id,a.id,false,'HISTORICAL',e.source_ref
from public.competition_editions e join public.assets a on a.sport='F1'
where e.sport='F1' and e.label='2025'
and a.external_key in ('lando-norris','oscar-piastri','george-russell','kimi-antonelli','max-verstappen','isack-hadjar','charles-leclerc','lewis-hamilton','alex-albon','carlos-sainz','liam-lawson','fernando-alonso','lance-stroll','esteban-ocon','oliver-bearman','nico-hulkenberg','gabriel-bortoleto','pierre-gasly','franco-colapinto','yuki-tsunoda','jack-doohan')
on conflict (edition_id,asset_id) do update set draftable=false,entry_status='HISTORICAL',source_ref=excluded.source_ref;

insert into public.competition_entries(edition_id,asset_id,draftable,entry_status,source_ref)
select e.id,a.id,false,'HISTORICAL',e.source_ref
from public.competition_editions e join public.assets a on a.sport='UCL'
where e.sport='UCL' and e.label='2025-26'
and a.external_key in ('arsenal','atletico-madrid','barcelona','bayern-munich','bod-glimt','borussia-dortmund','club-brugge','galatasaray','inter-milan','liverpool','manchester-city','napoli','paris-saint-germain','psv-eindhoven','real-madrid','slavia-prague','sporting-cp','villarreal','ajax','atalanta','athletic-club','benfica','chelsea','copenhagen','eintracht-frankfurt','juventus','kairat-almaty','bayer-leverkusen','marseille','monaco','newcastle-united','olympiacos','pafos','qarabag','tottenham-hotspur','union-saint-gilloise')
on conflict (edition_id,asset_id) do update set draftable=false,entry_status='HISTORICAL',source_ref=excluded.source_ref;
