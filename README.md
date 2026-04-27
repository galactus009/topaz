# Topaz Trading Dashboard

Lazarus/LCL desktop GUI talking to a Thorium gateway — real-time trading dashboard for Indian markets (NSE/NFO/MCX).

## Architecture

```
Thorium gateway                       Pascal GUI (LCL/Cocoa)
─────────────────                     ──────────────────────

REST  POST /api/v1/* ◄────────────── TBroker.LTP / PlaceOrder / ...
WS    JSON tick frames ──────────►   TBroker WS reader thread
                                            │
                                            ▼
                                       CbTick / CbOrder / CbConnect / CbDisconnect
                                            │
                                            ▼
                                       TEventBus (lock-free SPSC rings)
                                       ┌──────────────────────────────┐
                                       │ GuiTicks    [SPSC 8192]      │──► tmrDrain (50ms) ──► gridWatchlist
                                       │ Orders      [SPSC 256]       │──► tmrDrain ──► gridOrders
                                       │ Status      [SPSC 64]        │──► tmrDrain ──► shpStatus/lblStatus
                                       │ StratSlots  [SPSC x16]       │──► TStrategyThread.Execute (spin)
                                       └──────────────────────────────┘
                                            ▲
GUI buttons ────────────────────────────────┘
  btnStart  ──► TBroker.Create/Connect/StreamStart
  btnStop   ──► TBroker.StreamStop/Disconnect/Free
  btnAdd    ──► TBroker.Subscribe              (sends WS subscribe frame)
  btnOrder  ──► TBroker.PlaceOrder             (POST /api/v1/placeorder)
                                            │
                                            ▼
                                  tmrPoll (2s) ──► TBroker.AvailableMargin
                                                 ──► TBroker.UsedMargin
                                                 ──► Bot.Strategy.PnL
```

### Interaction paths

1. **Thorium → GUI** (hot path): WS reader thread receives JSON tick frames →
   fires `CbTick` → writes into a lock-free `TRingBuffer` → `tmrDrain` (50ms TTimer)
   polls rings on the main thread → updates grids/labels. No locks, no allocs in
   the dispatch step.

2. **GUI → Thorium** (cold path): Button clicks call `TBroker` methods directly,
   which issue blocking HTTP POSTs to `/api/v1/*`. Only on user action.

3. **Thorium → Strategies** (hot path): `CbTick` fans out ticks to per-strategy
   SPSC rings. Each `TStrategyThread` spins on its own ring with `Sleep(1)` idle.
   Strategy calls `TBroker.PlaceOrder` for orders.

### Isolation rules

- GUI thread never touches strategy state
- Strategies never touch GUI widgets
- Both sides read from separate SPSC ring copies
- Only shared object is `TBroker` (thread-safe; HTTP calls and WS sends each
  guard their own state with a critical section)

## Files

```
topaz/
├── modules/
│   ├── Thorium.Broker.pas         ← TBroker over Thorium REST + WebSocket
│   ├── Topaz.RingBuffer.pas       ← Lock-free SPSC ring buffer
│   ├── Topaz.EventTypes.pas       ← Event records + cdecl callback trampolines
│   └── Topaz.Strategy.pas         ← Strategy base class + thread runner
├── TopazDashboard.lpr             ← Program entry point
├── TopazDashboard.lpi             ← Lazarus project file
├── MainForm.pas                   ← Dashboard form (6 pages)
├── MainForm.lfm                   ← Form layout (designer-compatible)
└── README.md                      ← This file
```

## Requirements

- A running Thorium gateway (REST on `:5000`, WebSocket on `:8765`)
- A configured `THORIUM_APIKEY`
- Lazarus 3.x with the bundled FreePascal 3.2+
- mORMot 2 — registered in Lazarus via `mormot2.lpk`

## Build

```bash
make           # debug build, Cocoa widgetset
make qt6       # debug build, Qt6 widgetset
make release   # optimized release build
```

## Quick Start

```pascal
uses Thorium.Broker;

var B: TBroker;
begin
  B := TBroker.Create('http://127.0.0.1:5000', 'your-thorium-apikey');
  try
    B.Connect;
    WriteLn(B.LTP('SBIN', exNSE):0:2);
  finally
    B.Free;
  end;
end.
```

See `examples/` for streaming, order placement, option chain, and indicator demos.
