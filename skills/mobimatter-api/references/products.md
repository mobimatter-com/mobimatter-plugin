# Products, categories and field meanings

## Categories

| `productCategory` | Meaning |
|---|---|
| `esim_realtime` | New eSIM sale. Returns a fresh QR and LPA. |
| `esim_addon` | Top-up. Adds a package to an existing eSIM of the same product family. |
| `esim_replacement` | Replacement. New QR, existing package moved onto it. |
| `esim_delayed` | KYC eSIM. Requires identity verification before activation; the only category that returns `KYC_URL`. |
| `physical_sim` | **Retired.** No longer sold. May still appear on historical orders. |

Type `productCategory` as an open string. A closed enum or union throws on historical
orders carrying retired categories, and again on whatever category is added after this
file was written. Only the categories above are sold; anything else you encounter on a
read path is historical and must not break parsing.

## Product families

Every product carries a `productFamilyId`. Two products can top up one another if
and only if they share it. To find the top-ups available for a product:

```
GET /api/v2/products?category=esim_addon&familyId=<the product's productFamilyId>
```

## Availability

`MerchantProductResponeModel` has no stock, status or availability field. A product
is available to this merchant if and only if `GET /api/v2/products` returns it.

Absence therefore means unassigned or withdrawn — but only when the call itself
succeeded. A failed call is not an empty catalogue. See `flows.md`.

## Caching

`updated` is the cache-busting key: when it changes, re-read the product. `created`
and `updated` are ISO-8601.

## `MerchantProductResponeModel` fields

| Field | Notes |
|---|---|
| `productId` | The id you order with. Key the merchant's catalogue on this. |
| `uniqueId` | Always a copy of `productId` — the partner API overwrites it on every product it returns. Ignore it. |
| `rank` | MobiMatter quality score, higher is better. Useful for sorting. |
| `productCategoryId` / `productCategory` | See table above |
| `productFamilyId` / `productFamilyName` | Top-up compatibility |
| `networkListId` | Nullable. Identifies a shared network list, not a per-product one. |
| `providerId` / `providerName` / `providerLogo` | |
| `retailPrice` | The merchant's own selling price, set in the Partner Portal |
| `wholesalePrice` | What the wallet is charged. This is the number that matters. |
| `currencyCode` | USD |
| `regions` / `countries` | `countries` is ISO-2 |
| `displayAttributes` | Key/value array. Undocumented; usually empty. |
| `productDetails` | Name/value array — see below |

## `productDetails` keys

An array of `{ name, value }`, all values strings. Parse at sync time, not per
request.

| `name` | Value |
|---|---|
| `PLAN_TITLE` | Display title, e.g. `Vietnam 60 GB` |
| `PLAN_DATA_LIMIT` | Numeric amount, e.g. `60` |
| `PLAN_DATA_UNIT` | Unit for the above, e.g. `GB` |
| `PLAN_VALIDITY` | **Hours**, not days. `360` is 15 days. |
| `PLAN_DETAILS` | JSON string: `{ heading, description, items[] }` |
| `TAGS` | JSON string: `[{ color, item }]` |

`PLAN_DETAILS` and `TAGS` are JSON *inside* a string field — parse twice.

### Validity starts at installation

`PLAN_VALIDITY` counts from when the customer installs and activates the eSIM, not
from purchase. Deriving an expiry date from the order's `created` timestamp is
wrong for every customer who does not install immediately.

Show validity as a duration until the eSIM is live. Once it is, read the real
`activationDate` and `expirationDate` from `GET /api/v2/provider/info/{orderId}`.

## `lineItemDetails` keys

On `orderLineItem` of a completed order. Also `{ name, value }` pairs.

| `name` | Value |
|---|---|
| `LOCAL_PROFILE_ASSISTANT` | The LPA string, `LPA:1$smdp.host$MATCHING-ID`. The canonical activation credential. |
| `QR_CODE` | `data:image/png;base64,...` — render directly |
| `ICCID` | eSIM identifier; also the key for `GET /api/v2/order?iccid=` |
| `SMDP_ADDRESS` | SM-DP+ host |
| `ACTIVATION_CODE` | Matching id portion |
| `ACCESS_POINT_NAME` | APN, where the provider requires manual setup |
| `PHONE_NUMBER` | Where the product has one |
| `KYC_URL` | Present on `esim_delayed` orders in `Processing`. Send the customer here. |

Not every key appears on every product. Treat the array as a lookup, never as a
fixed-position tuple.

Alongside these, `orderLineItem.oneClickInstall` gives `{ ios, android }` deep
links that launch the device's native eSIM installer — a better default than
showing a QR code to someone already on their phone. Present only when an LPA
exists.
