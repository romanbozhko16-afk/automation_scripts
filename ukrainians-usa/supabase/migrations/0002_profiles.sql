-- Профили, роли модераторов, лист ожидания.
-- Сознательно НЕ храним: A-number, номера кейсов, сканы документов, SSN.
-- Статус нужен только для фильтрации контента и всегда может быть скрыт.

create type immigration_status as enum (
  'u4u',
  'tps',
  'asylum_pending',
  'asylum_granted',
  'green_card',
  'citizen',
  'other',
  'prefer_not_say'
);

create table profiles (
  id                uuid primary key references auth.users(id) on delete cascade,
  display_name      text,
  lang              char(2) not null default 'uk',
  zip               char(5),
  state_code        char(2) references states(code),
  metro_id          uuid references metros(id),
  sub_area_id       uuid references sub_areas(id),
  status            immigration_status,
  phone_verified_at timestamptz,
  trust_score       int not null default 0,
  is_banned         boolean not null default false,
  created_at        timestamptz not null default now()
);

-- metro_id null = глобальный модератор
create table moderators (
  user_id  uuid not null references profiles(id) on delete cascade,
  metro_id uuid references metros(id) on delete cascade,
  primary key (user_id, metro_id)
);

create unique index moderators_global_uniq
  on moderators (user_id) where metro_id is null;

create table waitlist (
  id         uuid primary key default gen_random_uuid(),
  email      text not null,
  zip        char(5) not null,
  state_code char(2) references states(code),
  metro_id   uuid references metros(id),
  created_at timestamptz not null default now(),
  unique (email, zip)
);

create index on profiles (metro_id);
create index on waitlist (metro_id);

-- Хелперы для RLS. security definer — чтобы политики могли читать
-- moderators/profiles, не упираясь в собственные политики.

create or replace function is_moderator(p_metro_id uuid default null)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from moderators
    where user_id = auth.uid()
      and (metro_id is null or metro_id = p_metro_id)
  );
$$;

create or replace function current_metro()
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select metro_id from profiles where id = auth.uid();
$$;

create or replace function can_post()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from profiles
    where id = auth.uid()
      and not is_banned
      and phone_verified_at is not null
  );
$$;

alter table profiles   enable row level security;
alter table moderators enable row level security;
alter table waitlist   enable row level security;

-- Профиль виден только владельцу и модераторам. Публичный минимум
-- (display_name) отдаётся отдельным view там, где он нужен.
create policy "own profile readable" on profiles
  for select using (id = auth.uid() or is_moderator(metro_id));

create policy "own profile writable" on profiles
  for update using (id = auth.uid()) with check (id = auth.uid());

create policy "own profile insert" on profiles
  for insert with check (id = auth.uid());

create policy "moderators readable" on moderators
  for select using (true);

-- Лист ожидания: писать может кто угодно (в т.ч. без аккаунта), читать — нет.
create policy "anyone can join waitlist" on waitlist
  for insert with check (true);
