{
  Topaz.PortfolioGreeks -- Real-time Portfolio Greeks Tracker.

  Aggregates per-position Greeks into a portfolio-level snapshot.
  Uses TBlackScholes.Calculate for each position, sums weighted by Qty.
  DeltaDollars and GammaScalp give dollar-denominated risk measures.
}
unit Topaz.PortfolioGreeks;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Math, Generics.Collections, Topaz.BlackScholes;

type
  TOptionPosition = record
    Symbol: AnsiString;
    Strike: Double;
    IsCall: Boolean;
    Qty: Integer;          // positive=long, negative=short
    EntryPrice: Double;
    CurrentPrice: Double;
    Spot: Double;
    TTE: Double;           // time to expiry in years
    IV: Double;
    RFR: Double;
  end;

  TPortfolioGreeksSnapshot = record
    NetDelta: Double;
    NetGamma: Double;
    NetTheta: Double;      // per day
    NetVega: Double;       // per 1% IV move
    TotalPremium: Double;  // sum of position values
    UnrealizedPnL: Double;
    PositionCount: Integer;
    DeltaDollars: Double;  // net delta * spot * lot size
    GammaScalp: Double;   // estimated gamma P&L for 1% spot move
  end;

  TPortfolioGreeks = class
  private
    FPositions: TList<TOptionPosition>;
    FLotSize: Integer;
    FSnapshot: TPortfolioGreeksSnapshot;
  public
    constructor Create(ALotSize: Integer = 75);
    destructor Destroy; override;

    procedure AddPosition(const APos: TOptionPosition);
    procedure RemovePosition(const ASymbol: AnsiString);
    procedure UpdatePrice(const ASymbol: AnsiString; APrice, ASpot: Double);
    procedure UpdateTTE(ATTE: Double);  // update all positions
    procedure Clear;

    function Compute: TPortfolioGreeksSnapshot;
    function DeltaHedgeQty(ASpot: Double): Integer;  // shares needed to delta-neutralize

    function ToJson: AnsiString;

    property Snapshot: TPortfolioGreeksSnapshot read FSnapshot;
    property LotSize: Integer read FLotSize write FLotSize;
  end;

implementation

{ ── TPortfolioGreeks ─────────────────────────────────────────────────────────── }

constructor TPortfolioGreeks.Create(ALotSize: Integer);
begin
  inherited Create;
  FLotSize := ALotSize;
  FPositions := TList<TOptionPosition>.Create;
  FillChar(FSnapshot, SizeOf(TPortfolioGreeksSnapshot), 0);
end;

destructor TPortfolioGreeks.Destroy;
begin
  FPositions.Free;
  inherited;
end;

procedure TPortfolioGreeks.AddPosition(const APos: TOptionPosition);
begin
  FPositions.Add(APos);
end;

procedure TPortfolioGreeks.RemovePosition(const ASymbol: AnsiString);
var
  I: Integer;
begin
  for I := FPositions.Count - 1 downto 0 do
    if FPositions[I].Symbol = ASymbol then
    begin
      FPositions.Delete(I);
      Break;
    end;
end;

procedure TPortfolioGreeks.UpdatePrice(const ASymbol: AnsiString;
  APrice, ASpot: Double);
var
  I: Integer;
  Pos: TOptionPosition;
begin
  for I := 0 to FPositions.Count - 1 do
    if FPositions[I].Symbol = ASymbol then
    begin
      Pos := FPositions[I];
      Pos.CurrentPrice := APrice;
      Pos.Spot := ASpot;
      FPositions[I] := Pos;
      Break;
    end;
end;

procedure TPortfolioGreeks.UpdateTTE(ATTE: Double);
var
  I: Integer;
  Pos: TOptionPosition;
begin
  for I := 0 to FPositions.Count - 1 do
  begin
    Pos := FPositions[I];
    Pos.TTE := ATTE;
    FPositions[I] := Pos;
  end;
end;

procedure TPortfolioGreeks.Clear;
begin
  FPositions.Clear;
  FillChar(FSnapshot, SizeOf(TPortfolioGreeksSnapshot), 0);
end;

function TPortfolioGreeks.Compute: TPortfolioGreeksSnapshot;
var
  I: Integer;
  Pos: TOptionPosition;
  G: TGreeks;
  AvgSpot: Double;
  SpotSum: Double;
  SpotCount: Integer;
  Move1Pct: Double;
begin
  FillChar(Result, SizeOf(TPortfolioGreeksSnapshot), 0);
  Result.PositionCount := FPositions.Count;

  SpotSum := 0;
  SpotCount := 0;

  for I := 0 to FPositions.Count - 1 do
  begin
    Pos := FPositions[I];

    G := TBlackScholes.Calculate(Pos.Spot, Pos.Strike, Pos.TTE,
      Pos.IV, Pos.RFR, 0.0, Pos.IsCall);

    Result.NetDelta := Result.NetDelta + G.Delta * Pos.Qty;
    Result.NetGamma := Result.NetGamma + G.Gamma * Pos.Qty;
    Result.NetTheta := Result.NetTheta + G.Theta * Pos.Qty;
    Result.NetVega  := Result.NetVega  + G.Vega  * Pos.Qty;

    Result.TotalPremium  := Result.TotalPremium + Pos.CurrentPrice * Pos.Qty * FLotSize;
    Result.UnrealizedPnL := Result.UnrealizedPnL +
      (Pos.CurrentPrice - Pos.EntryPrice) * Pos.Qty * FLotSize;

    if Pos.Spot > 0 then
    begin
      SpotSum := SpotSum + Pos.Spot;
      Inc(SpotCount);
    end;
  end;

  // Use average spot across positions for dollar-denominated measures
  if SpotCount > 0 then
    AvgSpot := SpotSum / SpotCount
  else
    AvgSpot := 0;

  Result.DeltaDollars := Result.NetDelta * AvgSpot * FLotSize;

  // GammaScalp: 0.5 * NetGamma * (Spot * 0.01)^2 * LotSize
  if AvgSpot > 0 then
  begin
    Move1Pct := AvgSpot * 0.01;
    Result.GammaScalp := 0.5 * Result.NetGamma * Move1Pct * Move1Pct * FLotSize;
  end;

  FSnapshot := Result;
end;

function TPortfolioGreeks.DeltaHedgeQty(ASpot: Double): Integer;
begin
  // Negative result means buy shares; positive means sell shares
  Result := -Round(FSnapshot.NetDelta * FLotSize);
end;

function TPortfolioGreeks.ToJson: AnsiString;
begin
  Result := '{'
    + '"netDelta":' + FloatToStr(FSnapshot.NetDelta)
    + ',"netGamma":' + FloatToStr(FSnapshot.NetGamma)
    + ',"netTheta":' + FloatToStr(FSnapshot.NetTheta)
    + ',"netVega":' + FloatToStr(FSnapshot.NetVega)
    + ',"totalPremium":' + FloatToStr(FSnapshot.TotalPremium)
    + ',"unrealizedPnL":' + FloatToStr(FSnapshot.UnrealizedPnL)
    + ',"positionCount":' + IntToStr(FSnapshot.PositionCount)
    + ',"deltaDollars":' + FloatToStr(FSnapshot.DeltaDollars)
    + ',"gammaScalp":' + FloatToStr(FSnapshot.GammaScalp)
    + '}';
end;

end.
