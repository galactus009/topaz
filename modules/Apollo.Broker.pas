(**
 * Apollo.Broker — Free Pascal / Delphi-compatible OOP wrapper over libapollo.
 *
 * Wraps the Apollo C FFI (libapollo.dylib / .so / .dll) in a TBroker class.
 * No HTTP or WebSocket implementation — all delegated to Apollo.
 *
 * Supports: Upstox, Kite (Zerodha), Fyers, INDmoney, Dhan
 *
 * Requirements:
 *   - libapollo.dylib / .so built via `cargo build --release -p apollo-cffi`
 *   - On macOS: copy to /usr/local/lib/ or set DYLD_LIBRARY_PATH
 *   - On Linux: copy to /usr/lib/ or set LD_LIBRARY_PATH
 *
 * Usage:
 *   var B: TBroker;
 *   B := TBroker.Create('upstox', 'eyJ...', '');
 *   try
 *     B.Connect;
 *     WriteLn('NIFTY 50 LTP: ', B.LTP('NIFTY 50', exNSE):0:2);
 *     B.Subscribe('NIFTY 50', exNSE, smLTP);
 *   finally
 *     B.Free;
 *   end;
 *)

{$IFDEF FPC}
  {$mode Delphi}{$H+}
{$ENDIF}

unit Apollo.Broker;

interface

uses
  {$IFDEF FPC}SysUtils{$ELSE}System.SysUtils{$ENDIF};

// ── Enums ────────────────────────────────────────────────────────────────────

type
  TExchange = (
    exNSE = 0,
    exBSE = 1,
    exNFO = 2,
    exBFO = 3,
    exMCX = 4,
    exCDS = 5
  );

  TSide = (
    sdBuy  = 0,
    sdSell = 1
  );

  TOrderKind = (
    okMarket    = 0,
    okLimit     = 1,
    okStopLoss  = 2,
    okStopLimit = 3
  );

  TProductType = (
    ptCNC      = 0,
    ptIntraday = 1,
    ptMargin   = 2
  );

  TValidity = (
    vDay = 0,
    vIOC = 1
  );

  TOptionType = (
    otNone = 0,
    otCall = 1,
    otPut  = 2
  );

  TSubMode = (
    smLTP   = 0,  // LTP only
    smQuote = 1,  // LTP + bid/ask
    smFull  = 2   // Full with market depth
  );

// ── Callback types ────────────────────────────────────────────────────────────

  TApolloTickCb = procedure(UserData: Pointer; SymbolId: Integer;
    LTP, Bid, Ask: Double; Volume, OI: Int64); cdecl;

  TApolloDepthCb = procedure(UserData: Pointer; SymbolId: Integer;
    Json: PAnsiChar); cdecl;

  TApolloCandleCb = procedure(UserData: Pointer; SymbolId: Integer;
    Json: PAnsiChar); cdecl;

  TApolloOrderCb = procedure(UserData: Pointer; Json: PAnsiChar); cdecl;

  TApolloConnectCb = procedure(UserData: Pointer; Feed: PAnsiChar); cdecl;

  TApolloDisconnectCb = procedure(UserData: Pointer; Feed: PAnsiChar;
    Reason: PAnsiChar); cdecl;

// ── TBroker ───────────────────────────────────────────────────────────────────

  TBroker = class
  private
    FHandle: Pointer;
    function GetName: AnsiString;
    function GetIsConnected: Boolean;
    function GetInstrumentCount: Integer;
    function GetTickCount: Int64;
    function SafeStr(P: PAnsiChar): AnsiString; inline;
  public
    /// Create a broker session.
    /// ABroker: 'upstox', 'kite', 'fyers', 'indmoney', or 'dhan'
    constructor Create(const ABroker, AToken, AApiKey: AnsiString);
    destructor Destroy; override;

    // ── Connection ──────────────────────────────────────────────────────────
    function Connect: Boolean;
    function Disconnect: Boolean;
    function SetToken(const AToken: AnsiString): Boolean;
    function LastError: AnsiString;

    // ── Catalog ─────────────────────────────────────────────────────────────
    /// Find SymbolId by canonical name. Returns -1 if not found.
    function FindInstrument(const ASymbol: AnsiString; AExchange: TExchange): Integer;
    function CatalogSymbol(ASymbolId: Integer): AnsiString;
    function InstrumentKey(ASymbolId: Integer): AnsiString;
    function InstrumentJson(ASymbolId: Integer): AnsiString;
    function NearestExpiry(const AUnderlying: AnsiString; AExchange: TExchange): Int64;
    function ListExpiriesJson(const AUnderlying: AnsiString; AExchange: TExchange): AnsiString;
    function ATMStrike(const AUnderlying: AnsiString; AExpiryUnix: Int64; ASpot: Double): Double;
    function ListStrikesJson(const AUnderlying: AnsiString; AExpiryUnix: Int64;
      AExchange: TExchange): AnsiString;
    function ResolveOption(const AUnderlying: AnsiString; AExpiryUnix: Int64;
      AStrike: Double; AOptionType: TOptionType; AExchange: TExchange): Integer;
    function SearchJson(const AQuery: AnsiString; AExchange: TExchange;
      AMaxResults: Integer): AnsiString;

    // ── Symbol Mapping ───────────────────────────────────────────────────────
    function ToBrokerKey(const ACanonical: AnsiString): AnsiString;
    function FromBrokerKey(const ABrokerKey: AnsiString): AnsiString;
    function ToCanonical(ASymbolId: Integer): AnsiString;
    function FromCanonical(const ACanonical: AnsiString): Integer;

    // ── Market Data ──────────────────────────────────────────────────────────
    function LTP(const ASymbol: AnsiString; AExchange: TExchange): Double;
    function HistoryJson(const ASymbol: AnsiString; AExchange: TExchange;
      const AFrom, ATo, AInterval: AnsiString): AnsiString;

    // ── Account ──────────────────────────────────────────────────────────────
    function AvailableMargin: Double;
    function UsedMargin: Double;
    function PositionsJson: AnsiString;
    function FundsJson: AnsiString;
    function ExitPosition(const ASymbol: AnsiString; AExchange: TExchange): Boolean;

    // ── Orders ───────────────────────────────────────────────────────────────
    function PlaceOrder(const ASymbol: AnsiString; AExchange: TExchange;
      ASide: TSide; AKind: TOrderKind; AProduct: TProductType; AValidity: TValidity;
      AQty: Integer; APrice, ATriggerPrice: Double;
      const ATag: AnsiString = ''): AnsiString;
    function ModifyOrder(const AOrderId: AnsiString; AKind: TOrderKind;
      AQty: Integer; APrice, ATriggerPrice: Double): Boolean;
    function CancelOrder(const AOrderId: AnsiString): Boolean;

    // ── Streaming ────────────────────────────────────────────────────────────
    procedure SetCallbacks(
      AOnTick:       TApolloTickCb;
      AOnDepth:      TApolloDepthCb;
      AOnCandle:     TApolloCandleCb;
      AOnOrder:      TApolloOrderCb;
      AOnConnect:    TApolloConnectCb;
      AOnDisconnect: TApolloDisconnectCb;
      AUserData:     Pointer = nil);
    function StreamStart: Boolean;
    procedure StreamStop;
    function Subscribe(const ASymbol: AnsiString; AExchange: TExchange;
      AMode: TSubMode = smLTP): Boolean;
    procedure Unsubscribe(const ASymbol: AnsiString; AExchange: TExchange);
    function SubscribeOrders: Boolean;

    // ── Properties ───────────────────────────────────────────────────────────
    property Name:            AnsiString read GetName;
    property IsConnected:     Boolean    read GetIsConnected;
    property InstrumentCount: Integer    read GetInstrumentCount;
    property TickCount:       Int64      read GetTickCount;
  end;

function ApolloVersion: Integer;

// ── Exceptions ────────────────────────────────────────────────────────────────

type
  EApolloError = class(Exception);

implementation

// ── External C declarations ───────────────────────────────────────────────────

const
{$IFDEF FPC}
  {$IFDEF DARWIN}
  ApolloLib = 'apollo';
  {$LINKLIB apollo, static}
  {$LINKLIB iconv}
  {$LINKFRAMEWORK CoreFoundation}
  {$LINKFRAMEWORK Security}
  {$ENDIF}
  {$IFDEF LINUX}
  ApolloLib = 'apollo';
  {$LINKLIB apollo, static}
  {$ENDIF}
  {$IFDEF WINDOWS}
  ApolloLib = 'apollo.dll';
  {$ENDIF}
{$ELSE}
  {$IFDEF MACOS}
  ApolloLib = 'libapollo.dylib';
  {$ENDIF}
  {$IFDEF LINUX}
  ApolloLib = 'libapollo.so';
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  ApolloLib = 'apollo.dll';
  {$ENDIF}
{$ENDIF}

function  apollo_create(Broker, Token, ApiKey: PAnsiChar): Pointer;
  cdecl; external ApolloLib name 'create';
procedure apollo_free_handle(H: Pointer);
  cdecl; external ApolloLib name 'free_handle';
function  apollo_last_error(H: Pointer): PAnsiChar;
  cdecl; external ApolloLib name 'last_error';
function  apollo_version: Integer;
  cdecl; external ApolloLib name 'version';

function  apollo_connect(H: Pointer): Integer;
  cdecl; external ApolloLib name 'connect';
function  apollo_disconnect(H: Pointer): Integer;
  cdecl; external ApolloLib name 'disconnect';
function  apollo_is_connected(H: Pointer): Integer;
  cdecl; external ApolloLib name 'is_connected';
function  apollo_broker_name(H: Pointer): PAnsiChar;
  cdecl; external ApolloLib name 'broker_name';
function  apollo_set_token(H: Pointer; Token: PAnsiChar): Integer;
  cdecl; external ApolloLib name 'set_token';

function  apollo_catalog_count(H: Pointer): Integer;
  cdecl; external ApolloLib name 'catalog_count';
function  apollo_catalog_find(H: Pointer; Symbol: PAnsiChar; Exchange: Integer): Integer;
  cdecl; external ApolloLib name 'catalog_find';
function  apollo_catalog_symbol(H: Pointer; SymbolId: Integer): PAnsiChar;
  cdecl; external ApolloLib name 'catalog_symbol';
function  apollo_catalog_broker_key(H: Pointer; SymbolId: Integer): PAnsiChar;
  cdecl; external ApolloLib name 'catalog_broker_key';
function  apollo_instrument_json(H: Pointer; SymbolId: Integer): PAnsiChar;
  cdecl; external ApolloLib name 'instrument_json';
function  apollo_nearest_expiry(H: Pointer; Underlying: PAnsiChar; Exchange: Integer): Int64;
  cdecl; external ApolloLib name 'nearest_expiry';
function  apollo_list_expiries_json(H: Pointer; Underlying: PAnsiChar; Exchange: Integer): PAnsiChar;
  cdecl; external ApolloLib name 'list_expiries_json';
function  apollo_atm_strike(H: Pointer; Underlying: PAnsiChar; ExpiryUnix: Int64; Spot: Double): Double;
  cdecl; external ApolloLib name 'atm_strike';
function  apollo_list_strikes_json(H: Pointer; Underlying: PAnsiChar; ExpiryUnix: Int64; Exchange: Integer): PAnsiChar;
  cdecl; external ApolloLib name 'list_strikes_json';
function  apollo_resolve_option(H: Pointer; Underlying: PAnsiChar; ExpiryUnix: Int64;
  Strike: Double; OptionType, Exchange: Integer): Integer;
  cdecl; external ApolloLib name 'resolve_option';
function  apollo_search_json(H: Pointer; Query: PAnsiChar; Exchange, MaxResults: Integer): PAnsiChar;
  cdecl; external ApolloLib name 'search_json';

function  apollo_to_broker_key(H: Pointer; Canonical: PAnsiChar): PAnsiChar;
  cdecl; external ApolloLib name 'to_broker_key';
function  apollo_from_broker_key(H: Pointer; BrokerKey: PAnsiChar): PAnsiChar;
  cdecl; external ApolloLib name 'from_broker_key';
function  apollo_to_canonical(H: Pointer; SymbolId: Integer): PAnsiChar;
  cdecl; external ApolloLib name 'to_canonical';
function  apollo_from_canonical(H: Pointer; Canonical: PAnsiChar): Integer;
  cdecl; external ApolloLib name 'from_canonical';

function  apollo_ltp(H: Pointer; Symbol: PAnsiChar; Exchange: Integer): Double;
  cdecl; external ApolloLib name 'ltp';
function  apollo_history_json(H: Pointer; Symbol: PAnsiChar; Exchange: Integer;
  FromDate, ToDate, Interval: PAnsiChar): PAnsiChar;
  cdecl; external ApolloLib name 'history_json';

function  apollo_available_margin(H: Pointer): Double;
  cdecl; external ApolloLib name 'available_margin';
function  apollo_used_margin(H: Pointer): Double;
  cdecl; external ApolloLib name 'used_margin';
function  apollo_positions_json(H: Pointer): PAnsiChar;
  cdecl; external ApolloLib name 'positions_json';
function  apollo_funds_json(H: Pointer): PAnsiChar;
  cdecl; external ApolloLib name 'funds_json';
function  apollo_exit_position(H: Pointer; Symbol: PAnsiChar; Exchange: Integer): Integer;
  cdecl; external ApolloLib name 'exit_position';

function  apollo_place_order(H: Pointer; Symbol: PAnsiChar; Exchange: Integer;
  Side, OrderType, Product, Validity, Qty: Integer;
  Price, TriggerPrice: Double; Tag: PAnsiChar): PAnsiChar;
  cdecl; external ApolloLib name 'place_order';
function  apollo_modify_order(H: Pointer; OrderId: PAnsiChar;
  OrderType, Qty: Integer; Price, TriggerPrice: Double): Integer;
  cdecl; external ApolloLib name 'modify_order';
function  apollo_cancel_order(H: Pointer; OrderId: PAnsiChar): Integer;
  cdecl; external ApolloLib name 'cancel_order';

procedure apollo_set_callbacks(H: Pointer; UserData: Pointer;
  OnTick:       TApolloTickCb;
  OnDepth:      TApolloDepthCb;
  OnCandle:     TApolloCandleCb;
  OnOrder:      TApolloOrderCb;
  OnConnect:    TApolloConnectCb;
  OnDisconnect: TApolloDisconnectCb);
  cdecl; external ApolloLib name 'set_callbacks';
function  apollo_stream_start(H: Pointer): Integer;
  cdecl; external ApolloLib name 'stream_start';
procedure apollo_stream_stop(H: Pointer);
  cdecl; external ApolloLib name 'stream_stop';
function  apollo_subscribe(H: Pointer; Symbol: PAnsiChar; Exchange, Mode: Integer): Integer;
  cdecl; external ApolloLib name 'subscribe';
function  apollo_unsubscribe(H: Pointer; Symbol: PAnsiChar; Exchange: Integer): Integer;
  cdecl; external ApolloLib name 'unsubscribe';
function  apollo_subscribe_orders(H: Pointer): Integer;
  cdecl; external ApolloLib name 'subscribe_orders';
function  apollo_tick_count(H: Pointer): Int64;
  cdecl; external ApolloLib name 'tick_count';

// ── TBroker implementation ────────────────────────────────────────────────────

function ApolloVersion: Integer;
begin
  Result := apollo_version;
end;

constructor TBroker.Create(const ABroker, AToken, AApiKey: AnsiString);
begin
  inherited Create;
  FHandle := apollo_create(PAnsiChar(ABroker), PAnsiChar(AToken), PAnsiChar(AApiKey));
  if FHandle = nil then
    raise EApolloError.CreateFmt('Failed to create broker ''%s''', [ABroker]);
end;

destructor TBroker.Destroy;
begin
  if FHandle <> nil then
  begin
    apollo_stream_stop(FHandle);
    apollo_free_handle(FHandle);
    FHandle := nil;
  end;
  inherited;
end;

function TBroker.SafeStr(P: PAnsiChar): AnsiString;
begin
  if P <> nil then Result := AnsiString(P)
  else             Result := '';
end;

function TBroker.LastError: AnsiString;
begin
  Result := SafeStr(apollo_last_error(FHandle));
end;

// ── Connection ────────────────────────────────────────────────────────────────

function TBroker.Connect: Boolean;
var
  Err: AnsiString;
begin
  Result := apollo_connect(FHandle) <> 0;
  if not Result then
  begin
    Err := LastError;
    if Err <> '' then raise EApolloError.Create(Err);
  end;
end;

function TBroker.Disconnect: Boolean;
begin
  Result := apollo_disconnect(FHandle) <> 0;
end;

function TBroker.SetToken(const AToken: AnsiString): Boolean;
begin
  Result := apollo_set_token(FHandle, PAnsiChar(AToken)) <> 0;
end;

function TBroker.GetName: AnsiString;
begin
  Result := SafeStr(apollo_broker_name(FHandle));
end;

function TBroker.GetIsConnected: Boolean;
begin
  Result := apollo_is_connected(FHandle) <> 0;
end;

function TBroker.GetInstrumentCount: Integer;
begin
  Result := apollo_catalog_count(FHandle);
end;

function TBroker.GetTickCount: Int64;
begin
  Result := apollo_tick_count(FHandle);
end;

// ── Catalog ───────────────────────────────────────────────────────────────────

function TBroker.FindInstrument(const ASymbol: AnsiString; AExchange: TExchange): Integer;
begin
  Result := apollo_catalog_find(FHandle, PAnsiChar(ASymbol), Ord(AExchange));
end;

function TBroker.CatalogSymbol(ASymbolId: Integer): AnsiString;
begin
  Result := SafeStr(apollo_catalog_symbol(FHandle, ASymbolId));
end;

function TBroker.InstrumentKey(ASymbolId: Integer): AnsiString;
begin
  Result := SafeStr(apollo_catalog_broker_key(FHandle, ASymbolId));
end;

function TBroker.InstrumentJson(ASymbolId: Integer): AnsiString;
begin
  Result := SafeStr(apollo_instrument_json(FHandle, ASymbolId));
  if Result = '' then Result := '{}';
end;

function TBroker.NearestExpiry(const AUnderlying: AnsiString; AExchange: TExchange): Int64;
begin
  Result := apollo_nearest_expiry(FHandle, PAnsiChar(AUnderlying), Ord(AExchange));
end;

function TBroker.ListExpiriesJson(const AUnderlying: AnsiString; AExchange: TExchange): AnsiString;
begin
  Result := SafeStr(apollo_list_expiries_json(FHandle, PAnsiChar(AUnderlying), Ord(AExchange)));
  if Result = '' then Result := '[]';
end;

function TBroker.ATMStrike(const AUnderlying: AnsiString; AExpiryUnix: Int64; ASpot: Double): Double;
begin
  Result := apollo_atm_strike(FHandle, PAnsiChar(AUnderlying), AExpiryUnix, ASpot);
end;

function TBroker.ListStrikesJson(const AUnderlying: AnsiString; AExpiryUnix: Int64;
  AExchange: TExchange): AnsiString;
begin
  Result := SafeStr(apollo_list_strikes_json(FHandle, PAnsiChar(AUnderlying), AExpiryUnix, Ord(AExchange)));
  if Result = '' then Result := '[]';
end;

function TBroker.ResolveOption(const AUnderlying: AnsiString; AExpiryUnix: Int64;
  AStrike: Double; AOptionType: TOptionType; AExchange: TExchange): Integer;
begin
  Result := apollo_resolve_option(FHandle, PAnsiChar(AUnderlying), AExpiryUnix,
    AStrike, Ord(AOptionType), Ord(AExchange));
end;

function TBroker.SearchJson(const AQuery: AnsiString; AExchange: TExchange;
  AMaxResults: Integer): AnsiString;
begin
  Result := SafeStr(apollo_search_json(FHandle, PAnsiChar(AQuery), Ord(AExchange), AMaxResults));
  if Result = '' then Result := '[]';
end;

// ── Symbol Mapping ────────────────────────────────────────────────────────────

function TBroker.ToBrokerKey(const ACanonical: AnsiString): AnsiString;
begin
  Result := SafeStr(apollo_to_broker_key(FHandle, PAnsiChar(ACanonical)));
end;

function TBroker.FromBrokerKey(const ABrokerKey: AnsiString): AnsiString;
begin
  Result := SafeStr(apollo_from_broker_key(FHandle, PAnsiChar(ABrokerKey)));
end;

function TBroker.ToCanonical(ASymbolId: Integer): AnsiString;
begin
  Result := SafeStr(apollo_to_canonical(FHandle, ASymbolId));
end;

function TBroker.FromCanonical(const ACanonical: AnsiString): Integer;
begin
  Result := apollo_from_canonical(FHandle, PAnsiChar(ACanonical));
end;

// ── Market Data ───────────────────────────────────────────────────────────────

function TBroker.LTP(const ASymbol: AnsiString; AExchange: TExchange): Double;
begin
  Result := apollo_ltp(FHandle, PAnsiChar(ASymbol), Ord(AExchange));
end;

function TBroker.HistoryJson(const ASymbol: AnsiString; AExchange: TExchange;
  const AFrom, ATo, AInterval: AnsiString): AnsiString;
begin
  Result := SafeStr(apollo_history_json(FHandle, PAnsiChar(ASymbol), Ord(AExchange),
    PAnsiChar(AFrom), PAnsiChar(ATo), PAnsiChar(AInterval)));
  if Result = '' then Result := '[]';
end;

// ── Account ───────────────────────────────────────────────────────────────────

function TBroker.AvailableMargin: Double;
begin
  Result := apollo_available_margin(FHandle);
end;

function TBroker.UsedMargin: Double;
begin
  Result := apollo_used_margin(FHandle);
end;

function TBroker.PositionsJson: AnsiString;
begin
  Result := SafeStr(apollo_positions_json(FHandle));
  if Result = '' then Result := '[]';
end;

function TBroker.FundsJson: AnsiString;
begin
  Result := SafeStr(apollo_funds_json(FHandle));
  if Result = '' then Result := '{}';
end;

function TBroker.ExitPosition(const ASymbol: AnsiString; AExchange: TExchange): Boolean;
begin
  Result := apollo_exit_position(FHandle, PAnsiChar(ASymbol), Ord(AExchange)) <> 0;
end;

// ── Orders ────────────────────────────────────────────────────────────────────

function TBroker.PlaceOrder(const ASymbol: AnsiString; AExchange: TExchange;
  ASide: TSide; AKind: TOrderKind; AProduct: TProductType; AValidity: TValidity;
  AQty: Integer; APrice, ATriggerPrice: Double; const ATag: AnsiString): AnsiString;
var
  P: PAnsiChar;
begin
  P := apollo_place_order(FHandle, PAnsiChar(ASymbol), Ord(AExchange),
    Ord(ASide), Ord(AKind), Ord(AProduct), Ord(AValidity),
    AQty, APrice, ATriggerPrice, PAnsiChar(ATag));
  Result := SafeStr(P);
  if Result = '' then
    raise EApolloError.CreateFmt('place_order failed: %s', [LastError]);
end;

function TBroker.ModifyOrder(const AOrderId: AnsiString; AKind: TOrderKind;
  AQty: Integer; APrice, ATriggerPrice: Double): Boolean;
begin
  Result := apollo_modify_order(FHandle, PAnsiChar(AOrderId), Ord(AKind),
    AQty, APrice, ATriggerPrice) <> 0;
end;

function TBroker.CancelOrder(const AOrderId: AnsiString): Boolean;
begin
  Result := apollo_cancel_order(FHandle, PAnsiChar(AOrderId)) <> 0;
end;

// ── Streaming ─────────────────────────────────────────────────────────────────

procedure TBroker.SetCallbacks(
  AOnTick:       TApolloTickCb;
  AOnDepth:      TApolloDepthCb;
  AOnCandle:     TApolloCandleCb;
  AOnOrder:      TApolloOrderCb;
  AOnConnect:    TApolloConnectCb;
  AOnDisconnect: TApolloDisconnectCb;
  AUserData:     Pointer);
begin
  apollo_set_callbacks(FHandle, AUserData,
    AOnTick, AOnDepth, AOnCandle, AOnOrder, AOnConnect, AOnDisconnect);
end;

function TBroker.StreamStart: Boolean;
var
  Err: AnsiString;
begin
  Result := apollo_stream_start(FHandle) <> 0;
  if not Result then
  begin
    Err := LastError;
    if Err <> '' then raise EApolloError.Create(Err);
  end;
end;

procedure TBroker.StreamStop;
begin
  apollo_stream_stop(FHandle);
end;

function TBroker.Subscribe(const ASymbol: AnsiString; AExchange: TExchange;
  AMode: TSubMode): Boolean;
begin
  Result := apollo_subscribe(FHandle, PAnsiChar(ASymbol), Ord(AExchange), Ord(AMode)) <> 0;
end;

procedure TBroker.Unsubscribe(const ASymbol: AnsiString; AExchange: TExchange);
begin
  apollo_unsubscribe(FHandle, PAnsiChar(ASymbol), Ord(AExchange));
end;

function TBroker.SubscribeOrders: Boolean;
begin
  Result := apollo_subscribe_orders(FHandle) <> 0;
end;

end.
