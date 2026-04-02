unit Topaz.Session;
{$mode Delphi}{$H+}
interface
uses SysUtils;

type
  TMarketSession = record
    MarketOpenHour, MarketOpenMin: Integer;
    MarketCloseHour, MarketCloseMin: Integer;
    ForceExitHour, ForceExitMin: Integer;
    EntryStartHour, EntryStartMin: Integer;
    EntryEndHour, EntryEndMin: Integer;
    procedure SetDefaults;
    function IsMarketOpen: Boolean;
    function IsEntryWindow: Boolean;
    function IsForceExitTime: Boolean;
    function MinutesToClose: Integer;
    function MinutesSinceOpen: Integer;
    function MarketStatus: AnsiString;
    function ClockDisplay: AnsiString;
  end;

var
  GSession: TMarketSession;

implementation

function TimeToMinutes(H, M: Integer): Integer;
begin
  Result := H * 60 + M;
end;

function NowMinutes: Integer;
var
  H, M, S, MS: Word;
begin
  DecodeTime(Now, H, M, S, MS);
  Result := TimeToMinutes(H, M);
end;

procedure TMarketSession.SetDefaults;
begin
  MarketOpenHour := 9;   MarketOpenMin := 15;
  MarketCloseHour := 15; MarketCloseMin := 30;
  ForceExitHour := 15;   ForceExitMin := 20;
  EntryStartHour := 9;   EntryStartMin := 20;
  EntryEndHour := 14;    EntryEndMin := 30;
end;

function TMarketSession.IsMarketOpen: Boolean;
var
  Cur, Open, Close: Integer;
begin
  Cur := NowMinutes;
  Open := TimeToMinutes(MarketOpenHour, MarketOpenMin);
  Close := TimeToMinutes(MarketCloseHour, MarketCloseMin);
  Result := (Cur >= Open) and (Cur < Close);
end;

function TMarketSession.IsEntryWindow: Boolean;
var
  Cur, Start, Finish: Integer;
begin
  Cur := NowMinutes;
  Start := TimeToMinutes(EntryStartHour, EntryStartMin);
  Finish := TimeToMinutes(EntryEndHour, EntryEndMin);
  Result := IsMarketOpen and (Cur >= Start) and (Cur < Finish);
end;

function TMarketSession.IsForceExitTime: Boolean;
var
  Cur, FE: Integer;
begin
  Cur := NowMinutes;
  FE := TimeToMinutes(ForceExitHour, ForceExitMin);
  Result := Cur >= FE;
end;

function TMarketSession.MinutesToClose: Integer;
var
  Cur, Close: Integer;
begin
  Cur := NowMinutes;
  Close := TimeToMinutes(MarketCloseHour, MarketCloseMin);
  Result := Close - Cur;
  if Result < 0 then Result := 0;
end;

function TMarketSession.MinutesSinceOpen: Integer;
var
  Cur, Open: Integer;
begin
  Cur := NowMinutes;
  Open := TimeToMinutes(MarketOpenHour, MarketOpenMin);
  Result := Cur - Open;
  if Result < 0 then Result := 0;
end;

function TMarketSession.MarketStatus: AnsiString;
var
  Cur, Open, Close: Integer;
begin
  Cur := NowMinutes;
  Open := TimeToMinutes(MarketOpenHour, MarketOpenMin);
  Close := TimeToMinutes(MarketCloseHour, MarketCloseMin);
  if Cur < Open then
    Result := 'Pre-Open'
  else if Cur >= Close then
    Result := 'Closed'
  else if (Close - Cur) <= 10 then
    Result := 'Closing'
  else
    Result := 'Open';
end;

function TMarketSession.ClockDisplay: AnsiString;
var
  H, M, S, MS: Word;
  Status: AnsiString;
  MTC: Integer;
begin
  DecodeTime(Now, H, M, S, MS);
  Status := MarketStatus;
  MTC := MinutesToClose;
  if (Status = 'Open') or (Status = 'Closing') then
    Result := AnsiString(Format('%02d:%02d:%02d | %s | %dm to close',
      [H, M, S, string(Status), MTC]))
  else
    Result := AnsiString(Format('%02d:%02d:%02d | %s',
      [H, M, S, string(Status)]));
end;

end.
