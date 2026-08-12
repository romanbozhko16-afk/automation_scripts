-- Доска нужд с анонимностью + трекер дедлайнов.
--
-- АНОНИМНОСТЬ: author_id никогда не покидает сервер. Публично отдаётся
-- только view needs_public. Прямой select на needs закрыт RLS: автор видит
-- своё, модератор — всё в своём метро.
--
-- ДЕНЬГИ: в MVP отключены. Zelle/Venmo/PayPal показывают имя и телефон
-- получателя — платёжная ссылка в анонимном посте раскрывает автора первым
-- же кликом. Денежные нужды включаются в Фазе 2 через счёт партнёра-НКО.
-- Контракт mvp_no_money снимается тогда же.

create type need_type   as enum ('money', 'goods', 'help');
create type need_status as enum (
  'pending_review', 'active', 'fulfilled', 'rejected', 'expired'
);

create table needs (
  id           uuid primary key default gen_random_uuid(),
  author_id    uuid not null references profiles(id) on delete cascade,
  metro_id     uuid not null references metros(id),
  sub_area_id  uuid references sub_areas(id),
  type         need_type not null,
  title        text not null,
  description  text not null,
  amount_cents bigint,
  status       need_status not null default 'pending_review',
  reviewed_by  uuid references profiles(id),
  reviewed_at  timestamptz,
  expires_at   timestamptz not null default (now() + interval '30 days'),
  created_at   timestamptz not null default now(),

  constraint mvp_no_money check (type <> 'money'),
  constraint amount_only_for_money check (
    (type = 'money') = (amount_cents is not null)
  )
);

-- Отклик. Контакты НЕ раскрываются автоматически: автор сам решает,
-- принять ли отклик, и только после accepted стороны видят друг друга.
create table need_responses (
  id           uuid primary key default gen_random_uuid(),
  need_id      uuid not null references needs(id) on delete cascade,
  responder_id uuid not null references profiles(id) on delete cascade,
  message      text,
  accepted_at  timestamptz,
  created_at   timestamptz not null default now(),
  unique (need_id, responder_id)
);

create table deadlines (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references profiles(id) on delete cascade,
  kind       text not null,   -- status_expiry | ead_expiry | biometrics | custom
  due_date   date not null,
  note       text,
  created_at timestamptz not null default now()
);

create index on needs (metro_id, status, created_at desc);
create index on needs (author_id);
create index on need_responses (need_id);
create index on deadlines (user_id, due_date);

-- Анти-спам: не более 3 активных нужд на пользователя.
create or replace function check_need_limit()
returns trigger
language plpgsql
as $$
begin
  if (select count(*) from needs
      where author_id = new.author_id
        and status in ('pending_review', 'active')) >= 3 then
    raise exception 'Достигнут лимит активных нужд (3)';
  end if;
  return new;
end;
$$;

create trigger needs_limit
  before insert on needs
  for each row execute function check_need_limit();

-- Публичное представление: author_id отсутствует физически.
create view needs_public
with (security_invoker = false) as
  select id, metro_id, sub_area_id, type, title, description,
         amount_cents, status, created_at, expires_at
  from needs
  where status in ('active', 'fulfilled')
    and expires_at > now();

grant select on needs_public to anon, authenticated;

alter table needs          enable row level security;
alter table need_responses enable row level security;
alter table deadlines      enable row level security;

-- Прямой доступ к needs: только свои + модераторы метро.
create policy "own or moderated needs" on needs
  for select using (author_id = auth.uid() or is_moderator(metro_id));

-- Публиковать может только пользователь с подтверждённым телефоном.
-- Статус всегда стартует с pending_review — минуя модерацию не пройти.
create policy "verified users can post needs" on needs
  for insert with check (
    author_id = auth.uid()
    and can_post()
    and status = 'pending_review'
  );

create policy "author or moderator updates need" on needs
  for update using (author_id = auth.uid() or is_moderator(metro_id));

-- Откликаться может любой авторизованный; автор видит отклики на свои нужды.
create policy "responder or need author" on need_responses
  for select using (
    responder_id = auth.uid()
    or exists (select 1 from needs n
               where n.id = need_id
                 and (n.author_id = auth.uid() or is_moderator(n.metro_id)))
  );

create policy "can respond" on need_responses
  for insert with check (responder_id = auth.uid() and can_post());

create policy "own deadlines" on deadlines
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());
