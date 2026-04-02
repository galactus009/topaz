program TopazDashboard;

{$mode Delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Interfaces,
  Forms,
  MainForm,
  BotWizard,
  Topaz.Strategy.OptionScalper,
  Topaz.Strategy.MLStrategy,
  Topaz.Strategy.KalmanScalper,
  Topaz.Strategy.Momentum,
  Topaz.Strategy.DoubleRSI,
  Topaz.Strategy.MeanReversion,
  Topaz.Strategy.ORB,
  Topaz.Strategy.ExpiryGamma,
  Topaz.Strategy.CompositeScalper,
  Topaz.Strategy.GammaScalp,
  Topaz.Strategy.OptionsScalper;

begin
  RequireDerivedFormResource := True;
  Application.Scaled := True;
  Application.Initialize;
  Application.CreateForm(TfrmDashboard, frmDashboard);
  Application.Run;
end.
