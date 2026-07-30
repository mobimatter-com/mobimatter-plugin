# Order completion webhooks

Full published detail, including the public key and per-language verification
samples, is at
<https://docs.mobimatter.com/docs/mobimatter/order-completion-webhooks>. This page
covers what the generated handler must do.

## When they fire

Pass `callbackUrl` (HTTPS, validated against `^https://.*`) when creating an order.
Honoured for **`esim_replacement` and `esim_delayed` only** — other categories
ignore it silently.

The webhook fires as soon as the order completes. For providers whose replacement
completes synchronously that is essentially immediate; for 3HK and for KYC orders it
is later. Because it behaves identically in both cases, treat the webhook as the
source of truth for completion and the `PUT /order/complete` response as an early
signal.

## Payload

```jsonc
{
  "eventType": "order.esim_replacement.completed",
  "signature": "base64-encoded-rsa-sha256-signature",
  "eventData": { /* same shape as GET /api/v2/order/{orderId} */ }
}
```

## Verification

Signature is RSA-SHA256, base64, verified with MobiMatter's public key — published
in the guide above. No shared secret.

The signing string is three fields joined by dots, in this fixed order:

```
{eventData.orderId}.{eventData.merchantId}.{eventData.orderLineItem.providerName}
```

Reject with 401 when verification fails.

## Handler requirements

**Verify, record, return 200, then process.** MobiMatter retries on any non-2xx:
immediate, ~30s, ~1m, ~5m, ~15m, then ~30m intervals to attempt 8 — roughly a two
hour window. A handler that provisions, writes to a database and sends email inline
can exceed the delivery timeout and trigger retries for an event it did in fact
process.

Hand the work to whatever queue or job runner the project already has. If it has
none, process inline, keep it minimal, and say so in your report.

**Be idempotent on `orderId`.** The same webhook can arrive more than once — from a
retry, and separately because for synchronous providers the callback can land while
the `complete` call is still returning. A partner that fulfils on both paths
processes the same completion twice. Key on `eventData.orderId` and ignore repeats.

**Return 200 on success.** Any non-2xx triggers the retry schedule.

## Fallback

After the retry window is exhausted the webhook is marked failed. Poll
`GET /api/v2/order/{orderId}` as the fallback — this is a MobiMatter-side read and
is not subject to the usage-endpoint polling rules.

Polling is the fallback, not the primary mechanism. Do not generate a poller for
orders whose category supports `callbackUrl` unless the webhook route genuinely
cannot be exposed — for example a local-only development environment or a partner
with no public ingress. Say which case applies in your report.
