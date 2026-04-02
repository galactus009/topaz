# XGBoost.Wrapper.pas — Free Pascal API Reference

OOP wrapper over XGBoost's C API. Dynamic linking via `DynLibs` — loads `libxgboost` at runtime. Zero compile-time dependency. Compiles with FreePascal 3.2+ and Delphi XE2+.

## Setup

### Install XGBoost

```bash
# macOS
brew install xgboost

# Linux (Ubuntu/Debian)
apt install libxgboost-dev

# Or via pip (library lands in the Python site-packages)
pip install xgboost
```

### Add to your project

Add `modules/XGBoost.Wrapper.pas` to your uses clause:

```pascal
uses XGBoost.Wrapper;
```

No other units needed. The library is loaded on first use of `TDMatrix` or `TBooster`.

---

## Library Management

```pascal
// Auto-loaded on first use — usually you don't need these
procedure LoadXGBoost(const APath: AnsiString = '');
procedure UnloadXGBoost;
function XGBoostLoaded: Boolean;
```

The library is auto-loaded when you create the first `TDMatrix` or `TBooster`. To load from a custom path:

```pascal
// Load from Homebrew location
LoadXGBoost('/opt/homebrew/lib/libxgboost.dylib');

// Load from Python site-packages
LoadXGBoost('/path/to/site-packages/xgboost/lib/libxgboost.dylib');
```

Automatically unloaded in the `finalization` section.

---

## TDMatrix

Feature matrix — holds training/test data and associated labels/weights.

### Constructor

```pascal
constructor Create(const AData: array of Single; ARows, ACols: Integer;
  AMissing: Single = 0);
```

| Param | Description |
|-------|-------------|
| `AData` | Row-major flat array of features (`ARows * ACols` elements) |
| `ARows` | Number of samples |
| `ACols` | Number of features |
| `AMissing` | Value treated as missing (default `0`, use `NaN` for real missing) |

### Methods

```pascal
procedure SetLabels(const ALabels: array of Single);
procedure SetWeights(const AWeights: array of Single);
procedure SetFloatInfo(const AField: AnsiString; const AValues: array of Single);
function RowCount: Int64;
function ColCount: Int64;
```

| Method | Description |
|--------|-------------|
| `SetLabels` | Set target values (length must equal `ARows`) |
| `SetWeights` | Set sample weights (length must equal `ARows`) |
| `SetFloatInfo` | Set arbitrary float info: `'label'`, `'weight'`, `'base_margin'` |
| `RowCount` | Number of rows in the matrix |
| `ColCount` | Number of columns in the matrix |

---

## TBooster

Gradient boosted tree model — train, predict, save, load.

### Constructor

```pascal
constructor Create(const AMatrices: array of TDMatrix);
```

Pass one or more `TDMatrix` objects to cache. Typically just the training matrix.

### Methods

```pascal
procedure SetParam(const AName, AValue: AnsiString);
procedure Train(ATrain: TDMatrix; ARounds: Integer);
procedure UpdateOneIter(AIter: Integer; ATrain: TDMatrix);
function Predict(AData: TDMatrix; AOptionMask: Integer = 0;
  ANTreeLimit: Cardinal = 0): TSingleArray;
procedure SaveModel(const APath: AnsiString);
procedure LoadModel(const APath: AnsiString);
```

| Method | Description |
|--------|-------------|
| `SetParam` | Set a hyperparameter (all values are strings) |
| `Train` | Train for `ARounds` iterations (calls `UpdateOneIter` in a loop) |
| `UpdateOneIter` | Single boosting iteration (for custom training loops) |
| `Predict` | Return predictions as `TSingleArray` |
| `SaveModel` | Save model to file (`.json`, `.ubj`, or `.bin`) |
| `LoadModel` | Load model from file |

### Predict Options

| `AOptionMask` | Output |
|---------------|--------|
| `0` | Normal prediction |
| `1` | Raw margin values |
| `2` | Leaf indices |
| `4` | Feature contributions (SHAP values) |

Set `ANTreeLimit` to limit how many trees are used (0 = all).

---

## Parameters Reference

Set via `Booster.SetParam('name', 'value')`. All values are strings.

### Core

| Parameter | Default | Description |
|-----------|---------|-------------|
| `eta` | `0.3` | Learning rate (0–1) |
| `max_depth` | `6` | Maximum tree depth |
| `min_child_weight` | `1` | Minimum sum of instance weight in a child |
| `subsample` | `1` | Row subsampling ratio (0–1) |
| `colsample_bytree` | `1` | Column subsampling ratio per tree (0–1) |
| `lambda` | `1` | L2 regularization |
| `alpha` | `0` | L1 regularization |
| `nthread` | all | Number of threads |
| `seed` | `0` | Random seed |

### Objective Functions

| Value | Task |
|-------|------|
| `reg:squarederror` | Regression (MSE) |
| `reg:squaredlogerror` | Regression (MSLE) |
| `binary:logistic` | Binary classification (probability output) |
| `binary:hinge` | Binary classification (0/1 output) |
| `multi:softmax` | Multiclass (requires `num_class`) |
| `multi:softprob` | Multiclass probabilities (requires `num_class`) |
| `rank:pairwise` | Learning to rank |

### Evaluation Metrics

| Value | Description |
|-------|-------------|
| `rmse` | Root mean squared error |
| `mae` | Mean absolute error |
| `logloss` | Log loss |
| `auc` | Area under ROC curve |
| `error` | Binary classification error rate |
| `merror` | Multiclass error rate |

---

## Error Handling

All methods raise `EXGBoostError` on failure with the XGBoost error message:

```pascal
try
  Booster.Train(DM, 100);
except
  on E: EXGBoostError do
    WriteLn('XGBoost error: ', E.Message);
end;
```

---

## Examples

### 1. Regression — Predict House Prices

```pascal
program HousePrice;

{$mode Delphi}{$H+}

uses
  SysUtils, XGBoost.Wrapper;

const
  ROWS = 6;
  COLS = 3;  // sqft, bedrooms, age

var
  Features: array[0..ROWS*COLS-1] of Single = (
    1400, 3, 10,
    1600, 3,  5,
    1700, 4,  8,
    1875, 4,  3,
    1100, 2, 15,
    1550, 3,  7
  );
  Labels: array[0..ROWS-1] of Single = (
    245000, 312000, 279000, 308000, 199000, 268000
  );

var
  DM: TDMatrix;
  Model: TBooster;
  Preds: TSingleArray;
  I: Integer;
begin
  DM := TDMatrix.Create(Features, ROWS, COLS);
  DM.SetLabels(Labels);
  try
    Model := TBooster.Create([DM]);
    try
      Model.SetParam('objective', 'reg:squarederror');
      Model.SetParam('max_depth', '4');
      Model.SetParam('eta', '0.1');

      Model.Train(DM, 200);

      Preds := Model.Predict(DM);
      for I := 0 to High(Preds) do
        WriteLn(Format('Sample %d: actual=%.0f predicted=%.0f',
          [I, Labels[I], Preds[I]]));

      Model.SaveModel('house_price.json');
    finally
      Model.Free;
    end;
  finally
    DM.Free;
  end;
end.
```

### 2. Binary Classification — Buy/Sell Signal

```pascal
program BuySellSignal;

{$mode Delphi}{$H+}

uses
  SysUtils, XGBoost.Wrapper;

const
  ROWS = 8;
  COLS = 4;  // rsi, macd, volume_ratio, spread

var
  Features: array[0..ROWS*COLS-1] of Single = (
    30, -2.5, 1.8, 0.05,   // oversold, bearish MACD, high volume
    72,  1.2, 0.9, 0.02,   // overbought, bullish
    45,  0.1, 1.0, 0.03,   // neutral
    25, -3.1, 2.2, 0.08,   // deeply oversold
    68,  2.0, 0.7, 0.01,   // overbought
    35, -1.0, 1.5, 0.04,   // slightly oversold
    80,  3.5, 0.5, 0.01,   // very overbought
    50,  0.0, 1.1, 0.03    // neutral
  );
  // 1.0 = price went up (buy was correct), 0.0 = price went down
  Labels: array[0..ROWS-1] of Single = (
    1, 0, 0, 1, 0, 1, 0, 0
  );

var
  DM: TDMatrix;
  Model: TBooster;
  Preds: TSingleArray;
  I: Integer;
begin
  DM := TDMatrix.Create(Features, ROWS, COLS);
  DM.SetLabels(Labels);
  try
    Model := TBooster.Create([DM]);
    try
      Model.SetParam('objective', 'binary:logistic');
      Model.SetParam('max_depth', '3');
      Model.SetParam('eta', '0.3');
      Model.SetParam('eval_metric', 'logloss');

      Model.Train(DM, 50);

      Preds := Model.Predict(DM);
      for I := 0 to High(Preds) do
        WriteLn(Format('Sample %d: prob=%.3f signal=%s',
          [I, Preds[I], IfThen(Preds[I] > 0.5, 'BUY', 'SELL')]));

      Model.SaveModel('signal_model.json');
    finally
      Model.Free;
    end;
  finally
    DM.Free;
  end;
end.
```

### 3. Train Once, Predict Many — Load Saved Model

```pascal
program PredictFromModel;

{$mode Delphi}{$H+}

uses
  SysUtils, XGBoost.Wrapper;

const
  COLS = 4;

var
  // Single new sample to predict
  Sample: array[0..COLS-1] of Single = (42, -0.5, 1.3, 0.04);

var
  DM: TDMatrix;
  Model: TBooster;
  Preds: TSingleArray;
  EmptyDM: TDMatrix;
begin
  // Create a dummy DMatrix to initialize the booster
  EmptyDM := TDMatrix.Create(Sample, 1, COLS);
  try
    Model := TBooster.Create([EmptyDM]);
    try
      Model.LoadModel('signal_model.json');

      // Create DMatrix for the new sample
      DM := TDMatrix.Create(Sample, 1, COLS);
      try
        Preds := Model.Predict(DM);
        WriteLn(Format('Prediction: %.4f → %s',
          [Preds[0], IfThen(Preds[0] > 0.5, 'BUY', 'SELL')]));
      finally
        DM.Free;
      end;
    finally
      Model.Free;
    end;
  finally
    EmptyDM.Free;
  end;
end.
```

### 4. Custom Training Loop with Validation

```pascal
program CustomTraining;

{$mode Delphi}{$H+}

uses
  SysUtils, Math, XGBoost.Wrapper;

procedure TrainWithValidation(
  const TrainData, TrainLabels: array of Single; TrainRows: Integer;
  const ValData, ValLabels: array of Single; ValRows: Integer;
  NCols, NRounds: Integer);
var
  DTrain, DVal: TDMatrix;
  Model: TBooster;
  Preds: TSingleArray;
  I, R: Integer;
  MSE: Double;
begin
  DTrain := TDMatrix.Create(TrainData, TrainRows, NCols);
  DTrain.SetLabels(TrainLabels);
  DVal := TDMatrix.Create(ValData, ValRows, NCols);
  DVal.SetLabels(ValLabels);
  try
    Model := TBooster.Create([DTrain, DVal]);
    try
      Model.SetParam('objective', 'reg:squarederror');
      Model.SetParam('max_depth', '5');
      Model.SetParam('eta', '0.1');
      Model.SetParam('subsample', '0.8');
      Model.SetParam('colsample_bytree', '0.8');

      for R := 0 to NRounds - 1 do
      begin
        Model.UpdateOneIter(R, DTrain);

        // Evaluate on validation set every 10 rounds
        if (R + 1) mod 10 = 0 then
        begin
          Preds := Model.Predict(DVal);
          MSE := 0;
          for I := 0 to High(Preds) do
            MSE := MSE + Sqr(Preds[I] - ValLabels[I]);
          MSE := MSE / Length(Preds);
          WriteLn(Format('[%3d] val-rmse=%.4f', [R + 1, Sqrt(MSE)]));
        end;
      end;

      Model.SaveModel('validated_model.json');
    finally
      Model.Free;
    end;
  finally
    DTrain.Free;
    DVal.Free;
  end;
end;
```

### 5. Multiclass Classification

```pascal
program MultiClass;

{$mode Delphi}{$H+}

uses
  SysUtils, XGBoost.Wrapper;

const
  ROWS = 6;
  COLS = 2;
  NCLASS = 3;

var
  Features: array[0..ROWS*COLS-1] of Single = (
    1.0, 2.0,
    1.5, 1.8,
    5.0, 8.0,
    6.0, 9.0,
    9.0, 1.0,
    8.5, 1.5
  );
  Labels: array[0..ROWS-1] of Single = (
    0, 0, 1, 1, 2, 2  // three classes
  );

var
  DM: TDMatrix;
  Model: TBooster;
  Preds: TSingleArray;
  I: Integer;
begin
  DM := TDMatrix.Create(Features, ROWS, COLS);
  DM.SetLabels(Labels);
  try
    Model := TBooster.Create([DM]);
    try
      Model.SetParam('objective', 'multi:softmax');
      Model.SetParam('num_class', IntToStr(NCLASS));
      Model.SetParam('max_depth', '3');
      Model.SetParam('eta', '0.3');

      Model.Train(DM, 50);

      Preds := Model.Predict(DM);
      for I := 0 to High(Preds) do
        WriteLn(Format('Sample %d: actual=%d predicted=%d',
          [I, Round(Labels[I]), Round(Preds[I])]));
    finally
      Model.Free;
    end;
  finally
    DM.Free;
  end;
end.
```

### 6. Feature Importance (SHAP Contributions)

```pascal
// After training a model:
var
  Contribs: TSingleArray;
  I, J, NCols: Integer;
begin
  NCols := DM.ColCount;

  // option_mask=4 returns SHAP values
  // Output shape: ROWS * (COLS + 1) — last column is bias
  Contribs := Model.Predict(DM, 4);

  for I := 0 to DM.RowCount - 1 do
  begin
    Write(Format('Sample %d contributions: ', [I]));
    for J := 0 to NCols do  // NCols+1 values per row (last is bias)
      Write(Format('%.3f ', [Contribs[I * (NCols + 1) + J]]));
    WriteLn;
  end;
end;
```

---

## Integration with Topaz Strategies

Use XGBoost inside a strategy's `OnStart`/`OnTick` to generate ML-based signals:

```pascal
unit Topaz.Strategy.MLSignal;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Apollo.Broker, Topaz.EventTypes, Topaz.Strategy, XGBoost.Wrapper;

type
  TMLSignalStrategy = class(TStrategy)
  private
    FModel: TBooster;
    FFeatureWindow: array[0..3] of Single;  // rsi, macd, vol_ratio, spread
    FDummyDM: TDMatrix;
  protected
    procedure OnStart; override;
    procedure OnTick(const ATick: TTickEvent); override;
    procedure OnStop; override;
  end;

implementation

procedure TMLSignalStrategy.OnStart;
var
  Zeros: array[0..3] of Single;
begin
  FillChar(Zeros, SizeOf(Zeros), 0);
  FDummyDM := TDMatrix.Create(Zeros, 1, 4);
  FModel := TBooster.Create([FDummyDM]);
  FModel.LoadModel('signal_model.json');
end;

procedure TMLSignalStrategy.OnTick(const ATick: TTickEvent);
var
  DM: TDMatrix;
  Preds: TSingleArray;
begin
  // Update feature window from tick data
  // (compute RSI, MACD, etc. from price history — omitted for brevity)
  FFeatureWindow[0] := 42;   // RSI
  FFeatureWindow[1] := -0.5; // MACD
  FFeatureWindow[2] := 1.3;  // Volume ratio
  FFeatureWindow[3] := ATick.Ask - ATick.Bid;  // Spread

  DM := TDMatrix.Create(FFeatureWindow, 1, 4);
  try
    Preds := FModel.Predict(DM);
    if Preds[0] > 0.7 then
      Buy(Underlying, Lots, 0, exNSE)
    else if Preds[0] < 0.3 then
      Sell(Underlying, Lots, 0, exNSE);
  finally
    DM.Free;
  end;
end;

procedure TMLSignalStrategy.OnStop;
begin
  FModel.Free;
  FDummyDM.Free;
end;

initialization
  RegisterStrategy('MLSignal', TMLSignalStrategy);

end.
```

---

## Model File Formats

| Extension | Format | Notes |
|-----------|--------|-------|
| `.json` | JSON | Human-readable, recommended for debugging |
| `.ubj` | UBJSON | Binary, smaller than JSON |
| `.bin` | Legacy binary | Deprecated, use `.json` or `.ubj` |

The format is auto-detected from the file extension.

---

## Thread Safety

- `TDMatrix` and `TBooster` instances are **not** thread-safe
- Create separate instances per thread for parallel prediction
- The global `LoadXGBoost`/`UnloadXGBoost` should only be called once (auto-handled)
- `Predict` returns a copy of XGBoost's internal buffer — safe to use after the call

---

## Platform Notes

| Platform | Library | Install |
|----------|---------|---------|
| macOS (arm64) | `libxgboost.dylib` | `brew install xgboost` |
| macOS (x86_64) | `libxgboost.dylib` | `brew install xgboost` |
| Linux | `libxgboost.so` | `apt install libxgboost-dev` |
| Windows | `xgboost.dll` | Download from XGBoost releases |

If the library is not in the default search path, pass the full path to `LoadXGBoost`:

```pascal
LoadXGBoost('/opt/homebrew/lib/libxgboost.dylib');
```
