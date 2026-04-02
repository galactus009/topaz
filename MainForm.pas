{
  MainForm — Topaz Trading Dashboard (designer-compatible).

  Modern side-nav application. Components are defined in MainForm.lfm
  and can be edited in the Lazarus visual designer.

  Architecture:
    Rust callbacks → lock-free ring buffers → GUI timer (50ms)
    Rust callbacks → lock-free ring buffers → strategy threads
    Positions/funds → polling timer (2s)
}
unit MainForm;

{$mode Delphi}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs,
  StdCtrls, ExtCtrls, Grids, Spin, ComCtrls, Menus, Generics.Collections,
  LCLType,
  Apollo.Broker, Topaz.EventTypes, Topaz.Strategy, Topaz.Risk,
  Topaz.State, Topaz.Reconciler, Topaz.Session, BotWizard,
  Topaz.IVAnalysis, Topaz.BlackScholes, Topaz.Alerts,
  Topaz.PortfolioGreeks;

type
  TEngineState = (esIdle, esStarting, esConnected, esStopping, esError);

  TRunningBot = record
    Name: AnsiString;
    StrategyName: AnsiString;
    Underlying: AnsiString;
    Strategy: TStrategy;
    Thread: TStrategyThread;
    SlotIndex: Integer;
    Running: Boolean;
  end;

  { TfrmDashboard }
  TfrmDashboard = class(TForm)
    { ── Side navigation ── }
    pnlSideNav: TPanel;
    btnNavDashboard: TButton;
    btnNavOrders: TButton;
    btnNavStrategies: TButton;
    btnNavSearch: TButton;
    btnNavSettings: TButton;
    btnNavLog: TButton;
    btnNavOptions: TButton;
    btnNavHealth: TButton;
    lblAppTitle: TLabel;
    lblNavBotCount: TLabel;
    lblNavPositions: TLabel;

    { ── Top bar ── }
    pnlTopBar: TPanel;
    btnStartEngine: TButton;
    btnStopEngine: TButton;
    btnRestartEngine: TButton;
    shpStatus: TShape;
    lblStatus: TLabel;
    lblBrokerInfo: TLabel;
    lblDailyPnLBar: TLabel;
    lblMarketClock: TLabel;
    btnFlattenAll: TButton;

    { ── Page container ── }
    nbPages: TPageControl;
    tsDashboard: TTabSheet;
    tsOrders: TTabSheet;
    tsStrategies: TTabSheet;
    tsSearch: TTabSheet;
    tsSettings: TTabSheet;
    tsLog: TTabSheet;
    tsOptionChain: TTabSheet;
    tsHealth: TTabSheet;

    { ── Page: Dashboard ── }
    pnlDashWatchToolbar: TPanel;
    edtAddSymbol: TEdit;
    cbxWatchExchange: TComboBox;
    btnAddSymbol: TButton;
    btnRemoveSymbol: TButton;
    gridWatchlist: TStringGrid;
    pnlDashBottom: TPanel;
    gridPositions: TStringGrid;
    pnlDashFunds: TPanel;
    lblFundsAvail: TLabel;
    lblFundsUsed: TLabel;
    lblFundsBalance: TLabel;
    lblNetPosition: TLabel;

    { ── Page: Orders ── }
    grpOrderEntry: TGroupBox;
    edtOrdSymbol: TEdit;
    cbxOrdExchange: TComboBox;
    cbxOrdSide: TComboBox;
    cbxOrdType: TComboBox;
    cbxOrdProduct: TComboBox;
    edtOrdQty: TSpinEdit;
    edtOrdPrice: TEdit;
    edtOrdTrigger: TEdit;
    btnPlaceOrder: TButton;
    lblOrdSymbol: TLabel;
    lblOrdExchange: TLabel;
    lblOrdSide: TLabel;
    lblOrdType: TLabel;
    lblOrdProduct: TLabel;
    lblOrdQty: TLabel;
    lblOrdPrice: TLabel;
    lblOrdTrigger: TLabel;
    gridOrders: TStringGrid;

    { ── Page: Strategies ── }
    pnlStratToolbar: TPanel;
    cbxStratName: TComboBox;
    edtStratUnderlying: TEdit;
    edtStratLots: TSpinEdit;
    btnStratStart: TButton;
    btnStratStop: TButton;
    gridStrategies: TStringGrid;

    { ── Page: Search ── }
    pnlSearchToolbar: TPanel;
    edtSearch: TEdit;
    cbxSearchExchange: TComboBox;
    btnSearch: TButton;
    gridSearch: TStringGrid;

    { ── Page: Settings ── }
    scrollSettings: TScrollBox;
    grpBroker: TGroupBox;
    cbxBroker: TComboBox;
    edtToken: TEdit;
    edtApiKey: TEdit;
    chkAutoConnect: TCheckBox;
    btnSaveSettings: TButton;
    lblSettingsStatus: TLabel;
    lblBrokerLabel: TLabel;
    lblTokenLabel: TLabel;
    lblApiKeyLabel: TLabel;
    grpRisk: TGroupBox;
    edtDailyLossLimit: TEdit;
    edtMaxExposure: TEdit;
    edtStrategyLossLimit: TEdit;
    edtMaxSymbolExposure: TEdit;
    edtMaxOrdersPerSec: TEdit;
    edtMaxOpenOrders: TEdit;
    chkRiskEnabled: TCheckBox;
    lblDailyLossLimit: TLabel;
    lblMaxExposure: TLabel;
    lblStrategyLossLimit: TLabel;
    lblMaxSymbolExp: TLabel;
    lblMaxOrdersPerSec: TLabel;
    lblMaxOpenOrders: TLabel;
    grpTimers: TGroupBox;
    edtDrainInterval: TEdit;
    edtPollInterval: TEdit;
    edtStateSaveInterval: TEdit;
    edtDefaultWarmup: TEdit;
    lblDrainInterval: TLabel;
    lblPollInterval: TLabel;
    lblStateSaveInterval: TLabel;
    lblDefaultWarmup: TLabel;
    grpTradingHours: TGroupBox;
    lblMarketOpen: TLabel;
    edtMarketOpen: TEdit;
    lblMarketClose: TLabel;
    edtMarketClose: TEdit;
    lblForceExit: TLabel;
    edtForceExit: TEdit;
    lblEntryStart: TLabel;
    edtEntryStart: TEdit;
    lblEntryEnd: TLabel;
    edtEntryEnd: TEdit;
    btnLaunchWizard: TButton;

    { ── Page: Log ── }
    memoLog: TMemo;
    pnlLogToolbar: TPanel;
    btnClearLog: TButton;
    lblLogCount: TLabel;
    pnlLogFilter: TPanel;
    chkLogInfo: TCheckBox;
    chkLogWarn: TCheckBox;
    chkLogError: TCheckBox;
    chkLogRisk: TCheckBox;
    chkLogOrder: TCheckBox;
    chkLogFill: TCheckBox;
    chkLogSystem: TCheckBox;

    { ── Page: Options Chain ── }
    pnlChainToolbar: TPanel;
    lblChainUnderlying: TLabel;
    edtChainUnderlying: TEdit;
    lblChainExpiry: TLabel;
    cbxChainExpiry: TComboBox;
    btnLoadChain: TButton;
    lblIVRank: TLabel;
    lblMaxPain: TLabel;
    gridOptionChain: TStringGrid;

    { ── Page: Health ── }
    pnlHealthTop: TPanel;
    shpRiskLight: TShape;
    lblRiskStatus: TLabel;
    lblOpenOrders: TLabel;
    lblDailyPnL: TLabel;
    lblExposure: TLabel;
    lblNetDelta: TLabel;
    lblNetGamma: TLabel;
    lblNetTheta: TLabel;
    lblNetVega: TLabel;
    pnlPnLBreakdown: TPanel;
    lblRealizedPnL: TLabel;
    lblUnrealizedPnL: TLabel;
    lblTotalPnL: TLabel;
    lblTotalTrades: TLabel;
    gridHealth: TStringGrid;

    { ── Status bar ── }
    pnlStatusBar: TPanel;
    shpStatusIcon: TShape;
    lblStatusMsg: TLabel;

    { ── Timers ── }
    tmrDrain: TTimer;
    tmrPoll: TTimer;

    { ── Context menus ── }
    pmWatchlist: TPopupMenu;
    miWatchUnsubscribe: TMenuItem;
    miWatchPlaceOrder: TMenuItem;
    pmStrategies: TPopupMenu;
    miStratStop: TMenuItem;
    miStratRemove: TMenuItem;

    { ── Event handlers ── }
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure FormCloseQuery(Sender: TObject; var CanClose: Boolean);
    procedure FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure btnNavDashboardClick(Sender: TObject);
    procedure btnNavOrdersClick(Sender: TObject);
    procedure btnNavStrategiesClick(Sender: TObject);
    procedure btnNavSearchClick(Sender: TObject);
    procedure btnNavSettingsClick(Sender: TObject);
    procedure btnNavLogClick(Sender: TObject);
    procedure btnNavOptionsClick(Sender: TObject);
    procedure btnNavHealthClick(Sender: TObject);
    procedure btnLoadChainClick(Sender: TObject);
    procedure btnStartEngineClick(Sender: TObject);
    procedure btnStopEngineClick(Sender: TObject);
    procedure btnRestartEngineClick(Sender: TObject);
    procedure btnAddSymbolClick(Sender: TObject);
    procedure btnRemoveSymbolClick(Sender: TObject);
    procedure btnPlaceOrderClick(Sender: TObject);
    procedure btnSearchClick(Sender: TObject);
    procedure btnSaveSettingsClick(Sender: TObject);
    procedure btnLaunchWizardClick(Sender: TObject);
    procedure btnClearLogClick(Sender: TObject);
    procedure btnFlattenAllClick(Sender: TObject);
    procedure btnStratStartClick(Sender: TObject);
    procedure btnStratStopClick(Sender: TObject);
    procedure gridWatchlistDblClick(Sender: TObject);
    procedure miWatchUnsubscribeClick(Sender: TObject);
    procedure miWatchPlaceOrderClick(Sender: TObject);
    procedure miStratStopClick(Sender: TObject);
    procedure miStratRemoveClick(Sender: TObject);
    procedure tmrDrainTimer(Sender: TObject);
    procedure tmrPollTimer(Sender: TObject);
  private
    FBroker: TBroker;
    FEventBus: TEventBus;
    FEngineState: TEngineState;
    FAlerts: TAlertManager;
    FPortfolioGreeks: TPortfolioGreeks;
    FSymbolRowMap: TDictionary<Integer, Integer>;
    FPrevLTP: array of Double;
    FBots: TList<TRunningBot>;
    FRisk: TRiskManager;
    FState: TStateManager;
    FStatusLastUpdate: TDateTime;

    procedure ShowPage(AIndex: Integer);
    procedure HighlightNav(ABtn: TButton);
    procedure SetEngineState(AState: TEngineState);
    procedure StartEngine;
    procedure StopEngine;
    procedure UpdateWatchlistRow(const ATick: TTickEvent);
    procedure ProcessOrderEvent(const AEvt: TOrderEvent);
    procedure ProcessStatusEvent(const AEvt: TStatusEvent);
    procedure Log(const AMsg: AnsiString);
    procedure LoadSettings;
    procedure SaveSettings;
    function ExchangeFromIndex(AIndex: Integer): TExchange;
    procedure InitGridHeaders(AGrid: TStringGrid;
      const ACols: array of string; const AWidths: array of Integer);
    procedure PopulateStrategyCombo;
    procedure RefreshHealth;
    procedure SaveBots;
    procedure LoadBots;
  end;

var
  frmDashboard: TfrmDashboard;

implementation

{$R *.lfm}

uses
  fpjson, jsonparser, StrUtils, DateUtils, Math;

const
  PAGE_DASHBOARD  = 0;
  PAGE_ORDERS     = 1;
  PAGE_STRATEGIES = 2;
  PAGE_SEARCH     = 3;
  PAGE_SETTINGS   = 4;
  PAGE_LOG        = 5;
  PAGE_OPTIONS    = 6;
  PAGE_HEALTH     = 7;

{ ═══════════════════════════════════════════════════════════════════ }
{  Form lifecycle                                                     }
{ ═══════════════════════════════════════════════════════════════════ }

procedure TfrmDashboard.FormCreate(Sender: TObject);
begin
  FEngineState := esIdle;
  FSymbolRowMap := TDictionary<Integer, Integer>.Create;
  FBots := TList<TRunningBot>.Create;
  FRisk := TRiskManager.Create;
  FAlerts := TAlertManager.Create;
  FPortfolioGreeks := TPortfolioGreeks.Create;
  FState := TStateManager.Create;
  FState.Load;
  GSession.SetDefaults;

  // Init grid headers
  InitGridHeaders(gridWatchlist,
    ['Symbol', 'LTP', 'Change', 'Chg%', 'Bid', 'Ask', 'Volume', 'OI'],
    [110, 80, 70, 60, 80, 80, 90, 80]);
  InitGridHeaders(gridPositions,
    ['Symbol', 'Exchange', 'Qty', 'Avg Price', 'LTP', 'P&L'],
    [110, 70, 60, 90, 80, 90]);
  InitGridHeaders(gridOrders,
    ['OrderId', 'Symbol', 'Side', 'Type', 'Qty', 'Price', 'Status'],
    [120, 100, 50, 60, 50, 80, 80]);
  InitGridHeaders(gridStrategies,
    ['Name', 'Strategy', 'Underlying', 'Lots', 'Status', 'P&L', 'Ticks'],
    [100, 100, 100, 50, 70, 80, 70]);
  InitGridHeaders(gridSearch,
    ['Symbol', 'Name', 'Exchange', 'Type', 'Lot', 'Tick', 'Key'],
    [110, 150, 70, 60, 50, 50, 150]);
  InitGridHeaders(gridOptionChain,
    ['CE OI', 'CE Vol', 'CE LTP', 'CE IV', 'CE Delta', 'CE Gamma', 'Strike',
     'PE Gamma', 'PE Delta', 'PE IV', 'PE LTP', 'PE Vol', 'PE OI'],
    [70, 60, 70, 60, 65, 65, 80, 65, 65, 60, 70, 60, 70]);
  InitGridHeaders(gridHealth,
    ['Strategy', 'Status', 'Trades', 'Win%', 'P&L', 'Max DD', 'Sharpe', 'Ticks'],
    [100, 70, 60, 60, 80, 80, 70, 70]);

  FStatusLastUpdate := 0;

  // Set defaults for settings fields before loading
  edtDailyLossLimit.Text := '50000';
  edtMaxExposure.Text := '500000';
  edtStrategyLossLimit.Text := '10000';
  edtMaxSymbolExposure.Text := '100000';
  edtMaxOrdersPerSec.Text := '5';
  edtMaxOpenOrders.Text := '20';
  edtDrainInterval.Text := '50';
  edtPollInterval.Text := '2000';
  edtStateSaveInterval.Text := '30';
  edtDefaultWarmup.Text := '50';

  edtMarketOpen.Text := '09:15';
  edtMarketClose.Text := '15:30';
  edtForceExit.Text := '15:20';
  edtEntryStart.Text := '09:20';
  edtEntryEnd.Text := '14:30';

  PopulateStrategyCombo;
  LoadBots;
  LoadSettings;
  SetEngineState(esIdle);
  ShowPage(PAGE_DASHBOARD);
  HighlightNav(btnNavDashboard);
end;

procedure TfrmDashboard.FormDestroy(Sender: TObject);
begin
  tmrDrain.Enabled := False;
  tmrPoll.Enabled := False;
  FState.Save;
  SaveBots;
  StopEngine;
  SaveSettings;
  FAlerts.Free;
  FPortfolioGreeks.Free;
  FRisk.Free;
  FState.Free;
  FSymbolRowMap.Free;
  FBots.Free;
end;

procedure TfrmDashboard.FormCloseQuery(Sender: TObject; var CanClose: Boolean);
begin
  if FEngineState = esConnected then
  begin
    if MessageDlg('Disconnect and exit?', mtConfirmation, [mbYes, mbNo], 0) = mrYes then
    begin
      StopEngine;
      CanClose := True;
    end
    else
      CanClose := False;
  end
  else
    CanClose := True;
end;

procedure TfrmDashboard.FormKeyDown(Sender: TObject; var Key: Word;
  Shift: TShiftState);
begin
  case Key of
    VK_F5: if btnStartEngine.Enabled then btnStartEngineClick(nil);
    VK_F6: if btnStopEngine.Enabled then btnStopEngineClick(nil);
    VK_ESCAPE: if FEngineState = esConnected then btnFlattenAllClick(nil);
    VK_F1: begin ShowPage(PAGE_DASHBOARD); HighlightNav(btnNavDashboard); end;
    VK_F2: begin ShowPage(PAGE_ORDERS); HighlightNav(btnNavOrders); end;
    VK_F3: begin ShowPage(PAGE_STRATEGIES); HighlightNav(btnNavStrategies); end;
    VK_F4: begin ShowPage(PAGE_SEARCH); HighlightNav(btnNavSearch); end;
    VK_F7: begin ShowPage(PAGE_SETTINGS); HighlightNav(btnNavSettings); end;
    VK_F8: begin ShowPage(PAGE_LOG); HighlightNav(btnNavLog); end;
    VK_F9: begin ShowPage(PAGE_OPTIONS); HighlightNav(btnNavOptions); end;
    VK_F10: begin ShowPage(PAGE_HEALTH); HighlightNav(btnNavHealth); end;
  end;
end;

{ ═══════════════════════════════════════════════════════════════════ }
{  Navigation                                                         }
{ ═══════════════════════════════════════════════════════════════════ }

procedure TfrmDashboard.ShowPage(AIndex: Integer);
begin
  nbPages.ActivePageIndex := AIndex;
end;

procedure TfrmDashboard.HighlightNav(ABtn: TButton);
const
  CLR_NAV_BG  = $00302020;
  CLR_NAV_SEL = $00604030;
var
  I: Integer;
begin
  for I := 0 to pnlSideNav.ControlCount - 1 do
    if pnlSideNav.Controls[I] is TButton then
      TButton(pnlSideNav.Controls[I]).Color := CLR_NAV_BG;
  ABtn.Color := CLR_NAV_SEL;
end;

procedure TfrmDashboard.btnNavDashboardClick(Sender: TObject);
begin ShowPage(PAGE_DASHBOARD); HighlightNav(btnNavDashboard); end;

procedure TfrmDashboard.btnNavOrdersClick(Sender: TObject);
begin ShowPage(PAGE_ORDERS); HighlightNav(btnNavOrders); end;

procedure TfrmDashboard.btnNavStrategiesClick(Sender: TObject);
begin ShowPage(PAGE_STRATEGIES); HighlightNav(btnNavStrategies); end;

procedure TfrmDashboard.btnNavSearchClick(Sender: TObject);
begin ShowPage(PAGE_SEARCH); HighlightNav(btnNavSearch); end;

procedure TfrmDashboard.btnNavSettingsClick(Sender: TObject);
begin ShowPage(PAGE_SETTINGS); HighlightNav(btnNavSettings); end;

procedure TfrmDashboard.btnNavLogClick(Sender: TObject);
begin ShowPage(PAGE_LOG); HighlightNav(btnNavLog); end;

procedure TfrmDashboard.btnNavOptionsClick(Sender: TObject);
begin ShowPage(PAGE_OPTIONS); HighlightNav(btnNavOptions); end;

procedure TfrmDashboard.btnNavHealthClick(Sender: TObject);
begin ShowPage(PAGE_HEALTH); HighlightNav(btnNavHealth); end;

{ ═══════════════════════════════════════════════════════════════════ }
{  Engine control                                                     }
{ ═══════════════════════════════════════════════════════════════════ }

procedure TfrmDashboard.SetEngineState(AState: TEngineState);
begin
  FEngineState := AState;
  case AState of
    esIdle: begin
      shpStatus.Brush.Color := clRed; lblStatus.Caption := 'Disconnected';
      btnStartEngine.Enabled := True; btnStopEngine.Enabled := False;
      btnRestartEngine.Enabled := False;
    end;
    esStarting: begin
      shpStatus.Brush.Color := clYellow; lblStatus.Caption := 'Connecting...';
      btnStartEngine.Enabled := False; btnStopEngine.Enabled := False;
      btnRestartEngine.Enabled := False;
    end;
    esConnected: begin
      shpStatus.Brush.Color := clLime; lblStatus.Caption := 'Connected';
      btnStartEngine.Enabled := False; btnStopEngine.Enabled := True;
      btnRestartEngine.Enabled := True;
    end;
    esStopping: begin
      shpStatus.Brush.Color := clYellow; lblStatus.Caption := 'Stopping...';
      btnStartEngine.Enabled := False; btnStopEngine.Enabled := False;
      btnRestartEngine.Enabled := False;
    end;
    esError: begin
      shpStatus.Brush.Color := clRed; lblStatus.Caption := 'Error';
      btnStartEngine.Enabled := True; btnStopEngine.Enabled := False;
      btnRestartEngine.Enabled := True;
    end;
  end;
end;

procedure TfrmDashboard.btnStartEngineClick(Sender: TObject);
begin StartEngine; end;

procedure TfrmDashboard.btnStopEngineClick(Sender: TObject);
begin
  if FEngineState <> esConnected then Exit;
  if MessageDlg('Stop engine? All bots will be terminated.',
    mtConfirmation, [mbYes, mbNo], 0) = mrYes then
    StopEngine;
end;

procedure TfrmDashboard.btnRestartEngineClick(Sender: TObject);
begin StopEngine; StartEngine; end;

procedure TfrmDashboard.StartEngine;
var
  BrokerNames: array[0..4] of AnsiString;
  BN, TK, AK: AnsiString;
begin
  BrokerNames[0] := 'upstox'; BrokerNames[1] := 'kite';
  BrokerNames[2] := 'fyers'; BrokerNames[3] := 'indmoney';
  BrokerNames[4] := 'dhan';

  BN := BrokerNames[cbxBroker.ItemIndex];
  TK := AnsiString(edtToken.Text);
  AK := AnsiString(edtApiKey.Text);

  if TK = '' then begin Log('ERROR: Access token required'); Exit; end;

  SetEngineState(esStarting);
  Application.ProcessMessages;

  try
    FBroker := TBroker.Create(BN, TK, AK);
    if not FBroker.Connect then
    begin
      Log('ERROR: ' + FBroker.LastError);
      FreeAndNil(FBroker);
      SetEngineState(esError);
      Exit;
    end;

    FEventBus := TEventBus.Create;
    FBroker.SetCallbacks(@CbTick, @CbDepth, @CbCandle, @CbOrder,
      @CbConnect, @CbDisconnect, Pointer(FEventBus));

    if not FBroker.StreamStart then
    begin
      Log('ERROR: StreamStart failed');
      FreeAndNil(FEventBus); FBroker.Disconnect; FreeAndNil(FBroker);
      SetEngineState(esError);
      Exit;
    end;

    FBroker.SubscribeOrders;
    tmrDrain.Enabled := True;
    tmrPoll.Enabled := True;

    lblBrokerInfo.Caption := Format('%s | %d instruments',
      [string(FBroker.Name), FBroker.InstrumentCount]);
    Log(Format('Engine started: %s (%d instruments)',
      [string(FBroker.Name), FBroker.InstrumentCount]));

    // Reconcile positions with broker
    try
      with TReconciler.Create(FBroker, FState) do
      try
        Reconcile;
        if HasDrift then
          Log('RECONCILE: ' + AnsiString(DriftSummary))
        else
          Log('RECONCILE: Positions match broker');
      finally
        Free;
      end;
    except
      on E: Exception do Log('RECONCILE: ' + AnsiString(E.Message));
    end;

    FRisk.ResetDaily;
    SetEngineState(esConnected);
  except
    on E: Exception do
    begin
      Log('ERROR: ' + E.Message);
      FreeAndNil(FEventBus); FreeAndNil(FBroker);
      SetEngineState(esError);
    end;
  end;
end;

procedure TfrmDashboard.StopEngine;
var
  I: Integer;
  Bot: TRunningBot;
begin
  if FEngineState = esIdle then Exit;
  SetEngineState(esStopping);
  Application.ProcessMessages;

  tmrDrain.Enabled := False;
  tmrPoll.Enabled := False;

  for I := FBots.Count - 1 downto 0 do
  begin
    Bot := FBots[I];
    if Bot.Running and (Bot.Thread <> nil) then
    begin
      Bot.Thread.Terminate;
      Bot.Thread.WaitFor;
      FreeAndNil(Bot.Thread);
      FreeAndNil(Bot.Strategy);
      if (FEventBus <> nil) and (Bot.SlotIndex >= 0) then
        FEventBus.RemoveStrategySlot(Bot.SlotIndex);
      Bot.Running := False;
      FBots[I] := Bot;
    end;
  end;

  if FBroker <> nil then
  begin
    FBroker.StreamStop;
    FBroker.Disconnect;
    FreeAndNil(FBroker);
  end;
  FreeAndNil(FEventBus);

  lblBrokerInfo.Caption := '';
  Log('Engine stopped');
  SetEngineState(esIdle);
end;

{ ═══════════════════════════════════════════════════════════════════ }
{  Timer: Drain (50ms)                                                }
{ ═══════════════════════════════════════════════════════════════════ }

procedure TfrmDashboard.tmrDrainTimer(Sender: TObject);
var
  Tick: TTickEvent;
  Order: TOrderEvent;
  Status: TStatusEvent;
  LogEvt: TLogEvent;
  Prefix: string;
  N: Integer;
begin
  if FEventBus = nil then Exit;

  N := 0;
  gridWatchlist.BeginUpdate;
  try
    while (N < 256) and FEventBus.GuiTicks.TryRead(Tick) do
    begin
      UpdateWatchlistRow(Tick);
      Inc(N);
    end;
  finally
    gridWatchlist.EndUpdate;
  end;

  while FEventBus.Orders.TryRead(Order) do
    ProcessOrderEvent(Order);

  while FEventBus.Status.TryRead(Status) do
    ProcessStatusEvent(Status);

  // Drain structured log events from strategies
  while FEventBus.Logs.TryRead(LogEvt) do
  begin
    // Check log filter checkboxes
    case LogEvt.Level of
      llInfo:   if not chkLogInfo.Checked then Continue;
      llWarn:   if not chkLogWarn.Checked then Continue;
      llError:  if not chkLogError.Checked then Continue;
      llRisk:   if not chkLogRisk.Checked then Continue;
      llOrder:  if not chkLogOrder.Checked then Continue;
      llFill:   if not chkLogFill.Checked then Continue;
      llSystem: if not chkLogSystem.Checked then Continue;
    end;

    case LogEvt.Level of
      llInfo:   Prefix := 'INFO';
      llWarn:   Prefix := 'WARN';
      llError:  Prefix := 'ERROR';
      llRisk:   Prefix := 'RISK';
      llOrder:  Prefix := 'ORDER';
      llFill:   Prefix := 'FILL';
      llSystem: Prefix := 'SYS';
    end;
    Log(AnsiString(Format('[%s] %s: %s',
      [Prefix, PAnsiChar(@LogEvt.Source[0]), PAnsiChar(@LogEvt.Msg[0])])));

    // Update status bar for order/risk/fill events
    case LogEvt.Level of
      llOrder: begin
        lblStatusMsg.Caption := Format('[ORDER] %s: %s',
          [PAnsiChar(@LogEvt.Source[0]), PAnsiChar(@LogEvt.Msg[0])]);
        shpStatusIcon.Brush.Color := clLime;
        FStatusLastUpdate := Now;
      end;
      llRisk: begin
        lblStatusMsg.Caption := Format('[RISK] %s: %s',
          [PAnsiChar(@LogEvt.Source[0]), PAnsiChar(@LogEvt.Msg[0])]);
        shpStatusIcon.Brush.Color := clRed;
        FStatusLastUpdate := Now;
      end;
      llFill: begin
        lblStatusMsg.Caption := Format('[FILL] %s: %s',
          [PAnsiChar(@LogEvt.Source[0]), PAnsiChar(@LogEvt.Msg[0])]);
        shpStatusIcon.Brush.Color := clBlue;
        FStatusLastUpdate := Now;
      end;
    end;

    // Fire alerts for critical events
    case LogEvt.Level of
      llRisk: FAlerts.Alert(alWarning, AnsiString(PAnsiChar(@LogEvt.Msg[0])));
      llError: FAlerts.Alert(alWarning, AnsiString(PAnsiChar(@LogEvt.Msg[0])));
    end;
  end;

  // Auto-clear status bar after 5 seconds
  if (FStatusLastUpdate > 0) and ((Now - FStatusLastUpdate) > (5 / 86400)) then
  begin
    lblStatusMsg.Caption := '';
    shpStatusIcon.Brush.Color := clGray;
    FStatusLastUpdate := 0;
  end;

end;

procedure TfrmDashboard.UpdateWatchlistRow(const ATick: TTickEvent);
var
  Row: Integer;
  Prev, Change, ChangePct: Double;
begin
  if not FSymbolRowMap.TryGetValue(ATick.SymbolId, Row) then Exit;
  if (Row < 1) or (Row >= gridWatchlist.RowCount) then Exit;

  Prev := 0;
  if (Row - 1) < Length(FPrevLTP) then Prev := FPrevLTP[Row - 1];

  Change := 0; ChangePct := 0;
  if Prev > 0 then begin
    Change := ATick.LTP - Prev;
    ChangePct := (Change / Prev) * 100;
  end;

  if ATick.LTP > Prev then
    gridWatchlist.Cells[1, Row] := #$E2#$96#$B2 + ' ' + FormatFloat('0.00', ATick.LTP)
  else if ATick.LTP < Prev then
    gridWatchlist.Cells[1, Row] := #$E2#$96#$BC + ' ' + FormatFloat('0.00', ATick.LTP)
  else
    gridWatchlist.Cells[1, Row] := '  ' + FormatFloat('0.00', ATick.LTP);
  if Change > 0 then
    gridWatchlist.Cells[2, Row] := '+' + FormatFloat('0.00', Change)
  else
    gridWatchlist.Cells[2, Row] := FormatFloat('0.00', Change);
  gridWatchlist.Cells[3, Row] := FormatFloat('0.00', ChangePct) + '%';
  gridWatchlist.Cells[4, Row] := FormatFloat('0.00', ATick.Bid);
  gridWatchlist.Cells[5, Row] := FormatFloat('0.00', ATick.Ask);
  gridWatchlist.Cells[6, Row] := IntToStr(ATick.Volume);
  gridWatchlist.Cells[7, Row] := IntToStr(ATick.OI);

  if (Row - 1) < Length(FPrevLTP) then FPrevLTP[Row - 1] := ATick.LTP;
end;

procedure TfrmDashboard.ProcessOrderEvent(const AEvt: TOrderEvent);
var
  S: string;
  Row, I: Integer;
  JObj: TJSONObject;
  JData: TJSONData;
  OrderId, Status, Symbol, Side: string;
  FilledQty: Integer;
  AvgPrice: Double;
begin
  S := string(PAnsiChar(@AEvt.Json[0]));

  // Try to parse JSON for structured processing
  try
    JData := GetJSON(S);
    if JData is TJSONObject then
    begin
      JObj := TJSONObject(JData);
      OrderId := JObj.Get('order_id', JObj.Get('orderId', ''));
      Status := JObj.Get('status', '');
      Symbol := JObj.Get('symbol', JObj.Get('tradingsymbol', ''));
      Side := JObj.Get('side', JObj.Get('transaction_type', ''));
      FilledQty := JObj.Get('filled_qty', JObj.Get('filled_quantity', 0));
      AvgPrice := JObj.Get('avg_price', JObj.Get('average_price', 0.0));

      // Find existing row by order ID or add new
      Row := -1;
      for I := 1 to gridOrders.RowCount - 1 do
        if gridOrders.Cells[0, I] = OrderId then
        begin
          Row := I;
          Break;
        end;

      if Row < 0 then
      begin
        Row := gridOrders.RowCount;
        gridOrders.RowCount := Row + 1;
      end;

      gridOrders.Cells[0, Row] := OrderId;
      if Symbol <> '' then gridOrders.Cells[1, Row] := Symbol;
      if Side <> '' then gridOrders.Cells[2, Row] := Side;
      gridOrders.Cells[4, Row] := IntToStr(FilledQty);
      if AvgPrice > 0 then gridOrders.Cells[5, Row] := FormatFloat('0.00', AvgPrice);
      gridOrders.Cells[6, Row] := Status;

      // Record fill in risk manager
      if (FilledQty > 0) and (AvgPrice > 0) and (FRisk <> nil) then
        FRisk.RecordFill('', AnsiString(Symbol), FilledQty, AvgPrice,
          (LowerCase(Side) = 'buy') or (LowerCase(Side) = 'b'));

      // Update state
      if (FState <> nil) and (FilledQty > 0) then
      begin
        if (LowerCase(Side) = 'buy') or (LowerCase(Side) = 'b') then
          FState.UpdatePosition('', AnsiString(Symbol), 0, FilledQty, AvgPrice, 0, 0)
        else
          FState.UpdatePosition('', AnsiString(Symbol), 0, -FilledQty, AvgPrice, 0, 0);
      end;

      JData.Free;
    end
    else
    begin
      JData.Free;
      // Fallback: just log
      Row := gridOrders.RowCount;
      gridOrders.RowCount := Row + 1;
      gridOrders.Cells[6, Row] := 'Update';
    end;
  except
    // JSON parse failed — fallback
    Row := gridOrders.RowCount;
    gridOrders.RowCount := Row + 1;
    gridOrders.Cells[6, Row] := 'Update';
  end;

  Log('Order: ' + AnsiString(Copy(S, 1, 120)));
end;

procedure TfrmDashboard.ProcessStatusEvent(const AEvt: TStatusEvent);
begin
  case AEvt.Kind of
    0: begin
      shpStatus.Brush.Color := clLime;
      lblStatus.Caption := 'Connected';
      Log('Connected: ' + AnsiString(PAnsiChar(@AEvt.Feed[0])));
    end;
    1: begin
      shpStatus.Brush.Color := clRed;
      lblStatus.Caption := 'Disconnected';
      Log('Disconnected: ' + AnsiString(PAnsiChar(@AEvt.Feed[0])));
    end;
  end;
end;

{ ═══════════════════════════════════════════════════════════════════ }
{  Timer: Poll (2s)                                                   }
{ ═══════════════════════════════════════════════════════════════════ }

procedure TfrmDashboard.tmrPollTimer(Sender: TObject);
var
  Avail, Used: Double;
  I, RunningCount: Integer;
  Bot: TRunningBot;
begin
  if FBroker = nil then Exit;

  Avail := FBroker.AvailableMargin;
  Used := FBroker.UsedMargin;
  lblFundsAvail.Caption := Format('Available: %.0f', [Avail]);
  lblFundsUsed.Caption := Format('Used: %.0f', [Used]);
  lblFundsBalance.Caption := Format('Balance: %.0f', [Avail + Used]);

  if gridPositions.RowCount <= 1 then
    lblNetPosition.Caption := 'Net: FLAT'
  else
    lblNetPosition.Caption := Format('Net: %d positions', [gridPositions.RowCount - 1]);

  for I := 0 to FBots.Count - 1 do
  begin
    Bot := FBots[I];
    if Bot.Running and (Bot.Strategy <> nil) and ((I + 1) < gridStrategies.RowCount) then
    begin
      gridStrategies.Cells[5, I + 1] := FormatFloat('0.00', Bot.Strategy.PnL);
      gridStrategies.Cells[6, I + 1] := IntToStr(Bot.Strategy.TickCount);
      // Update risk manager with strategy P&L
      FRisk.UpdatePnL(Bot.Name, Bot.Strategy.PnL);
    end;
  end;

  // Update daily P&L and auto-save state
  FRisk.UpdateDailyPnL(Used);  // approximate from margin used
  FState.CheckAutoSave;

  // Update top bar P&L and market clock
  if FRisk.DailyPnL >= 0 then
    lblDailyPnLBar.Font.Color := clGreen
  else
    lblDailyPnLBar.Font.Color := clRed;
  lblDailyPnLBar.Caption := Format('P&L: %s%.2f',
    [IfThen(FRisk.DailyPnL >= 0, '+', ''), FRisk.DailyPnL]);
  lblMarketClock.Caption := string(GSession.ClockDisplay);

  // Update side nav bot count and position count
  RunningCount := 0;
  for I := 0 to FBots.Count - 1 do
    if FBots[I].Running then Inc(RunningCount);
  lblNavBotCount.Caption := Format('Bots: %d/%d', [RunningCount, FBots.Count]);
  lblNavPositions.Caption := Format('Positions: %d', [gridPositions.RowCount - 1]);

  // Refresh health page
  RefreshHealth;

  // Kill switch check
  if FRisk.KillSwitchTripped then
  begin
    FAlerts.Alert(alCritical, 'KILL SWITCH TRIPPED — all trading halted');
    Log('RISK: Kill switch tripped — ' + AnsiString(FRisk.LastViolation));
    StopEngine;
  end;
end;

{ ═══════════════════════════════════════════════════════════════════ }
{  Health page                                                        }
{ ═══════════════════════════════════════════════════════════════════ }

procedure TfrmDashboard.RefreshHealth;
var
  I, Row: Integer;
  Bot: TRunningBot;
  Snap: TPortfolioGreeksSnapshot;
  TotalRealized, TotalUnrealized, TotalPnL: Double;
  TotalTrades: Integer;
begin
  // Update risk status indicators
  if FRisk.KillSwitchTripped then
  begin
    lblRiskStatus.Caption := 'Risk: KILL SWITCH';
    shpRiskLight.Brush.Color := clRed;
  end
  else
  begin
    lblRiskStatus.Caption := 'Risk: OK';
    shpRiskLight.Brush.Color := clLime;
  end;

  lblOpenOrders.Caption := Format('Open Orders: %d/%d',
    [FRisk.OpenOrderCount, FRisk.MaxOpenOrders]);
  lblDailyPnL.Caption := Format('Daily P&L: %.2f', [FRisk.DailyPnL]);
  lblExposure.Caption := Format('Exposure: %.2f', [FRisk.Exposure]);

  // Update per-strategy health grid
  gridHealth.RowCount := 1;
  for I := 0 to FBots.Count - 1 do
  begin
    Bot := FBots[I];
    Row := gridHealth.RowCount;
    gridHealth.RowCount := Row + 1;

    gridHealth.Cells[0, Row] := string(Bot.Name);
    if Bot.Running then
      gridHealth.Cells[1, Row] := 'Running'
    else
      gridHealth.Cells[1, Row] := 'Stopped';

    if Bot.Strategy <> nil then
    begin
      gridHealth.Cells[2, Row] := IntToStr(Bot.Strategy.TradeCount);
      if Bot.Strategy.TradeCount > 0 then
        gridHealth.Cells[3, Row] := FormatFloat('0.0',
          (Bot.Strategy.WinCount / Bot.Strategy.TradeCount) * 100)
      else
        gridHealth.Cells[3, Row] := '0.0';
      gridHealth.Cells[4, Row] := FormatFloat('0.00', Bot.Strategy.PnL);
      gridHealth.Cells[5, Row] := FormatFloat('0.00', Bot.Strategy.MaxDrawdown);
      gridHealth.Cells[6, Row] := FormatFloat('0.00', Bot.Strategy.Sharpe);
      gridHealth.Cells[7, Row] := IntToStr(Bot.Strategy.TickCount);
    end
    else
    begin
      gridHealth.Cells[2, Row] := '0';
      gridHealth.Cells[3, Row] := '0.0';
      gridHealth.Cells[4, Row] := '0.00';
      gridHealth.Cells[5, Row] := '0.00';
      gridHealth.Cells[6, Row] := '0.00';
      gridHealth.Cells[7, Row] := '0';
    end;
  end;

  // Compute and display portfolio Greeks
  Snap := FPortfolioGreeks.Compute;
  lblNetDelta.Caption := Format('Delta: %.1f', [Snap.NetDelta]);
  lblNetGamma.Caption := Format('Gamma: %.2f', [Snap.NetGamma]);
  lblNetTheta.Caption := Format('Theta: %.0f', [Snap.NetTheta]);
  lblNetVega.Caption := Format('Vega: %.0f', [Snap.NetVega]);

  // Aggregate P&L breakdown across all strategies
  TotalRealized := 0;
  TotalUnrealized := 0;
  TotalTrades := 0;
  for I := 0 to FBots.Count - 1 do
  begin
    Bot := FBots[I];
    if Bot.Strategy <> nil then
    begin
      if Bot.Running then
        TotalUnrealized := TotalUnrealized + Bot.Strategy.PnL
      else
        TotalRealized := TotalRealized + Bot.Strategy.PnL;
      TotalTrades := TotalTrades + Bot.Strategy.TradeCount;
    end;
  end;
  TotalPnL := TotalRealized + TotalUnrealized;

  lblRealizedPnL.Caption := Format('Realized: %.2f', [TotalRealized]);
  lblUnrealizedPnL.Caption := Format('Unrealized: %.2f', [TotalUnrealized]);
  lblTotalPnL.Caption := Format('Total: %.2f', [TotalPnL]);
  lblTotalTrades.Caption := Format('Trades: %d', [TotalTrades]);

  if TotalPnL >= 0 then
    lblTotalPnL.Font.Color := clLime
  else
    lblTotalPnL.Font.Color := clRed;
end;

{ ═══════════════════════════════════════════════════════════════════ }
{  Button handlers                                                    }
{ ═══════════════════════════════════════════════════════════════════ }

procedure TfrmDashboard.btnAddSymbolClick(Sender: TObject);
var
  Sym: AnsiString;
  Ex: TExchange;
  SymId, Row: Integer;
begin
  if FBroker = nil then begin Log('Engine not running'); Exit; end;
  Sym := AnsiString(edtAddSymbol.Text);
  Ex := ExchangeFromIndex(cbxWatchExchange.ItemIndex);
  if Sym = '' then Exit;

  SymId := FBroker.FindInstrument(Sym, Ex);
  if SymId < 0 then begin Log('Not found: ' + Sym); Exit; end;
  if FSymbolRowMap.ContainsKey(SymId) then begin Log('Already watching'); Exit; end;

  FBroker.Subscribe(Sym, Ex, smQuote);
  Row := gridWatchlist.RowCount;
  gridWatchlist.RowCount := Row + 1;
  gridWatchlist.Cells[0, Row] := string(Sym);
  FSymbolRowMap.Add(SymId, Row);
  SetLength(FPrevLTP, Row);
  FPrevLTP[Row - 1] := 0;
  Log(Format('Subscribed: %s → %d', [string(Sym), SymId]));
  edtAddSymbol.Text := '';
end;

procedure TfrmDashboard.btnRemoveSymbolClick(Sender: TObject);
var
  Row: Integer;
  Sym: AnsiString;
begin
  if FBroker = nil then Exit;
  Row := gridWatchlist.Row;
  if Row < 1 then Exit;
  Sym := AnsiString(gridWatchlist.Cells[0, Row]);
  FBroker.Unsubscribe(Sym, exNSE);
  gridWatchlist.DeleteRow(Row);
  FSymbolRowMap.Clear;
  Log('Unsubscribed: ' + Sym);
end;

procedure TfrmDashboard.btnPlaceOrderClick(Sender: TObject);
var
  Sym, OrderId: AnsiString;
  Row: Integer;
begin
  if FBroker = nil then begin Log('Engine not running'); Exit; end;
  Sym := AnsiString(edtOrdSymbol.Text);
  if Sym = '' then Exit;

  try
    OrderId := FBroker.PlaceOrder(Sym,
      ExchangeFromIndex(cbxOrdExchange.ItemIndex),
      TSide(cbxOrdSide.ItemIndex),
      TOrderKind(cbxOrdType.ItemIndex),
      TProductType(cbxOrdProduct.ItemIndex),
      vDay, edtOrdQty.Value,
      StrToFloatDef(edtOrdPrice.Text, 0),
      StrToFloatDef(edtOrdTrigger.Text, 0));
    Row := gridOrders.RowCount;
    gridOrders.RowCount := Row + 1;
    gridOrders.Cells[0, Row] := string(OrderId);
    gridOrders.Cells[1, Row] := string(Sym);
    gridOrders.Cells[2, Row] := cbxOrdSide.Text;
    gridOrders.Cells[3, Row] := cbxOrdType.Text;
    gridOrders.Cells[4, Row] := IntToStr(edtOrdQty.Value);
    gridOrders.Cells[5, Row] := edtOrdPrice.Text;
    gridOrders.Cells[6, Row] := 'Pending';
    Log('Order placed: ' + OrderId);
  except
    on E: Exception do Log('Order failed: ' + AnsiString(E.Message));
  end;
end;

procedure TfrmDashboard.btnSearchClick(Sender: TObject);
var
  Q, R: AnsiString;
  JArr: TJSONArray;
  JObj: TJSONObject;
  I, Row: Integer;
begin
  if FBroker = nil then begin Log('Engine not running'); Exit; end;
  Q := AnsiString(edtSearch.Text);
  if Q = '' then Exit;

  R := FBroker.SearchJson(Q, ExchangeFromIndex(cbxSearchExchange.ItemIndex), 30);
  if R = '' then begin Log('No results'); Exit; end;

  try
    JArr := GetJSON(string(R)) as TJSONArray;
    try
      gridSearch.RowCount := 1;
      for I := 0 to JArr.Count - 1 do
      begin
        JObj := JArr.Objects[I];
        Row := gridSearch.RowCount;
        gridSearch.RowCount := Row + 1;
        gridSearch.Cells[0, Row] := JObj.Get('symbol', '');
        gridSearch.Cells[1, Row] := JObj.Get('name', '');
        gridSearch.Cells[2, Row] := JObj.Get('exchange', '');
        gridSearch.Cells[3, Row] := JObj.Get('type', '');
        gridSearch.Cells[4, Row] := IntToStr(JObj.Get('lot_size', 1));
        gridSearch.Cells[5, Row] := FloatToStr(JObj.Get('tick_size', 0.05));
        gridSearch.Cells[6, Row] := JObj.Get('key', '');
      end;
      Log(Format('Search: %d results', [gridSearch.RowCount - 1]));
    finally
      JArr.Free;
    end;
  except
    on E: Exception do Log('Search error: ' + AnsiString(E.Message));
  end;
end;

procedure TfrmDashboard.btnSaveSettingsClick(Sender: TObject);
begin
  SaveSettings;
  // Apply risk settings to live risk manager
  FRisk.DailyLossLimit := StrToFloatDef(edtDailyLossLimit.Text, FRisk.DailyLossLimit);
  FRisk.MaxExposure := StrToFloatDef(edtMaxExposure.Text, FRisk.MaxExposure);
  FRisk.StrategyLossLimit := StrToFloatDef(edtStrategyLossLimit.Text, FRisk.StrategyLossLimit);
  FRisk.MaxSymbolExposure := StrToFloatDef(edtMaxSymbolExposure.Text, FRisk.MaxSymbolExposure);
  FRisk.MaxOrdersPerSec := StrToIntDef(edtMaxOrdersPerSec.Text, FRisk.MaxOrdersPerSec);
  FRisk.MaxOpenOrders := StrToIntDef(edtMaxOpenOrders.Text, FRisk.MaxOpenOrders);
  FRisk.Enabled := chkRiskEnabled.Checked;
  // Apply timer settings
  tmrDrain.Interval := StrToIntDef(edtDrainInterval.Text, tmrDrain.Interval);
  tmrPoll.Interval := StrToIntDef(edtPollInterval.Text, tmrPoll.Interval);
  FState.SaveInterval := StrToIntDef(edtStateSaveInterval.Text, FState.SaveInterval);
  // Apply trading hours to GSession
  if Pos(':', edtMarketOpen.Text) > 0 then
  begin
    GSession.MarketOpenHour := StrToIntDef(Copy(edtMarketOpen.Text, 1, Pos(':', edtMarketOpen.Text) - 1), 9);
    GSession.MarketOpenMin := StrToIntDef(Copy(edtMarketOpen.Text, Pos(':', edtMarketOpen.Text) + 1, MaxInt), 15);
  end;
  if Pos(':', edtMarketClose.Text) > 0 then
  begin
    GSession.MarketCloseHour := StrToIntDef(Copy(edtMarketClose.Text, 1, Pos(':', edtMarketClose.Text) - 1), 15);
    GSession.MarketCloseMin := StrToIntDef(Copy(edtMarketClose.Text, Pos(':', edtMarketClose.Text) + 1, MaxInt), 30);
  end;
  if Pos(':', edtForceExit.Text) > 0 then
  begin
    GSession.ForceExitHour := StrToIntDef(Copy(edtForceExit.Text, 1, Pos(':', edtForceExit.Text) - 1), 15);
    GSession.ForceExitMin := StrToIntDef(Copy(edtForceExit.Text, Pos(':', edtForceExit.Text) + 1, MaxInt), 20);
  end;
  if Pos(':', edtEntryStart.Text) > 0 then
  begin
    GSession.EntryStartHour := StrToIntDef(Copy(edtEntryStart.Text, 1, Pos(':', edtEntryStart.Text) - 1), 9);
    GSession.EntryStartMin := StrToIntDef(Copy(edtEntryStart.Text, Pos(':', edtEntryStart.Text) + 1, MaxInt), 20);
  end;
  if Pos(':', edtEntryEnd.Text) > 0 then
  begin
    GSession.EntryEndHour := StrToIntDef(Copy(edtEntryEnd.Text, 1, Pos(':', edtEntryEnd.Text) - 1), 14);
    GSession.EntryEndMin := StrToIntDef(Copy(edtEntryEnd.Text, Pos(':', edtEntryEnd.Text) + 1, MaxInt), 30);
  end;
  lblSettingsStatus.Caption := 'Saved';
  Log('Settings saved and applied');
end;

procedure TfrmDashboard.btnLaunchWizardClick(Sender: TObject);
begin
  if FBroker = nil then
  begin
    Log('Connect to broker first, then use Strategies > Start');
    ShowPage(PAGE_STRATEGIES);
    HighlightNav(btnNavStrategies);
    Exit;
  end;
  btnStratStartClick(Sender);
end;

procedure TfrmDashboard.btnClearLogClick(Sender: TObject);
begin
  memoLog.Lines.Clear;
  lblLogCount.Caption := 'Lines: 0/1000';
end;

procedure TfrmDashboard.btnFlattenAllClick(Sender: TObject);
var
  I: Integer;
  Bot: TRunningBot;
begin
  if MessageDlg('FLATTEN ALL positions and stop all bots?',
    mtWarning, [mbYes, mbNo], 0) <> mrYes then Exit;

  Log('FLATTEN ALL triggered by user');

  // Exit all positions via broker first
  if FBroker <> nil then
  begin
    for I := 0 to FBots.Count - 1 do
    begin
      Bot := FBots[I];
      if Bot.Running and (Bot.Strategy <> nil) and (Bot.Underlying <> '') then
      begin
        try
          FBroker.ExitPosition(Bot.Underlying, Bot.Strategy.Exchange);
          Log('Exited position: ' + Bot.Underlying);
        except
          on E: Exception do
            Log('Exit failed: ' + Bot.Underlying + ' — ' + AnsiString(E.Message));
        end;
      end;
    end;
  end;

  StopEngine;
  Log('FLATTEN ALL complete');
end;

procedure TfrmDashboard.gridWatchlistDblClick(Sender: TObject);
var
  Row: Integer;
  Sym: string;
begin
  Row := gridWatchlist.Row;
  if Row < 1 then Exit;
  Sym := gridWatchlist.Cells[0, Row];
  if Sym = '' then Exit;
  edtOrdSymbol.Text := Sym;
  ShowPage(PAGE_ORDERS);
  HighlightNav(btnNavOrders);
end;

procedure TfrmDashboard.miWatchUnsubscribeClick(Sender: TObject);
begin
  btnRemoveSymbolClick(Sender);
end;

procedure TfrmDashboard.miWatchPlaceOrderClick(Sender: TObject);
begin
  gridWatchlistDblClick(Sender);
end;

procedure TfrmDashboard.miStratStopClick(Sender: TObject);
begin
  btnStratStopClick(Sender);
end;

procedure TfrmDashboard.miStratRemoveClick(Sender: TObject);
var
  Row, Idx: Integer;
  Bot: TRunningBot;
begin
  Row := gridStrategies.Row;
  if Row < 1 then Exit;
  Idx := Row - 1;
  if Idx >= FBots.Count then Exit;
  Bot := FBots[Idx];

  if Bot.Running then
  begin
    Bot.Thread.Terminate;
    Bot.Thread.WaitFor;
    FreeAndNil(Bot.Thread);
    FreeAndNil(Bot.Strategy);
    if FEventBus <> nil then
      FEventBus.RemoveStrategySlot(Bot.SlotIndex);
    Bot.Running := False;
  end
  else
    FreeAndNil(Bot.Strategy);

  FBots.Delete(Idx);
  gridStrategies.DeleteRow(Row);
  Log('Removed bot: ' + Bot.Name);
end;

procedure TfrmDashboard.btnStratStartClick(Sender: TObject);
var
  Regs: TArray<TStrategyRegistration>;
  Wiz: TfrmBotWizard;
  Bot: TRunningBot;
  Idx, SlotIdx, Row, I: Integer;
  StratName: AnsiString;
begin
  if FBroker = nil then begin Log('Engine not running'); Exit; end;

  Wiz := TfrmBotWizard.Create(Self);
  try
    if Wiz.ShowModal <> mrOK then Exit;

    StratName := Wiz.GetStrategyName;
    Regs := GetRegisteredStrategies;
    Idx := -1;
    for I := 0 to High(Regs) do
      if Regs[I].Name = StratName then begin Idx := I; Break; end;
    if Idx < 0 then begin Log('Strategy not found: ' + StratName); Exit; end;

    SlotIdx := FEventBus.AddStrategySlot;
    if SlotIdx < 0 then begin Log('Max strategy slots reached'); Exit; end;

    Bot.Name := AnsiString(Format('bot-%d', [FBots.Count + 1]));
    Bot.StrategyName := StratName;
    Bot.Underlying := Wiz.GetUnderlying;
    Bot.Strategy := Regs[Idx].StrategyClass.Create;
    Bot.Strategy.Name := Bot.Name;
    Bot.Strategy.Underlying := Bot.Underlying;
    Bot.Strategy.Lots := Wiz.GetLots;
    Bot.Strategy.WarmupTicks := Wiz.GetWarmupTicks;
    Bot.Strategy.Broker := FBroker;
    Bot.Strategy.Risk := FRisk;
    Bot.Strategy.EventBus := FEventBus;
    Bot.SlotIndex := SlotIdx;

    for I := 0 to Wiz.GetParamCount - 1 do
      Bot.Strategy.ApplyParam(Wiz.GetParamName(I), Wiz.GetParamValue(I));

    FBroker.Subscribe(Bot.Underlying, exNSE, smQuote);

    Bot.Thread := TStrategyThread.Create(Bot.Strategy,
      FEventBus.StrategySlots[SlotIdx].Ticks);
    Bot.Running := True;
    Bot.Thread.Start;
    FBots.Add(Bot);

    Row := gridStrategies.RowCount;
    gridStrategies.RowCount := Row + 1;
    gridStrategies.Cells[0, Row] := string(Bot.Name);
    gridStrategies.Cells[1, Row] := string(Bot.StrategyName);
    gridStrategies.Cells[2, Row] := string(Bot.Underlying);
    gridStrategies.Cells[3, Row] := IntToStr(Bot.Strategy.Lots);
    gridStrategies.Cells[4, Row] := #$E2#$97#$8F + ' Running';

    Log(Format('Started: %s (%s on %s)', [string(Bot.Name),
      string(Bot.StrategyName), string(Bot.Underlying)]));
  finally
    Wiz.Free;
  end;
end;

procedure TfrmDashboard.btnStratStopClick(Sender: TObject);
var
  Row, Idx: Integer;
  Bot: TRunningBot;
begin
  Row := gridStrategies.Row;
  if Row < 1 then Exit;
  Idx := Row - 1;
  if Idx >= FBots.Count then Exit;
  Bot := FBots[Idx];
  if not Bot.Running then Exit;

  Bot.Thread.Terminate;
  Bot.Thread.WaitFor;
  FreeAndNil(Bot.Thread);
  FreeAndNil(Bot.Strategy);
  if FEventBus <> nil then
    FEventBus.RemoveStrategySlot(Bot.SlotIndex);
  Bot.Running := False;
  FBots[Idx] := Bot;
  gridStrategies.Cells[4, Row] := #$E2#$97#$8B + ' Stopped';
  Log('Stopped: ' + string(Bot.Name));
end;

{ ═══════════════════════════════════════════════════════════════════ }
{  Options Chain                                                       }
{ ═══════════════════════════════════════════════════════════════════ }

procedure TfrmDashboard.btnLoadChainClick(Sender: TObject);
var
  Underlying, ExpiriesJson, StrikesJson: AnsiString;
  JData, JStrikesData: TJSONData;
  JArr, JStrikesArr: TJSONArray;
  JObj: TJSONObject;
  I, Row: Integer;
  ExpiryUnix: Int64;
  Strikes: array of Double;
  CallOI, PutOI: array of Int64;
  CEKey, PEKey: AnsiString;
  CELTP, PELTP, Spot, TTE, CEIV, PEIV: Double;
  CEGreeks, PEGreeks: TGreeks;
  MaxPain: TMaxPainResult;
  IVAnalyzer: TIVAnalyzer;
  Stats: TIVStats;
  AvgIV: Double;
begin
  if FBroker = nil then begin Log('Engine not running'); Exit; end;
  Underlying := AnsiString(edtChainUnderlying.Text);
  if Underlying = '' then begin Log('Enter underlying symbol'); Exit; end;

  // Step 1: Load expiries if combo is empty
  if cbxChainExpiry.Items.Count = 0 then
  begin
    ExpiriesJson := FBroker.ListExpiriesJson(Underlying, exNFO);
    if ExpiriesJson = '' then
    begin
      Log('No expiries found for ' + Underlying);
      Exit;
    end;
    try
      JData := GetJSON(string(ExpiriesJson));
      try
        if JData is TJSONArray then
        begin
          JArr := JData as TJSONArray;
          cbxChainExpiry.Items.Clear;
          for I := 0 to JArr.Count - 1 do
          begin
            if JArr.Items[I] is TJSONObject then
            begin
              JObj := JArr.Objects[I];
              cbxChainExpiry.Items.AddObject(
                JObj.Get('label', JObj.Get('expiry', '')),
                TObject(PtrInt(JObj.Get('unix', Int64(0)))));
            end
            else
              cbxChainExpiry.Items.Add(JArr.Items[I].AsString);
          end;
          if cbxChainExpiry.Items.Count > 0 then
            cbxChainExpiry.ItemIndex := 0;
        end;
      finally
        JData.Free;
      end;
    except
      on E: Exception do begin Log('Expiry parse error: ' + AnsiString(E.Message)); Exit; end;
    end;
    Log(Format('Loaded %d expiries for %s', [cbxChainExpiry.Items.Count, string(Underlying)]));
    Exit;
  end;

  // Step 2: Load option chain for selected expiry
  if cbxChainExpiry.ItemIndex < 0 then begin Log('Select an expiry'); Exit; end;
  ExpiryUnix := PtrInt(cbxChainExpiry.Items.Objects[cbxChainExpiry.ItemIndex]);

  StrikesJson := FBroker.ListStrikesJson(Underlying, ExpiryUnix, exNFO);
  if StrikesJson = '' then begin Log('No strikes found'); Exit; end;

  // Get spot price
  Spot := FBroker.LTP(Underlying, exNSE);
  if Spot <= 0 then
    Spot := FBroker.LTP(Underlying, exNFO);

  // Compute time to expiry in years (approximate)
  if ExpiryUnix > 0 then
    TTE := (ExpiryUnix - DateTimeToUnix(Now)) / (365.25 * 86400)
  else
    TTE := 7.0 / 365.25;
  if TTE <= 0 then TTE := 1.0 / 365.25;

  try
    JStrikesData := GetJSON(string(StrikesJson));
    try
      if not (JStrikesData is TJSONArray) then
      begin
        Log('Invalid strikes data');
        JStrikesData.Free;
        Exit;
      end;
      JStrikesArr := JStrikesData as TJSONArray;

      SetLength(Strikes, JStrikesArr.Count);
      SetLength(CallOI, JStrikesArr.Count);
      SetLength(PutOI, JStrikesArr.Count);

      gridOptionChain.RowCount := 1;

      for I := 0 to JStrikesArr.Count - 1 do
      begin
        if not (JStrikesArr.Items[I] is TJSONObject) then Continue;
        JObj := JStrikesArr.Objects[I];

        Strikes[I] := JObj.Get('strike', 0.0);
        CEKey := AnsiString(JObj.Get('ce_key', ''));
        PEKey := AnsiString(JObj.Get('pe_key', ''));
        CallOI[I] := JObj.Get('ce_oi', Int64(0));
        PutOI[I] := JObj.Get('pe_oi', Int64(0));

        // Get LTP for CE and PE
        CELTP := 0; PELTP := 0;
        if CEKey <> '' then
          CELTP := FBroker.LTP(CEKey, exNFO);
        if PEKey <> '' then
          PELTP := FBroker.LTP(PEKey, exNFO);

        // Compute Greeks via Black-Scholes
        // Use a default IV estimate if we can compute it
        CEIV := 0.20; PEIV := 0.20;
        if (Spot > 0) and (Strikes[I] > 0) and (CELTP > 0) then
          CEIV := Max(0.01, CELTP / (Spot * 0.4 * Sqrt(TTE)));
        if (Spot > 0) and (Strikes[I] > 0) and (PELTP > 0) then
          PEIV := Max(0.01, PELTP / (Spot * 0.4 * Sqrt(TTE)));

        CEGreeks := TBlackScholes.Calculate(Spot, Strikes[I], TTE, CEIV, 0.07, 0.0, True);
        PEGreeks := TBlackScholes.Calculate(Spot, Strikes[I], TTE, PEIV, 0.07, 0.0, False);

        Row := gridOptionChain.RowCount;
        gridOptionChain.RowCount := Row + 1;

        gridOptionChain.Cells[0, Row] := IntToStr(CallOI[I]);
        gridOptionChain.Cells[1, Row] := IntToStr(JObj.Get('ce_vol', Int64(0)));
        gridOptionChain.Cells[2, Row] := FormatFloat('0.00', CELTP);
        gridOptionChain.Cells[3, Row] := FormatFloat('0.00', CEIV * 100);
        gridOptionChain.Cells[4, Row] := FormatFloat('0.000', CEGreeks.Delta);
        gridOptionChain.Cells[5, Row] := FormatFloat('0.0000', CEGreeks.Gamma);
        gridOptionChain.Cells[6, Row] := FormatFloat('0.00', Strikes[I]);
        gridOptionChain.Cells[7, Row] := FormatFloat('0.0000', PEGreeks.Gamma);
        gridOptionChain.Cells[8, Row] := FormatFloat('0.000', PEGreeks.Delta);
        gridOptionChain.Cells[9, Row] := FormatFloat('0.00', PEIV * 100);
        gridOptionChain.Cells[10, Row] := FormatFloat('0.00', PELTP);
        gridOptionChain.Cells[11, Row] := IntToStr(JObj.Get('pe_vol', Int64(0)));
        gridOptionChain.Cells[12, Row] := IntToStr(PutOI[I]);
      end;

      // Compute Max Pain
      MaxPain := TIVAnalyzer.ComputeMaxPain(Strikes, CallOI, PutOI, Spot);
      lblMaxPain.Caption := Format('Max Pain: %.0f | PCR: %.2f',
        [MaxPain.Strike, MaxPain.PCR]);

      // Compute IV Rank from average chain IV
      AvgIV := 0;
      if gridOptionChain.RowCount > 1 then
      begin
        for I := 1 to gridOptionChain.RowCount - 1 do
          AvgIV := AvgIV + StrToFloatDef(gridOptionChain.Cells[3, I], 0);
        AvgIV := AvgIV / (gridOptionChain.RowCount - 1);
      end;

      IVAnalyzer := TIVAnalyzer.Create;
      try
        // Seed with a simple range estimate if no historical data
        IVAnalyzer.AddHistoricalIV(AvgIV * 0.6);
        IVAnalyzer.AddHistoricalIV(AvgIV * 0.8);
        IVAnalyzer.AddHistoricalIV(AvgIV);
        IVAnalyzer.AddHistoricalIV(AvgIV * 1.2);
        IVAnalyzer.AddHistoricalIV(AvgIV * 1.5);
        Stats := IVAnalyzer.ComputeStats(AvgIV);
        lblIVRank.Caption := Format('IV Rank: %.0f | Regime: %s',
          [Stats.IVRank, string(Stats.Regime)]);
      finally
        IVAnalyzer.Free;
      end;

      Log(Format('Options chain loaded: %d strikes, Max Pain=%.0f, PCR=%.2f',
        [Length(Strikes), MaxPain.Strike, MaxPain.PCR]));
    finally
      JStrikesData.Free;
    end;
  except
    on E: Exception do Log('Chain error: ' + AnsiString(E.Message));
  end;
end;

{ ═══════════════════════════════════════════════════════════════════ }
{  Helpers                                                            }
{ ═══════════════════════════════════════════════════════════════════ }

procedure TfrmDashboard.Log(const AMsg: AnsiString);
begin
  memoLog.Lines.Add(FormatDateTime('hh:nn:ss', Now) + ' ' + string(AMsg));
  while memoLog.Lines.Count > 1000 do memoLog.Lines.Delete(0);
  lblLogCount.Caption := Format('Lines: %d/1000', [memoLog.Lines.Count]);
end;

function TfrmDashboard.ExchangeFromIndex(AIndex: Integer): TExchange;
begin
  Result := TExchange(AIndex);
end;

procedure TfrmDashboard.InitGridHeaders(AGrid: TStringGrid;
  const ACols: array of string; const AWidths: array of Integer);
var
  I: Integer;
begin
  AGrid.ColCount := Length(ACols);
  AGrid.FixedRows := 1;
  AGrid.RowCount := 1;
  AGrid.Options := AGrid.Options + [goRowSelect] - [goEditing];
  for I := 0 to High(ACols) do
  begin
    AGrid.Cells[I, 0] := ACols[I];
    if I <= High(AWidths) then AGrid.ColWidths[I] := AWidths[I];
  end;
end;

procedure TfrmDashboard.PopulateStrategyCombo;
var
  Regs: TArray<TStrategyRegistration>;
  I: Integer;
begin
  Regs := GetRegisteredStrategies;
  cbxStratName.Items.Clear;
  for I := 0 to High(Regs) do
    cbxStratName.Items.Add(string(Regs[I].Name));
  if cbxStratName.Items.Count > 0 then
    cbxStratName.ItemIndex := 0;
end;

function BotsPath: string;
begin
  Result := ExtractFilePath(ParamStr(0)) + 'config' + PathDelim + 'bots.json';
end;

function SettingsPath: string;
begin
  Result := ExtractFilePath(ParamStr(0)) + 'config' + PathDelim + 'settings.ini';
end;

procedure TfrmDashboard.LoadSettings;
var
  F: TextFile;
  Line, Key, Val: string;
  P: Integer;
begin
  if not FileExists(SettingsPath) then Exit;
  AssignFile(F, SettingsPath);
  try
    Reset(F);
    while not Eof(F) do
    begin
      ReadLn(F, Line);
      P := Pos('=', Line);
      if P > 0 then
      begin
        Key := Trim(Copy(Line, 1, P - 1));
        Val := Trim(Copy(Line, P + 1, MaxInt));
        if Key = 'broker' then cbxBroker.ItemIndex := cbxBroker.Items.IndexOf(Val)
        else if Key = 'token' then edtToken.Text := Val
        else if Key = 'api_key' then edtApiKey.Text := Val
        else if Key = 'auto_connect' then chkAutoConnect.Checked := (Val = '1')
        else if Key = 'daily_loss_limit' then edtDailyLossLimit.Text := Val
        else if Key = 'max_exposure' then edtMaxExposure.Text := Val
        else if Key = 'strategy_loss_limit' then edtStrategyLossLimit.Text := Val
        else if Key = 'max_symbol_exposure' then edtMaxSymbolExposure.Text := Val
        else if Key = 'max_orders_per_sec' then edtMaxOrdersPerSec.Text := Val
        else if Key = 'max_open_orders' then edtMaxOpenOrders.Text := Val
        else if Key = 'risk_enabled' then chkRiskEnabled.Checked := (Val = '1')
        else if Key = 'drain_interval' then edtDrainInterval.Text := Val
        else if Key = 'poll_interval' then edtPollInterval.Text := Val
        else if Key = 'state_save_interval' then edtStateSaveInterval.Text := Val
        else if Key = 'default_warmup' then edtDefaultWarmup.Text := Val
        else if Key = 'market_open' then edtMarketOpen.Text := Val
        else if Key = 'market_close' then edtMarketClose.Text := Val
        else if Key = 'force_exit' then edtForceExit.Text := Val
        else if Key = 'entry_start' then edtEntryStart.Text := Val
        else if Key = 'entry_end' then edtEntryEnd.Text := Val;
      end;
    end;
    CloseFile(F);
  except
  end;
end;

procedure TfrmDashboard.SaveSettings;
var
  F: TextFile;
begin
  ForceDirectories(ExtractFilePath(SettingsPath));
  AssignFile(F, SettingsPath);
  try
    Rewrite(F);
    WriteLn(F, 'broker=' + cbxBroker.Text);
    WriteLn(F, 'token=' + edtToken.Text);
    WriteLn(F, 'api_key=' + edtApiKey.Text);
    if chkAutoConnect.Checked then WriteLn(F, 'auto_connect=1')
    else WriteLn(F, 'auto_connect=0');
    WriteLn(F, 'daily_loss_limit=' + edtDailyLossLimit.Text);
    WriteLn(F, 'max_exposure=' + edtMaxExposure.Text);
    WriteLn(F, 'strategy_loss_limit=' + edtStrategyLossLimit.Text);
    WriteLn(F, 'max_symbol_exposure=' + edtMaxSymbolExposure.Text);
    WriteLn(F, 'max_orders_per_sec=' + edtMaxOrdersPerSec.Text);
    WriteLn(F, 'max_open_orders=' + edtMaxOpenOrders.Text);
    if chkRiskEnabled.Checked then WriteLn(F, 'risk_enabled=1')
    else WriteLn(F, 'risk_enabled=0');
    WriteLn(F, 'drain_interval=' + edtDrainInterval.Text);
    WriteLn(F, 'poll_interval=' + edtPollInterval.Text);
    WriteLn(F, 'state_save_interval=' + edtStateSaveInterval.Text);
    WriteLn(F, 'default_warmup=' + edtDefaultWarmup.Text);
    WriteLn(F, 'market_open=' + edtMarketOpen.Text);
    WriteLn(F, 'market_close=' + edtMarketClose.Text);
    WriteLn(F, 'force_exit=' + edtForceExit.Text);
    WriteLn(F, 'entry_start=' + edtEntryStart.Text);
    WriteLn(F, 'entry_end=' + edtEntryEnd.Text);
    CloseFile(F);
  except
    on E: Exception do Log('Save failed: ' + AnsiString(E.Message));
  end;
end;

{ ═══════════════════════════════════════════════════════════════════ }
{  Bot persistence                                                    }
{ ═══════════════════════════════════════════════════════════════════ }

procedure TfrmDashboard.SaveBots;
var
  JArr: TJSONArray;
  JBot, JParams: TJSONObject;
  I, J: Integer;
  Bot: TRunningBot;
  Params: TArray<TStrategyParam>;
  S: TJSONStringType;
  F: TextFile;
begin
  JArr := TJSONArray.Create;
  try
    for I := 0 to FBots.Count - 1 do
    begin
      Bot := FBots[I];
      JBot := TJSONObject.Create;
      JBot.Add('strategy', string(Bot.StrategyName));
      JBot.Add('underlying', string(Bot.Underlying));
      if Bot.Strategy <> nil then
        JBot.Add('lots', Bot.Strategy.Lots)
      else
        JBot.Add('lots', 1);

      if Bot.Strategy <> nil then
        JBot.Add('warmup', Bot.Strategy.WarmupTicks)
      else
        JBot.Add('warmup', 50);

      JParams := TJSONObject.Create;
      { Get param values from the live strategy if available }
      if Bot.Strategy <> nil then
      begin
        Params := Bot.Strategy.DeclareParams;
        if Params <> nil then
          for J := 0 to High(Params) do
            JParams.Add(string(Params[J].Name),
              string(Bot.Strategy.GetParamValue(Params[J].Name)));
      end;
      JBot.Add('params', JParams);
      JArr.Add(JBot);
    end;

    S := JArr.FormatJSON;
    ForceDirectories(ExtractFilePath(BotsPath));
    AssignFile(F, BotsPath);
    try
      Rewrite(F);
      Write(F, S);
      CloseFile(F);
    except
      on E: Exception do Log('SaveBots failed: ' + AnsiString(E.Message));
    end;
  finally
    JArr.Free;
  end;
end;

procedure TfrmDashboard.LoadBots;
var
  F: TextFile;
  S, Line: string;
  JData: TJSONData;
  JArr: TJSONArray;
  JBot, JParams: TJSONObject;
  I, J, RegIdx, Row: Integer;
  Regs: TArray<TStrategyRegistration>;
  Bot: TRunningBot;
  StratName: AnsiString;
begin
  if not FileExists(BotsPath) then Exit;

  S := '';
  AssignFile(F, BotsPath);
  try
    Reset(F);
    while not Eof(F) do
    begin
      ReadLn(F, Line);
      S := S + Line;
    end;
    CloseFile(F);
  except
    Exit;
  end;

  if S = '' then Exit;

  try
    JData := GetJSON(S);
  except
    Exit;
  end;

  try
    if not (JData is TJSONArray) then Exit;
    JArr := JData as TJSONArray;
    Regs := GetRegisteredStrategies;

    for I := 0 to JArr.Count - 1 do
    begin
      if not (JArr.Items[I] is TJSONObject) then Continue;
      JBot := JArr.Objects[I];

      StratName := AnsiString(JBot.Get('strategy', ''));
      RegIdx := -1;
      for J := 0 to High(Regs) do
        if Regs[J].Name = StratName then begin RegIdx := J; Break; end;
      if RegIdx < 0 then Continue;

      Bot.Name := AnsiString(Format('bot-%d', [FBots.Count + 1]));
      Bot.StrategyName := StratName;
      Bot.Underlying := AnsiString(JBot.Get('underlying', ''));
      Bot.Strategy := Regs[RegIdx].StrategyClass.Create;
      Bot.Strategy.Name := Bot.Name;
      Bot.Strategy.Underlying := Bot.Underlying;
      Bot.Strategy.Lots := JBot.Get('lots', 1);
      Bot.Strategy.WarmupTicks := JBot.Get('warmup', 50);
      Bot.Thread := nil;
      Bot.SlotIndex := -1;
      Bot.Running := False;

      { Apply params }
      JParams := JBot.Get('params', TJSONObject(nil));
      if JParams <> nil then
        for J := 0 to JParams.Count - 1 do
          Bot.Strategy.ApplyParam(
            AnsiString(JParams.Names[J]),
            AnsiString(JParams.Items[J].AsString));

      FBots.Add(Bot);

      Row := gridStrategies.RowCount;
      gridStrategies.RowCount := Row + 1;
      gridStrategies.Cells[0, Row] := string(Bot.Name);
      gridStrategies.Cells[1, Row] := string(Bot.StrategyName);
      gridStrategies.Cells[2, Row] := string(Bot.Underlying);
      gridStrategies.Cells[3, Row] := IntToStr(Bot.Strategy.Lots);
      gridStrategies.Cells[4, Row] := #$E2#$97#$8B + ' Stopped';
    end;
  finally
    JData.Free;
  end;
end;

end.
