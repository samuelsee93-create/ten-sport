import { ACTIVE_SLOTS, LINEUP_STATUS } from './constants.js';
export const teamById=(s,id)=>s.teams.find(t=>t.id===id);
export const assetById=(s,id)=>s.assets.find(a=>a.id===id);
export function rosterForTeam(s,teamId){return s.rosterMemberships.filter(m=>m.teamId===teamId).map(m=>({...m,asset:assetById(s,m.assetId)}));}
export const activeRosterForTeam=(s,id)=>rosterForTeam(s,id).filter(m=>m.lineupStatus===LINEUP_STATUS.ACTIVE);
export const benchRosterForTeam=(s,id)=>rosterForTeam(s,id).filter(m=>m.lineupStatus===LINEUP_STATUS.BENCH);
export const pointsForTeam=(s,id)=>rosterForTeam(s,id).reduce((n,m)=>n+(m.asset?.pointsForTeam??0),0);
export const ownedDraftPicks=(s,id)=>s.draftPicks.filter(p=>p.currentTeamId===id);
export const keeperIdsForTeam=(s,id)=>s.keeperSelections.filter(k=>k.teamId===id).map(k=>k.assetId);
export function tradeItemsForSide(s,trade,side){return trade.items.filter(i=>i.side===side).map(i=>{if(i.type==='ASSET')return{...i,label:assetById(s,i.assetId)?.name??'Unknown asset'};const p=s.draftPicks.find(x=>x.id===i.draftPickId);const o=p?teamById(s,p.originalTeamId):null;return{...i,label:p?`${p.season} Round ${p.round} · Originally ${o?.managerName??o?.name??'Unknown'}`:'Unknown draft pick'};});}
export function draftOrder(s){const rows=[];for(let round=1;round<=s.draft.rounds;round+=1){const ordered=round%2===0?[...s.teams].reverse():s.teams;ordered.forEach((team,index)=>{const pick=s.draftPicks.find(p=>p.round===round&&p.originalTeamId===team.id);rows.push({overall:rows.length+1,round,slot:index+1,originalTeamId:team.id,currentTeamId:pick?.currentTeamId??team.id,draftPickId:pick?.id??null});});}return rows;}
export const activeSlotCount=(s,id)=>activeRosterForTeam(s,id).length;
export const canActivate=(s,id)=>activeSlotCount(s,id)<ACTIVE_SLOTS;
