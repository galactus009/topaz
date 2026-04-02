program TopazDashboard;

{$IFDEF FPC}
  {$ERROR This is the Delphi FMX project. Use TopazDashboard.lpr for Lazarus/FPC.}
{$ENDIF}

uses
  System.StartUpCopy,
  FMX.Forms,
  MainForm in 'MainForm.pas' {frmDashboard},
  BotWizard in 'BotWizard.pas' {frmBotWizard},
  Apollo.Broker in 'modules\Apollo.Broker.pas',
  Topaz.RingBuffer in 'modules\Topaz.RingBuffer.pas',
  Topaz.EventTypes in 'modules\Topaz.EventTypes.pas',
  Topaz.Strategy in 'modules\Topaz.Strategy.pas',
  Topaz.Indicators in 'modules\Topaz.Indicators.pas',
  Topaz.BlackScholes in 'modules\Topaz.BlackScholes.pas',
  Topaz.Risk in 'modules\Topaz.Risk.pas',
  Topaz.Bracket in 'modules\Topaz.Bracket.pas',
  Topaz.State in 'modules\Topaz.State.pas',
  Topaz.Reconciler in 'modules\Topaz.Reconciler.pas',
  Topaz.Metrics in 'modules\Topaz.Metrics.pas',
  Topaz.Candles in 'modules\Topaz.Candles.pas',
  Topaz.Execution in 'modules\Topaz.Execution.pas',
  Topaz.Session in 'modules\Topaz.Session.pas',
  Topaz.Intents in 'modules\Topaz.Intents.pas',
  Topaz.Backtest in 'modules\Topaz.Backtest.pas',
  Topaz.ParamSweep in 'modules\Topaz.ParamSweep.pas',
  Topaz.ConfigLoader in 'modules\Topaz.ConfigLoader.pas',
  Topaz.Alerts in 'modules\Topaz.Alerts.pas',
  Topaz.IVAnalysis in 'modules\Topaz.IVAnalysis.pas',
  Topaz.PortfolioGreeks in 'modules\Topaz.PortfolioGreeks.pas',
  Topaz.OptionTemplates in 'modules\Topaz.OptionTemplates.pas',
  Topaz.Adjustment in 'modules\Topaz.Adjustment.pas',
  XGBoost.Wrapper in 'modules\XGBoost.Wrapper.pas',
  Topaz.Strategy.OptionScalper in 'Topaz.Strategy.OptionScalper.pas',
  Topaz.Strategy.MLStrategy in 'Topaz.Strategy.MLStrategy.pas',
  Topaz.Strategy.KalmanScalper in 'Topaz.Strategy.KalmanScalper.pas',
  Topaz.Strategy.Momentum in 'Topaz.Strategy.Momentum.pas',
  Topaz.Strategy.DoubleRSI in 'Topaz.Strategy.DoubleRSI.pas',
  Topaz.Strategy.MeanReversion in 'Topaz.Strategy.MeanReversion.pas',
  Topaz.Strategy.ORB in 'Topaz.Strategy.ORB.pas',
  Topaz.Strategy.ExpiryGamma in 'Topaz.Strategy.ExpiryGamma.pas',
  Topaz.Strategy.CompositeScalper in 'Topaz.Strategy.CompositeScalper.pas',
  Topaz.Strategy.GammaScalp in 'Topaz.Strategy.GammaScalp.pas',
  Topaz.Strategy.OptionsScalper in 'Topaz.Strategy.OptionsScalper.pas';

{$R *.res}

begin
  Application.Initialize;
  Application.CreateForm(TfrmDashboard, frmDashboard);
  Application.Run;
end.
