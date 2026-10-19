#!/usr/bin/env bash
# Создаёт коллекцию Bruno с автотестами API в 03-rest/tests/delivery-api
set -e
ROOT=~/projects/analyst-lab/03-rest/tests/delivery-api
mkdir -p "$ROOT/environments" "$ROOT/01-card" "$ROOT/02-shop-orders" "$ROOT/03-cancel" "$ROOT/04-webhook"
cd "$ROOT"

# ---------- коллекция и окружение ----------
cat > bruno.json <<'EOF'
{
  "version": "1",
  "name": "Delivery API",
  "type": "collection",
  "ignore": ["node_modules", ".git"]
}
EOF

cat > environments/local.bru <<'EOF'
vars {
  baseUrl: http://localhost:8000
  orderId: 1
  customerId: 1
  shopId: 1
}
EOF

# ================= 01. КАРТОЧКА ЗАКАЗА =================
cat > 01-card/01-no-token.bru <<'EOF'
meta {
  name: 01 Без токена → 401
  type: http
  seq: 1
}

get {
  url: {{baseUrl}}/v1/orders/{{orderId}}
  body: none
  auth: none
}

tests {
  test("код 401", function () {
    expect(res.status).to.equal(401);
  });
  test("ошибка в формате Problem Details", function () {
    expect(res.getHeader("content-type")).to.include("application/problem+json");
    expect(res.body.status).to.equal(401);
    expect(res.body.title).to.be.a("string");
  });
}
EOF

cat > 01-card/02-support.bru <<'EOF'
meta {
  name: 02 Поддержка видит любой заказ → 200
  type: http
  seq: 2
}

get {
  url: {{baseUrl}}/v1/orders/{{orderId}}
  body: none
  auth: bearer
}

auth:bearer {
  token: support
}

tests {
  test("код 200", function () {
    expect(res.status).to.equal(200);
  });
  test("вернулся именно запрошенный заказ", function () {
    expect(res.body.id).to.equal(Number(bru.getEnvVar("orderId")));
  });
  test("все обязательные поля схемы Order на месте", function () {
    ["id", "shop_id", "status", "items_amount", "delivery_fee", "created_at"].forEach(function (f) {
      expect(res.body).to.have.property(f);
    });
  });
  test("статус из списка OrderStatus", function () {
    expect(["AWAITING_PAYMENT", "PAID", "ASSEMBLING", "AWAITING_COURIER",
            "IN_DELIVERY", "DELIVERED", "CANCELLED"]).to.include(res.body.status);
  });
  test("в карточке есть позиции", function () {
    expect(res.body.items).to.be.an("array").that.is.not.empty;
  });
  test("customer_id наружу не отдаётся (его нет в контракте)", function () {
    expect(res.body).to.not.have.property("customer_id");
  });
}
EOF

cat > 01-card/03-owner.bru <<'EOF'
meta {
  name: 03 Владелец видит свой заказ → 200
  type: http
  seq: 3
}

get {
  url: {{baseUrl}}/v1/orders/{{orderId}}
  body: none
  auth: bearer
}

auth:bearer {
  token: customer-{{customerId}}
}

tests {
  test("код 200", function () {
    expect(res.status).to.equal(200);
  });
}
EOF

cat > 01-card/04-foreign-customer.bru <<'EOF'
meta {
  name: 04 Чужой клиент → 404 (скрываем существование)
  type: http
  seq: 4
}

get {
  url: {{baseUrl}}/v1/orders/{{orderId}}
  body: none
  auth: bearer
}

auth:bearer {
  token: customer-999999
}

tests {
  test("код 404, а не 403", function () {
    expect(res.status).to.equal(404);
  });
  test("Problem Details", function () {
    expect(res.getHeader("content-type")).to.include("application/problem+json");
  });
}
EOF

cat > 01-card/05-not-found.bru <<'EOF'
meta {
  name: 05 Несуществующий заказ → 404
  type: http
  seq: 5
}

get {
  url: {{baseUrl}}/v1/orders/99999999
  body: none
  auth: bearer
}

auth:bearer {
  token: support
}

tests {
  test("код 404", function () {
    expect(res.status).to.equal(404);
  });
}
EOF

cat > 01-card/06-bad-id.bru <<'EOF'
meta {
  name: 06 id не число → 400
  type: http
  seq: 6
}

get {
  url: {{baseUrl}}/v1/orders/abc
  body: none
  auth: bearer
}

auth:bearer {
  token: support
}

tests {
  test("код 400", function () {
    expect(res.status).to.equal(400);
  });
}
EOF

# ================= 02. ЗАКАЗЫ МАГАЗИНА =================
cat > 02-shop-orders/01-first-page.bru <<'EOF'
meta {
  name: 01 Первая страница → 200 + курсор
  type: http
  seq: 1
}

get {
  url: {{baseUrl}}/v1/shops/{{shopId}}/orders?limit=3
  body: none
  auth: bearer
}

auth:bearer {
  token: shop-{{shopId}}
}

script:post-response {
  // запоминаем курсор и id заказов для следующего запроса
  bru.setVar("cursor", res.body.next_cursor);
  bru.setVar("page1Ids", JSON.stringify(res.body.items.map(function (o) { return o.id; })));
}

tests {
  test("код 200", function () {
    expect(res.status).to.equal(200);
  });
  test("ровно 3 заказа (limit=3)", function () {
    expect(res.body.items).to.have.lengthOf(3);
  });
  test("есть курсор следующей страницы", function () {
    expect(res.body.next_cursor).to.be.a("string");
  });
  test("все заказы этого магазина", function () {
    var shopId = Number(bru.getEnvVar("shopId"));
    res.body.items.forEach(function (o) { expect(o.shop_id).to.equal(shopId); });
  });
  test("сортировка: сначала новые", function () {
    var dates = res.body.items.map(function (o) { return o.created_at; });
    for (var i = 1; i < dates.length; i++) {
      expect(new Date(dates[i - 1]) >= new Date(dates[i])).to.equal(true);
    }
  });
}
EOF

cat > 02-shop-orders/02-second-page.bru <<'EOF'
meta {
  name: 02 Вторая страница по курсору → без повторов
  type: http
  seq: 2
}

get {
  url: {{baseUrl}}/v1/shops/{{shopId}}/orders?limit=3&cursor={{cursor}}
  body: none
  auth: bearer
}

auth:bearer {
  token: shop-{{shopId}}
}

tests {
  test("код 200", function () {
    expect(res.status).to.equal(200);
  });
  test("заказы не повторяют первую страницу", function () {
    var page1 = JSON.parse(bru.getVar("page1Ids"));
    res.body.items.forEach(function (o) { expect(page1).to.not.include(o.id); });
  });
}
EOF

cat > 02-shop-orders/03-foreign-shop.bru <<'EOF'
meta {
  name: 03 Чужой магазин → 403
  type: http
  seq: 3
}

get {
  url: {{baseUrl}}/v1/shops/{{shopId}}/orders
  body: none
  auth: bearer
}

auth:bearer {
  token: shop-999
}

tests {
  test("код 403 (магазин не секрет, поэтому не 404)", function () {
    expect(res.status).to.equal(403);
  });
}
EOF

cat > 02-shop-orders/04-limit-0.bru <<'EOF'
meta {
  name: 04 Граница limit=0 → 400
  type: http
  seq: 4
}

get {
  url: {{baseUrl}}/v1/shops/{{shopId}}/orders?limit=0
  body: none
  auth: bearer
}

auth:bearer {
  token: shop-{{shopId}}
}

tests {
  test("код 400", function () {
    expect(res.status).to.equal(400);
  });
}
EOF

cat > 02-shop-orders/05-limit-1.bru <<'EOF'
meta {
  name: 05 Граница limit=1 → 200, один заказ
  type: http
  seq: 5
}

get {
  url: {{baseUrl}}/v1/shops/{{shopId}}/orders?limit=1
  body: none
  auth: bearer
}

auth:bearer {
  token: shop-{{shopId}}
}

tests {
  test("код 200", function () {
    expect(res.status).to.equal(200);
  });
  test("ровно один заказ", function () {
    expect(res.body.items).to.have.lengthOf(1);
  });
}
EOF

cat > 02-shop-orders/06-limit-100.bru <<'EOF'
meta {
  name: 06 Граница limit=100 → 200
  type: http
  seq: 6
}

get {
  url: {{baseUrl}}/v1/shops/{{shopId}}/orders?limit=100
  body: none
  auth: bearer
}

auth:bearer {
  token: shop-{{shopId}}
}

tests {
  test("код 200", function () {
    expect(res.status).to.equal(200);
  });
  test("не больше 100 заказов", function () {
    expect(res.body.items.length).to.be.at.most(100);
  });
}
EOF

cat > 02-shop-orders/07-limit-101.bru <<'EOF'
meta {
  name: 07 Граница limit=101 → 400
  type: http
  seq: 7
}

get {
  url: {{baseUrl}}/v1/shops/{{shopId}}/orders?limit=101
  body: none
  auth: bearer
}

auth:bearer {
  token: shop-{{shopId}}
}

tests {
  test("код 400", function () {
    expect(res.status).to.equal(400);
  });
}
EOF

cat > 02-shop-orders/08-bad-status.bru <<'EOF'
meta {
  name: 08 Неизвестный статус → 400
  type: http
  seq: 8
}

get {
  url: {{baseUrl}}/v1/shops/{{shopId}}/orders?status=FOO
  body: none
  auth: bearer
}

auth:bearer {
  token: shop-{{shopId}}
}

tests {
  test("код 400", function () {
    expect(res.status).to.equal(400);
  });
}
EOF

cat > 02-shop-orders/09-bad-cursor.bru <<'EOF'
meta {
  name: 09 Испорченный курсор → 400
  type: http
  seq: 9
}

get {
  url: {{baseUrl}}/v1/shops/{{shopId}}/orders?cursor=garbage
  body: none
  auth: bearer
}

auth:bearer {
  token: shop-{{shopId}}
}

tests {
  test("код 400", function () {
    expect(res.status).to.equal(400);
  });
}
EOF

# ================= 03. ОТМЕНА (без изменения данных) =================
cat > 03-cancel/01-shop-forbidden.bru <<'EOF'
meta {
  name: 01 Магазин не может cancel → 403
  type: http
  seq: 1
}

post {
  url: {{baseUrl}}/v1/orders/{{orderId}}/cancel
  body: json
  auth: bearer
}

auth:bearer {
  token: shop-{{shopId}}
}

body:json {
  {
    "reason": "Нет товара"
  }
}

tests {
  test("код 403", function () {
    expect(res.status).to.equal(403);
  });
}
EOF

cat > 03-cancel/02-empty-body.bru <<'EOF'
meta {
  name: 02 Без причины → 422
  type: http
  seq: 2
}

post {
  url: {{baseUrl}}/v1/orders/{{orderId}}/cancel
  body: json
  auth: bearer
}

auth:bearer {
  token: customer-{{customerId}}
}

body:json {
  {}
}

tests {
  test("код 422", function () {
    expect(res.status).to.equal(422);
  });
  test("в описании ошибки упомянуто поле reason", function () {
    expect(res.body.detail).to.include("reason");
  });
}
EOF

cat > 03-cancel/03-delivered-conflict.bru <<'EOF'
meta {
  name: 03 Отмена доставленного → 409
  type: http
  seq: 3
}

post {
  url: {{baseUrl}}/v1/orders/{{orderId}}/cancel
  body: json
  auth: bearer
}

auth:bearer {
  token: support
}

body:json {
  {
    "reason": "Автотест"
  }
}

tests {
  test("код 409", function () {
    expect(res.status).to.equal(409);
  });
  test("в описании указан текущий статус", function () {
    expect(res.body.detail).to.include("DELIVERED");
  });
}
EOF

# ================= 04. ВЕБХУК =================
cat > 04-webhook/01-bad-signature.bru <<'EOF'
meta {
  name: 01 Поддельная подпись → 401
  type: http
  seq: 1
}

post {
  url: {{baseUrl}}/v1/webhooks/payments
  body: json
  auth: none
}

headers {
  X-Signature: 0000000000000000000000000000000000000000000000000000000000000000
}

body:json {
  {
    "event_id": "evt_bruno",
    "type": "payment.succeeded",
    "provider_payment_id": "PAY-BRUNO",
    "order_id": 1,
    "amount": 100.0,
    "occurred_at": "2026-10-16T10:00:00Z"
  }
}

tests {
  test("код 401", function () {
    expect(res.status).to.equal(401);
  });
}
EOF

echo "Коллекция создана: $ROOT"