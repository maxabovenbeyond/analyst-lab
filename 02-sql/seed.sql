-- Генерация тестовых данных: полгода работы сервиса (апрель–сентябрь 2026)
-- Запускать сразу после ddl.sql, на пустой схеме

SET search_path TO delivery;
SET timezone = 'Europe/Moscow';
SET enable_memoize = off;   -- иначе PostgreSQL может закешировать подбор товаров и выдать одинаковые корзины
SELECT setseed(0.42);       -- одинаковые «случайные» данные при каждом запуске

-- ===== 1. Магазины: подключаются постепенно с марта по июль =====
INSERT INTO shop (name, address, commission_percent, created_at)
SELECT
    (ARRAY['Фермерская лавка', 'Пекарня', 'Сырная', 'Мясная лавка', 'Овощи и фрукты',
           'Рыбный двор', 'Чайная', 'Кондитерская', 'Молочная ферма', 'Эко-маркет'])[1 + g % 10]
        || ' №' || g,
    'ул. ' || (ARRAY['Ленина', 'Мира', 'Садовая', 'Школьная', 'Лесная', 'Победы'])[1 + g % 6]
        || ', ' || (1 + g * 3 % 90),
    round((10 + random() * 5)::numeric, 2),
    timestamptz '2026-03-01 10:00' + random() * interval '150 days'
FROM generate_series(1, 50) g;

-- ===== 2. Сотрудники магазинов: 1 владелец и 2 сотрудника =====
INSERT INTO shop_user (shop_id, phone, role)
SELECT id, '+7901' || lpad(id::text, 7, '0'), 'OWNER' FROM shop;

INSERT INTO shop_user (shop_id, phone, role)
SELECT s.id, '+7902' || lpad((s.id * 10 + n)::text, 7, '0'), 'STAFF'
FROM shop s CROSS JOIN generate_series(1, 2) n;

-- ===== 3. Операторы поддержки =====
INSERT INTO support_user (name, email)
SELECT 'Оператор ' || g, 'support' || g || '@delivery.local'
FROM generate_series(1, 5) g;

-- ===== 4. Товары: по 30 на магазин =====
INSERT INTO product (shop_id, name, price, unit, in_stock)
SELECT
    s.id,
    (ARRAY['Сыр', 'Хлеб', 'Молоко', 'Творог', 'Яблоки', 'Мёд', 'Колбаса', 'Рыба', 'Пирог', 'Чай'])[1 + n % 10]
        || ' (арт. ' || n || ')',
    round((80 + random() * 1400)::numeric, 0),
    (ARRAY['шт', 'кг', 'л'])[1 + floor(random() * 3)::int],
    random() < 0.9
FROM shop s CROSS JOIN generate_series(1, 30) n;

-- ===== 5. Клиенты (даты регистрации уточним после создания заказов) =====
INSERT INTO customer (phone, name, pd_consent_at, created_at)
SELECT
    '+7903' || lpad(g::text, 7, '0'),
    (ARRAY['Анна', 'Иван', 'Мария', 'Алексей', 'Елена', 'Дмитрий', 'Ольга', 'Сергей'])[1 + g % 8],
    timestamptz '2026-04-01 00:00',
    timestamptz '2026-04-01 00:00'
FROM generate_series(1, 1500) g;

-- ===== 6. Заказы: 8 000 штук, ~10 % отмен =====
INSERT INTO orders (customer_id, shop_id, status, items_amount, delivery_fee,
                    delivery_address, cancel_reason, created_at)
SELECT
    o.customer_id,
    s.id,
    CASE WHEN o.r < 0.10 THEN 'CANCELLED' ELSE 'DELIVERED' END,
    0, 0,   -- суммы пересчитаем после создания позиций
    'ул. Клиентская, ' || (o.customer_id % 120 + 1),
    CASE WHEN o.r < 0.03 THEN 'Не оплачен'
         WHEN o.r < 0.07 THEN 'Магазин не подтвердил'
         WHEN o.r < 0.09 THEN 'Клиент отменил'
         WHEN o.r < 0.10 THEN 'Курьер не найден'
    END,
    -- случайный день между подключением магазина и концом периода, время с 9:00 до 22:00
    date_trunc('day', s.created_at + random() * (timestamptz '2026-09-30 22:00' - s.created_at))
        + interval '9 hours' + random() * interval '13 hours'
FROM (
    SELECT 1 + floor(1500 * power(random(), 2))::int AS customer_id,  -- часть клиентов заказывает часто
           1 + floor(50 * power(random(), 1.3))::int AS shop_id,      -- часть магазинов популярнее
           random() AS r
    FROM generate_series(1, 8000)
) o
JOIN shop s ON s.id = o.shop_id;

-- ===== 7. Позиции заказа: 1–5 разных товаров из магазина заказа =====
INSERT INTO order_item (order_id, product_id, quantity, price)
SELECT
    o.id,
    p.id,
    CASE WHEN p.unit = 'шт' THEN 1 + floor(random() * 3)
         ELSE round((0.3 + random() * 1.7)::numeric, 3)
    END,
    p.price
FROM orders o
CROSS JOIN LATERAL (
    SELECT id, unit, price
    FROM product
    WHERE shop_id = o.shop_id
    ORDER BY random()
    LIMIT 1 + floor(random() * 5)::int
) p;

-- ===== 8. Суммы заказа и плата за доставку (бесплатно от 2 000 ₽) =====
UPDATE orders o
SET items_amount = s.total,
    delivery_fee = CASE WHEN s.total >= 2000 THEN 0 ELSE 149 END
FROM (
    SELECT order_id, round(sum(quantity * price), 2) AS total
    FROM order_item
    GROUP BY order_id
) s
WHERE s.order_id = o.id;

-- ===== 9. Регистрация клиента — незадолго до первого заказа =====
UPDATE customer c
SET created_at    = f.first_at - interval '10 minutes',
    pd_consent_at = f.first_at - interval '10 minutes'
FROM (SELECT customer_id, min(created_at) AS first_at FROM orders GROUP BY customer_id) f
WHERE f.customer_id = c.id;

-- ===== 10. Хронология каждого заказа =====
-- max_step — до какого статуса дошёл заказ: 1 = ожидает оплаты ... 6 = доставлен
CREATE TEMP TABLE tl AS
SELECT
    id, status, cancel_reason, t0,
    t0 + d1                     AS t1,   -- оплачен
    t0 + d1 + d2                AS t2,   -- магазин принял
    t0 + d1 + d2 + d3           AS t3,   -- собран, ждём курьера
    t0 + d1 + d2 + d3 + d4      AS t4,   -- курьер забрал
    t0 + d1 + d2 + d3 + d4 + d5 AS t5,   -- доставлен
    CASE cancel_reason
        WHEN 'Не оплачен'            THEN 1
        WHEN 'Магазин не подтвердил' THEN 2
        WHEN 'Клиент отменил'        THEN 2
        WHEN 'Курьер не найден'      THEN 4
        ELSE 6
    END AS max_step,
    backup_roll
FROM (
    SELECT id, status, cancel_reason, created_at AS t0,
           (1 + random() * 4)   * interval '1 minute' AS d1,
           (1 + random() * 8)   * interval '1 minute' AS d2,
           (5 + random() * 12)  * interval '1 minute' AS d3,
           (5 + random() * 20)  * interval '1 minute' AS d4,
           (10 + random() * 30) * interval '1 minute' AS d5,
           random() < 0.03 AS backup_roll          -- ~3 % доставлено резервной службой
    FROM orders
) x;

-- ===== 11. История статусов =====
INSERT INTO order_status_history (order_id, status, changed_at, changed_by)
SELECT tl.id, s.st, s.ts, s.who
FROM tl
CROSS JOIN LATERAL (VALUES
    (1, 'AWAITING_PAYMENT', tl.t0, 'CUSTOMER'),
    (2, 'PAID',             tl.t1, 'PAYMENT_PROVIDER'),
    (3, 'ASSEMBLING',       tl.t2, 'SHOP'),
    (4, 'AWAITING_COURIER', tl.t3, 'SHOP'),
    (5, 'IN_DELIVERY',      tl.t4, 'DELIVERY_PROVIDER'),
    (6, 'DELIVERED',        tl.t5, 'DELIVERY_PROVIDER')
) AS s(step, st, ts, who)
WHERE s.step <= tl.max_step;

-- Строка отмены: время и инициатор по правилам state-диаграммы
INSERT INTO order_status_history (order_id, status, changed_at, changed_by)
SELECT
    id,
    'CANCELLED',
    CASE cancel_reason
        WHEN 'Не оплачен'            THEN t0 + interval '15 minutes'
        WHEN 'Магазин не подтвердил' THEN t1 + interval '10 minutes'
        WHEN 'Клиент отменил'        THEN t1 + interval '3 minutes'
        WHEN 'Курьер не найден'      THEN t3 + interval '45 minutes'
    END,
    CASE cancel_reason WHEN 'Клиент отменил' THEN 'CUSTOMER' ELSE 'SYSTEM' END
FROM tl
WHERE status = 'CANCELLED';

-- ===== 12. Платежи =====
-- Отклонённые попытки: ~5 % заказов и все неоплаченные
INSERT INTO payment (order_id, type, status, amount, provider_payment_id, decline_reason, created_at)
SELECT o.id, 'PAYMENT', 'DECLINED', o.items_amount + o.delivery_fee,
       'PAY-' || o.id || '-D', 'Недостаточно средств', tl.t0 + interval '30 seconds'
FROM orders o JOIN tl ON tl.id = o.id
WHERE random() < 0.05 OR o.cancel_reason = 'Не оплачен';

-- Успешные оплаты: все заказы, дошедшие до статуса «Оплачен»
INSERT INTO payment (order_id, type, status, amount, provider_payment_id, fee, created_at)
SELECT o.id, 'PAYMENT', 'SUCCEEDED', o.items_amount + o.delivery_fee, 'PAY-' || o.id,
       round((o.items_amount + o.delivery_fee) * 0.025, 2),   -- эквайринг 2,5 %
       tl.t1
FROM orders o JOIN tl ON tl.id = o.id
WHERE tl.max_step >= 2;

-- Возвраты: отменённые после оплаты
INSERT INTO payment (order_id, type, status, amount, provider_payment_id, created_at)
SELECT o.id, 'REFUND', 'SUCCEEDED', o.items_amount + o.delivery_fee, 'REF-' || o.id,
       h.changed_at + interval '1 minute'
FROM orders o
JOIN tl ON tl.id = o.id
JOIN order_status_history h ON h.order_id = o.id AND h.status = 'CANCELLED'
WHERE o.status = 'CANCELLED' AND tl.max_step >= 2;

-- ===== 13. Доставки: заказы, дошедшие до вызова курьера =====
-- Основная служба
INSERT INTO delivery (order_id, provider, provider_delivery_id, status, courier_name, cost, created_at)
SELECT id, 'MAIN', 'MAIN-' || id,
       CASE WHEN use_backup THEN 'CANCELLED' ELSE 'DELIVERED' END,
       CASE WHEN use_backup THEN NULL ELSE 'Курьер ' || (1 + floor(random() * 40))::int END,
       CASE WHEN use_backup THEN 0 ELSE round((180 + random() * 80)::numeric, 0) END,
       t3
FROM (SELECT tl.*, (max_step = 4 OR (max_step = 6 AND backup_roll)) AS use_backup
      FROM tl WHERE max_step >= 4) d;

-- Резервная служба: подключалась, когда основная не нашла курьера
INSERT INTO delivery (order_id, provider, provider_delivery_id, status, courier_name, cost, created_at)
SELECT id, 'BACKUP', 'BACKUP-' || id,
       CASE WHEN max_step = 6 THEN 'DELIVERED' ELSE 'CANCELLED' END,
       CASE WHEN max_step = 6 THEN 'Курьер Р-' || (1 + floor(random() * 15))::int END,
       CASE WHEN max_step = 6 THEN round((220 + random() * 100)::numeric, 0) ELSE 0 END,
       t3 + interval '20 minutes'
FROM tl
WHERE max_step = 4 OR (max_step = 6 AND backup_roll);

-- ===== 14. Обновить статистику для планировщика и вывести итог =====
ANALYZE;

SELECT 'shop' AS tbl, count(*) FROM shop
UNION ALL SELECT 'shop_user', count(*) FROM shop_user
UNION ALL SELECT 'product', count(*) FROM product
UNION ALL SELECT 'customer', count(*) FROM customer
UNION ALL SELECT 'orders', count(*) FROM orders
UNION ALL SELECT 'order_item', count(*) FROM order_item
UNION ALL SELECT 'payment', count(*) FROM payment
UNION ALL SELECT 'delivery', count(*) FROM delivery
UNION ALL SELECT 'order_status_history', count(*) FROM order_status_history;