{
  QuickStart.pas — Minimal example: connect, get LTP, check margin.
  Compile:
    fpc -Mdelphi QuickStart.pas       (FreePascal)
    dcc64 QuickStart.pas              (Delphi)
}
program QuickStart;

{$IFDEF FPC}{$mode Delphi}{$H+}{$ENDIF}

uses
  {$IFDEF FPC}SysUtils{$ELSE}System.SysUtils{$ENDIF},
  Apollo.Broker;

var
  B: TBroker;
begin
  B := TBroker.Create('upstox', 'YOUR_TOKEN_HERE', '');
  try
    B.Connect;
    WriteLn('Broker:      ', B.Name);
    WriteLn('Instruments: ', B.InstrumentCount);
    WriteLn('SBIN LTP:    ', B.LTP('SBIN', exNSE):0:2);
    WriteLn('Margin:      ', B.AvailableMargin:0:2);
    WriteLn('Funds:       ', B.FundsJson);
  finally
    B.Free;
  end;
end.
