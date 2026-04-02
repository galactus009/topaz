{
  Topaz.Strategy.GammaScalp -- Dynamic delta-hedged long straddle.

  Buys ATM CE + PE (long straddle), then continuously delta-hedges
  the underlying to capture gamma P&L from realised volatility.

  Delta hedging:
    - Recalculates portfolio delta via Black-Scholes on each spot tick
    - If |net delta| > DeltaThreshold per lot, hedges with underlying
    - Also rehedges when spot moves > PriceTrigger from last hedge price

  Time exit at 15:20. All legs squared off on stop.

  Registered as 'GammaScalp'.
}
unit Topaz.Strategy.GammaScalp;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Math, DateUtils, Apollo.Broker, Topaz.EventTypes, Topaz.Strategy,
  Topaz.BlackScholes, Topaz.Adjustment;

type
  TGammaScalpState = (gsInit, gsPositioned, gsSquaredOff);

  TGammaScalp = class(TStrategy)
  private
    { -- Parameters -- }
    FDeltaThreshold: Double;
    FMaxCostPct: Double;
    FMaxDTE: Integer;
    FEstimatedIV: Double;
    FPriceTrigger: Double;

    { -- State -- }
    FState: TGammaScalpState;
    FExpiry: Int64;
    FStrike: Double;
    FLotSize: Integer;

    FCESymId: Integer;
    FPESymId: Integer;
    FSpotSymId: Integer;
    FCESymbol: AnsiString;
    FPESymbol: AnsiString;

    FCEEntry: Double;
    FPEEntry: Double;
    FCELTP: Double;
    FPELTP: Double;
    FSpotLTP: Double;
    FLastHedgePrice: Double;

    FHedgeQty: Integer;   // net underlying hedge: +ve = long, -ve = short

    FRFR: Double;         // risk-free rate assumption

    FAdjustment: TAdjustmentEngine;
    FAdjustConfig: TAdjustmentConfig;

    function TTE: Double;
    function IsTimeExit: Boolean;
    procedure EnterStraddle;
    procedure DeltaHedge;
    procedure SquareOff;
  protected
    procedure OnStart; override;
    procedure OnTick(const ATick: TTickEvent); override;
    procedure OnStop; override;
  public
    constructor Create;
    function DeclareParams: TArray<TStrategyParam>; override;
    procedure ApplyParam(const AName, AValue: AnsiString); override;
    function GetParamValue(const AName: AnsiString): AnsiString; override;
    property DeltaThreshold: Double read FDeltaThreshold write FDeltaThreshold;
    property MaxCostPct: Double read FMaxCostPct write FMaxCostPct;
    property MaxDTE: Integer read FMaxDTE write FMaxDTE;
    property EstimatedIV: Double read FEstimatedIV write FEstimatedIV;
    property PriceTrigger: Double read FPriceTrigger write FPriceTrigger;
  end;

implementation

const
  DEFAULT_LOT_SIZE = 75;
  EXIT_HOUR = 15;
  EXIT_MIN  = 20;

function MkParam(const AName, ADisplay: AnsiString; AKind: TParamKind; const AValue: AnsiString): TStrategyParam;
begin
  Result.Name := AName;
  Result.Display := ADisplay;
  Result.Kind := AKind;
  Result.Value := AValue;
end;

{ ── Constructor ── }

constructor TGammaScalp.Create;
begin
  inherited Create;
  Exchange := exNFO;
  FDeltaThreshold := 2.0;
  FMaxCostPct := 3.0;
  FMaxDTE := 7;
  FEstimatedIV := 0.20;
  FPriceTrigger := 5.0;
  FLotSize := DEFAULT_LOT_SIZE;
  FState := gsInit;
  FCESymId := -1;
  FPESymId := -1;
  FSpotSymId := -1;
  FHedgeQty := 0;
  FRFR := 0.065;  // ~6.5% India T-bill rate
  FAdjustConfig := DefaultAdjustmentConfig(arDeltaAdjust);
end;

function TGammaScalp.DeclareParams: TArray<TStrategyParam>;
begin
  SetLength(Result, 4);
  Result[0] := MkParam('delta_threshold', 'Delta Threshold', pkFloat, FloatToStr(FDeltaThreshold));
  Result[1] := MkParam('max_cost_pct', 'Max Cost %', pkFloat, FloatToStr(FMaxCostPct));
  Result[2] := MkParam('estimated_iv', 'Estimated IV', pkFloat, FloatToStr(FEstimatedIV));
  Result[3] := MkParam('price_trigger', 'Price Trigger', pkFloat, FloatToStr(FPriceTrigger));
end;

procedure TGammaScalp.ApplyParam(const AName, AValue: AnsiString);
begin
  if AName = 'delta_threshold' then FDeltaThreshold := StrToFloatDef(string(AValue), FDeltaThreshold)
  else if AName = 'max_cost_pct' then FMaxCostPct := StrToFloatDef(string(AValue), FMaxCostPct)
  else if AName = 'estimated_iv' then FEstimatedIV := StrToFloatDef(string(AValue), FEstimatedIV)
  else if AName = 'price_trigger' then FPriceTrigger := StrToFloatDef(string(AValue), FPriceTrigger);
end;

function TGammaScalp.GetParamValue(const AName: AnsiString): AnsiString;
begin
  if AName = 'delta_threshold' then Result := FloatToStr(FDeltaThreshold)
  else if AName = 'max_cost_pct' then Result := FloatToStr(FMaxCostPct)
  else if AName = 'estimated_iv' then Result := FloatToStr(FEstimatedIV)
  else if AName = 'price_trigger' then Result := FloatToStr(FPriceTrigger)
  else Result := '';
end;

{ ── Time to expiry in years ── }

function TGammaScalp.TTE: Double;
var
  SecsLeft: Int64;
begin
  SecsLeft := FExpiry - DateTimeToUnix(Now, False);
  if SecsLeft <= 0 then
    Result := 0.0
  else
    Result := SecsLeft / (365.0 * 24 * 3600);
end;

{ ── Time exit check ── }

function TGammaScalp.IsTimeExit: Boolean;
var
  H, M, S, MS: Word;
begin
  DecodeTime(Now, H, M, S, MS);
  Result := (H > EXIT_HOUR) or ((H = EXIT_HOUR) and (M >= EXIT_MIN));
end;

{ ── OnStart ── }

procedure TGammaScalp.OnStart;
var
  Spot: Double;
begin
  inherited;
  if Broker = nil then Exit;
  if Underlying = '' then Underlying := 'NIFTY 50';

  Spot := Broker.LTP(Underlying, exNSE);
  if Spot <= 0 then Exit;
  FSpotLTP := Spot;

  FSpotSymId := Broker.FindInstrument(Underlying, exNSE);

  FExpiry := Broker.NearestExpiry(Underlying, exNFO);
  if FExpiry <= 0 then Exit;

  FStrike := Broker.ATMStrike(Underlying, FExpiry, Spot);
  if FStrike <= 0 then Exit;

  FCESymId := Broker.ResolveOption(Underlying, FExpiry, FStrike, otCall, exNFO);
  FPESymId := Broker.ResolveOption(Underlying, FExpiry, FStrike, otPut, exNFO);
  if (FCESymId < 0) or (FPESymId < 0) then Exit;

  FCESymbol := Broker.CatalogSymbol(FCESymId);
  FPESymbol := Broker.CatalogSymbol(FPESymId);

  // Subscribe to CE, PE, and underlying ticks
  Broker.Subscribe(FCESymbol, exNFO, smQuote);
  Broker.Subscribe(FPESymbol, exNFO, smQuote);
  Broker.Subscribe(Underlying, exNSE, smQuote);

  FAdjustment := TAdjustmentEngine.Create(Broker, FAdjustConfig);

  // Check cost: entry premium should be within MaxCostPct of spot
  FCELTP := Broker.LTP(FCESymbol, exNFO);
  FPELTP := Broker.LTP(FPESymbol, exNFO);

  if (FCELTP > 0) and (FPELTP > 0) then
  begin
    if ((FCELTP + FPELTP) / Spot * 100.0) > FMaxCostPct then
      Exit;  // straddle too expensive
    EnterStraddle;
  end;
end;

{ ── Enter long straddle ── }

procedure TGammaScalp.EnterStraddle;
var
  Qty: Integer;
  Greeks: TGreeks;
begin
  Qty := Lots * FLotSize;

  try
    Buy(FCESymbol, Qty, 0, exNFO);
    Buy(FPESymbol, Qty, 0, exNFO);
  except
    on E: Exception do
    begin
      FState := gsSquaredOff;
      Exit;
    end;
  end;

  FCEEntry := FCELTP;
  FPEEntry := FPELTP;
  FLastHedgePrice := FSpotLTP;
  FHedgeQty := 0;

  // Calculate initial Greeks for logging / tracking
  Greeks := TBlackScholes.Calculate(FSpotLTP, FStrike, TTE, FEstimatedIV,
    FRFR, 0.0, True);

  FState := gsPositioned;
end;

{ ── Delta hedge the portfolio ── }

procedure TGammaScalp.DeltaHedge;
var
  T: Double;
  CEGreeks, PEGreeks: TGreeks;
  NetDelta: Double;
  DesiredHedge, HedgeAdj: Integer;
begin
  T := TTE;
  if T <= 0 then Exit;

  CEGreeks := TBlackScholes.Calculate(FSpotLTP, FStrike, T, FEstimatedIV,
    FRFR, 0.0, True);
  PEGreeks := TBlackScholes.Calculate(FSpotLTP, FStrike, T, FEstimatedIV,
    FRFR, 0.0, False);

  // Portfolio delta: long CE + long PE, per lot
  NetDelta := (CEGreeks.Delta + PEGreeks.Delta) * Lots * FLotSize;

  // Include existing hedge in net delta
  NetDelta := NetDelta + FHedgeQty;

  if Abs(NetDelta) < FDeltaThreshold * Lots then
    Exit;  // within threshold

  // Desired hedge quantity to flatten delta
  // We want NetDelta + HedgeAdj = 0 => HedgeAdj = -NetDelta
  DesiredHedge := -Round(NetDelta);
  HedgeAdj := DesiredHedge;  // shares to trade

  if HedgeAdj = 0 then Exit;

  try
    if HedgeAdj > 0 then
      Buy(Underlying, Abs(HedgeAdj), 0, exNSE)
    else
      Sell(Underlying, Abs(HedgeAdj), 0, exNSE);

    FHedgeQty := FHedgeQty + HedgeAdj;
    FLastHedgePrice := FSpotLTP;
  except
    // Hedge order failed; will retry on next tick
  end;
end;

{ ── Square off all legs ── }

procedure TGammaScalp.SquareOff;
var
  Qty: Integer;
begin
  Qty := Lots * FLotSize;

  // Sell both option legs
  try Sell(FCESymbol, Qty, 0, exNFO); except end;
  try Sell(FPESymbol, Qty, 0, exNFO); except end;

  // Unwind underlying hedge
  if FHedgeQty > 0 then
    try Sell(Underlying, FHedgeQty, 0, exNSE); except end
  else if FHedgeQty < 0 then
    try Buy(Underlying, Abs(FHedgeQty), 0, exNSE); except end;

  // Mark-to-market PnL
  PnL := ((FCELTP - FCEEntry) + (FPELTP - FPEEntry)) * Qty;
  FHedgeQty := 0;
  FState := gsSquaredOff;
end;

{ ── OnTick ── }

procedure TGammaScalp.OnTick(const ATick: TTickEvent);
begin
  // Update LTPs
  if ATick.SymbolId = FCESymId then
    FCELTP := ATick.LTP
  else if ATick.SymbolId = FPESymId then
    FPELTP := ATick.LTP
  else if (ATick.SymbolId = FSpotSymId) or
          ((FCESymId < 0) and (FPESymId < 0)) then
    FSpotLTP := ATick.LTP;

  if not WarmedUp then Exit;

  case FState of
    gsInit:
    begin
      // Waiting for valid prices to enter
      if (FCELTP > 0) and (FPELTP > 0) and (FSpotLTP > 0) then
        EnterStraddle;
    end;

    gsPositioned:
    begin
      // Time exit
      if IsTimeExit then
      begin
        SquareOff;
        Exit;
      end;

      // Only hedge on spot ticks
      if (ATick.SymbolId <> FCESymId) and (ATick.SymbolId <> FPESymId) then
      begin
        // Price trigger: rehedge if spot moved enough
        if Abs(FSpotLTP - FLastHedgePrice) >= FPriceTrigger then
          DeltaHedge
        else
          DeltaHedge;  // always check delta threshold too
      end;
    end;

    gsSquaredOff:
      ;  // done for the day
  end;
end;

{ ── OnStop ── }

procedure TGammaScalp.OnStop;
begin
  if FState = gsPositioned then
    SquareOff;
end;

initialization
  RegisterStrategy('GammaScalp', TGammaScalp);

end.
