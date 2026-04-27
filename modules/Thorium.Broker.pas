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
  SysUtils, Classes, SyncObjs, fpjson, jsonparser, fphttpclient, opensslsockets,
  mormot.core.base, mormot.core.text,
  mormot.net.ws.core, mormot.net.ws.client;

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
    // Lets caller pass exNSE for an index without us knowing in advance
    // whether NSE or NSE_INDEX is the right CIDExchange.
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

    function HttpPostJson(const APath: AnsiString;
      ABody: TJSONObject): TJSONData;
    function StatusOk(AResp: TJSONData; out AData: TJSONData): Boolean;

    function GetOrCreateSymId(const ASym, AExch: AnsiString): Integer;
    function SymKey(ASymbolId: Integer): AnsiString;
    function ParseSymKey(const AKey: AnsiString;
      out ASym, AExch: AnsiString): Boolean;

    procedure WsIncomingFrame(Sender: TWebSocketProcess;
      const Frame: TWebSocketFrame);
    procedure DispatchTickJson(AObj: TJSONObject);
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
  Body: TJSONObject;
  Resp: TJSONData;
  Data: TJSONData;
begin
  Result := False;
  if (ASym = '') or (AExchStr = '') then Exit;
  Body := TJSONObject.Create;
  try
    Body.Add('symbol',   string(ASym));
    Body.Add('exchange', string(AExchStr));
    Resp := HttpPostJson('/api/v1/symbol', Body);
  finally
    Body.Free;
  end;
  if Resp = nil then Exit;
  try
    Result := StatusOk(Resp, Data);
  finally
    Resp.Free;
  end;
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

// ── HTTP plumbing ────────────────────────────────────────────────────────────

function TBroker.HttpPostJson(const APath: AnsiString;
  ABody: TJSONObject): TJSONData;
var
  Http: TFPHTTPClient;
  Req:  TStringStream;
  Resp: TStringStream;
  Url:  AnsiString;
begin
  Result := nil;
  if (ABody.IndexOfName('apikey') < 0) and (FApiKey <> '') then
    ABody.Add('apikey', FApiKey);

  Url := FBaseUrl + APath;
  Http := TFPHTTPClient.Create(nil);
  Req  := TStringStream.Create(ABody.AsJSON);
  Resp := TStringStream.Create('');
  try
    Http.AddHeader('Content-Type', 'application/json');
    Http.AllowRedirect := True;
    Http.RequestBody := Req;
    try
      Http.Post(Url, Resp);
    except
      on E: Exception do
      begin
        FLastError := AnsiString(Format('POST %s failed: %s', [Url, E.Message]));
        Exit(nil);
      end;
    end;
    if (Http.ResponseStatusCode < 200) or (Http.ResponseStatusCode >= 300) then
    begin
      // Still try to parse body — Thorium errors come back with status:error JSON.
      if Resp.DataString = '' then
      begin
        FLastError := AnsiString(Format('HTTP %d on %s', [Http.ResponseStatusCode, APath]));
        Exit(nil);
      end;
    end;
    try
      Result := GetJSON(Resp.DataString);
    except
      on E: Exception do
      begin
        FLastError := AnsiString('Invalid JSON response: ' + E.Message);
        Result := nil;
      end;
    end;
  finally
    Resp.Free;
    Req.Free;
    Http.Free;
  end;
end;

function TBroker.StatusOk(AResp: TJSONData; out AData: TJSONData): Boolean;
var
  Obj: TJSONObject;
  Status: AnsiString;
  MsgVal: TJSONData;
begin
  AData := nil;
  Result := False;
  if (AResp = nil) or not (AResp is TJSONObject) then Exit;
  Obj := TJSONObject(AResp);
  Status := AnsiString(Obj.Get('status', ''));
  if Status <> 'success' then
  begin
    MsgVal := Obj.Find('message');
    if MsgVal <> nil then
      FLastError := AnsiString(MsgVal.AsString)
    else
      FLastError := 'broker returned status=' + Status;
    Exit;
  end;
  AData := Obj.Find('data');
  Result := True;
end;

// ── Connection ───────────────────────────────────────────────────────────────

function TBroker.Connect: Boolean;
var
  Body: TJSONObject;
  Resp: TJSONData;
  Data: TJSONData;
  Msg: AnsiString;
begin
  Result := False;

  // Liveness: POST /api/v1/ping (no auth required).
  Body := TJSONObject.Create;
  try
    Resp := HttpPostJson('/api/v1/ping', Body);
  finally
    Body.Free;
  end;
  if Resp = nil then
  begin
    if FLastError = '' then FLastError := 'thorium not reachable';
    Exit;
  end;
  try
    if not StatusOk(Resp, Data) then Exit;
  finally
    Resp.Free;
  end;

  // Auth probe: POST /api/v1/funds. Three outcomes worth distinguishing:
  //   - status:success  → broker attached, apikey accepted.
  //   - status:error + "no broker" message → apikey accepted, broker not yet
  //     attached on the server. Treat as connected; calls that need a broker
  //     will fail individually.
  //   - status:error + "invalid apikey" / 401 / 403 → fail Connect.
  Body := TJSONObject.Create;
  try
    Resp := HttpPostJson('/api/v1/funds', Body);
  finally
    Body.Free;
  end;
  if Resp = nil then
  begin
    if FLastError = '' then FLastError := 'thorium funds probe failed';
    Exit;
  end;
  try
    if StatusOk(Resp, Data) then
    begin
      FConnected := True;
      FLastError := '';
      Exit(True);
    end;
    // StatusOk left FLastError populated with the broker message.
    Msg := LowerCase(FLastError);
    if (Pos('apikey', Msg) > 0) or (Pos('api key', Msg) > 0)
       or (Pos('unauthor', Msg) > 0) or (Pos('forbidden', Msg) > 0) then
      Exit;
    // Anything else (no broker, broker not ready, etc.) — auth itself ok.
    FConnected := True;
    Result := True;
  finally
    Resp.Free;
  end;
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
    Result := FIdKeys.Count - 1;  // SymbolId = position in FIdKeys
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

function TBroker.FindInstrument(const ASymbol: AnsiString; AExchange: TExchange): Integer;
var
  ExchStr: AnsiString;
begin
  Result := -1;
  if ASymbol = '' then Exit;
  // ResolveExchange probes /api/v1/symbol; trying both equity and index
  // forms for NSE/BSE callers and caching the answer.
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
  // Compose 'EXCH|SYM' style broker key — Thorium doesn't surface a separate
  // broker key over REST without a per-symbol fetch, so use the canonical form.
  if ParseSymKey(SymKey(ASymbolId), Sym, Exch) then
    Result := Exch + '|' + Sym
  else
    Result := '';
end;

function TBroker.InstrumentJson(ASymbolId: Integer): AnsiString;
var
  Body: TJSONObject;
  Resp: TJSONData;
  Data: TJSONData;
  Sym, Exch: AnsiString;
begin
  Result := '{}';
  if not ParseSymKey(SymKey(ASymbolId), Sym, Exch) then Exit;
  Body := TJSONObject.Create;
  try
    Body.Add('symbol',   string(Sym));
    Body.Add('exchange', string(Exch));
    Resp := HttpPostJson('/api/v1/symbol', Body);
  finally
    Body.Free;
  end;
  if Resp = nil then Exit;
  try
    if StatusOk(Resp, Data) and (Data <> nil) then
      Result := AnsiString(Data.AsJSON);
  finally
    Resp.Free;
  end;
end;

function TBroker.ListExpiriesJson(const AUnderlying: AnsiString;
  AExchange: TExchange): AnsiString;
var
  Body: TJSONObject;
  Resp: TJSONData;
  Data: TJSONData;
  ExpArr: TJSONData;
  OutArr: TJSONArray;
  Item:   TJSONObject;
  S, MonthName: AnsiString;
  I, Y, M, D: Integer;
  DT: TDateTime;
begin
  // Output shape (preserved from libapollo era so consumers don't change):
  //   [{"label":"24APR26","expiry":"2026-04-24","unix":1714521600}, ...]
  Result := '[]';
  Body := TJSONObject.Create;
  try
    Body.Add('symbol', string(AUnderlying));
    Resp := HttpPostJson('/api/v1/expiry', Body);
  finally
    Body.Free;
  end;
  if Resp = nil then Exit;
  try
    if not StatusOk(Resp, Data) then Exit;
    if not (Data is TJSONObject) then Exit;
    ExpArr := TJSONObject(Data).Find('expiries');
    if (ExpArr = nil) or not (ExpArr is TJSONArray) then Exit;

    OutArr := TJSONArray.Create;
    try
      for I := 0 to TJSONArray(ExpArr).Count - 1 do
      begin
        S := AnsiString(TJSONArray(ExpArr).Strings[I]);
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
        Item := TJSONObject.Create;
        Item.Add('label',  Format('%.2d%s%.2d', [D, string(MonthName), Y mod 100]));
        Item.Add('expiry', string(S));
        Item.Add('unix',   Int64(DateTimeToUnix(DT)));
        OutArr.Add(Item);
      end;
      Result := AnsiString(OutArr.AsJSON);
    finally
      OutArr.Free;
    end;
  finally
    Resp.Free;
  end;
end;

function TBroker.NearestExpiry(const AUnderlying: AnsiString;
  AExchange: TExchange): Int64;
var
  Json: AnsiString;
  Arr: TJSONData;
  S: AnsiString;
  Y, M, D: Integer;
  DT: TDateTime;
begin
  Result := 0;
  Json := ListExpiriesJson(AUnderlying, AExchange);
  if (Json = '') or (Json = '[]') then Exit;
  Arr := nil;
  try
    Arr := GetJSON(string(Json));
    if (Arr is TJSONArray) and (TJSONArray(Arr).Count > 0) then
    begin
      S := AnsiString(TJSONArray(Arr).Strings[0]);  // 'YYYY-MM-DD'
      if (Length(S) = 10)
         and TryStrToInt(Copy(string(S), 1, 4), Y)
         and TryStrToInt(Copy(string(S), 6, 2), M)
         and TryStrToInt(Copy(string(S), 9, 2), D) then
      begin
        DT := EncodeDate(Y, M, D);
        Result := DateTimeToUnix(DT);
      end;
    end;
  finally
    Arr.Free;
  end;
end;

function TBroker.ListStrikesJson(const AUnderlying: AnsiString;
  AExpiryUnix: Int64; AExchange: TExchange): AnsiString;
var
  Body, ChainObj, ItemObj, CE, PE, StrikeRow: TJSONObject;
  Resp, Data, ChainArr, Item, Side: TJSONData;
  ExpStr: AnsiString;
  OutArr: TJSONArray;
  I: Integer;
begin
  // Output shape (preserved from libapollo era):
  //   [{"strike":24000,"ce_key":"NIFTY28APR2524000CE","pe_key":"...PE",
  //     "ce_oi":12345,"pe_oi":54321,"ce_vol":...,"pe_vol":...}, ...]
  Result := '[]';
  Body := TJSONObject.Create;
  try
    Body.Add('underlying', string(AUnderlying));
    if AExpiryUnix > 0 then
    begin
      ExpStr := AnsiString(FormatDateTime('yyyy-mm-dd', UnixToDateTime(AExpiryUnix)));
      Body.Add('expiry_date', string(ExpStr));
    end;
    Resp := HttpPostJson('/api/v1/optionchain', Body);
  finally
    Body.Free;
  end;
  if Resp = nil then Exit;
  try
    if not StatusOk(Resp, Data) then Exit;
    if not (Data is TJSONObject) then Exit;
    ChainObj := TJSONObject(Data);
    ChainArr := ChainObj.Find('chain');
    if (ChainArr = nil) or not (ChainArr is TJSONArray) then Exit;

    OutArr := TJSONArray.Create;
    try
      for I := 0 to TJSONArray(ChainArr).Count - 1 do
      begin
        Item := TJSONArray(ChainArr).Items[I];
        if not (Item is TJSONObject) then Continue;
        ItemObj := TJSONObject(Item);
        if ItemObj.Find('strike') = nil then Continue;

        StrikeRow := TJSONObject.Create;
        StrikeRow.Add('strike', ItemObj.Get('strike', Double(0)));

        Side := ItemObj.Find('ce');
        if (Side <> nil) and (Side is TJSONObject) then
        begin
          CE := TJSONObject(Side);
          StrikeRow.Add('ce_key', CE.Get('symbol', ''));
          StrikeRow.Add('ce_oi',  CE.Get('oi',     Int64(0)));
          StrikeRow.Add('ce_vol', CE.Get('volume', Int64(0)));
        end
        else
        begin
          StrikeRow.Add('ce_key', '');
          StrikeRow.Add('ce_oi',  Int64(0));
          StrikeRow.Add('ce_vol', Int64(0));
        end;

        Side := ItemObj.Find('pe');
        if (Side <> nil) and (Side is TJSONObject) then
        begin
          PE := TJSONObject(Side);
          StrikeRow.Add('pe_key', PE.Get('symbol', ''));
          StrikeRow.Add('pe_oi',  PE.Get('oi',     Int64(0)));
          StrikeRow.Add('pe_vol', PE.Get('volume', Int64(0)));
        end
        else
        begin
          StrikeRow.Add('pe_key', '');
          StrikeRow.Add('pe_oi',  Int64(0));
          StrikeRow.Add('pe_vol', Int64(0));
        end;

        OutArr.Add(StrikeRow);
      end;
      Result := AnsiString(OutArr.AsJSON);
    finally
      OutArr.Free;
    end;
  finally
    Resp.Free;
  end;
end;

function TBroker.ATMStrike(const AUnderlying: AnsiString; AExpiryUnix: Int64;
  ASpot: Double): Double;
var
  Json: AnsiString;
  Arr: TJSONData;
  Item: TJSONData;
  I: Integer;
  S, Best, BestDiff, D: Double;
begin
  // Try the chain first to land on a real listed strike.
  Json := ListStrikesJson(AUnderlying, AExpiryUnix, exNFO);
  Arr := nil;
  Best := 0;
  BestDiff := 1e18;
  try
    Arr := GetJSON(string(Json));
    if Arr is TJSONArray then
    begin
      for I := 0 to TJSONArray(Arr).Count - 1 do
      begin
        Item := TJSONArray(Arr).Items[I];
        if not (Item is TJSONObject) then Continue;
        S := TJSONObject(Item).Get('strike', Double(0));
        if S <= 0 then Continue;
        D := Abs(S - ASpot);
        if D < BestDiff then
        begin
          BestDiff := D;
          Best := S;
        end;
      end;
    end;
  finally
    Arr.Free;
  end;
  if Best > 0 then
    Exit(Best);

  // Fallback: heuristic step. NIFTY=50, BANKNIFTY/SENSEX=100.
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
  Body: TJSONObject;
  Resp: TJSONData;
  Data: TJSONData;
  ExpStr, Sym: AnsiString;
begin
  Result := -1;
  if (AOptionType = otNone) or (AExpiryUnix <= 0) then Exit;
  ExpStr := AnsiString(FormatDateTime('yyyy-mm-dd', UnixToDateTime(AExpiryUnix)));
  Body := TJSONObject.Create;
  try
    Body.Add('symbol',      string(AUnderlying));
    Body.Add('expiry',      string(ExpStr));
    Body.Add('strike',      AStrike);
    Body.Add('option_type', string(OptionTypeStr(AOptionType)));
    Resp := HttpPostJson('/api/v1/optionsymbol', Body);
  finally
    Body.Free;
  end;
  if Resp = nil then Exit;
  try
    if not StatusOk(Resp, Data) then Exit;
    if not (Data is TJSONObject) then Exit;
    Sym := AnsiString(TJSONObject(Data).Get('symbol', ''));
    if Sym = '' then Exit;
    Result := GetOrCreateSymId(Sym, ResolveExchange(Sym, AExchange));
  finally
    Resp.Free;
  end;
end;

function TBroker.SearchJson(const AQuery: AnsiString; AExchange: TExchange;
  AMaxResults: Integer): AnsiString;
var
  Body: TJSONObject;
  Resp: TJSONData;
  Data: TJSONData;
begin
  Result := '[]';
  Body := TJSONObject.Create;
  try
    Body.Add('query', string(AQuery));
    if AMaxResults > 0 then Body.Add('limit', AMaxResults);
    Resp := HttpPostJson('/api/v1/search', Body);
  finally
    Body.Free;
  end;
  if Resp = nil then Exit;
  try
    if StatusOk(Resp, Data) and (Data is TJSONArray) then
      Result := AnsiString(Data.AsJSON);
  finally
    Resp.Free;
  end;
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
  // Linear scan — only used by examples / debug paths.
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
  Body: TJSONObject;
  Resp: TJSONData;
  Data: TJSONData;
begin
  Result := 0;
  Body := TJSONObject.Create;
  try
    Body.Add('symbol',   string(ASymbol));
    Body.Add('exchange', string(ResolveExchange(ASymbol, AExchange)));
    Resp := HttpPostJson('/api/v1/quotes', Body);
  finally
    Body.Free;
  end;
  if Resp = nil then Exit;
  try
    if StatusOk(Resp, Data) and (Data is TJSONObject) then
      Result := TJSONObject(Data).Get('ltp', Double(0));
  finally
    Resp.Free;
  end;
end;

function TBroker.HistoryJson(const ASymbol: AnsiString; AExchange: TExchange;
  const AFrom, ATo, AInterval: AnsiString): AnsiString;
var
  Body: TJSONObject;
  Resp: TJSONData;
  Data: TJSONData;
begin
  Result := '[]';
  Body := TJSONObject.Create;
  try
    Body.Add('symbol',     string(ASymbol));
    Body.Add('exchange',   string(ResolveExchange(ASymbol, AExchange)));
    Body.Add('interval',   string(AInterval));
    Body.Add('start_date', string(AFrom));
    Body.Add('end_date',   string(ATo));
    Resp := HttpPostJson('/api/v1/history', Body);
  finally
    Body.Free;
  end;
  if Resp = nil then Exit;
  try
    if StatusOk(Resp, Data) and (Data is TJSONArray) then
      Result := AnsiString(Data.AsJSON);
  finally
    Resp.Free;
  end;
end;

// ── Account ──────────────────────────────────────────────────────────────────

function TBroker.FundsJson: AnsiString;
var
  Body: TJSONObject;
  Resp: TJSONData;
  Data: TJSONData;
begin
  Result := '{}';
  Body := TJSONObject.Create;
  try
    Resp := HttpPostJson('/api/v1/funds', Body);
  finally
    Body.Free;
  end;
  if Resp = nil then Exit;
  try
    if StatusOk(Resp, Data) and (Data <> nil) then
      Result := AnsiString(Data.AsJSON);
  finally
    Resp.Free;
  end;
end;

function FundsField(Obj: TJSONObject; const AName: AnsiString): Double;
var
  V: TJSONData;
begin
  Result := 0;
  if Obj = nil then Exit;
  V := Obj.Find(string(AName));
  if V = nil then Exit;
  // Thorium emits these as 2-decimal INR strings; older brokers return floats.
  // AsFloat handles both — a JSON string like "245000.00" parses cleanly.
  try
    Result := V.AsFloat;
  except
    Result := StrToFloatDef(V.AsString, 0);
  end;
end;

function TBroker.AvailableMargin: Double;
var
  Json: AnsiString;
  Obj:  TJSONData;
begin
  Result := 0;
  Json := FundsJson;
  Obj := nil;
  try
    Obj := GetJSON(string(Json));
    if Obj is TJSONObject then
      Result := FundsField(TJSONObject(Obj), 'availablecash');
  finally
    Obj.Free;
  end;
end;

function TBroker.UsedMargin: Double;
var
  Json: AnsiString;
  Obj:  TJSONData;
begin
  Result := 0;
  Json := FundsJson;
  Obj := nil;
  try
    Obj := GetJSON(string(Json));
    if Obj is TJSONObject then
      Result := FundsField(TJSONObject(Obj), 'utiliseddebits');
  finally
    Obj.Free;
  end;
end;

function TBroker.PositionsJson: AnsiString;
var
  Body: TJSONObject;
  Resp: TJSONData;
  Data: TJSONData;
begin
  Result := '[]';
  Body := TJSONObject.Create;
  try
    Resp := HttpPostJson('/api/v1/positionbook', Body);
  finally
    Body.Free;
  end;
  if Resp = nil then Exit;
  try
    if StatusOk(Resp, Data) and (Data is TJSONArray) then
      Result := AnsiString(Data.AsJSON);
  finally
    Resp.Free;
  end;
end;

function TBroker.ExitPosition(const ASymbol: AnsiString;
  AExchange: TExchange): Boolean;
var
  Body: TJSONObject;
  Resp: TJSONData;
  Data: TJSONData;
begin
  Result := False;
  Body := TJSONObject.Create;
  try
    Body.Add('symbol',   string(ASymbol));
    Body.Add('exchange', string(ResolveExchange(ASymbol, AExchange)));
    Body.Add('product',  'MIS');
    Resp := HttpPostJson('/api/v1/closeposition', Body);
  finally
    Body.Free;
  end;
  if Resp = nil then Exit;
  try
    Result := StatusOk(Resp, Data);
  finally
    Resp.Free;
  end;
end;

// ── Orders ───────────────────────────────────────────────────────────────────

function TBroker.PlaceOrder(const ASymbol: AnsiString; AExchange: TExchange;
  ASide: TSide; AKind: TOrderKind; AProduct: TProductType; AValidity: TValidity;
  AQty: Integer; APrice, ATriggerPrice: Double; const ATag: AnsiString): AnsiString;
var
  Body: TJSONObject;
  Resp: TJSONData;
  OrderId: TJSONData;
begin
  Result := '';
  Body := TJSONObject.Create;
  try
    Body.Add('symbol',        string(ASymbol));
    Body.Add('exchange',      string(ResolveExchange(ASymbol, AExchange)));
    Body.Add('action',        string(SideStr(ASide)));
    Body.Add('quantity',      AQty);
    Body.Add('pricetype',     string(PriceTypeStr(AKind)));
    Body.Add('product',       string(ProductStr(AProduct)));
    if APrice > 0 then         Body.Add('price', APrice);
    if ATriggerPrice > 0 then  Body.Add('trigger_price', ATriggerPrice);
    if ATag <> '' then         Body.Add('strategy', string(ATag));
    Resp := HttpPostJson('/api/v1/placeorder', Body);
  finally
    Body.Free;
  end;
  if Resp = nil then
    raise EBrokerError.CreateFmt('place_order failed: %s', [FLastError]);
  try
    if not (Resp is TJSONObject) then
      raise EBrokerError.Create('place_order: unexpected response shape');
    if AnsiString(TJSONObject(Resp).Get('status', '')) <> 'success' then
    begin
      FLastError := AnsiString(TJSONObject(Resp).Get('message', 'unknown'));
      raise EBrokerError.CreateFmt('place_order failed: %s', [FLastError]);
    end;
    OrderId := TJSONObject(Resp).Find('orderid');
    if OrderId <> nil then
      Result := AnsiString(OrderId.AsString);
  finally
    Resp.Free;
  end;
end;

function TBroker.ModifyOrder(const AOrderId: AnsiString; AKind: TOrderKind;
  AQty: Integer; APrice, ATriggerPrice: Double): Boolean;
var
  Body: TJSONObject;
  Resp: TJSONData;
  Data: TJSONData;
begin
  Result := False;
  Body := TJSONObject.Create;
  try
    Body.Add('orderid',   string(AOrderId));
    Body.Add('quantity',  AQty);
    Body.Add('pricetype', string(PriceTypeStr(AKind)));
    if APrice > 0 then        Body.Add('price', APrice);
    if ATriggerPrice > 0 then Body.Add('trigger_price', ATriggerPrice);
    Resp := HttpPostJson('/api/v1/modifyorder', Body);
  finally
    Body.Free;
  end;
  if Resp = nil then Exit;
  try
    Result := StatusOk(Resp, Data);
  finally
    Resp.Free;
  end;
end;

function TBroker.CancelOrder(const AOrderId: AnsiString): Boolean;
var
  Body: TJSONObject;
  Resp: TJSONData;
  Data: TJSONData;
begin
  Result := False;
  Body := TJSONObject.Create;
  try
    Body.Add('orderid', string(AOrderId));
    Resp := HttpPostJson('/api/v1/cancelorder', Body);
  finally
    Body.Free;
  end;
  if Resp = nil then Exit;
  try
    Result := StatusOk(Resp, Data);
  finally
    Resp.Free;
  end;
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

procedure TBroker.DispatchTickJson(AObj: TJSONObject);
var
  Sym, Exch, Key: AnsiString;
  SymId: Integer;
  Idx: Integer;
  LTPv, Bid, Ask: Double;
  Vol, OI: Int64;
begin
  Sym  := AnsiString(AObj.Get('symbol', ''));
  Exch := AnsiString(AObj.Get('exchange', ''));
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

  LTPv := AObj.Get('ltp',     Double(0));
  Bid  := AObj.Get('bid',     Double(0));
  Ask  := AObj.Get('ask',     Double(0));
  Vol  := AObj.Get('volume',  Int64(0));
  OI   := AObj.Get('oi',      Int64(0));
  Inc(FTickCount);

  if Assigned(FOnTick) then
    FOnTick(FUserData, SymId, LTPv, Bid, Ask, Vol, OI);
end;

procedure TBroker.WsIncomingFrame(Sender: TWebSocketProcess;
  const Frame: TWebSocketFrame);
var
  S: AnsiString;
  J: TJSONData;
  Obj: TJSONObject;
  T:   AnsiString;
  Reason: AnsiString;
begin
  case Frame.opcode of
    focContinuation:
      begin
        // Connection upgraded — fire the connect callback.
        if Assigned(FOnConnect) then
          FOnConnect(FUserData, PAnsiChar('thorium-ws'));
      end;
    focConnectionClose:
      begin
        // Mark the session dead so a subsequent StreamStart re-handshakes
        // from scratch. Don't touch FWsClient here — the process thread
        // still owns it; StreamStart/Stop handles teardown.
        FStreamRunning := False;
        if Assigned(FOnDisconnect) then
          FOnDisconnect(FUserData, PAnsiChar('thorium-ws'),
            PAnsiChar('connection closed'));
      end;
    focText, focBinary:
      begin
        S := AnsiString(Frame.payload);
        if S = '' then Exit;
        J := nil;
        try
          try
            J := GetJSON(string(S));
          except
            Exit;
          end;
          if not (J is TJSONObject) then Exit;
          Obj := TJSONObject(J);
          T := AnsiString(Obj.Get('type', ''));

          if T = 'tick' then
            DispatchTickJson(Obj)
          else if T = 'heartbeat' then
            Exit
          else if T = 'auth' then
          begin
            if AnsiString(Obj.Get('status', '')) <> 'success' then
            begin
              Reason := AnsiString(Obj.Get('message', 'auth failed'));
              if Assigned(FOnDisconnect) then
                FOnDisconnect(FUserData, PAnsiChar('thorium-ws'),
                  PAnsiChar(Reason));
            end;
          end
          else if T = 'subscribe' then
          begin
            if AnsiString(Obj.Get('status', '')) <> 'success' then
              FLastError := AnsiString(Obj.Get('message', 'subscribe failed'));
          end
          else if Obj.Find('symbol') <> nil then
            // Untyped tick frame.
            DispatchTickJson(Obj)
          else if Obj.Find('orderid') <> nil then
          begin
            if Assigned(FOnOrder) then
              FOnOrder(FUserData, PAnsiChar(S));
          end;
        finally
          J.Free;
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

  // Make sure the SymbolId exists for tick correlation.
  GetOrCreateSymId(ASymbol, Exch);

  // Persist the subscription for replay across reconnects.
  SubKey := ASymbol + '|' + Exch + '|' + AnsiString(IntToStr(Mode));
  FSubLock.Enter;
  try
    if FSubs.IndexOf(string(SubKey)) < 0 then
      FSubs.Add(string(SubKey));
  finally
    FSubLock.Leave;
  end;

  if not FStreamRunning then
    Exit(True);  // queued — will replay on StreamStart.

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
  // Thorium's WS protocol streams tick data; order updates are emitted as
  // typed frames on the same socket. There's no separate subscribe action.
  // Send a hint frame for servers that gate on it; ignore the response.
  FOrdersSubscribed := True;
  if not FStreamRunning then
    Exit(True);
  Body := '{"action":"subscribe_orders"}';
  WsSendJson(Body);
  Result := True;
end;

end.
