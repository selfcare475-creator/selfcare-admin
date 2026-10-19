-- Promoters step 4: commission payouts (settle up + keep history)
create table if not exists public.promoter_payouts (
  id bigserial primary key,
  code int not null,
  paid_at timestamptz not null default now(),
  period_from timestamptz,
  period_to timestamptz not null,
  orders int not null default 0,
  new_orders int not null default 0,
  sales numeric not null default 0,
  commission numeric not null default 0,
  amount numeric not null default 0,
  note text
);
alter table public.promoter_payouts enable row level security;
create index if not exists promoter_payouts_code_idx on public.promoter_payouts(code, period_to desc);

-- what a promoter has earned between two moments (orders that are not Draft/Cancelled)
create or replace function public.sc_promoter_stats(p_code int, p_from timestamptz, p_to timestamptz)
returns table(orders int, new_orders int, sales numeric, commission numeric)
language sql stable security definer set search_path = public as $$
  select count(o.id)::int,
         (count(o.id) filter (where not coalesce(o.promoter_duplicate, false)))::int,
         coalesce(sum(coalesce(o.product_total, o.total - coalesce(o.delivery_fee, 0))), 0),
         round(coalesce(sum(coalesce(o.product_total, o.total - coalesce(o.delivery_fee, 0)))
               filter (where not coalesce(o.promoter_duplicate, false)), 0)
               * (select commission_pct from promoters where code = p_code) / 100)
  from orders o
  where o.promoter_code = p_code
    and coalesce(o.status, '') not in ('Draft', 'Cancelled')
    and o.created_at > coalesce(p_from, '-infinity'::timestamptz) and o.created_at <= p_to;
$$;
revoke all on function public.sc_promoter_stats(int, timestamptz, timestamptz) from public, anon, authenticated;

-- promoters list for the admin page: period stats + what is owed since the last payout
create or replace function public.promoters_admin(p_key text, p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare t0 timestamptz := (p_from::timestamp at time zone 'Africa/Cairo');
        t1 timestamptz := ((p_to + 1)::timestamp at time zone 'Africa/Cairo');
begin
  if not sc_is_admin(p_key) then raise exception 'not allowed'; end if;
  return coalesce((
    select jsonb_agg(row_to_json(x)::jsonb order by x.active desc, x.code)
    from (
      select p.id, p.code, p.name, p.lang, p.commission_pct, p.phone, p.active, p.notes,
        (select count(*) from promoter_visits v where v.code = p.code and v.visited_at >= t0 and v.visited_at < t1) visits,
        s.orders, s.new_orders, s.orders - s.new_orders old_orders, s.sales, s.commission,
        lp.paid_at last_paid_at, lp.amount last_paid_amount, lp.period_to last_period_to,
        u.orders unpaid_orders, u.new_orders unpaid_new_orders, u.sales unpaid_sales, u.commission unpaid_commission,
        (select count(*) from promoter_payouts q where q.code = p.code) payouts_count
      from promoters p
      cross join lateral sc_promoter_stats(p.code, t0 - interval '1 microsecond', t1 - interval '1 microsecond') s
      left join lateral (select * from promoter_payouts q where q.code = p.code order by q.period_to desc limit 1) lp on true
      cross join lateral sc_promoter_stats(p.code, lp.period_to, now()) u
    ) x), '[]'::jsonb);
end $$;

-- settle up: snapshot everything since the last payout, record the amount paid
create or replace function public.promoter_payout_admin(p_key text, p_code int, p_amount numeric, p_note text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_from timestamptz; v_to timestamptz := now(); s record; r promoter_payouts;
begin
  if not sc_is_admin(p_key) then raise exception 'not allowed'; end if;
  if not exists (select 1 from promoters where code = p_code) then raise exception 'promoter not found'; end if;
  select max(period_to) into v_from from promoter_payouts where code = p_code;
  select * into s from sc_promoter_stats(p_code, v_from, v_to);
  insert into promoter_payouts(code, period_from, period_to, orders, new_orders, sales, commission, amount, note)
  values (p_code, v_from, v_to, s.orders, s.new_orders, s.sales, s.commission, coalesce(p_amount, s.commission), nullif(p_note, ''))
  returning * into r;
  return to_jsonb(r);
end $$;

-- payout history of one promoter
create or replace function public.promoter_payouts_admin(p_key text, p_code int)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not sc_is_admin(p_key) then raise exception 'not allowed'; end if;
  return coalesce((select jsonb_agg(to_jsonb(q) order by q.period_to desc) from promoter_payouts q where q.code = p_code), '[]'::jsonb);
end $$;

-- delete a promoter only if it has no orders and no payouts
create or replace function public.promoter_delete_admin(p_key text, p_id bigint)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_code int;
begin
  if not sc_is_admin(p_key) then raise exception 'not allowed'; end if;
  select code into v_code from promoters where id = p_id;
  if v_code is null then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;
  if exists (select 1 from orders where promoter_code = v_code and coalesce(status, '') <> 'Draft')
     or exists (select 1 from promoter_payouts where code = v_code) then
    return jsonb_build_object('ok', false, 'reason', 'has_orders');
  end if;
  delete from promoter_visits where code = v_code;
  delete from promoters where id = p_id;
  return jsonb_build_object('ok', true);
end $$;

revoke all on function public.promoter_payout_admin(text, int, numeric, text) from public;
revoke all on function public.promoter_payouts_admin(text, int) from public;
grant execute on function public.promoter_payout_admin(text, int, numeric, text) to anon, authenticated;
grant execute on function public.promoter_payouts_admin(text, int) to anon, authenticated;
