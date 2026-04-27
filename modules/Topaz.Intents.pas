(**
 * Topaz.Intents — Intent-Based Execution Layer
 *
 * Decouples strategy logic from order placement. Strategies emit intents
 * (entry, exit, reduce, flatten, bracket), and the engine converts them
 * to broker orders after risk checks. Manages per-strategy positions
 * with full reversal and partial-exit semantics.
 *
 * Usage:
 *   Engine := TIntentEngine.Create(Broker, Risk);
 *   try
 *     Intent.Kind := ikEntry;
 *     Intent.Symbol := 'NIFTY 50';
 *     Intent.Exchange := exNSE;
 *     Intent.Side := sdBuy;
 *     Intent.Qty := 50;
 *     Intent.Tag := 'MyStrategy';
 *     OrderId := Engine.Submit(Intent);
 *     // On fill callback:
 *     Engine.ApplyFill('MyStrategy', 'NIFTY 50', exNSE, 50, 22150.0, True);
 *   finally
 *     Engine.Free;
 *   end;
 *)
unit Topaz.Intents;

{$IFDEF FPC}{$mode Delphi}{$H+}{$ENDIF}

interface

uses
  SysUtils, Math, Generics.Collections, Thorium.Broker, Topaz.Risk;

type
  TIntentKind = (ikEntry, ikExit, ikReduce, ikFlatten, ikBracket, ikMultiLeg);

  TIntent = record
    Id: Integer;
    Kind: TIntentKind;
    Symbol: AnsiString;
    Exchange: TExchange;
    Side: TSide;
    Qty: Integer;
    Price: Double;           // 0 = market order
    StopPrice: Double;       // for bracket SL leg
    TargetPrice: Double;     // for bracket TP leg
    Tag: AnsiString;         // strategy name
    ReducePct: Double;       // for ikReduce: 0.5 = close 50%
  end;

  TMultiLegIntent = record
    Legs: array of TIntent;
    AtomicExecution: Boolean;  // if true, cancel all if any leg fails
    Tag: AnsiString;
  end;

  TPosition = record
    Symbol: AnsiString;
    Exchange: TExchange;
    Qty: Integer;            // positive = long, negative = short
    AvgPrice: Double;
    RealizedPnL: Double;
    UnrealizedPnL: Double;
    Strategy: AnsiString;
  end;

  TIntentEngine = class
  private
    FBroker: TBroker;
    FRisk: TRiskManager;
    FPositions: TDictionary<AnsiString, TPosition>;  // key = strategy:symbol
    FNextId: Integer;
    function PosKey(const AStrategy, ASymbol: AnsiString): AnsiString;
    function OppositeSide(ASide: TSide): TSide; inline;
    function PlaceOrderForIntent(const ASymbol: AnsiString; AExchange: TExchange;
      ASide: TSide; AQty: Integer; APrice: Double;
      const ATag: AnsiString): AnsiString;
  public
    constructor Create(ABroker: TBroker; ARisk: TRiskManager);
    destructor Destroy; override;

    { Submit an intent -- returns broker order ID or '' if rejected }
    function Submit(const AIntent: TIntent): AnsiString;

    { Position queries }
    function GetPosition(const AStrategy, ASymbol: AnsiString): TPosition;
    function HasPosition(const AStrategy, ASymbol: AnsiString): Boolean;
    function NetQty(const AStrategy, ASymbol: AnsiString): Integer;
    function AllPositions: TArray<TPosition>;

    { Update position from a fill }
    procedure ApplyFill(const AStrategy, ASymbol: AnsiString;
      AExchange: TExchange; AQty: Integer; APrice: Double; AIsBuy: Boolean);

    { Multi-leg submission }
    function SubmitMultiLeg(const AIntent: TMultiLegIntent): TArray<AnsiString>;

    { Flatten helpers }
    procedure FlattenAll;
    procedure FlattenSymbol(const AStrategy, ASymbol: AnsiString);
  end;

implementation

{ ── Helpers ─────────────────────────────────────────────────────────────────── }

function TIntentEngine.PosKey(const AStrategy, ASymbol: AnsiString): AnsiString;
begin
  Result := AStrategy + ':' + ASymbol;
end;

function TIntentEngine.OppositeSide(ASide: TSide): TSide;
begin
  if ASide = sdBuy then
    Result := sdSell
  else
    Result := sdBuy;
end;

function TIntentEngine.PlaceOrderForIntent(const ASymbol: AnsiString;
  AExchange: TExchange; ASide: TSide; AQty: Integer; APrice: Double;
  const ATag: AnsiString): AnsiString;
var
  Kind: TOrderKind;
begin
  if APrice > 0 then
    Kind := okLimit
  else
    Kind := okMarket;

  try
    Result := FBroker.PlaceOrder(ASymbol, AExchange, ASide, Kind,
      ptIntraday, vDay, AQty, APrice, 0, ATag);
  except
    on E: Exception do
      Result := '';
  end;
end;

{ ── TIntentEngine ───────────────────────────────────────────────────────────── }

constructor TIntentEngine.Create(ABroker: TBroker; ARisk: TRiskManager);
begin
  inherited Create;
  FBroker := ABroker;
  FRisk := ARisk;
  FPositions := TDictionary<AnsiString, TPosition>.Create;
  FNextId := 1;
end;

destructor TIntentEngine.Destroy;
begin
  FPositions.Free;
  inherited;
end;

function TIntentEngine.Submit(const AIntent: TIntent): AnsiString;
var
  Pos: TPosition;
  Key: AnsiString;
  ExitSide: TSide;
  ExitQty: Integer;
  Price: Double;
begin
  Result := '';

  case AIntent.Kind of

    { ── ikEntry ─────────────────────────────────────────────────────────────── }
    ikEntry:
    begin
      // Risk check
      Price := AIntent.Price;
      if Price <= 0 then
        Price := FBroker.LTP(AIntent.Symbol, AIntent.Exchange);

      if (FRisk <> nil) and
         (not FRisk.CheckOrder(AIntent.Tag, AIntent.Symbol, AIntent.Qty, Price)) then
        Exit('');

      Result := PlaceOrderForIntent(AIntent.Symbol, AIntent.Exchange,
        AIntent.Side, AIntent.Qty, AIntent.Price, AIntent.Tag);
    end;

    { ── ikExit ──────────────────────────────────────────────────────────────── }
    ikExit:
    begin
      Key := PosKey(AIntent.Tag, AIntent.Symbol);
      if not FPositions.TryGetValue(Key, Pos) then
        Exit('');
      if Pos.Qty = 0 then
        Exit('');

      // Determine exit side: opposite of current position direction
      if Pos.Qty > 0 then
        ExitSide := sdSell
      else
        ExitSide := sdBuy;
      ExitQty := Abs(Pos.Qty);

      Result := PlaceOrderForIntent(AIntent.Symbol, AIntent.Exchange,
        ExitSide, ExitQty, AIntent.Price, AIntent.Tag);
    end;

    { ── ikReduce ────────────────────────────────────────────────────────────── }
    ikReduce:
    begin
      Key := PosKey(AIntent.Tag, AIntent.Symbol);
      if not FPositions.TryGetValue(Key, Pos) then
        Exit('');
      if Pos.Qty = 0 then
        Exit('');

      // Compute reduce qty: floor of abs(qty) * ReducePct, minimum 1
      ExitQty := Floor(Abs(Pos.Qty) * AIntent.ReducePct);
      if ExitQty <= 0 then
        ExitQty := 1;
      if ExitQty > Abs(Pos.Qty) then
        ExitQty := Abs(Pos.Qty);

      if Pos.Qty > 0 then
        ExitSide := sdSell
      else
        ExitSide := sdBuy;

      Result := PlaceOrderForIntent(AIntent.Symbol, AIntent.Exchange,
        ExitSide, ExitQty, AIntent.Price, AIntent.Tag);
    end;

    { ── ikFlatten ───────────────────────────────────────────────────────────── }
    ikFlatten:
    begin
      if AIntent.Symbol <> '' then
        FlattenSymbol(AIntent.Tag, AIntent.Symbol)
      else
        FlattenAll;
      Result := 'FLATTEN';
    end;

    { ── ikBracket ───────────────────────────────────────────────────────────── }
    ikBracket:
    begin
      // Place entry leg; bracket SL/TP legs handled by Topaz.Bracket
      Price := AIntent.Price;
      if Price <= 0 then
        Price := FBroker.LTP(AIntent.Symbol, AIntent.Exchange);

      if (FRisk <> nil) and
         (not FRisk.CheckOrder(AIntent.Tag, AIntent.Symbol, AIntent.Qty, Price)) then
        Exit('');

      Result := PlaceOrderForIntent(AIntent.Symbol, AIntent.Exchange,
        AIntent.Side, AIntent.Qty, AIntent.Price, AIntent.Tag);
    end;
  end;
end;

{ ── Position Queries ────────────────────────────────────────────────────────── }

function TIntentEngine.GetPosition(const AStrategy, ASymbol: AnsiString): TPosition;
var
  Key: AnsiString;
begin
  Key := PosKey(AStrategy, ASymbol);
  if not FPositions.TryGetValue(Key, Result) then
  begin
    FillChar(Result, SizeOf(TPosition), 0);
    Result.Symbol := ASymbol;
    Result.Strategy := AStrategy;
  end;
end;

function TIntentEngine.HasPosition(const AStrategy, ASymbol: AnsiString): Boolean;
var
  Pos: TPosition;
  Key: AnsiString;
begin
  Key := PosKey(AStrategy, ASymbol);
  Result := FPositions.TryGetValue(Key, Pos) and (Pos.Qty <> 0);
end;

function TIntentEngine.NetQty(const AStrategy, ASymbol: AnsiString): Integer;
var
  Pos: TPosition;
  Key: AnsiString;
begin
  Key := PosKey(AStrategy, ASymbol);
  if FPositions.TryGetValue(Key, Pos) then
    Result := Pos.Qty
  else
    Result := 0;
end;

function TIntentEngine.AllPositions: TArray<TPosition>;
var
  Pair: TPair<AnsiString, TPosition>;
  I: Integer;
begin
  SetLength(Result, FPositions.Count);
  I := 0;
  for Pair in FPositions do
  begin
    Result[I] := Pair.Value;
    Inc(I);
  end;
end;

{ ── ApplyFill — Position reversal and partial exit logic ────────────────────── }

procedure TIntentEngine.ApplyFill(const AStrategy, ASymbol: AnsiString;
  AExchange: TExchange; AQty: Integer; APrice: Double; AIsBuy: Boolean);
var
  Key: AnsiString;
  Pos: TPosition;
  OldQty, NewQty, SignedFill: Integer;
  OldSign, NewSign: Integer;
  ClosedQty, RemainQty: Integer;
  RealizedThisFill: Double;
begin
  Key := PosKey(AStrategy, ASymbol);

  // Fetch or create position
  if not FPositions.TryGetValue(Key, Pos) then
  begin
    FillChar(Pos, SizeOf(TPosition), 0);
    Pos.Symbol := ASymbol;
    Pos.Exchange := AExchange;
    Pos.Strategy := AStrategy;
  end;

  OldQty := Pos.Qty;

  // Signed fill: buy adds, sell subtracts
  if AIsBuy then
    SignedFill := AQty
  else
    SignedFill := -AQty;

  NewQty := OldQty + SignedFill;

  // Determine old and new signs (0 treated as neutral)
  if OldQty > 0 then OldSign := 1
  else if OldQty < 0 then OldSign := -1
  else OldSign := 0;

  if NewQty > 0 then NewSign := 1
  else if NewQty < 0 then NewSign := -1
  else NewSign := 0;

  RealizedThisFill := 0;

  if OldQty = 0 then
  begin
    // ── Fresh entry ──
    Pos.Qty := NewQty;
    Pos.AvgPrice := APrice;
  end
  else if (OldSign <> 0) and (NewSign <> 0) and (OldSign <> NewSign) then
  begin
    // ── Position crosses zero (reversal) ──
    // Close old position entirely
    ClosedQty := Abs(OldQty);
    if OldQty > 0 then
      RealizedThisFill := (APrice - Pos.AvgPrice) * ClosedQty   // was long
    else
      RealizedThisFill := (Pos.AvgPrice - APrice) * ClosedQty;  // was short

    // Open new position with remaining qty at fill price
    RemainQty := Abs(NewQty);
    Pos.Qty := NewQty;
    Pos.AvgPrice := APrice;
    Pos.RealizedPnL := Pos.RealizedPnL + RealizedThisFill;
  end
  else if NewQty = 0 then
  begin
    // ── Full close (reduces to zero) ──
    ClosedQty := Abs(OldQty);
    if OldQty > 0 then
      RealizedThisFill := (APrice - Pos.AvgPrice) * ClosedQty
    else
      RealizedThisFill := (Pos.AvgPrice - APrice) * ClosedQty;

    Pos.Qty := 0;
    Pos.AvgPrice := 0;
    Pos.RealizedPnL := Pos.RealizedPnL + RealizedThisFill;
  end
  else if (OldSign = NewSign) and (Abs(NewQty) < Abs(OldQty)) then
  begin
    // ── Partial reduce (same sign, smaller magnitude) ──
    ClosedQty := Abs(OldQty) - Abs(NewQty);
    if OldQty > 0 then
      RealizedThisFill := (APrice - Pos.AvgPrice) * ClosedQty
    else
      RealizedThisFill := (Pos.AvgPrice - APrice) * ClosedQty;

    Pos.Qty := NewQty;
    // AvgPrice stays the same for partial reduces
    Pos.RealizedPnL := Pos.RealizedPnL + RealizedThisFill;
  end
  else
  begin
    // ── Position increase (same sign, larger magnitude) ──
    // Weighted average price
    Pos.AvgPrice := (Pos.AvgPrice * Abs(OldQty) + APrice * AQty)
                    / Abs(NewQty);
    Pos.Qty := NewQty;
  end;

  // Notify risk manager of the fill
  if FRisk <> nil then
  begin
    FRisk.RecordFill(AStrategy, ASymbol, AQty, APrice, AIsBuy);
    if RealizedThisFill <> 0 then
      FRisk.UpdatePnL(AStrategy, Pos.RealizedPnL);
  end;

  FPositions.AddOrSetValue(Key, Pos);
end;

{ ── SubmitMultiLeg ─────────────────────────────────────────────────────────── }

function TIntentEngine.SubmitMultiLeg(const AIntent: TMultiLegIntent): TArray<AnsiString>;
var
  I: Integer;
  OrderId: AnsiString;
  AnyFailed: Boolean;
begin
  SetLength(Result, Length(AIntent.Legs));
  AnyFailed := False;

  for I := 0 to High(AIntent.Legs) do
  begin
    OrderId := Submit(AIntent.Legs[I]);
    Result[I] := OrderId;
    if OrderId = '' then
      AnyFailed := True;
  end;

  // If atomic and any leg failed, cancel all successfully placed legs
  if AIntent.AtomicExecution and AnyFailed then
  begin
    for I := 0 to High(Result) do
    begin
      if Result[I] <> '' then
      begin
        try
          FBroker.CancelOrder(Result[I]);
        except
          // Best effort cancellation
        end;
        Result[I] := '';
      end;
    end;
  end;
end;

{ ── Flatten ─────────────────────────────────────────────────────────────────── }

procedure TIntentEngine.FlattenSymbol(const AStrategy, ASymbol: AnsiString);
var
  Pos: TPosition;
  Key: AnsiString;
  Intent: TIntent;
begin
  Key := PosKey(AStrategy, ASymbol);
  if not FPositions.TryGetValue(Key, Pos) then
    Exit;
  if Pos.Qty = 0 then
    Exit;

  FillChar(Intent, SizeOf(TIntent), 0);
  Intent.Kind := ikExit;
  Intent.Symbol := ASymbol;
  Intent.Exchange := Pos.Exchange;
  Intent.Tag := AStrategy;
  // Side is determined by ikExit handler from position direction
  Submit(Intent);
end;

procedure TIntentEngine.FlattenAll;
var
  Pair: TPair<AnsiString, TPosition>;
  Positions: TArray<TPair<AnsiString, TPosition>>;
  I: Integer;
begin
  // Snapshot positions to avoid dictionary modification during iteration
  SetLength(Positions, FPositions.Count);
  I := 0;
  for Pair in FPositions do
  begin
    Positions[I] := Pair;
    Inc(I);
  end;

  for I := 0 to High(Positions) do
  begin
    if Positions[I].Value.Qty <> 0 then
      FlattenSymbol(Positions[I].Value.Strategy, Positions[I].Value.Symbol);
  end;
end;

end.
