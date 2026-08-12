-- Чат. Каналы привязаны к scope, а не захардкожены под конкретный город:
-- federal-каналы общие для всей страны, metro-каналы создаются при запуске
-- нового города.

create table channels (
  id          uuid primary key default gen_random_uuid(),
  scope_level scope_level not null,
  scope_ref   text,
  topic       text not null,   -- general | jobs | housing | documents | kids
  name        text not null,
  is_archived boolean not null default false,
  created_at  timestamptz not null default now(),
  constraint scope_ref_consistent check (
    (scope_level = 'federal' and scope_ref is null) or
    (scope_level <> 'federal' and scope_ref is not null)
  )
);

create table messages (
  id         uuid primary key default gen_random_uuid(),
  channel_id uuid not null references channels(id) on delete cascade,
  author_id  uuid not null references profiles(id) on delete cascade,
  body       text not null,
  created_at timestamptz not null default now(),
  deleted_at timestamptz,
  deleted_by uuid references profiles(id)
);

create table reports (
  id          uuid primary key default gen_random_uuid(),
  reporter_id uuid not null references profiles(id) on delete cascade,
  message_id  uuid references messages(id) on delete cascade,
  need_id     uuid references needs(id) on delete cascade,
  reason      text not null,
  resolved_at timestamptz,
  resolved_by uuid references profiles(id),
  created_at  timestamptz not null default now(),
  constraint one_target check (num_nonnulls(message_id, need_id) = 1)
);

create index on channels (scope_level, scope_ref) where not is_archived;
create index on messages (channel_id, created_at desc) where deleted_at is null;
create index on reports (resolved_at) where resolved_at is null;

alter table channels enable row level security;
alter table messages enable row level security;
alter table reports  enable row level security;

create policy "channels readable" on channels
  for select using (not is_archived);

-- Сообщения видны участникам канала, соответствующего локации пользователя.
create policy "messages readable in own scope" on messages
  for select using (
    deleted_at is null
    and exists (
      select 1 from channels c, profiles p
      where c.id = channel_id
        and p.id = auth.uid()
        and scope_matches(c.scope_level, c.scope_ref, p.state_code, p.metro_id)
    )
  );

create policy "verified users can write" on messages
  for insert with check (author_id = auth.uid() and can_post());

-- Удаление — мягкое, автором или модератором.
create policy "author or moderator deletes" on messages
  for update using (author_id = auth.uid() or is_moderator(current_metro()));

create policy "can report" on reports
  for insert with check (reporter_id = auth.uid());

create policy "moderators read reports" on reports
  for select using (is_moderator() or reporter_id = auth.uid());
