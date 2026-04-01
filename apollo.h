/**
 * Apollo CFFI — Broker-agnostic trading API for Indian markets.
 *
 * Supports: Upstox, Kite (Zerodha), Fyers, INDmoney, Dhan
 *
 * Build: cargo build --release -p apollo-cffi
 *   → libapollo.dylib (macOS) / libapollo.so (Linux) / apollo.dll (Windows)
 *
 * All symbol arguments use canonical names (broker-agnostic):
 *   Equity:  "RELIANCE", "INFY", "NIFTYBEES"
 *   Index:   "NIFTY 50", "BANK NIFTY"
 *   Options/Futures: resolved via resolve_option() / nearest_expiry()
 *
 * Exchange enum: 0=NSE, 1=BSE, 2=NFO, 3=BFO, 4=MCX, 5=CDS
 * Side enum:     0=Buy, 1=Sell
 * OrderType:     0=Market, 1=Limit, 2=StopLoss, 3=StopLimit
 * Product:       0=CNC/Delivery, 1=Intraday/MIS, 2=Margin/NRML
 * Validity:      0=Day, 1=IOC
 * SubMode:       0=LTP, 1=Quote, 2=Full+Depth
 * OptionType:    0=None, 1=Call, 2=Put
 */

#ifndef APOLLO_H
#define APOLLO_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Opaque handle — one per broker session */
typedef void* handle_t;

/* ── Lifecycle ─────────────────────────────────────────────── */

handle_t    create(const char* broker, const char* access_token, const char* api_key);
void        free_handle(handle_t h);
const char* last_error(handle_t h);
int         version(void);

/* ── Connection ────────────────────────────────────────────── */

int  connect(handle_t h);
int  disconnect(handle_t h);
int  is_connected(handle_t h);

/* ── Catalog & Symbology ───────────────────────────────────── */

int         catalog_count(handle_t h);
int         catalog_find(handle_t h, const char* symbol, int exchange);
const char* catalog_symbol(handle_t h, int symbol_id);
const char* catalog_broker_key(handle_t h, int symbol_id);
const char* instrument_json(handle_t h, int symbol_id);
int64_t     nearest_expiry(handle_t h, const char* underlying, int exchange);
const char* list_expiries_json(handle_t h, const char* underlying, int exchange);
double      atm_strike(handle_t h, const char* underlying, int64_t expiry_unix, double spot);
const char* list_strikes_json(handle_t h, const char* underlying, int64_t expiry_unix, int exchange);
int         resolve_option(handle_t h, const char* underlying, int64_t expiry_unix,
                           double strike, int option_type, int exchange);
const char* search_json(handle_t h, const char* query, int exchange, int max_results);

/* ── Symbol Mapping ────────────────────────────────────────── */

const char* to_broker_key(handle_t h, const char* canonical);
const char* from_broker_key(handle_t h, const char* broker_key);
const char* to_canonical(handle_t h, int symbol_id);
int         from_canonical(handle_t h, const char* canonical);

/* ── Market Data (REST) ────────────────────────────────────── */

double      ltp(handle_t h, const char* symbol, int exchange);
const char* history_json(handle_t h, const char* symbol, int exchange,
                         const char* from_date, const char* to_date, const char* interval);
const char* positions_json(handle_t h);
const char* funds_json(handle_t h);
double      available_margin(handle_t h);
double      used_margin(handle_t h);

/* ── Streaming (WebSocket) ─────────────────────────────────── */

typedef void (*tick_cb)(void* user_data, int symbol_id,
                        double ltp, double bid, double ask,
                        int64_t volume, int64_t oi);
typedef void (*depth_cb)(void* user_data, int symbol_id, const char* json);
typedef void (*candle_cb)(void* user_data, int symbol_id, const char* json);
typedef void (*order_cb)(void* user_data, const char* json);
typedef void (*connect_cb)(void* user_data, const char* feed);
typedef void (*disconnect_cb)(void* user_data, const char* feed, const char* reason);

void set_callbacks(handle_t h, void* user_data,
                   tick_cb on_tick, depth_cb on_depth,
                   candle_cb on_candle, order_cb on_order,
                   connect_cb on_connect, disconnect_cb on_disconnect);

int     stream_start(handle_t h);
void    stream_stop(handle_t h);
int     subscribe(handle_t h, const char* symbol, int exchange, int mode);
int     unsubscribe(handle_t h, const char* symbol, int exchange);
int     subscribe_orders(handle_t h);
int64_t tick_count(handle_t h);

/* ── Orders ────────────────────────────────────────────────── */

const char* place_order(handle_t h,
                        const char* symbol, int exchange,
                        int side, int order_type, int product, int validity,
                        int qty, double price, double trigger_price,
                        const char* tag);
int  modify_order(handle_t h, const char* order_id,
                  int order_type, int qty, double price, double trigger_price);
int  cancel_order(handle_t h, const char* order_id);
int  exit_position(handle_t h, const char* symbol, int exchange);

/* ── Utility ───────────────────────────────────────────────── */

const char* broker_name(handle_t h);
int         set_token(handle_t h, const char* new_token);

#ifdef __cplusplus
}
#endif

#endif /* APOLLO_H */
