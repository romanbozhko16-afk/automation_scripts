-- Контент со scope-разметкой: гайды, шаги, прогресс, новости, организации.
-- Ключевой паттерн: scope_level + scope_ref. Один запрос отдаёт релевантный
-- набор для пользователя из любого города.

create type scope_level as enum ('federal', 'state', 'metro');

-- scope_ref: null для federal, код штата для state, metro_id::text для metro
create or replace function scope_matches(
  p_level scope_level,
  p_ref   text,
  p_state char(2),
  p_metro uuid
) returns boolean
language sql
immutable
as $$
  select case p_level
    when 'federal' then true
    when 'state'   then p_ref = p_state
    when 'metro'   then p_ref = p_metro::text
  end;
$$;

create table guides (
  id                uuid primary key default gen_random_uuid(),
  scope_level       scope_level not null,
  scope_ref         text,
  category          text not null,
  slug              text not null,
  lang              char(2) not null,
  title             text not null,
  body              text not null,
  relevant_statuses immigration_status[],   -- null = для всех статусов
  source_urls       text[] not null default '{}',
  last_verified_at  date not null,
  order_hint        int not null default 0,
  is_published      boolean not null default false,
  unique (slug, lang),
  constraint scope_ref_consistent check (
    (scope_level = 'federal' and scope_ref is null) or
    (scope_level <> 'federal' and scope_ref is not null)
  ),
  -- cardinality, а не array_length: у пустого массива array_length = NULL,
  -- а CHECK при NULL считается пройденным — гайд без источников утёк бы в
  -- публикацию.
  constraint sources_required check (
    not is_published or cardinality(source_urls) >= 1
  )
);

create table guide_steps (
  id       uuid primary key default gen_random_uuid(),
  guide_id uuid not null references guides(id) on delete cascade,
  position int not null,
  title    text not null,
  body     text,
  unique (guide_id, position)
);

create table user_guide_progress (
  user_id uuid not null references profiles(id) on delete cascade,
  step_id uuid not null references guide_steps(id) on delete cascade,
  done_at timestamptz not null default now(),
  primary key (user_id, step_id)
);

create table news (
  id                uuid primary key default gen_random_uuid(),
  scope_level       scope_level not null,
  scope_ref         text,
  lang              char(2) not null,
  title             text not null,
  summary           text not null,
  what_it_means     text,
  relevant_statuses immigration_status[],
  source_url        text not null,
  published_at      timestamptz not null default now(),
  approved_by       uuid references profiles(id),
  approved_at       timestamptz
);

create table orgs (
  id          uuid primary key default gen_random_uuid(),
  metro_id    uuid references metros(id),   -- null = национальная
  type        text not null,   -- ngo | church | lawyer | doctor | accountant | gov
  name        text not null,
  langs       text[] not null default '{}',
  phone       text,
  website     text,
  address     text,
  lat         double precision,
  lon         double precision,
  license_ref text,            -- напр. номер WSBA для адвокатов
  notes       text,
  verified_at date,
  verified_by uuid references profiles(id),
  -- Адвокат без проверенной лицензии не публикуется: защита от notario fraud
  constraint lawyer_needs_license check (
    type <> 'lawyer' or (license_ref is not null and verified_at is not null)
  )
);

create index on guides (scope_level, scope_ref, lang) where is_published;
create index on guides (last_verified_at) where is_published;
create index on news (scope_level, scope_ref, lang, published_at desc);
create index on orgs (metro_id, type);

alter table guides              enable row level security;
alter table guide_steps         enable row level security;
alter table user_guide_progress enable row level security;
alter table news                enable row level security;
alter table orgs                enable row level security;

create policy "published guides readable" on guides
  for select using (is_published or is_moderator());

create policy "steps follow guide" on guide_steps
  for select using (
    exists (select 1 from guides g
            where g.id = guide_id and (g.is_published or is_moderator()))
  );

create policy "own progress" on user_guide_progress
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

-- Ничего не показывается в ленте без ручного одобрения.
create policy "approved news readable" on news
  for select using (approved_by is not null or is_moderator());

create policy "orgs readable" on orgs
  for select using (true);

-- Очередь на перепроверку для админки: гайд, не проверявшийся 90+ дней,
-- показывается пользователю с плашкой «требует подтверждения».
create or replace function stale_guides(p_days int default 90)
returns setof guides
language sql
stable
as $$
  select * from guides
  where is_published
    and last_verified_at < current_date - p_days
  order by last_verified_at;
$$;

-- Основной запрос ленты гайдов для пользователя.
create or replace function guides_for_user(
  p_state  char(2),
  p_metro  uuid,
  p_lang   char(2) default 'uk',
  p_status immigration_status default null
)
returns setof guides
language sql
stable
as $$
  select * from guides
  where is_published
    and lang = p_lang
    and scope_matches(scope_level, scope_ref, p_state, p_metro)
    and (relevant_statuses is null
         or p_status is null
         or p_status = any(relevant_statuses))
  order by scope_level, order_hint, title;
$$;
