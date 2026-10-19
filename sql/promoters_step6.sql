-- Promoters step 6: partner dashboard shows only points and the money they are worth (no visits, no sales)
create or replace function public.partner_dashboard(p_token text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare p promoters; lp promoter_payouts; d0 date := (now() at time zone 'Africa/Cairo')::date; b record; a record;
begin
  if p_token is null or length(p_token) < 16 then return null; end if;
  select * into p from promoters where access_token = p_token;
  if p.id is null then return null; end if;
  select * into lp from promoter_payouts where code = p.code order by period_to desc limit 1;
  select * into b from sc_promoter_stats(p.code, lp.period_to, now());
  select * into a from sc_promoter_stats(p.code, null, now());
  return jsonb_build_object(
    'name', p.name, 'code', p.code, 'lang', p.lang, 'active', p.active,
    'link', 'https://selfcare-en.com/' || p.code,
    'since', lp.period_to,
    'balance', jsonb_build_object('points', b.points, 'money', b.commission),
    'all_time', jsonb_build_object('points', a.points,
                                   'paid', coalesce((select sum(amount) from promoter_payouts q where q.code = p.code), 0)),
    'days', (select jsonb_agg(jsonb_build_object('d', g.d,
              'p', (select coalesce(floor(sum(coalesce(o.product_total, o.total - coalesce(o.delivery_fee, 0))) / 100 * p.points_per_100), 0)
                    from orders o where o.promoter_code = p.code and not coalesce(o.promoter_duplicate, false)
                      and coalesce(o.status, '') not in ('Draft', 'Cancelled')
                      and (o.created_at at time zone 'Africa/Cairo')::date = g.d)
            ) order by g.d) from (select generate_series(d0 - 29, d0, interval '1 day')::date d) g),
    'payouts', coalesce((select jsonb_agg(jsonb_build_object('paid_at', q.paid_at, 'points', q.points, 'amount', q.amount) order by q.period_to desc)
                         from promoter_payouts q where q.code = p.code), '[]'::jsonb)
  );
end $$;
