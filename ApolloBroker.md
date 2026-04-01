# Apollo.Broker.pas — Delphi / FreePascal API Reference

OOP wrapper over libapollo. Single-file, zero Pascal dependencies (only `SysUtils`). Compiles with Delphi (XE2+) and FreePascal (3.2+).

Supports 5 Indian brokers: **Upstox, Kite (Zerodha), Fyers, INDmoney, Dhan**.

## Setup

1. Build libapollo:
   ```bash
   cd apollo && cargo build --release -p apollo-cffi
   ```
2. Copy the library next to your executable:
   - macOS: `libapollo.dylib`
   - Linux: `libapollo.so`
   - Windows: `apollo.dll`

3. Add `Apollo.Broker.pas` to your project. No other units needed.

---

## Quick Start

```pascal
uses Apollo.Broker;

var
  B: TBroker;
begin
  B := TBroker.Create('upstox', 'eyJhbGci...', '');
  try
    B.Connect;
    WriteLn('Broker: ', B.Name);
    WriteLn('Instruments loaded: ', B.InstrumentCount);
    WriteLn('RELIANCE LTP: ', B.LTP('RELIANCE', exNSE):0:2);
    WriteLn('Margin available: ', B.AvailableMargin:0:2);
  finally
    B.Free;
  end;
end.
```

---

## TBroker Class

### Constructor

```pascal
constructor Create(const ABroker, AToken, AApiKey: AnsiString);
```

| Param | Description |
|-------|-------------|
| `ABroker` | `'upstox'`, `'kite'`, `'fyers'`, `'indmoney'`, or `'dhan'` |
| `AToken` | Access/bearer token from the broker |
| `AApiKey` | API key (required for Kite, Fyers, Dhan — pass `''` for Upstox/INDmoney) |

Raises `EApolloError` if the broker name is invalid.

### Destructor

Automatically stops streaming and frees the native handle. Use `try..finally`.

---

## Connection

```pascal
function Connect: Boolean;
function Disconnect: Boolean;
function SetToken(const AToken: AnsiString): Boolean;
function LastError: AnsiString;
```

- `Connect` downloads the instrument catalog from the broker. Raises `EApolloError` on failure.
- `SetToken` hot-swaps the token without reconnecting.
- `LastError` returns the last error message from the native library.

### Properties

```pascal
property Name: AnsiString;            // Broker name (e.g. 'upstox')
property IsConnected: Boolean;        // Connection status
property InstrumentCount: Integer;    // Number of instruments in catalog
property TickCount: Int64;            // Total ticks received since StreamStart
```

---

## Instrument Catalog

After `Connect`, the broker's full instrument catalog is loaded. Use canonical (broker-agnostic) symbol names.

```pascal
// Find a symbol — returns SymbolId (integer key), or -1 if not found
SymId := B.FindInstrument('RELIANCE', exNSE);

// Get info about a symbol
Name      := B.CatalogSymbol(SymId);     // 'RELIANCE'
BrokerKey := B.InstrumentKey(SymId);      // Broker-specific key
Json      := B.InstrumentJson(SymId);     // Full instrument details as JSON

// Search instruments
Results := B.SearchJson('RELI', exNSE, 10);  // Top 10 matches, JSON array
```

### Symbol Mapping

Convert between canonical names and broker-specific keys:

```pascal
BrokerKey := B.ToBrokerKey('NSE:RELIANCE');       // Canonical → broker key
Canonical := B.FromBrokerKey('NSE_EQ|INE002A01018'); // Broker key → canonical
Canonical := B.ToCanonical(SymId);                 // SymbolId → canonical string
SymId     := B.FromCanonical('NSE:RELIANCE');       // Canonical string → SymbolId
```

---

## Derivatives (Options & Futures)

```pascal
// Get nearest expiry (returns Unix timestamp)
Expiry := B.NearestExpiry('NIFTY 50', exNFO);

// List all expiries
ExpiriesJson := B.ListExpiriesJson('NIFTY 50', exNFO);  // JSON array of timestamps

// Get ATM strike for a given spot price
Strike := B.ATMStrike('NIFTY 50', Expiry, 22450.0);

// List all strikes for an expiry
StrikesJson := B.ListStrikesJson('NIFTY 50', Expiry, exNFO);

// Resolve a specific option contract → SymbolId
CE := B.ResolveOption('NIFTY 50', Expiry, 22450.0, otCall, exNFO);
PE := B.ResolveOption('NIFTY 50', Expiry, 22450.0, otPut,  exNFO);

// Now use the SymbolId to get LTP, subscribe, place orders, etc.
WriteLn('CE LTP: ', B.LTP(B.CatalogSymbol(CE), exNFO):0:2);
```

---

## Market Data (REST)

```pascal
// Last traded price
Price := B.LTP('SBIN', exNSE);

// OHLCV history (returns JSON array)
History := B.HistoryJson('RELIANCE', exNSE, '2025-01-01', '2025-01-31', '1d');
// Intervals: '1m', '5m', '15m', '30m', '1h', '1d'
```

---

## Account

```pascal
Margin    := B.AvailableMargin;   // Available cash for trading
Used      := B.UsedMargin;        // Margin currently used
Positions := B.PositionsJson;     // Open positions as JSON array
Funds     := B.FundsJson;         // Fund details as JSON object
```

---

## Orders

### Place Order

```pascal
function PlaceOrder(
  const ASymbol: AnsiString;
  AExchange: TExchange;
  ASide: TSide;
  AKind: TOrderKind;
  AProduct: TProductType;
  AValidity: TValidity;
  AQty: Integer;
  APrice, ATriggerPrice: Double;
  const ATag: AnsiString = ''
): AnsiString;  // Returns order ID
```

Examples:

```pascal
// Market order — buy 50 shares of SBIN intraday
OrderId := B.PlaceOrder('SBIN', exNSE, sdBuy, okMarket, ptIntraday, vDay, 50, 0, 0);

// Limit order — sell RELIANCE at 2500
OrderId := B.PlaceOrder('RELIANCE', exNSE, sdSell, okLimit, ptIntraday, vDay, 10, 2500.0, 0);

// Stop-loss order — trigger at 750, execute at market
OrderId := B.PlaceOrder('SBIN', exNSE, sdSell, okStopLoss, ptIntraday, vDay, 50, 0, 750.0);

// Stop-limit order — trigger at 750, limit at 748
OrderId := B.PlaceOrder('SBIN', exNSE, sdSell, okStopLimit, ptIntraday, vDay, 50, 748.0, 750.0);

// Option order — buy 1 lot of NIFTY CE
CE := B.ResolveOption('NIFTY 50', Expiry, Strike, otCall, exNFO);
OrderId := B.PlaceOrder(B.CatalogSymbol(CE), exNFO, sdBuy, okMarket, ptIntraday, vDay, 50, 0, 0);

// Tagged order (for filtering in orderbook)
OrderId := B.PlaceOrder('SBIN', exNSE, sdBuy, okMarket, ptIntraday, vDay, 50, 0, 0, 'my-strategy');
```

Raises `EApolloError` if the order fails.

### Modify Order

```pascal
function ModifyOrder(const AOrderId: AnsiString; AKind: TOrderKind;
  AQty: Integer; APrice, ATriggerPrice: Double): Boolean;

// Change price and quantity
B.ModifyOrder(OrderId, okLimit, 20, 2510.0, 0);
```

### Cancel Order

```pascal
function CancelOrder(const AOrderId: AnsiString): Boolean;

B.CancelOrder(OrderId);
```

### Exit Position

```pascal
function ExitPosition(const ASymbol: AnsiString; AExchange: TExchange): Boolean;

B.ExitPosition('SBIN', exNSE);  // Market-exits the position
```

---

## Real-Time Streaming (WebSocket)

### 1. Define Callback Procedures

All callbacks are `cdecl` — they fire on Apollo's internal thread. Keep them fast. Do **not** call TBroker methods from inside a callback (deadlock risk).

```pascal
procedure OnTick(UserData: Pointer; SymbolId: Integer;
  LTP, Bid, Ask: Double; Volume, OI: Int64); cdecl;
begin
  WriteLn(Format('Tick #%d: LTP=%.2f Bid=%.2f Ask=%.2f Vol=%d',
    [SymbolId, LTP, Bid, Ask, Volume]));
end;

procedure OnDepth(UserData: Pointer; SymbolId: Integer; Json: PAnsiChar); cdecl;
begin
  WriteLn('Depth: ', Json);
end;

procedure OnCandle(UserData: Pointer; SymbolId: Integer; Json: PAnsiChar); cdecl;
begin
  WriteLn('Candle: ', Json);
end;

procedure OnOrder(UserData: Pointer; Json: PAnsiChar); cdecl;
begin
  WriteLn('Order update: ', Json);
end;

procedure OnConnect(UserData: Pointer; Feed: PAnsiChar); cdecl;
begin
  WriteLn('Stream connected: ', Feed);
end;

procedure OnDisconnect(UserData: Pointer; Feed: PAnsiChar; Reason: PAnsiChar); cdecl;
begin
  WriteLn('Stream disconnected: ', Feed, ' reason: ', Reason);
end;
```

### 2. Register and Start

```pascal
B.SetCallbacks(@OnTick, @OnDepth, @OnCandle, @OnOrder, @OnConnect, @OnDisconnect, nil);
B.StreamStart;
```

The `UserData` parameter (last arg of `SetCallbacks`) is passed through to every callback. Use it to pass your form/object pointer:

```pascal
B.SetCallbacks(@OnTick, @OnDepth, @OnCandle, @OnOrder, @OnConnect, @OnDisconnect, Self);
```

### 3. Subscribe to Symbols

```pascal
// Subscribe modes
B.Subscribe('RELIANCE', exNSE, smLTP);    // LTP only (lowest bandwidth)
B.Subscribe('SBIN',     exNSE, smQuote);  // LTP + bid/ask
B.Subscribe('NIFTY 50', exNSE, smFull);   // Full tick with market depth

// Subscribe to order updates
B.SubscribeOrders;

// Unsubscribe
B.Unsubscribe('RELIANCE', exNSE);
```

### 4. Stop Streaming

```pascal
B.StreamStop;
// Or just free the broker — destructor calls StreamStop automatically
```

### Tick Counter

```pascal
WriteLn('Total ticks received: ', B.TickCount);
```

---

## Enums Reference

### TExchange

| Value | Exchange |
|-------|----------|
| `exNSE` | National Stock Exchange (equity) |
| `exBSE` | Bombay Stock Exchange |
| `exNFO` | NSE Futures & Options |
| `exBFO` | BSE Futures & Options |
| `exMCX` | Multi Commodity Exchange |
| `exCDS` | Currency Derivatives |

### TSide

| Value | Meaning |
|-------|---------|
| `sdBuy` | Buy |
| `sdSell` | Sell |

### TOrderKind

| Value | Meaning |
|-------|---------|
| `okMarket` | Market order |
| `okLimit` | Limit order |
| `okStopLoss` | Stop-loss (market on trigger) |
| `okStopLimit` | Stop-loss (limit on trigger) |

### TProductType

| Value | Meaning |
|-------|---------|
| `ptCNC` | Cash & Carry / Delivery |
| `ptIntraday` | Intraday / MIS |
| `ptMargin` | Margin / NRML |

### TValidity

| Value | Meaning |
|-------|---------|
| `vDay` | Valid for the trading day |
| `vIOC` | Immediate or Cancel |

### TOptionType

| Value | Meaning |
|-------|---------|
| `otNone` | Not an option (equity/future) |
| `otCall` | Call option |
| `otPut` | Put option |

### TSubMode

| Value | Data Received |
|-------|---------------|
| `smLTP` | LTP only (lowest bandwidth) |
| `smQuote` | LTP + bid + ask |
| `smFull` | Full tick with 5-level market depth |

---

## Callback Types

| Type | Signature | When Fired |
|------|-----------|------------|
| `TApolloTickCb` | `(UserData; SymbolId; LTP, Bid, Ask; Volume, OI)` | Every tick update |
| `TApolloDepthCb` | `(UserData; SymbolId; Json)` | Market depth change (smFull mode) |
| `TApolloCandleCb` | `(UserData; SymbolId; Json)` | 1-minute candle close |
| `TApolloOrderCb` | `(UserData; Json)` | Order status change |
| `TApolloConnectCb` | `(UserData; Feed)` | WebSocket connected |
| `TApolloDisconnectCb` | `(UserData; Feed; Reason)` | WebSocket disconnected |

All callbacks are `cdecl` and fire on Apollo's internal thread.

---

## Error Handling

All methods that can fail either return `Boolean` (False on failure) or raise `EApolloError`:

```pascal
try
  B.Connect;
  OrderId := B.PlaceOrder('SBIN', exNSE, sdBuy, okMarket, ptIntraday, vDay, 50, 0, 0);
except
  on E: EApolloError do
    WriteLn('Error: ', E.Message);
end;

// For Boolean-returning methods, check LastError:
if not B.ModifyOrder(OrderId, okLimit, 20, 800.0, 0) then
  WriteLn('Modify failed: ', B.LastError);
```

---

## Thread Safety

- `TBroker` is **not** thread-safe. Use one instance per thread.
- Streaming callbacks fire on Apollo's internal thread — do not call `TBroker` methods from inside a callback.
- For GUI apps: queue callback data and process it on the main thread (timer or `TThread.Synchronize`).

---

## Broker-Specific Notes

| Broker | Token Format | API Key Required | Notes |
|--------|-------------|-----------------|-------|
| Upstox | Bearer token (`eyJ...`) | No | Token valid 1 day |
| Kite | Kite token | Yes (`api_key`) | Use `kite.trade` to generate |
| Fyers | Access token | Yes (`client_id`) | Format: `client_id:token` handled internally |
| INDmoney | Bearer token | No | Token valid 24h |
| Dhan | Access token | Yes (`client_id`) | |

---

## Complete Example: Intraday Scalper Skeleton

```pascal
program Scalper;

uses
  SysUtils, Apollo.Broker;

procedure OnTick(UserData: Pointer; SymbolId: Integer;
  LTP, Bid, Ask: Double; Volume, OI: Int64); cdecl;
begin
  WriteLn(Format('[%s] SymId=%d LTP=%.2f Vol=%d',
    [FormatDateTime('hh:nn:ss.zzz', Now), SymbolId, LTP, Volume]));
end;

procedure OnConnect(UserData: Pointer; Feed: PAnsiChar); cdecl;
begin
  WriteLn('Connected to ', Feed);
end;

procedure OnDisconnect(UserData: Pointer; Feed: PAnsiChar; Reason: PAnsiChar); cdecl;
begin
  WriteLn('Disconnected: ', Reason);
end;

var
  B: TBroker;
begin
  B := TBroker.Create('upstox', 'YOUR_TOKEN', '');
  try
    B.Connect;
    WriteLn('Instruments: ', B.InstrumentCount);
    WriteLn('Margin: ', B.AvailableMargin:0:2);

    // Set up streaming
    B.SetCallbacks(@OnTick, nil, nil, nil, @OnConnect, @OnDisconnect, nil);
    B.StreamStart;
    B.Subscribe('NIFTY 50', exNSE, smFull);
    B.Subscribe('SBIN', exNSE, smQuote);

    WriteLn('Streaming... Press Enter to stop.');
    ReadLn;

    B.StreamStop;
  finally
    B.Free;
  end;
end.
```

---

## GUI Wiring Example (Delphi VCL / Lazarus LCL)

Apollo callbacks fire on an internal thread — you cannot touch GUI controls directly. The pattern is: callbacks enqueue data into a lock-protected list, a TTimer on the main thread drains it.

### Step 1: Define a tick record and a thread-safe queue

```pascal
type
  TTickEvent = record
    SymbolId: Integer;
    LTP, Bid, Ask: Double;
    Volume, OI: Int64;
  end;

  TOrderEvent = record
    Json: AnsiString;
  end;

  TStreamStatus = (ssConnected, ssDisconnected);
  TStatusEvent = record
    Status: TStreamStatus;
    Feed, Reason: AnsiString;
  end;
```

### Step 2: Form with broker, queue, and timer

```pascal
unit MainForm;

{$IFDEF FPC}{$mode Delphi}{$H+}{$ENDIF}

interface

uses
  {$IFDEF FPC}
  Classes, SysUtils, Forms, Controls, StdCtrls, ExtCtrls, Grids, SyncObjs,
  {$ELSE}
  System.SysUtils, System.Classes, System.SyncObjs,
  Vcl.Forms, Vcl.Controls, Vcl.StdCtrls, Vcl.ExtCtrls, Vcl.Grids,
  {$ENDIF}
  Apollo.Broker;

type
  TTickEvent = record
    SymbolId: Integer;
    LTP, Bid, Ask: Double;
    Volume, OI: Int64;
  end;

  TForm1 = class(TForm)
    EdtToken: TEdit;
    CbxBroker: TComboBox;
    BtnConnect: TButton;
    BtnSubscribe: TButton;
    EdtSymbol: TEdit;
    GridTicks: TStringGrid;
    MemoLog: TMemo;
    TimerPoll: TTimer;       // Interval = 50ms
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure BtnConnectClick(Sender: TObject);
    procedure BtnSubscribeClick(Sender: TObject);
    procedure TimerPollTimer(Sender: TObject);
  private
    FBroker: TBroker;
    FTickQueue: TList;        // of ^TTickEvent
    FTickLock: TCriticalSection;
    procedure Log(const S: string);
  end;

var
  Form1: TForm1;
```

### Step 3: cdecl callback trampolines

The callbacks receive the form pointer via `UserData`, enqueue data under lock:

```pascal
implementation

type
  PTickEvent = ^TTickEvent;

// Called on Apollo's internal thread — must be fast, no GUI access
procedure CbTick(UserData: Pointer; SymbolId: Integer;
  LTP, Bid, Ask: Double; Volume, OI: Int64); cdecl;
var
  F: TForm1;
  P: PTickEvent;
begin
  F := TForm1(UserData);
  New(P);
  P^.SymbolId := SymbolId;
  P^.LTP := LTP;
  P^.Bid := Bid;
  P^.Ask := Ask;
  P^.Volume := Volume;
  P^.OI := OI;

  F.FTickLock.Enter;
  try
    F.FTickQueue.Add(P);
  finally
    F.FTickLock.Leave;
  end;
end;

procedure CbConnect(UserData: Pointer; Feed: PAnsiChar); cdecl;
begin
  // For simplicity, log via Synchronize
  TThread.Queue(nil, procedure
  begin
    TForm1(UserData).Log('Stream connected: ' + string(AnsiString(Feed)));
  end);
end;

procedure CbDisconnect(UserData: Pointer; Feed: PAnsiChar; Reason: PAnsiChar); cdecl;
begin
  TThread.Queue(nil, procedure
  begin
    TForm1(UserData).Log('Disconnected: ' + string(AnsiString(Reason)));
  end);
end;

procedure CbOrder(UserData: Pointer; Json: PAnsiChar); cdecl;
begin
  TThread.Queue(nil, procedure
  begin
    TForm1(UserData).Log('Order: ' + string(AnsiString(Json)));
  end);
end;
```

### Step 4: Form lifecycle and timer drain

```pascal
procedure TForm1.FormCreate(Sender: TObject);
begin
  FTickQueue := TList.Create;
  FTickLock := TCriticalSection.Create;

  GridTicks.ColCount := 6;
  GridTicks.RowCount := 1;
  GridTicks.FixedRows := 1;
  GridTicks.Cells[0, 0] := 'SymbolId';
  GridTicks.Cells[1, 0] := 'LTP';
  GridTicks.Cells[2, 0] := 'Bid';
  GridTicks.Cells[3, 0] := 'Ask';
  GridTicks.Cells[4, 0] := 'Volume';
  GridTicks.Cells[5, 0] := 'OI';
end;

procedure TForm1.FormDestroy(Sender: TObject);
var
  I: Integer;
begin
  TimerPoll.Enabled := False;
  FBroker.Free;

  // Free any remaining queued events
  for I := 0 to FTickQueue.Count - 1 do
    Dispose(PTickEvent(FTickQueue[I]));
  FTickQueue.Free;
  FTickLock.Free;
end;

procedure TForm1.Log(const S: string);
begin
  MemoLog.Lines.Add(FormatDateTime('hh:nn:ss.zzz', Now) + '  ' + S);
end;

procedure TForm1.BtnConnectClick(Sender: TObject);
begin
  FBroker := TBroker.Create(
    AnsiString(CbxBroker.Text),
    AnsiString(EdtToken.Text),
    '');

  FBroker.Connect;
  Log('Connected to ' + CbxBroker.Text +
      ' — ' + IntToStr(FBroker.InstrumentCount) + ' instruments');

  // Wire callbacks with Self as UserData
  FBroker.SetCallbacks(
    @CbTick,        // on tick
    nil,            // on depth (optional)
    nil,            // on candle (optional)
    @CbOrder,       // on order update
    @CbConnect,     // on WS connect
    @CbDisconnect,  // on WS disconnect
    Self);          // UserData = this form

  FBroker.StreamStart;
  FBroker.SubscribeOrders;
  TimerPoll.Enabled := True;
  Log('Streaming started');
end;

procedure TForm1.BtnSubscribeClick(Sender: TObject);
begin
  FBroker.Subscribe(AnsiString(EdtSymbol.Text), exNSE, smFull);
  Log('Subscribed: ' + EdtSymbol.Text);
end;
```

### Step 5: Timer drains the queue (main thread, safe for GUI)

```pascal
procedure TForm1.TimerPollTimer(Sender: TObject);
var
  Snapshot: TList;
  I, Row: Integer;
  P: PTickEvent;
begin
  // Swap the queue under lock — minimizes lock hold time
  Snapshot := nil;
  FTickLock.Enter;
  try
    if FTickQueue.Count = 0 then Exit;
    Snapshot := FTickQueue;
    FTickQueue := TList.Create;
  finally
    FTickLock.Leave;
  end;

  // Process all ticks on main thread — safe to update grid
  for I := 0 to Snapshot.Count - 1 do begin
    P := PTickEvent(Snapshot[I]);

    // Find or add row for this SymbolId
    Row := -1;
    for var R := 1 to GridTicks.RowCount - 1 do
      if GridTicks.Cells[0, R] = IntToStr(P^.SymbolId) then begin
        Row := R;
        Break;
      end;
    if Row = -1 then begin
      Row := GridTicks.RowCount;
      GridTicks.RowCount := Row + 1;
    end;

    GridTicks.Cells[0, Row] := IntToStr(P^.SymbolId);
    GridTicks.Cells[1, Row] := FormatFloat('0.00', P^.LTP);
    GridTicks.Cells[2, Row] := FormatFloat('0.00', P^.Bid);
    GridTicks.Cells[3, Row] := FormatFloat('0.00', P^.Ask);
    GridTicks.Cells[4, Row] := IntToStr(P^.Volume);
    GridTicks.Cells[5, Row] := IntToStr(P^.OI);

    Dispose(P);
  end;

  Snapshot.Free;
end;
```

### Key Points

| Concern | Solution |
|---------|----------|
| Callbacks on wrong thread | `TCriticalSection` + `TList` queue |
| Timer interval | 50ms is a good balance (20 FPS grid update) |
| Lock contention | Swap the entire list under lock, process outside lock |
| Memory | `New`/`Dispose` for tick records; freed in timer or `FormDestroy` |
| Order updates | Use `TThread.Queue` for low-frequency events (simpler) |
| High-frequency ticks | Use the queue pattern (avoids per-tick `Synchronize` overhead) |
| Multiple symbols | Grid keyed by `SymbolId`; use `CatalogSymbol(SymId)` for display names |
