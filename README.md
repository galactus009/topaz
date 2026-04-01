# Apollo Pascal Wrapper

Delphi / FreePascal wrapper for libapollo — broker-agnostic trading API for Indian markets.

## Files

```
pascal/
├── Apollo.Broker.pas      ← Single-file wrapper (add to your project)
├── apollo.h               ← C ABI reference (36 functions)
├── ApolloBroker.md        ← Full API documentation with GUI wiring example
├── README.md              ← This file
└── examples/
    ├── QuickStart.pas     ← Connect, get LTP, check margin
    ├── StreamTicks.pas    ← Real-time tick streaming with callbacks
    ├── PlaceOrder.pas     ← Place, modify, cancel orders
    ├── OptionChain.pas    ← Resolve options, ATM strike, expiries
    ├── OrderStream.pas    ← Real-time order/trade update stream
    └── MultiBroker.pas    ← Use multiple brokers simultaneously
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
