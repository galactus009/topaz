(**
 * Thorium.Broker — TBroker over Thorium REST + WebSocket.
 *
 * Talks to a running Thorium gateway:
 *
 *   - HTTP REST on the configured base URL (default http://127.0.0.1:5000)
 *     for catalog lookups, quotes, orders, positions, funds.
 *   - WebSocket on the same host (port 8765 by default) for tick + order
 *     streams; protocol is plain JSON text frames per Thorium spec.
 *
 * Constructor:
 *   TBroker.Create(BaseUrl, ApiKey)
 *
 *   - BaseUrl: full http URL of the Thorium REST endpoint. The WS endpoint
 *     is derived from it (host kept, port → 8765, scheme → ws).
 *   - ApiKey: the shared THORIUM_APIKEY value.
 *
 * Implementation: HTTP client + JSON via mORMot 2 (TSimpleHttpClient +
 * TDocVariant). Compiles in both FreePascal and Delphi.
 *
 * SymbolId model:
 *   Thorium identifies instruments by (symbol, exchange) string pairs, but
 *   the topaz codebase uses an integer SymbolId for hot-path tick dispatch.
 *   This unit maintains a per-process string→int map. SymbolIds are not
 *   stable across Thorium restarts; they're allocated on first lookup
 *   (FindInstrument, ResolveOption, etc.).
 *)

{$IFDEF FPC}
  {$mode Delphi}{$H+}
{$ENDIF}

unit Thorium.Broker;

interface

uses
  SysUtils, Classes, SyncObjs, Variants,
  mormot.core.base, mormot.core.text, mormot.core.variants,
  mormot.net.client, mormot.net.ws.core, mormot.net.ws.client;

type
  TExchange = (
    exNSE = 0,
    exBSE = 1,
    exNFO = 2,
    exBFO = 3,
    exMCX = 4,
    exCDS = 5
  );

  TSide = (sdBuy = 0, sdSell = 1);

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

  TValidity = (vDay = 0, vIOC = 1);

  TOptionType = (otNone = 0, otCall = 1, otPut = 2);

  TSubMode = (smLTP = 0, smQuote = 1, smFull = 2);

  // Callback types — cdecl-compatible so the Topaz.EventTypes trampolines
  // (CbTick/CbDepth/...) plug in unchanged.
  TBrokerTickCb = procedure(UserData: Pointer; SymbolId: Integer;
    LTP, Bid, Ask: Double; Volume, OI: Int64); cdecl;
  TBrokerDepthCb = procedure(UserData: Pointer; SymbolId: Integer;
    Json: PAnsiChar); cdecl;
  TBrokerCandleCb = procedure(UserData: Pointer; SymbolId: Integer;
    Json: PAnsiChar); cdecl;
  TBrokerOrderCb = procedure(UserData: Pointer; Json: PAnsiChar); cdecl;
  TBrokerConnectCb = procedure(UserData: Pointer; Feed: PAnsiChar); cdecl;
  TBrokerDisconnectCb = procedure(UserData: Pointer; Feed: PAnsiChar;
    Reason: PAnsiChar); cdecl;

  EBrokerError = class(Exception);

  TBroker = class
  private
    FBaseUrl: AnsiString;       // e.g. http://127.0.0.1:5000
    FWsHost: AnsiString;        // e.g. 127.0.0.1
    FWsPort: AnsiString;        // e.g. 8765
    FApiKey: AnsiString;
    FConnected: Boolean;
    FLastError: AnsiString;
    FTickCount: Int64;
    FInstrumentCount: Integer;

    // Symbol↔SymbolId map. Key form: 'SYMBOL|EXCHANGE' (uppercase).
    FSymToId: TStringList;        // Key='SYM|EXCH'  Object=Pointer(SymbolId)
    FIdKeys:  TStringList;        // Index = SymbolId, value = 'SYM|EXCH'
    FSymLock: TCriticalSection;

    // Exchange auto-detect cache: 'SYM|REQ_EX' → resolved Thorium exchange.
    FExchCache: TStringList;
    FExchLock:  TCriticalSection;

    // Subscriptions kept for replay on reconnect.
    FSubs:    TStringList;        // 'SYM|EXCH|MODE'
    FSubLock: TCriticalSection;

    // WebSocket state (mormot2 ws client + chat protocol).
    FWsClient:   THttpClientWebSockets;
    FWsProtocol: TWebSocketProtocolChat;
    FWsLock:     TCriticalSection;
    FStreamRunning: Boolean;
    FOrdersSubscribed: Boolean;

    // User callbacks.
    FOnTick:       TBrokerTickCb;
    FOnDepth:      TBrokerDepthCb;
    FOnCandle:     TBrokerCandleCb;
    FOnOrder:      TBrokerOrderCb;
    FOnConnect:    TBrokerConnectCb;
    FOnDisconnect: TBrokerDisconnectCb;
    FUserData:     Pointer;

    // Helpers.
    function ExchangeStr(const ASym: AnsiString; AEx: TExchange): AnsiString;
    function ResolveExchange(const ASym: AnsiString; AEx: TExchange): AnsiString;
    function SideStr(ASide: TSide): AnsiString;
    function PriceTypeStr(AKind: TOrderKind): AnsiString;
    function ProductStr(AProd: TProductType): AnsiString;
    function OptionTypeStr(AOpt: TOptionType): AnsiString;
    function ProbeSymbol(const ASym, AExchStr: AnsiString): Boolean;

    // Returns Null on transport failure, otherwise the parsed response
    // variant (which may itself be {status:error,...}). FLastError is set
    // on transport failure; StatusOk handles application-level errors.
    function HttpPostJson(const APath: RawUtf8; const ABody: variant): variant;
    function StatusOk(const AResp: variant; out AData: variant): Boolean;

    function GetOrCreateSymId(const ASym, AExch: AnsiString): Integer;
    function SymKey(ASymbolId: Integer): AnsiString;
    function ParseSymKey(const AKey: AnsiString;
      out ASym, AExch: AnsiString): Boolean;

    procedure WsIncomingFrame(Sender: TWebSocketProcess;
      const Frame: TWebSocketFrame);
    procedure DispatchTick(const ATick: variant; const ARawText: AnsiString);
    function WsSendJson(const AJson: AnsiString): Boolean;
    function WsAuthenticate: Boolean;
    procedure WsResubscribeAll;

    function GetName: AnsiString;
    function GetIsConnected: Boolean;
    function GetInstrumentCount: Integer;
    function GetTickCount: Int64;

  public
    constructor Create(const ABaseUrl, AApiKey: AnsiString);
    destructor Destroy; override;

    // Connection
    function Connect: Boolean;
    function Disconnect: Boolean;
    function SetToken(const AToken: AnsiString): Boolean;
    function LastError: AnsiString;

    // Catalog
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

    // Symbol mapping (Thorium uses CIDs — these mostly identity-pass).
    function ToBrokerKey(const ACanonical: AnsiString): AnsiString;
    function FromBrokerKey(const ABrokerKey: AnsiString): AnsiString;
    function ToCanonical(ASymbolId: Integer): AnsiString;
    function FromCanonical(const ACanonical: AnsiString): Integer;

    // Market data
    function LTP(const ASymbol: AnsiString; AExchange: TExchange): Double;
    function HistoryJson(const ASymbol: AnsiString; AExchange: TExchange;
      const AFrom, ATo, AInterval: AnsiString): AnsiString;

    // Account
    function AvailableMargin: Double;
    function UsedMargin: Double;
    function PositionsJson: AnsiString;
    function FundsJson: AnsiString;
    function ExitPosition(const ASymbol: AnsiString; AExchange: TExchange): Boolean;

    // Orders
    function PlaceOrder(const ASymbol: AnsiString; AExchange: TExchange;
      ASide: TSide; AKind: TOrderKind; AProduct: TProductType; AValidity: TValidity;
      AQty: Integer; APrice, ATriggerPrice: Double;
      const ATag: AnsiString = ''): AnsiString;
    function ModifyOrder(const AOrderId: AnsiString; AKind: TOrderKind;
      AQty: Integer; APrice, ATriggerPrice: Double): Boolean;
    function CancelOrder(const AOrderId: AnsiString): Boolean;

    // Streaming
    procedure SetCallbacks(
      AOnTick:       TBrokerTickCb;
      AOnDepth:      TBrokerDepthCb;
      AOnCandle:     TBrokerCandleCb;
      AOnOrder:      TBrokerOrderCb;
      AOnConnect:    TBrokerConnectCb;
      AOnDisconnect: TBrokerDisconnectCb;
      AUserData:     Pointer = nil);
    function StreamStart: Boolean;
    procedure StreamStop;
    function Subscribe(const ASymbol: AnsiString; AExchange: TExchange;
      AMode: TSubMode = smLTP): Boolean;
    procedure Unsubscribe(const ASymbol: AnsiString; AExchange: TExchange);
    function SubscribeOrders: Boolean;

    // Properties
    property Name:            AnsiString read GetName;
    property IsConnected:     Boolean    read GetIsConnected;
    property InstrumentCount: Integer    read GetInstrumentCount;
    property TickCount:       Int64      read GetTickCount;
    property BaseUrl:         AnsiString read FBaseUrl;
  end;

function ThoriumBrokerVersion: Integer;

implementation

uses
  StrUtils, DateUtils, Math;

const
  THORIUM_DEFAULT_WS_PORT = '8765';

// ── Helpers ──────────────────────────────────────────────────────────────────

function ThoriumBrokerVersion: Integer;
begin
  Result := 1;
end;

function StripScheme(const AUrl: AnsiString; out AHost, APort: AnsiString;
  out ATls: Boolean): Boolean;
var
  S: AnsiString;
  P: Integer;
begin
  Result := False;
  S := AUrl;
  ATls := False;
  if Pos('http://', S) = 1 then
    Delete(S, 1, 7)
  else if Pos('https://', S) = 1 then
  begin
    Delete(S, 1, 8);
    ATls := True;
  end
  else
    Exit(False);
  P := Pos('/', S);
  if P > 0 then SetLength(S, P - 1);
  P := Pos(':', S);
  if P > 0 then
  begin
    AHost := Copy(S, 1, P - 1);
    APort := Copy(S, P + 1, MaxInt);
  end
  else
  begin
    AHost := S;
    if ATls then APort := '443' else APort := '80';
  end;
  Result := AHost <> '';
end;

function JsonEscape(const S: AnsiString): AnsiString;
var
  I: Integer;
  C: AnsiChar;
begin
  Result := '';
  for I := 1 to Length(S) do
  begin
    C := S[I];
    case C of
      '"':  Result := Result + '\"';
      '\':  Result := Result + '\\';
      #8:   Result := Result + '\b';
      #9:   Result := Result + '\t';
      #10:  Result := Result + '\n';
      #12:  Result := Result + '\f';
      #13:  Result := Result + '\r';
    else
      if Ord(C) < 32 then
        Result := Result + Format('\u%4.4x', [Ord(C)])
      else
        Result := Result + C;
    end;
  end;
end;

// VariantToInteger / VariantToDouble fallbacks for fields that may be
// serialized as strings (Thorium emits cash fields as 2-decimal INR strings).
function VarToFloatLoose(const V: variant): Double;
var
  S: string;
begin
  if VarIsNumeric(V) then
    Result := V
  else if VarIsStr(V) then
  begin
    S := VarToStr(V);
    Result := StrToFloatDef(S, 0);
  end
  else
    Result := 0;
end;

function VarToInt64Loose(const V: variant): Int64;
var
  S: string;
begin
  if VarIsNumeric(V) then
    Result := V
  else if VarIsStr(V) then
  begin
    S := VarToStr(V);
    Result := StrToInt64Def(S, 0);
  end
  else
    Result := 0;
end;

// ── TBroker ──────────────────────────────────────────────────────────────────

constructor TBroker.Create(const ABaseUrl, AApiKey: AnsiString);
var
  Host, Port: AnsiString;
  Tls: Boolean;
begin
  inherited Create;
  if ABaseUrl = '' then
    FBaseUrl := 'http://127.0.0.1:5000'
  else
    FBaseUrl := ABaseUrl;
  FApiKey := AApiKey;

  if not StripScheme(FBaseUrl, Host, Port, Tls) then
    raise EBrokerError.CreateFmt('Invalid base URL: %s', [FBaseUrl]);
  FWsHost := Host;
  FWsPort := THORIUM_DEFAULT_WS_PORT;

  FSymToId := TStringList.Create;
  FSymToId.CaseSensitive := False;
  FSymToId.Sorted := False;
  FIdKeys  := TStringList.Create;
  FSubs    := TStringList.Create;
  FExchCache := TStringList.Create;
  FExchCache.CaseSensitive := False;

  FSymLock  := TCriticalSection.Create;
  FSubLock  := TCriticalSection.Create;
  FWsLock   := TCriticalSection.Create;
  FExchLock := TCriticalSection.Create;

  FConnected       := False;
  FStreamRunning   := False;
  FOrdersSubscribed := False;
  FTickCount       := 0;
  FInstrumentCount := 0;
end;

destructor TBroker.Destroy;
begin
  StreamStop;
  FreeAndNil(FSymToId);
  FreeAndNil(FIdKeys);
  FreeAndNil(FSubs);
  FreeAndNil(FExchCache);
  FreeAndNil(FSymLock);
  FreeAndNil(FSubLock);
  FreeAndNil(FWsLock);
  FreeAndNil(FExchLock);
  inherited;
end;

function TBroker.ExchangeStr(const ASym: AnsiString; AEx: TExchange): AnsiString;
begin
  // Naive mapping — used as the first-attempt exchange before any catalog
  // probe. Auto-detect (ResolveExchange) refines this for indices.
  case AEx of
    exNSE: Result := 'NSE';
    exBSE: Result := 'BSE';
    exNFO: Result := 'NFO';
    exBFO: Result := 'BFO';
    exMCX: Result := 'MCX';
    exCDS: Result := 'CDS';
  else
    Result := 'NSE';
  end;
end;

function TBroker.ProbeSymbol(const ASym, AExchStr: AnsiString): Boolean;
var
  Body, Resp, Data: variant;
begin
  Result := False;
  if (ASym = '') or (AExchStr = '') then Exit;
  Body := _ObjFast(['symbol', string(ASym), 'exchange', string(AExchStr)]);
  Resp := HttpPostJson('/api/v1/symbol', Body);
  Result := StatusOk(Resp, Data);
end;

function TBroker.ResolveExchange(const ASym: AnsiString;
  AEx: TExchange): AnsiString;
var
  CacheKey, First, Alt: AnsiString;
  Idx: Integer;
begin
  // Only NSE/BSE have the equity-vs-index ambiguity; other segments map 1:1.
  if not (AEx in [exNSE, exBSE]) then
    Exit(ExchangeStr(ASym, AEx));

  CacheKey := UpperCase(ASym) + '|' + IntToStr(Ord(AEx));
  FExchLock.Enter;
  try
    Idx := FExchCache.IndexOfName(string(CacheKey));
    if Idx >= 0 then
      Exit(AnsiString(FExchCache.ValueFromIndex[Idx]));
  finally
    FExchLock.Leave;
  end;

  First := ExchangeStr(ASym, AEx);
  if AEx = exNSE then Alt := 'NSE_INDEX' else Alt := 'BSE_INDEX';

  if ProbeSymbol(ASym, First) then
    Result := First
  else if ProbeSymbol(ASym, Alt) then
    Result := Alt
  else
    Result := First;  // both failed — keep naive form so subsequent calls
                      // don't re-probe; downstream HTTP will surface the miss.

  FExchLock.Enter;
  try
    FExchCache.Add(string(CacheKey) + '=' + string(Result));
  finally
    FExchLock.Leave;
  end;
end;

function TBroker.SideStr(ASide: TSide): AnsiString;
begin
  if ASide = sdBuy then Result := 'BUY' else Result := 'SELL';
end;

function TBroker.PriceTypeStr(AKind: TOrderKind): AnsiString;
begin
  case AKind of
    okMarket:    Result := 'MARKET';
    okLimit:     Result := 'LIMIT';
    okStopLoss:  Result := 'SL';
    okStopLimit: Result := 'SL-M';
  else
    Result := 'MARKET';
  end;
end;

function TBroker.ProductStr(AProd: TProductType): AnsiString;
begin
  case AProd of
    ptCNC:      Result := 'CNC';
    ptIntraday: Result := 'MIS';
    ptMargin:   Result := 'NRML';
  else
    Result := 'MIS';
  end;
end;

function TBroker.OptionTypeStr(AOpt: TOptionType): AnsiString;
begin
  if AOpt = otCall then Result := 'CE'
  else if AOpt = otPut then Result := 'PE'
  else Result := '';
end;

// ── HTTP plumbing (mORMot 2 — TSimpleHttpClient + TDocVariant) ───────────────

function TBroker.HttpPostJson(const APath: RawUtf8;
  const ABody: variant): variant;
var
  HTTP: TSimpleHttpClient;
  Url, BodyJson: RawUtf8;
  D: PDocVariantData;
  Status: Integer;
begin
  // VarClear leaves Result as Unassigned — caller treats that as transport
  // failure. mORMot's variant semantics: VarIsClear/VarIsEmpty match.
  VarClear(Result);

  // Inject apikey into the request body if not already present.
  D := _Safe(ABody);
  if (FApiKey <> '') and (D^.GetValueIndex('apikey') < 0) then
    D^.AddValue('apikey', FApiKey);

  Url := RawUtf8(FBaseUrl) + APath;
  BodyJson := VariantSaveJson(ABody);

  HTTP := TSimpleHttpClient.Create;
  try
    try
      Status := HTTP.Request(Url, 'POST', '', BodyJson, 'application/json', 0);
    except
      on E: Exception do
      begin
        FLastError := AnsiString(Format('POST %s failed: %s',
          [string(Url), E.Message]));
        Exit;
      end;
    end;
    if HTTP.Body = '' then
    begin
      FLastError := AnsiString(Format('POST %s: empty response (HTTP %d)',
        [string(Url), Status]));
      Exit;
    end;
    try
      Result := _Json(string(HTTP.Body));
    except
      on E: Exception do
      begin
        FLastError := AnsiString('Invalid JSON response: ' + E.Message);
        VarClear(Result);
      end;
    end;
  finally
    HTTP.Free;
  end;
end;

function TBroker.StatusOk(const AResp: variant; out AData: variant): Boolean;
var
  D: PDocVariantData;
  Status, Msg: RawUtf8;
begin
  VarClear(AData);
  Result := False;
  if VarIsClear(AResp) or VarIsEmpty(AResp) then Exit;
  D := _Safe(AResp);
  if D^.Kind <> dvObject then Exit;
  if not D^.GetAsRawUtf8('status', Status) then
  begin
    FLastError := 'response missing status field';
    Exit;
  end;
  if Status <> 'success' then
  begin
    if D^.GetAsRawUtf8('message', Msg) then
      FLastError := AnsiString(Msg)
    else
      FLastError := AnsiString('broker returned status=' + Status);
    Exit;
  end;
  // Some endpoints carry the payload under "data"; place/cancel/modify
  // return the orderid at top level. Caller decides which.
  AData := D^.Value['data'];
  Result := True;
end;

// ── Connection ───────────────────────────────────────────────────────────────

function TBroker.Connect: Boolean;
var
  Resp, Data: variant;
  Msg: AnsiString;
begin
  Result := False;

  // Liveness: POST /api/v1/ping (no auth required).
  Resp := HttpPostJson('/api/v1/ping', _ObjFast([]));
  if VarIsClear(Resp) then
  begin
    if FLastError = '' then FLastError := 'thorium not reachable';
    Exit;
  end;
  if not StatusOk(Resp, Data) then Exit;

  // Auth probe: POST /api/v1/funds. Three outcomes worth distinguishing:
  //   - status:success → broker attached, apikey accepted.
  //   - status:error + apikey/forbidden message → fail Connect.
  //   - status:error + anything else (e.g. no broker) → auth ok, accept.
  Resp := HttpPostJson('/api/v1/funds', _ObjFast([]));
  if VarIsClear(Resp) then
  begin
    if FLastError = '' then FLastError := 'thorium funds probe failed';
    Exit;
  end;
  if StatusOk(Resp, Data) then
  begin
    FConnected := True;
    FLastError := '';
    Exit(True);
  end;
  Msg := LowerCase(FLastError);
  if (Pos('apikey', Msg) > 0) or (Pos('api key', Msg) > 0)
     or (Pos('unauthor', Msg) > 0) or (Pos('forbidden', Msg) > 0) then
    Exit;
  FConnected := True;
  Result := True;
end;

function TBroker.Disconnect: Boolean;
begin
  StreamStop;
  FConnected := False;
  Result := True;
end;

function TBroker.SetToken(const AToken: AnsiString): Boolean;
begin
  FApiKey := AToken;
  Result := True;
end;

function TBroker.LastError: AnsiString;
begin
  Result := FLastError;
end;

function TBroker.GetName: AnsiString;
begin
  Result := 'thorium';
end;

function TBroker.GetIsConnected: Boolean;
begin
  Result := FConnected;
end;

function TBroker.GetInstrumentCount: Integer;
begin
  Result := FInstrumentCount;
end;

function TBroker.GetTickCount: Int64;
begin
  Result := FTickCount;
end;

// ── Symbol↔Id mapping ────────────────────────────────────────────────────────

function TBroker.GetOrCreateSymId(const ASym, AExch: AnsiString): Integer;
var
  Key: AnsiString;
  Idx: Integer;
begin
  Key := UpperCase(ASym) + '|' + UpperCase(AExch);
  FSymLock.Enter;
  try
    Idx := FSymToId.IndexOf(string(Key));
    if Idx >= 0 then
      Exit(PtrInt(FSymToId.Objects[Idx]));
    FIdKeys.Add(string(Key));
    Result := FIdKeys.Count - 1;
    FSymToId.AddObject(string(Key), TObject(PtrInt(Result)));
  finally
    FSymLock.Leave;
  end;
end;

function TBroker.SymKey(ASymbolId: Integer): AnsiString;
begin
  FSymLock.Enter;
  try
    if (ASymbolId >= 0) and (ASymbolId < FIdKeys.Count) then
      Result := AnsiString(FIdKeys[ASymbolId])
    else
      Result := '';
  finally
    FSymLock.Leave;
  end;
end;

function TBroker.ParseSymKey(const AKey: AnsiString;
  out ASym, AExch: AnsiString): Boolean;
var
  P: Integer;
begin
  P := Pos('|', AKey);
  if P <= 0 then Exit(False);
  ASym  := Copy(AKey, 1, P - 1);
  AExch := Copy(AKey, P + 1, MaxInt);
  Result := (ASym <> '') and (AExch <> '');
end;

// ── Catalog ──────────────────────────────────────────────────────────────────

function TBroker.FindInstrument(const ASymbol: AnsiString;
  AExchange: TExchange): Integer;
var
  ExchStr: AnsiString;
begin
  Result := -1;
  if ASymbol = '' then Exit;
  ExchStr := ResolveExchange(ASymbol, AExchange);
  if not ProbeSymbol(ASymbol, ExchStr) then Exit;
  Result := GetOrCreateSymId(ASymbol, ExchStr);
end;

function TBroker.CatalogSymbol(ASymbolId: Integer): AnsiString;
var
  Sym, Exch: AnsiString;
begin
  if ParseSymKey(SymKey(ASymbolId), Sym, Exch) then
    Result := Sym
  else
    Result := '';
end;

function TBroker.InstrumentKey(ASymbolId: Integer): AnsiString;
var
  Sym, Exch: AnsiString;
begin
  if ParseSymKey(SymKey(ASymbolId), Sym, Exch) then
    Result := Exch + '|' + Sym
  else
    Result := '';
end;

function TBroker.InstrumentJson(ASymbolId: Integer): AnsiString;
var
  Sym, Exch: AnsiString;
  Body, Resp, Data: variant;
begin
  Result := '{}';
  if not ParseSymKey(SymKey(ASymbolId), Sym, Exch) then Exit;
  Body := _ObjFast(['symbol', string(Sym), 'exchange', string(Exch)]);
  Resp := HttpPostJson('/api/v1/symbol', Body);
  if not StatusOk(Resp, Data) then Exit;
  if not VarIsClear(Data) then
    Result := AnsiString(VariantSaveJson(Data));
end;

function TBroker.ListExpiriesJson(const AUnderlying: AnsiString;
  AExchange: TExchange): AnsiString;
var
  Body, Resp, Data: variant;
  ExpArr: PDocVariantData;
  Out: TDocVariantData;
  S: RawUtf8;
  Y, M, D, I: Integer;
  DT: TDateTime;
  MonthName: string;
  ItemObj: variant;
begin
  // Output shape (preserved from the pre-Thorium era):
  //   [{"label":"24APR26","expiry":"2026-04-24","unix":1714521600}, ...]
  Result := '[]';
  Body := _ObjFast(['symbol', string(AUnderlying)]);
  Resp := HttpPostJson('/api/v1/expiry', Body);
  if not StatusOk(Resp, Data) then Exit;
  if _Safe(Data)^.Kind <> dvObject then Exit;
  if not _Safe(Data)^.GetAsArray('expiries', ExpArr) then Exit;

  Out.InitArray([], JSON_FAST);
  for I := 0 to ExpArr^.Count - 1 do
  begin
    S := VariantToUtf8(ExpArr^.Values[I]);
    if (Length(S) <> 10)
       or not TryStrToInt(Copy(string(S), 1, 4), Y)
       or not TryStrToInt(Copy(string(S), 6, 2), M)
       or not TryStrToInt(Copy(string(S), 9, 2), D) then
      Continue;
    DT := EncodeDate(Y, M, D);
    case M of
      1: MonthName := 'JAN';  2: MonthName := 'FEB';  3: MonthName := 'MAR';
      4: MonthName := 'APR';  5: MonthName := 'MAY';  6: MonthName := 'JUN';
      7: MonthName := 'JUL';  8: MonthName := 'AUG';  9: MonthName := 'SEP';
     10: MonthName := 'OCT'; 11: MonthName := 'NOV'; 12: MonthName := 'DEC';
    else MonthName := '???';
    end;
    ItemObj := _ObjFast([
      'label',  Format('%.2d%s%.2d', [D, MonthName, Y mod 100]),
      'expiry', string(S),
      'unix',   Int64(DateTimeToUnix(DT))
    ]);
    Out.AddItem(ItemObj);
  end;
  Result := AnsiString(Out.ToJson);
end;

function TBroker.NearestExpiry(const AUnderlying: AnsiString;
  AExchange: TExchange): Int64;
var
  Body, Resp, Data: variant;
  ExpArr: PDocVariantData;
  S: RawUtf8;
  Y, M, D: Integer;
begin
  Result := 0;
  Body := _ObjFast(['symbol', string(AUnderlying)]);
  Resp := HttpPostJson('/api/v1/expiry', Body);
  if not StatusOk(Resp, Data) then Exit;
  if _Safe(Data)^.Kind <> dvObject then Exit;
  if not _Safe(Data)^.GetAsArray('expiries', ExpArr) then Exit;
  if ExpArr^.Count = 0 then Exit;
  S := VariantToUtf8(ExpArr^.Values[0]);  // first expiry — server returns sorted
  if (Length(S) = 10)
     and TryStrToInt(Copy(string(S), 1, 4), Y)
     and TryStrToInt(Copy(string(S), 6, 2), M)
     and TryStrToInt(Copy(string(S), 9, 2), D) then
    Result := DateTimeToUnix(EncodeDate(Y, M, D));
end;

function TBroker.ListStrikesJson(const AUnderlying: AnsiString;
  AExpiryUnix: Int64; AExchange: TExchange): AnsiString;
var
  Body, Resp, Data: variant;
  Chain: PDocVariantData;
  Out: TDocVariantData;
  Item, CE, PE: PDocVariantData;
  Row: variant;
  ExpStr: AnsiString;
  I: Integer;
begin
  // Output shape (preserved from the pre-Thorium era):
  //   [{"strike":24000,"ce_key":"NIFTY28APR2524000CE","pe_key":"...PE",
  //     "ce_oi":...,"pe_oi":...,"ce_vol":...,"pe_vol":...}, ...]
  Result := '[]';
  if AExpiryUnix > 0 then
  begin
    ExpStr := AnsiString(FormatDateTime('yyyy-mm-dd', UnixToDateTime(AExpiryUnix)));
    Body := _ObjFast(['underlying', string(AUnderlying), 'expiry_date', string(ExpStr)]);
  end
  else
    Body := _ObjFast(['underlying', string(AUnderlying)]);

  Resp := HttpPostJson('/api/v1/optionchain', Body);
  if not StatusOk(Resp, Data) then Exit;
  if _Safe(Data)^.Kind <> dvObject then Exit;
  if not _Safe(Data)^.GetAsArray('chain', Chain) then Exit;

  Out.InitArray([], JSON_FAST);
  for I := 0 to Chain^.Count - 1 do
  begin
    Item := _Safe(Chain^.Values[I]);
    if Item^.Kind <> dvObject then Continue;
    if Item^.GetValueIndex('strike') < 0 then Continue;

    Row := _ObjFast(['strike', Item^.D['strike']]);
    CE := _Safe(Item^.Value['ce']);
    if CE^.Kind = dvObject then
    begin
      _Safe(Row)^.AddValue('ce_key', CE^.U['symbol']);
      _Safe(Row)^.AddValue('ce_oi',  CE^.I['oi']);
      _Safe(Row)^.AddValue('ce_vol', CE^.I['volume']);
    end
    else
    begin
      _Safe(Row)^.AddValue('ce_key', '');
      _Safe(Row)^.AddValue('ce_oi',  Int64(0));
      _Safe(Row)^.AddValue('ce_vol', Int64(0));
    end;
    PE := _Safe(Item^.Value['pe']);
    if PE^.Kind = dvObject then
    begin
      _Safe(Row)^.AddValue('pe_key', PE^.U['symbol']);
      _Safe(Row)^.AddValue('pe_oi',  PE^.I['oi']);
      _Safe(Row)^.AddValue('pe_vol', PE^.I['volume']);
    end
    else
    begin
      _Safe(Row)^.AddValue('pe_key', '');
      _Safe(Row)^.AddValue('pe_oi',  Int64(0));
      _Safe(Row)^.AddValue('pe_vol', Int64(0));
    end;
    Out.AddItem(Row);
  end;
  Result := AnsiString(Out.ToJson);
end;

function TBroker.ATMStrike(const AUnderlying: AnsiString; AExpiryUnix: Int64;
  ASpot: Double): Double;
var
  Json: AnsiString;
  Strikes: TDocVariantData;
  Item: PDocVariantData;
  I: Integer;
  S, Best, BestDiff, Diff: Double;
begin
  Json := ListStrikesJson(AUnderlying, AExpiryUnix, exNFO);
  Best := 0;
  BestDiff := 1e18;
  Strikes.InitJson(RawUtf8(Json), JSON_FAST);
  if Strikes.Kind = dvArray then
  begin
    for I := 0 to Strikes.Count - 1 do
    begin
      Item := _Safe(Strikes.Values[I]);
      if Item^.Kind <> dvObject then Continue;
      S := Item^.D['strike'];
      if S <= 0 then Continue;
      Diff := Abs(S - ASpot);
      if Diff < BestDiff then
      begin
        BestDiff := Diff;
        Best := S;
      end;
    end;
  end;
  if Best > 0 then Exit(Best);

  // Fallback heuristic if the chain endpoint returned nothing.
  if (UpperCase(AUnderlying) = 'BANKNIFTY')
     or (UpperCase(AUnderlying) = 'SENSEX')
     or (UpperCase(AUnderlying) = 'BANKEX') then
    Result := Round(ASpot / 100) * 100
  else
    Result := Round(ASpot / 50) * 50;
end;

function TBroker.ResolveOption(const AUnderlying: AnsiString; AExpiryUnix: Int64;
  AStrike: Double; AOptionType: TOptionType; AExchange: TExchange): Integer;
var
  Body, Resp, Data: variant;
  ExpStr, Sym: AnsiString;
begin
  Result := -1;
  if (AOptionType = otNone) or (AExpiryUnix <= 0) then Exit;
  ExpStr := AnsiString(FormatDateTime('yyyy-mm-dd', UnixToDateTime(AExpiryUnix)));
  Body := _ObjFast([
    'symbol',      string(AUnderlying),
    'expiry',      string(ExpStr),
    'strike',      AStrike,
    'option_type', string(OptionTypeStr(AOptionType))
  ]);
  Resp := HttpPostJson('/api/v1/optionsymbol', Body);
  if not StatusOk(Resp, Data) then Exit;
  if _Safe(Data)^.Kind <> dvObject then Exit;
  Sym := AnsiString(string(_Safe(Data)^.U['symbol']));
  if Sym = '' then Exit;
  Result := GetOrCreateSymId(Sym, ResolveExchange(Sym, AExchange));
end;

function TBroker.SearchJson(const AQuery: AnsiString; AExchange: TExchange;
  AMaxResults: Integer): AnsiString;
var
  Body, Resp, Data: variant;
begin
  Result := '[]';
  if AMaxResults > 0 then
    Body := _ObjFast(['query', string(AQuery), 'limit', AMaxResults])
  else
    Body := _ObjFast(['query', string(AQuery)]);
  Resp := HttpPostJson('/api/v1/search', Body);
  if not StatusOk(Resp, Data) then Exit;
  if _Safe(Data)^.Kind = dvArray then
    Result := AnsiString(VariantSaveJson(Data));
end;

// ── Symbol mapping (identity over Thorium's CID model) ───────────────────────

function TBroker.ToBrokerKey(const ACanonical: AnsiString): AnsiString;
begin
  Result := ACanonical;
end;

function TBroker.FromBrokerKey(const ABrokerKey: AnsiString): AnsiString;
begin
  Result := ABrokerKey;
end;

function TBroker.ToCanonical(ASymbolId: Integer): AnsiString;
begin
  Result := CatalogSymbol(ASymbolId);
end;

function TBroker.FromCanonical(const ACanonical: AnsiString): Integer;
var
  I: Integer;
  Sym, Exch: AnsiString;
begin
  FSymLock.Enter;
  try
    for I := 0 to FIdKeys.Count - 1 do
      if ParseSymKey(AnsiString(FIdKeys[I]), Sym, Exch)
         and SameText(string(Sym), string(ACanonical)) then
        Exit(I);
  finally
    FSymLock.Leave;
  end;
  Result := -1;
end;

// ── Market data ──────────────────────────────────────────────────────────────

function TBroker.LTP(const ASymbol: AnsiString; AExchange: TExchange): Double;
var
  Body, Resp, Data: variant;
begin
  Result := 0;
  Body := _ObjFast([
    'symbol',   string(ASymbol),
    'exchange', string(ResolveExchange(ASymbol, AExchange))
  ]);
  Resp := HttpPostJson('/api/v1/quotes', Body);
  if not StatusOk(Resp, Data) then Exit;
  if _Safe(Data)^.Kind = dvObject then
    Result := _Safe(Data)^.D['ltp'];
end;

function TBroker.HistoryJson(const ASymbol: AnsiString; AExchange: TExchange;
  const AFrom, ATo, AInterval: AnsiString): AnsiString;
var
  Body, Resp, Data: variant;
begin
  Result := '[]';
  Body := _ObjFast([
    'symbol',     string(ASymbol),
    'exchange',   string(ResolveExchange(ASymbol, AExchange)),
    'interval',   string(AInterval),
    'start_date', string(AFrom),
    'end_date',   string(ATo)
  ]);
  Resp := HttpPostJson('/api/v1/history', Body);
  if not StatusOk(Resp, Data) then Exit;
  if _Safe(Data)^.Kind = dvArray then
    Result := AnsiString(VariantSaveJson(Data));
end;

// ── Account ──────────────────────────────────────────────────────────────────

function TBroker.FundsJson: AnsiString;
var
  Resp, Data: variant;
begin
  Result := '{}';
  Resp := HttpPostJson('/api/v1/funds', _ObjFast([]));
  if not StatusOk(Resp, Data) then Exit;
  if not VarIsClear(Data) then
    Result := AnsiString(VariantSaveJson(Data));
end;

function TBroker.AvailableMargin: Double;
var
  Resp, Data: variant;
begin
  Result := 0;
  Resp := HttpPostJson('/api/v1/funds', _ObjFast([]));
  if not StatusOk(Resp, Data) then Exit;
  if _Safe(Data)^.Kind = dvObject then
    Result := VarToFloatLoose(_Safe(Data)^.Value['availablecash']);
end;

function TBroker.UsedMargin: Double;
var
  Resp, Data: variant;
begin
  Result := 0;
  Resp := HttpPostJson('/api/v1/funds', _ObjFast([]));
  if not StatusOk(Resp, Data) then Exit;
  if _Safe(Data)^.Kind = dvObject then
    Result := VarToFloatLoose(_Safe(Data)^.Value['utiliseddebits']);
end;

function TBroker.PositionsJson: AnsiString;
var
  Resp, Data: variant;
begin
  Result := '[]';
  Resp := HttpPostJson('/api/v1/positionbook', _ObjFast([]));
  if not StatusOk(Resp, Data) then Exit;
  if _Safe(Data)^.Kind = dvArray then
    Result := AnsiString(VariantSaveJson(Data));
end;

function TBroker.ExitPosition(const ASymbol: AnsiString;
  AExchange: TExchange): Boolean;
var
  Body, Resp, Data: variant;
begin
  Body := _ObjFast([
    'symbol',   string(ASymbol),
    'exchange', string(ResolveExchange(ASymbol, AExchange)),
    'product',  'MIS'
  ]);
  Resp := HttpPostJson('/api/v1/closeposition', Body);
  Result := StatusOk(Resp, Data);
end;

// ── Orders ───────────────────────────────────────────────────────────────────

function TBroker.PlaceOrder(const ASymbol: AnsiString; AExchange: TExchange;
  ASide: TSide; AKind: TOrderKind; AProduct: TProductType; AValidity: TValidity;
  AQty: Integer; APrice, ATriggerPrice: Double; const ATag: AnsiString): AnsiString;
var
  Body, Resp: variant;
  D: PDocVariantData;
  Status: RawUtf8;
begin
  Result := '';
  Body := _ObjFast([
    'symbol',    string(ASymbol),
    'exchange',  string(ResolveExchange(ASymbol, AExchange)),
    'action',    string(SideStr(ASide)),
    'quantity',  AQty,
    'pricetype', string(PriceTypeStr(AKind)),
    'product',   string(ProductStr(AProduct))
  ]);
  D := _Safe(Body);
  if APrice > 0 then        D^.AddValue('price', APrice);
  if ATriggerPrice > 0 then D^.AddValue('trigger_price', ATriggerPrice);
  if ATag <> '' then        D^.AddValue('strategy', string(ATag));

  Resp := HttpPostJson('/api/v1/placeorder', Body);
  if VarIsClear(Resp) then
    raise EBrokerError.CreateFmt('place_order failed: %s', [FLastError]);

  D := _Safe(Resp);
  if D^.Kind <> dvObject then
    raise EBrokerError.Create('place_order: unexpected response shape');
  if not D^.GetAsRawUtf8('status', Status) or (Status <> 'success') then
  begin
    if not D^.GetAsRawUtf8('message', Status) then Status := 'unknown';
    FLastError := AnsiString(Status);
    raise EBrokerError.CreateFmt('place_order failed: %s', [FLastError]);
  end;
  Result := AnsiString(string(D^.U['orderid']));
end;

function TBroker.ModifyOrder(const AOrderId: AnsiString; AKind: TOrderKind;
  AQty: Integer; APrice, ATriggerPrice: Double): Boolean;
var
  Body, Resp, Data: variant;
  D: PDocVariantData;
begin
  Body := _ObjFast([
    'orderid',   string(AOrderId),
    'quantity',  AQty,
    'pricetype', string(PriceTypeStr(AKind))
  ]);
  D := _Safe(Body);
  if APrice > 0 then        D^.AddValue('price', APrice);
  if ATriggerPrice > 0 then D^.AddValue('trigger_price', ATriggerPrice);
  Resp := HttpPostJson('/api/v1/modifyorder', Body);
  Result := StatusOk(Resp, Data);
end;

function TBroker.CancelOrder(const AOrderId: AnsiString): Boolean;
var
  Body, Resp, Data: variant;
begin
  Body := _ObjFast(['orderid', string(AOrderId)]);
  Resp := HttpPostJson('/api/v1/cancelorder', Body);
  Result := StatusOk(Resp, Data);
end;

// ── Streaming ────────────────────────────────────────────────────────────────

procedure TBroker.SetCallbacks(
  AOnTick:       TBrokerTickCb;
  AOnDepth:      TBrokerDepthCb;
  AOnCandle:     TBrokerCandleCb;
  AOnOrder:      TBrokerOrderCb;
  AOnConnect:    TBrokerConnectCb;
  AOnDisconnect: TBrokerDisconnectCb;
  AUserData:     Pointer);
begin
  FOnTick       := AOnTick;
  FOnDepth      := AOnDepth;
  FOnCandle     := AOnCandle;
  FOnOrder      := AOnOrder;
  FOnConnect    := AOnConnect;
  FOnDisconnect := AOnDisconnect;
  FUserData     := AUserData;
end;

function TBroker.WsSendJson(const AJson: AnsiString): Boolean;
var
  Frame: TWebSocketFrame;
begin
  Result := False;
  FWsLock.Enter;
  try
    if (FWsClient = nil) or (FWsProtocol = nil)
       or (FWsClient.WebSockets = nil) then Exit;
    FillChar(Frame, SizeOf(Frame), 0);
    Frame.opcode  := focText;
    Frame.payload := RawByteString(AJson);
    Result := FWsProtocol.SendFrame(FWsClient.WebSockets, Frame);
  finally
    FWsLock.Leave;
  end;
end;

function TBroker.WsAuthenticate: Boolean;
var
  Body: AnsiString;
begin
  // Send both `apikey` and `api_key` — Thorium docs use one form, the
  // OpenAlgo bridge spec uses the other; either field is sufficient.
  Body := AnsiString(Format('{"action":"authenticate","apikey":"%s","api_key":"%s"}',
    [JsonEscape(FApiKey), JsonEscape(FApiKey)]));
  Result := WsSendJson(Body);
end;

procedure TBroker.WsResubscribeAll;
var
  I: Integer;
  Sym, Exch, Mode: AnsiString;
  Parts: TStringArray;
  Body: AnsiString;
begin
  FSubLock.Enter;
  try
    for I := 0 to FSubs.Count - 1 do
    begin
      Parts := SplitString(FSubs[I], '|');
      if Length(Parts) < 3 then Continue;
      Sym  := AnsiString(Parts[0]);
      Exch := AnsiString(Parts[1]);
      Mode := AnsiString(Parts[2]);
      Body := AnsiString(Format(
        '{"action":"subscribe","symbol":"%s","exchange":"%s","mode":%s}',
        [JsonEscape(Sym), JsonEscape(Exch), Mode]));
      WsSendJson(Body);
    end;
  finally
    FSubLock.Leave;
  end;
end;

procedure TBroker.DispatchTick(const ATick: variant; const ARawText: AnsiString);
var
  D: PDocVariantData;
  Sym, Exch, Key: AnsiString;
  SymId, Idx: Integer;
  LTPv, Bid, Ask: Double;
  Vol, OI: Int64;
begin
  D := _Safe(ATick);
  if D^.Kind <> dvObject then Exit;
  Sym  := AnsiString(string(D^.U['symbol']));
  Exch := AnsiString(string(D^.U['exchange']));
  if (Sym = '') or (Exch = '') then Exit;
  Key := UpperCase(Sym) + '|' + UpperCase(Exch);

  FSymLock.Enter;
  try
    Idx := FSymToId.IndexOf(string(Key));
    if Idx >= 0 then SymId := PtrInt(FSymToId.Objects[Idx])
    else
    begin
      // Stream ahead of FindInstrument — allocate so callers can correlate.
      FIdKeys.Add(string(Key));
      SymId := FIdKeys.Count - 1;
      FSymToId.AddObject(string(Key), TObject(PtrInt(SymId)));
    end;
  finally
    FSymLock.Leave;
  end;

  LTPv := D^.D['ltp'];
  Bid  := D^.D['bid'];
  Ask  := D^.D['ask'];
  Vol  := D^.I['volume'];
  OI   := D^.I['oi'];
  Inc(FTickCount);

  if Assigned(FOnTick) then
    FOnTick(FUserData, SymId, LTPv, Bid, Ask, Vol, OI);
end;

procedure TBroker.WsIncomingFrame(Sender: TWebSocketProcess;
  const Frame: TWebSocketFrame);
var
  RawText: AnsiString;
  Frm: variant;
  D: PDocVariantData;
  T, Status, Reason: RawUtf8;
begin
  case Frame.opcode of
    focContinuation:
      begin
        if Assigned(FOnConnect) then
          FOnConnect(FUserData, PAnsiChar('thorium-ws'));
      end;
    focConnectionClose:
      begin
        FStreamRunning := False;
        if Assigned(FOnDisconnect) then
          FOnDisconnect(FUserData, PAnsiChar('thorium-ws'),
            PAnsiChar('connection closed'));
      end;
    focText, focBinary:
      begin
        RawText := AnsiString(Frame.payload);
        if RawText = '' then Exit;
        try
          Frm := _Json(string(RawText));
        except
          Exit;
        end;
        D := _Safe(Frm);
        if D^.Kind <> dvObject then Exit;

        D^.GetAsRawUtf8('type', T);
        if T = 'tick' then
          DispatchTick(Frm, RawText)
        else if T = 'heartbeat' then
          Exit
        else if T = 'auth' then
        begin
          if not D^.GetAsRawUtf8('status', Status) or (Status <> 'success') then
          begin
            if not D^.GetAsRawUtf8('message', Reason) then Reason := 'auth failed';
            if Assigned(FOnDisconnect) then
              FOnDisconnect(FUserData, PAnsiChar('thorium-ws'),
                PAnsiChar(string(Reason)));
          end;
        end
        else if T = 'subscribe' then
        begin
          if D^.GetAsRawUtf8('status', Status) and (Status <> 'success') then
            if D^.GetAsRawUtf8('message', Reason) then
              FLastError := AnsiString(Reason);
        end
        else if D^.GetValueIndex('symbol') >= 0 then
          // Untyped tick frame.
          DispatchTick(Frm, RawText)
        else if D^.GetValueIndex('orderid') >= 0 then
        begin
          if Assigned(FOnOrder) then
            FOnOrder(FUserData, PAnsiChar(RawText));
        end;
      end;
  end;
end;

function TBroker.StreamStart: Boolean;
var
  Err: RawUtf8;
begin
  Result := False;
  FWsLock.Enter;
  try
    if FStreamRunning then Exit(True);
    FWsProtocol := TWebSocketProtocolChat.Create('', '', WsIncomingFrame);
    FWsClient := THttpClientWebSockets.WebSocketsConnect(
      RawUtf8(FWsHost), RawUtf8(FWsPort), FWsProtocol, nil, 'topaz');
    if FWsClient = nil then
    begin
      FLastError := AnsiString(Format('WS connect failed: %s:%s',
        [FWsHost, FWsPort]));
      FWsProtocol := nil;  // freed inside WebSocketsConnect on failure
      Exit;
    end;
    Err := FWsClient.WebSocketsUpgrade('/', '', false, [], FWsProtocol);
    if Err <> '' then
    begin
      FLastError := AnsiString(string(Err));
      FreeAndNil(FWsClient);
      FWsProtocol := nil;
      Exit;
    end;
    FStreamRunning := True;
  finally
    FWsLock.Leave;
  end;
  if not WsAuthenticate then
  begin
    StreamStop;
    Exit;
  end;
  WsResubscribeAll;
  Result := True;
end;

procedure TBroker.StreamStop;
begin
  FWsLock.Enter;
  try
    if FWsClient <> nil then
    begin
      try
        FWsClient.Free;
      except
        // ignore — connection may already be torn
      end;
      FWsClient := nil;
    end;
    FWsProtocol := nil;
    FStreamRunning := False;
  finally
    FWsLock.Leave;
  end;
end;

function TBroker.Subscribe(const ASymbol: AnsiString; AExchange: TExchange;
  AMode: TSubMode): Boolean;
var
  Exch, Body, SubKey: AnsiString;
  Mode: Integer;
begin
  Exch := ResolveExchange(ASymbol, AExchange);
  case AMode of
    smLTP:   Mode := 1;
    smQuote: Mode := 2;
    smFull:  Mode := 2;  // Thorium rejects mode=3; cap at quote.
  else
    Mode := 1;
  end;

  GetOrCreateSymId(ASymbol, Exch);

  SubKey := ASymbol + '|' + Exch + '|' + AnsiString(IntToStr(Mode));
  FSubLock.Enter;
  try
    if FSubs.IndexOf(string(SubKey)) < 0 then
      FSubs.Add(string(SubKey));
  finally
    FSubLock.Leave;
  end;

  if not FStreamRunning then
    Exit(True);

  Body := AnsiString(Format(
    '{"action":"subscribe","symbol":"%s","exchange":"%s","mode":%d}',
    [JsonEscape(ASymbol), JsonEscape(Exch), Mode]));
  Result := WsSendJson(Body);
end;

procedure TBroker.Unsubscribe(const ASymbol: AnsiString; AExchange: TExchange);
var
  Exch, Body, Prefix: AnsiString;
  I: Integer;
begin
  Exch := ResolveExchange(ASymbol, AExchange);
  Prefix := ASymbol + '|' + Exch + '|';
  FSubLock.Enter;
  try
    for I := FSubs.Count - 1 downto 0 do
      if Pos(string(Prefix), FSubs[I]) = 1 then
        FSubs.Delete(I);
  finally
    FSubLock.Leave;
  end;
  if not FStreamRunning then Exit;
  Body := AnsiString(Format(
    '{"action":"unsubscribe","symbol":"%s","exchange":"%s"}',
    [JsonEscape(ASymbol), JsonEscape(Exch)]));
  WsSendJson(Body);
end;

function TBroker.SubscribeOrders: Boolean;
var
  Body: AnsiString;
begin
  FOrdersSubscribed := True;
  if not FStreamRunning then
    Exit(True);
  Body := '{"action":"subscribe_orders"}';
  WsSendJson(Body);
  Result := True;
end;

end.
