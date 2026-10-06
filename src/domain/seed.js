import { LINEUP_STATUS, TRADE_STATUS, DRAFT_STATUS } from './constants.js';

const samAssets = [
  ['Toronto Maple Leafs','NHL',487,487],['Philadelphia Eagles','NFL',532,532],['Lando Norris','F1',610,610],['Scottie Scheffler','Golf',775,775],['Oklahoma City Thunder','NBA',702,702],['Los Angeles Dodgers','MLB',566,566],['Paris Saint-Germain','UCL',644,644],['Florida Gators','NCAA',490,490],['France','6 Nations',520,520],['Jannik Sinner','Tennis',900,900],['Florida Panthers','NHL',401,401],['Buffalo Bills','NFL',455,455],['Max Verstappen','F1',598,598],['Rory McIlroy','Golf',510,510],['Boston Celtics','NBA',430,430],['New York Yankees','MLB',390,254],['Barcelona','UCL',477,310],['Duke','NCAA',365,238],['Ireland','6 Nations',420,273],['Carlos Alcaraz','Tennis',810,526],
];
const extraAssets = [
  ['Charles Leclerc','F1',544],['Connor McDavid','NHL',612],['Detroit Lions','NFL',501],['Ludvig Aberg','Golf',418],['New York Knicks','NBA',402],['Atlanta Braves','MLB',389],['Arsenal','UCL',458],['Houston','NCAA',472],['Scotland','6 Nations',355],['Aryna Sabalenka','Tennis',735],
];
const teams = [
  { id:'team-sam', name:'The Decathletes', managerName:'Sam', role:'COMMISSIONER' },
  { id:'team-akash', name:'Akash Attack', managerName:'Akash', role:'MANAGER' },
  { id:'team-tuch', name:'Tuch Aho in Seider', managerName:'Manager 3', role:'MANAGER' },
  { id:'team-sunday', name:'Sunday Scaries', managerName:'Manager 4', role:'MANAGER' },
];
const assets = [
  ...samAssets.map(([name,sport,seasonPoints,pointsForTeam],i)=>({id:`asset-${i+1}`,name,sport,seasonPoints,pointsForTeam})),
  ...extraAssets.map(([name,sport,seasonPoints],i)=>({id:`asset-extra-${i+1}`,name,sport,seasonPoints,pointsForTeam:0})),
];
const rosterMemberships = samAssets.map((_,i)=>({id:`rm-sam-${i+1}`,teamId:'team-sam',assetId:`asset-${i+1}`,lineupStatus:i<15?LINEUP_STATUS.ACTIVE:LINEUP_STATUS.BENCH,acquiredAt:'2026-08-20T19:00:00-04:00'}));
rosterMemberships.push({id:'rm-akash-leclerc',teamId:'team-akash',assetId:'asset-extra-1',lineupStatus:LINEUP_STATUS.ACTIVE,acquiredAt:'2026-08-20T19:00:00-04:00'});
const draftPicks=[];
for(let round=1;round<=17;round+=1){teams.forEach((team,slot)=>{const tradedToAkash=round===3&&team.id==='team-sam';draftPicks.push({id:`pick-2027-${round}-${slot+1}`,season:2027,round,slot:slot+1,originalTeamId:team.id,currentTeamId:tradedToAkash?'team-akash':team.id});});}
export function createSeedState(){return{
  version:3,currentUserId:'user-sam',currentTeamId:'team-sam',currentRole:'COMMISSIONER',currentUser:{id:'user-sam',displayName:'Sam',avatarUrl:null},
  league:{id:'league-ten-sport',name:'Ten Sport Fantasy League',season:'2026-27',scoringVersion:'v1.2',keeperDeadline:'2027-08-15T23:59:00-04:00',rosterSize:20,activeSlots:15,benchSlots:5,keeperSlots:3},
  teams,assets,rosterMemberships,
  keeperSelections:[{teamId:'team-sam',assetId:'asset-2'},{teamId:'team-sam',assetId:'asset-4'}],
  draftPicks,
  trades:[{id:'trade-1',fromTeamId:'team-akash',toTeamId:'team-sam',status:TRADE_STATUS.PENDING,createdAt:'2026-10-06T09:20:00-04:00',items:[{side:'FROM',type:'ASSET',assetId:'asset-extra-1'},{side:'FROM',type:'DRAFT_PICK',draftPickId:'pick-2027-3-1'},{side:'TO',type:'ASSET',assetId:'asset-13'}]}],
  draft:{id:'draft-2027',season:2027,scheduledAt:'2027-08-22T19:30:00-04:00',pickTimerSeconds:90,status:DRAFT_STATUS.SCHEDULED,currentOverallPick:1,rounds:17,selections:[]},
  lockedAssetIds:[],transactionLog:[],
};}
