{
  Momentum — EMA crossover + velocity + ATR trailing stop strategy.

  Entry: price velocity exceeds threshold AND fast EMA > slow EMA (buy),
         or velocity < -threshold AND fast EMA < slow EMA (sell).
  Exit:  ATR trailing stop, max loss, take profit (ATR multiple), time exit.

  Velocity is computed as a rolling rate-of-change over VelocityPeriod ticks,
  stored in a circular buffer. ATR trailing stop adjusts on each tick
  when price moves in favour.
}
unit Topaz.Strategy.Momentum;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Math, Thorium.Broker, Topaz.EventTypes, Topaz.Strategy,
  Topaz.Indicators;

type
  TMomentumStrategy = class(TStrategy)
  private
    { Parameters }
    FFastPeriod: Integer;
    FSlowPeriod: Integer;
    FVelocityPeriod: Integer;
    FVelocityThreshold: Double;
    FATRPeriod: Integer;
    FATRMultiplier: Double;
    FMaxLoss: Double;
    FTPMultiplier: Double;

    { Indicators }
    FFastEMA: TEMA;
    FSlowEMA: TEMA;
    FATR: TATR;

    { Velocity rolling buffer }
    FVelBuf: array[0..255] of Double;
    FVelPos: Integer;
    FVelCount: Integer;

    { Position state }
    FInPosition: Boolean;
    FPositionSide: Integer;     // +1 = long, -1 = short
    FEntryPrice: Double;
    FTrailingStop: Double;
    FHighWatermark: Double;     // best price since entry (long)
    FLowWatermark: Double;      // best price since entry (short)

    function Velocity(APrice: Double): Double;
    function TimeExitDue: Boolean;
  protected
    procedure OnStart; override;
    procedure OnTick(const ATick: TTickEvent); override;
    procedure OnStop; override;
  public
    constructor Create;
    function DeclareParams: TArray<TStrategyParam>; override;
    procedure ApplyParam(const AName, AValue: AnsiString); override;
    function GetParamValue(const AName: AnsiString): AnsiString; override;
    property FastPeriod: Integer read FFastPeriod write FFastPeriod;
    property SlowPeriod: Integer read FSlowPeriod write FSlowPeriod;
    property VelocityPeriod: Integer read FVelocityPeriod write FVelocityPeriod;
    property VelocityThreshold: Double read FVelocityThreshold write FVelocityThreshold;
    property ATRPeriod: Integer read FATRPeriod write FATRPeriod;
    property ATRMultiplier: Double read FATRMultiplier write FATRMultiplier;
    property MaxLoss: Double read FMaxLoss write FMaxLoss;
    property TPMultiplier: Double read FTPMultiplier write FTPMultiplier;
  end;

implementation

function MkParam(const AName, ADisplay: AnsiString; AKind: TParamKind; const AValue: AnsiString): TStrategyParam;
begin
  Result.Name := AName;
  Result.Display := ADisplay;
  Result.Kind := AKind;
  Result.Value := AValue;
end;

{ ── Constructor ── }

constructor TMomentumStrategy.Create;
begin
  inherited Create;
  FFastPeriod := 9;
  FSlowPeriod := 21;
  FVelocityPeriod := 20;
  FVelocityThreshold := 0.15;
  FATRPeriod := 14;
  FATRMultiplier := 2.0;
  FMaxLoss := 5000.0;
  FTPMultiplier := 3.0;
  FInPosition := False;
end;

function TMomentumStrategy.DeclareParams: TArray<TStrategyParam>;
begin
  SetLength(Result, 6);
  Result[0] := MkParam('fast_period', 'Fast Period', pkInteger, IntToStr(FFastPeriod));
  Result[1] := MkParam('slow_period', 'Slow Period', pkInteger, IntToStr(FSlowPeriod));
  Result[2] := MkParam('atr_multiplier', 'ATR Multiplier', pkFloat, FloatToStr(FATRMultiplier));
  Result[3] := MkParam('velocity_threshold', 'Velocity Threshold', pkFloat, FloatToStr(FVelocityThreshold));
  Result[4] := MkParam('max_loss', 'Max Loss', pkFloat, FloatToStr(FMaxLoss));
  Result[5] := MkParam('take_profit_atr', 'Take Profit ATR', pkFloat, FloatToStr(FTPMultiplier));
end;

procedure TMomentumStrategy.ApplyParam(const AName, AValue: AnsiString);
begin
  if AName = 'fast_period' then FFastPeriod := StrToIntDef(string(AValue), FFastPeriod)
  else if AName = 'slow_period' then FSlowPeriod := StrToIntDef(string(AValue), FSlowPeriod)
  else if AName = 'atr_multiplier' then FATRMultiplier := StrToFloatDef(string(AValue), FATRMultiplier)
  else if AName = 'velocity_threshold' then FVelocityThreshold := StrToFloatDef(string(AValue), FVelocityThreshold)
  else if AName = 'max_loss' then FMaxLoss := StrToFloatDef(string(AValue), FMaxLoss)
  else if AName = 'take_profit_atr' then FTPMultiplier := StrToFloatDef(string(AValue), FTPMultiplier);
end;

function TMomentumStrategy.GetParamValue(const AName: AnsiString): AnsiString;
begin
  if AName = 'fast_period' then Result := IntToStr(FFastPeriod)
  else if AName = 'slow_period' then Result := IntToStr(FSlowPeriod)
  else if AName = 'atr_multiplier' then Result := FloatToStr(FATRMultiplier)
  else if AName = 'velocity_threshold' then Result := FloatToStr(FVelocityThreshold)
  else if AName = 'max_loss' then Result := FloatToStr(FMaxLoss)
  else if AName = 'take_profit_atr' then Result := FloatToStr(FTPMultiplier)
  else Result := '';
end;

{ ── Velocity helper ── }

function TMomentumStrategy.Velocity(APrice: Double): Double;
var
  OldIdx: Integer;
  OldPrice: Double;
begin
  FVelBuf[FVelPos] := APrice;
  FVelPos := (FVelPos + 1) mod FVelocityPeriod;
  if FVelCount < FVelocityPeriod then
    Inc(FVelCount);

  if FVelCount < FVelocityPeriod then
    Exit(0.0);

  OldIdx := FVelPos; // oldest entry (circular)
  OldPrice := FVelBuf[OldIdx];
  if OldPrice <> 0 then
    Result := (APrice - OldPrice) / OldPrice
  else
    Result := 0.0;
end;

{ ── Time exit: 15:20 IST ── }

function TMomentumStrategy.TimeExitDue: Boolean;
var
  H, M, S, Ms: Word;
begin
  DecodeTime(Now, H, M, S, Ms);
  Result := (H > 15) or ((H = 15) and (M >= 20));
end;

{ ── Lifecycle ── }

procedure TMomentumStrategy.OnStart;
begin
  inherited;
  FFastEMA.Init(FFastPeriod);
  FSlowEMA.Init(FSlowPeriod);
  FATR.Init(FATRPeriod);

  FVelPos := 0;
  FVelCount := 0;
  FillChar(FVelBuf, SizeOf(FVelBuf), 0);

  FInPosition := False;
end;

procedure TMomentumStrategy.OnTick(const ATick: TTickEvent);
var
  FastVal, SlowVal, Vel, ATRVal: Double;
  PnLNow, TakeProfit: Double;
  NewStop: Double;
begin
  { Update indicators }
  FastVal := FFastEMA.Update(ATick.LTP);
  SlowVal := FSlowEMA.Update(ATick.LTP);
  ATRVal := FATR.Update(ATick.LTP, ATick.LTP, ATick.LTP);
  Vel := Velocity(ATick.LTP);

  if not WarmedUp then Exit;

  { ── Exit logic ── }
  if FInPosition then
  begin
    if FPositionSide = 1 then
    begin
      PnLNow := (ATick.LTP - FEntryPrice) * Lots;

      { Update high watermark and trailing stop }
      if ATick.LTP > FHighWatermark then
      begin
        FHighWatermark := ATick.LTP;
        NewStop := FHighWatermark - FATRMultiplier * ATRVal;
        if NewStop > FTrailingStop then
          FTrailingStop := NewStop;
      end;

      TakeProfit := FEntryPrice + FTPMultiplier * ATRVal;

      { Trailing stop hit }
      if ATick.LTP <= FTrailingStop then
      begin
        Sell(Underlying, Lots, 0, Exchange);
        PnL := PnL + PnLNow;
        FInPosition := False;
        Exit;
      end;

      { Take profit }
      if ATick.LTP >= TakeProfit then
      begin
        Sell(Underlying, Lots, 0, Exchange);
        PnL := PnL + PnLNow;
        FInPosition := False;
        Exit;
      end;

      { Max loss }
      if PnLNow <= -FMaxLoss then
      begin
        Sell(Underlying, Lots, 0, Exchange);
        PnL := PnL + PnLNow;
        FInPosition := False;
        Exit;
      end;

      { Time exit }
      if TimeExitDue then
      begin
        Sell(Underlying, Lots, 0, Exchange);
        PnL := PnL + PnLNow;
        FInPosition := False;
        Exit;
      end;
    end
    else
    begin
      PnLNow := (FEntryPrice - ATick.LTP) * Lots;

      { Update low watermark and trailing stop }
      if ATick.LTP < FLowWatermark then
      begin
        FLowWatermark := ATick.LTP;
        NewStop := FLowWatermark + FATRMultiplier * ATRVal;
        if NewStop < FTrailingStop then
          FTrailingStop := NewStop;
      end;

      TakeProfit := FEntryPrice - FTPMultiplier * ATRVal;

      { Trailing stop hit }
      if ATick.LTP >= FTrailingStop then
      begin
        Buy(Underlying, Lots, 0, Exchange);
        PnL := PnL + PnLNow;
        FInPosition := False;
        Exit;
      end;

      { Take profit }
      if ATick.LTP <= TakeProfit then
      begin
        Buy(Underlying, Lots, 0, Exchange);
        PnL := PnL + PnLNow;
        FInPosition := False;
        Exit;
      end;

      { Max loss }
      if PnLNow <= -FMaxLoss then
      begin
        Buy(Underlying, Lots, 0, Exchange);
        PnL := PnL + PnLNow;
        FInPosition := False;
        Exit;
      end;

      { Time exit }
      if TimeExitDue then
      begin
        Buy(Underlying, Lots, 0, Exchange);
        PnL := PnL + PnLNow;
        FInPosition := False;
        Exit;
      end;
    end;

    Exit; // no new entry while in position
  end;

  { ── Entry logic ── }
  if TimeExitDue then Exit; // no entries after 15:20

  if not FATR.Ready then Exit;

  { Long: velocity > threshold AND fast EMA > slow EMA }
  if (Vel > FVelocityThreshold) and (FastVal > SlowVal) then
  begin
    Buy(Underlying, Lots, 0, Exchange);
    FInPosition := True;
    FPositionSide := 1;
    FEntryPrice := ATick.LTP;
    FHighWatermark := ATick.LTP;
    FTrailingStop := ATick.LTP - FATRMultiplier * ATRVal;
    Exit;
  end;

  { Short: velocity < -threshold AND fast EMA < slow EMA }
  if (Vel < -FVelocityThreshold) and (FastVal < SlowVal) then
  begin
    Sell(Underlying, Lots, 0, Exchange);
    FInPosition := True;
    FPositionSide := -1;
    FEntryPrice := ATick.LTP;
    FLowWatermark := ATick.LTP;
    FTrailingStop := ATick.LTP + FATRMultiplier * ATRVal;
  end;
end;

procedure TMomentumStrategy.OnStop;
begin
  if FInPosition then
  begin
    if FPositionSide = 1 then
      Sell(Underlying, Lots, 0, Exchange)
    else
      Buy(Underlying, Lots, 0, Exchange);
    FInPosition := False;
  end;
end;

initialization
  RegisterStrategy('Momentum', TMomentumStrategy);

end.
