-- Смоук-тесты схемы. Прогоняются на чистой БД после всех миграций и seed.
-- Запуск: ./supabase/tests/run.sh
--
-- Покрывают то, что дороже всего сломать незаметно: трёхслойную фильтрацию,
-- анонимность нужд и защитные ограничения.

\set ON_ERROR_STOP on
\set QUIET on
\pset pager off


insert into auth.users values
  ('aaaa1111-0000-0000-0000-000000000001'),
  ('bbbb2222-0000-0000-0000-000000000002'),
  ('cccc3333-0000-0000-0000-000000000003');

insert into profiles (id, state_code, metro_id, status, phone_verified_at) values
  ('aaaa1111-0000-0000-0000-000000000001', 'WA', '11111111-1111-1111-1111-111111111111', 'u4u',        now()),
  ('bbbb2222-0000-0000-0000-000000000002', 'WA', '11111111-1111-1111-1111-111111111111', 'green_card', now());
-- C намеренно без phone_verified_at
insert into profiles (id, state_code, metro_id) values ('cccc3333-0000-0000-0000-000000000003', 'WA', '11111111-1111-1111-1111-111111111111');

insert into guides (scope_level,scope_ref,category,slug,lang,title,body,
                    source_urls,last_verified_at,is_published,relevant_statuses) values
  ('federal',null, 'documents','t-ssn',   'uk','SSN',    '.','{https://ssa.gov}',   current_date,true,null),
  ('state',  'WA', 'documents','t-wa',    'uk','WA',     '.','{https://dol.wa.gov}',current_date,true,null),
  ('state',  'CA', 'documents','t-ca',    'uk','CA',     '.','{https://dmv.ca.gov}',current_date,true,null),
  ('metro',  '11111111-1111-1111-1111-111111111111', 'housing',  't-sea',   'uk','Seattle','.','{https://x}',         current_date,true,null),
  ('federal',null, 'documents','t-tps',   'uk','TPS',    '.','{https://uscis.gov}', current_date,true,'{tps}'),
  ('federal',null, 'documents','t-draft', 'uk','Draft',  '.','{https://x}',         current_date,false,null);

grant usage on schema public to authenticated;
grant select, insert, update on all tables in schema public to authenticated;

\set QUIET off

do $$
declare n int; begin
  ---------------------------------------------------------------- гео
  select count(*) into n from resolve_zip('98030') where is_live;
  assert n = 1, 'ZIP Кента должен резолвиться в запущенное метро';

  select count(*) into n from resolve_zip('99201') where not is_live;
  assert n = 1, 'ZIP Спокана должен резолвиться в НЕзапущенное метро';

  select count(*) into n from resolve_zip('00000');
  assert n = 0, 'Неизвестный ZIP не должен резолвиться';

  ------------------------------------------------------- scope-фильтрация
  select count(*) into n from guides_for_user('WA', '11111111-1111-1111-1111-111111111111'::uuid, 'uk', 'u4u');
  assert n = 3, format('u4u в Сиэтле: ожидалось 3 гайда, получено %s', n);

  select count(*) into n from guides_for_user('WA', '11111111-1111-1111-1111-111111111111'::uuid, 'uk', 'u4u')
   where slug = 't-ca';
  assert n = 0, 'Гайд другого штата не должен попадать в выдачу';

  select count(*) into n from guides_for_user('WA', '11111111-1111-1111-1111-111111111111'::uuid, 'uk', 'u4u')
   where slug = 't-draft';
  assert n = 0, 'Неопубликованный гайд не должен попадать в выдачу';

  select count(*) into n from guides_for_user('WA', '11111111-1111-1111-1111-111111111111'::uuid, 'uk', 'tps')
   where slug = 't-tps';
  assert n = 1, 'Гайд по TPS должен показываться пользователю со статусом TPS';

  select count(*) into n from guides_for_user('WA', '11111111-1111-1111-1111-111111111111'::uuid, 'uk', 'u4u')
   where slug = 't-tps';
  assert n = 0, 'Гайд по TPS не должен показываться пользователю на U4U';

  -- пользователь из непокрытого метро всё равно получает federal + свой штат
  select count(*) into n from guides_for_user('WA', null, 'uk', 'u4u');
  assert n = 2, format('Незапущенное метро: ожидалось 2 (federal+WA), получено %s', n);
end $$;

-------------------------------------------------------------- ограничения
do $$
begin
  begin
    insert into needs (author_id, metro_id, type, title, description, amount_cents)
    values ('aaaa1111-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'money', 'x', 'x', 1000);
    assert false, 'Денежные нужды должны быть заблокированы в MVP';
  exception when check_violation then null; end;

  begin
    insert into orgs (type, name) values ('lawyer', 'Без лицензии');
    assert false, 'Адвокат без лицензии не должен добавляться';
  exception when check_violation then null; end;

  begin
    insert into guides (scope_level,category,slug,lang,title,body,
                        last_verified_at,is_published)
    values ('federal','documents','t-nosrc','uk','x','x',current_date,true);
    assert false, 'Публикация гайда без источников должна блокироваться';
  exception when check_violation then null; end;

  -- черновик без источников — разрешён
  insert into guides (scope_level,category,slug,lang,title,body,
                      last_verified_at,is_published)
  values ('federal','documents','t-nosrc2','uk','x','x',current_date,false);
end $$;

---------------------------------------------------- анонимность и изоляция
set role authenticated;
set request.jwt.claim.sub = 'aaaa1111-0000-0000-0000-000000000001';

insert into needs (author_id, metro_id, type, title, description)
values ('aaaa1111-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'goods', 'Потрібне ліжко', 'опис');
update needs set status = 'active' where author_id = 'aaaa1111-0000-0000-0000-000000000001';

do $$
declare n int; begin
  select count(*) into n from needs;
  assert n = 1, 'Автор должен видеть свою нужду';
end $$;

-- лимит активных нужд
do $$
begin
  insert into needs (author_id, metro_id, type, title, description) values
    ('aaaa1111-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'help', 'n2', 'd'),
    ('aaaa1111-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'help', 'n3', 'd');
  begin
    insert into needs (author_id, metro_id, type, title, description)
    values ('aaaa1111-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'help', 'n4', 'd');
    assert false, 'Лимит в 3 активных нужды должен срабатывать';
  exception when raise_exception then null; end;
end $$;

set request.jwt.claim.sub = 'bbbb2222-0000-0000-0000-000000000002';
do $$
declare n int; begin
  select count(*) into n from needs;
  assert n = 0, 'Чужие нужды не должны читаться напрямую — утечка author_id';

  select count(*) into n from needs_public where status = 'active';
  assert n >= 1, 'Публичная доска должна показывать активные нужды';
end $$;

-- непроверенный телефон не может публиковать
set request.jwt.claim.sub = 'cccc3333-0000-0000-0000-000000000003';
do $$
begin
  insert into needs (author_id, metro_id, type, title, description)
  values ('cccc3333-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111', 'help', 'спам', 'спам');
  assert false, 'Пользователь без подтверждённого телефона не должен публиковать';
exception when insufficient_privilege then null; end;
$$;

reset role;

-- author_id не должен существовать в публичном view даже как колонка
do $$
declare n int; begin
  select count(*) into n from information_schema.columns
   where table_name = 'needs_public' and column_name = 'author_id';
  assert n = 0, 'needs_public не должен содержать author_id';
end $$;

\echo ''
\echo '  ✓ Все смоук-тесты пройдены'
