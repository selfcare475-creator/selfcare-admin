-- Promoters step 2: short-link visits + attach promoter to orders
create or replace function public.promoter_hit(p_code int, p_host text default null)
returns text language plpgsql security definer set search_path = public as $$
declare v_lang text;
begin
  select lang into v_lang from promoters where code = p_code and active;
  if v_lang is null then return null; end if;
  insert into promoter_visits(code, lang, host) values (p_code, v_lang, left(p_host, 100));
  return v_lang;
end $$;
revoke all on function public.promoter_hit(int, text) from public;
grant execute on function public.promoter_hit(int, text) to anon, authenticated;

create or replace function public.orders_promoter_guard()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_phone text;
begin
  -- once an order has a promoter it can't be changed or removed from the website
  if tg_op = 'UPDATE' and old.promoter_code is not null then
    new.promoter_code := old.promoter_code; new.promoter_set_at := old.promoter_set_at; new.promoter_duplicate := old.promoter_duplicate;
    return new;
  end if;
  if new.promoter_code is null then return new; end if;
  if not exists (select 1 from promoters where code = new.promoter_code and active) then
    new.promoter_code := null; return new;
  end if;
  new.promoter_set_at := now();
  -- duplicate = this phone already ordered before (not a new customer)
  v_phone := regexp_replace(coalesce(new.customer_phone, ''), '\D', '', 'g');
  new.promoter_duplicate := length(v_phone) >= 8 and exists (
    select 1 from orders o
    where o.id is distinct from new.id
      and coalesce(o.status, '') <> 'Draft'
      and o.created_at < coalesce(new.created_at, now())
      and right(regexp_replace(coalesce(o.customer_phone, ''), '\D', '', 'g'), 9) = right(v_phone, 9));
  return new;
end $$;

drop trigger if exists orders_promoter_guard on public.orders;
create trigger orders_promoter_guard before insert or update of promoter_code on public.orders
for each row execute function public.orders_promoter_guard();

-- test promoter (German) for trying the link; delete later
insert into promoters(code, name, lang, commission_pct, notes)
values (999, 'TEST - T', 'de', 10, 'test promoter, delete later')
on conflict (code) do nothing;
