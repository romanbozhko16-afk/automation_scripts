-- Гео-иерархия: Country > State > Metro > Sub-area
-- ZIP-коды заполняются для всей страны, включая незапущенные метро —
-- это позволяет собирать лист ожидания до запуска города.

create extension if not exists "pgcrypto";

create table states (
  code       char(2) primary key,
  name       text not null,
  is_live    boolean not null default false
);

create table metros (
  id          uuid primary key default gen_random_uuid(),
  state_code  char(2) not null references states(code),
  slug        text unique not null,
  name        text not null,
  is_live     boolean not null default false,
  launched_at date,
  created_at  timestamptz not null default now()
);

create table sub_areas (
  id       uuid primary key default gen_random_uuid(),
  metro_id uuid not null references metros(id) on delete cascade,
  name     text not null
);

-- metro_id null = ZIP известен, но метро ещё не запущено.
-- Пользователь всё равно получает federal-слой и попадает в лист ожидания.
create table zip_to_metro (
  zip        char(5) primary key,
  state_code char(2) not null references states(code),
  metro_id   uuid references metros(id)
);

create index on metros (state_code);
create index on sub_areas (metro_id);
create index on zip_to_metro (metro_id);

-- Справочники читают все, включая неавторизованных: онбординг по ZIP
-- происходит до создания аккаунта.
alter table states       enable row level security;
alter table metros       enable row level security;
alter table sub_areas    enable row level security;
alter table zip_to_metro enable row level security;

create policy "geo readable by everyone" on states       for select using (true);
create policy "geo readable by everyone" on metros       for select using (true);
create policy "geo readable by everyone" on sub_areas    for select using (true);
create policy "geo readable by everyone" on zip_to_metro for select using (true);

-- Резолв ZIP -> локация. Единственная точка входа онбординга.
create or replace function resolve_zip(p_zip char(5))
returns table (
  state_code char(2),
  state_name text,
  metro_id   uuid,
  metro_name text,
  is_live    boolean
)
language sql
stable
as $$
  select z.state_code,
         s.name,
         z.metro_id,
         m.name,
         coalesce(m.is_live, false)
  from zip_to_metro z
  join states s on s.code = z.state_code
  left join metros m on m.id = z.metro_id
  where z.zip = p_zip;
$$;
