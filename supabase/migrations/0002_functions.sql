set search_path = keldan, public;

-- ------------------------------------------------------------------ accounts
create or replace function keldan.norm_phone(p text) returns text language sql immutable as $$
  select right(regexp_replace(coalesce(p, ''), '\D', '', 'g'), 9)
$$;



/** First-time set-up: the reserved email becomes Keldan's owner (only while there is none). */
create or replace function keldan.claim_owner(p_name text) returns boolean
language plpgsql security definer set search_path = keldan, public as $$
begin
  if exists (select 1 from keldan.profiles where role = 'owner') then raise exception 'Keldan already has an owner account'; end if;
  if exists (select 1 from keldan.profiles where user_id = auth.uid()) then raise exception 'This account is already set up'; end if;
  if lower((select email from auth.users where id = auth.uid())) <> (select lower(reserved_admin_email) from keldan.secrets) then raise exception 'This email cannot set up Keldan'; end if;
  insert into keldan.profiles (user_id, role, owner_id, name, email, title) values (auth.uid(), 'owner', 'keldan', p_name, (select email from auth.users where id = auth.uid()), 'Owner');
  return true;
end $$;
create or replace function keldan.owner_exists() returns boolean language sql stable security definer set search_path = keldan, public as $$
  select exists (select 1 from keldan.profiles where role = 'owner')
$$;

/** Hands ownership to a staff member; the current owner becomes a manager with full access. */
create or replace function keldan.transfer_owner(p_user uuid) returns void
language plpgsql security definer set search_path = keldan, public as $$
declare me keldan.profiles := keldan.me(); m keldan.profiles;
begin
  if me is null or me.role <> 'owner' then raise exception 'Only the owner can hand over ownership'; end if;
  select * into m from keldan.profiles where user_id = p_user;
  if m is null or m.role <> 'manager' or m.owner_id <> me.owner_id then raise exception 'Choose a staff member who has signed in'; end if;
  update keldan.profiles set role = 'owner', title = 'Owner', perms = '{}' where user_id = p_user;
  update keldan.profiles set role = 'manager', title = 'Former owner',
    property_ids = coalesce((select array_agg(id) from keldan.records where owner_id = me.owner_id and col = 'properties'), '{}'),
    perms = '{"payments": true, "tenants": true, "maintenance": true, "expenses": true, "reports": true}' where user_id = me.user_id;
  perform keldan.alert(me.owner_id, 'Ownership handed over', coalesce(m.name, '') || ' is now the owner', 'staff');
end $$;

/** Public brand for the sign-in screens (before anyone is signed in): name, tagline, logos, colours, front picture. */
create or replace function keldan.public_brand() returns jsonb
language sql stable security definer set search_path = keldan, public as $$
  select jsonb_build_object('company', data->>'company', 'tagline', data->>'tagline', 'logo', data->>'logo', 'logoWide', data->>'logoWide',
    'frontImage', data->>'frontImage', 'theme', data->'theme', 'phone', data->>'phone', 'email', data->>'email', 'address', data->>'address')
  from keldan.owners where id = 'keldan'
$$;

/** Owner switches test mode (simulated payments) on or off. */
create or replace function keldan.set_test_mode(p_on boolean) returns void
language plpgsql security definer set search_path = keldan, public as $$
begin
  if (keldan.me()).role is distinct from 'owner' then raise exception 'Only the owner can change this'; end if;
  update keldan.config set platform = jsonb_set(platform, '{testMode}', to_jsonb(p_on));
end $$;

/** Tenants and invited staff join a company with its code; matched by the phone number the owner saved. */
create or replace function keldan.join_company(p_code text, p_name text, p_phone text, p_email text)
returns text language plpgsql security definer set search_path = keldan, public as $$
declare o keldan.owners; t record; inv record;
begin
  perform set_config('keldan.server', 'on', true);
  if auth.uid() is null then raise exception 'Please sign in first'; end if;
  if exists (select 1 from keldan.profiles where user_id = auth.uid()) then raise exception 'This account is already set up'; end if;
  select * into o from keldan.owners where code = upper(trim(p_code));
  if o is null then raise exception 'No company has the code %', upper(trim(p_code)); end if;
  if o.status = 'suspended' then raise exception 'This company is not active on Efie Wura'; end if;
  if keldan.norm_phone(p_phone) = '' then raise exception 'Enter your phone number'; end if;
  -- staff invite?
  select * into inv from keldan.records where owner_id = o.id and col = 'invites' and coalesce(data->>'accepted', '') = ''
    and keldan.norm_phone(data->>'phone') = keldan.norm_phone(p_phone) limit 1;
  if inv is not null then
    insert into keldan.profiles (user_id, role, owner_id, name, phone, email, title, property_ids, perms)
    values (auth.uid(), 'manager', o.id, coalesce(nullif(p_name, ''), inv.data->>'name'), p_phone, nullif(p_email, ''), coalesce(inv.data->>'title', 'Property Manager'),
            coalesce((select array_agg(x) from jsonb_array_elements_text(inv.data->'propertyIds') x), '{}'), coalesce(inv.data->'perms', '{}'));
    update keldan.records set data = data || jsonb_build_object('accepted', now(), 'userId', auth.uid()) where owner_id = o.id and col = 'invites' and id = inv.id;
    perform keldan.alert(o.id, coalesce(nullif(p_name, ''), inv.data->>'name') || ' joined your team', 'Staff account is active', 'staff');
    return 'manager';
  end if;
  select r.* into t from keldan.records r where r.owner_id = o.id and r.col = 'tenants' and keldan.norm_phone(r.data->>'phone') = keldan.norm_phone(p_phone)
    order by exists (select 1 from keldan.records l where l.owner_id = o.id and l.col = 'leases' and l.data->>'tenantId' = r.id and l.data->>'status' = 'active') desc limit 1;
  if t is null then raise exception 'We could not find a tenant with this phone number at %. Ask your landlord to add you with this number.', coalesce(o.data->>'company', 'this company'); end if;
  if exists (select 1 from keldan.profiles where owner_id = o.id and tenant_id = t.id) then raise exception 'This tenant already has an app account. Ask your landlord for help.'; end if;
  insert into keldan.profiles (user_id, role, owner_id, tenant_id, name, phone, email) values (auth.uid(), 'tenant', o.id, t.id, t.data->>'name', p_phone, nullif(p_email, ''));
  perform keldan.alert(o.id, (t.data->>'name') || ' joined the tenant app', 'They can now pay rent and report repairs in the app', 'tenant');
  return 'tenant';
end $$;




/** Owner edits or removes a staff member, or removes a tenant's app access. */
create or replace function keldan.update_member(p_user uuid, p_patch jsonb, p_remove boolean default false) returns void
language plpgsql security definer set search_path = keldan, public as $$
declare me keldan.profiles := keldan.me(); m keldan.profiles;
begin
  select * into m from keldan.profiles where user_id = p_user;
  if m is null or me is null or not (me.role = 'admin' or (me.role = 'owner' and me.owner_id = m.owner_id and m.role in ('manager', 'tenant'))) then raise exception 'Not allowed'; end if;
  if p_remove then delete from keldan.profiles where user_id = p_user; return; end if;
  update keldan.profiles set
    name = coalesce(p_patch->>'name', name), phone = coalesce(p_patch->>'phone', phone), title = coalesce(p_patch->>'title', title),
    property_ids = coalesce((select array_agg(x) from jsonb_array_elements_text(p_patch->'propertyIds') x), case when p_patch ? 'propertyIds' then '{}' else property_ids end),
    perms = coalesce(p_patch->'perms', perms)
  where user_id = p_user;
end $$;

-- ------------------------------------------------------------------ notifications & SMS
create or replace function keldan.alert(p_owner text, p_title text, p_text text, p_kind text) returns void
language plpgsql security definer set search_path = keldan, public as $$
begin
  perform set_config('keldan.server', 'on', true);
  insert into keldan.records (owner_id, col, id, data) values (p_owner, 'alerts', keldan.rid('al'),
    jsonb_build_object('title', p_title, 'text', p_text, 'kind', p_kind, 'at', now(), 'read', false));
end $$;

create or replace function keldan.fill(tpl text, vars jsonb) returns text language plpgsql immutable as $$
declare k text; r text := coalesce(tpl, '');
begin
  for k in select jsonb_object_keys(vars) loop r := replace(r, '{' || k || '}', coalesce(vars->>k, '')); end loop;
  return r;
end $$;

/** Queues SMS for sending (the keldan-sms function sends them). recipients: [{phone, name, text?}] */
create or replace function keldan.queue_sms(p_owner text, p_recipients jsonb, p_text text, p_kind text) returns int
language plpgsql security definer set search_path = keldan, public as $$
declare me keldan.profiles := keldan.me(); r jsonb; n int := 0; lim int; sent int;
begin
  if not keldan.is_server() and (me is null or (me.role <> 'admin' and (me.owner_id <> p_owner or me.role not in ('owner', 'manager')))) then raise exception 'Not allowed'; end if;
  perform set_config('keldan.server', 'on', true);
  lim := coalesce((keldan.platform()->>'smsDailyLimit')::int, 300);
  select count(*) into sent from keldan.records where owner_id = p_owner and col = 'sms' and (data->>'at')::timestamptz > now() - interval '1 day';
  for r in select * from jsonb_array_elements(p_recipients) loop
    if keldan.norm_phone(r->>'phone') = '' then continue; end if;
    insert into keldan.records (owner_id, col, id, data) values (p_owner, 'sms', keldan.rid('sms'), jsonb_build_object(
      'to', r->>'phone', 'name', r->>'name', 'kind', p_kind, 'text', coalesce(r->>'text', p_text), 'at', now(),
      'status', case when sent + n >= lim then 'limit' else 'queued' end));
    n := n + 1;
  end loop;
  return n;
end $$;

-- Each queued SMS is handed to the Edge Function straight away (pg_net).
create extension if not exists pg_net;
create or replace function keldan.sms_hook() returns trigger language plpgsql security definer set search_path = keldan, public as $$
declare s keldan.secrets;
begin
  if new.col = 'sms' and new.data->>'status' = 'queued' then
    select * into s from keldan.secrets;
    perform net.http_post(url := s.functions_url || '/keldan-sms', body := jsonb_build_object('owner', new.owner_id, 'id', new.id),
      headers := jsonb_build_object('Content-Type', 'application/json', 'x-hook-secret', s.hook_secret));
  end if;
  return null;
end $$;
create trigger records_sms after insert on keldan.records for each row when (new.col = 'sms') execute function keldan.sms_hook();

-- ------------------------------------------------------------------ billing
create or replace function keldan.lease_end(d jsonb) returns date language sql immutable as $$
  select ((d->>'start')::date + ((d->>'months')::int * interval '1 month') - interval '1 day')::date
$$;

/** Raises rent bills due within 14 days for every running tenancy (idempotent) and late fees on overdue rent. */
create or replace function keldan.bill_owner(p_owner text) returns int
language plpgsql security definer set search_path = keldan, public as $$
declare l record; u jsonb; st date; en date; lastd date; step int; p date; pe date; i int; mth int; n int := 0; rc int;
        horizon date := current_date + 14; o jsonb; latepct numeric; grace int; inv record; bal numeric;
begin
  perform set_config('keldan.server', 'on', true);
  update keldan.records set data = data || jsonb_build_object('status', 'ended', 'endedOn', keldan.lease_end(data))
   where owner_id = p_owner and col = 'leases' and data->>'status' = 'active' and coalesce(data->>'renewedBy', '') <> '' and keldan.lease_end(data) < current_date;
  for l in select id, data from keldan.records where owner_id = p_owner and col = 'leases' and data->>'status' = 'active' loop
    select data into u from keldan.records where owner_id = p_owner and col = 'units' and id = l.data->>'unitId';
    st := (l.data->>'start')::date;
    en := (st + ((l.data->>'months')::int * interval '1 month'))::date;
    lastd := coalesce((l.data->>'endedOn')::date, en);
    step := case l.data->>'cycle' when 'monthly' then 1 when 'quarterly' then 3 when 'biannual' then 6 when 'yearly' then 12 else (l.data->>'months')::int end;
    if coalesce((l.data->>'deposit')::numeric, 0) > 0 then
      insert into keldan.records (owner_id, col, id, data) values (p_owner, 'invoices', 'inv_' || l.id || '_dep', jsonb_build_object(
        'kind', 'deposit', 'title', 'Security deposit', 'periodStart', st, 'periodEnd', st, 'amount', (l.data->>'deposit')::numeric, 'due', st, 'issued', st,
        'leaseId', l.id, 'tenantId', l.data->>'tenantId', 'unitId', l.data->>'unitId', 'propertyId', u->>'propertyId', 'paid', 0)) on conflict do nothing;
      get diagnostics rc = row_count; n := n + rc;
    end if;
    i := 0;
    loop
      p := (st + (step * i * interval '1 month'))::date;
      exit when p >= en or p > horizon or p > lastd;
      pe := least((st + (step * (i + 1) * interval '1 month'))::date, en);
      mth := round((pe - p) / 30.44);
      insert into keldan.records (owner_id, col, id, data) values (p_owner, 'invoices', 'inv_' || l.id || '_' || i, jsonb_build_object(
        'kind', 'rent', 'title', 'Rent ' || to_char(p, 'Mon YYYY') || case when mth > 1 then ' – ' || to_char(pe - 1, 'Mon YYYY') else '' end,
        'periodStart', p, 'periodEnd', pe - 1, 'months', mth, 'amount', round((l.data->>'rent')::numeric * mth, 2), 'due', p, 'issued', p - 14,
        'leaseId', l.id, 'tenantId', l.data->>'tenantId', 'unitId', l.data->>'unitId', 'propertyId', u->>'propertyId', 'paid', 0)) on conflict do nothing;
      get diagnostics rc = row_count; n := n + rc;
      i := i + 1;
    end loop;
  end loop;
  select data into o from keldan.owners where id = p_owner;
  latepct := coalesce((o->'settings'->>'lateFeePct')::numeric, 0);
  grace := coalesce((o->'settings'->>'graceDays')::int, 5);
  if latepct > 0 then
    for inv in select * from keldan.records r where r.owner_id = p_owner and r.col = 'invoices' and r.data->>'kind' = 'rent' and coalesce((r.data->>'void')::boolean, false) = false
        and current_date - (r.data->>'due')::date between grace + 1 and 90 loop
      bal := (inv.data->>'amount')::numeric - coalesce((inv.data->>'paid')::numeric, 0);
      continue when bal <= 0.001;
      insert into keldan.records (owner_id, col, id, data) values (p_owner, 'invoices', inv.id || '_late', inv.data || jsonb_build_object(
        'kind', 'late', 'title', 'Late fee · ' || (inv.data->>'title'), 'amount', round(bal * latepct / 100, 2), 'paid', 0, 'issued', current_date, 'due', current_date)) on conflict do nothing;
      get diagnostics rc = row_count; n := n + rc;
    end loop;
  end if;
  return n;
end $$;
revoke execute on function keldan.bill_owner(text) from public, anon, authenticated;

create or replace function keldan.run_billing(p_owner text) returns int
language plpgsql security definer set search_path = keldan, public as $$
declare me keldan.profiles := keldan.me();
begin
  if me is null or (me.role <> 'admin' and me.owner_id is distinct from p_owner) then raise exception 'Not allowed'; end if;
  return keldan.bill_owner(p_owner);
end $$;

create or replace function keldan.bill_all() returns int language plpgsql security definer set search_path = keldan, public as $$
declare o record; n int := 0;
begin
  for o in select id from keldan.owners where status <> 'suspended' loop n := n + keldan.bill_owner(o.id); end loop;
  return n;
end $$;
revoke execute on function keldan.bill_all() from public, anon, authenticated;

-- ------------------------------------------------------------------ payments
/** Spreads a payment over the tenant's open bills (chosen ones first), saves it, sends a receipt SMS and an alert. */
create or replace function keldan.apply_payment(p_owner text, p_tenant text, p_amount numeric, p_method text, p_invoice_ids text[],
  p_by text, p_payer text, p_note text, p_online boolean, p_test boolean) returns jsonb
language plpgsql security definer set search_path = keldan, public as $$
declare left_ numeric := round(p_amount, 2); inv record; take numeric; allocs jsonb := '[]'; fee numeric; pay jsonb; pid text := keldan.rid('pay');
        first_unit text; first_prop text; t jsonb; o jsonb; unit_label text; ref text := 'EW' || lpad(floor(random() * 1e9)::text, 9, '0');
begin
  perform set_config('keldan.server', 'on', true);
  for inv in
    select r.id, r.data from keldan.records r where r.owner_id = p_owner and r.col = 'invoices' and r.data->>'tenantId' = p_tenant
      and coalesce((r.data->>'void')::boolean, false) = false and (r.data->>'amount')::numeric - coalesce((r.data->>'paid')::numeric, 0) > 0.001
    order by (r.id = any (coalesce(p_invoice_ids, '{}'))) desc, r.data->>'due', r.id
    for update
  loop
    exit when left_ <= 0;
    take := least(left_, (inv.data->>'amount')::numeric - coalesce((inv.data->>'paid')::numeric, 0));
    update keldan.records set data = jsonb_set(data, '{paid}', to_jsonb(round(coalesce((data->>'paid')::numeric, 0) + take, 2))) where owner_id = p_owner and col = 'invoices' and id = inv.id;
    allocs := allocs || jsonb_build_object('invoiceId', inv.id, 'amount', round(take, 2));
    left_ := round(left_ - take, 2);
    first_unit := coalesce(first_unit, inv.data->>'unitId'); first_prop := coalesce(first_prop, inv.data->>'propertyId');
  end loop;
  if first_unit is null then
    select data->>'unitId' into first_unit from keldan.records where owner_id = p_owner and col = 'leases' and data->>'tenantId' = p_tenant order by data->>'status' = 'active' desc, data->>'start' desc limit 1;
    select data->>'propertyId' into first_prop from keldan.records where owner_id = p_owner and col = 'units' and id = first_unit;
  end if;
  fee := case when p_online then round(p_amount * (keldan.platform()->>'feePct')::numeric / 100, 2) else 0 end;
  pay := jsonb_build_object('tenantId', p_tenant, 'unitId', first_unit, 'propertyId', first_prop, 'amount', round(p_amount, 2), 'fee', fee, 'net', round(p_amount - fee, 2),
    'method', p_method, 'online', p_online, 'ref', ref, 'at', now(), 'allocations', allocs, 'credit', left_, 'by', p_by, 'payer', p_payer, 'note', p_note, 'test', p_test);
  insert into keldan.records (owner_id, col, id, data) values (p_owner, 'payments', pid, pay);
  select data into t from keldan.records where owner_id = p_owner and col = 'tenants' and id = p_tenant;
  select data into o from keldan.owners where id = p_owner;
  select data->>'label' into unit_label from keldan.records where owner_id = p_owner and col = 'units' and id = first_unit;
  perform keldan.alert(p_owner, (t->>'name') || ' paid GH₵ ' || to_char(p_amount, 'FM999,999,990.00'), coalesce(unit_label, '') || ' · ' || ref, 'payment');
  if coalesce(t->>'phone', '') <> '' then
    perform keldan.queue_sms(p_owner, jsonb_build_array(jsonb_build_object('phone', t->>'phone', 'name', t->>'name')),
      keldan.fill(o->'settings'->'templates'->>'receipt', jsonb_build_object('name', split_part(t->>'name', ' ', 1), 'amount', 'GH₵ ' || to_char(p_amount, 'FM999,999,990.00'),
        'unit', coalesce(unit_label, ''), 'ref', ref, 'company', o->>'company')), 'receipt');
  end if;
  return pay || jsonb_build_object('id', pid, 'ownerId', p_owner);
end $$;
revoke execute on function keldan.apply_payment(text, text, numeric, text, text[], text, text, text, boolean, boolean) from public, anon, authenticated;

/** Owner/staff record cash, bank, cheque or MoMo paid to them directly (not added to the wallet). */
create or replace function keldan.record_payment(p_owner text, p_tenant text, p_amount numeric, p_method text, p_invoice_ids text[], p_note text)
returns jsonb language plpgsql security definer set search_path = keldan, public as $$
declare me keldan.profiles := keldan.me();
begin
  if me is null or me.owner_id is distinct from p_owner or not (me.role = 'owner' or (me.role = 'manager' and coalesce((me.perms->>'payments')::boolean, false))) then raise exception 'Not allowed'; end if;
  if p_method not in ('cash', 'bank', 'cheque', 'momo_direct') then raise exception 'Use the online checkout for MoMo or card'; end if;
  if p_amount is null or p_amount <= 0 or p_amount > 1000000 then raise exception 'Enter a valid amount'; end if;
  if not exists (select 1 from keldan.records where owner_id = p_owner and col = 'tenants' and id = p_tenant) then raise exception 'Tenant not found'; end if;
  return keldan.apply_payment(p_owner, p_tenant, p_amount, p_method, p_invoice_ids, me.name, null, p_note, false, false);
end $$;

/** Starts an online payment (tenant paying rent, staff charging a tenant, or an owner paying for a plan). */
create or replace function keldan.start_checkout(p_owner text, p_tenant text, p_amount numeric, p_method text, p_payer text, p_invoice_ids text[], p_plan text default null)
returns keldan.checkouts language plpgsql security definer set search_path = keldan, public as $$
declare me keldan.profiles := keldan.me(); o keldan.owners; c keldan.checkouts; pl jsonb; amt numeric := round(p_amount, 2);
begin
  if me is null then raise exception 'Please sign in'; end if;
  select * into o from keldan.owners where id = p_owner;
  if o is null or me.owner_id is distinct from p_owner then raise exception 'Not allowed'; end if;
  if p_plan is not null then
    if me.role <> 'owner' then raise exception 'Only the owner can change the plan'; end if;
    select x into pl from jsonb_array_elements(keldan.platform()->'plans') x where x->>'id' = p_plan;
    if pl is null or (pl->>'price')::numeric <= 0 then raise exception 'Choose a paid plan'; end if;
    amt := (pl->>'price')::numeric;
  else
    if o.status <> 'approved' then raise exception 'Online payment is not switched on for this landlord yet'; end if;
    if me.role = 'tenant' and me.tenant_id is distinct from p_tenant then raise exception 'Not allowed'; end if;
    if me.role = 'manager' and not coalesce((me.perms->>'payments')::boolean, false) then raise exception 'Not allowed'; end if;
    if not exists (select 1 from keldan.records where owner_id = p_owner and col = 'tenants' and id = p_tenant) then raise exception 'Tenant not found'; end if;
    if amt is null or amt < 1 or amt > 200000 then raise exception 'Enter an amount between GH₵ 1 and GH₵ 200,000'; end if;
  end if;
  insert into keldan.checkouts (owner_id, tenant_id, kind, plan, amount, method, payer, invoice_ids, provider, test, created_by)
  values (p_owner, case when p_plan is null then p_tenant end, case when p_plan is null then 'rent' else 'plan' end, p_plan, amt, p_method, p_payer,
          coalesce(p_invoice_ids, '{}'), o.provider, coalesce((keldan.platform()->>'testMode')::boolean, true), auth.uid())
  returning * into c;
  return c;
end $$;

/** Marks a checkout paid and applies it. Called by the payment webhook / verifier (service role) or the test-mode simulator. */
create or replace function keldan.settle_checkout(p_id text, p_ref text) returns jsonb
language plpgsql security definer set search_path = keldan, public as $$
declare c keldan.checkouts; pay jsonb; who text;
begin
  perform set_config('keldan.server', 'on', true);
  select * into c from keldan.checkouts where id = p_id for update;
  if c is null then raise exception 'Checkout not found'; end if;
  if c.status = 'success' then return jsonb_build_object('status', 'success', 'paymentId', c.payment_id); end if;
  if c.kind = 'rent' then
    select name into who from keldan.profiles where user_id = c.created_by;
    pay := keldan.apply_payment(c.owner_id, c.tenant_id, c.amount, c.method, c.invoice_ids,
      case when (select role from keldan.profiles where user_id = c.created_by) = 'tenant' then 'tenant' else who end, c.payer, null, true, c.test);
    update keldan.checkouts set status = 'success', provider_ref = coalesce(p_ref, provider_ref), settled_at = now(), payment_id = pay->>'id' where id = p_id;
  else
    update keldan.owners set plan = c.plan, plan_renews = (current_date + interval '1 month')::date where id = c.owner_id;
    insert into keldan.records (owner_id, col, id, data) values (c.owner_id, 'subscriptions', keldan.rid('sub'),
      jsonb_build_object('plan', c.plan, 'amount', c.amount, 'at', now(), 'method', c.method, 'fromWallet', false, 'test', c.test));
    update keldan.checkouts set status = 'success', provider_ref = coalesce(p_ref, provider_ref), settled_at = now() where id = p_id;
  end if;
  return jsonb_build_object('status', 'success', 'payment', pay);
end $$;
revoke execute on function keldan.settle_checkout(text, text) from public, anon, authenticated;
grant execute on function keldan.settle_checkout(text, text) to service_role;

create or replace function keldan.fail_checkout(p_id text, p_error text) returns void
language sql security definer set search_path = keldan, public as $$
  update keldan.checkouts set status = 'failed', error = p_error, settled_at = now() where id = p_id and status = 'pending'
$$;
revoke execute on function keldan.fail_checkout(text, text) from public, anon, authenticated;
grant execute on function keldan.fail_checkout(text, text) to service_role;

/** Test mode only: simulates the MoMo prompt / card result (numbers ending 000 or cards ending 0002 decline). */
create or replace function keldan.confirm_test_checkout(p_id text) returns jsonb
language plpgsql security definer set search_path = keldan, public as $$
declare c keldan.checkouts;
begin
  select * into c from keldan.checkouts where id = p_id;
  if c is null or c.created_by <> auth.uid() then raise exception 'Not allowed'; end if;
  if not c.test then raise exception 'This is a live payment'; end if;
  if (c.method = 'card' and c.payer like '%0002') or (c.method <> 'card' and c.payer like '%000') then
    perform keldan.fail_checkout(p_id, case when c.method = 'card' then 'Card declined by your bank.' else 'The MoMo prompt was declined or timed out.' end);
    return jsonb_build_object('status', 'failed', 'error', (select error from keldan.checkouts where id = p_id));
  end if;
  return keldan.settle_checkout(p_id, 'TEST-' || p_id);
end $$;

create or replace function keldan.checkout_status(p_id text) returns jsonb
language sql stable security definer set search_path = keldan, public as $$
  select jsonb_build_object('status', c.status, 'error', c.error, 'payUrl', c.pay_url,
    'payment', (select r.data from keldan.records r where r.owner_id = c.owner_id and r.col = 'payments' and r.id = c.payment_id))
  from keldan.checkouts c where c.id = p_id and (c.created_by = auth.uid() or keldan.is_admin())
$$;

-- ------------------------------------------------------------------ wallet & withdrawals
create or replace function keldan.wallet_balance(p_owner text) returns numeric
language sql stable security definer set search_path = keldan, public as $$
  select round(
    coalesce((select sum((data->>'net')::numeric) from keldan.records where owner_id = p_owner and col = 'payments' and (data->>'online')::boolean), 0)
  - coalesce((select sum((data->>'amount')::numeric) from keldan.records where owner_id = p_owner and col = 'withdrawals' and data->>'status' not in ('rejected', 'failed')), 0)
  - coalesce((select sum((data->>'amount')::numeric) from keldan.records where owner_id = p_owner and col = 'subscriptions' and (data->>'fromWallet')::boolean), 0), 2)
$$;







-- ------------------------------------------------------------------ plans


-- ------------------------------------------------------------------ tenants
create or replace function keldan.sign_lease(p_lease text, p_name text, p_image text) returns void
language plpgsql security definer set search_path = keldan, public as $$
declare me keldan.profiles := keldan.me(); l jsonb; who text;
begin
  perform set_config('keldan.server', 'on', true);
  if me is null then raise exception 'Please sign in'; end if;
  select data into l from keldan.records where owner_id = me.owner_id and col = 'leases' and id = p_lease;
  if l is null then raise exception 'Tenancy not found'; end if;
  if me.role = 'tenant' then
    if l->>'tenantId' <> me.tenant_id then raise exception 'Not your tenancy'; end if;
    who := 'signedTenant';
  elsif me.role in ('owner', 'manager') then who := 'signedOwner';
  else raise exception 'Not allowed'; end if;
  if length(coalesce(p_image, '')) > 200000 then raise exception 'Signature image too large'; end if;
  update keldan.records set data = data || jsonb_build_object(who, jsonb_build_object('name', p_name, 'image', p_image, 'at', now()))
  where owner_id = me.owner_id and col = 'leases' and id = p_lease;
  if who = 'signedTenant' then perform keldan.alert(me.owner_id, me.name || ' signed the tenancy agreement', l->>'no', 'lease'); end if;
end $$;

create or replace function keldan.report_repair(p jsonb) returns text
language plpgsql security definer set search_path = keldan, public as $$
declare me keldan.profiles := keldan.me(); l jsonb; u jsonb; rid text := keldan.rid('mt');
begin
  perform set_config('keldan.server', 'on', true);
  if me is null or me.role <> 'tenant' then raise exception 'Not allowed'; end if;
  select data into l from keldan.records where owner_id = me.owner_id and col = 'leases' and data->>'tenantId' = me.tenant_id order by data->>'status' = 'active' desc, data->>'start' desc limit 1;
  if l is null then raise exception 'No tenancy found'; end if;
  select data into u from keldan.records where owner_id = me.owner_id and col = 'units' and id = l->>'unitId';
  if length(coalesce(p->>'photo', '')) > 600000 then raise exception 'Photo too large'; end if;
  insert into keldan.records (owner_id, col, id, data) values (me.owner_id, 'maintenance', rid, jsonb_build_object(
    'title', left(p->>'title', 140), 'category', p->>'category', 'priority', coalesce(p->>'priority', 'medium'), 'desc', left(coalesce(p->>'desc', ''), 2000), 'photo', p->>'photo',
    'unitId', l->>'unitId', 'propertyId', u->>'propertyId', 'tenantId', me.tenant_id, 'status', 'open', 'at', now(), 'updates', '[]'::jsonb, 'assignee', ''));
  perform keldan.alert(me.owner_id, 'New repair request: ' || left(p->>'title', 80), me.name || ' · ' || coalesce(u->>'label', ''), 'maintenance');
  return rid;
end $$;

-- ------------------------------------------------------------------ Super Admin




-- ------------------------------------------------------------------ grants
revoke execute on all functions in schema keldan from public, anon, authenticated;
grant execute on function keldan.claim_owner(text), keldan.transfer_owner(uuid), keldan.set_test_mode(boolean), keldan.join_company(text, text, text, text),
  keldan.update_member(uuid, jsonb, boolean), keldan.queue_sms(text, jsonb, text, text),
  keldan.run_billing(text), keldan.record_payment(text, text, numeric, text, text[], text),
  keldan.start_checkout(text, text, numeric, text, text, text[], text), keldan.confirm_test_checkout(text), keldan.checkout_status(text),
  keldan.sign_lease(text, text, text), keldan.report_repair(jsonb),
  keldan.me(), keldan.is_admin(), keldan.can_read(text, text, text, jsonb), keldan.can_write(text, text, jsonb), keldan.platform(), keldan.is_server()
  to authenticated;
grant execute on function keldan.owner_exists(), keldan.public_brand() to anon, authenticated;
grant execute on all functions in schema keldan to service_role;

-- Realtime: clients get live changes (still filtered by row-level security).
alter publication supabase_realtime add table keldan.records, keldan.owners, keldan.checkouts;

-- Daily billing run (05:15 UTC) for every owner.
create extension if not exists pg_cron;
select cron.schedule('keldan-billing', '15 5 * * *', 'select keldan.bill_all()');
