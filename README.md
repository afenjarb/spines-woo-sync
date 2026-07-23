# WooCommerce to Twenty CRM Integration

This project synchronizes completed WooCommerce orders into a self-hosted Twenty CRM through n8n. It preserves historical purchase details, reuses customers and products, prevents duplicates, and includes two Twenty-native automations:

- a completed-order email;
- Opportunity ARR calculation (`Amount × 12`).

## Architecture

```text
WooCommerce
    │ order.updated webhook + HMAC-SHA256
    ▼
Caddy HTTPS reverse proxy
    ▼
n8n + PostgreSQL
    │ Twenty API
    ▼
Twenty CRM + PostgreSQL + Redis
```

WordPress and WooCommerce run on a separate host. Caddy, n8n, Twenty, PostgreSQL, and Redis run with Docker Compose on one Linux server. Only HTTPS/HTTP are public; databases and internal application ports remain private.

## Repository contents


| Path                             | Purpose                                            |
| -------------------------------- | -------------------------------------------------- |
| `compose.yaml`                   | n8n, Twenty, PostgreSQL, Redis, and Caddy services |
| `Caddyfile`                      | HTTPS reverse proxy configuration                  |
| `.env.example`                   | Required environment variables without values      |
| `postgres/init/01-databases.sh`  | Creates separate n8n and Twenty databases/users    |
| `n8n/woocommerce-to-twenty.json` | Sanitized, inactive n8n production workflow export |




## Deployment approach

The AWS server runs the committed Docker Compose configuration. Caddy terminates HTTPS and routes traffic to n8n and Twenty. PostgreSQL uses separate databases and users for the two applications, Redis supports Twenty, and Docker named volumes preserve all application data across restarts.

Real values live only in the server's private `.env` and application credential stores. `.env.example` documents the required variable names without values. The exported n8n workflow is intentionally inactive and excludes credentials, pinned payloads, and instance metadata.

## Reproducing the deployment

These steps document how the deployment can be reproduced from the repository.

1. Install Docker with the Compose plugin on a Linux server and clone this repository. Point the n8n and Twenty hostnames to the server; expose only `80/443` publicly and restrict SSH to the operator's IP.
2. Copy `.env.example` to `.env`, set the required host, password, and encryption values, and run `docker compose up -d`. On the first startup, PostgreSQL automatically runs `postgres/init/01-databases.sh` and creates separate n8n and Twenty users and databases.
3. Run `docker compose ps` and confirm that all services are healthy.
4. Reproduce the Twenty objects, fields, relations, and two native workflows documented below, then create a restricted API key.
5. Import the sanitized n8n workflow, attach a Crypto credential for the WooCommerce webhook secret and a Bearer Auth credential for the Twenty API key, then publish it.
6. Create an `order.updated` WooCommerce webhook using the same secret and enable the two InfinityFree-specific snippets documented below.



## Twenty data model

The deployed workspace uses this model:


| Object     | Unique key                                                    | Important relationships        |
| ---------- | ------------------------------------------------------------- | ------------------------------ |
| Person     | Registered customer: `wooCustomerId`; guest: normalized email | Person → Orders                |
| Product    | `wooCatalogId`                                                | Product → Order Items          |
| Order      | `wooOrderId`                                                  | Order → Person and Order Items |
| Order Item | `wooLineItemKey` (`orderId:itemId`)                           | Order Item → Order and Product |


Required API field names:

- **Person:** `wooCustomerId`, `emails`, `name`
- **Product:** `wooCatalogId`, `parentWooProductId`, `sku`, `currentPrice`, `description`, `name`
- **Order:** `wooOrderId`, `orderNumber`, `total`, `currencyCustom`, `completedAt`, `syncStatus`, `completedEmailAt`, `name`
- **Order Item:** `wooLineItemKey`, `productNameSnapshot`, `skuSnapshot`, `quantity`, `unitPriceSnapshot`, `lineTotal`, `variationSnapshot`, `addOnsSnapshot`, `name`
- **Relations:** Order `customer`; Order Item `order` and `product`

Order Items store purchased name, SKU, quantity, unit price, line total, variation, and add-on snapshots. These values remain historical even if the reusable Product changes later.

A restricted API key allows n8n to access only People, Products, Orders, and Order Items. The two active Twenty-native workflows are:

- **Completed order email:** trigger on Order `Sync Status`; require `COMPLETED` and an empty `Completed Email At`; send the formatted email; then set `Completed Email At`.
- **Opportunity ARR:** trigger only when Opportunity `Amount` changes; a Twenty Code action returns the same currency with `amountMicros × 12`; update `ARR`.

Twenty Code actions use `LOGIC_FUNCTION_TYPE=LOCAL` for this trusted, single-user assignment deployment.

## n8n workflow

`[n8n/woocommerce-to-twenty.json](n8n/woocommerce-to-twenty.json)` is the sanitized production workflow. In the live instance:

- the `Signature` node uses an encrypted Crypto credential containing the shared WooCommerce webhook secret.
- the Twenty HTTP Request nodes use an encrypted Bearer Auth credential containing the restricted API key.
- invalid signatures return `401`.

Credentials are deliberately absent from the exported copy.

## InfinityFree hosting constraints

InfinityFree affected two parts of the WooCommerce integration.

### Product-description enrichment

WooCommerce order line items do not include the full product description. The initial n8n approach attempted a read-only WooCommerce REST API lookup, but InfinityFree returned a JavaScript anti-bot challenge instead of JSON to server-to-server requests.

The working solution enriches the existing order webhook inside WordPress. It adds a clean `product_description` to each line item before WooCommerce signs and sends the payload:

```php
add_filter(
    'woocommerce_webhook_payload',
    static function ( $payload, $resource, $resource_id, $webhook_id ) {
        if ( 'order' !== $resource || empty( $payload['line_items'] ) ) {
            return $payload;
        }

        foreach ( $payload['line_items'] as &$item ) {
            $product = wc_get_product( absint( $item['product_id'] ?? 0 ) );

            $description = $product ? $product->get_description() : '';

            if ( '' === $description && $product ) {
                $description = $product->get_short_description();
            }

            $item['product_description'] = html_entity_decode(
                wp_strip_all_tags( $description ),
                ENT_QUOTES,
                get_bloginfo( 'charset' )
            );
        }

        unset( $item );

        return $payload;
    },
    10,
    4
);
```

This avoids another API credential and keeps the existing HMAC verification valid because WooCommerce signs the enriched body.

### Webhook delivery

InfinityFree's WordPress cron was also unreliable. A second topic-scoped snippet makes only `order.updated` webhook delivery synchronous:

```php
add_filter(
    'woocommerce_webhook_deliver_async',
    static function ( $async, $webhook ) {
        return $webhook instanceof WC_Webhook && 'order.updated' === $webhook->get_topic()
            ? false
            : $async;
    },
    10,
    2
);
```

Both snippets run through the WordPress Code Snippets plugin. The workaround is intentionally limited to this assignment host & plan.

## Sync and retry behavior

```text
Person → Products → Order (SYNCING) → Order Items → Order (COMPLETED)
```

Twenty GraphQL upserts use the unique keys above. Replaying a webhook therefore reuses the same records. If execution stops after an Order becomes `SYNCING`, retrying the same payload fills any missing Order Items and completes that same Order without duplicates.

Registered customers match by WooCommerce customer ID, with normalized email retained. Guests match by normalized email.

## Security

- HMAC-SHA256 authenticates WooCommerce webhooks.
- API keys, passwords, `.env`, private keys, and n8n credentials are excluded from Git.
- The exported workflow contains no credential references, pinned payloads, or customer data.
- PostgreSQL, Redis, n8n, and Twenty internal ports are not publicly exposed.
- SSH access is restricted to the operator's IP through the AWS security group.
- No live-system credentials are stored in the repository.

## Validation and demonstration

The submission includes a separate showcase video covering the requested demonstration scenarios.  
Video link: ++[https://drive.google.com/file/d/1jL4Gpr1dreXLXez5cTJXVBsd3vcHF1MK/view?usp=sharing](https://drive.google.com/file/d/1jL4Gpr1dreXLXez5cTJXVBsd3vcHF1MK/view?usp=sharing)++  
The implementation was also checked with signed Postman requests, real WooCommerce orders, repeated upserts, a controlled partial failure and retry, CRM relation inspection, container restart/persistence checks, and both Twenty workflow histories.

Verified cases include:

- new and returning customers;
- multiple products, variations, and paid add-ons;
- a product reused across orders;
- duplicate payload replay without duplicate records;
- partial failure followed by successful retry;
- one completed-order email with duplicate-send prevention;
- ARR for positive, zero, and empty Amount values without self-triggering.

## Known limitations and assumptions

- This is a single-host assignment deployment, not a high-availability architecture.
- Empty Opportunity Amount maps ARR to zero because Twenty retained the previous Currency value when dynamic `null` subfields were used.
- `LOGIC_FUNCTION_TYPE=LOCAL` is appropriate only for trusted workflow code. Use a sandboxed executor for untrusted or multi-user environments.
- Registered customers are identified by WooCommerce customer ID; guest matching assumes normalized email is a stable identity.
- Opportunities are independent CRM records and are not created from WooCommerce orders.

## AI use

OpenAI Codex helped split the assignment into testable stages, interpret Twenty metadata, draft n8n transformations and GraphQL mutations, diagnose webhook/context issues, and maintain documentation. All generated work was validated in the deployed WooCommerce, n8n, Twenty, and AWS environments.
