"""
Bridge SCADA <-> OpenPLC per l'impianto chimico.

    browser (index.html: modello d'impianto + HMI)
        |  WebSocket  ws://<host>:8080/ws   (JSON)
    bridge.py
        |  Modbus TCP  (client)  ->  OpenPLC runtime, porta 502
    OpenPLC (programma impianto_chimico.st)

A ogni ciclo (50 ms di default) il bridge:
  1. scrive i 10 ingressi del campo nei registri %MW0..%MW9
     (holding register 1024..1033 del server Modbus di OpenPLC);
  2. legge le 8 uscite digitali %QX0.0..%QX0.7 (coil 0..7);
  3. legge i 6 registri %QW0..%QW5 (holding register 0..5);
  4. invia le uscite a tutti i browser collegati.

Se OpenPLC non risponde, al browser arriva plc=false e il modello
d'impianto tratta tutte le uscite come spente (condizione sicura).

Avvio:   uv run bridge.py                       (OpenPLC su localhost:502)
         uv run bridge.py --plc 192.168.1.50 --port 502 --http 8080
Poi apri http://localhost:8080 e scegli "OpenPLC" in alto.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import logging
import time
from pathlib import Path

from aiohttp import WSMsgType, web
from pymodbus.client import AsyncModbusTcpClient

# ---------------------------------------------------------------- mappa I/O
MW_BASE = 1024   # %MW0 -> holding register 1024 (OpenPLC)
N_IN = 10        # %MW0..%MW9
COIL_BASE = 0    # %QX0.0 -> coil 0
N_COILS = 8      # %QX0.0..%QX0.7
QW_BASE = 0      # %QW0 -> holding register 0
N_QW = 6         # %QW0..%QW5

HMI_DIR = Path(__file__).resolve().parent.parent / "hmi"
log = logging.getLogger("bridge")


def to_u16(v: int) -> int:
    v = int(v)
    v = max(-32768, min(32767, v))
    return v & 0xFFFF


def to_s16(v: int) -> int:
    return v - 0x10000 if v & 0x8000 else v


class Bridge:
    def __init__(self, host: str, port: int, period: float):
        self.host, self.port, self.period = host, port, period
        self.inputs = [0, 1, 1, 0, 0, 0, 0, 0, 1, 200]  # STOP/EMERG/FR NC chiusi
        self.inputs_at = 0.0
        self.clients: set[web.WebSocketResponse] = set()
        self.plc_ok = False
        self.client: AsyncModbusTcpClient | None = None
        self.cycle_ms = 0.0

    async def ensure_client(self) -> bool:
        if self.client and self.client.connected:
            return True
        if self.client:
            self.client.close()
        self.client = AsyncModbusTcpClient(self.host, port=self.port, timeout=1, retries=0)
        try:
            await self.client.connect()
        except Exception as e:  # noqa: BLE001
            log.debug("connect: %s", e)
        return bool(self.client.connected)

    async def cycle(self) -> dict:
        out = {"t": "out", "plc": False, "qx": [0] * N_COILS, "qw": [0] * N_QW}
        if not await self.ensure_client():
            return out
        c = self.client
        assert c is not None
        # se il browser tace da più di 2 s (scheda chiusa) l'impianto è "spento":
        # mando STOP premuto per sicurezza
        ins = list(self.inputs)
        if time.monotonic() - self.inputs_at > 2.0:
            ins[0], ins[1], ins[3] = 0, 0, 0
        w = await c.write_registers(MW_BASE, [to_u16(v) for v in ins])
        r1 = await c.read_coils(COIL_BASE, count=N_COILS)
        r2 = await c.read_holding_registers(QW_BASE, count=N_QW)
        if w.isError() or r1.isError() or r2.isError():
            raise RuntimeError(f"risposta Modbus di errore: {w} {r1} {r2}")
        out["plc"] = True
        out["qx"] = [int(b) for b in r1.bits[:N_COILS]]
        out["qw"] = [to_s16(v) for v in r2.registers[:N_QW]]
        return out

    async def run(self):
        last_state = None
        while True:
            t0 = time.monotonic()
            try:
                out = await self.cycle()
            except Exception as e:  # noqa: BLE001
                log.warning("Modbus: %s", e)
                if self.client:
                    self.client.close()
                out = {"t": "out", "plc": False, "qx": [0] * N_COILS, "qw": [0] * N_QW}
            self.plc_ok = out["plc"]
            if self.plc_ok != last_state:
                log.info("OpenPLC %s:%s %s", self.host, self.port,
                         "IN LINEA" if self.plc_ok else "NON raggiungibile")
                last_state = self.plc_ok
            self.cycle_ms = (time.monotonic() - t0) * 1000
            out["ms"] = round(self.cycle_ms, 1)
            msg = json.dumps(out)
            for ws in list(self.clients):
                try:
                    await ws.send_str(msg)
                except Exception:  # noqa: BLE001
                    self.clients.discard(ws)
            dt = self.period - (time.monotonic() - t0)
            await asyncio.sleep(dt if dt > 0 else (0.5 if not self.plc_ok else 0))


async def ws_handler(request: web.Request):
    br: Bridge = request.app["bridge"]
    ws = web.WebSocketResponse(heartbeat=10)
    await ws.prepare(request)
    br.clients.add(ws)
    log.info("browser collegato (%d)", len(br.clients))
    try:
        async for msg in ws:
            if msg.type == WSMsgType.TEXT:
                try:
                    m = json.loads(msg.data)
                except ValueError:
                    continue
                if m.get("t") == "in" and isinstance(m.get("mw"), list) and len(m["mw"]) == N_IN:
                    br.inputs = [int(v) for v in m["mw"]]
                    br.inputs_at = time.monotonic()
    finally:
        br.clients.discard(ws)
        log.info("browser scollegato (%d)", len(br.clients))
    return ws


async def index(_request):
    return web.FileResponse(HMI_DIR / "index.html")


async def on_start(app):
    app["task"] = asyncio.create_task(app["bridge"].run())


async def on_stop(app):
    app["task"].cancel()


def main():
    ap = argparse.ArgumentParser(description="Bridge SCADA <-> OpenPLC (Modbus TCP)")
    ap.add_argument("--plc", default="127.0.0.1", help="indirizzo del runtime OpenPLC")
    ap.add_argument("--port", type=int, default=502, help="porta Modbus TCP di OpenPLC")
    ap.add_argument("--http", type=int, default=8080, help="porta della pagina SCADA")
    ap.add_argument("--period", type=float, default=0.05, help="periodo di scambio in s")
    ap.add_argument("-v", "--verbose", action="store_true")
    a = ap.parse_args()
    logging.basicConfig(level=logging.DEBUG if a.verbose else logging.INFO,
                        format="%(asctime)s  %(message)s", datefmt="%H:%M:%S")
    logging.getLogger("pymodbus").setLevel(logging.CRITICAL)

    app = web.Application()
    app["bridge"] = Bridge(a.plc, a.port, a.period)
    app.router.add_get("/", index)
    app.router.add_get("/ws", ws_handler)
    app.on_startup.append(on_start)
    app.on_cleanup.append(on_stop)
    log.info("SCADA su http://localhost:%d  ·  OpenPLC atteso su %s:%d", a.http, a.plc, a.port)
    web.run_app(app, port=a.http, print=None)


if __name__ == "__main__":
    main()
