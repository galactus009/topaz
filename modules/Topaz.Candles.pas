(**
 * Topaz.Candles — Multi-Timeframe Candle Aggregator
 *
 * Streaming candle builder from ticks. Supports multiple timeframes
 * simultaneously. TCandleBuilder is a stack-allocated record (zero heap).
 * TCandleEngine wraps multiple builders for convenience.
 *
 * Usage:
 *   Engine := TCandleEngine.Create;
 *   try
 *     Engine.EnableTimeframe(tf1m);
 *     Engine.EnableTimeframe(tf5m);
 *     Mask := Engine.Update(Price, Volume, Now);
 *     if (Mask and (1 shl Ord(tf1m))) <> 0 then
 *       WriteLn('1m candle closed: ', Engine.GetLastComplete(tf1m).Close:0:2);
 *   finally
 *     Engine.Free;
 *   end;
 *)
unit Topaz.Candles;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, DateUtils;

type
  TTimeframe = (tf1m, tf5m, tf15m, tf30m, tf1h, tf1d);

  TCandle = record
    Open, High, Low, Close: Double;
    Volume: Int64;
    StartTime: TDateTime;
    Complete: Boolean;
  end;

  TCandleBuilder = record
  private
    FCandle: TCandle;
    FLastComplete: TCandle;
    FIntervalSecs: Integer;
    FStarted: Boolean;
    FCurrentSlot: Int64;     // time slot index
    class function TimeToSlot(ATime: TDateTime; AIntervalSecs: Integer): Int64; static;
    class function SlotToTime(ASlot: Int64; AIntervalSecs: Integer): TDateTime; static;
  public
    procedure Init(ATimeframe: TTimeframe);
    function Update(APrice: Double; AVolume: Int64; ATime: TDateTime): Boolean;
      // Returns True when a candle completes
    function Current: TCandle;
    function LastComplete: TCandle;
    function Started: Boolean;
  end;

  TCandleEngine = class
  private
    FBuilders: array[TTimeframe] of TCandleBuilder;
    FEnabled: array[TTimeframe] of Boolean;
  public
    constructor Create;
    procedure EnableTimeframe(ATF: TTimeframe);
    procedure DisableTimeframe(ATF: TTimeframe);
    function Update(APrice: Double; AVolume: Int64; ATime: TDateTime): Integer;
      // Returns bitmask of completed timeframes
    function GetCandle(ATF: TTimeframe): TCandle;
    function GetLastComplete(ATF: TTimeframe): TCandle;
    function IsEnabled(ATF: TTimeframe): Boolean;
  end;

function TimeframeToSecs(ATF: TTimeframe): Integer;

implementation

{ ── Helpers ───────────────────────────────────────────────────────────────── }

function TimeframeToSecs(ATF: TTimeframe): Integer;
begin
  case ATF of
    tf1m:  Result := 60;
    tf5m:  Result := 300;
    tf15m: Result := 900;
    tf30m: Result := 1800;
    tf1h:  Result := 3600;
    tf1d:  Result := 86400;
  else
    Result := 60;
  end;
end;

{ ── TCandleBuilder ────────────────────────────────────────────────────────── }

class function TCandleBuilder.TimeToSlot(ATime: TDateTime; AIntervalSecs: Integer): Int64;
var
  UnixSecs: Int64;
begin
  UnixSecs := DateTimeToUnix(ATime);
  Result := UnixSecs div AIntervalSecs;
end;

class function TCandleBuilder.SlotToTime(ASlot: Int64; AIntervalSecs: Integer): TDateTime;
begin
  Result := UnixToDateTime(ASlot * AIntervalSecs);
end;

procedure TCandleBuilder.Init(ATimeframe: TTimeframe);
begin
  FIntervalSecs := TimeframeToSecs(ATimeframe);
  FStarted := False;
  FCurrentSlot := 0;
  FillChar(FCandle, SizeOf(TCandle), 0);
  FillChar(FLastComplete, SizeOf(TCandle), 0);
end;

function TCandleBuilder.Update(APrice: Double; AVolume: Int64; ATime: TDateTime): Boolean;
var
  Slot: Int64;
begin
  Result := False;
  Slot := TimeToSlot(ATime, FIntervalSecs);

  if not FStarted then
  begin
    // First tick — start a new candle
    FCurrentSlot := Slot;
    FCandle.Open := APrice;
    FCandle.High := APrice;
    FCandle.Low := APrice;
    FCandle.Close := APrice;
    FCandle.Volume := AVolume;
    FCandle.StartTime := SlotToTime(Slot, FIntervalSecs);
    FCandle.Complete := False;
    FStarted := True;
    Exit;
  end;

  if Slot = FCurrentSlot then
  begin
    // Same time slot — update OHLCV
    if APrice > FCandle.High then
      FCandle.High := APrice;
    if APrice < FCandle.Low then
      FCandle.Low := APrice;
    FCandle.Close := APrice;
    FCandle.Volume := FCandle.Volume + AVolume;
  end
  else
  begin
    // New time slot — complete current candle, start new one
    FCandle.Complete := True;
    FLastComplete := FCandle;
    Result := True;

    // Start new candle
    FCurrentSlot := Slot;
    FCandle.Open := APrice;
    FCandle.High := APrice;
    FCandle.Low := APrice;
    FCandle.Close := APrice;
    FCandle.Volume := AVolume;
    FCandle.StartTime := SlotToTime(Slot, FIntervalSecs);
    FCandle.Complete := False;
  end;
end;

function TCandleBuilder.Current: TCandle;
begin
  Result := FCandle;
end;

function TCandleBuilder.LastComplete: TCandle;
begin
  Result := FLastComplete;
end;

function TCandleBuilder.Started: Boolean;
begin
  Result := FStarted;
end;

{ ── TCandleEngine ─────────────────────────────────────────────────────────── }

constructor TCandleEngine.Create;
var
  TF: TTimeframe;
begin
  inherited Create;
  for TF := Low(TTimeframe) to High(TTimeframe) do
  begin
    FBuilders[TF].Init(TF);
    FEnabled[TF] := False;
  end;
end;

procedure TCandleEngine.EnableTimeframe(ATF: TTimeframe);
begin
  if not FEnabled[ATF] then
  begin
    FBuilders[ATF].Init(ATF);
    FEnabled[ATF] := True;
  end;
end;

procedure TCandleEngine.DisableTimeframe(ATF: TTimeframe);
begin
  FEnabled[ATF] := False;
end;

function TCandleEngine.Update(APrice: Double; AVolume: Int64; ATime: TDateTime): Integer;
var
  TF: TTimeframe;
begin
  Result := 0;
  for TF := Low(TTimeframe) to High(TTimeframe) do
  begin
    if FEnabled[TF] then
    begin
      if FBuilders[TF].Update(APrice, AVolume, ATime) then
        Result := Result or (1 shl Ord(TF));
    end;
  end;
end;

function TCandleEngine.GetCandle(ATF: TTimeframe): TCandle;
begin
  Result := FBuilders[ATF].Current;
end;

function TCandleEngine.GetLastComplete(ATF: TTimeframe): TCandle;
begin
  Result := FBuilders[ATF].LastComplete;
end;

function TCandleEngine.IsEnabled(ATF: TTimeframe): Boolean;
begin
  Result := FEnabled[ATF];
end;

end.
