# Agracta — registros de ensaios de campo (mapa + NDVI)

App de agricultura de precisão da estação experimental (Plantec, Iracemápolis‑SP):
mapa de satélite real, quadras georreferenciadas (área e coordenadas), fenologia/estudos,
e índices de vegetação **NDVI / NDRE / GNDVI** do Sentinel‑2, com série temporal e consulta por ponto.

## Rodar localmente
1. Abrir o app: sirva a pasta (recomendado, habilita GPS/PWA) —
   `python3 -m http.server 8080` e acesse `http://localhost:8080`.
   (Também abre com 2 cliques no `index.html`, mas aí GPS/instalação ficam bloqueados pelo navegador.)
2. NDVI (opcional): rode o proxy do Sentinel‑2 —
   `python3 ndvi-proxy.py` (na 1ª vez ele pede o Client ID/Secret do Copernicus e salva em `ndvi-credenciais.json`).

## Estrutura
- `index.html` — o app inteiro (mapa Leaflet + lógica).
- `vendor/` — Leaflet e plugins (offline).
- `quadras-default.js` (em `vendor/`) — alinhamento + geometria das quadras (gerado de backup).
- `ndvi-proxy.py` — proxy local que conversa com o Sentinel Hub (Copernicus).
- `manifest.webmanifest`, `sw.js`, `icon-*.png` — PWA (instalável/offline).

## Segurança
`ndvi-credenciais.json` (segredo do Copernicus) **não** é versionado (ver `.gitignore`).

## Publicar
- **App** → GitHub Pages (estático, https).
- **Proxy NDVI** → servidor (ex.: Render) — GitHub Pages não roda Python.
- **Multiusuário** (futuro) → Supabase (banco + login).
