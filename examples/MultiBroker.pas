{
  MultiBroker.pas — Use multiple brokers simultaneously.
  Compile:
    fpc -Mdelphi MultiBroker.pas
}
program MultiBroker;

{$IFDEF FPC}{$mode Delphi}{$H+}{$ENDIF}

uses
  {$IFDEF FPC}SysUtils{$ELSE}System.SysUtils{$ENDIF},
  Apollo.Broker;

var
  Upstox, Fyers: TBroker;
  UpstoxLTP, FyersLTP: Double;
begin
  Upstox := TBroker.Create('upstox', 'UPSTOX_TOKEN', '');
  Fyers  := TBroker.Create('fyers',  'FYERS_TOKEN', 'FYERS_CLIENT_ID');
  try
    Upstox.Connect;
    Fyers.Connect;

    WriteLn('Upstox instruments: ', Upstox.InstrumentCount);
    WriteLn('Fyers instruments:  ', Fyers.InstrumentCount);

    // Compare LTP across brokers
    UpstoxLTP := Upstox.LTP('RELIANCE', exNSE);
    FyersLTP  := Fyers.LTP('RELIANCE', exNSE);
    WriteLn('RELIANCE LTP (Upstox): ', UpstoxLTP:0:2);
    WriteLn('RELIANCE LTP (Fyers):  ', FyersLTP:0:2);
    WriteLn('Diff: ', Abs(UpstoxLTP - FyersLTP):0:2);

    // Symbol mapping — same canonical name, different broker keys
    WriteLn('Upstox key: ', Upstox.ToBrokerKey('NSE:RELIANCE'));
    WriteLn('Fyers key:  ', Fyers.ToBrokerKey('NSE:RELIANCE'));
  finally
    Fyers.Free;
    Upstox.Free;
  end;
end.
