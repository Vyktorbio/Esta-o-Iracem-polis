#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Proxy local NDVI/NDRE/GNDVI — Estação Iracemápolis
==================================================
Conversa com o Sentinel Hub (Copernicus Data Space Ecosystem) usando SUA credencial,
sem expor o segredo no navegador. Usa só a biblioteca padrão do Python (nada pra instalar).

COMO USAR
---------
1) Crie a conta gratuita em https://dataspace.copernicus.eu  e gere um OAuth client em
   https://shapps.dataspace.copernicus.eu/dashboard  (User settings -> OAuth clients).
2) Crie um arquivo  ndvi-credenciais.json  nesta mesma pasta, assim:
       { "client_id": "SEU_CLIENT_ID", "client_secret": "SEU_CLIENT_SECRET" }
   (ou defina as variáveis de ambiente SH_CLIENT_ID e SH_CLIENT_SECRET)
3) Rode:   python3 ndvi-proxy.py
4) Deixe rodando e abra o app (index.html). Pronto.

Endpoints (uso interno do app):
  GET /health
  GET /dates?bbox=w,s,e,n&from=YYYY-MM-DD&to=YYYY-MM-DD
  GET /index?index=NDVI|NDRE|GNDVI&date=YYYY-MM-DD&bbox=w,s,e,n&width=1024
  GET /stats?index=NDVI&from=YYYY-MM-DD&to=YYYY-MM-DD&geom=<GeoJSON urlencoded>
"""
import json, os, time, urllib.request, urllib.parse, urllib.error
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("PORT", "8799"))
HOST = "0.0.0.0" if os.environ.get("PORT") else "127.0.0.1"  # nuvem (Render) usa $PORT e 0.0.0.0; local fica em 127.0.0.1
HERE = os.path.dirname(os.path.abspath(__file__))
TOKEN_URL = "https://identity.dataspace.copernicus.eu/auth/realms/CDSE/protocol/openid-connect/token"
PROCESS_URL = "https://sh.dataspace.copernicus.eu/process/v1"
STATS_URL   = "https://sh.dataspace.copernicus.eu/statistics/v1"
CATALOG_URL = "https://sh.dataspace.copernicus.eu/catalog/v1/search"
CRS84 = "http://www.opengis.net/def/crs/OGC/1.3/CRS84"

# ---------------------------------------------------------------- credenciais
def load_creds():
    cid = os.environ.get("SH_CLIENT_ID")
    csec = os.environ.get("SH_CLIENT_SECRET")
    if cid and csec:
        return cid, csec
    p = os.path.join(HERE, "ndvi-credenciais.json")
    if os.path.exists(p):
        try:
            d = json.load(open(p, encoding="utf-8"))
            return d.get("client_id"), d.get("client_secret")
        except Exception as e:
            print("Erro lendo ndvi-credenciais.json:", e)
    return None, None

_token = {"value": None, "exp": 0}
def get_token():
    if _token["value"] and time.time() < _token["exp"] - 60:
        return _token["value"]
    cid, csec = load_creds()
    if not cid or not csec:
        raise RuntimeError("SEM_CREDENCIAL")
    body = urllib.parse.urlencode({
        "grant_type": "client_credentials",
        "client_id": cid,
        "client_secret": csec,
    }).encode()
    req = urllib.request.Request(TOKEN_URL, data=body,
                                 headers={"Content-Type": "application/x-www-form-urlencoded"})
    with urllib.request.urlopen(req, timeout=30) as r:
        d = json.loads(r.read().decode())
    _token["value"] = d["access_token"]
    _token["exp"] = time.time() + int(d.get("expires_in", 600))
    return _token["value"]

# ---------------------------------------------------------------- evalscripts
def index_formula(index):
    index = (index or "NDVI").upper()
    if index == "GNDVI":
        return "(s.B08 - s.B03) / (s.B08 + s.B03)"
    if index == "NDRE":
        return "(s.B08 - s.B05) / (s.B08 + s.B05)"
    return "(s.B08 - s.B04) / (s.B08 + s.B04)"  # NDVI

# máscara de nuvem via SCL (Scene Classification): 0 no-data,1 saturated,3 shadow,8/9 cloud,10 cirrus,11 snow
CLOUD_MASK = "(s.SCL===0||s.SCL===1||s.SCL===3||s.SCL===8||s.SCL===9||s.SCL===10||s.SCL===11)"

def evalscript_image(index):
    return """//VERSION=3
function setup(){ return { input:["B03","B04","B05","B08","SCL","dataMask"], output:{bands:4} }; }
function ramp(v){
  // paleta tipo vegetacao: marrom -> vermelho -> amarelo -> verde claro -> verde escuro
  var stops=[[-0.2,[0.4,0.27,0.18]],[0.0,[0.66,0.27,0.14]],[0.2,[0.9,0.45,0.2]],
             [0.35,[0.95,0.85,0.35]],[0.5,[0.7,0.85,0.35]],[0.65,[0.35,0.72,0.27]],
             [0.8,[0.12,0.5,0.18]],[0.95,[0.0,0.3,0.08]]];
  if(v<=stops[0][0]) return stops[0][1];
  for(var i=1;i<stops.length;i++){
    if(v<=stops[i][0]){ var t=(v-stops[i-1][0])/(stops[i][0]-stops[i-1][0]);
      var a=stops[i-1][1],b=stops[i][1];
      return [a[0]+t*(b[0]-a[0]),a[1]+t*(b[1]-a[1]),a[2]+t*(b[2]-a[2])]; } }
  return stops[stops.length-1][1];
}
function evaluatePixel(s){
  if(s.dataMask===0 || %CLOUD%) return [0,0,0,0];
  var v=%FORMULA%;
  var c=ramp(v);
  return [c[0],c[1],c[2],1];
}
""".replace("%FORMULA%", index_formula(index)).replace("%CLOUD%", CLOUD_MASK)

def evalscript_stats(index):
    return """//VERSION=3
function setup(){ return { input:[{bands:["B03","B04","B05","B08","SCL","dataMask"]}],
  output:[{id:"idx",bands:1,sampleType:"FLOAT32"},{id:"dataMask",bands:1}] }; }
function evaluatePixel(s){
  var bad = (s.dataMask===0 || %CLOUD%);
  var v = %FORMULA%;
  return { idx:[v], dataMask:[bad?0:1] };
}
""".replace("%FORMULA%", index_formula(index)).replace("%CLOUD%", CLOUD_MASK)

# ---------------------------------------------------------------- chamadas API
def api_post(url, payload, accept):
    token = get_token()
    data = json.dumps(payload).encode()
    req = urllib.request.Request(url, data=data, headers={
        "Authorization": "Bearer " + token,
        "Content-Type": "application/json",
        "Accept": accept,
    })
    with urllib.request.urlopen(req, timeout=90) as r:
        return r.read(), r.headers.get("Content-Type", accept)

def evalscript_raw(index):
    # 2 bandas: L = (indice+1)/2 (0..1 -> 0..255), A = valido(1)/invalido(0). Para medir por quadra no app.
    return ("//VERSION=3\n"
        "function setup(){ return { input:[\"B03\",\"B04\",\"B05\",\"B08\",\"SCL\",\"dataMask\"], output:{bands:2} }; }\n"
        "function evaluatePixel(s){ if(s.dataMask===0 || " + CLOUD_MASK + ") return [0,0];\n"
        "  var v=" + index_formula(index) + "; if(v<-1)v=-1; if(v>1)v=1; return [(v+1)/2, 1]; }")

def do_index(index, date, bbox, width, geometry=None, raw=False):
    w, s, e, n = bbox
    width = max(64, min(2500, int(width or 1024)))
    height = max(64, min(2500, int(round(width * (n - s) / (e - w))))) if e != w else width
    from datetime import datetime, timedelta
    try:
        d0 = datetime.strptime(date, "%Y-%m-%d")
        frm = (d0 - timedelta(days=3)).strftime("%Y-%m-%d")
        to2 = (d0 + timedelta(days=3)).strftime("%Y-%m-%d")
    except Exception:
        frm = date; to2 = date
    payload = {
        "input": {
            "bounds": {"bbox": [w, s, e, n], "properties": {"crs": CRS84}},
            "data": [{
                "type": "sentinel-2-l2a",
                "dataFilter": {
                    "timeRange": {"from": frm + "T00:00:00Z", "to": to2 + "T23:59:59Z"},
                    "mosaickingOrder": "leastCC",
                },
            }],
        },
        "output": {"width": width, "height": height,
                   "responses": [{"identifier": "default", "format": {"type": "image/png"}}]},
        "evalscript": (evalscript_raw(index) if raw else evalscript_image(index)),
    }
    if geometry:
        payload["input"]["bounds"]["geometry"] = geometry  # recorta o índice só dentro das quadras
    return api_post(PROCESS_URL, payload, "image/png")

def do_stats(index, frm, to, geometry):
    payload = {
        "input": {
            "bounds": {"geometry": geometry, "properties": {"crs": CRS84}},
            "data": [{"type": "sentinel-2-l2a",
                      "dataFilter": {"mosaickingOrder": "leastCC"}}],
        },
        "aggregation": {
            "timeRange": {"from": frm + "T00:00:00Z", "to": to + "T23:59:59Z"},
            "aggregationInterval": {"of": "P5D"},
            "evalscript": evalscript_stats(index),
            "resx": 10, "resy": 10,
        },
        "calculations": {"idx": {"statistics": {"default": {}}}},
    }
    raw, _ = api_post(STATS_URL, payload, "application/json")
    d = json.loads(raw.decode())
    out = []
    for it in d.get("data", []):
        interval = it.get("interval", {})
        stt = (((it.get("outputs", {}).get("idx", {}) or {}).get("bands", {}) or {}).get("B0", {}) or {}).get("stats", {})
        if not stt or stt.get("sampleCount", 0) == 0 or stt.get("mean") is None:
            continue
        if stt.get("sampleCount", 0) - stt.get("noDataCount", 0) <= 0:
            continue
        out.append({
            "date": (interval.get("from", "") or "")[:10],
            "mean": round(stt.get("mean"), 4),
            "min": round(stt.get("min", 0), 4),
            "max": round(stt.get("max", 0), 4),
        })
    return out

def do_point(lat, lng, date):
    import math
    from datetime import datetime, timedelta
    dlat = 12.0 / 110540.0
    dlng = 12.0 / (111320.0 * math.cos(lat * math.pi / 180))
    poly = {"type": "Polygon", "coordinates": [[[lng - dlng, lat - dlat], [lng + dlng, lat - dlat],
            [lng + dlng, lat + dlat], [lng - dlng, lat + dlat], [lng - dlng, lat - dlat]]]}
    try:
        d0 = datetime.strptime(date, "%Y-%m-%d")
        frm = (d0 - timedelta(days=3)).strftime("%Y-%m-%d")
        to = (d0 + timedelta(days=4)).strftime("%Y-%m-%d")
    except Exception:
        frm = date; to = date
    evalscript = ("//VERSION=3\n"
        "function setup(){ return { input:[{bands:[\"B03\",\"B04\",\"B05\",\"B08\",\"SCL\",\"dataMask\"]}], "
        "output:[{id:\"ndvi\",bands:1,sampleType:\"FLOAT32\"},{id:\"ndre\",bands:1,sampleType:\"FLOAT32\"},"
        "{id:\"gndvi\",bands:1,sampleType:\"FLOAT32\"},{id:\"dataMask\",bands:1}] }; }\n"
        "function evaluatePixel(s){ var bad=(s.dataMask===0||" + CLOUD_MASK + ");\n"
        "  return { ndvi:[(s.B08-s.B04)/(s.B08+s.B04)], ndre:[(s.B08-s.B05)/(s.B08+s.B05)], "
        "gndvi:[(s.B08-s.B03)/(s.B08+s.B03)], dataMask:[bad?0:1] }; }")
    payload = {
        "input": {"bounds": {"geometry": poly, "properties": {"crs": CRS84}},
                  "data": [{"type": "sentinel-2-l2a", "dataFilter": {"mosaickingOrder": "leastCC"}}]},
        "aggregation": {"timeRange": {"from": frm + "T00:00:00Z", "to": to + "T23:59:59Z"},
                        "aggregationInterval": {"of": "P7D"}, "evalscript": evalscript, "resx": 10, "resy": 10},
        "calculations": {"ndvi": {"statistics": {"default": {}}}, "ndre": {"statistics": {"default": {}}},
                         "gndvi": {"statistics": {"default": {}}}},
    }
    raw, _ = api_post(STATS_URL, payload, "application/json")
    d = json.loads(raw.decode())
    res = {"ndvi": None, "ndre": None, "gndvi": None, "date": None}
    for it in d.get("data", []):
        outs = it.get("outputs", {}); ok = False
        for k in ["ndvi", "ndre", "gndvi"]:
            st = (((outs.get(k, {}) or {}).get("bands", {}) or {}).get("B0", {}) or {}).get("stats", {})
            if st and (st.get("sampleCount", 0) - st.get("noDataCount", 0)) > 0 and st.get("mean") is not None:
                res[k] = round(st.get("mean"), 3); ok = True
        if ok:
            res["date"] = (it.get("interval", {}).get("from", "") or "")[:10]; break
    return res

def do_dates(bbox, frm, to):
    # Datas com imagem via Statistical API (mais confiavel que o catalog): dias com pixels validos.
    w, s, e, n = bbox
    poly = {"type": "Polygon", "coordinates": [[[w, s], [e, s], [e, n], [w, n], [w, s]]]}
    evalscript = ("//VERSION=3\n"
        "function setup(){ return { input:[{bands:[\"SCL\",\"dataMask\"]}], "
        "output:[{id:\"idx\",bands:1,sampleType:\"FLOAT32\"},{id:\"dataMask\",bands:1}] }; }\n"
        "function evaluatePixel(s){ var bad=(s.dataMask===0||" + CLOUD_MASK + "); return { idx:[1], dataMask:[bad?0:1] }; }")
    payload = {
        "input": {"bounds": {"geometry": poly, "properties": {"crs": CRS84}},
                  "data": [{"type": "sentinel-2-l2a"}]},
        "aggregation": {"timeRange": {"from": frm + "T00:00:00Z", "to": to + "T23:59:59Z"},
                        "aggregationInterval": {"of": "P1D"},
                        "evalscript": evalscript, "resx": 60, "resy": 60},
        "calculations": {"idx": {"statistics": {"default": {}}}},
    }
    # resx/resy estao em graus (CRS84). ~0.0045 deg ~= 500 m/px: bem abaixo do limite de 1500 m/px
    # da colecao S2L2A e suficiente para detectar disponibilidade/nuvem em qualquer area.
    payload["aggregation"]["resx"] = min(0.0045, max(1e-5, e - w))
    payload["aggregation"]["resy"] = min(0.0045, max(1e-5, n - s))
    raw, _ = api_post(STATS_URL, payload, "application/json")
    d = json.loads(raw.decode())
    best = {}
    for it in d.get("data", []):
        dt = (it.get("interval", {}).get("from", "") or "")[:10]
        st = (((it.get("outputs", {}).get("idx", {}) or {}).get("bands", {}) or {}).get("B0", {}) or {}).get("stats", {})
        sc = st.get("sampleCount", 0); nd = st.get("noDataCount", 0)
        if not dt or (sc - nd) <= 0:
            continue
        cloud = round((nd / sc) * 100) if sc else None
        if dt not in best or (cloud is not None and (best[dt] is None or cloud < best[dt])):
            best[dt] = cloud
    return [{"date": k, "cloud": best[k]} for k in sorted(best.keys(), reverse=True)]

# ---------------------------------------------------------------- HTTP server
class H(BaseHTTPRequestHandler):
    def _cors(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "*")
        self.send_header("Access-Control-Allow-Methods", "GET,POST,OPTIONS")
    def _json(self, obj, code=200):
        b = json.dumps(obj).encode()
        self.send_response(code); self._cors()
        self.send_header("Content-Type", "application/json"); self.end_headers()
        self.wfile.write(b)
    def do_OPTIONS(self):
        self.send_response(204); self._cors(); self.end_headers()
    def _err(self, e):
        import urllib.error as ue
        if isinstance(e, RuntimeError) and str(e) == "SEM_CREDENCIAL":
            return self._json({"error": "Sem credencial. Configure rodando python3 ndvi-proxy.py."}, 400)
        if isinstance(e, ue.HTTPError):
            try: detail = e.read().decode()[:500]
            except Exception: detail = ""
            return self._json({"error": "Sentinel Hub %s: %s" % (e.code, detail)}, 502)
        return self._json({"error": repr(e)}, 500)
    def do_POST(self):
        u = urllib.parse.urlparse(self.path)
        try:
            ln = int(self.headers.get("Content-Length", 0) or 0)
            body = json.loads(self.rfile.read(ln).decode()) if ln else {}
            if u.path == "/index":
                img, ctype = do_index(body.get("index", "NDVI"), body["date"], body["bbox"],
                                      body.get("width", 1024), body.get("geom"))
                self.send_response(200); self._cors()
                self.send_header("Content-Type", ctype or "image/png"); self.end_headers()
                return self.wfile.write(img)
            self._json({"error": "rota desconhecida"}, 404)
        except Exception as e:
            self._err(e)
    def log_message(self, *a):  # silencioso
        pass
    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        q = {k: v[0] for k, v in urllib.parse.parse_qs(u.query).items()}
        try:
            if u.path == "/health":
                cid, _ = load_creds()
                return self._json({"ok": True, "hasCreds": bool(cid)})
            if u.path == "/dates":
                bbox = [float(x) for x in q["bbox"].split(",")]
                return self._json(do_dates(bbox, q["from"], q["to"]))
            if u.path == "/index":
                bbox = [float(x) for x in q["bbox"].split(",")]
                img, ctype = do_index(q.get("index", "NDVI"), q["date"], bbox, q.get("width", 1024), None, q.get("raw"))
                self.send_response(200); self._cors()
                self.send_header("Content-Type", ctype or "image/png"); self.end_headers()
                return self.wfile.write(img)
            if u.path == "/stats":
                geometry = json.loads(q["geom"])
                return self._json(do_stats(q.get("index", "NDVI"), q["from"], q["to"], geometry))
            if u.path == "/point":
                return self._json(do_point(float(q["lat"]), float(q["lng"]), q["date"]))
            self._json({"error": "rota desconhecida"}, 404)
        except RuntimeError as e:
            if str(e) == "SEM_CREDENCIAL":
                self._json({"error": "Sem credencial. Crie ndvi-credenciais.json (client_id/client_secret)."}, 400)
            else:
                self._json({"error": str(e)}, 500)
        except urllib.error.HTTPError as e:
            try: detail = e.read().decode()[:500]
            except Exception: detail = ""
            self._json({"error": "Sentinel Hub %s: %s" % (e.code, detail)}, 502)
        except Exception as e:
            self._json({"error": repr(e)}, 500)

def setup_creds_interactive():
    """Pergunta a credencial no Terminal (fica só na sua máquina) e salva localmente."""
    import getpass
    print("\nNenhuma credencial encontrada. Vamos configurar — fica salvo só aqui no seu computador.")
    print("Onde pegar: https://shapps.dataspace.copernicus.eu/dashboard  ->  User settings  ->  OAuth clients\n")
    try:
        cid = input("Cole o Client ID e Enter: ").strip()
        csec = getpass.getpass("Cole o Client Secret e Enter (nao aparece na tela): ").strip()
    except (EOFError, KeyboardInterrupt):
        print("\nConfiguracao cancelada."); return False
    if not cid or not csec:
        print("Faltou o ID ou o Secret. Rode de novo: python3 ndvi-proxy.py"); return False
    p = os.path.join(HERE, "ndvi-credenciais.json")
    json.dump({"client_id": cid, "client_secret": csec}, open(p, "w"), indent=2)
    try: os.chmod(p, 0o600)
    except Exception: pass
    print("Credencial salva em ndvi-credenciais.json (so voce le).")
    return True

if __name__ == "__main__":
    cid, _ = load_creds()
    if not cid:
        setup_creds_interactive()
    cid, _ = load_creds()
    valid = False
    if cid:
        try:
            get_token(); valid = True
        except Exception as e:
            print("\n[!] Credencial NAO validou:", e)
            print("    Confira o Client ID/Secret (ou apague ndvi-credenciais.json e rode de novo).")
    print("=" * 56)
    print(" Proxy NDVI - Estacao Iracemapolis")
    print(" Porta:  http://localhost:%d" % PORT)
    print(" Credencial:", "OK (validada)" if valid else ("encontrada, mas nao validou" if cid else "NAO configurada"))
    print(" Deixe esta janela aberta enquanto usa o app.")
    print("=" * 56)
    ThreadingHTTPServer((HOST, PORT), H).serve_forever()
