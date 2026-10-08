# Tessera OCaml Pipeline

An OCaml implementation of the Tessera satellite imagery embedding pipeline. Downloads Sentinel-2 and Sentinel-1 data, preprocesses it (cloud masking, mosaicking, harmonisation), runs ONNX model inference, and outputs quantized int8 embeddings.

Two tools are provided:

- **`bin/pipeline.ml`** — Full inference pipeline. Downloads Sentinel-2 and Sentinel-1 data per MGRS tile from Microsoft Planetary Computer (MPC) or AWS, processes spatial blocks, runs ONNX model inference, and outputs int8 embeddings.
- **`bin/tessera_dpixel.ml`** — Download-only tool (`tessera-dpixel`). Port of the worker pipeline's `dpixel.py`: fetches S2 and S1 for one grid tile and writes the "dpixel" `.npy` files (bands, masks, doys, SAR ascending/descending) byte-identically to it.

## Prerequisites

- OCaml 5.3.0 with opam
- GDAL (>= 3.10; 3.11+ recommended for Float16 support)
- ONNX Runtime shared library (`libonnxruntime.so`), for `tessera-pipeline` only

## External Repositories

These libraries must be cloned and pinned locally via `opam pin`:

| Library | Repository | Description |
|---------|-----------|-------------|
| `stac-client` | [mtelvers/stac-client](https://github.com/mtelvers/stac-client) | STAC API search + Planetary Computer token signing |
| `gdal` | [mtelvers/ocaml-gdal](https://github.com/mtelvers/ocaml-gdal) | GDAL bindings (ctypes-based) |
| `onnxruntime` | [mtelvers/ocaml-onnxruntime](https://github.com/mtelvers/ocaml-onnxruntime) | ONNX Runtime bindings (ctypes-based) |
| `npy` | [mtelvers/ocaml-npy](https://github.com/mtelvers/ocaml-npy) | NumPy `.npy` file reader/writer |

## Build

```bash
# Pin external dependencies (one-time setup)
opam pin add stac-client https://github.com/mtelvers/stac-client.git -n
opam pin add gdal https://github.com/mtelvers/ocaml-gdal.git -n
opam pin add onnxruntime https://github.com/mtelvers/ocaml-onnxruntime.git -n
opam pin add npy https://github.com/mtelvers/ocaml-npy.git -n
opam install stac-client gdal onnxruntime npy

# Build
eval $(opam env)
day10 build .
```

Note: GDAL ctypes bindings require relaxed C flags. The `dune-workspace` is configured with `-Wno-incompatible-pointer-types` for this reason.

## Usage

### pipeline.exe — Full inference

```bash
LD_LIBRARY_PATH=/path/to/onnxruntime/lib \
dune exec bin/pipeline.exe -- \
  --dpixel_dir /tmp/py_cache/grid_51.05_10.35 \
  --model tessera_model.onnx \
  --output /tmp/ocaml_out \
  --batch_size 1024 \
  --num_threads 20 \
  --repeat_times 1
```

### tessera-dpixel — Download

Downloads Sentinel-2 L2A and Sentinel-1 RTC for one 0.1° grid tile and writes
the d-pixel `.npy` arrays. This is a port of the worker pipeline's `dpixel.py`
and its output is byte-identical to it on the default MPC path (verified on
whole 2017 tiles against `/data/aardvark` on pima, including tiles straddling
UTM zones). Tile geometry is derived from the grid id alone, exactly as
`dpixel.load_roi_from_grid_id` does; the all-ones tiffs in
`global_map_0.1_degree_tiff` are not read.

```bash
day10 exec . -- dune exec -- tessera-dpixel \
  --grid_id grid_51.05_10.35 \
  --output /tmp/dpixel_cache \
  --start 2024-01-01 \
  --end 2024-12-31
```

Output layout (same as `dpixel.save`): `<output>/<grid_id>/s2/{bands,masks,doys}.npy`
and `<output>/<grid_id>/s1/sar_{ascending,descending}{,_doy}.npy`.

**Grid-aligned windows.** Instead of a 0.1° tile the tool can build a window
cut straight out of a seeded Zarr zone grid, the `zarr_poc/dpixel_window.py`
mode: `--window ZONE:ROW:COL:HxW` (zone-grid pixel row/col of the top-left
corner, size in pixels) with `--zone_grid FILE`, where FILE is either a
`zone_grids.json` dump or a genesis `/work` document (its `grid` object).
Bounds are exact multiples of the pixel size, so nothing is snapped or cropped;
south of the equator the imagery is read in the 327xx CRS with the false
northing added back. Output goes to `<output>/utmZZ/r<ROW>c<COL>/`.

```bash
day10 exec . -- dune exec -- tessera-dpixel \
  --window 30:232448:58368:1024x1024 --zone_grid zarr_poc/zone_grids.json \
  --output /tmp/dpixel_cache --start 2017-01-01 --end 2017-12-31
```

**Shards.** `--shard ZONE:SR:SC` runs every `--subwindow` (default 1024) sub-window
of Zarr shard (SR, SC) in turn, each written as `utmZZ/r<ROW>c<COL>/` as above, so a
shard is produced with a tile-sized working set per step and the sixteen outputs
can be handed to `tessera-zarr-upload --sr SR --sc SC` in one go to write one object
per array. Already-produced sub-windows are skipped, so a run resumes. A sub-window
with no Sentinel-2 items at all (open sea) is skipped with a message and left for
the uploader to fill with `+inf`; only a transient failure makes the run exit 3.
A whole 4096-px shard as one `--window` also works, but a year of it needs tens of GB
of RAM (one month measured at 9.4 GB peak, 3.1 GB output).

**Options:**

| Flag | Default | Description |
|------|---------|-------------|
| `--grid_id` | one of these | Grid id of the form `grid_<lon>_<lat>` |
| `--window` | one of these | Zone-grid window `ZONE:ROW:COL:HxW`; needs `--zone_grid` |
| `--shard` | one of these | Zarr shard `ZONE:SR:SC`, run as `--subwindow` sub-windows; needs `--zone_grid` |
| `--shard_px`, `--subwindow` | `4096`, `1024` | Shard side and sub-window side in pixels |
| `--zone_grid` | | Zone grid JSON (`zone_grids.json` dump or genesis `/work` document) |
| `--output` | (required) | Output directory |
| `--start` | `2024-01-01` | Start date (YYYY-MM-DD) |
| `--end` | `2024-12-31` | End date (YYYY-MM-DD, inclusive) |
| `--data_source` | `mpc` | `mpc` (Planetary Computer, byte-identical path) or `aws` |
| `--download_workers` | `$DOWNLOAD_WORKERS` or `4` | Concurrent COG reads per instance (OCaml domains). Same lever as dask `num_workers` / `--download-workers` in the Python stack |
| `--s2_min_load_frac` | `$S2_MIN_LOAD_FRAC` or `0.9` | Min fraction of S2 dates that must load, else exit 3 (0 disables) |
| `--s1_min_load_frac` | `$S1_MIN_LOAD_FRAC` or `0.9` | Min fraction of S1 dates that must load, else exit 3 (0 disables) |
| `--no_research` | off | Do not re-search STAC for fresh signed URLs after read failures |
| `--flat_output` | off | Write into `--output` directly instead of `--output/<grid_id>` |
| `--layout` | `nested` | `nested` (`s2/`, `s1/` subdirectories) or `flat` (all files in one directory) |
| `--max_cloud` | `100.0` | Max cloud cover % for scene filtering |

**Concurrency and environment.** `--download_workers` is the per-instance read
concurrency, the same quantity as dask `num_workers` (4 in `build_tile.py`;
the fleet notes in `azure/DOWNLOAD_ENGINE_NOTES.md` keep it at 4 per worker so
many instances together do not trip MPC throttling). Each concurrent read is
one OCaml domain; the tool caps this at 120. GDAL reads its own configuration
from the environment, so `GDAL_NUM_THREADS` (per-warp threads, unset = 1; the
Python workers use 8), `GDAL_CACHEMAX`, `CPL_VSIL_CURL_CACHE_SIZE` and friends
apply unchanged; the tool only sets defaults for the stackstac options
(`GDAL_DISABLE_READDIR_ON_OPEN`, HTTP multi-range, retries) when they are not
already in the environment. CPU threads per instance are roughly
`download_workers × GDAL_NUM_THREADS`; there is no BLAS, so the `OMP_*`
caps have no counterpart. `S2_MIN_LOAD_FRAC` / `S1_MIN_LOAD_FRAC` are honoured
like in `dpixel.py`.

**Exit codes** (the `dpixel.py` coverage policy): `0` tile written; `2` permanent
failure (no S2 items, or every S2 date genuinely absent) — mark the cell bad;
`3` transient failure (too many dates lost to read errors) — re-queue.

**Processing** (matches `dpixel.py`): SCL nearest, spectral bands bilinear,
per-date first-valid-tile selection with a 0.01 % coverage filter,
harmonisation (−1000 where ≥ 1000 after 2022-01-25); S1 nearest,
dB = (20·log10(amp) + 50)·200 as int16, per-date mean over all of the day's
scenes, emitted once per orbit present. Transient read failures are retried
once with freshly signed URLs. See the comment on `warp_read` in
`bin/tessera_dpixel.ml` for how rasterio's WarpedVRT read is reproduced.

### tessera-zarr-upload — Encoder output into the S3 Zarr store

Places encoder output into the shards of the geotessera-layout Zarr v3 store
(the one the Zarr PoC writes to): per UTM zone, `embeddings` int8
`(T,128,H,W)`, `embeddings_d16`, `embeddings_d4` and `scales` float32
`(T,H,W)`, shards of 4096×4096 pixels. Inputs are the `.npy` pairs the
encoders write, `<name>.npy` int8 `(H,W,128)` plus `<name>_scales.npy`
float32 `(H,W)`. Each argument is one input, nothing is scanned: a `.npy`
file (its `_scales` partner must sit beside it) or a directory holding
`<basename>.npy` and `<basename>_scales.npy`, the archive's
`<year>/<grid>/<grid>.npy` layout, so `--year 2017 /data/2017/grid_*` works.
`<name>` is `grid_<lon>_<lat>` for a tile, or `r<ROW>c<COL>` for a window or
shard sub-window from `tessera-dpixel` (then pass `--zone`; the `utmZZ/`
directory is not parsed).

```bash
AWS_ACCESS_KEY_ID=… AWS_SECRET_ACCESS_KEY=… \
day10 exec . -- dune exec -- tessera-zarr-upload \
  --endpoint https://s3.example --bucket tessera-v2 --prefix zarr/v2-world \
  --year 2017 /data/2017/grid_-0.05_50.75 /data/2017/grid_-0.15_50.75 …
```

- The zone grid, extent, codecs and fill values come from the store's own
  metadata (`utmZZ/zarr.json` `spatial:transform` and the array `zarr.json`s),
  so the tool cannot write against a different store's geometry.
- Tiles are placed by geotessera's floor rule, which is the stackstac snapped
  origin dpixel lays pixels out from (`lib/tile_geom.ml`). Tiles overlap and
  may straddle up to four shards; every shard the inputs touch is assembled in
  memory and written as one object per array in the PoC's order, d4, d16,
  scales, then `embeddings` last as the completion marker (any stale one is
  deleted first). Restrict to one shard with `--sr`/`--sc`; a shard is only as
  complete as the inputs you pass.
- No-data: the encoders mark empty pixels as an all-zero vector with the
  quantiser floor scale `1e-12/127`, which the (0,1) validity test would
  accept. Those become NaN scales (covered, no data); pixels nothing covers
  stay `+inf`. Later inputs overwrite earlier valid pixels; no-data never
  overwrites data.
- Shards are encoded with `ocaml-zarr` (byte-identical to zarr-python,
  Blosc included) using `--domains` cores, and uploaded with multipart PUTs.
  `--dry_run` places and assembles without writing.
- Verified against a MinIO store seeded from the published beta1 metadata:
  zarr-python reads back embeddings, depth prefixes and scales identical to
  the `.npy`, and the placement matches geotessera's.

## Data Sources

- **Sentinel-2**: MPC (`planetarycomputer.microsoft.com`) or AWS (`earth-search.aws.element84.com`)
- **Sentinel-1 (SAR)**: NASA OPERA RTC-S1 via CMR (`cmr.earthdata.nasa.gov`)

## DPixel Output Format

The dpixel tool writes 7-8 `.npy` files per grid tile:

| File | Shape | Dtype | Description |
|------|-------|-------|-------------|
| `bands.npy` | (T,H,W,10) | uint16 | S2 spectral bands |
| `masks.npy` | (T,H,W) | uint8 | SCL-derived validity masks |
| `doys.npy` | (T,) | uint16 | Day-of-year for each S2 timestep |
| `sar_ascending.npy` | (T,H,W,2) | int16 | S1 ascending VV+VH |
| `sar_ascending_doy.npy` | (T,) | int16 | Day-of-year for ascending |
| `sar_descending.npy` | (T,H,W,2) | int16 | S1 descending VV+VH |
| `sar_descending_doy.npy` | (T,) | int16 | Day-of-year for descending |
