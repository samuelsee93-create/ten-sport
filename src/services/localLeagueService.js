import { createSeedState } from '../domain/seed.js';
import { ACTIVE_SLOTS, KEEPER_SLOTS, LINEUP_STATUS, ROSTER_SIZE, TRADE_STATUS, DRAFT_STATUS } from '../domain/constants.js';
import { activeSlotCount, draftOrder, rosterForTeam } from '../domain/selectors.js';
import { tradeError, rosterMoveError } from '../domain/transactions.js';
import { draftEligibility, rankedAssets, remainingPickSeconds } from '../domain/draft.js';

const STORAGE_KEY='ten-sport-v0.3';
const clone=(v)=>structuredClone(v);
const now=()=>new Date().toISOString();

export class LocalLeagueService {
  constructor(){this.listeners=new Set();this.state=this.load();}
  load(){try{const raw=localStorage.getItem(STORAGE_KEY);if(!raw)return createSeedState();const parsed=JSON.parse(raw);return parsed.version===3?parsed:createSeedState();}catch{return createSeedState();}}
  persist(){this.state.keeperDesignations=(this.state.keeperDesignations??[]).filter(k=>this.state.rosterMemberships.some(m=>m.teamId===k.teamId&&m.assetId===k.assetId));localStorage.setItem(STORAGE_KEY,JSON.stringify(this.state));this.listeners.forEach(fn=>fn(this.getState()));}
  getState(){return clone(this.state);}
  subscribe(fn){this.listeners.add(fn);return()=>this.listeners.delete(fn);}
  reset(){this.state=createSeedState();this.persist();}
  mutate(type,detail,fn){const next=clone(this.state);fn(next);next.transactionLog.unshift({id:crypto.randomUUID(),type,detail,createdAt:now()});this.state=next;this.persist();return this.getState();}
  renameLeague(name){const clean=name.trim();if(!clean)throw new Error('League name cannot be empty.');return this.mutate('LEAGUE_RENAMED',{name:clean},s=>{s.league.name=clean;});}
  renameTeam(teamId,name){const clean=name.trim();if(!clean)throw new Error('Team name cannot be empty.');return this.mutate('TEAM_RENAMED',{teamId,name:clean},s=>{const t=s.teams.find(x=>x.id===teamId);if(!t)throw new Error('Team not found.');t.name=clean;});}
  setTeamLogoUrl(teamId,logoUrl){const clean=logoUrl.trim();return this.mutate('TEAM_LOGO_CHANGED',{teamId,logoUrl:clean||null},s=>{const t=s.teams.find(x=>x.id===teamId);if(!t)throw new Error('Team not found.');t.logoUrl=clean||null;});}
  setLineupStatus(teamId,assetId,status){return this.mutate('LINEUP_CHANGED',{teamId,assetId,status},s=>{if(s.lockedAssetIds.includes(assetId))throw new Error('This asset is locked for its current scoring event.');const m=s.rosterMemberships.find(x=>x.teamId===teamId&&x.assetId===assetId);if(!m)throw new Error('Asset is not on this roster.');if(status===LINEUP_STATUS.ACTIVE&&m.lineupStatus!==LINEUP_STATUS.ACTIVE&&activeSlotCount(s,teamId)>=ACTIVE_SLOTS)throw new Error(`You can only have ${ACTIVE_SLOTS} active assets.`);m.lineupStatus=status;});}
  toggleKeeper(teamId,assetId){return this.mutate('KEEPER_CHANGED',{teamId,assetId},s=>{
    if(teamId!==s.currentTeamId)throw new Error('Not authorized for this team');
    if(s.keeperPlan?.closed || (s.keeperPlan?.deadline && Date.now()>=new Date(s.keeperPlan.deadline).getTime()))throw new Error('Keeper deadline has passed');
    if(!s.rosterMemberships.some(m=>m.teamId===teamId&&m.assetId===assetId))throw new Error('Keeper must be on your roster');
    s.keeperDesignations??=[];
    const idx=s.keeperDesignations.findIndex(k=>k.teamId===teamId&&k.assetId===assetId);
    if(idx>=0){s.keeperDesignations.splice(idx,1);return;}
    if(s.keeperDesignations.filter(k=>k.teamId===teamId).length>=(s.league.keeperSlots??3))throw new Error('Keeper limit reached');
    s.keeperDesignations.push({id:crypto.randomUUID(),teamId,assetId});
  });}

  acceptTrade(tradeId){return this.mutate('TRADE_ACCEPTED',{tradeId},s=>{const trade=s.trades.find(t=>t.id===tradeId);if(!trade||trade.status!==TRADE_STATUS.PENDING)throw new Error('Trade is no longer available.');if(trade.toTeamId!==s.currentTeamId)throw new Error('Only the recipient can accept this trade.');const reason=tradeError(s,trade.fromTeamId,trade.toTeamId,trade.items);if(reason)throw new Error(reason);const moveAsset=(assetId,from,to)=>{const m=s.rosterMemberships.find(x=>x.teamId===from&&x.assetId===assetId);if(!m)throw new Error('Trade validation failed: asset ownership changed.');m.teamId=to;m.lineupStatus=LINEUP_STATUS.BENCH;m.acquiredAt=now();s.keeperSelections=s.keeperSelections.filter(k=>k.assetId!==assetId);};const fromAssets=trade.items.filter(i=>i.side==='FROM'&&i.type==='ASSET');const toAssets=trade.items.filter(i=>i.side==='TO'&&i.type==='ASSET');const fromCount=rosterForTeam(s,trade.fromTeamId).length-fromAssets.length+toAssets.length;const toCount=rosterForTeam(s,trade.toTeamId).length-toAssets.length+fromAssets.length;if(fromCount>ROSTER_SIZE||toCount>ROSTER_SIZE)throw new Error('Trade would create an illegal roster size.');fromAssets.forEach(i=>moveAsset(i.assetId,trade.fromTeamId,trade.toTeamId));toAssets.forEach(i=>moveAsset(i.assetId,trade.toTeamId,trade.fromTeamId));const fillActive=(teamId,preferred)=>{let needed=Math.min(ACTIVE_SLOTS,rosterForTeam(s,teamId).length)-activeSlotCount(s,teamId);const ids=[...preferred,...rosterForTeam(s,teamId).filter(m=>m.lineupStatus===LINEUP_STATUS.BENCH).map(m=>m.assetId)];for(const id of ids){if(needed<=0)break;const m=s.rosterMemberships.find(x=>x.teamId===teamId&&x.assetId===id);if(m&&m.lineupStatus===LINEUP_STATUS.BENCH){m.lineupStatus=LINEUP_STATUS.ACTIVE;needed-=1;}}};fillActive(trade.toTeamId,fromAssets.map(i=>i.assetId));fillActive(trade.fromTeamId,toAssets.map(i=>i.assetId));trade.items.filter(i=>i.type==='DRAFT_PICK').forEach(i=>{const p=s.draftPicks.find(x=>x.id===i.draftPickId);if(!p)throw new Error('Draft pick not found.');const expected=i.side==='FROM'?trade.fromTeamId:trade.toTeamId;const destination=i.side==='FROM'?trade.toTeamId:trade.fromTeamId;if(p.currentTeamId!==expected)throw new Error('Trade validation failed: draft pick ownership changed.');p.currentTeamId=destination;});trade.status=TRADE_STATUS.ACCEPTED;trade.acceptedAt=now();trade.resolvedAt=now();});}
  declineTrade(tradeId){return this.mutate('TRADE_DECLINED',{tradeId},s=>{const t=s.trades.find(x=>x.id===tradeId);if(!t||t.status!==TRADE_STATUS.PENDING)throw new Error('Trade is no longer available.');if(t.toTeamId!==s.currentTeamId)throw new Error('Only the recipient can decline this trade.');t.status=TRADE_STATUS.DECLINED;t.resolvedAt=now();});}
  prepareTradeBuilder(){return this.getState();}
  proposeTrade(toTeamId,items,counterOfTradeId=null){
    const id=crypto.randomUUID();
    this.mutate('TRADE_PROPOSED',{id,toTeamId},s=>{
      const old=counterOfTradeId?s.trades.find(t=>t.id===counterOfTradeId):null;
      if(counterOfTradeId&&(!old||old.status!=='PENDING'||old.toTeamId!==s.currentTeamId||old.fromTeamId!==toTeamId))throw new Error('Only the recipient can counter a pending trade.');
      const reason=tradeError(s,s.currentTeamId,toTeamId,items);if(reason)throw new Error(reason);
      if(old){old.status='COUNTERED';old.resolvedAt=now();}
      s.trades.unshift({id,fromTeamId:s.currentTeamId,toTeamId,status:'PENDING',items:clone(items),createdAt:now(),counterOfTradeId});
    });
    return id;
  }
  claimWaiverAsset(assetId,dropAssetId=null){return this.mutate('WAIVER_CLAIMED',{assetId,dropAssetId},s=>{
    const teamId=s.currentTeamId;
    if(!teamId)throw new Error('No team is assigned.');
    if(['LIVE','PAUSED'].includes(s.draft?.status))throw new Error('Pool additions are available after the draft finishes.');
    if(!s.assets.some(a=>a.id===assetId))throw new Error('Asset is unavailable.');
    if(s.rosterMemberships.some(m=>m.assetId===assetId))throw new Error('Asset has already been claimed.');
    if(s.lockedAssetIds.includes(assetId)||s.lockedAssetIds.includes(dropAssetId))throw new Error('This asset is currently locked.');
    const drop=dropAssetId?s.rosterMemberships.find(m=>m.teamId===teamId&&m.assetId===dropAssetId):null;
    if(dropAssetId&&!drop)throw new Error('Drop asset is not on your roster.');
    const reason=rosterMoveError(s,teamId,dropAssetId?[dropAssetId]:[],[assetId]);if(reason)throw new Error(reason);
    const status=drop?.lineupStatus??(activeSlotCount(s,teamId)<(s.league.activeSlots??15)?'ACTIVE':'BENCH');
    s.rosterMemberships=s.rosterMemberships.filter(m=>m!==drop);
    s.keeperSelections=s.keeperSelections.filter(k=>!(k.teamId===teamId&&k.assetId===dropAssetId));
    s.rosterMemberships.push({id:crypto.randomUUID(),teamId,assetId,lineupStatus:status,acquiredAt:now()});
    s.waiverTransactions??=[];
    s.waiverTransactions.unshift({id:crypto.randomUUID(),teamId,addedAssetId:assetId,droppedAssetId:dropAssetId,transactionType:'WAIVER',createdAt:now()});
  });}
  setDraftFavorite(assetId,starred){return this.mutate('DRAFT_FAVORITE_CHANGED',{assetId,starred},s=>{s.draft.preferences??=[];let p=s.draft.preferences.find(x=>x.assetId===assetId);if(!p){p={id:crypto.randomUUID(),assetId,starred:false,queuePosition:null,updatedAt:now()};s.draft.preferences.push(p);}p.starred=starred;p.updatedAt=now();});}
  toggleDraftQueue(assetId){return this.mutate('DRAFT_QUEUE_CHANGED',{assetId},s=>{s.draft.preferences??=[];let p=s.draft.preferences.find(x=>x.assetId===assetId);if(!p){p={id:crypto.randomUUID(),assetId,starred:false,queuePosition:null,updatedAt:now()};s.draft.preferences.push(p);}if(p.queuePosition!=null){p.queuePosition=null;}else{const max=Math.max(0,...s.draft.preferences.map(x=>x.queuePosition??0));p.queuePosition=max+1;}p.updatedAt=now();});}
  moveDraftQueue(assetId,direction){return this.mutate('DRAFT_QUEUE_MOVED',{assetId,direction},s=>{s.draft.preferences??=[];const q=s.draft.preferences.filter(x=>x.queuePosition!=null).sort((a,b)=>a.queuePosition-b.queuePosition);const i=q.findIndex(x=>x.assetId===assetId);const j=i+direction;if(i<0||j<0||j>=q.length)return;const a=q[i],b=q[j],tmp=a.queuePosition;a.queuePosition=b.queuePosition;b.queuePosition=tmp;a.updatedAt=now();b.updatedAt=now();});}
  swapLineupAssets(teamId,activeAssetId,benchAssetId){return this.mutate('LINEUP_SWAPPED',{teamId,activeAssetId,benchAssetId},s=>{
    const active=s.rosterMemberships.find(row=>row.teamId===teamId&&row.assetId===activeAssetId&&row.lineupStatus===LINEUP_STATUS.ACTIVE);
    const bench=s.rosterMemberships.find(row=>row.teamId===teamId&&row.assetId===benchAssetId&&row.lineupStatus===LINEUP_STATUS.BENCH);
    if(!active||!bench)throw new Error('Choose one active asset and one bench asset.');
    if(s.lockedAssetIds.includes(activeAssetId)||s.lockedAssetIds.includes(benchAssetId))throw new Error('This asset is locked for its current scoring event.');
    active.lineupStatus=LINEUP_STATUS.BENCH;bench.lineupStatus=LINEUP_STATUS.ACTIVE;
  });}
  setDraftTimer(seconds){return this.mutate('DRAFT_TIMER_CHANGED',{seconds},s=>{
    if(s.currentRole!=='COMMISSIONER')throw new Error('Commissioner permission required');
    if(!Number.isInteger(seconds)||seconds<10||seconds>600)throw new Error('Pick timer must be between 10 and 600 seconds');
    if(s.draft.status===DRAFT_STATUS.COMPLETE)throw new Error('Draft is complete');
    s.draft.pickTimerSeconds=seconds;
    if(s.draft.status===DRAFT_STATUS.LIVE)s.draft.pickDeadlineAt=new Date(Date.now()+seconds*1000).toISOString();
    if(s.draft.status===DRAFT_STATUS.PAUSED)s.draft.pausedSeconds=seconds;
  });}
  setDraftStatus(status){return this.mutate('DRAFT_STATUS_CHANGED',{status},s=>{
    if(s.currentRole!=='COMMISSIONER')throw new Error('Commissioner permission required');
    const old=s.draft.status;
    if(status===DRAFT_STATUS.PAUSED){s.draft.pausedSeconds=remainingPickSeconds(s.draft);s.draft.pickDeadlineAt=null;}
    if(status===DRAFT_STATUS.LIVE&&old!==DRAFT_STATUS.LIVE)s.draft.pickDeadlineAt=new Date(Date.now()+(old===DRAFT_STATUS.PAUSED?(s.draft.pausedSeconds??s.draft.pickTimerSeconds):s.draft.pickTimerSeconds)*1000).toISOString();
    s.draft.status=status;
  });}
  syncDraftClock(){
    const s=this.state;
    if(s.draft.status!==DRAFT_STATUS.LIVE||remainingPickSeconds(s.draft)!==0)return this.getState();
    const slot=draftOrder(s)[s.draft.currentOverallPick-1];
    if(!slot)return this.getState();
    const teamId=slot.currentTeamId;
    const queued=teamId===s.currentTeamId?(s.draft.preferences??[]).filter(row=>row.queuePosition!=null).sort((a,b)=>a.queuePosition-b.queuePosition).map(row=>s.assets.find(a=>a.id===row.assetId)):[];
    const asset=[...queued,...rankedAssets(s)].find(a=>!draftEligibility(s,teamId,a));
    if(!asset)return this.mutate('DRAFT_AUTO_PICK_BLOCKED',{},next=>{next.draft.status=DRAFT_STATUS.PAUSED;});
    return this.makeDraftPick(asset.id,true);
  }
  makeDraftPick(assetId,auto=false){return this.mutate('DRAFT_PICK_MADE',{assetId,auto},s=>{
    if(s.draft.status!==DRAFT_STATUS.LIVE)throw new Error('Draft is not live.');
    const order=draftOrder(s),slot=order[s.draft.currentOverallPick-1];
    if(!slot)throw new Error('Draft is complete.');
    if(!auto&&slot.currentTeamId!==s.currentTeamId)throw new Error('You are not on the clock');
    if(!auto&&remainingPickSeconds(s.draft)===0)throw new Error('Pick timer has expired');
    const reason=draftEligibility(s,slot.currentTeamId,s.assets.find(a=>a.id===assetId));
    if(reason)throw new Error(reason);
    s.draft.selections.push({id:crypto.randomUUID(),overallPick:s.draft.currentOverallPick,round:slot.round,teamId:slot.currentTeamId,assetId,draftPickId:slot.draftPickId,selectionType:'DRAFT',autoPicked:auto,createdAt:now()});
    s.rosterMemberships.push({id:crypto.randomUUID(),teamId:slot.currentTeamId,assetId,lineupStatus:activeSlotCount(s,slot.currentTeamId)<ACTIVE_SLOTS?LINEUP_STATUS.ACTIVE:LINEUP_STATUS.BENCH,acquiredAt:now()});
    s.draft.currentOverallPick+=1;
    if(s.draft.currentOverallPick>order.length){s.draft.status=DRAFT_STATUS.COMPLETE;s.draft.pickDeadlineAt=null;}
    else s.draft.pickDeadlineAt=new Date(Date.now()+s.draft.pickTimerSeconds*1000).toISOString();
  });}
}
