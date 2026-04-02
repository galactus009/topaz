{
  Topaz.ConfigLoader — JSON configuration loader for strategies.

  Loads / saves strategy configurations from config/strategies.json.
  Each entry specifies the strategy class name, underlying instrument,
  exchange, lot size, warmup period, auto-start flag, and arbitrary
  key-value parameters.

  JSON format (config/strategies.json):
    [
      {
        "strategy": "Momentum",
        "underlying": "NIFTY 50",
        "exchange": 0,
        "lots": 1,
        "warmup": 50,
        "auto_start": false,
        "params": {
          "fast_period": "9",
          "atr_multiplier": "2.0"
        }
      }
    ]

  Usage:
    var
      Configs: TArray<TStrategyConfig>;
    begin
      Configs := TConfigLoader.LoadStrategies;
      for C in Configs do
        WriteLn(C.StrategyName, ' on ', C.Underlying);
    end;
}
unit Topaz.ConfigLoader;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Classes, fpjson, jsonparser, Topaz.Strategy;

type
  { ── Single parameter key-value pair ── }
  TConfigParam = record
    Name: AnsiString;
    Value: AnsiString;
  end;

  { ── Strategy configuration record ── }
  TStrategyConfig = record
    StrategyName: AnsiString;
    Underlying: AnsiString;
    Exchange: Integer;
    Lots: Integer;
    WarmupTicks: Integer;
    AutoStart: Boolean;
    Params: array of TConfigParam;
  end;

  { ── Config loader (all class methods — no instance needed) ── }
  TConfigLoader = class
  public
    class function LoadStrategies(const APath: AnsiString = ''): TArray<TStrategyConfig>;
    class procedure SaveStrategies(const AConfigs: TArray<TStrategyConfig>;
      const APath: AnsiString = '');
    class function DefaultPath: AnsiString;
  end;

implementation

{ ── TConfigLoader ─────────────────────────────────────────────────────── }

class function TConfigLoader.DefaultPath: AnsiString;
begin
  Result := ExtractFilePath(ParamStr(0)) + 'config' + PathDelim + 'strategies.json';
end;

{ ── LoadStrategies ── }

class function TConfigLoader.LoadStrategies(const APath: AnsiString): TArray<TStrategyConfig>;
var
  FilePath: AnsiString;
  FS: TFileStream;
  Src: AnsiString;
  Root: TJSONData;
  Arr: TJSONArray;
  Obj, ParamsObj: TJSONObject;
  I, J, PCount: Integer;
  Cfg: TStrategyConfig;
begin
  Result := nil;

  if APath = '' then
    FilePath := DefaultPath
  else
    FilePath := APath;

  if not FileExists(FilePath) then
    Exit;

  FS := TFileStream.Create(FilePath, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Src, FS.Size);
    if FS.Size > 0 then
      FS.ReadBuffer(Src[1], FS.Size);
  finally
    FS.Free;
  end;

  if Src = '' then Exit;

  Root := GetJSON(Src);
  try
    if not (Root is TJSONArray) then
      raise Exception.Create('TConfigLoader: root element must be a JSON array');

    Arr := TJSONArray(Root);
    SetLength(Result, Arr.Count);

    for I := 0 to Arr.Count - 1 do
    begin
      if not (Arr.Items[I] is TJSONObject) then
        Continue;

      Obj := TJSONObject(Arr.Items[I]);

      Cfg.StrategyName := Obj.Get('strategy', '');
      Cfg.Underlying := Obj.Get('underlying', '');
      Cfg.Exchange := Obj.Get('exchange', 0);
      Cfg.Lots := Obj.Get('lots', 1);
      Cfg.WarmupTicks := Obj.Get('warmup', 50);
      Cfg.AutoStart := Obj.Get('auto_start', False);

      // Parse params object
      SetLength(Cfg.Params, 0);
      if Obj.Find('params') <> nil then
      begin
        if Obj.Find('params') is TJSONObject then
        begin
          ParamsObj := TJSONObject(Obj.Find('params'));
          PCount := ParamsObj.Count;
          SetLength(Cfg.Params, PCount);
          for J := 0 to PCount - 1 do
          begin
            Cfg.Params[J].Name := ParamsObj.Names[J];
            Cfg.Params[J].Value := ParamsObj.Items[J].AsString;
          end;
        end;
      end;

      Result[I] := Cfg;
    end;
  finally
    Root.Free;
  end;
end;

{ ── SaveStrategies ── }

class procedure TConfigLoader.SaveStrategies(
  const AConfigs: TArray<TStrategyConfig>; const APath: AnsiString);
var
  FilePath: AnsiString;
  Arr: TJSONArray;
  Obj, ParamsObj: TJSONObject;
  I, J: Integer;
  Dir: AnsiString;
  FS: TFileStream;
  Src: AnsiString;
begin
  if APath = '' then
    FilePath := DefaultPath
  else
    FilePath := APath;

  // Ensure directory exists
  Dir := ExtractFilePath(FilePath);
  if (Dir <> '') and (not DirectoryExists(Dir)) then
    ForceDirectories(Dir);

  Arr := TJSONArray.Create;
  try
    for I := 0 to High(AConfigs) do
    begin
      Obj := TJSONObject.Create;
      Obj.Add('strategy', AConfigs[I].StrategyName);
      Obj.Add('underlying', AConfigs[I].Underlying);
      Obj.Add('exchange', AConfigs[I].Exchange);
      Obj.Add('lots', AConfigs[I].Lots);
      Obj.Add('warmup', AConfigs[I].WarmupTicks);
      Obj.Add('auto_start', AConfigs[I].AutoStart);

      ParamsObj := TJSONObject.Create;
      for J := 0 to High(AConfigs[I].Params) do
        ParamsObj.Add(AConfigs[I].Params[J].Name, AConfigs[I].Params[J].Value);
      Obj.Add('params', ParamsObj);

      Arr.Add(Obj);
    end;

    Src := Arr.FormatJSON;
  finally
    Arr.Free;
  end;

  FS := TFileStream.Create(FilePath, fmCreate);
  try
    if Length(Src) > 0 then
      FS.WriteBuffer(Src[1], Length(Src));
  finally
    FS.Free;
  end;
end;

end.
