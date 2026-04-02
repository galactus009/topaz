# Topaz Trading Dashboard

Lazarus/LCL desktop GUI for libapollo — real-time trading dashboard for Indian markets (NSE/NFO/MCX).

## Architecture

```
Rust (libapollo)                    Pascal GUI (LCL/Cocoa)
─────────────────                   ──────────────────────

                    cdecl callbacks
WS tick data  ───────────────────►  CbTick()
WS order data ───────────────────►  CbOrder()
WS connect    ───────────────────►  CbConnect()
WS disconnect ───────────────────►  CbDisconnect()
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
GUI buttons ────────────────────────────┘
  btnStart  ──► TBroker.Create/Connect/StreamStart   (direct FFI)
  btnStop   ──► TBroker.StreamStop/Disconnect/Free   (direct FFI)
  btnAdd    ──► TBroker.Subscribe                    (direct FFI)
  btnOrder  ──► TBroker.PlaceOrder                   (direct FFI)
                                        │
                                        ▼
                              tmrPoll (2s) ──► TBroker.AvailableMargin
                                             ──► TBroker.UsedMargin
                                             ──► Bot.Strategy.PnL
```

### Interaction paths

1. **Rust → GUI** (hot path): Rust WS thread fires cdecl callbacks → write into
   lock-free `TRingBuffer` → `tmrDrain` (50ms TTimer) polls rings on main thread →
   updates grids/labels. No locks, no allocs.

2. **GUI → Rust** (cold path): Button clicks call `TBroker` methods directly
   (FFI into libapollo). Blocking HTTP calls, only on user action.

3. **Rust → Strategies** (hot path): `CbTick` fans out ticks to per-strategy
   SPSC rings. Each `TStrategyThread` spins on its own ring with `Sleep(1)` idle.
   Strategy calls `TBroker.PlaceOrder` for orders (thread-safe in libapollo).

### Isolation rules

- GUI thread never touches strategy state
- Strategies never touch GUI widgets
- Both sides read from separate SPSC ring copies
- Only shared object is `TBroker` (thread-safe on the Rust side)

## Files

```
topaz/
├── Apollo.Broker.pas              ← OOP wrapper over libapollo C FFI
├── ApolloBroker.md                ← Full API reference
├── README.md                      ← This file
└── pascal/
    ├── TopazDashboard.lpr         ← Program entry point
    ├── TopazDashboard.lpi         ← Lazarus project file
    ├── MainForm.pas               ← Dashboard form (6 pages)
    ├── MainForm.lfm               ← Form layout (designer-compatible)
    ├── Topaz.RingBuffer.pas       ← Lock-free SPSC ring buffer
    ├── Topaz.EventTypes.pas       ← Event records + cdecl callback trampolines
    └── Topaz.Strategy.pas         ← Strategy base class + thread runner
```

## Supported Brokers

Upstox, Kite (Zerodha), Fyers, INDmoney, Dhan

## Requirements

- libapollo native library (build from `../apollo` repo via `cargo build --release -p apollo-cffi`)
- Delphi XE2+ or FreePascal 3.2+

## Build Examples (FreePascal)

```bash
# Make sure libapollo.dylib is in /usr/local/lib or same directory
fpc -Mdelphi -Fl/usr/local/lib examples/QuickStart.pas
fpc -Mdelphi -Fl/usr/local/lib examples/StreamTicks.pas
```

## Build Examples (Delphi)

```bash
dcc64 -U. examples\QuickStart.pas
```

## Quick Start

```pascal
uses Apollo.Broker;

var B: TBroker;
begin
  B := TBroker.Create('upstox', 'eyJ...', '');
  try
    B.Connect;
    WriteLn(B.LTP('SBIN', exNSE):0:2);
  finally
    B.Free;
  end;
end.
```

See [ApolloBroker.md](ApolloBroker.md) for the full API reference including GUI wiring patterns.
