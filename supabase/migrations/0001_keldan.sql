-- Keldan Properties Limited (single company, independent of Efie Wura). Own schema "keldan" so it can share a Supabase project safely.
-- Clients read/write ordinary records under row-level security; anything that moves money
-- (payments, wallet, withdrawals, plan charges) only happens inside the functions below.

create schema if not exists keldan;
grant usage on schema keldan to anon, authenticated, service_role;
set search_path = keldan, public;

-- ------------------------------------------------------------------ tables
create table keldan.config (
  id boolean primary key default true check (id),
  platform jsonb not null
);
insert into keldan.config (platform) values ('{
  "name": "Keldan Properties Limited", "feePct": 0, "minWithdraw": 0, "autoLimit": 0, "graceDays": 5, "testMode": true, "smsDailyLimit": 300, "single": true,
  "plans": [{"id": "keldan", "name": "Keldan", "price": 0, "units": 100000, "perks": []}]}');

-- Never readable by clients.
create table keldan.secrets (
  id boolean primary key default true check (id),
  reserved_admin_email text not null default 'nyamebabaku@gmail.com',
  hook_secret text not null default replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''),
  functions_url text not null default 'https://jepkzvunetajsgscoelv.supabase.co/functions/v1'
);
insert into keldan.secrets default values;

create table keldan.owners (
  id text primary key default 'o_' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 12),
  code text not null unique,
  status text not null default 'pending' check (status in ('pending', 'approved', 'suspended')),
  plan text not null default 'keldan',
  plan_renews date,
  provider text not null default 'paystack' check (provider in ('paystack', 'hubtel')),
  data jsonb not null default '{}',          -- brand + public business details + rent settings
  created_by uuid references auth.users on delete set null,
  created_at timestamptz not null default now()
);

-- Owner-only details (Ghana Card / registration, payout accounts): staff and tenants never see these.
create table keldan.owner_private (
  owner_id text primary key references keldan.owners on delete cascade,
  data jsonb not null default '{}'
);

-- The one company this app serves.
insert into keldan.owners (id, code, status, plan, provider, data) values ('keldan', 'KELDAN', 'approved', 'keldan', 'paystack', jsonb_build_object(
  'company', 'Keldan Properties Limited', 'tagline', 'Your Comfort, Our Priority', 'contactName', 'Keldan Properties Limited',
  'phone', '0303980439 / 0544212969', 'email', 'info@keldanproperties.com', 'address', 'No. 8 Ebenezer Lane, East Legon, Accra',
  'logo', './keldan-badge.png', 'logoWide', './keldan-logo.png', 'frontImage', '', 'setupDone', true,
  'theme', jsonb_build_object('brand', '#0b7a4f', 'accent', '#7cc242', 'font', 'Fraunces', 'radius', 'rounded', 'sidebar', 'dark', 'dark', false),
  'settings', jsonb_build_object('graceDays', 5, 'lateFeePct', 0, 'autoReminders', true, 'reminderDays', 3, 'smsSender', 'KELDAN', 'templates', jsonb_build_object(
    'reminder', 'Hello {name}, your rent of {amount} for {unit} is due on {due}. Pay easily with MoMo in the Keldan Properties app. Thank you.',
    'overdue', 'Dear {name}, your rent balance of {amount} for {unit} is overdue. Kindly pay today. – Keldan Properties Limited',
    'receipt', 'Payment received: {amount} for {unit}. Receipt {ref}. Thank you, {name}! – Keldan Properties Limited',
    'expiry', 'Hello {name}, your tenancy for {unit} ends on {due}. Call 0303980439 to renew. – Keldan Properties Limited'))));
insert into keldan.owner_private (owner_id, data) values ('keldan', '{"kyc": {}, "payoutAccounts": []}');

create table keldan.profiles (
  user_id uuid primary key references auth.users on delete cascade,
  role text not null check (role in ('owner', 'manager', 'tenant', 'admin')),
  owner_id text references keldan.owners on delete cascade,
  tenant_id text,
  name text not null,
  phone text,
  email text,
  title text,
  property_ids text[] not null default '{}',
  perms jsonb not null default '{}',
  status text not null default 'active' check (status in ('active', 'suspended')),
  created_at timestamptz not null default now(),
  check ((role = 'admin') = (owner_id is null))
);
create index profiles_owner on keldan.profiles (owner_id);

create table keldan.records (
  owner_id text not null references keldan.owners on delete cascade,
  col text not null,
  id text not null,
  data jsonb not null,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  primary key (owner_id, col, id)
);
create index records_tenant on keldan.records (owner_id, col, (data->>'tenantId'));

create table keldan.checkouts (
  id text primary key default 'ck_' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 16),
  owner_id text not null references keldan.owners on delete cascade,
  tenant_id text,
  kind text not null default 'rent' check (kind in ('rent', 'plan')),
  plan text,
  amount numeric(12, 2) not null check (amount > 0),
  method text not null check (method in ('mtn', 'telecel', 'at', 'card')),
  payer text,
  invoice_ids text[] not null default '{}',
  provider text not null,
  test boolean not null,
  status text not null default 'pending' check (status in ('pending', 'success', 'failed')),
  provider_ref text,
  pay_url text,
  error text,
  payment_id text,
  created_by uuid not null references auth.users on delete cascade,
  created_at timestamptz not null default now(),
  settled_at timestamptz
);
create index checkouts_owner on keldan.checkouts (owner_id, created_at desc);

-- ------------------------------------------------------------------ helpers
create or replace function keldan.me() returns keldan.profiles
language sql stable security definer set search_path = keldan, public as $$
  select * from keldan.profiles where user_id = auth.uid() and status = 'active'
$$;
create or replace function keldan.is_admin() returns boolean
language sql stable security definer set search_path = keldan, public as $$
  select exists (select 1 from keldan.profiles where user_id = auth.uid() and role = 'admin' and status = 'active')
$$;
create or replace function keldan.is_server() returns boolean language sql stable as $$
  select coalesce(current_setting('keldan.server', true), '') = 'on' or coalesce(auth.role(), '') = 'service_role'
$$;
create or replace function keldan.rid(prefix text) returns text language sql volatile as $$
  select prefix || '_' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 14)
$$;
create or replace function keldan.platform() returns jsonb language sql stable security definer set search_path = keldan, public as $$
  select platform from keldan.config
$$;

/** Can the signed-in account read this record? */
create or replace function keldan.can_read(p_owner text, p_col text, p_id text, p_data jsonb) returns boolean
language plpgsql stable security definer set search_path = keldan, public as $$
declare m keldan.profiles; pid text := coalesce(p_data->>'propertyId', '');
begin
  select * into m from keldan.profiles where user_id = auth.uid() and status = 'active';
  if m is null then return false; end if;
  if m.role = 'admin' then return true; end if;
  if m.owner_id is distinct from p_owner then return false; end if;
  if m.role = 'owner' then return true; end if;
  if m.role = 'manager' then
    if p_col in ('withdrawals', 'subscriptions') then return false; end if;
    if p_col = 'properties' then return p_id = any (m.property_ids); end if;
    return pid = '' or pid = any (m.property_ids);
  end if;
  -- tenant
  if p_col = 'tenants' then return p_id = m.tenant_id; end if;
  if p_col in ('leases', 'invoices', 'payments', 'maintenance') then return p_data->>'tenantId' = m.tenant_id; end if;
  if p_col = 'units' then
    return exists (select 1 from keldan.records l where l.owner_id = p_owner and l.col = 'leases' and l.data->>'tenantId' = m.tenant_id and l.data->>'unitId' = p_id);
  end if;
  if p_col in ('properties', 'notices') then
    if p_col = 'notices' and pid = '' then return true; end if;
    return exists (select 1 from keldan.records l join keldan.records u on u.owner_id = l.owner_id and u.col = 'units' and u.id = l.data->>'unitId'
                   where l.owner_id = p_owner and l.col = 'leases' and l.data->>'tenantId' = m.tenant_id
                     and u.data->>'propertyId' = case when p_col = 'properties' then p_id else pid end);
  end if;
  return false;
end $$;

/** Can the signed-in account create / change / delete this record directly? (Money records: never.) */
create or replace function keldan.can_write(p_owner text, p_col text, p_data jsonb) returns boolean
language plpgsql stable security definer set search_path = keldan, public as $$
declare m keldan.profiles; pid text := coalesce(p_data->>'propertyId', '');
begin
  if keldan.is_server() then return true; end if;
  select * into m from keldan.profiles where user_id = auth.uid() and status = 'active';
  if m is null or m.role = 'tenant' then return false; end if;
  if m.role = 'admin' then return p_col not in ('payments', 'withdrawals', 'subscriptions', 'sms'); end if;
  if m.owner_id is distinct from p_owner then return false; end if;
  if (select status from keldan.owners where id = p_owner) = 'suspended' then return false; end if;
  if m.role = 'owner' then
    return p_col in ('properties', 'units', 'tenants', 'leases', 'invoices', 'maintenance', 'expenses', 'notices', 'invites', 'alerts');
  end if;
  -- manager: only their properties, only what their permissions allow
  if pid <> '' and not pid = any (m.property_ids) then return false; end if;
  return case p_col
    when 'tenants' then coalesce((m.perms->>'tenants')::boolean, false)
    when 'leases' then coalesce((m.perms->>'tenants')::boolean, false)
    when 'units' then coalesce((m.perms->>'tenants')::boolean, false)
    when 'invoices' then coalesce((m.perms->>'payments')::boolean, false)
    when 'maintenance' then coalesce((m.perms->>'maintenance')::boolean, false)
    when 'expenses' then coalesce((m.perms->>'expenses')::boolean, false)
    when 'notices' then true
    when 'alerts' then true
    else false end;
end $$;

-- Guards: clients can never set an invoice's paid amount, forge a tenant signature or change owner status/plan.
create or replace function keldan.guard_records() returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  new.updated_by := auth.uid();
  new.data := new.data || jsonb_build_object('id', new.id, 'ownerId', new.owner_id);
  if keldan.is_server() then return new; end if;
  if new.col = 'invoices' then
    new.data := jsonb_set(new.data, '{paid}', case when tg_op = 'UPDATE' then coalesce(old.data->'paid', '0') else '0' end);
  elsif new.col = 'leases' then
    new.data := jsonb_set(new.data, '{signedTenant}', case when tg_op = 'UPDATE' then coalesce(old.data->'signedTenant', 'null') else 'null' end);
  end if;
  return new;
end $$;
create trigger records_guard before insert or update on keldan.records for each row execute function keldan.guard_records();

create or replace function keldan.guard_owners() returns trigger language plpgsql as $$
begin
  if keldan.is_server() or keldan.is_admin() then return new; end if;
  new.status := old.status; new.plan := old.plan; new.plan_renews := old.plan_renews; new.code := old.code; new.created_by := old.created_by;
  return new;
end $$;
create trigger owners_guard before update on keldan.owners for each row execute function keldan.guard_owners();

-- ------------------------------------------------------------------ row-level security
alter table keldan.config enable row level security;
alter table keldan.secrets enable row level security;
alter table keldan.owners enable row level security;
alter table keldan.owner_private enable row level security;
alter table keldan.profiles enable row level security;
alter table keldan.records enable row level security;
alter table keldan.checkouts enable row level security;

create policy config_read on keldan.config for select using (true);
create policy owners_read on keldan.owners for select using (keldan.is_admin() or id = (keldan.me()).owner_id);
create policy owners_write on keldan.owners for update
  using (keldan.is_admin() or (id = (keldan.me()).owner_id and (keldan.me()).role = 'owner'))
  with check (keldan.is_admin() or (id = (keldan.me()).owner_id and (keldan.me()).role = 'owner'));
create policy private_all on keldan.owner_private for all
  using (keldan.is_admin() or (owner_id = (keldan.me()).owner_id and (keldan.me()).role = 'owner'))
  with check (keldan.is_admin() or (owner_id = (keldan.me()).owner_id and (keldan.me()).role = 'owner'));
create policy profiles_read on keldan.profiles for select using (
  user_id = auth.uid() or keldan.is_admin() or (owner_id = (keldan.me()).owner_id and (keldan.me()).role in ('owner', 'manager')));
create policy records_read on keldan.records for select using (keldan.can_read(owner_id, col, id, data));
create policy records_insert on keldan.records for insert with check (keldan.can_write(owner_id, col, data));
create policy records_update on keldan.records for update using (keldan.can_write(owner_id, col, data)) with check (keldan.can_write(owner_id, col, data));
create policy records_delete on keldan.records for delete using (keldan.can_write(owner_id, col, data) and col not in ('invoices', 'leases') or keldan.is_admin());
create policy checkouts_read on keldan.checkouts for select using (
  created_by = auth.uid() or keldan.is_admin() or (owner_id = (keldan.me()).owner_id and (keldan.me()).role = 'owner'));

grant select on keldan.config to anon, authenticated;
grant select, update on keldan.owners to authenticated;
grant select, insert, update on keldan.owner_private to authenticated;
grant select on keldan.profiles to authenticated;
grant select, insert, update, delete on keldan.records to authenticated;
grant select on keldan.checkouts to authenticated;
grant all on all tables in schema keldan to service_role;
