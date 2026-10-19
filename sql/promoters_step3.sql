-- Promoters step 3: admin page functions (only the admin password can use them)
create table if not exists public.admin_keys (hash text primary key, role text not null, created_at timestamptz default now());
alter table public.admin_keys enable row level security;
insert into public.admin_keys(hash, role) values ('343b9b86794eb6e8cf9844549fa58b4e9f3b8ffbc9757ce91b5a86bf6f689027', 'admin') on conflict (hash) do nothing;

create or replace function public.sc_is_admin(p_key text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from admin_keys where hash = p_key and role = 'admin');
$$;
revoke all on function public.sc_is_admin(text) from public, anon, authenticated;

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
        count(o.id) orders,
        count(o.id) filter (where not coalesce(o.promoter_duplicate, false)) new_orders,
        count(o.id) filter (where coalesce(o.promoter_duplicate, false)) old_orders,
        coalesce(sum(coalesce(o.product_total, o.total - coalesce(o.delivery_fee, 0))), 0) sales,
        round(coalesce(sum(coalesce(o.product_total, o.total - coalesce(o.delivery_fee, 0)))
              filter (where not coalesce(o.promoter_duplicate, false)), 0) * p.commission_pct / 100) commission
      from promoters p
      left join orders o on o.promoter_code = p.code
        and coalesce(o.status, '') not in ('Draft', 'Cancelled')
        and o.created_at >= t0 and o.created_at < t1
      group by p.id
    ) x), '[]'::jsonb);
end $$;

create or replace function public.promoter_orders_admin(p_key text, p_code int, p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not sc_is_admin(p_key) then raise exception 'not allowed'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', o.id, 'created_at', o.created_at, 'customer_name', o.customer_name,
      'hotel', o.hotel, 'status', o.status, 'total', o.total,
      'product_total', coalesce(o.product_total, o.total - coalesce(o.delivery_fee, 0)),
      'old_customer', coalesce(o.promoter_duplicate, false)) order by o.created_at desc)
    from orders o
    where o.promoter_code = p_code and coalesce(o.status, '') <> 'Draft'
      and o.created_at >= (p_from::timestamp at time zone 'Africa/Cairo')
      and o.created_at < ((p_to + 1)::timestamp at time zone 'Africa/Cairo')), '[]'::jsonb);
end $$;

create or replace function public.promoter_save_admin(p_key text, p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r promoters;
begin
  if not sc_is_admin(p_key) then raise exception 'not allowed'; end if;
  if nullif(p->>'id', '') is null then
    insert into promoters(code, name, lang, commission_pct, phone, active, notes)
    values ((p->>'code')::int, p->>'name', coalesce(nullif(p->>'lang', ''), 'en'), coalesce(nullif(p->>'commission_pct', '')::numeric, 0),
            nullif(p->>'phone', ''), coalesce((p->>'active')::boolean, true), nullif(p->>'notes', ''))
    returning * into r;
  else
    update promoters set code = (p->>'code')::int, name = p->>'name', lang = coalesce(nullif(p->>'lang', ''), 'en'),
      commission_pct = coalesce(nullif(p->>'commission_pct', '')::numeric, 0), phone = nullif(p->>'phone', ''),
      active = coalesce((p->>'active')::boolean, true), notes = nullif(p->>'notes', '')
    where id = (p->>'id')::bigint returning * into r;
  end if;
  return to_jsonb(r);
end $$;

revoke all on function public.promoters_admin(text, date, date) from public;
revoke all on function public.promoter_orders_admin(text, int, date, date) from public;
revoke all on function public.promoter_save_admin(text, jsonb) from public;
grant execute on function public.promoters_admin(text, date, date) to anon, authenticated;
grant execute on function public.promoter_orders_admin(text, int, date, date) to anon, authenticated;
grant execute on function public.promoter_save_admin(text, jsonb) to anon, authenticated;
