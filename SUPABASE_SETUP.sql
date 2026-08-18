-- ALAE SHOP SECURE BACKEND v1
-- Keep new profiles tied to the Auth user and optional referral code.
create or replace function public.handle_new_user() returns trigger language plpgsql security definer set search_path=public as $$
begin
  insert into public.profiles(id,username,full_name,referred_by) values(NEW.id,NEW.raw_user_meta_data->>'username',NEW.raw_user_meta_data->>'full_name',nullif(NEW.raw_user_meta_data->>'referred_by','')::uuid) on conflict(id) do update set username=coalesce(excluded.username,profiles.username),full_name=coalesce(excluded.full_name,profiles.full_name),referred_by=coalesce(excluded.referred_by,profiles.referred_by);
  return NEW;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users for each row execute function public.handle_new_user();

-- Run this ONCE in Supabase SQL Editor, then put your browser-safe Publishable/Anon key in supabase-config.js.

create extension if not exists pgcrypto;

alter table public.profiles add column if not exists referred_by uuid references auth.users(id) on delete set null;
alter table public.profiles add column if not exists last_wheel_at timestamptz;

create table if not exists public.app_tasks(
 id uuid primary key default gen_random_uuid(), task_key text unique not null, title text not null, points integer not null check(points>=0), active boolean not null default true, min_seconds integer not null default 10
);
create table if not exists public.task_attempts(
 id uuid primary key default gen_random_uuid(), user_id uuid not null references auth.users(id) on delete cascade, task_key text not null references public.app_tasks(task_key) on delete cascade, started_at timestamptz not null default now(), completed_at timestamptz, unique(user_id,task_key)
);
create table if not exists public.daily_task_claims(
 id uuid primary key default gen_random_uuid(), user_id uuid not null references auth.users(id) on delete cascade, task_key text not null, claim_date date not null default current_date, points integer not null, created_at timestamptz not null default now(), unique(user_id,task_key,claim_date)
);

insert into public.app_tasks(task_key,title,points,min_seconds) values
('daily-login','Visit the site',5,0),('daily-wheel','Complete the wheel',5,0),('daily-game','Watch an ad',20,0),('daily-instagram','Instagram',15,12),('daily-whatsapp','WhatsApp',10,10),('daily-share','Share',15,8),('special-invite','Invite a friend',25,20),('special-five','5 tasks',30,20),('special-seven','7 tasks',50,20),('special-shop','Visit shop',100,20)
on conflict(task_key) do update set points=excluded.points,min_seconds=excluded.min_seconds,active=true;

grant select on public.app_tasks,public.task_attempts,public.daily_task_claims to authenticated;
grant select on public.profiles,public.points_history,public.redemptions,public.rewards,public.tasks to authenticated;

alter table public.app_tasks enable row level security;
alter table public.task_attempts enable row level security;
alter table public.daily_task_claims enable row level security;

drop policy if exists app_tasks_select on public.app_tasks;
create policy app_tasks_select on public.app_tasks for select to authenticated using(active=true);
drop policy if exists attempts_select_own on public.task_attempts;
create policy attempts_select_own on public.task_attempts for select to authenticated using(user_id=auth.uid());
drop policy if exists daily_claims_select_own on public.daily_task_claims;
create policy daily_claims_select_own on public.daily_task_claims for select to authenticated using(user_id=auth.uid());

create or replace function public.get_my_points() returns integer language sql security definer set search_path=public as $$ select coalesce((select points from public.profiles where id=auth.uid()),0); $$;
revoke all on function public.get_my_points() from public; grant execute on function public.get_my_points() to authenticated;

create or replace function public.get_wheel_status() returns jsonb language plpgsql security definer set search_path=public as $$
declare last timestamptz; next_at timestamptz;
begin select last_wheel_at into last from profiles where id=auth.uid(); next_at=coalesce(last, '-infinity'::timestamptz)+interval '12 hours'; if last is null then next_at=now(); end if; return jsonb_build_object('available',now()>=next_at,'next_spin_at_ms',extract(epoch from next_at)*1000); end $$;
revoke all on function public.get_wheel_status() from public; grant execute on function public.get_wheel_status() to authenticated;

create or replace function public.spin_wheel() returns jsonb language plpgsql security definer set search_path=public as $$
declare last timestamptz; idx int; prize int; new_points int; next_at timestamptz; r float8;
begin
 if auth.uid() is null then
   return jsonb_build_object('ok',false,'message','خاصك تسجل الدخول أولاً');
 end if;
 select last_wheel_at into last from profiles where id=auth.uid() for update;
 if last is not null and now()<last+interval '12 hours' then return jsonb_build_object('ok',false,'message','العجلة متاحة مرة كل 12 ساعة','next_spin_at_ms',extract(epoch from last+interval '12 hours')*1000); end if;
 r=random(); idx=floor(r*8)::int;
 prize=case idx when 0 then 5 when 1 then 25 when 2 then 0 when 3 then 15 when 4 then 1 when 5 then 50 when 6 then 100 else 500 end;
 update profiles set points=points+prize,last_wheel_at=now() where id=auth.uid() returning points into new_points;
 if prize>0 then insert into points_history(user_id,amount,reason) values(auth.uid(),prize,'wheel'); end if;
 next_at=now()+interval '12 hours'; return jsonb_build_object('ok',true,'segment_index',idx,'reward',case when idx=2 then 'retry' else prize::text end,'points',new_points,'next_spin_at_ms',extract(epoch from next_at)*1000);
end $$;
revoke all on function public.spin_wheel() from public; grant execute on function public.spin_wheel() to authenticated;

create or replace function public.claim_daily_task(p_task_key text) returns jsonb language plpgsql security definer set search_path=public as $$
declare t app_tasks; new_points int;
begin if auth.uid() is null then return jsonb_build_object('ok',false,'message','خاصك تسجل الدخول أولاً'); end if; select * into t from app_tasks where task_key=p_task_key and active=true; if not found then return jsonb_build_object('ok',false,'message','المهمة غير موجودة'); end if;
 if exists(select 1 from daily_task_claims where user_id=auth.uid() and task_key=p_task_key and claim_date=current_date) then select points into new_points from profiles where id=auth.uid(); return jsonb_build_object('ok',false,'message','تم احتساب هذه المهمة اليوم','points',new_points); end if;
 update profiles set points=points+t.points where id=auth.uid() returning points into new_points;
 insert into daily_task_claims(user_id,task_key,claim_date,points) values(auth.uid(),p_task_key,current_date,t.points);
 insert into points_history(user_id,amount,reason) values(auth.uid(),t.points,'task:'||p_task_key);
 return jsonb_build_object('ok',true,'points',new_points,'task_key',p_task_key);
end $$;
revoke all on function public.claim_daily_task(text) from public; grant execute on function public.claim_daily_task(text) to authenticated;

create or replace function public.begin_task(p_task_key text) returns jsonb
language plpgsql security definer set search_path=public as $$
declare
  t app_tasks;
  a task_attempts;
begin
  if auth.uid() is null then
    return jsonb_build_object('ok',false,'message','خاصك تسجل الدخول أولاً');
  end if;

  select * into t from app_tasks
  where task_key=p_task_key and active=true;

  if not found then
    return jsonb_build_object('ok',false,'message','المهمة غير موجودة');
  end if;

  if exists(
    select 1 from daily_task_claims
    where user_id=auth.uid() and task_key=p_task_key and claim_date=current_date
  ) then
    return jsonb_build_object('ok',false,'message','تم احتساب هذه المهمة اليوم');
  end if;

  insert into task_attempts(user_id,task_key)
  values(auth.uid(),p_task_key)
  on conflict(user_id,task_key)
  do update set started_at=now(),completed_at=null
  returning * into a;

  return jsonb_build_object(
    'ok',true,
    'started_at',a.started_at,
    'min_seconds',t.min_seconds
  );
end $$;

create or replace function public.claim_task(p_task_key text) returns jsonb
language plpgsql security definer set search_path=public as $$
declare
  t app_tasks;
  a task_attempts;
  new_points int;
  elapsed numeric;
  completed_today int;
  referral_count int;
begin
  if auth.uid() is null then
    return jsonb_build_object('ok',false,'message','خاصك تسجل الدخول أولاً');
  end if;

  select * into t from app_tasks where task_key=p_task_key and active=true;
  if not found then
    return jsonb_build_object('ok',false,'message','المهمة غير موجودة');
  end if;

  if exists(
    select 1 from daily_task_claims
    where user_id=auth.uid() and task_key=p_task_key and claim_date=current_date
  ) then
    select points into new_points from profiles where id=auth.uid();
    return jsonb_build_object('ok',false,'message','تم احتساب هذه المهمة اليوم','points',new_points);
  end if;

  -- Special tasks have real server-side requirements.
  if p_task_key = 'special-invite' then
    select count(*) into referral_count from profiles where referred_by=auth.uid();
    if referral_count < 1 then
      return jsonb_build_object('ok',false,'message','خاصك تدعي صديق واحد على الأقل أولاً');
    end if;
  elsif p_task_key = 'special-five' then
    select count(*) into completed_today
    from daily_task_claims
    where user_id=auth.uid() and claim_date=current_date
      and task_key in ('daily-login','daily-wheel','daily-game','daily-instagram','daily-whatsapp','daily-share');
    if completed_today < 5 then
      return jsonb_build_object('ok',false,'message','خاصك تكمل 5 مهام يومية أولاً');
    end if;
  elsif p_task_key = 'special-seven' then
    select count(*) into completed_today
    from daily_task_claims
    where user_id=auth.uid() and claim_date=current_date
      and task_key in ('daily-login','daily-wheel','daily-game','daily-instagram','daily-whatsapp','daily-share');
    if completed_today < 6 then
      return jsonb_build_object('ok',false,'message','خاصك تكمل المهام اليومية المتاحة أولاً');
    end if;
  end if;

  select * into a
  from task_attempts
  where user_id=auth.uid() and task_key=p_task_key;

  if a.id is null then
    return jsonb_build_object('ok',false,'message','خاصك تبدأ المهمة أولاً');
  end if;

  elapsed = extract(epoch from (now() - a.started_at));

  if elapsed < t.min_seconds then
    return jsonb_build_object('ok',false,'message','خاصك تكمل مدة التحقق');
  end if;

  update profiles
  set points = points + t.points
  where id=auth.uid()
  returning points into new_points;

  insert into daily_task_claims(user_id,task_key,claim_date,points)
  values(auth.uid(),p_task_key,current_date,t.points);

  update task_attempts set completed_at=now() where id=a.id;

  insert into points_history(user_id,amount,reason)
  values(auth.uid(),t.points,'task:'||p_task_key);

  return jsonb_build_object('ok',true,'points',new_points,'task_key',p_task_key);
end $$;

create or replace function public.get_daily_task_status() returns table(task_key text,completed boolean) language sql security definer set search_path=public as $$ select a.task_key, exists(select 1 from daily_task_claims d where d.user_id=auth.uid() and d.task_key=a.task_key and d.claim_date=current_date) from app_tasks a where a.active=true order by a.task_key; $$;
revoke all on function public.get_daily_task_status() from public; grant execute on function public.get_daily_task_status() to authenticated;

create or replace function public.redeem_reward(p_reward_id uuid) returns jsonb language plpgsql security definer set search_path=public as $$
declare r rewards; bal int; new_bal int;
begin select * into r from rewards where id=p_reward_id and active=true; if not found then return jsonb_build_object('ok',false,'message','الجائزة غير متاحة'); end if; select points into bal from profiles where id=auth.uid() for update; if bal<r.points_cost then return jsonb_build_object('ok',false,'message','النقاط غير كافية','points',bal); end if; update profiles set points=points-r.points_cost where id=auth.uid() returning points into new_bal; insert into redemptions(user_id,reward_id,points_spent,status) values(auth.uid(),r.id,r.points_cost,'pending'); insert into points_history(user_id,amount,reason) values(auth.uid(),-r.points_cost,'redeem:'||r.id::text); return jsonb_build_object('ok',true,'points',new_bal,'reward_id',r.id); end $$;
revoke all on function public.redeem_reward(uuid) from public; grant execute on function public.redeem_reward(uuid) to authenticated;

create or replace function public.get_my_profile() returns jsonb language plpgsql security definer set search_path=public as $$
declare p profiles; rc int; rw int; tc int;
begin select * into p from profiles where id=auth.uid(); select count(*) into rc from profiles where referred_by=auth.uid(); select count(*) into rw from redemptions where user_id=auth.uid(); select count(*) into tc from daily_task_claims where user_id=auth.uid(); return jsonb_build_object('points',coalesce(p.points,0),'username',p.username,'full_name',p.full_name,'referrals_count',rc,'rewards_won',rw,'tasks_completed',tc); end $$;
revoke all on function public.get_my_profile() from public; grant execute on function public.get_my_profile() to authenticated;

-- RLS for existing business tables: clients can read their own rows, not write points directly.
alter table public.profiles enable row level security; alter table public.points_history enable row level security; alter table public.task_completions enable row level security; alter table public.redemptions enable row level security; alter table public.rewards enable row level security; alter table public.tasks enable row level security;

drop policy if exists profiles_select_own on public.profiles; create policy profiles_select_own on public.profiles for select to authenticated using(id=auth.uid());
drop policy if exists points_history_select_own on public.points_history; create policy points_history_select_own on public.points_history for select to authenticated using(user_id=auth.uid());
drop policy if exists redemptions_select_own on public.redemptions; create policy redemptions_select_own on public.redemptions for select to authenticated using(user_id=auth.uid());
drop policy if exists rewards_select_active on public.rewards; create policy rewards_select_active on public.rewards for select to authenticated using(active=true);
drop policy if exists tasks_select_active on public.tasks; create policy tasks_select_active on public.tasks for select to authenticated using(active=true);

revoke insert,update,delete on public.profiles from anon,authenticated;
revoke insert,update,delete on public.points_history from anon,authenticated;
revoke insert,update,delete on public.redemptions from anon,authenticated;
revoke insert,update,delete on public.task_completions from anon,authenticated;
