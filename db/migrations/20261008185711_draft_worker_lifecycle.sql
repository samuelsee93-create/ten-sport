-- Keep the one-second worker asleep outside live drafts to avoid idle job/log growth.
create or replace function private.set_draft_worker_activity()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_job bigint; v_live boolean;
begin
  select jobid into v_job from cron.job where jobname='ten-sport-draft-timeouts';
  select exists(select 1 from public.drafts where status='LIVE') into v_live;
  if v_job is not null then perform cron.alter_job(v_job,active:=v_live); end if;
  return null;
end;
$$;
revoke all on function private.set_draft_worker_activity() from public,anon,authenticated;
create trigger draft_worker_after_status after insert or update of status or delete on public.drafts
for each statement execute function private.set_draft_worker_activity();
select cron.alter_job(jobid,active:=exists(select 1 from public.drafts where status='LIVE'))
from cron.job where jobname='ten-sport-draft-timeouts';

-- Do not reopen a completed draft or move a running draft back into its lobby.
create or replace function private.guard_draft_lifecycle()
returns trigger language plpgsql set search_path = '' as $$
begin
  if old.status='COMPLETE' and new.status<>'COMPLETE' then raise exception 'Draft is complete'; end if;
  if old.status in ('LIVE','PAUSED') and new.status in ('LOBBY','SCHEDULED') then
    raise exception 'A running draft can only be paused, resumed or completed';
  end if;
  return new;
end;
$$;
revoke all on function private.guard_draft_lifecycle() from public,anon,authenticated;
create trigger draft_lifecycle_before_status before update of status on public.drafts
for each row execute function private.guard_draft_lifecycle();
