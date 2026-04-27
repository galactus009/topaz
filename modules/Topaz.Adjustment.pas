{
  Topaz.Adjustment -- Auto-Adjustment Engine for Options.

  Monitors option positions and triggers adjustments when delta exceeds
  thresholds or DTE drops below minimum. Supports rolling untested legs,
  widening strikes, adding hedges, rolling expiry, and delta-adjusting.

  Adjustment actions are returned as intent-compatible records for
  submission through TIntentEngine.
}
unit Topaz.Adjustment;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Math, StrUtils, Thorium.Broker, Topaz.BlackScholes, Topaz.Intents;

type
  TAdjustmentRule = (
    arRollUntested,    // roll untested leg closer when tested leg approaches strike
    arWidenStrikes,    // widen strikes to reduce risk
    arAddHedge,        // add a protective leg
    arRollExpiry,      // roll to next expiry at N DTE
    arDeltaAdjust      // adjust to maintain target delta
  );

  TAdjustmentConfig = record
    Enabled: Boolean;
    Rule: TAdjustmentRule;
    TriggerDelta: Double;      // adjust when abs(delta) exceeds this (default 0.30)
    TargetDelta: Double;       // adjust back to this delta (default 0.15)
    RollAtDTE: Integer;        // roll when DTE <= this (default 1)
    MaxAdjustments: Integer;   // max adjustments per position (default 3)
    MinPremiumToRoll: Double;  // min premium to receive on roll (default 1.0)
  end;

  TAdjustmentAction = record
    Description: AnsiString;
    CloseLegs: array of AnsiString;   // symbols to close
    OpenLegs: array of TIntent;       // new legs to open
  end;

  TAdjustmentEngine = class
  private
    FBroker: TBroker;
    FConfig: TAdjustmentConfig;
    FAdjustmentCount: Integer;
  public
    constructor Create(ABroker: TBroker; const AConfig: TAdjustmentConfig);

    { Check if adjustment needed. Returns action to take (or empty if none). }
    function CheckAdjustment(
      const ASymbol: AnsiString;   // option symbol
      AStrike, ASpot: Double;
      AIsCall: Boolean;
      ATTE, AIV: Double;
      AQty: Integer
    ): TAdjustmentAction;

    { Execute an adjustment action }
    procedure Execute(AIntentEngine: TIntentEngine; const AAction: TAdjustmentAction;
      const AStrategy: AnsiString);

    property AdjustmentCount: Integer read FAdjustmentCount;
    property Config: TAdjustmentConfig read FConfig write FConfig;
  end;

{ Return a default adjustment config with sensible values }
function DefaultAdjustmentConfig(ARule: TAdjustmentRule): TAdjustmentConfig;

implementation

{ ── DefaultAdjustmentConfig ──────────────────────────────────────────────────── }

function DefaultAdjustmentConfig(ARule: TAdjustmentRule): TAdjustmentConfig;
begin
  Result.Enabled := True;
  Result.Rule := ARule;
  Result.TriggerDelta := 0.30;
  Result.TargetDelta := 0.15;
  Result.RollAtDTE := 1;
  Result.MaxAdjustments := 3;
  Result.MinPremiumToRoll := 1.0;
end;

{ ── TAdjustmentEngine ────────────────────────────────────────────────────────── }

constructor TAdjustmentEngine.Create(ABroker: TBroker;
  const AConfig: TAdjustmentConfig);
begin
  inherited Create;
  FBroker := ABroker;
  FConfig := AConfig;
  FAdjustmentCount := 0;
end;

function TAdjustmentEngine.CheckAdjustment(
  const ASymbol: AnsiString;
  AStrike, ASpot: Double;
  AIsCall: Boolean;
  ATTE, AIV: Double;
  AQty: Integer): TAdjustmentAction;
var
  G: TGreeks;
  AbsDelta: Double;
  DTEDays: Integer;
  NewStrike: Double;
  OT: TOptionType;
  SymId: Integer;
  NewSymbol: AnsiString;
  Expiry: Int64;
  Intent: TIntent;
  HedgeQty: Integer;
begin
  // Initialize empty result
  SetLength(Result.CloseLegs, 0);
  SetLength(Result.OpenLegs, 0);
  Result.Description := '';

  if not FConfig.Enabled then
    Exit;

  // Stop if max adjustments reached
  if FAdjustmentCount >= FConfig.MaxAdjustments then
    Exit;

  // Compute current Greeks
  G := TBlackScholes.Calculate(ASpot, AStrike, ATTE, AIV, 0.05, 0.0, AIsCall);
  AbsDelta := Abs(G.Delta);
  DTEDays := Round(ATTE * 365.0);

  // ── Check DTE-based roll first (applies to arRollExpiry) ──
  if (FConfig.Rule = arRollExpiry) and (DTEDays <= FConfig.RollAtDTE) then
  begin
    // Close current leg, open same delta at next expiry
    SetLength(Result.CloseLegs, 1);
    Result.CloseLegs[0] := ASymbol;

    // Resolve next expiry (use nearest, which should be next weekly/monthly)
    // Note: this uses the underlying extracted from broker catalog
    if AIsCall then OT := otCall else OT := otPut;

    // Find new strike at target delta in next expiry
    // For simplicity, keep same strike and let caller adjust if needed
    FillChar(Intent, SizeOf(TIntent), 0);
    Intent.Kind := ikEntry;
    Intent.Symbol := ASymbol;  // placeholder -- caller should resolve next expiry
    Intent.Exchange := exNFO;
    if AQty > 0 then
      Intent.Side := sdBuy
    else
      Intent.Side := sdSell;
    Intent.Qty := Abs(AQty);
    Intent.Price := 0;  // market

    SetLength(Result.OpenLegs, 1);
    Result.OpenLegs[0] := Intent;

    Result.Description := Format(
      'Roll expiry: close %s (DTE=%d), open next expiry at same strike %.0f',
      [ASymbol, DTEDays, AStrike]);
    Exit;
  end;

  // ── Check delta-based triggers ──
  if AbsDelta <= FConfig.TriggerDelta then
    Exit;  // delta within bounds, no adjustment needed

  case FConfig.Rule of

    { ── Roll Untested: close current, open at target delta ── }
    arRollUntested:
    begin
      SetLength(Result.CloseLegs, 1);
      Result.CloseLegs[0] := ASymbol;

      // Find new strike at target delta
      // Move strike further OTM to reduce delta
      if AIsCall then
        NewStrike := AStrike + (AbsDelta - FConfig.TargetDelta) * ASpot * 0.5
      else
        NewStrike := AStrike - (AbsDelta - FConfig.TargetDelta) * ASpot * 0.5;

      // Round to nearest 50 (typical NSE strike interval)
      NewStrike := Round(NewStrike / 50.0) * 50.0;

      if AIsCall then OT := otCall else OT := otPut;
      Expiry := FBroker.NearestExpiry('', exNFO);  // current expiry
      SymId := FBroker.ResolveOption('', Expiry, NewStrike, OT, exNFO);

      FillChar(Intent, SizeOf(TIntent), 0);
      Intent.Kind := ikEntry;
      if SymId >= 0 then
        Intent.Symbol := FBroker.CatalogSymbol(SymId)
      else
        Intent.Symbol := ASymbol;  // fallback
      Intent.Exchange := exNFO;
      if AQty > 0 then
        Intent.Side := sdBuy
      else
        Intent.Side := sdSell;
      Intent.Qty := Abs(AQty);
      Intent.Price := 0;

      SetLength(Result.OpenLegs, 1);
      Result.OpenLegs[0] := Intent;

      Result.Description := Format(
        'Roll untested: close %s (delta=%.2f), open strike %.0f (target delta=%.2f)',
        [ASymbol, G.Delta, NewStrike, FConfig.TargetDelta]);
    end;

    { ── Widen Strikes: move strike further OTM ── }
    arWidenStrikes:
    begin
      SetLength(Result.CloseLegs, 1);
      Result.CloseLegs[0] := ASymbol;

      // Widen by moving 100 points further OTM
      if AIsCall then
        NewStrike := AStrike + 100
      else
        NewStrike := AStrike - 100;

      if AIsCall then OT := otCall else OT := otPut;
      Expiry := FBroker.NearestExpiry('', exNFO);
      SymId := FBroker.ResolveOption('', Expiry, NewStrike, OT, exNFO);

      FillChar(Intent, SizeOf(TIntent), 0);
      Intent.Kind := ikEntry;
      if SymId >= 0 then
        Intent.Symbol := FBroker.CatalogSymbol(SymId)
      else
        Intent.Symbol := ASymbol;
      Intent.Exchange := exNFO;
      if AQty > 0 then
        Intent.Side := sdBuy
      else
        Intent.Side := sdSell;
      Intent.Qty := Abs(AQty);
      Intent.Price := 0;

      SetLength(Result.OpenLegs, 1);
      Result.OpenLegs[0] := Intent;

      Result.Description := Format(
        'Widen strikes: close %s at %.0f (delta=%.2f), open at %.0f',
        [ASymbol, AStrike, G.Delta, NewStrike]);
    end;

    { ── Add Hedge: buy a protective leg further OTM ── }
    arAddHedge:
    begin
      // Do not close anything -- just add protection
      if AIsCall then
      begin
        // Being tested on call side: buy a further OTM call
        NewStrike := AStrike + 100;
        OT := otCall;
      end
      else
      begin
        // Being tested on put side: buy a further OTM put
        NewStrike := AStrike - 100;
        OT := otPut;
      end;

      NewStrike := Round(NewStrike / 50.0) * 50.0;
      Expiry := FBroker.NearestExpiry('', exNFO);
      SymId := FBroker.ResolveOption('', Expiry, NewStrike, OT, exNFO);

      FillChar(Intent, SizeOf(TIntent), 0);
      Intent.Kind := ikEntry;
      if SymId >= 0 then
        Intent.Symbol := FBroker.CatalogSymbol(SymId)
      else
        Intent.Symbol := '';
      Intent.Exchange := exNFO;
      Intent.Side := sdBuy;  // always buy the hedge
      Intent.Qty := Abs(AQty);
      Intent.Price := 0;

      SetLength(Result.OpenLegs, 1);
      Result.OpenLegs[0] := Intent;

      Result.Description := Format(
        'Add hedge: buy %s at strike %.0f to protect %s (delta=%.2f)',
        [Intent.Symbol, NewStrike, ASymbol, G.Delta]);
    end;

    { ── Delta Adjust: add shares/futures to neutralize delta ── }
    arDeltaAdjust:
    begin
      // Calculate shares needed to bring delta back to target
      // HedgeQty = -(currentDelta - targetDelta) * Qty * LotSize
      // We use Qty directly here; lot-size multiplication is caller's responsibility
      HedgeQty := -Round((G.Delta - FConfig.TargetDelta) * Abs(AQty));
      if HedgeQty = 0 then
        Exit;

      FillChar(Intent, SizeOf(TIntent), 0);
      Intent.Kind := ikEntry;
      Intent.Symbol := '';  // underlying symbol -- caller must set
      Intent.Exchange := exNSE;
      if HedgeQty > 0 then
      begin
        Intent.Side := sdBuy;
        Intent.Qty := HedgeQty;
      end
      else
      begin
        Intent.Side := sdSell;
        Intent.Qty := Abs(HedgeQty);
      end;
      Intent.Price := 0;

      SetLength(Result.OpenLegs, 1);
      Result.OpenLegs[0] := Intent;

      Result.Description := Format(
        'Delta adjust: %s %d shares to neutralize (delta=%.2f, target=%.2f)',
        [IfThen(HedgeQty > 0, 'buy', 'sell'), Abs(HedgeQty),
         G.Delta, FConfig.TargetDelta]);
    end;

    { ── Roll Expiry: handled above in DTE check; delta trigger fallthrough ── }
    arRollExpiry:
    begin
      // Delta exceeded but DTE not yet at roll threshold -- no action
      Exit;
    end;
  end;
end;

{ ── Execute ──────────────────────────────────────────────────────────────────── }

procedure TAdjustmentEngine.Execute(AIntentEngine: TIntentEngine;
  const AAction: TAdjustmentAction; const AStrategy: AnsiString);
var
  I: Integer;
  CloseIntent: TIntent;
  OpenIntent: TIntent;
begin
  if (Length(AAction.CloseLegs) = 0) and (Length(AAction.OpenLegs) = 0) then
    Exit;  // nothing to do

  // Submit close intents for legs being removed
  for I := 0 to High(AAction.CloseLegs) do
  begin
    FillChar(CloseIntent, SizeOf(TIntent), 0);
    CloseIntent.Kind := ikExit;
    CloseIntent.Symbol := AAction.CloseLegs[I];
    CloseIntent.Exchange := exNFO;
    CloseIntent.Tag := AStrategy;
    CloseIntent.Price := 0;  // market
    AIntentEngine.Submit(CloseIntent);
  end;

  // Submit open intents for new legs
  for I := 0 to High(AAction.OpenLegs) do
  begin
    OpenIntent := AAction.OpenLegs[I];
    OpenIntent.Tag := AStrategy;
    AIntentEngine.Submit(OpenIntent);
  end;

  Inc(FAdjustmentCount);
end;

end.
