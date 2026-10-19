-- Promoters step 5: points + private partner dashboard
alter table public.promoters add column if not exists points_per_100 numeric not null default 1;   -- points for every 100 EGP of new-customer sales
alter table public.promoters add column if not exists point_value numeric not null default 4;      -- EGP paid per point (admin only)
alter table public.promoters add column if not exists access_token text;
update public.promoters set access_token = replace(gen_random_uuid()::text, '-', '') where access_token is null;
alter table public.promoters alter column access_token set default replace(gen_random_uuid()::text, '-', '');
create unique index if not exists promoters_access_token_key on public.promoters(access_token);
alter table public.promoter_payouts add column if not exists points numeric not null default 0;

-- stats between two moments: orders, new orders, sales, points (new customers only) and their money value
drop function if exists public.sc_promoter_stats(int, timestamptz, timestamptz);
create function public.sc_promoter_stats(p_code int, p_from timestamptz, p_to timestamptz)
returns table(orders int, new_orders int, sales numeric, points numeric, commission numeric)
language sql stable security definer set search_path = public as $$
  with x as (
    select count(o.id)::int n,
           (count(o.id) filter (where not coalesce(o.promoter_duplicate, false)))::int nn,
           coalesce(sum(coalesce(o.product_total, o.total - coalesce(o.delivery_fee, 0))), 0) s,
           coalesce(sum(coalesce(o.product_total, o.total - coalesce(o.delivery_fee, 0))) filter (where not coalesce(o.promoter_duplicate, false)), 0) sn
    from orders o
    where o.promoter_code = p_code
      and coalesce(o.status, '') not in ('Draft', 'Cancelled')
      and o.created_at > coalesce(p_from, '-infinity'::timestamptz) and o.created_at <= p_to
  ), pr as (select points_per_100, point_value from promoters where code = p_code)
  select x.n, x.nn, x.s, floor(x.sn / 100 * pr.points_per_100), floor(x.sn / 100 * pr.points_per_100) * pr.point_value
  from x, pr;
$$;
revoke all on function public.sc_promoter_stats(int, timestamptz, timestamptz) from public, anon, authenticated;

create or replace function public.promoters_admin(p_key text, p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare t0 timestamptz := (p_from::timestamp at time zone 'Africa/Cairo');
        t1 timestamptz := ((p_to + 1)::timestamp at time zone 'Africa/Cairo');
begin
  if not sc_is_admin(p_key) then raise exception 'not allowed'; end if;
  return coalesce((
    select jsonb_agg(row_to_json(x)::jsonb order by x.active desc, x.code)
    from (
      select p.id, p.code, p.name, p.lang, p.commission_pct, p.points_per_100, p.point_value, p.access_token, p.phone, p.active, p.notes,
        (select count(*) from promoter_visits v where v.code = p.code and v.visited_at >= t0 and v.visited_at < t1) visits,
        s.orders, s.new_orders, s.orders - s.new_orders old_orders, s.sales, s.points, s.commission,
        lp.paid_at last_paid_at, lp.amount last_paid_amount, lp.points last_paid_points, lp.period_to last_period_to,
        u.orders unpaid_orders, u.new_orders unpaid_new_orders, u.sales unpaid_sales, u.points unpaid_points, u.commission unpaid_commission,
        (select count(*) from promoter_payouts q where q.code = p.code) payouts_count
      from promoters p
      cross join lateral sc_promoter_stats(p.code, t0 - interval '1 microsecond', t1 - interval '1 microsecond') s
      left join lateral (select * from promoter_payouts q where q.code = p.code order by q.period_to desc limit 1) lp on true
      cross join lateral sc_promoter_stats(p.code, lp.period_to, now()) u
    ) x), '[]'::jsonb);
end $$;

create or replace function public.promoter_payout_admin(p_key text, p_code int, p_amount numeric, p_note text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_from timestamptz; v_to timestamptz := now(); s record; r promoter_payouts;
begin
  if not sc_is_admin(p_key) then raise exception 'not allowed'; end if;
  if not exists (select 1 from promoters where code = p_code) then raise exception 'promoter not found'; end if;
  select max(period_to) into v_from from promoter_payouts where code = p_code;
  select * into s from sc_promoter_stats(p_code, v_from, v_to);
  insert into promoter_payouts(code, period_from, period_to, orders, new_orders, sales, points, commission, amount, note)
  values (p_code, v_from, v_to, s.orders, s.new_orders, s.sales, s.points, s.commission, coalesce(p_amount, s.commission), nullif(p_note, ''))
  returning * into r;
  return to_jsonb(r);
end $$;

create or replace function public.promoter_save_admin(p_key text, p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r promoters;
begin
  if not sc_is_admin(p_key) then raise exception 'not allowed'; end if;
  if nullif(p->>'id', '') is null then
    insert into promoters(code, name, lang, commission_pct, points_per_100, point_value, phone, active, notes)
    values ((p->>'code')::int, p->>'name', coalesce(nullif(p->>'lang', ''), 'en'), 0,
            coalesce(nullif(p->>'points_per_100', '')::numeric, 1), coalesce(nullif(p->>'point_value', '')::numeric, 4),
            nullif(p->>'phone', ''), coalesce((p->>'active')::boolean, true), nullif(p->>'notes', ''))
    returning * into r;
  else
    update promoters set code = (p->>'code')::int, name = p->>'name', lang = coalesce(nullif(p->>'lang', ''), 'en'),
      points_per_100 = coalesce(nullif(p->>'points_per_100', '')::numeric, points_per_100),
      point_value = coalesce(nullif(p->>'point_value', '')::numeric, point_value),
      phone = nullif(p->>'phone', ''), active = coalesce((p->>'active')::boolean, true), notes = nullif(p->>'notes', '')
    where id = (p->>'id')::bigint returning * into r;
  end if;
  return to_jsonb(r);
end $$;

-- new private link for a promoter (old link stops working)
create or replace function public.promoter_new_token_admin(p_key text, p_code int)
returns text language plpgsql security definer set search_path = public as $$
declare t text := replace(gen_random_uuid()::text, '-', '');
begin
  if not sc_is_admin(p_key) then raise exception 'not allowed'; end if;
  update promoters set access_token = t where code = p_code;
  return t;
end $$;

-- the promoter's own dashboard (opened with the private link). No money values except his sales.
create or replace function public.partner_dashboard(p_token text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare p promoters; lp promoter_payouts; d0 date := (now() at time zone 'Africa/Cairo')::date;
begin
  if p_token is null or length(p_token) < 16 then return null; end if;
  select * into p from promoters where access_token = p_token;
  if p.id is null then return null; end if;
  select * into lp from promoter_payouts where code = p.code order by period_to desc limit 1;
  return jsonb_build_object(
    'name', p.name, 'code', p.code, 'lang', p.lang, 'active', p.active,
    'link', 'https://selfcare-en.com/' || p.code,
    'balance', (select to_jsonb(s) from sc_promoter_stats(p.code, lp.period_to, now()) s) - 'commission',
    'all_time', (select to_jsonb(s) from sc_promoter_stats(p.code, null, now()) s) - 'commission',
    'visits', jsonb_build_object(
       'today', (select count(*) from promoter_visits v where v.code = p.code and (v.visited_at at time zone 'Africa/Cairo')::date = d0),
       'd7', (select count(*) from promoter_visits v where v.code = p.code and (v.visited_at at time zone 'Africa/Cairo')::date > d0 - 7),
       'd30', (select count(*) from promoter_visits v where v.code = p.code and (v.visited_at at time zone 'Africa/Cairo')::date > d0 - 30),
       'all', (select count(*) from promoter_visits v where v.code = p.code)),
    'days', (select jsonb_agg(jsonb_build_object('d', g.d,
              'v', (select count(*) from promoter_visits v where v.code = p.code and (v.visited_at at time zone 'Africa/Cairo')::date = g.d),
              'o', (select count(*) from orders o where o.promoter_code = p.code and coalesce(o.status, '') not in ('Draft', 'Cancelled') and (o.created_at at time zone 'Africa/Cairo')::date = g.d),
              'p', (select coalesce(floor(sum(coalesce(o.product_total, o.total - coalesce(o.delivery_fee, 0))) / 100 * p.points_per_100), 0) from orders o where o.promoter_code = p.code and not coalesce(o.promoter_duplicate, false) and coalesce(o.status, '') not in ('Draft', 'Cancelled') and (o.created_at at time zone 'Africa/Cairo')::date = g.d)
            ) order by g.d) from (select generate_series(d0 - 29, d0, interval '1 day')::date d) g),
    'payouts', coalesce((select jsonb_agg(jsonb_build_object('paid_at', q.paid_at, 'points', q.points, 'sales', q.sales, 'orders', q.orders) order by q.period_to desc) from promoter_payouts q where q.code = p.code), '[]'::jsonb),
    'since', lp.period_to
  );
end $$;

revoke all on function public.promoter_new_token_admin(text, int) from public;
revoke all on function public.partner_dashboard(text) from public;
grant execute on function public.promoter_new_token_admin(text, int) to anon, authenticated;
grant execute on function public.partner_dashboard(text) to anon, authenticated;
