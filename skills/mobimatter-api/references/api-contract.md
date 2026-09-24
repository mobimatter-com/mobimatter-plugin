# MobiMatter API contract

Authoritative source is the fetched spec — `swagger.live.yaml` and
`restricted.live.json` after `mm.sh spec-refresh`, or the `.snapshot.*` files when
the fetch failed. This page is the working summary; when it and the spec disagree,
the spec wins.

**Base URL:** `https://api.mobimatter.com/mobimatter`

**Required headers on every request:**

| Header | Value |
|---|---|
| `api-key` | Merchant API key, from the Partner Portal API section |
| `merchantId` | Merchant id, from the same place |

There is one server. No sandbox, no staging. Every write is production.

## Response envelopes are not uniform

Most endpoints wrap results:

```json
{ "statusCode": 200, "result": { } }
```

**`GET /api/v2/provider/usage/{orderId}` does not.** It returns
`ProviderOrderQueryModel` at the top level with no envelope. Unwrap per endpoint;
a single global unwrap helper will silently produce `undefined` for usage.

Errors are always `ErrorResponseModel`:

```json
{ "statusCode": 400, "message": "..." }
```

There are no error codes. `message` is the only detail the API gives, so pass it
through rather than replacing it. See `errors.md`.

## Endpoints

### Catalogue

| | |
|---|---|
| **`GET /api/v2/products`** | The merchant's assigned catalogue |
| Query | `productId`, `country` (ISO-2), `region`, `provider`, `category`, `familyId` |
| Returns | `{ statusCode, result: MerchantProductResponeModel[] }` |

The query parameters are filters, **not paging** — there are no paging parameters
anywhere in this API, and a call returns the whole matching set. A product is
available to this merchant if and only if it appears here; there is no stock or
status field.

| | |
|---|---|
| **`GET /api/v2/products/{productId}/networks`** | Networks a product connects to |
| Returns | `{ statusCode, result: NetworkListAssignmentModel[] }` |

`NetworkListAssignmentModel`: `networkId`, `brand`, `tadig`, `is4G`, `is5G`,
`countryCode`.

Takes a `productId` but returns the list identified by that product's
`networkListId`, which many products share. Fetch once per distinct
`networkListId`, not once per product. `networkListId` is nullable; skip products
that have none.

### Orders

| | |
|---|---|
| **`POST /api/v2/order`** | Create — authorizes `wholesalePrice` from the wallet |
| Body | `CreateOrderModelV2` |
| Returns | `{ statusCode, result: { orderId, productCategory } }` |

```jsonc
{
  "productId": "9f0d2dcb-...",        // required
  "productCategory": "esim_realtime", // esim_realtime | esim_addon | esim_replacement | esim_delayed
  "addOnOrderIdentifier": "MM-1234",  // addon/replacement only: the ORIGINAL order
  "label": "your-internal-ref",       // portal-searchable; no personal data
  "callbackUrl": "https://..."        // esim_replacement and esim_delayed only; must be https
}
```

No idempotency key exists, and no endpoint looks an order up by `label` or by
merchant reference. A create that times out cannot be reconciled. Never retry it.

| | |
|---|---|
| **`PUT /api/v2/order/complete`** | Complete — captures the authorized amount |
| Body | `CompleteOrderModelV2`: `orderId` (required), `notes` |
| Returns | `{ statusCode, result: OrderViewModel }` |

May return `orderState: "Completed"` or `"Processing"`. `Processing` is not an
error — see `flows.md`.

If completion fails, MobiMatter voids the authorization and cancels the order
automatically. Do not send a compensating cancel.

| | |
|---|---|
| **`PUT /api/v2/order/cancel`** | Cancel an order in `Created` state |
| Body | `CancelOrderModel`: `orderId` (required), `reason` (required) |
| Returns | `{ statusCode, result: string }` |

| | |
|---|---|
| **`GET /api/v2/order/{orderId}`** | Order by id |
| Query | `returnProductDetails` (boolean) |
| Returns | `{ statusCode, result: OrderViewModel }` |

| | |
|---|---|
| **`GET /api/v2/order?iccid=`** | Order by ICCID |
| Returns | `{ statusCode, result: OrderViewModel }` |

| | |
|---|---|
| **`GET /api/v2/order/{orderId}/linked`** | Ids of the top-ups and replacements bought against an order |
| Query | `completedOnly` (boolean, default false), `completedWithRefunded` (boolean, default false) |
| Returns | `{ statusCode, result: string[] }` — order ids only |

Scoped by the `merchantId` header: the order must belong to the caller, and only
the caller's own linked orders come back. An unknown order, or one owned by another
merchant, returns **404** `order not found` — the spec lists only 200 and 400.

- Pass the **root order id**. The platform files every top-up and replacement
  directly under the original purchase, so a top-up's or replacement's own id
  returns `[]`, not its siblings.
- No flag: every state, including `Created`, `Expired` and `Cancelled`.
  `completedOnly`: `Completed` only. `completedWithRefunded`: `Completed` plus
  refunded. If both are set, `completedOnly` wins.
- Unordered. Fetch each id with `GET /api/v2/order/{orderId}` for details.

There is no endpoint that lists a merchant's orders. Orders are reachable only by
`orderId`, `iccid`, or as linked ids of a root order, so the partner must persist
every `orderId` it creates.

`OrderViewModel`: `orderId`, `orderState`, `merchantId`, `externalId`,
`currencyCode`, `created`, `updated`, `label`, `orderLineItem`.

`orderState` is one of `Created`, `Completed`, `Expired`, `Cancelled`,
`Processing`.

`orderLineItem`: `productId`, `productCategory`, `productFamilyName`,
`productFamilyId`, `title`, `provider`, `providerName`, `providerLogo`,
`retailPrice`, `wholesalePrice`, `lineItemDetails[]`, `oneClickInstall`.

`oneClickInstall`: `{ ios, android }` — deep links that launch the device's native
eSIM install. Present only when an LPA exists.

### Wallet

| | |
|---|---|
| **`GET /api/v2/merchant/balance`** | |
| Returns | `{ statusCode, result: { balance } }` |

MobiMatter emails the merchant automatically when the wallet runs low. Do not
generate a polling monitor for this.

### Notification

| | |
|---|---|
| **`POST /api/v2/email`** | MobiMatter emails the eSIM to the customer |
| Body | `NotificationRequestVm` |
| Returns | `{ statusCode, result: string }` |

```jsonc
{
  "orderId": "MM-1234",              // required
  "customer": { "id": "", "name": "", "email": "", "ccEmail": "", "phone": "" },
  "amountCharged": 12.99,
  "currency": "USD",
  "merchantOrderId": "your-ref"
}
```

Called against an order awaiting KYC, MobiMatter holds the message until the order
reaches `Completed`.

### Usage and eSIM state

| | |
|---|---|
| **`GET /api/v2/provider/usage/{orderId}`** | Unstructured usage |
| Returns | `ProviderOrderQueryModel` — **no envelope** |

`ProviderOrderQueryModel`: `orderId`, `merchantId`, `planName`, `planData`,
`validityDays`, `rechargeable`, `providerInfo { providerName, providerLogo,
message, data { activationDate, expirationDate, status, balance, phone } }`.

`rechargeable` tells you whether to offer top-ups at all.

| | |
|---|---|
| **`GET /api/v2/provider/info/{orderId}`** | Structured eSIM and package state |
| Query | `skipLocation` (boolean, default false) |
| Returns | `{ statusCode, result: StructuredEsimInfo }` |

`StructuredEsimInfo`: `ussdCode`, `esim`, `packages[]`.

`esim`: `status`, `smdpCode`, `installationDate`, `location { updated, country,
network }`, `kycStatus`, `iccid`, `phoneNumber`, `puk`, `isSuspended`, `wallet`.

`packages[]`: `name`, `associatedProductId`, `activationDate`, `expirationDate`,
`totalAllowanceMb`, `totalAllowanceMin`, `usedMb`, `usedMin`.

Pass `skipLocation=true` unless the caller actually displays last-seen country and
network.

Both of these reach the upstream provider. One attempt, cached, never retried,
never polled.

### Refund

| | |
|---|---|
| **`GET /api/v2/order/{orderId}/refund/eligibility`** | |
| Returns | `{ statusCode, result: { isEligible, fee, reason } }` |

| | |
|---|---|
| **`PUT /api/v2/order/refund`** | **Restricted** |
| Body | `RefundOrderModel`: `orderId` (required) |

Refunds the merchant's wallet. It does not refund the merchant's customer — that
remains the partner's own payment provider's job.

### Restricted endpoints

These live in `restricted_apis.json` and require elevated merchant access. No
endpoint reports whether a merchant has it; a merchant without access sees 401 or
403, which is indistinguishable from a bad key unless the error message says so.

| Endpoint | Body |
|---|---|
| `PUT /api/v2/order/refund` | `{ orderId }` |
| `POST /api/v{version}/provider/sms/{orderId}` | `{ text }` |
| `GET /api/v{version}/provider/info/{orderId}` | duplicate of the public route |

## Currency

USD only. Any other display currency is the partner's FX problem, including the
rate risk between catalogue sync and order.
