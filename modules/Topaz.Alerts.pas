{
  Topaz.Alerts — Alerting / Notification System.

  Simple alerting that can notify via macOS system notification and
  log file.  Alert levels control the notification channel:

    alInfo     — log to file only
    alWarning  — log + macOS notification
    alCritical — log + macOS notification + audible alert

  Usage:
    var
      Alerts: TAlertManager;
    begin
      Alerts := TAlertManager.Create;
      try
        Alerts.Alert(alInfo, 'Strategy started');
        Alerts.Alert(alWarning, 'Drawdown exceeded 2%');
        Alerts.Alert(alCritical, 'Risk limit breached — all positions closed');
      finally
        Alerts.Free;
      end;
    end;
}
unit Topaz.Alerts;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Classes, Process;

type
  TAlertLevel = (alInfo, alWarning, alCritical);

  TAlertManager = class
  private
    FLogPath: AnsiString;
    FEnabled: Boolean;
    FSoundEnabled: Boolean;

    procedure WriteToFile(ALevel: TAlertLevel; const AMsg: AnsiString);
    procedure SystemNotify(const ATitle, AMsg: AnsiString);
    procedure PlaySound;
  public
    constructor Create(const ALogPath: AnsiString = '');
    procedure Alert(ALevel: TAlertLevel; const AMsg: AnsiString);
    property Enabled: Boolean read FEnabled write FEnabled;
    property SoundEnabled: Boolean read FSoundEnabled write FSoundEnabled;
  end;

implementation

const
  LEVEL_NAMES: array[TAlertLevel] of AnsiString = ('INFO', 'WARNING', 'CRITICAL');

{ ── TAlertManager ─────────────────────────────────────────────────────── }

constructor TAlertManager.Create(const ALogPath: AnsiString);
var
  Dir: AnsiString;
begin
  inherited Create;
  FEnabled := True;
  FSoundEnabled := True;

  if ALogPath = '' then
    FLogPath := ExtractFilePath(ParamStr(0)) + 'config' + PathDelim + 'alerts.log'
  else
    FLogPath := ALogPath;

  // Ensure directory exists
  Dir := ExtractFilePath(FLogPath);
  if (Dir <> '') and (not DirectoryExists(Dir)) then
    ForceDirectories(Dir);
end;

{ ── WriteToFile ── }

procedure TAlertManager.WriteToFile(ALevel: TAlertLevel;
  const AMsg: AnsiString);
var
  F: TextFile;
  Line: AnsiString;
begin
  Line := FormatDateTime('yyyy-mm-dd hh:nn:ss.zzz', Now) +
    ' [' + LEVEL_NAMES[ALevel] + '] ' + AMsg;
  try
    AssignFile(F, FLogPath);
    if FileExists(FLogPath) then
      Append(F)
    else
      Rewrite(F);
    WriteLn(F, Line);
    CloseFile(F);
  except
    // Swallow file errors — alerting must never crash the engine
  end;
end;

{ ── SystemNotify (macOS) ── }

procedure TAlertManager.SystemNotify(const ATitle, AMsg: AnsiString);
var
  Proc: TProcess;
  Script: AnsiString;
begin
  // Escape double quotes in message and title for AppleScript
  Script := 'display notification "' +
    StringReplace(AMsg, '"', '\"', [rfReplaceAll]) +
    '" with title "' +
    StringReplace(ATitle, '"', '\"', [rfReplaceAll]) + '"';
  try
    Proc := TProcess.Create(nil);
    try
      Proc.Executable := 'osascript';
      Proc.Parameters.Add('-e');
      Proc.Parameters.Add(Script);
      Proc.Options := Proc.Options + [poWaitOnExit, poNoConsole];
      Proc.Execute;
    finally
      Proc.Free;
    end;
  except
    // Swallow — notification failure must not crash the engine
  end;
end;

{ ── PlaySound (macOS) ── }

procedure TAlertManager.PlaySound;
var
  Proc: TProcess;
begin
  try
    Proc := TProcess.Create(nil);
    try
      Proc.Executable := 'afplay';
      Proc.Parameters.Add('/System/Library/Sounds/Glass.aiff');
      Proc.Options := Proc.Options + [poWaitOnExit, poNoConsole];
      Proc.Execute;
    finally
      Proc.Free;
    end;
  except
    // Swallow — sound failure must not crash the engine
  end;
end;

{ ── Alert ── }

procedure TAlertManager.Alert(ALevel: TAlertLevel; const AMsg: AnsiString);
begin
  if not FEnabled then Exit;

  // All levels log to file
  WriteToFile(ALevel, AMsg);

  case ALevel of
    alInfo:
      ; // file only — already done above

    alWarning:
      SystemNotify('Topaz Warning', AMsg);

    alCritical:
    begin
      SystemNotify('Topaz CRITICAL', AMsg);
      if FSoundEnabled then
        PlaySound;
    end;
  end;
end;

end.
