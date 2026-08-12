-- Стартовые данные: Вашингтон, Seattle metro, субрегионы, каналы чата.
--
-- ZIP-коды здесь — представительная выборка по Puget Sound для разработки.
-- Полный импорт всех ZIP США (Census ZCTA / USPS) делается отдельным скриптом
-- до запуска: он нужен, чтобы пользователь из любого города попадал хотя бы в
-- лист ожидания, а не в пустой экран.

insert into states (code, name, is_live) values
  ('WA', 'Washington', true),
  ('CA', 'California', false),
  ('OR', 'Oregon',     false),
  ('IL', 'Illinois',   false),
  ('PA', 'Pennsylvania', false)
on conflict do nothing;

insert into metros (id, state_code, slug, name, is_live, launched_at) values
  ('11111111-1111-1111-1111-111111111111', 'WA', 'seattle-tacoma',
   'Сіетл–Такома', true, current_date),
  ('22222222-2222-2222-2222-222222222222', 'WA', 'spokane',
   'Спокан', false, null)
on conflict do nothing;

insert into sub_areas (metro_id, name) values
  ('11111111-1111-1111-1111-111111111111', 'South King County'),
  ('11111111-1111-1111-1111-111111111111', 'Snohomish County'),
  ('11111111-1111-1111-1111-111111111111', 'Eastside'),
  ('11111111-1111-1111-1111-111111111111', 'Seattle'),
  ('11111111-1111-1111-1111-111111111111', 'Tacoma / Pierce County');

-- Seattle metro
insert into zip_to_metro (zip, state_code, metro_id)
select z, 'WA', '11111111-1111-1111-1111-111111111111'
from unnest(array[
  -- Seattle
  '98101','98103','98105','98107','98115','98118','98122','98125','98133',
  -- Kent / Auburn / Federal Way / Renton (крупнейшая славянская концентрация)
  '98030','98031','98032','98042','98001','98002','98003','98023',
  '98055','98056','98057','98058','98059',
  -- Everett / Lynnwood / Marysville
  '98201','98203','98204','98208','98036','98037','98270','98271',
  -- Eastside
  '98004','98005','98006','98007','98008','98052','98053',
  -- Tacoma
  '98402','98404','98405','98408','98409'
]) as z
on conflict do nothing;

-- Спокан: метро заведено, но не запущено. Пользователь получит federal + WA
-- и экран листа ожидания вместо metro-слоя.
insert into zip_to_metro (zip, state_code, metro_id)
select z, 'WA', '22222222-2222-2222-2222-222222222222'
from unnest(array['99201','99202','99205','99206','99207','99208','99216']) as z
on conflict do nothing;

-- Каналы чата.
-- Federal — общие для всей страны, создаются один раз.
insert into channels (scope_level, scope_ref, topic, name) values
  ('federal', null, 'documents', 'Документи та статус'),
  ('federal', null, 'general',   'Загальний чат');

-- State — на весь Вашингтон.
insert into channels (scope_level, scope_ref, topic, name) values
  ('state', 'WA', 'general', 'Вашингтон');

-- Metro — создаются при запуске каждого нового города (см. playbook).
insert into channels (scope_level, scope_ref, topic, name) values
  ('metro', '11111111-1111-1111-1111-111111111111', 'general', 'Сіетл — загальний'),
  ('metro', '11111111-1111-1111-1111-111111111111', 'jobs',    'Сіетл — робота'),
  ('metro', '11111111-1111-1111-1111-111111111111', 'housing', 'Сіетл — житло'),
  ('metro', '11111111-1111-1111-1111-111111111111', 'kids',    'Сіетл — діти та школа');
