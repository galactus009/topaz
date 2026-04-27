(**
 * Topaz.Bracket — Bracket Order Manager
 *
 * Manages SL + TP leg submission after entry fill, with OCO
 * (one-cancels-other) behavior. When a stop-loss fills the target is
 * cancelled, and vice versa.
 *
 * Usage:
 *   BM := TBracketManager.Create(Broker);
 *   Id := BM.PlaceBracket('NIFTY 50', exNSE, sdBuy, 50, 22000, 21900, 22200);
 *   // Wire order callbacks:
 *   //   on entry fill  -> BM.OnFill(OrderId, FilledQty, FillPrice)
 *   //   on SL/TP fill  -> BM.OnLegFill(OrderId)
 *)
unit Topaz.Bracket;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Generics.Collections, Thorium.Broker;

type
  TBracketState = (bsPending, bsActive, bsPartialFill, bsCompleted, bsCancelled);

  TBracketOrder = record
    Id: Integer;
    EntryOrderId: AnsiString;
    Symbol: AnsiString;
    Exchange: TExchange;
    EntryQty: Integer;
    EntrySide: TSide;       // sdBuy or sdSell
    EntryPrice: Double;
    StopPrice: Double;
    TargetPrice: Double;
    SLOrderId: AnsiString;  // filled after entry fills
    TPOrderId: AnsiString;
    State: TBracketState;
    FilledQty: Integer;
  end;

  TBracketManager = class
  private
    FBroker: TBroker;
    FBrackets: TList<TBracketOrder>;
    FNextId: Integer;

    function FindByEntryOrderId(const AOrderId: AnsiString): Integer;
    function FindByLegOrderId(const AOrderId: AnsiString): Integer;
    function FindById(AId: Integer): Integer;
    function OppositeSide(ASide: TSide): TSide; inline;
  public
    constructor Create(ABroker: TBroker);
    destructor Destroy; override;

    // Create a bracket: places entry order, registers SL/TP for auto-submission
    function PlaceBracket(const ASymbol: AnsiString; AExchange: TExchange;
      ASide: TSide; AQty: Integer; AEntryPrice, AStopPrice, ATargetPrice: Double;
      const ATag: AnsiString = ''): Integer;  // returns bracket ID

    // Call this when an order fills (from order callback)
    procedure OnFill(const AOrderId: AnsiString; AFilledQty: Integer;
      AFillPrice: Double);

    // Cancel a bracket (cancels all legs)
    procedure CancelBracket(ABracketId: Integer);

    // OCO: when SL or TP fills, cancel the other
    procedure OnLegFill(const AOrderId: AnsiString);

    function GetBracket(AId: Integer): TBracketOrder;
    function ActiveCount: Integer;
  end;

implementation

{ ── TBracketManager ─────────────────────────────────────────────────────────── }

constructor TBracketManager.Create(ABroker: TBroker);
begin
  inherited Create;
  FBroker := ABroker;
  FBrackets := TList<TBracketOrder>.Create;
  FNextId := 1;
end;

destructor TBracketManager.Destroy;
begin
  FBrackets.Free;
  inherited;
end;

function TBracketManager.OppositeSide(ASide: TSide): TSide;
begin
  if ASide = sdBuy then
    Result := sdSell
  else
    Result := sdBuy;
end;

function TBracketManager.FindByEntryOrderId(const AOrderId: AnsiString): Integer;
var
  I: Integer;
begin
  for I := 0 to FBrackets.Count - 1 do
    if FBrackets[I].EntryOrderId = AOrderId then
      Exit(I);
  Result := -1;
end;

function TBracketManager.FindByLegOrderId(const AOrderId: AnsiString): Integer;
var
  I: Integer;
begin
  for I := 0 to FBrackets.Count - 1 do
    if (FBrackets[I].SLOrderId = AOrderId) or
       (FBrackets[I].TPOrderId = AOrderId) then
      Exit(I);
  Result := -1;
end;

function TBracketManager.FindById(AId: Integer): Integer;
var
  I: Integer;
begin
  for I := 0 to FBrackets.Count - 1 do
    if FBrackets[I].Id = AId then
      Exit(I);
  Result := -1;
end;

function TBracketManager.PlaceBracket(const ASymbol: AnsiString;
  AExchange: TExchange; ASide: TSide; AQty: Integer;
  AEntryPrice, AStopPrice, ATargetPrice: Double;
  const ATag: AnsiString): Integer;
var
  B: TBracketOrder;
  OrderId: AnsiString;
  Tag: AnsiString;
begin
  if ATag <> '' then
    Tag := ATag
  else
    Tag := Format('bracket_%d', [FNextId]);

  // Place entry limit order
  OrderId := FBroker.PlaceOrder(ASymbol, AExchange, ASide, okLimit,
    ptIntraday, vDay, AQty, AEntryPrice, 0, Tag);

  B := Default(TBracketOrder);
  B.Id := FNextId;
  B.EntryOrderId := OrderId;
  B.Symbol := ASymbol;
  B.Exchange := AExchange;
  B.EntryQty := AQty;
  B.EntrySide := ASide;
  B.EntryPrice := AEntryPrice;
  B.StopPrice := AStopPrice;
  B.TargetPrice := ATargetPrice;
  B.SLOrderId := '';
  B.TPOrderId := '';
  B.State := bsPending;
  B.FilledQty := 0;

  FBrackets.Add(B);
  Result := FNextId;
  Inc(FNextId);
end;

procedure TBracketManager.OnFill(const AOrderId: AnsiString;
  AFilledQty: Integer; AFillPrice: Double);
var
  Idx: Integer;
  B: TBracketOrder;
  ExitSide: TSide;
begin
  Idx := FindByEntryOrderId(AOrderId);
  if Idx < 0 then
    Exit;

  B := FBrackets[Idx];

  // Update filled quantity
  B.FilledQty := B.FilledQty + AFilledQty;

  if B.FilledQty < B.EntryQty then
  begin
    B.State := bsPartialFill;
    FBrackets[Idx] := B;
    Exit;
  end;

  // Entry fully filled — submit SL and TP legs
  ExitSide := OppositeSide(B.EntrySide);

  // Stop-loss order (SL order with trigger price)
  B.SLOrderId := FBroker.PlaceOrder(B.Symbol, B.Exchange, ExitSide,
    okStopLoss, ptIntraday, vDay, B.EntryQty, 0, B.StopPrice,
    Format('bracket_%d_sl', [B.Id]));

  // Take-profit order (limit order)
  B.TPOrderId := FBroker.PlaceOrder(B.Symbol, B.Exchange, ExitSide,
    okLimit, ptIntraday, vDay, B.EntryQty, B.TargetPrice, 0,
    Format('bracket_%d_tp', [B.Id]));

  B.State := bsActive;
  FBrackets[Idx] := B;
end;

procedure TBracketManager.OnLegFill(const AOrderId: AnsiString);
var
  Idx: Integer;
  B: TBracketOrder;
begin
  Idx := FindByLegOrderId(AOrderId);
  if Idx < 0 then
    Exit;

  B := FBrackets[Idx];

  if B.SLOrderId = AOrderId then
  begin
    // SL filled — cancel TP (OCO)
    if B.TPOrderId <> '' then
      FBroker.CancelOrder(B.TPOrderId);
  end
  else if B.TPOrderId = AOrderId then
  begin
    // TP filled — cancel SL (OCO)
    if B.SLOrderId <> '' then
      FBroker.CancelOrder(B.SLOrderId);
  end;

  B.State := bsCompleted;
  FBrackets[Idx] := B;
end;

procedure TBracketManager.CancelBracket(ABracketId: Integer);
var
  Idx: Integer;
  B: TBracketOrder;
begin
  Idx := FindById(ABracketId);
  if Idx < 0 then
    Exit;

  B := FBrackets[Idx];

  // Cancel all live legs
  if (B.State = bsPending) and (B.EntryOrderId <> '') then
    FBroker.CancelOrder(B.EntryOrderId);

  if (B.State = bsActive) or (B.State = bsPartialFill) then
  begin
    if B.SLOrderId <> '' then
      FBroker.CancelOrder(B.SLOrderId);
    if B.TPOrderId <> '' then
      FBroker.CancelOrder(B.TPOrderId);
  end;

  B.State := bsCancelled;
  FBrackets[Idx] := B;
end;

function TBracketManager.GetBracket(AId: Integer): TBracketOrder;
var
  Idx: Integer;
begin
  Idx := FindById(AId);
  if Idx >= 0 then
    Result := FBrackets[Idx]
  else
    raise Exception.CreateFmt('Bracket %d not found', [AId]);
end;

function TBracketManager.ActiveCount: Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to FBrackets.Count - 1 do
    if FBrackets[I].State in [bsPending, bsActive, bsPartialFill] then
      Inc(Result);
end;

end.
