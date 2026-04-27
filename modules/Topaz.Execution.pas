(**
 * Topaz.Execution — Execution Algorithms (TWAP + Direct)
 *
 * Simple execution layer that wraps order placement with algorithmic
 * splitting. Supports direct (single order) and TWAP (time-weighted
 * average price via equal slices at fixed intervals).
 *
 * Usage:
 *   Exec := TExecutionEngine.Create(Broker);
 *   try
 *     Id := Exec.Execute('NIFTY 50', exNSE, sdBuy, 100, eaTWAP, 5, 2000);
 *     // In main loop:
 *     Exec.Tick;
 *   finally
 *     Exec.Free;
 *   end;
 *)
unit Topaz.Execution;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, DateUtils, Thorium.Broker;

type
  TExecAlgo = (eaDirect, eaTWAP);

  TExecState = (exsPending, exsActive, exsCompleted, exsFailed);

  TExecOrder = record
    Id: Integer;
    Symbol: AnsiString;
    Exchange: TExchange;
    Side: TSide;
    TotalQty: Integer;
    FilledQty: Integer;
    AvgPrice: Double;
    Algo: TExecAlgo;
    // TWAP fields
    Slices: Integer;        // number of child orders
    SliceIntervalMs: Integer; // milliseconds between slices
    SlicesFilled: Integer;
    NextSliceTime: TDateTime;
    State: TExecState;
    Tag: AnsiString;
  end;

  TExecutionEngine = class
  private
    FBroker: TBroker;
    FOrders: array of TExecOrder;
    FOrderCount: Integer;
    FNextId: Integer;
    FCapacity: Integer;

    procedure GrowIfNeeded;
    function FindOrder(AId: Integer): Integer;
    procedure PlaceSlice(var AOrder: TExecOrder);
  public
    constructor Create(ABroker: TBroker);
    destructor Destroy; override;

    // Place order with algorithm
    function Execute(const ASymbol: AnsiString; AExchange: TExchange;
      ASide: TSide; AQty: Integer; AAlgo: TExecAlgo;
      ASlices: Integer = 5; AIntervalMs: Integer = 2000;
      const ATag: AnsiString = ''): Integer;

    // Call periodically to process pending TWAP slices
    procedure Tick;

    // Query
    function GetOrder(AId: Integer): TExecOrder;
    function ActiveCount: Integer;
    function OrderCount: Integer;
  end;

implementation

const
  INITIAL_CAPACITY = 256;

{ ── TExecutionEngine ──────────────────────────────────────────────────────── }

constructor TExecutionEngine.Create(ABroker: TBroker);
begin
  inherited Create;
  FBroker := ABroker;
  FNextId := 1;
  FOrderCount := 0;
  FCapacity := INITIAL_CAPACITY;
  SetLength(FOrders, FCapacity);
end;

destructor TExecutionEngine.Destroy;
begin
  inherited;
end;

procedure TExecutionEngine.GrowIfNeeded;
begin
  if FOrderCount >= FCapacity then
  begin
    FCapacity := FCapacity * 2;
    SetLength(FOrders, FCapacity);
  end;
end;

function TExecutionEngine.FindOrder(AId: Integer): Integer;
var
  I: Integer;
begin
  for I := 0 to FOrderCount - 1 do
  begin
    if FOrders[I].Id = AId then
      Exit(I);
  end;
  Result := -1;
end;

procedure TExecutionEngine.PlaceSlice(var AOrder: TExecOrder);
var
  SliceQty, Remaining: Integer;
  OrderId: AnsiString;
begin
  Remaining := AOrder.TotalQty - AOrder.FilledQty;
  if Remaining <= 0 then
  begin
    AOrder.State := exsCompleted;
    Exit;
  end;

  // Calculate slice size — last slice gets the remainder
  if (AOrder.Slices > 0) and (AOrder.SlicesFilled < AOrder.Slices - 1) then
    SliceQty := AOrder.TotalQty div AOrder.Slices
  else
    SliceQty := Remaining;

  if SliceQty > Remaining then
    SliceQty := Remaining;
  if SliceQty <= 0 then
    SliceQty := Remaining;

  try
    OrderId := FBroker.PlaceOrder(
      AOrder.Symbol, AOrder.Exchange, AOrder.Side,
      okMarket, ptIntraday, vDay,
      SliceQty, 0, 0, AOrder.Tag);

    AOrder.FilledQty := AOrder.FilledQty + SliceQty;
    Inc(AOrder.SlicesFilled);

    if AOrder.FilledQty >= AOrder.TotalQty then
      AOrder.State := exsCompleted
    else
      AOrder.NextSliceTime := IncMilliSecond(Now, AOrder.SliceIntervalMs);
  except
    on E: Exception do
      AOrder.State := exsFailed;
  end;
end;

function TExecutionEngine.Execute(const ASymbol: AnsiString; AExchange: TExchange;
  ASide: TSide; AQty: Integer; AAlgo: TExecAlgo;
  ASlices: Integer; AIntervalMs: Integer;
  const ATag: AnsiString): Integer;
var
  Idx: Integer;
begin
  GrowIfNeeded;

  Idx := FOrderCount;
  Inc(FOrderCount);

  FOrders[Idx].Id := FNextId;
  Result := FNextId;
  Inc(FNextId);

  FOrders[Idx].Symbol := ASymbol;
  FOrders[Idx].Exchange := AExchange;
  FOrders[Idx].Side := ASide;
  FOrders[Idx].TotalQty := AQty;
  FOrders[Idx].FilledQty := 0;
  FOrders[Idx].AvgPrice := 0;
  FOrders[Idx].Algo := AAlgo;
  FOrders[Idx].Slices := ASlices;
  FOrders[Idx].SliceIntervalMs := AIntervalMs;
  FOrders[Idx].SlicesFilled := 0;
  FOrders[Idx].NextSliceTime := 0;
  FOrders[Idx].Tag := ATag;

  case AAlgo of
    eaDirect:
    begin
      FOrders[Idx].State := exsActive;
      FOrders[Idx].Slices := 1;
      PlaceSlice(FOrders[Idx]);
    end;
    eaTWAP:
    begin
      FOrders[Idx].State := exsActive;
      // Place first slice immediately
      PlaceSlice(FOrders[Idx]);
    end;
  end;
end;

procedure TExecutionEngine.Tick;
var
  I: Integer;
  NowDT: TDateTime;
begin
  NowDT := Now;
  for I := 0 to FOrderCount - 1 do
  begin
    if FOrders[I].State <> exsActive then
      Continue;
    if FOrders[I].Algo <> eaTWAP then
      Continue;
    if FOrders[I].FilledQty >= FOrders[I].TotalQty then
    begin
      FOrders[I].State := exsCompleted;
      Continue;
    end;
    // Check if next slice is due
    if (FOrders[I].NextSliceTime > 0) and (NowDT >= FOrders[I].NextSliceTime) then
      PlaceSlice(FOrders[I]);
  end;
end;

function TExecutionEngine.GetOrder(AId: Integer): TExecOrder;
var
  Idx: Integer;
begin
  Idx := FindOrder(AId);
  if Idx >= 0 then
    Result := FOrders[Idx]
  else
  begin
    FillChar(Result, SizeOf(TExecOrder), 0);
    Result.Id := -1;
    Result.State := exsFailed;
  end;
end;

function TExecutionEngine.ActiveCount: Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to FOrderCount - 1 do
  begin
    if FOrders[I].State = exsActive then
      Inc(Result);
  end;
end;

function TExecutionEngine.OrderCount: Integer;
begin
  Result := FOrderCount;
end;

end.
