program TopazDashboard;

{$mode Delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Interfaces,
  Forms,
  MainForm,
  Topaz.Strategy.OptionScalper,
  Topaz.Strategy.MLStrategy,
  Topaz.Strategy.KalmanScalper;

begin
  RequireDerivedFormResource := True;
  Application.Scaled := True;
  Application.Initialize;
  Application.CreateForm(TfrmDashboard, frmDashboard);
  Application.Run;
end.
