# Tessera Tools

Command-line tools, in OCaml, for producing the Tessera v2 embedding store:
deciding what to produce, downloading the satellite time series for it,
*dpixel*, and writing the encoder's output into the Zarr store on S3. The encoder
itself is a separate program; these tools surround it.

```
World Bank boundaries + zone_grids.json
        |
        v
  tessera-shard            list of shards, each with its live sub-windows
        |                  ZONE:SR:SC  i,j,k
        v
  tessera-dpixel           one d-pixel directory per sub-window
        |                  utmZZ/r<ROW>c<COL>/{s2,s1}/*.npy
        v
  tessera_encode (C++)     one embedding pair per sub-window
        |                  r<ROW>c<COL>.npy, r<ROW>c<COL>_scales.npy
        v
  tessera-zarr-upload      one object per array per shard
                           utmZZ/{embeddings,…,scales}/c/<t>/…/<sr>/<sc>
```

The unit of work is a **shard**: a 4096 × 4096 pixel (41 km) square of a UTM
zone's 10 m grid, which is also the unit the Zarr store writes as one object
per array. The unit of memory is a **sub-window**: a 1024 × 1024 pixel cut of
a shard, which keeps every step's working set at the size of a single
0.1° tile. Everything is addressed in integer pixels of the store's own zone
grid, so nothing in this chain projects a tile edge or snaps a coordinate:
the position of every pixel is decided once, by the grid the store was
seeded with.

The sections below walk through one shard. Reference tables for each tool's
options follow at the end.

## Build

### opam

The OCaml bindings (`gdal`, `stac_client`, `npy`, `zarr`, `zarr-blosc`,
`zarr-s3`, `s3`, `tessera-grid`) and `conf-gdal` come from the
[tunbury opam overlay](https://github.com/tunbury/opam-repository-overlay),
pinned there by commit. Add it with higher priority than the default
repository (upstream has an unrelated package also called `zarr`), then
install the dependencies and build. On Debian or Ubuntu:

```bash
sudo apt-get install -y libgdal-dev libblosc-dev libcurl4-openssl-dev \
  libffi-dev libgmp-dev pkg-config m4
opam repo add --rank 1 tunbury \
  https://github.com/tunbury/opam-repository-overlay.git
opam update
opam install -y stac_client gdal npy yojson cmdliner \
  zarr zarr-blosc zarr-s3 s3 eio eio_main tessera-grid
dune build
# _build/default/bin/: tessera_{shard,dpixel,zarr_upload}.exe
```

OCaml 5.1 or later. GDAL 3.8 to 3.11 have all been checked for byte-identical
output; `dune-workspace` relaxes the C flags the GDAL ctypes bindings need.
The `Dockerfile` is the same recipe, verbatim.

### day10

[day10](https://github.com/tunbury/day10) assembles the same dependency
layers in a container, so no switch is needed on the host:

```bash
day10 build .
```

`.day10` must list the overlay repository before the main opam repository,
for the same `zarr` reason.

### Container image

The `Dockerfile` builds all three tools into one image (Debian 13, GDAL
3.10, 576 MB), installing the OCaml bindings from the overlay so it tracks
the same commits as day10:

```bash
docker build -t tessera-tools .
docker run --rm -v ~/world_bank:/wb:ro -v $PWD:/work tessera-tools \
  tessera-shard --shapefile /wb/WB_GAD_ADM0_complete.shp \
  --country "United Kingdom" --zone_grid /work/zone_grids.json
```

There is no entrypoint: name the tool. Docker runs as root, so files written
to a bind mount are root-owned; Apptainer below does not have that problem.
Tiles produced in the image are byte-identical to the host build.

### Apptainer

On the HPCs (Dawn, Endeavour) the image runs under Apptainer. Build the SIF once
from the Docker image on a machine that has Docker:

```bash
apptainer build tessera-tools.sif docker-daemon://tessera-tools:latest  # 275 MB
```

or, without Docker on the target, push the image to a registry you can
write to and pull it there, for example:

```bash
docker tag tessera-tools ghcr.io/<you>/tessera-tools:latest
docker push ghcr.io/<you>/tessera-tools:latest   # after docker login ghcr.io
apptainer pull tessera-tools.sif docker://ghcr.io/<you>/tessera-tools:latest
```

Then each step is `apptainer exec` with the tool name. Apptainer runs as the
invoking user, binds `$HOME`, `/tmp` and the current directory by default,
and has network access, so outputs land with your ownership and only paths
outside those need `--bind`:

```bash
# 1. the work list
apptainer exec --bind /rds/world_bank:/wb:ro tessera-tools.sif \
  tessera-shard --shapefile /wb/WB_GAD_ADM0_complete.shp \
  --country "United Kingdom" --zone_grid zone_grids.json --output uk.shards

# 2. download one shard's live sub-windows (one line of uk.shards)
apptainer exec --env DOWNLOAD_WORKERS=4 --bind /scratch tessera-tools.sif \
  tessera-dpixel --shard 30:27:13 --windows 0,4 --zone_grid zone_grids.json \
  --output /scratch/dpixel --start 2017-01-01 --end 2017-12-31

# 3. encode (tessera_encode, outside this image)

# 4. upload the shard
apptainer exec --env AWS_ACCESS_KEY_ID=… --env AWS_SECRET_ACCESS_KEY=… \
  --bind /scratch tessera-tools.sif \
  tessera-zarr-upload --endpoint https://s3.example --bucket tessera \
  --prefix zarr/v2-world --zone 30 --sr 27 --sc 13 --year 2017 \
  /scratch/emb/r110592c53248 /scratch/emb/r111616c53248
```

Environment variables pass with `--env NAME=value` (or by exporting
`APPTAINERENV_NAME` on the host); with `--containall` or `--cleanenv` nothing
else leaks in, which is the safer setting for credentials. `GDAL_NUM_THREADS`
and the `S2_MIN_LOAD_FRAC`/`S1_MIN_LOAD_FRAC` knobs pass the same way. A
Slurm array over the lines of `uk.shards` is the natural way to run it.

## 1. Decide the work: `tessera-shard`

`tessera-shard` reads region polygons (the World Bank GAD ADM0 shapefile, or
any OGR source with a `NAM_0` or `name` field) and tests them directly
against a seeded zone grid. It lists every shard the selected regions touch
and, for each, the row-major indices of the sub-windows that overlap land.

```bash
tessera-shard --shapefile ~/world_bank/WB_GAD_ADM0_complete.shp \
  --country "United Kingdom" --zone_grid zone_grids.json --output uk.shards
```

`--zone_grid` is the destination store's zone geometry (origin, pixel size,
shard rows and columns per UTM zone), read from the store's own
`utmZZ/zarr.json` files. Give it the store's base URL directly, e.g.
`https://data.source.coop/tessera/tessera/zarr/v2-2B-L~beta1`, or write a
file once for offline use and pass that to every tool:

```bash
tessera-shard \
  --zone_grid https://data.source.coop/tessera/tessera/zarr/v2-2B-L~beta1 \
  --dump_zone_grid zone_grids.json
```

Use the destination's grid, not a reference store's: shard indices only
mean anything against the grid they were computed on.

Output, one shard per line, sorted by zone, row, column:

```
29:34:10	11,14,15
29:34:11	2,3,5,6,7,8,9,10,11,12,13,14,15
30:27:13	0,4
```

Sub-window indices are row-major within the shard, 0 to 15 for 1024-px
sub-windows (index = row × 4 + column), as `tessera-dpixel --windows`
takes them.

Rules: rings are clipped to the zone's
6° band (with a margin) and densified before projecting, so a straight
lon/lat edge does not bow across a sub-window; a sub-window belongs to the
zone of its centre longitude; the *request* chooses the shards but *all
land* chooses the windows, because a shard is written whole and its
existence means "finished", so a shard holding the Isle of Man and the Mull
of Galloway must be produced with both; land outside the seeded grid (zones
seeded short of the pole) is reported, never folded onto the edge. The
projection is PROJ, through GDAL. `--list` prints the region names
(World Bank spellings: `Isle of Man (U.K.)`), `--all` takes every region.

What to expect:

| region | shards | live sub-windows | time |
|---|---|---|---|
| Isle of Man | 4 | 16 of 64 | 3 s |
| United Kingdom | 259 | 2,941 of 4,144 | 8 s |
| world (`--all`) | 93,204 | 1,318,114 of 1,491,264 (12 % skipped) | 2 min, 1.6 GB |

The world list is about 3 MB of text.

## 2. Download: `tessera-dpixel`

Each line of the list is one `tessera-dpixel` run:

```bash
tessera-dpixel --shard 30:27:13 --windows 0,4 --zone_grid zone_grids.json \
  --output /scratch --start 2017-01-01 --end 2017-12-31
```

It expands the shard into its 1024-px sub-windows, keeps those named by
`--windows`, and downloads each in turn from Microsoft Planetary Computer:
Sentinel-2 L2A (ten bands, SCL cloud mask) and Sentinel-1 RTC (VV, VH), one
calendar year. The bounds of a sub-window are `origin + 10 m × (col, row)`
from the zone grid, so the pixels land exactly on the store's grid. The
output is the "d-pixel", the per-pixel time series the encoder consumes:

```
/scratch/
└── utm30/
    ├── r110592c53248/              sub-window 0 of shard 27/13
    │   ├── s2/
    │   │   ├── bands.npy     (T, 1024, 1024, 10) uint16  10 S2 bands
    │   │   ├── masks.npy     (T, 1024, 1024)     uint8   1 = valid
    │   │   └── doys.npy      (T,)                uint16  day of year
    │   └── s1/
    │       ├── sar_ascending.npy       (Ta, 1024, 1024, 2) int16  VV, VH
    │       ├── sar_ascending_doy.npy   (Ta,)               int16
    │       ├── sar_descending.npy      (Td, 1024, 1024, 2) int16
    │       └── sar_descending_doy.npy  (Td,)               int16
    └── r111616c53248/              sub-window 4
        └── …
```

Sizes for one sub-window and one year, measured on zone 30 in 2017 (51
cloud-filtered S2 dates, 119 ascending and 118 descending S1 passes):

| file | size |
|---|---|
| `s2/bands.npy` (B04 B02 B03 B08 B8A B05 B06 B07 B11 B12) | 1.07 GB (20 MB per S2 date) |
| `s2/masks.npy` | 53 MB |
| `s1/sar_ascending.npy` + `sar_descending.npy` | 0.5 GB each (4 MB per pass) |
| **total per sub-window-year** | **≈ 2.1 GB** |
| per fully-live shard-year (16 sub-windows) | ≈ 34 GB |

Scale with the number of clear S2 dates and S1 passes, so cloudy or
high-latitude areas differ. One sub-window-year takes about 3.5 minutes on a
fast link with 32 download workers; the download is latency-bound, not
bandwidth-bound. This is scratch data: it exists to be encoded and deleted.

Behaviour worth knowing:

- Sub-windows already on disk are skipped, so an interrupted shard resumes.
- A sub-window with no Sentinel-2 items at all (open sea) is skipped with a
  message; the uploader later leaves it as no-data. Only read starvation
  (too many dates lost to transient errors, MPC throttling) fails the run,
  with exit code 3, meaning re-queue. For a single tile, exit 2 is a
  permanent failure (mark the cell bad), 3 transient.
- Transient read failures are retried once after re-searching STAC for
  freshly signed URLs, waiting past the current SAS expiry if it is about to
  roll over.
- Concurrency: `--download_workers` (or `$DOWNLOAD_WORKERS`, default 4) is
  the number of simultaneous COG reads per process. Keep it modest when many
  processes run at once: it is their total that trips Planetary Computer's
  rate limiting. GDAL reads its own configuration from the environment
  (`GDAL_NUM_THREADS`, `GDAL_CACHEMAX`, …); CPU threads per process are
  about `download_workers × GDAL_NUM_THREADS`.
- The 0.1° tile path, `--grid_id grid_<lon>_<lat>`, is also supported. It
  reproduces the reference Python implementation byte for byte and exists
  for reproducing and ingesting the existing tile archive; new production
  goes through shards. A whole shard as one `--window 30:110592:53248:4096x4096`
  works too but needs tens of GB of RAM per year.

## 3. Encode: `tessera_encode` (external)

Inference reads one d-pixel directory and writes one embedding pair;
where the pixels are does not enter into it. The v2 encoder used for
production is `tessera_encode` (C++, from the encoder repository), invoked
per sub-window:

```bash
tessera_encode /scratch/utm30/r110592c53248 /embeddings/ [student_large.tcw]
```

It writes, named after the input directory:

```
/embeddings/
├── r110592c53248.npy          (1024, 1024, 128) int8     embedding codes
└── r110592c53248_scales.npy   (1024, 1024)      float32  per-pixel scale
```

128 MiB plus 4 MiB per full sub-window, whatever the number of dates. The
embedding of a pixel is `code × scale`. A pixel with no observations comes
out as an all-zero vector with the quantiser's floor scale `1e-12/127`; the
uploader recognises that signature. See the source for the model, batching
and thread settings (`OMP_NUM_THREADS`, `TC_BATCH`).

## 4. Upload: `tessera-zarr-upload`

When a shard's sub-windows are all encoded, one call writes the shard:

```bash
AWS_ACCESS_KEY_ID=… AWS_SECRET_ACCESS_KEY=… \
tessera-zarr-upload --endpoint https://s3.example --bucket tessera \
  --prefix zarr/v2-world --zone 30 --sr 27 --sc 13 --year 2017 \
  /embeddings/r110592c53248 /embeddings/r111616c53248
```

Each argument is one input: a `.npy` file (its `_scales` partner beside it)
or a directory holding `<basename>.npy` and `<basename>_scales.npy`.
Nothing is scanned, so pass exactly the sub-windows of the shard. The
tool reads the zone's origin, extent, codecs and fill values from the
store's own metadata, assembles a 4096 × 4096 buffer in memory (2 GiB of
int8 plus 64 MiB of scales), pastes each input at its integer offset, and
writes four objects in this order:

```
s3://tessera/zarr/v2-world/
├── zarr.json                                  root group
└── utm30/
    ├── zarr.json                    zone group: spatial:transform, proj:code
    ├── embeddings_d4/c/0/0/27/13    int8 (1, 4,   4096, 4096)  first 4 bands
    ├── embeddings_d16/c/0/0/27/13   int8 (1, 16,  4096, 4096)  first 16 bands
    ├── scales/c/0/27/13             f32  (1, 4096, 4096)
    └── embeddings/c/0/0/27/13       int8 (1, 128, 4096, 4096)  written LAST
```

The key is `array/c/<time index>/[band chunk]/<sr>/<sc>`; the time index is
`year − first year` (2017 is 0). Each object is a Zarr v3 shard: 32 × 32
pixel inner chunks compressed with Blosc (zstd, bitshuffle), Morton-ordered,
with an index at the end, byte-identical to what zarr-python writes. The
`embeddings` object is written last and any stale one deleted first, so its
presence means the shard is complete; that is how a resumed run knows what
is done. Inner chunks that are entirely fill are omitted, so a sub-window
that was never produced costs nothing in the store.

Scales encode coverage: `+inf` is the fill, "nothing was ever produced
here"; `NaN` is "produced, no data" (the encoder's all-zero signature, or
water); finite is valid. Valid pixels of a later input overwrite earlier
ones; no-data never overwrites data.

Sizes per shard-year, measured on a fully covered land area and scaled to
4096 × 4096 (compression is about 59 bytes per pixel for the 128 codes):

| object | size |
|---|---|
| `embeddings` | ≈ 1.0 GB |
| `embeddings_d16` | ≈ 130 MB |
| `embeddings_d4` | ≈ 36 MB |
| `scales` | ≈ 50 MB |
| **total per shard-year** | **≈ 1.2 GB**; less where sub-windows were not produced |

Uploads are multipart (64 MiB parts, four in flight); a shard takes about
10 s to encode and upload on a local network. `--dry_run` assembles without
writing; `--domains` sets the cores used for compression.

Two things to get right at this step: pass all of a shard's sub-windows in
one call, since the shard object is replaced, not merged, and make sure the
`--prefix` store is the one whose `zone_grids.json` the other two steps
used, since the shard indices mean nothing against another grid.

## Scale of a world-year

From the `--all` enumeration: 93,204 shards, 1.32 million live sub-windows.

| stage | per sub-window | per world-year |
|---|---|---|
| d-pixel scratch | ≈ 2.1 GB | ≈ 2.8 PB transient; only sub-windows in flight exist at once |
| embeddings `.npy` | 132 MiB | ≈ 180 TB transient, deleted after upload |
| Zarr store | | ≤ 110 TB, four objects per shard |

Download dominates: at a few minutes per sub-window-year and Planetary
Computer's rate limits, the binding constraint is the total concurrency
across all workers, not CPU.

## Verifying

- dpixel: both the `--grid_id` and the `--window` paths are byte-identical
  to the reference Python implementation (`dpixel.py`) they port: sha256 of
  all seven files on whole 2017 tiles and windows, including a tile
  straddling two UTM zones, with GDAL 3.8, 3.10 and 3.11. See `warp_read` in `bin/tessera_dpixel.ml` for
  how rasterio's WarpedVRT read is reproduced.
- uploader: against a MinIO store seeded from the published beta1 metadata,
  zarr-python reads back embeddings, depth prefixes and scales identical to
  the `.npy`, and tile placement matches geotessera's converter.
- shard: enumerations identical to the production orchestrator's for the
  Isle of Man, the United Kingdom and the world.

## Reference

### tessera-shard

| Flag | Default | Description |
|---|---|---|
| `--shapefile` | (required) | Region polygons: WB GAD ADM0 or any OGR source |
| `--country` | | Region name (`NAM_0`), case-insensitive; repeatable |
| `--all` | off | Every region in the file |
| `--zone_grid` | (required) | Store base URL or `zone_grids.json` |
| `--dump_zone_grid` | | Write the zone grids to this JSON file |
| `--shard_px`, `--window` | `4096`, `1024` | Shard and sub-window side in pixels |
| `--domains` | cores (≤ 32) | Zones processed in parallel |
| `--output` | stdout | Write the list here |
| `--list` | | Print the region names and exit |

### tessera-dpixel

| Flag | Default | Description |
|---|---|---|
| `--shard` | one of these | `ZONE:SR:SC`; runs its sub-windows in turn; needs `--zone_grid` |
| `--windows` | all | With `--shard`: comma-separated sub-window indices, row-major |
| `--window` | one of these | One zone-grid window `ZONE:ROW:COL:HxW`; needs `--zone_grid` |
| `--grid_id` | one of these | A 0.1° tile `grid_<lon>_<lat>` (legacy path) |
| `--zone_grid` | | Store base URL or `zone_grids.json` from `tessera-shard --dump_zone_grid` |
| `--shard_px`, `--subwindow` | `4096`, `1024` | Shard and sub-window side in pixels |
| `--output` | (required) | Output directory; tiles go to `<output>/<grid_id>`, windows to `<output>/utmZZ/r<ROW>c<COL>` |
| `--start`, `--end` | 2024 | Date range, inclusive |
| `--download_workers` | `$DOWNLOAD_WORKERS` or 4 | Concurrent COG reads |
| `--s2_min_load_frac`, `--s1_min_load_frac` | `$S2_…`/`$S1_…` or 0.9 | Read-starvation thresholds (0 disables) |
| `--no_research` | off | No STAC re-search on read failures |
| `--max_cloud` | 100 | STAC `eo:cloud_cover` filter |
| `--layout`, `--flat_output` | `nested`, off | `flat` puts the seven files in one directory; `--flat_output` drops the per-tile directory |

Exit codes: 0 written, 2 permanent failure, 3 transient failure (re-queue).

### tessera-zarr-upload

| Flag | Default | Description |
|---|---|---|
| `--endpoint`, `--bucket`, `--prefix` | `$S3_ENDPOINT`, `$S3_BUCKET`, `$S3_PREFIX` | Destination store |
| `--region` | `$AWS_DEFAULT_REGION` or `us-east-1` | Signing region |
| `--year`, `--first_year` | , 2017 | Time index = year − first year |
| `--time_index` | | Overrides the above |
| `--zone` | | Required for `r<ROW>c<COL>` window inputs |
| `--sr`, `--sc` | all touched | Only write this shard |
| `--domains` | 8 | Compression threads |
| `--dry_run` | off | Assemble, do not write |

Credentials: `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`, else `~/.aws/credentials`.

### Shared geometry: `lib/tile_geom.ml`

The 0.1° tile footprint on its UTM grid (dpixel's `load_roi_from_grid_id`
plus stackstac's snap, computed with PROJ), used by both `tessera-dpixel`
and `tessera-zarr-upload` so a tile is downloaded for the same footprint it
is later placed at. Shard and window addressing never goes through it.

## Data sources

Sentinel-2 L2A and Sentinel-1 RTC from Microsoft Planetary Computer
(`planetarycomputer.microsoft.com`), the source the published store was
built from.
