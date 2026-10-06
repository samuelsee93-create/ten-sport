import { LocalLeagueService } from './localLeagueService.js';
import { SupabaseLeagueService } from './supabaseLeagueService.js';
import { supabaseConfigured } from './supabaseClient.js';

export const hostedBackendEnabled = supabaseConfigured;
export const leagueService = hostedBackendEnabled
  ? new SupabaseLeagueService()
  : new LocalLeagueService();
