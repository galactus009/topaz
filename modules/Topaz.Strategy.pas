{
  Topaz.Strategy — Strategy base class and strategy thread.

  Strategies run on their own thread, receiving ticks from a dedicated
  ring buffer. They never touch the GUI. Order placement goes through
  TBroker which is thread-safe for order calls.

  Usage:
    1. Subclass TStrategy, override OnTick (and optionally OnStart/OnStop)
    2. Register via RegisterStrategy('MyStrategy', TMyStrategy)
    3. GUI creates TStrategyThread to run it
}
unit Topaz.Strategy;

{$IFDEF FPC}{$mode Delphi}{$H+}{$ENDIF}

interface

uses
  Classes, SysUtils, Apollo.Broker, Topaz.RingBuffer, Topaz.EventTypes,
  Topaz.Risk;

type
  TStrategy = class;
  TStrategyClass = class of TStrategy;

  TParamKind = (pkFloat, pkInteger, pkString, pkBoolean);

  TStrategyParam = record
    Name: AnsiString;
    Display: AnsiString;
    Kind: TParamKind;
    Value: AnsiString;
  end;

  TStrategy = class
  private
    FName: AnsiString;
    FUnderlying: AnsiString;
    FLots: Integer;
    FExchange: TExchange;
    FPnL: Double;
    FTickCount: Int64;
    FWarmupTicks: Integer;    // ticks remaining in warmup
    FWarmedUp: Boolean;       // true once warmup complete
  protected
    FBroker: TBroker;
    FRisk: TRiskManager;
    FEventBus: TEventBus;
    { Override these in your strategy }
    procedure OnTick(const ATick: TTickEvent); virtual; abstract;
    procedure OnStart; virtual;
    procedure OnStop; virtual;
    { Order helpers — check risk before placing, log rejections }
    function Buy(const ASymbol: AnsiString; AQty: Integer;
      APrice: Double = 0; AExchange: TExchange = exNSE): AnsiString;
    function Sell(const ASymbol: AnsiString; AQty: Integer;
      APrice: Double = 0; AExchange: TExchange = exNSE): AnsiString;
    { Structured logging — emits to GUI event log via ring buffer }
    procedure EmitLog(ALevel: TLogLevel; const AMsg: AnsiString);
  public
    property Name: AnsiString read FName write FName;
    property Underlying: AnsiString read FUnderlying write FUnderlying;
    property Lots: Integer read FLots write FLots;
    property Exchange: TExchange read FExchange write FExchange;
    property Broker: TBroker read FBroker write FBroker;
    property Risk: TRiskManager read FRisk write FRisk;
    property EventBus: TEventBus read FEventBus write FEventBus;
    property PnL: Double read FPnL write FPnL;
    property TickCount: Int64 read FTickCount;
    property WarmupTicks: Integer read FWarmupTicks write FWarmupTicks;
    property WarmedUp: Boolean read FWarmedUp;
    { Strategy parameter declaration — override in subclass }
    function DeclareParams: TArray<TStrategyParam>; virtual;
    procedure ApplyParam(const AName, AValue: AnsiString); virtual;
    function GetParamValue(const AName: AnsiString): AnsiString; virtual;
  end;

  TStrategyThread = class(TThread)
  private
    FStrategy: TStrategy;
    FTickRing: ^TRingBuffer<TTickEvent>;
  protected
    procedure Execute; override;
  public
    constructor Create(AStrategy: TStrategy;
      var ATickRing: TRingBuffer<TTickEvent>);
  end;

  { ── Strategy registry ── }
  TStrategyRegistration = record
    Name: AnsiString;
    StrategyClass: TStrategyClass;
  end;

procedure RegisterStrategy(const AName: AnsiString; AClass: TStrategyClass);
function GetRegisteredStrategies: TArray<TStrategyRegistration>;

{ Model file path convention: models/<strategy>_<symbol>.json
  e.g. models/mlstrategy_nifty50.json, models/kalmanscalper_banknifty.json }
function ModelFilePath(const AStrategy, AUnderlying: AnsiString): AnsiString;

implementation

var
  GRegistry: array of TStrategyRegistration;

{ ── Registry ── }

procedure RegisterStrategy(const AName: AnsiString; AClass: TStrategyClass);
var
  N: Integer;
begin
  N := Length(GRegistry);
  SetLength(GRegistry, N + 1);
  GRegistry[N].Name := AName;
  GRegistry[N].StrategyClass := AClass;
end;

function GetRegisteredStrategies: TArray<TStrategyRegistration>;
begin
  Result := GRegistry;
end;

function ModelFilePath(const AStrategy, AUnderlying: AnsiString): AnsiString;
var
  SafeName: AnsiString;
  I: Integer;
begin
  // Sanitize symbol: 'NIFTY 50' → 'nifty50', 'BANK NIFTY' → 'banknifty'
  SafeName := LowerCase(AUnderlying);
  Result := '';
  for I := 1 to Length(SafeName) do
    if SafeName[I] in ['a'..'z', '0'..'9'] then
      Result := Result + SafeName[I];
  Result := 'models' + PathDelim + LowerCase(AStrategy) + '_' + Result + '.json';
end;

{ TStrategy }

procedure TStrategy.OnStart;
begin
  FWarmedUp := False;
  if FWarmupTicks <= 0 then
    FWarmupTicks := 50;  // default warmup: 50 ticks
end;

procedure TStrategy.OnStop;
begin
  // override in subclass
end;

function TStrategy.DeclareParams: TArray<TStrategyParam>;
begin
  Result := nil;
end;

procedure TStrategy.ApplyParam(const AName, AValue: AnsiString);
begin
  // override in subclass
end;

function TStrategy.GetParamValue(const AName: AnsiString): AnsiString;
begin
  Result := '';
end;

procedure TStrategy.EmitLog(ALevel: TLogLevel; const AMsg: AnsiString);
var
  Evt: TLogEvent;
  L: Integer;
begin
  if FEventBus = nil then Exit;
  Evt.Level := ALevel;
  StrLCopy(Evt.Source, PAnsiChar(FName), SizeOf(Evt.Source) - 1);
  L := Length(AMsg);
  if L > SizeOf(Evt.Msg) - 1 then L := SizeOf(Evt.Msg) - 1;
  Move(AMsg[1], Evt.Msg[0], L);
  Evt.Msg[L] := #0;
  Evt.Len := L;
  FEventBus.Logs.TryWrite(Evt);
end;

function TStrategy.Buy(const ASymbol: AnsiString; AQty: Integer;
  APrice: Double; AExchange: TExchange): AnsiString;
var
  Price: Double;
begin
  if APrice > 0 then Price := APrice else Price := 0;

  // Risk check
  if (FRisk <> nil) and (not FRisk.CheckOrder(FName, ASymbol, AQty, Price)) then
  begin
    EmitLog(llRisk, 'BUY REJECTED: ' + ASymbol + ' — ' + FRisk.LastViolation);
    Result := '';
    Exit;
  end;

  if APrice > 0 then
    Result := FBroker.PlaceOrder(ASymbol, AExchange, sdBuy, okLimit,
      ptIntraday, vDay, AQty, APrice, 0, FName)
  else
    Result := FBroker.PlaceOrder(ASymbol, AExchange, sdBuy, okMarket,
      ptIntraday, vDay, AQty, 0, 0, FName);

  if Result <> '' then
  begin
    EmitLog(llOrder, 'BUY ' + ASymbol + ' x' + IntToStr(AQty) + ' → ' + Result);
    if FRisk <> nil then FRisk.OrderOpened;
  end;
end;

function TStrategy.Sell(const ASymbol: AnsiString; AQty: Integer;
  APrice: Double; AExchange: TExchange): AnsiString;
var
  Price: Double;
begin
  if APrice > 0 then Price := APrice else Price := 0;

  // Risk check
  if (FRisk <> nil) and (not FRisk.CheckOrder(FName, ASymbol, AQty, Price)) then
  begin
    EmitLog(llRisk, 'SELL REJECTED: ' + ASymbol + ' — ' + FRisk.LastViolation);
    Result := '';
    Exit;
  end;

  if APrice > 0 then
    Result := FBroker.PlaceOrder(ASymbol, AExchange, sdSell, okLimit,
      ptIntraday, vDay, AQty, APrice, 0, FName)
  else
    Result := FBroker.PlaceOrder(ASymbol, AExchange, sdSell, okMarket,
      ptIntraday, vDay, AQty, 0, 0, FName);

  if Result <> '' then
  begin
    EmitLog(llOrder, 'SELL ' + ASymbol + ' x' + IntToStr(AQty) + ' → ' + Result);
    if FRisk <> nil then FRisk.OrderOpened;
  end;
end;

{ TStrategyThread }

constructor TStrategyThread.Create(AStrategy: TStrategy;
  var ATickRing: TRingBuffer<TTickEvent>);
begin
  inherited Create(True);  // suspended
  FStrategy := AStrategy;
  FTickRing := @ATickRing;
  FreeOnTerminate := False;
end;

procedure TStrategyThread.Execute;
var
  Tick: TTickEvent;
begin
  try
    FStrategy.OnStart;
    while not Terminated do
    begin
      if FTickRing^.TryRead(Tick) then
      begin
        Inc(FStrategy.FTickCount);
        if not FStrategy.FWarmedUp then
        begin
          Dec(FStrategy.FWarmupTicks);
          if FStrategy.FWarmupTicks <= 0 then
            FStrategy.FWarmedUp := True;
        end;
        FStrategy.OnTick(Tick);
      end
      else
        Sleep(1);  // yield when idle
    end;
    FStrategy.OnStop;
  except
    on E: Exception do
    begin
      // Strategy crashed — thread exits, GUI detects via status check
    end;
  end;
end;

end.
