-- Генерация претензий: ~2 % доставленных заказов
-- Запускать после seed.sql. Повторный запуск безопасен: старые претензии удаляются
SET search_path TO delivery;
SET timezone = 'Europe/Moscow';
SET enable_memoize = off;
SELECT setseed(0.7);

-- Идемпотентность: повторный запуск не создаёт дублей
DELETE FROM payment WHERE provider_payment_id LIKE 'CLM-%';
DELETE FROM claim;

WITH delivered AS (
    -- ~2 % доставленных заказов и время их доставки из истории
    SELECT o.id AS order_id, h.changed_at AS delivered_at
    FROM orders o
    JOIN order_status_history h ON h.order_id = o.id AND h.status = 'DELIVERED'
    WHERE o.status = 'DELIVERED'
      AND random() < 0.02
),
picked AS (
    -- одна случайная позиция в каждом заказе
    SELECT d.order_id, d.delivered_at, oi.id AS order_item_id,
           oi.price * oi.quantity AS item_total,
           random() AS r
    FROM delivered d
    CROSS JOIN LATERAL (
        SELECT id, price, quantity FROM order_item
        WHERE order_id = d.order_id
        ORDER BY random()
        LIMIT 1
    ) oi
),
prepared AS (
    SELECT *,
           CASE WHEN r < 0.60 THEN 'APPROVED'
                WHEN r < 0.85 THEN 'REJECTED'
                ELSE 'OPEN'
           END AS status,
           delivered_at + (1 + random() * 23) * interval '1 hour' AS created_at
    FROM picked
)
INSERT INTO claim (order_id, order_item_id, support_user_id, status, reason,
                   photo_urls, refund_amount, created_at, resolved_at)
SELECT
    order_id,
    order_item_id,
    CASE WHEN status <> 'OPEN' THEN 1 + floor(random() * 5)::int END,
    status,
    (ARRAY['Товар испорчен', 'Не соответствует описанию',
           'Повреждена упаковка', 'Истёк срок годности'])[1 + floor(random() * 4)::int],
    CASE WHEN random() < 0.5
         THEN ARRAY['https://cdn.example/claims/' || order_id || '-1.jpg']
         ELSE ARRAY['https://cdn.example/claims/' || order_id || '-1.jpg',
                    'https://cdn.example/claims/' || order_id || '-2.jpg']
    END,
    CASE WHEN status = 'APPROVED' THEN round(item_total, 2) END,
    created_at,
    CASE WHEN status <> 'OPEN' THEN created_at + (1 + random() * 47) * interval '1 hour' END
FROM prepared;

-- Возвраты по одобренным претензиям
INSERT INTO payment (order_id, type, status, amount, provider_payment_id, created_at)
SELECT order_id, 'REFUND', 'SUCCEEDED', refund_amount, 'CLM-' || id,
       resolved_at + interval '5 minutes'
FROM claim
WHERE status = 'APPROVED';

SELECT status, count(*), sum(refund_amount) AS refunds
FROM claim
GROUP BY status;