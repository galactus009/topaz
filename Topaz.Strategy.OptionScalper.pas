{
  Topaz.Strategy.OptionScalper — Composite option scalper (short straddle).

  Sells ATM CE + PE at entry, buys back both legs at target or stop-loss.
  Tracks combined premium as a single composite position.

  Parameters (set via properties before starting):
    Underlying  — e.g. 'NIFTY 50'
    Lots        — number of lots (qty = Lots * LotSize)
    TargetPct   — profit target as % of entry premium (default 30%)
    StopPct     — stop-loss as % of entry premium (default 50%)
    EntryAfter  — minutes after market open to enter (default 5)
    ExitBefore  — minutes before market close to exit (default 10)

  Lifecycle:
    OnStart  → resolve nearest expiry, ATM strike, CE/PE symbols
    OnTick   → track LTP of underlying + both legs
               if not in position and entry window → sell straddle
               if in position → check target/SL/time exit
    OnStop   → square off if still in position
}
unit Topaz.Strategy.OptionScalper;

{$IFDEF FPC}{$mode Delphi}{$H+}{$ENDIF}

interface

uses
  SysUtils, Apollo.Broker, Topaz.EventTypes, Topaz.Strategy;

type
  TScalperState = (ssWaiting, ssPositioned, ssSquaredOff);

  TOptionScalper = class(TStrategy)
  private
    FTargetPct: Double;
    FStopPct: Double;
    FEntryAfter: Integer;
    FExitBefore: Integer;

    FState: TScalperState;
    FExpiry: Int64;
    FStrike: Double;
    FLotSize: Integer;

    FCESymId: Integer;
    FPESymId: Integer;
    FCESymbol: AnsiString;
    FPESymbol: AnsiString;

    FCEEntry: Double;
    FPEEntry: Double;
    FEntryPremium: Double;

    FCELTP: Double;
    FPELTP: Double;
    FSpotLTP: Double;

    FCEOrderId: AnsiString;
    FPEOrderId: AnsiString;

    function IsEntryWindow: Boolean;
    function IsExitWindow: Boolean;
    function CurrentPremium: Double;
    procedure EnterPosition;
    procedure ExitPosition;
  protected
    procedure OnStart; override;
    procedure OnTick(const ATick: TTickEvent); override;
    procedure OnStop; override;
  public
    constructor Create;
    property TargetPct: Double read FTargetPct write FTargetPct;
    property StopPct: Double read FStopPct write FStopPct;
    property EntryAfter: Integer read FEntryAfter write FEntryAfter;
    property ExitBefore: Integer read FExitBefore write FExitBefore;
  end;

implementation

const
  MARKET_OPEN_HOUR  = 9;
  MARKET_OPEN_MIN   = 15;
  MARKET_CLOSE_HOUR = 15;
  MARKET_CLOSE_MIN  = 30;
  DEFAULT_LOT_SIZE  = 75;

constructor TOptionScalper.Create;
begin
  inherited Create;
  Exchange := exNFO;
  FTargetPct := 30.0;
  FStopPct := 50.0;
  FEntryAfter := 5;
  FExitBefore := 10;
  FState := ssWaiting;
  FLotSize := DEFAULT_LOT_SIZE;
  FCESymId := -1;
  FPESymId := -1;
end;

procedure TOptionScalper.OnStart;
var
  Spot: Double;
begin
  if Broker = nil then Exit;
  if Underlying = '' then Underlying := 'NIFTY 50';

  Spot := Broker.LTP(Underlying, exNSE);
  if Spot <= 0 then Exit;
  FSpotLTP := Spot;

  FExpiry := Broker.NearestExpiry(Underlying, exNFO);
  if FExpiry <= 0 then Exit;

  FStrike := Broker.ATMStrike(Underlying, FExpiry, Spot);
  if FStrike <= 0 then Exit;

  FCESymId := Broker.ResolveOption(Underlying, FExpiry, FStrike, otCall, exNFO);
  FPESymId := Broker.ResolveOption(Underlying, FExpiry, FStrike, otPut, exNFO);

  if (FCESymId < 0) or (FPESymId < 0) then Exit;

  FCESymbol := Broker.CatalogSymbol(FCESymId);
  FPESymbol := Broker.CatalogSymbol(FPESymId);

  Broker.Subscribe(FCESymbol, exNFO, smQuote);
  Broker.Subscribe(FPESymbol, exNFO, smQuote);

  FState := ssWaiting;
end;

procedure TOptionScalper.OnTick(const ATick: TTickEvent);
var
  Premium, PnLPct: Double;
begin
  if ATick.SymbolId = FCESymId then
    FCELTP := ATick.LTP
  else if ATick.SymbolId = FPESymId then
    FPELTP := ATick.LTP
  else
    FSpotLTP := ATick.LTP;

  case FState of
    ssWaiting:
    begin
      if (FCELTP > 0) and (FPELTP > 0) and IsEntryWindow then
        EnterPosition;
    end;

    ssPositioned:
    begin
      if (FCELTP <= 0) or (FPELTP <= 0) then Exit;

      Premium := CurrentPremium;
      PnL := (FEntryPremium - Premium) * Lots * FLotSize;
      PnLPct := ((FEntryPremium - Premium) / FEntryPremium) * 100;

      if PnLPct >= FTargetPct then
        ExitPosition
      else if PnLPct <= -FStopPct then
        ExitPosition
      else if IsExitWindow then
        ExitPosition;
    end;

    ssSquaredOff:
      ; // done for the day
  end;
end;

procedure TOptionScalper.OnStop;
begin
  if FState = ssPositioned then
    ExitPosition;
end;

function TOptionScalper.IsEntryWindow: Boolean;
var
  H, M, S, MS: Word;
  MinSinceOpen: Integer;
begin
  DecodeTime(Now, H, M, S, MS);
  MinSinceOpen := (H - MARKET_OPEN_HOUR) * 60 + (M - MARKET_OPEN_MIN);
  Result := (MinSinceOpen >= FEntryAfter) and (H < MARKET_CLOSE_HOUR);
end;

function TOptionScalper.IsExitWindow: Boolean;
var
  H, M, S, MS: Word;
  MinToClose: Integer;
begin
  DecodeTime(Now, H, M, S, MS);
  MinToClose := (MARKET_CLOSE_HOUR - H) * 60 + (MARKET_CLOSE_MIN - M);
  Result := MinToClose <= FExitBefore;
end;

function TOptionScalper.CurrentPremium: Double;
begin
  Result := FCELTP + FPELTP;
end;

procedure TOptionScalper.EnterPosition;
var
  Qty: Integer;
begin
  Qty := Lots * FLotSize;

  try
    FCEOrderId := Sell(FCESymbol, Qty, 0, exNFO);
    FPEOrderId := Sell(FPESymbol, Qty, 0, exNFO);

    FCEEntry := FCELTP;
    FPEEntry := FPELTP;
    FEntryPremium := FCEEntry + FPEEntry;
    FState := ssPositioned;
  except
    on E: Exception do
    begin
      // If one leg filled, try to exit it
      if FCEOrderId <> '' then
        try Buy(FCESymbol, Qty, 0, exNFO); except end;
      FState := ssSquaredOff;
    end;
  end;
end;

procedure TOptionScalper.ExitPosition;
var
  Qty: Integer;
begin
  Qty := Lots * FLotSize;

  try
    Buy(FCESymbol, Qty, 0, exNFO);
  except
  end;

  try
    Buy(FPESymbol, Qty, 0, exNFO);
  except
  end;

  PnL := (FEntryPremium - CurrentPremium) * Lots * FLotSize;
  FState := ssSquaredOff;
end;

initialization
  RegisterStrategy('OptionScalper', TOptionScalper);

end.
