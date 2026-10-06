import { LocalLeagueService } from './localLeagueService.js';

// The UI imports this interface, not localStorage directly. A future hosted
// implementation can replace LocalLeagueService while keeping the same calls.
export const leagueService = new LocalLeagueService();
