# Модель данных

Postgres (Supabase). Схема-набросок для MVP. Акцент на трёх вещах, которые
крайне дорого достраивать позже: **scope-разметка**, **свежесть контента**,
**анонимность в нуждах**.

## География

```sql
create table states (
  code        char(2) primary key,          -- 'WA'
  name        text not null,
  is_live     boolean not null default false
);

create table metros (
  id          uuid primary key default gen_random_uuid(),
  state_code  char(2) not null references states(code),
  slug        text unique not null,          -- 'seattle-tacoma'
  name        text not null,
  is_live     boolean not null default false,
  launched_at date
);

create table sub_areas (
  id          uuid primary key default gen_random_uuid(),
  metro_id    uuid not null references metros(id),
  name        text not null                  -- 'South King County'
);

create table zip_to_metro (
  zip         char(5) primary key,
  metro_id    uuid references metros(id),    -- null = метро не запущено
  state_code  char(2) not null references states(code)
);
```

`zip_to_metro` заполняется из открытых данных (Census ZCTA / USPS) один раз
для всей страны, включая незапущенные метро. Это позволяет собирать лист
ожидания и карту расселения ещё до запуска города.

## Scope: ключевой паттерн

Каждая контентная сущность несёт пару полей:

```sql
create type scope_level as enum ('federal', 'state', 'metro');

-- scope_ref: null для federal, код штата для state, metro_id для metro
```

Один запрос отдаёт релевантный набор для любого пользователя:

```sql
where (scope_level = 'federal')
   or (scope_level = 'state' and scope_ref = :user_state)
   or (scope_level = 'metro' and scope_ref = :user_metro_id)
```

Этот же паттерн применяется к `guides`, `news`, `channels`, `orgs`.

## Гайды

```sql
create table guides (
  id                uuid primary key default gen_random_uuid(),
  scope_level       scope_level not null,
  scope_ref         text,
  category          text not null,           -- 'documents','health','housing',...
  slug              text not null,
  title             text not null,
  body              text not null,           -- markdown
  lang              char(2) not null,        -- 'uk','ru','en'
  relevant_statuses text[],                  -- null = для всех
  source_urls       text[] not null,
  last_verified_at  date not null,
  order_hint        int default 0,
  unique (slug, lang)
);

create table guide_steps (
  id        uuid primary key default gen_random_uuid(),
  guide_id  uuid not null references guides(id) on delete cascade,
  position  int not null,
  title     text not null,
  body      text
);

create table user_guide_progress (
  user_id   uuid not null references profiles(id),
  step_id   uuid not null references guide_steps(id),
  done_at   timestamptz not null default now(),
  primary key (user_id, step_id)
);
```

### Почему `last_verified_at` и `source_urls` обязательны

Иммиграционные правила меняются несколько раз в год. Без этих полей через
полгода приложение содержит враньё, и невозможно понять, какая именно часть
устарела. С ними админка автоматически показывает очередь: «12 гайдов не
проверялись 90+ дней».

Свежесть — это не метаданные, это основная фича продукта.

### Почему `lang` в БД, а не в файлах локализации

Тело гайда — это контент, а не строка интерфейса. Если завязать перевод на
i18n-файлы, добавление английской версии станет отдельным проектом. Строки
интерфейса — обычный i18n; контент — строки в БД.

## Профили и статусы

```sql
create type immigration_status as enum (
  'u4u', 'tps', 'asylum_pending', 'asylum_granted',
  'green_card', 'citizen', 'other', 'prefer_not_say'
);

create table profiles (
  id            uuid primary key references auth.users(id),
  display_name  text,
  lang          char(2) not null default 'uk',
  zip           char(5),
  metro_id      uuid references metros(id),
  state_code    char(2) references states(code),
  status        immigration_status,
  phone_verified_at timestamptz,
  trust_score   int not null default 0,
  created_at    timestamptz not null default now()
);
```

**Сознательно НЕ храним:** A-number, номера кейсов, сканы документов, полный
SSN. Статус — опциональный enum, нужный только для фильтрации контента, с
вариантом `prefer_not_say`.

## Дедлайны

```sql
create table deadlines (
  id        uuid primary key default gen_random_uuid(),
  user_id   uuid not null references profiles(id),
  kind      text not null,        -- 'status_expiry','ead_expiry','biometrics',...
  due_date  date not null,
  note      text,
  created_at timestamptz not null default now()
);
```

Даты вводит пользователь вручную. Пуши за 90 / 60 / 30 / 7 дней. Всегда
federal — не зависит от города.

## Нужды: анонимность

Самая чувствительная часть модели.

```sql
create type need_type   as enum ('money', 'goods', 'help');
create type need_status as enum ('pending_review','active','fulfilled','rejected','expired');

create table needs (
  id            uuid primary key default gen_random_uuid(),
  author_id     uuid not null references profiles(id),   -- НИКОГДА не отдаётся публично
  metro_id      uuid not null references metros(id),
  sub_area_id   uuid references sub_areas(id),
  type          need_type not null,
  title         text not null,
  description   text not null,
  amount_cents  bigint,                 -- только для type='money'
  payout_url    text,                   -- внешняя ссылка, см. ниже
  status        need_status not null default 'pending_review',
  reviewed_by   uuid references profiles(id),
  reviewed_at   timestamptz,
  expires_at    timestamptz,
  created_at    timestamptz not null default now()
);

create table need_responses (
  id           uuid primary key default gen_random_uuid(),
  need_id      uuid not null references needs(id),
  responder_id uuid not null references profiles(id),
  message      text,
  created_at   timestamptz not null default now()
);
```

### Как обеспечивается анонимность

Публичное представление — только через view, где `author_id` отсутствует:

```sql
create view needs_public as
select id, metro_id, sub_area_id, type, title, description,
       amount_cents, status, created_at
from needs
where status in ('active','fulfilled');
```

RLS: прямой `select` на таблицу `needs` запрещён обычным пользователям; автор
видит свои записи, модераторы — все.

### Ловушка: платёжная ссылка деанонимизирует

Zelle / Venmo / PayPal показывают имя и телефон получателя. Поместить
`payout_url` в анонимный пост — значит раскрыть автора первым же кликом.

Варианты, между которыми надо выбрать до реализации:

1. **Анонимность и деньги несовместимы напрямую.** Для `type='money'` автор
   явно подтверждает: «моё имя увидят те, кто перейдёт по ссылке».
2. **Посредничество НКО.** Деньги идут на счёт партнёрской организации с
   пометкой кейса. Полностью анонимно для донора, но требует партнёра.
3. **Отложенный обмен контактами.** Донор жмёт «хочу помочь» → автор получает
   запрос → сам решает, раскрыться ли. Работает для `goods` и `help` без
   оговорок.

**Рекомендация для MVP:** запустить только `goods` и `help` с вариантом 3.
Денежные нужды — в фазе 2, после появления партнёра-НКО (вариант 2). Это
снимает и юридический риск, и риск деанонимизации, и большую часть скама.

### Антифрод

- Публикация нужды только с подтверждённым телефоном (`phone_verified_at`)
- Все нужды проходят `pending_review` перед публикацией
- Лимит: не более N активных нужд на пользователя
- `trust_score` растёт за закрытые нужды и подтверждённую помощь другим
- Отметка «помогли» с подтверждением от откликнувшегося — публичный сигнал
  доверия

## Организации и специалисты

```sql
create table orgs (
  id          uuid primary key default gen_random_uuid(),
  metro_id    uuid references metros(id),      -- null = национальная
  type        text not null,        -- 'ngo','church','lawyer','doctor','accountant'
  name        text not null,
  langs       text[],
  phone       text,
  website     text,
  address     text,
  geo         geography(point),
  license_ref text,                 -- номер bar license и т.п.
  verified_at date,
  verified_by uuid references profiles(id)
);
```

Для `type='lawyer'` проверка лицензии обязательна перед публикацией — это
прямая защита от notario fraud, одной из главных проблем общины.

## Чат

```sql
create table channels (
  id          uuid primary key default gen_random_uuid(),
  scope_level scope_level not null,
  scope_ref   text,
  topic       text not null,        -- 'jobs','housing','documents','general'
  name        text not null
);

create table messages (
  id          uuid primary key default gen_random_uuid(),
  channel_id  uuid not null references channels(id),
  author_id   uuid not null references profiles(id),
  body        text not null,
  created_at  timestamptz not null default now(),
  deleted_at  timestamptz,
  deleted_by  uuid references profiles(id)
);

create table moderators (
  user_id   uuid not null references profiles(id),
  metro_id  uuid references metros(id),   -- null = глобальный модератор
  primary key (user_id, metro_id)
);
```

Каналы — по scope, а не захардкожены. Общенациональные темы живут на federal,
локальные — на metro.

## Новости

```sql
create table news (
  id                uuid primary key default gen_random_uuid(),
  scope_level       scope_level not null,
  scope_ref         text,
  title             text not null,
  summary           text not null,
  what_it_means     text,            -- «что это значит для тебя»
  relevant_statuses text[],
  source_url        text not null,
  lang              char(2) not null,
  published_at      timestamptz not null,
  approved_by       uuid references profiles(id)   -- NOT NULL перед показом
);
```

Ничего не публикуется без `approved_by`. Источники (USCIS, DHS) подтягиваются
автоматически в очередь на модерацию, но не в ленту.

## Лист ожидания

```sql
create table waitlist (
  id         uuid primary key default gen_random_uuid(),
  email      text not null,
  zip        char(5) not null,
  state_code char(2),
  metro_id   uuid references metros(id),
  created_at timestamptz not null default now()
);
```

Основной вход для данных о приоритизации следующих городов.

## Приватность: решить до запуска

Аудитория с уязвимым иммиграционным статусом. Три вопроса, на которые нужен
письменный ответ в Terms of Service **до** первого пользователя:

1. Что происходит при запросе данных от властей?
2. Сколько хранятся сообщения чата и логи? (рекомендация: короткий TTL)
3. Что удаляется при удалении аккаунта и что остаётся?

Минимизация данных — лучшая защита: то, чего нет в базе, невозможно выдать.
