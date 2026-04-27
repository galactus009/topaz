{
  Topaz.Strategy.OptionsScalper -- RSI-driven premium scalper.

  Uses RSI as a proxy for order-flow direction to sell OTM options:
    RSI > 55 => bearish signal => sell CE
    RSI < 45 => bullish signal => sell PE

  Selects OTM strikes near a target delta using Black-Scholes estimation.
  Exits when premium drops by ScalpTargetPoints (profit) or rises by
  ScalpStopPoints (loss). Enforces MaxTrades and CooldownTicks between
  entries.

  Registered as 'OptionsScalper'.
}
unit Topaz.Strategy.OptionsScalper;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Math, DateUtils, Thorium.Broker, Topaz.EventTypes, Topaz.Strategy,
  Topaz.Indicators, Topaz.BlackScholes;

type
  TScalpSide = (ssNone, ssSoldCE, ssSoldPE);

  TOptionsScalper = class(TStrategy)
  private
    { -- Parameters -- }
    FScalpTargetPoints: Double;
    FScalpStopPoints: Double;
    FMaxTrades: Integer;
    FCooldownTicks: Integer;
    FImbalanceThreshold: Double;
    FTargetDelta: Double;
    FMinPremium: Double;
    FEstimatedIV: Double;

    { -- State -- }
    FRSI: TRSI;
    FExpiry: Int64;
    FSpotLTP: Double;
    FSpotSymId: Integer;

    FTradeCount: Integer;
    FTicksSinceTrade: Integer;

    FInPosition: Boolean;
    FPositionSide: TScalpSide;
    FEntryPremium: Double;
    FOptionSymId: Integer;
    FOptionSymbol: AnsiString;
    FOptionLTP: Double;
    FOptionStrike: Double;

    FRFR: Double;
    FLotSize: Integer;

    function FindOTMStrike(IsCall: Boolean): Double;
    procedure EnterTrade(Side: TScalpSide);
    procedure ExitTrade;
    function IsTimeExit: Boolean;
  protected
    procedure OnStart; override;
    procedure OnTick(const ATick: TTickEvent); override;
    procedure OnStop; override;
  public
    constructor Create;
    function DeclareParams: TArray<TStrategyParam>; override;
    procedure ApplyParam(const AName, AValue: AnsiString); override;
    function GetParamValue(const AName: AnsiString): AnsiString; override;
    property ScalpTargetPoints: Double read FScalpTargetPoints write FScalpTargetPoints;
    property ScalpStopPoints: Double read FScalpStopPoints write FScalpStopPoints;
    property MaxTrades: Integer read FMaxTrades write FMaxTrades;
    property CooldownTicks: Integer read FCooldownTicks write FCooldownTicks;
    property ImbalanceThreshold: Double read FImbalanceThreshold write FImbalanceThreshold;
    property TargetDelta: Double read FTargetDelta write FTargetDelta;
    property MinPremium: Double read FMinPremium write FMinPremium;
    property EstimatedIV: Double read FEstimatedIV write FEstimatedIV;
  end;

implementation

const
  DEFAULT_LOT_SIZE = 75;
  RSI_PERIOD       = 14;
  RSI_BEARISH      = 55.0;
  RSI_BULLISH      = 45.0;
  EXIT_HOUR        = 15;
  EXIT_MIN         = 20;
  STRIKE_STEP      = 50.0;  // NIFTY strike interval

function MkParam(const AName, ADisplay: AnsiString; AKind: TParamKind; const AValue: AnsiString): TStrategyParam;
begin
  Result.Name := AName;
  Result.Display := ADisplay;
  Result.Kind := AKind;
  Result.Value := AValue;
end;

{ ── Constructor ── }

constructor TOptionsScalper.Create;
begin
  inherited Create;
  Exchange := exNFO;
  FScalpTargetPoints := 5.0;
  FScalpStopPoints := 3.0;
  FMaxTrades := 10;
  FCooldownTicks := 30;
  FImbalanceThreshold := 2.0;
  FTargetDelta := 0.25;
  FMinPremium := 5.0;
  FEstimatedIV := 0.15;
  FLotSize := DEFAULT_LOT_SIZE;
  FRFR := 0.065;
  FInPosition := False;
  FPositionSide := ssNone;
  FTradeCount := 0;
  FTicksSinceTrade := 0;
  FSpotSymId := -1;
  FOptionSymId := -1;
end;

function TOptionsScalper.DeclareParams: TArray<TStrategyParam>;
begin
  SetLength(Result, 5);
  Result[0] := MkParam('scalp_target_points', 'Scalp Target Points', pkFloat, FloatToStr(FScalpTargetPoints));
  Result[1] := MkParam('scalp_stop_points', 'Scalp Stop Points', pkFloat, FloatToStr(FScalpStopPoints));
  Result[2] := MkParam('max_trades', 'Max Trades', pkInteger, IntToStr(FMaxTrades));
  Result[3] := MkParam('cooldown_ticks', 'Cooldown Ticks', pkInteger, IntToStr(FCooldownTicks));
  Result[4] := MkParam('target_delta', 'Target Delta', pkFloat, FloatToStr(FTargetDelta));
end;

procedure TOptionsScalper.ApplyParam(const AName, AValue: AnsiString);
begin
  if AName = 'scalp_target_points' then FScalpTargetPoints := StrToFloatDef(string(AValue), FScalpTargetPoints)
  else if AName = 'scalp_stop_points' then FScalpStopPoints := StrToFloatDef(string(AValue), FScalpStopPoints)
  else if AName = 'max_trades' then FMaxTrades := StrToIntDef(string(AValue), FMaxTrades)
  else if AName = 'cooldown_ticks' then FCooldownTicks := StrToIntDef(string(AValue), FCooldownTicks)
  else if AName = 'target_delta' then FTargetDelta := StrToFloatDef(string(AValue), FTargetDelta);
end;

function TOptionsScalper.GetParamValue(const AName: AnsiString): AnsiString;
begin
  if AName = 'scalp_target_points' then Result := FloatToStr(FScalpTargetPoints)
  else if AName = 'scalp_stop_points' then Result := FloatToStr(FScalpStopPoints)
  else if AName = 'max_trades' then Result := IntToStr(FMaxTrades)
  else if AName = 'cooldown_ticks' then Result := IntToStr(FCooldownTicks)
  else if AName = 'target_delta' then Result := FloatToStr(FTargetDelta)
  else Result := '';
end;

{ ── Find OTM strike near target delta ── }

function TOptionsScalper.FindOTMStrike(IsCall: Boolean): Double;
var
  Strike, BestStrike, BestDiff: Double;
  Greeks: TGreeks;
  T, AbsDelta: Double;
  I: Integer;
begin
  Result := 0;
  T := (FExpiry - DateTimeToUnix(Now, False)) / (365.0 * 24 * 3600);
  if T <= 0 then Exit;

  BestStrike := 0;
  BestDiff := 999.0;

  // Scan strikes: for CE go above spot, for PE go below spot
  for I := 1 to 20 do
  begin
    if IsCall then
      Strike := Round(FSpotLTP / STRIKE_STEP) * STRIKE_STEP + I * STRIKE_STEP
    else
      Strike := Round(FSpotLTP / STRIKE_STEP) * STRIKE_STEP - I * STRIKE_STEP;

    if Strike <= 0 then Continue;

    Greeks := TBlackScholes.Calculate(FSpotLTP, Strike, T, FEstimatedIV,
      FRFR, 0.0, IsCall);

    AbsDelta := Abs(Greeks.Delta);
    if Abs(AbsDelta - FTargetDelta) < BestDiff then
    begin
      BestDiff := Abs(AbsDelta - FTargetDelta);
      BestStrike := Strike;
    end;

    // Once delta is much smaller than target, stop searching
    if AbsDelta < FTargetDelta * 0.3 then
      Break;
  end;

  Result := BestStrike;
end;

{ ── Enter a scalp trade ── }

procedure TOptionsScalper.EnterTrade(Side: TScalpSide);
var
  Strike: Double;
  OptType: TOptionType;
  SymId: Integer;
  Symbol: AnsiString;
  Qty: Integer;
  Premium: Double;
begin
  if Side = ssSoldCE then
  begin
    Strike := FindOTMStrike(True);
    OptType := otCall;
  end
  else
  begin
    Strike := FindOTMStrike(False);
    OptType := otPut;
  end;

  if Strike <= 0 then Exit;

  SymId := Broker.ResolveOption(Underlying, FExpiry, Strike, OptType, exNFO);
  if SymId < 0 then Exit;

  Symbol := Broker.CatalogSymbol(SymId);
  if Symbol = '' then Exit;

  // Get current premium
  Premium := Broker.LTP(Symbol, exNFO);
  if Premium < FMinPremium then Exit;

  Qty := Lots * FLotSize;

  try
    Sell(Symbol, Qty, 0, exNFO);
  except
    Exit;
  end;

  // Subscribe to track the sold option
  Broker.Subscribe(Symbol, exNFO, smQuote);

  FInPosition := True;
  FPositionSide := Side;
  FEntryPremium := Premium;
  FOptionSymId := SymId;
  FOptionSymbol := Symbol;
  FOptionLTP := Premium;
  FOptionStrike := Strike;
  FTicksSinceTrade := 0;
  Inc(FTradeCount);
end;

{ ── Exit current trade ── }

procedure TOptionsScalper.ExitTrade;
var
  Qty: Integer;
  TradeResult: Double;
begin
  if not FInPosition then Exit;

  Qty := Lots * FLotSize;

  try
    Buy(FOptionSymbol, Qty, 0, exNFO);
  except
  end;

  // P&L for short option: entry premium - exit premium
  TradeResult := (FEntryPremium - FOptionLTP) * Qty;
  PnL := PnL + TradeResult;

  FInPosition := False;
  FPositionSide := ssNone;
  FOptionSymId := -1;
end;

{ ── Time exit check ── }

function TOptionsScalper.IsTimeExit: Boolean;
var
  H, M, S, MS: Word;
begin
  DecodeTime(Now, H, M, S, MS);
  Result := (H > EXIT_HOUR) or ((H = EXIT_HOUR) and (M >= EXIT_MIN));
end;

{ ── OnStart ── }

procedure TOptionsScalper.OnStart;
begin
  inherited;
  if Broker = nil then Exit;
  if Underlying = '' then Underlying := 'NIFTY 50';

  FSpotLTP := Broker.LTP(Underlying, exNSE);
  if FSpotLTP <= 0 then Exit;

  FSpotSymId := Broker.FindInstrument(Underlying, exNSE);

  FExpiry := Broker.NearestExpiry(Underlying, exNFO);
  if FExpiry <= 0 then Exit;

  FRSI.Init(RSI_PERIOD);

  // Subscribe to underlying for spot ticks
  Broker.Subscribe(Underlying, exNSE, smQuote);
end;

{ ── OnTick ── }

procedure TOptionsScalper.OnTick(const ATick: TTickEvent);
var
  RSIVal: Double;
begin
  // Option tick: update option LTP
  if FInPosition and (ATick.SymbolId = FOptionSymId) then
  begin
    FOptionLTP := ATick.LTP;

    // Check profit target (premium dropped)
    if (FEntryPremium - FOptionLTP) >= FScalpTargetPoints then
    begin
      ExitTrade;
      Exit;
    end;

    // Check stop loss (premium rose)
    if (FOptionLTP - FEntryPremium) >= FScalpStopPoints then
    begin
      ExitTrade;
      Exit;
    end;

    Exit;
  end;

  // Spot tick: update spot and RSI
  FSpotLTP := ATick.LTP;
  FRSI.Update(ATick.LTP);

  if not WarmedUp then Exit;

  Inc(FTicksSinceTrade);

  // Time exit
  if FInPosition and IsTimeExit then
  begin
    ExitTrade;
    Exit;
  end;

  // Don't enter new trades during time exit window
  if IsTimeExit then Exit;

  // Need RSI to be ready
  if not FRSI.Ready then Exit;

  // If in position, wait for exit (handled above on option ticks)
  if FInPosition then Exit;

  // Check trade limits
  if FTradeCount >= FMaxTrades then Exit;

  // Cooldown
  if FTicksSinceTrade < FCooldownTicks then Exit;

  // RSI signal
  RSIVal := FRSI.Value;

  if RSIVal > RSI_BEARISH then
    EnterTrade(ssSoldCE)    // bearish: sell call
  else if RSIVal < RSI_BULLISH then
    EnterTrade(ssSoldPE);   // bullish: sell put
end;

{ ── OnStop ── }

procedure TOptionsScalper.OnStop;
begin
  if FInPosition then
    ExitTrade;
end;

initialization
  RegisterStrategy('OptionsScalper', TOptionsScalper);

end.
