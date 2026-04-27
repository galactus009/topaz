# Topaz Backlog

Items deferred from the Thorium migration (2026-04-27).

## Thorium Integration

### A. WebSocket auto-reconnect watchdog

`Thorium.Broker.pas` fires `OnDisconnect` and resets `FStreamRunning := False`
on `focConnectionClose`, but nothing reinvokes `StreamStart`. Per Thorium
spec §5.5 the client is responsible for replay on reconnect.

What to add:
- A timer (or dedicated thread) that watches `FConnected and not FStreamRunning`
  and attempts `StreamStart` with exponential backoff (start 500 ms, cap 30 s).
- On a successful reconnect `WsResubscribeAll` already fires.
- Surface "reconnecting" status to the GUI so the operator isn't surprised.

Where: `modules/Thorium.Broker.pas` (own the watchdog there) or `MainForm.pas`
(use the existing `tmrPoll` 2-second timer).

### B. `InstrumentCount` always reads 0

`TBroker.GetInstrumentCount` is hardcoded to 0; the dashboard label shows
`thorium | 0 instruments`. Thorium's `/health` doesn't carry a count and
`/metrics` is Prometheus text.

Options:
- Parse `apollo_catalog_instruments` out of `GET /metrics` (cheap regex).
- Or hit `POST /api/v1/search` with an empty query and use the result count
  as a lower bound (less accurate but JSON).

Either way: cache after first fetch, refresh on `Connect()`.

### C. `SubscribeOrders` is speculative

`TBroker.SubscribeOrders` sends `{"action":"subscribe_orders"}` over WS,
but the documented Thorium WS protocol (Client.md §5, openalgo.md §7.2)
doesn't carve out a separate orders-stream subscribe action. The current
WS dispatch treats any incoming frame with an `orderid` field as an order
event, which works only if Thorium's tick stream also carries order
updates on the same socket.

To verify against a live Thorium:
- Place an order via REST, watch the WS for an order-update frame.
- If frames don't arrive, fall back to polling `POST /api/v1/orderbook`
  every 2 s from `tmrPoll`. Keep a per-orderid hash to suppress duplicate
  callback fires.

### D. `Validity` flag dropped on PlaceOrder

`TBroker.PlaceOrder`'s `AValidity` parameter (`vDay` / `vIOC`) is not sent
to Thorium because `/api/v1/placeorder` doesn't accept a validity field.
Every current call site passes `vDay` so this is a no-op today, but if
strategies start using IOC orders, OpenAlgo will route them as DAY.

Resolution path: confirm whether OpenAlgo extends with a `validity` field
and update the JSON body, or document the limitation in the strategy
authoring guide.

### E. Strategy/PlaceOrder `strategy` tag

Thorium's `/api/v1/placeorder` accepts an optional `strategy` field that's
echoed back on order events and surfaces in `/orderbook` rows. The current
`TBroker.PlaceOrder(...; ATag)` already wires this through, but no caller
populates it — `MainForm.btnPlaceOrderClick` and the strategy base class
both pass empty tags.

What to do: have each `TStrategy` descendant pass its own name as the tag
when calling `Broker.PlaceOrder`, so order events can be correlated to the
originating strategy without a separate state lookup.

### F. Index allowlist coverage

`Thorium.Broker.ResolveExchange` now auto-detects index vs equity by
probing `/api/v1/symbol` once and caching. This handles arbitrary indices
without code changes — but the cache is per-process, not persisted.

Optional improvement: persist the cache to `config/exchange_cache.json`
on shutdown, reload on startup, so a fresh process doesn't pay the
two-probe cost on the first call to every index symbol.

### G. `tick_size` missing from search results

`MainForm.btnSearchClick` populates the `tick_size` column from the
search response, but Thorium's `/api/v1/search` doesn't include it (only
`/api/v1/symbol` does). The grid currently shows `0.05` for every row
(the fpjson default).

Either:
- Drop the column from the search grid, or
- Lazy-populate it via `/api/v1/symbol` per row when the user double-clicks.

### H. `HistoryJson` interval mapping

Apollo accepted free-form interval strings; Thorium has a fixed enum
(`1m`, `5m`, `1h`, `D`, `W`, `M`, etc. — see `/api/v1/intervals`). The
current `TBroker.HistoryJson` passes through whatever the caller hands
in. If a strategy calls with `'1d'` instead of `'D'`, Thorium 400s.

Resolution: either map common synonyms in `HistoryJson` (`1d→D`, `1w→W`)
or document the restriction.

### I. `availablecash` field absence handling

If Thorium has no broker attached, `/api/v1/funds` returns `status:error`
and `Connect()` accepts that as "auth ok, no broker". But `AvailableMargin`
and `UsedMargin` still try to call `FundsJson` and parse — they'll get
`'{}'` back and silently return 0. The GUI shows margin=0 with no
explanation.

Resolution: surface the broker-not-attached state explicitly, e.g. set
`FBrokerAttached := False` on the error, expose a property, and have the
margin label in `MainForm` say "no broker" instead of "₹0.00".
