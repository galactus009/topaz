(**
 * Topaz.Risk — Centralized Risk Manager
 *
 * Gates all order submissions. Strategies should call CheckOrder before
 * placing orders. Tracks daily PnL, per-strategy PnL, exposure limits,
 * order rate throttling, and a kill switch for catastrophic scenarios.
 *
 * Usage:
 *   Risk := TRiskManager.Create;
 *   Risk.DailyLossLimit := 50000;
 *   if Risk.CheckOrder('MyStrategy', 'NIFTY 50', 50, 22000) then
 *     Broker.PlaceOrder(...)
 *   else
 *     WriteLn('Blocked: ', Risk.LastViolation);
 *)
unit Topaz.Risk;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, DateUtils, Generics.Collections;

type
  TRiskRule = (
    rrDailyLoss,         // Portfolio daily loss limit
    rrStrategyLoss,      // Per-strategy loss limit
    rrMaxExposure,       // Max total position value
    rrSymbolExposure,    // Max per-symbol position
    rrOrderRate,         // Orders per second throttle
    rrMaxOpenOrders,     // Max concurrent open orders
    rrMarginCheck        // Available margin check
  );

  TRiskViolation = record
    Rule: TRiskRule;
    Message: AnsiString;
    Value: Double;
    Limit: Double;
  end;

  TRiskManager = class
  private
    FDailyLossLimit: Double;
    FStrategyLossLimit: Double;
    FMaxExposure: Double;
    FMaxSymbolExposure: Double;
    FMaxOrdersPerSec: Integer;
    FMaxOpenOrders: Integer;
    FMinMargin: Double;

    FDailyPnL: Double;
    FKillSwitchTripped: Boolean;
    FOrderTimestamps: array of TDateTime;  // for rate limiting
    FOpenOrderCount: Integer;
    FPositions: TDictionary<AnsiString, Double>;  // symbol -> exposure
    FStrategyPnL: TDictionary<AnsiString, Double>; // strategy -> pnl

    FViolations: TList<TRiskViolation>;
    FEnabled: Boolean;

    procedure AddViolation(ARule: TRiskRule; const AMsg: AnsiString;
      AValue, ALimit: Double);
    procedure PruneOrderTimestamps;
    function TotalExposure: Double;
  public
    constructor Create;
    destructor Destroy; override;

    // Check if an order is allowed. Returns True if OK.
    function CheckOrder(const AStrategy, ASymbol: AnsiString;
      AQty: Integer; APrice: Double): Boolean;

    // Update state
    procedure RecordFill(const AStrategy, ASymbol: AnsiString;
      AQty: Integer; APrice: Double; AIsBuy: Boolean);
    procedure UpdatePnL(const AStrategy: AnsiString; APnL: Double);
    procedure UpdateDailyPnL(APnL: Double);
    procedure OrderOpened;
    procedure OrderClosed;
    procedure ResetDaily;

    // Query
    function IsKillSwitchTripped: Boolean;
    function LastViolation: AnsiString;
    function ViolationCount: Integer;

    // Config
    property Enabled: Boolean read FEnabled write FEnabled;
    property DailyLossLimit: Double read FDailyLossLimit write FDailyLossLimit;
    property StrategyLossLimit: Double read FStrategyLossLimit write FStrategyLossLimit;
    property MaxExposure: Double read FMaxExposure write FMaxExposure;
    property MaxSymbolExposure: Double read FMaxSymbolExposure write FMaxSymbolExposure;
    property MaxOrdersPerSec: Integer read FMaxOrdersPerSec write FMaxOrdersPerSec;
    property MaxOpenOrders: Integer read FMaxOpenOrders write FMaxOpenOrders;
    property MinMargin: Double read FMinMargin write FMinMargin;
    property KillSwitchTripped: Boolean read FKillSwitchTripped;
    property DailyPnL: Double read FDailyPnL;
  end;

implementation

{ ── TRiskManager ────────────────────────────────────────────────────────────── }

constructor TRiskManager.Create;
begin
  inherited Create;
  FEnabled := True;
  FKillSwitchTripped := False;
  FDailyPnL := 0;
  FOpenOrderCount := 0;

  // Defaults
  FDailyLossLimit   := 50000;
  FStrategyLossLimit := 10000;
  FMaxExposure       := 500000;
  FMaxSymbolExposure := 100000;
  FMaxOrdersPerSec   := 5;
  FMaxOpenOrders     := 20;
  FMinMargin         := 10000;

  FPositions   := TDictionary<AnsiString, Double>.Create;
  FStrategyPnL := TDictionary<AnsiString, Double>.Create;
  FViolations  := TList<TRiskViolation>.Create;
  SetLength(FOrderTimestamps, 0);
end;

destructor TRiskManager.Destroy;
begin
  FViolations.Free;
  FStrategyPnL.Free;
  FPositions.Free;
  inherited;
end;

procedure TRiskManager.AddViolation(ARule: TRiskRule; const AMsg: AnsiString;
  AValue, ALimit: Double);
var
  V: TRiskViolation;
begin
  V.Rule := ARule;
  V.Message := AMsg;
  V.Value := AValue;
  V.Limit := ALimit;
  FViolations.Add(V);
end;

procedure TRiskManager.PruneOrderTimestamps;
var
  Now_: TDateTime;
  I, Keep: Integer;
begin
  Now_ := Now;
  Keep := 0;
  // Find first timestamp within the last second
  for I := 0 to High(FOrderTimestamps) do
  begin
    if SecondsBetween(Now_, FOrderTimestamps[I]) < 1 then
    begin
      Keep := I;
      Break;
    end;
    Keep := I + 1;
  end;
  if Keep > 0 then
  begin
    if Keep <= High(FOrderTimestamps) then
    begin
      Move(FOrderTimestamps[Keep], FOrderTimestamps[0],
        (Length(FOrderTimestamps) - Keep) * SizeOf(TDateTime));
      SetLength(FOrderTimestamps, Length(FOrderTimestamps) - Keep);
    end
    else
      SetLength(FOrderTimestamps, 0);
  end;
end;

function TRiskManager.TotalExposure: Double;
var
  Pair: TPair<AnsiString, Double>;
begin
  Result := 0;
  for Pair in FPositions do
    Result := Result + Abs(Pair.Value);
end;

function TRiskManager.CheckOrder(const AStrategy, ASymbol: AnsiString;
  AQty: Integer; APrice: Double): Boolean;
var
  OrderValue, SymExp, StratPnL: Double;
begin
  Result := True;

  if not FEnabled then
    Exit(True);

  OrderValue := Abs(AQty) * APrice;

  // 1. Kill switch
  if FKillSwitchTripped then
  begin
    AddViolation(rrDailyLoss, 'Kill switch is tripped — all orders blocked',
      FDailyPnL, -FDailyLossLimit);
    Exit(False);
  end;

  // 2. Daily PnL check (trip kill switch if breached)
  if FDailyPnL <= -FDailyLossLimit then
  begin
    FKillSwitchTripped := True;
    AddViolation(rrDailyLoss,
      Format('Daily loss limit breached (PnL=%.2f, Limit=%.2f) — kill switch tripped',
        [FDailyPnL, FDailyLossLimit]),
      FDailyPnL, FDailyLossLimit);
    Exit(False);
  end;

  // 3. Strategy PnL check
  if FStrategyPnL.TryGetValue(AStrategy, StratPnL) then
  begin
    if StratPnL <= -FStrategyLossLimit then
    begin
      AddViolation(rrStrategyLoss,
        Format('Strategy "%s" loss limit breached (PnL=%.2f, Limit=%.2f)',
          [AStrategy, StratPnL, FStrategyLossLimit]),
        StratPnL, FStrategyLossLimit);
      Exit(False);
    end;
  end;

  // 4. Total exposure check
  if TotalExposure + OrderValue > FMaxExposure then
  begin
    AddViolation(rrMaxExposure,
      Format('Total exposure would exceed limit (Current=%.2f, Order=%.2f, Limit=%.2f)',
        [TotalExposure, OrderValue, FMaxExposure]),
      TotalExposure + OrderValue, FMaxExposure);
    Exit(False);
  end;

  // 5. Per-symbol exposure check
  SymExp := 0;
  FPositions.TryGetValue(ASymbol, SymExp);
  if Abs(SymExp) + OrderValue > FMaxSymbolExposure then
  begin
    AddViolation(rrSymbolExposure,
      Format('Symbol "%s" exposure would exceed limit (Current=%.2f, Order=%.2f, Limit=%.2f)',
        [ASymbol, Abs(SymExp), OrderValue, FMaxSymbolExposure]),
      Abs(SymExp) + OrderValue, FMaxSymbolExposure);
    Exit(False);
  end;

  // 6. Order rate throttle
  PruneOrderTimestamps;
  if Length(FOrderTimestamps) >= FMaxOrdersPerSec then
  begin
    AddViolation(rrOrderRate,
      Format('Order rate limit exceeded (%d orders in last second, Limit=%d)',
        [Length(FOrderTimestamps), FMaxOrdersPerSec]),
      Length(FOrderTimestamps), FMaxOrdersPerSec);
    Exit(False);
  end;

  // 7. Max open orders
  if FOpenOrderCount >= FMaxOpenOrders then
  begin
    AddViolation(rrMaxOpenOrders,
      Format('Max open orders reached (Open=%d, Limit=%d)',
        [FOpenOrderCount, FMaxOpenOrders]),
      FOpenOrderCount, FMaxOpenOrders);
    Exit(False);
  end;

  // Passed all checks — record the timestamp
  SetLength(FOrderTimestamps, Length(FOrderTimestamps) + 1);
  FOrderTimestamps[High(FOrderTimestamps)] := Now;
end;

procedure TRiskManager.RecordFill(const AStrategy, ASymbol: AnsiString;
  AQty: Integer; APrice: Double; AIsBuy: Boolean);
var
  Exp: Double;
  Signed: Double;
begin
  if AIsBuy then
    Signed := AQty * APrice
  else
    Signed := -(AQty * APrice);

  Exp := 0;
  FPositions.TryGetValue(ASymbol, Exp);
  FPositions.AddOrSetValue(ASymbol, Exp + Signed);
end;

procedure TRiskManager.UpdatePnL(const AStrategy: AnsiString; APnL: Double);
begin
  FStrategyPnL.AddOrSetValue(AStrategy, APnL);
end;

procedure TRiskManager.UpdateDailyPnL(APnL: Double);
begin
  FDailyPnL := APnL;
end;

procedure TRiskManager.OrderOpened;
begin
  Inc(FOpenOrderCount);
end;

procedure TRiskManager.OrderClosed;
begin
  if FOpenOrderCount > 0 then
    Dec(FOpenOrderCount);
end;

procedure TRiskManager.ResetDaily;
begin
  FDailyPnL := 0;
  FKillSwitchTripped := False;
  FOpenOrderCount := 0;
  FPositions.Clear;
  FStrategyPnL.Clear;
  FViolations.Clear;
  SetLength(FOrderTimestamps, 0);
end;

function TRiskManager.IsKillSwitchTripped: Boolean;
begin
  Result := FKillSwitchTripped;
end;

function TRiskManager.LastViolation: AnsiString;
begin
  if FViolations.Count > 0 then
    Result := FViolations[FViolations.Count - 1].Message
  else
    Result := '';
end;

function TRiskManager.ViolationCount: Integer;
begin
  Result := FViolations.Count;
end;

end.
