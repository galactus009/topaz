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
  Classes, SysUtils, Apollo.Broker, Topaz.RingBuffer, Topaz.EventTypes;

type
  TStrategy = class;
  TStrategyClass = class of TStrategy;

  TStrategy = class
  private
    FName: AnsiString;
    FUnderlying: AnsiString;
    FLots: Integer;
    FExchange: TExchange;
    FPnL: Double;
    FTickCount: Int64;
  protected
    FBroker: TBroker;
    { Override these in your strategy }
    procedure OnTick(const ATick: TTickEvent); virtual; abstract;
    procedure OnStart; virtual;
    procedure OnStop; virtual;
    { Order helpers — safe to call from strategy thread }
    function Buy(const ASymbol: AnsiString; AQty: Integer;
      APrice: Double = 0; AExchange: TExchange = exNSE): AnsiString;
    function Sell(const ASymbol: AnsiString; AQty: Integer;
      APrice: Double = 0; AExchange: TExchange = exNSE): AnsiString;
  public
    property Name: AnsiString read FName write FName;
    property Underlying: AnsiString read FUnderlying write FUnderlying;
    property Lots: Integer read FLots write FLots;
    property Exchange: TExchange read FExchange write FExchange;
    property Broker: TBroker read FBroker write FBroker;
    property PnL: Double read FPnL write FPnL;
    property TickCount: Int64 read FTickCount;
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

{ TStrategy }

procedure TStrategy.OnStart;
begin
  // override in subclass
end;

procedure TStrategy.OnStop;
begin
  // override in subclass
end;

function TStrategy.Buy(const ASymbol: AnsiString; AQty: Integer;
  APrice: Double; AExchange: TExchange): AnsiString;
begin
  if APrice > 0 then
    Result := FBroker.PlaceOrder(ASymbol, AExchange, sdBuy, okLimit,
      ptIntraday, vDay, AQty, APrice, 0, FName)
  else
    Result := FBroker.PlaceOrder(ASymbol, AExchange, sdBuy, okMarket,
      ptIntraday, vDay, AQty, 0, 0, FName);
end;

function TStrategy.Sell(const ASymbol: AnsiString; AQty: Integer;
  APrice: Double; AExchange: TExchange): AnsiString;
begin
  if APrice > 0 then
    Result := FBroker.PlaceOrder(ASymbol, AExchange, sdSell, okLimit,
      ptIntraday, vDay, AQty, APrice, 0, FName)
  else
    Result := FBroker.PlaceOrder(ASymbol, AExchange, sdSell, okMarket,
      ptIntraday, vDay, AQty, 0, 0, FName);
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
