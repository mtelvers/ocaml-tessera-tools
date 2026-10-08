(* Tessera dpixel download tool.

   Downloads Sentinel-2 L2A + Sentinel-1 RTC for one 0.1-degree grid tile and
   writes the d-pixel .npy arrays consumed by the Tessera encoders.

   This is a port of dpixel.py (the worker pipeline's shared d-pixel core) and
   is byte-identical to it:

   - Tile geometry is derived from the grid id exactly as
     dpixel.load_roi_from_grid_id does (UTM zone from the centre longitude,
     envelope of the four projected corners, integer 10 m pixels). The tiffs in
     global_map_0.1_degree_tiff are all-ones by design, so no tiff is read.
   - Each asset is warped onto the stackstac grid: bounds snapped outwards to
     the 10 m grid (floor/ceil), the whole tile in one go, and the top-left
     H x W pixels are kept. See warp_read for how rasterio's WarpedVRT read is
     reproduced (block-wise warp for sources without nodata, which get an
     alpha band; single whole-grid warp for sources with nodata).
   - S2: SCL nearest, spectral bands bilinear, per-date first-valid-tile
     selection, 0.01 % coverage filter, harmonisation (-1000 where >= 1000
     after 2022-01-25), mask = tile selected.
   - S1: nearest, dB = (20 log10 amp + 50) * 200 clipped to int16, per-date
     mean over ALL of the date's scenes (both orbits), emitted once per orbit
     present that day in sorted order (ascending, descending, unknown -> desc).
     Polarisations are resolved by asset name so single-pol scenes work.
   - Transient read failures are retried once, after re-searching STAC for
     freshly signed URLs (waiting past the current SAS expiry if it is about
     to roll over). A date whose scenes still fail is counted as read-failed.
   - Coverage policy: no S2 items or every S2 date genuinely absent is a
     permanent failure (exit 2); too many read-failed dates is a transient
     failure to re-queue (exit 3).
   - Output layout matches dpixel.save: <dir>/s2/{bands,masks,doys}.npy and
     <dir>/s1/sar_{ascending,descending}{,_doy}.npy.

   Verified byte-identical against stackstac 0.5.1 / rasterio 1.5.2
   (GDAL 3.12.2, PROJ 9.8.1) with GDAL 3.8.4 and 3.11.4 on this side. *)

open Bigarray

(* ======================== Constants ======================== *)

let s2_bands = [| "B04"; "B02"; "B03"; "B08"; "B8A"; "B05"; "B06"; "B07"; "B11"; "B12" |]
let scl_invalid = [| 0; 1; 2; 3; 8; 9 |]
let harmonisation_date_ymd = (2022, 1, 25)
let harmonisation_offset = 1000
let stac_url = "https://planetarycomputer.microsoft.com/api/stac/v1"

(* SAS freshness knobs (dpixel._memoize_research) *)
let sas_margin = 30.0
let sas_grace = 5.0

(* ======================== Utility helpers ======================== *)

let eprintf fmt = Printf.eprintf fmt
let printf fmt = Printf.printf fmt

let is_scl_invalid v = Array.exists (fun x -> x = v) scl_invalid

let rec mkdir_p dir =
  if dir <> "/" && dir <> "." && not (Sys.file_exists dir) then begin
    mkdir_p (Filename.dirname dir);
    (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ())
  end

(** Days since 1970-01-01 for a proleptic Gregorian civil date. *)
let days_from_civil y m d =
  let y = if m <= 2 then y - 1 else y in
  let era = (if y >= 0 then y else y - 399) / 400 in
  let yoe = y - era * 400 in
  let mp = (m + 9) mod 12 in
  let doy = (153 * mp + 2) / 5 + d - 1 in
  let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy in
  era * 146097 + doe - 719468

(** Day-of-year (1-366) from "YYYY-MM-DD" *)
let doy_of_date_str s =
  Scanf.sscanf s "%d-%d-%d" (fun y m d ->
    days_from_civil y m d - days_from_civil y 1 1 + 1)

(** Parse an ISO-8601 UTC datetime "YYYY-MM-DDTHH:MM:SS[.ffffff]Z" to epoch
    seconds (float, fractional part kept). Offsets other than Z are ignored
    (STAC datetimes are UTC). *)
let epoch_of_datetime s =
  try
    Scanf.sscanf s "%d-%d-%dT%d:%d:%d%s" (fun y mo d h mi sec rest ->
      let frac =
        if String.length rest > 1 && rest.[0] = '.' then begin
          let digits = Buffer.create 6 in
          (try String.iteri (fun i c ->
             if i > 0 then (if c >= '0' && c <= '9' then Buffer.add_char digits c
                            else raise Exit)) rest with Exit -> ());
          let ds = Buffer.contents digits in
          if ds = "" then 0.0
          else float_of_string ("0." ^ ds)
        end else 0.0 in
      Float.of_int (days_from_civil y mo d) *. 86400.0
      +. Float.of_int (h * 3600 + mi * 60 + sec) +. frac)
  with _ -> 0.0

(** Check if date_str > harmonisation_date *)
let is_after_harmonisation date_str =
  Scanf.sscanf date_str "%d-%d-%d" (fun y m d -> (y, m, d) > harmonisation_date_ymd)

(** Extract just YYYY-MM-DD from an ISO datetime string *)
let date_of_datetime dt =
  if String.length dt >= 10 then String.sub dt 0 10 else dt

let item_datetime (it : Stac_client.item) =
  match Stac_client.get_datetime it with Some d -> d | None -> ""

(** Get asset href from a STAC item *)
let get_asset_href (item : Stac_client.item) key =
  match List.assoc_opt key item.assets with
  | Some a -> Some a.href
  | None -> None

(** Retry [f] a few times with backoff; used around STAC search and SAS
    signing, which fail transiently (gateway 5xx). *)
let with_retries ?(attempts = 4) ~label f =
  let rec go n delay =
    try f () with exn when n < attempts ->
      eprintf "  %s failed (%s); retrying in %.0fs\n%!" label (Printexc.to_string exn) delay;
      Unix.sleepf delay;
      go (n + 1) (delay *. 2.0)
  in
  go 1 2.0

(** Environment-driven defaults, same names as the Python worker stack. *)
let env_int name default =
  match Sys.getenv_opt name with
  | Some v -> (try int_of_string (String.trim v) with _ -> default)
  | None -> default

let env_float name default =
  match Sys.getenv_opt name with
  | Some v -> (try float_of_string (String.trim v) with _ -> default)
  | None -> default

(** GDAL reads every config option from the environment itself; only supply a
    default when the caller has not set one, so GDAL_NUM_THREADS, GDAL_CACHEMAX,
    CPL_VSIL_CURL_CACHE_SIZE etc. in the environment win. *)
let set_config_default key value =
  if Sys.getenv_opt key = None then Gdal.set_config_option key value

(* ======================== Parallel map ======================== *)

(* OCaml 5 allows at most 128 domains including the main one. *)
let max_domains = 120

let parallel_map ~n_workers f items =
  let n = Array.length items in
  if n = 0 then [||]
  else if n_workers <= 1 || n = 1 then Array.map f items
  else begin
    let results = Array.make n None in
    let next = Atomic.make 0 in
    let actual = min (min n_workers max_domains) n in
    let domains = Array.init actual (fun _ ->
      Domain.spawn (fun () ->
        let rec loop () =
          let i = Atomic.fetch_and_add next 1 in
          if i < n then begin
            results.(i) <- Some (f items.(i));
            loop ()
          end
        in loop ())
    ) in
    Array.iter Domain.join domains;
    Array.map (function Some r -> r | None -> assert false) results
  end

(* ======================== ROI ======================== *)

type roi = {
  dst_srs : string;                         (* "EPSG:326xx" or WKT, for -t_srs *)
  grid_bounds : float * float * float * float;  (* snapped minx, miny, maxx, maxy *)
  w_out : int; h_out : int;                 (* snapped (stackstac) grid size *)
  height : int; width : int;                (* output H, W (top-left crop) *)
  resolution : float;
  bbox : float * float * float * float;     (* lon/lat for STAC search *)
}

let parse_grid_id = Tessera_common.Tile_geom.parse_grid_id
let snapped_bounds = Tessera_common.Tile_geom.snapped_bounds

(** dpixel.load_roi_from_grid_id + stackstac's snap: see Tile_geom. *)
let roi_of_grid lon lat =
  let g = Tessera_common.Tile_geom.of_centre lon lat in
  { dst_srs = Printf.sprintf "EPSG:%d" g.epsg;
    grid_bounds = (g.minx, g.maxy -. 10.0 *. Float.of_int g.h_out,
                   g.minx +. 10.0 *. Float.of_int g.w_out, g.maxy);
    w_out = g.w_out; h_out = g.h_out; height = g.height; width = g.width; resolution = 10.0;
    bbox = (lon -. 0.05, lat -. 0.05, lon +. 0.05, lat +. 0.05) }

(* ======================== Grid-aligned windows ======================== *)

module Zone_grid = Tessera_common.Zone_grid

(** zonegrid.window_bbox_lonlat: lon/lat bbox of a projected window for the
    STAC search, sampling the edges (a straight projected edge bows in lon/lat)
    with a 0.01 degree margin. *)
let window_bbox_lonlat ~epsg (left, bottom, right, top) =
  let src = Gdal.SpatialReference.of_epsg epsg |> Result.get_ok in
  let dst = Gdal.SpatialReference.of_epsg 4326 |> Result.get_ok in
  Gdal.SpatialReference.set_axis_mapping_strategy src Gdal.oams_traditional_gis_order;
  Gdal.SpatialReference.set_axis_mapping_strategy dst Gdal.oams_traditional_gis_order;
  let ct = Gdal.CoordinateTransformation.create src dst |> Result.get_ok in
  let n = 8 in
  let pts = Array.concat (List.init (n + 1) (fun i ->
    let fx = left +. (right -. left) *. Float.of_int i /. Float.of_int n in
    let fy = bottom +. (top -. bottom) *. Float.of_int i /. Float.of_int n in
    [| (fx, bottom); (fx, top); (left, fy); (right, fy) |])) in
  let ll = Gdal.CoordinateTransformation.transform_points ct pts |> Result.get_ok in
  Gdal.CoordinateTransformation.destroy ct;
  Gdal.SpatialReference.destroy src;
  Gdal.SpatialReference.destroy dst;
  let lons = Array.map fst ll and lats = Array.map snd ll in
  let fmin a = Array.fold_left Float.min a.(0) a and fmax a = Array.fold_left Float.max a.(0) a in
  let margin = 0.01 in
  (fmin lons -. margin, fmin lats -. margin, fmax lons +. margin, fmax lats +. margin)

(** A window cut from the zone grid at pixel (row, col), h x w pixels. Bounds are exact multiples of the
    pixel size so the stackstac snap is a no-op and nothing is cropped. The
    imagery is read in the real CRS: south of the equator that is the 327xx
    code and +10,000 km of northing. *)
let roi_of_window (g : Zone_grid.t) ~row ~col ~h ~w =
  if row < 0 || col < 0 || h <= 0 || w <= 0
     || row + h > g.height_px || col + w > g.width_px then
    failwith (Printf.sprintf "window r%dc%d %dx%d does not fit zone %02d grid (%d x %d px)"
                row col h w g.zone g.width_px g.height_px);
  let px = g.pixel in
  let left = g.origin_x +. Float.of_int col *. px in
  let top = g.origin_y -. Float.of_int row *. px in
  let bottom = top -. Float.of_int h *. px in
  let right = left +. Float.of_int w *. px in
  let south = bottom < 0.0 in
  let epsg = if south then g.epsg + 100 else g.epsg in
  let adj n = if south then n +. 10_000_000.0 else n in
  let bounds = (left, adj bottom, right, adj top) in
  let (minx, miny, maxx, maxy) as gb = snapped_bounds bounds px in
  let w_out = Float.to_int (Float.round ((maxx -. minx) /. px)) in
  let h_out = Float.to_int (Float.round ((maxy -. miny) /. px)) in
  if w_out <> w || h_out <> h then
    failwith (Printf.sprintf "window bounds are not grid-aligned: snapped to %dx%d, asked %dx%d"
                h_out w_out h w);
  { dst_srs = Printf.sprintf "EPSG:%d" epsg; grid_bounds = gb; w_out; h_out;
    height = h; width = w; resolution = px;
    bbox = window_bbox_lonlat ~epsg bounds }

(** "ZONE:ROW:COL:HxW" *)
let parse_window s =
  match String.split_on_char ':' s with
  | [ z; r; c; size ] ->
    (match String.split_on_char 'x' size with
     | [ h; w ] ->
       (try Some (int_of_string z, int_of_string r, int_of_string c, int_of_string h, int_of_string w)
        with _ -> None)
     | _ -> None)
  | _ -> None

(* ======================== COG reading via warped VRT ======================== *)

type failure_kind = Transient | Permanent

exception Read_failure of failure_kind * string

(** A signed HTTPS asset URL as a GDAL virtual filesystem path. *)
let gdal_vsi_path url = "/vsicurl/" ^ url

(** Warp [url] onto the ROI's snapped grid and return the top-left H x W
    window of band 1 as a bigarray of the requested kind.

    This reproduces what rasterio's WarpedVRT does under stackstac, which
    depends on whether the source has a nodata value:

    - No nodata (Sentinel-2 L2A on MPC): rasterio adds an alpha band
      (add_alpha). GDAL's optimised whole-image read of a warped VRT refuses
      datasets whose requested bands include a non-warped (alpha) band, so the
      read falls back to the block cache: the warp is done in 512 x 128 blocks.
      We build the same warped VRT (-dstalpha) and read band 1 through the band
      API, which is the same block path in every GDAL version. In-footprint
      zeros count as data (bilinear blends them); only alpha = 0 pixels are
      masked, and those are zeroed here (dpixel.py: NaN -> 0).
    - Nodata set (Sentinel-1 RTC, -32768): no alpha, one band, and rasterio's
      whole-image read is a single WarpRegionToBuffer over the full snapped
      grid. A single-chunk gdalwarp to MEM over the full grid is the same
      operation (the fill-ratio heuristic that would split low-coverage
      scenes into chunks is disabled), and works on GDAL 3.8 too. Nodata
      pixels are zeroed.

    Reading a sub-window of the grid would change the scanline extents fed to
    GDAL's approximate transformer and flip isolated nearest-neighbour pixels,
    so the nodata path always warps the whole grid and crops afterwards.
    Any GDAL failure is raised as a transient Read_failure. *)
let warp_read (type a b) (kind : (a, b) Gdal.ba_kind_witness) ~(roi : roi) ~resampling url
    : (a, b, c_layout) Array2.t =
  let fail msg = raise (Read_failure (Transient, msg)) in
  let src = match Gdal.Dataset.open_ex (gdal_vsi_path url) with
    | Ok ds -> ds
    | Error msg -> fail (Printf.sprintf "open failed: %s" msg) in
  let finish_src () = Gdal.Dataset.close src in
  let nodata =
    match Gdal.Dataset.get_band src 1 with
    | Ok b -> (match Gdal.RasterBand.no_data_value b with Ok nd -> nd | Error _ -> None)
    | Error _ -> None in
  let (minx, miny, maxx, maxy) = roi.grid_bounds in
  let common = [
    "-t_srs"; roi.dst_srs;
    "-te"; Printf.sprintf "%.15g" minx; Printf.sprintf "%.15g" miny;
           Printf.sprintf "%.15g" maxx; Printf.sprintf "%.15g" maxy;
    "-ts"; string_of_int roi.w_out; string_of_int roi.h_out;
    "-r"; resampling;
  ] in
  let opts = match nodata with
    | None -> common @ [ "-of"; "VRT"; "-dstalpha" ]
    | Some _ -> common @ [ "-of"; "MEM"; "-wo"; "SRC_FILL_RATIO_HEURISTICS=NO" ] in
  let warped = match Gdal.Dataset.warp src ~dst_filename:"" opts with
    | Ok ds -> ds
    | Error msg -> finish_src (); fail (Printf.sprintf "warp failed: %s" msg) in
  let finish () = Gdal.Dataset.close warped; finish_src () in
  let zero : a = match kind with
    | Gdal.BA_int8 -> 0 | Gdal.BA_byte -> 0 | Gdal.BA_uint16 -> 0 | Gdal.BA_int16 -> 0
    | Gdal.BA_int32 -> 0l | Gdal.BA_int64 -> 0L
    | Gdal.BA_float32 -> 0.0 | Gdal.BA_float64 -> 0.0 in
  let band = match Gdal.Dataset.get_band warped 1 with
    | Ok b -> b | Error msg -> finish (); fail msg in
  let h = roi.height and w = roi.width in
  match nodata with
  | None ->
    (* block path: sub-window read of band 1 + alpha *)
    let read k b =
      Gdal.RasterBand.read_region k b ~x_off:0 ~y_off:0 ~x_size:w ~y_size:h ~buf_x:w ~buf_y:h in
    let data = match read kind band with
      | Ok d -> d | Error msg -> finish (); fail (Printf.sprintf "read failed: %s" msg) in
    (match Gdal.Dataset.get_band warped 2 with
     | Ok ab ->
       (match read Gdal.BA_byte ab with
        | Ok alpha ->
          for i = 0 to h - 1 do
            for j = 0 to w - 1 do
              if Array2.unsafe_get alpha i j = 0 then Array2.unsafe_set data i j zero
            done
          done
        | Error msg -> finish (); fail (Printf.sprintf "alpha read failed: %s" msg))
     | Error msg -> finish (); fail msg);
    finish ();
    data
  | Some nd ->
    (* whole-grid warp already done into MEM; crop and zero nodata *)
    let full = match Gdal.RasterBand.read_region kind band ~x_off:0 ~y_off:0
                       ~x_size:roi.w_out ~y_size:roi.h_out ~buf_x:roi.w_out ~buf_y:roi.h_out with
      | Ok d -> d | Error msg -> finish (); fail (Printf.sprintf "read failed: %s" msg) in
    finish ();
    let data = Array2.create (Array2.kind full) c_layout h w in
    let is_nodata : a -> bool = match kind with
      | Gdal.BA_int8 -> fun v -> Float.of_int v = nd
      | Gdal.BA_byte -> fun v -> Float.of_int v = nd
      | Gdal.BA_uint16 -> fun v -> Float.of_int v = nd
      | Gdal.BA_int16 -> fun v -> Float.of_int v = nd
      | Gdal.BA_int32 -> fun v -> Int32.to_float v = nd
      | Gdal.BA_int64 -> fun v -> Int64.to_float v = nd
      | Gdal.BA_float32 -> fun v -> v = nd || Float.is_nan v
      | Gdal.BA_float64 -> fun v -> v = nd || Float.is_nan v in
    for i = 0 to h - 1 do
      for j = 0 to w - 1 do
        let v = Array2.unsafe_get full i j in
        Array2.unsafe_set data i j (if is_nodata v then zero else v)
      done
    done;
    data

(* ======================== STAC items ======================== *)

type s_item = {
  it : Stac_client.item;   (* signed *)
  dt : float;              (* epoch seconds *)
  date : string;           (* YYYY-MM-DD (UTC) *)
  orbit : string;          (* sat:orbit_state or "unknown" *)
}

let s_item_of (it : Stac_client.item) =
  let dts = item_datetime it in
  { it; dt = epoch_of_datetime dts; date = date_of_datetime dts;
    orbit = (match Stac_client.get_string_prop it "sat:orbit_state" with
             | Some o -> o | None -> "unknown") }

(** Group by acquisition date; dates sorted; within a date a stable sort by
    datetime so ties keep STAC order (matches dpixel.py). *)
let group_by_date (items : s_item list) =
  let tbl = Hashtbl.create 64 in
  List.iter (fun si ->
    let prev = try Hashtbl.find tbl si.date with Not_found -> [] in
    Hashtbl.replace tbl si.date (si :: prev)) items;
  let dates = List.sort String.compare (Hashtbl.fold (fun k _ acc -> k :: acc) tbl []) in
  List.map (fun d ->
    let its = List.rev (Hashtbl.find tbl d) in
    (d, List.stable_sort (fun a b -> compare a.dt b.dt) its)) dates

(* -- SAS expiry / re-search memoisation (dpixel._memoize_research) --------- *)

let url_decode s =
  let b = Buffer.create (String.length s) in
  let n = String.length s in
  let rec go i =
    if i < n then begin
      if s.[i] = '%' && i + 2 < n then begin
        (try Buffer.add_char b (Char.chr (int_of_string ("0x" ^ String.sub s (i + 1) 2)))
         with _ -> Buffer.add_char b '%');
        go (i + 3)
      end else begin Buffer.add_char b s.[i]; go (i + 1) end
    end in
  go 0; Buffer.contents b

(** Earliest SAS expiry (epoch) over all asset hrefs' [se=] query params. *)
let sas_expiry_epoch (items : Stac_client.item list) =
  List.fold_left (fun acc (it : Stac_client.item) ->
    List.fold_left (fun acc (_, (a : Stac_client.asset)) ->
      match String.index_opt a.href '?' with
      | None -> acc
      | Some q ->
        let query = String.sub a.href (q + 1) (String.length a.href - q - 1) in
        List.fold_left (fun acc kv ->
          match String.index_opt kv '=' with
          | Some e when String.sub kv 0 e = "se" ->
            let v = url_decode (String.sub kv (e + 1) (String.length kv - e - 1)) in
            let t = epoch_of_datetime v in
            if t <= 0.0 then acc
            else (match acc with None -> Some t | Some a -> Some (Float.min a t))
          | _ -> acc) acc (String.split_on_char '&' query)
    ) acc it.assets) None items

(** Wrap a search+sign closure so it only re-runs when the cached signed URLs
    are near expiry, waiting past the real expiry so PC rolls its token. Must
    be called from the main domain only. *)
let memoize_research (re_search : (unit -> Stac_client.item list) option) =
  match re_search with
  | None -> None
  | Some rs ->
    let cache = ref None in
    Some (fun () ->
      let rec go tries =
        let now = Unix.gettimeofday () in
        match !cache with
        | Some (items, exp) when (exp = None || now < Option.get exp -. sas_margin) -> items
        | _ when tries >= 3 -> (match !cache with Some (items, _) -> items | None -> [])
        | _ ->
          (match !cache with
           | Some (_, Some exp) when now < exp ->
             let wait = exp -. now +. sas_grace in
             printf "  SAS token expires in %.0fs; waiting %.0fs for PC to roll over before re-searching\n%!"
               (exp -. now) wait;
             Unix.sleepf wait
           | _ -> ());
          let items = with_retries ~label:"STAC re-search" rs in
          cache := Some (items, sas_expiry_epoch items);
          go (tries + 1)
      in
      go 0)

(** Replace failed items by their freshly signed counterparts (by id). Items
    missing from the fresh search are dropped. *)
let refresh_items research (failed : s_item list) =
  match research with
  | None -> []
  | Some rs ->
    let fresh = rs () in
    let tbl = Hashtbl.create 64 in
    List.iter (fun (it : Stac_client.item) -> Hashtbl.replace tbl it.id it) fresh;
    List.filter_map (fun si ->
      match Hashtbl.find_opt tbl si.it.id with
      | Some it -> Some { si with it }
      | None -> None) failed

(* ======================== Coverage ======================== *)

type coverage = {
  mutable found : int;
  mutable valid : int;
  mutable cloud : int;
  mutable read_failed : int;
  mutable unavailable : int;
}

let new_coverage () = { found = 0; valid = 0; cloud = 0; read_failed = 0; unavailable = 0 }

let read_fail_frac c =
  if c.found = 0 then 0.0 else Float.of_int c.read_failed /. Float.of_int c.found

(* ======================== Output frames ======================== *)

type u16 = (int, int16_unsigned_elt, c_layout) Array1.t
type u8 = (int, int8_unsigned_elt, c_layout) Array1.t
type i16 = (int, int16_signed_elt, c_layout) Array1.t

let flat2 (a : (_, _, c_layout) Array2.t) = reshape_1 (genarray_of_array2 a) (Array2.dim1 a * Array2.dim2 a)

(* ======================== process_s2 ======================== *)

type s2_date_result =
  | S2_ok of u16 * u8 * int        (* bands (H*W*10), mask (H*W), doy *)
  | S2_retry of s_item list        (* items that failed transiently *)
  | S2_dropped                     (* all items failed permanently after retry *)

let process_s2 ~(roi : roi) ~n_workers ~research (items : s_item list) =
  let h = roi.height and w = roi.width in
  let hw = h * w in
  let cov = new_coverage () in
  if items = [] then begin
    printf "  No S2 items found\n%!";
    ([], [], [], cov)
  end else begin
    let by_date = group_by_date items in
    cov.found <- List.length by_date;
    printf "  Streaming %d S2 scenes across %d dates...\n%!" (List.length items) (List.length by_date);

    (* ---- Pass 1: SCL for every scene (parallel), retry transients once ---- *)
    let scl_name = "SCL" in
    let load_scl (si : s_item) =
      match get_asset_href si.it scl_name with
      | None -> Error (Permanent, "no SCL asset")
      | Some href ->
        (try Ok (warp_read Gdal.BA_byte ~roi ~resampling:"near" href)
         with Read_failure (k, m) -> Error (k, m)) in
    let all_items = Array.of_list items in
    let results = parallel_map ~n_workers load_scl all_items in
    let scl_tbl = Hashtbl.create 256 in     (* item id -> scl array *)
    let failed_tbl = Hashtbl.create 16 in   (* item id -> failure kind *)
    Array.iteri (fun i r -> match r with
      | Ok a -> Hashtbl.replace scl_tbl all_items.(i).it.id a
      | Error (k, m) ->
        eprintf "  first-pass skipped %s (SCL): %s\n%!" all_items.(i).it.id m;
        Hashtbl.replace failed_tbl all_items.(i).it.id k) results;
    let transient = List.filter (fun si ->
      Hashtbl.find_opt failed_tbl si.it.id = Some Transient) items in
    if transient <> [] && research <> None then begin
      printf "  re-searching STAC for %d retry items with fresh signatures...\n%!" (List.length transient);
      let retry = Array.of_list (refresh_items research transient) in
      let rr = parallel_map ~n_workers load_scl retry in
      Array.iteri (fun i r -> match r with
        | Ok a -> Hashtbl.replace scl_tbl retry.(i).it.id a; Hashtbl.remove failed_tbl retry.(i).it.id
        | Error (_, m) -> eprintf "  retry-pass skipped %s (SCL): %s\n%!" retry.(i).it.id m) rr
    end;

    (* ---- tile selection per date ---- *)
    let valid_dates = List.filter_map (fun (date, date_items) ->
      let scl_items = List.filter (fun si -> Hashtbl.mem scl_tbl si.it.id) date_items in
      if scl_items = [] then begin
        let any_transient = List.exists (fun si ->
          Hashtbl.find_opt failed_tbl si.it.id = Some Transient) date_items in
        if any_transient then cov.read_failed <- cov.read_failed + 1
        else cov.unavailable <- cov.unavailable + 1;
        None
      end else begin
        let tile_sel = Array1.create int16_signed c_layout hw in
        Array1.fill tile_sel (-1);
        List.iteri (fun t si ->
          let scl = flat2 (Hashtbl.find scl_tbl si.it.id) in
          for p = 0 to hw - 1 do
            if Array1.unsafe_get tile_sel p < 0
               && not (is_scl_invalid (Array1.unsafe_get scl p)) then
              Array1.unsafe_set tile_sel p t
          done) scl_items;
        let valid_cnt = ref 0 in
        for p = 0 to hw - 1 do if Array1.unsafe_get tile_sel p >= 0 then incr valid_cnt done;
        let valid_pct = 100.0 *. Float.of_int !valid_cnt /. Float.of_int hw in
        if valid_pct < 0.01 then begin cov.cloud <- cov.cloud + 1; None end
        else Some (date, scl_items, tile_sel)
      end) by_date in
    (* SCL arrays for cloud-filtered dates are no longer needed *)
    let keep = Hashtbl.create 256 in
    List.iter (fun (_, its, _) -> List.iter (fun si -> Hashtbl.replace keep si.it.id ()) its) valid_dates;
    Hashtbl.filter_map_inplace (fun id a -> if Hashtbl.mem keep id then Some a else None) scl_tbl;
    printf "  %d/%d dates pass cloud filter\n%!" (List.length valid_dates) (List.length by_date);

    (* ---- Pass 2: spectral bands per valid date ---- *)
    let band_names = s2_bands in
    let load_date (date, (scl_items : s_item list), (tile_sel : i16)) =
      let n_tiles = List.length scl_items in
      let failed = ref [] in
      let tile_bands = List.map (fun si ->
        try
          Some (Array.map (fun band ->
            match get_asset_href si.it band with
            | None -> raise (Read_failure (Permanent, "no " ^ band ^ " asset"))
            | Some href -> flat2 (warp_read Gdal.BA_uint16 ~roi ~resampling:"bilinear" href)
          ) band_names)
        with Read_failure (k, m) ->
          eprintf "  %s: skipped %s (%s): %s\n%!" date si.it.id
            (match k with Transient -> "transient" | Permanent -> "permanent") m;
          if k = Transient then failed := si :: !failed;
          None) scl_items in
      if !failed <> [] then S2_retry (List.rev !failed)
      else if List.exists Option.is_none tile_bands then S2_dropped
      else begin
        let tiles = Array.of_list (List.map Option.get tile_bands) in
        let after = is_after_harmonisation date in
        let out : u16 = Array1.create int16_unsigned c_layout (hw * 10) in
        for bi = 0 to 9 do
          for p = 0 to hw - 1 do
            let ts = Array1.unsafe_get tile_sel p in
            let v =
              if ts >= 0 && ts < n_tiles then Array1.unsafe_get tiles.(ts).(bi) p
              else if n_tiles > 0 then Array1.unsafe_get tiles.(0).(bi) p
              else 0 in
            let v = if after && v >= harmonisation_offset then v - harmonisation_offset else v in
            Array1.unsafe_set out (p * 10 + bi) v
          done
        done;
        let mask : u8 = Array1.create int8_unsigned c_layout hw in
        for p = 0 to hw - 1 do
          Array1.unsafe_set mask p (if Array1.unsafe_get tile_sel p >= 0 then 1 else 0)
        done;
        S2_ok (out, mask, doy_of_date_str date)
      end in
    let valid_arr = Array.of_list valid_dates in
    let results = parallel_map ~n_workers load_date valid_arr in
    (* retry-at-end: dates whose scenes failed transiently, with fresh URLs *)
    let retry_idx = List.filter (fun i -> match results.(i) with S2_retry _ -> true | _ -> false)
        (List.init (Array.length results) Fun.id) in
    if retry_idx <> [] && research <> None then begin
      let n_items = List.fold_left (fun acc i -> match results.(i) with
        | S2_retry l -> acc + List.length l | _ -> acc) 0 retry_idx in
      printf "  re-searching STAC for %d retry items with fresh signatures...\n%!" n_items;
      let fresh_dates = Array.of_list (List.map (fun i ->
        let (date, scl_items, tile_sel) = valid_arr.(i) in
        let refreshed = refresh_items research scl_items in
        (* keep the original ordering; drop scenes that vanished *)
        let scl_items = List.filter_map (fun si ->
          List.find_opt (fun r -> r.it.id = si.it.id) refreshed) scl_items in
        (date, scl_items, tile_sel)) retry_idx) in
      let rr = parallel_map ~n_workers (fun (date, scl_items, tile_sel) ->
        if List.length scl_items = 0 then S2_dropped
        else load_date (date, scl_items, tile_sel)) fresh_dates in
      List.iteri (fun k i -> results.(i) <- rr.(k)) retry_idx
    end;
    let bands = ref [] and masks = ref [] and doys = ref [] in
    Array.iteri (fun i r ->
      let (date, _, _) = valid_arr.(i) in
      match r with
      | S2_ok (b, m, d) -> bands := b :: !bands; masks := m :: !masks; doys := d :: !doys
      | S2_retry _ | S2_dropped ->
        printf "  dropping %s: SCL valid but spectral bands did not load\n%!" date;
        cov.read_failed <- cov.read_failed + 1) results;
    cov.valid <- List.length !bands;
    printf "  S2 coverage: %d valid, %d cloud, %d read-failed, %d unavailable of %d dates\n%!"
      cov.valid cov.cloud cov.read_failed cov.unavailable cov.found;
    (List.rev !bands, List.rev !masks, List.rev !doys, cov)
  end

(* ======================== S1 processing ======================== *)

(** amplitude -> scaled dB int16 (H*W), zero where amp invalid.
    (20*log10(amp) + 50) * 200, clipped to [0, 32767], truncated. *)
let amplitude_to_db ~(roi : roi) (amp : (float, float32_elt, c_layout) Array1.t) : i16 =
  let hw = roi.height * roi.width in
  let out = Array1.create int16_signed c_layout hw in
  for p = 0 to hw - 1 do
    let a = Array1.unsafe_get amp p in
    let v =
      if Float.is_finite a && a > 0.0 then begin
        let scaled = (20.0 *. Float.log10 a +. 50.0) *. 200.0 in
        Float.to_int (Float.min 32767.0 (Float.max 0.0 scaled))
      end else 0 in
    Array1.unsafe_set out p v
  done;
  out

(** Mean of the positive dB values across tiles, truncated to int16; None if
    no pixel is valid in any tile. *)
let mosaic_mean ~hw (db_list : i16 list) : i16 option =
  if db_list = [] then None
  else begin
    let sum = Array1.create float64 c_layout hw in
    Array1.fill sum 0.0;
    let cnt = Bytes.make hw '\000' in
    let any = ref false in
    List.iter (fun db ->
      for p = 0 to hw - 1 do
        let v = Array1.unsafe_get db p in
        if v > 0 then begin
          any := true;
          Array1.unsafe_set sum p (Array1.unsafe_get sum p +. Float.of_int v);
          Bytes.unsafe_set cnt p (Char.unsafe_chr (Char.code (Bytes.unsafe_get cnt p) + 1))
        end
      done) db_list;
    if not !any then None
    else begin
      let out = Array1.create int16_signed c_layout hw in
      for p = 0 to hw - 1 do
        let c = Char.code (Bytes.unsafe_get cnt p) in
        Array1.unsafe_set out p
          (if c > 0 then Float.to_int (Array1.unsafe_get sum p /. Float.of_int c) else 0)
      done;
      Some out
    end
  end

let interleave_vv_vh ~hw (vv : i16 option) (vh : i16 option) : i16 =
  let out = Array1.create int16_signed c_layout (hw * 2) in
  for p = 0 to hw - 1 do
    Array1.unsafe_set out (2 * p) (match vv with Some a -> Array1.unsafe_get a p | None -> 0);
    Array1.unsafe_set out (2 * p + 1) (match vh with Some a -> Array1.unsafe_get a p | None -> 0)
  done;
  out

type s1_date_result =
  | S1_frames of (string * int * i16) list   (* (orbit, doy, frame) *)
  | S1_retry of s_item list
  | S1_unavailable                           (* no loadable scene (e.g. HH/HV) *)
  | S1_skipped                               (* loaded but nothing valid in ROI *)

(** dpixel.process_s1: per date, mosaic ALL of the date's scenes, then
    emit that mosaic once per orbit present, in sorted orbit order. *)
let process_s1 ~(roi : roi) ~n_workers ~research (items : s_item list) =
  let hw = roi.height * roi.width in
  let cov = new_coverage () in
  if items = [] then begin
    printf "  No S1 items found\n%!";
    ([], [], [], [], cov)
  end else begin
    let by_date = group_by_date items in
    cov.found <- List.length by_date;
    printf "  Streaming %d S1 scenes across %d dates...\n%!" (List.length items) (List.length by_date);
    let load_date (date, (date_items : s_item list)) =
      let failed = ref [] in
      let loaded = List.filter_map (fun si ->
        let vv = get_asset_href si.it "vv" and vh = get_asset_href si.it "vh" in
        if vv = None && vh = None then begin
          eprintf "  %s: skipped %s: no vv/vh asset (wrong polarisation)\n%!" date si.it.id;
          None
        end else
          try
            let rd = function
              | None -> None
              | Some href ->
                Some (amplitude_to_db ~roi (flat2 (warp_read Gdal.BA_float32 ~roi ~resampling:"near" href))) in
            Some (si, rd vv, rd vh)
          with Read_failure (_, m) ->
            eprintf "  %s: skipped %s: %s\n%!" date si.it.id m;
            failed := si :: !failed; None) date_items in
      if !failed <> [] then S1_retry (List.rev !failed)
      else if loaded = [] then S1_unavailable
      else begin
        let vv_out = mosaic_mean ~hw (List.filter_map (fun (_, vv, _) -> vv) loaded) in
        let vh_out = mosaic_mean ~hw (List.filter_map (fun (_, _, vh) -> vh) loaded) in
        if vv_out = None && vh_out = None then S1_skipped
        else begin
          let frame = interleave_vv_vh ~hw vv_out vh_out in
          let doy = doy_of_date_str date in
          let orbits = List.sort_uniq String.compare (List.map (fun (si, _, _) -> si.orbit) loaded) in
          S1_frames (List.map (fun o -> (o, doy, frame)) orbits)
        end
      end in
    let dates_arr = Array.of_list by_date in
    let results = parallel_map ~n_workers load_date dates_arr in
    let retry_idx = List.filter (fun i -> match results.(i) with S1_retry _ -> true | _ -> false)
        (List.init (Array.length results) Fun.id) in
    if retry_idx <> [] && research <> None then begin
      let n_items = List.fold_left (fun acc i -> match results.(i) with
        | S1_retry l -> acc + List.length l | _ -> acc) 0 retry_idx in
      printf "  re-searching STAC for %d retry items with fresh signatures...\n%!" n_items;
      let fresh = Array.of_list (List.map (fun i ->
        let (date, date_items) = dates_arr.(i) in
        let refreshed = refresh_items research date_items in
        let date_items = List.filter_map (fun si ->
          List.find_opt (fun r -> r.it.id = si.it.id) refreshed) date_items in
        (date, date_items)) retry_idx) in
      let rr = parallel_map ~n_workers (fun (date, date_items) ->
        if date_items = [] then S1_unavailable else load_date (date, date_items)) fresh in
      List.iteri (fun k i -> results.(i) <- rr.(k)) retry_idx
    end;
    let asc = ref [] and asc_d = ref [] and desc = ref [] and desc_d = ref [] in
    let any_loaded = ref false in
    Array.iter (fun r -> match r with
      | S1_frames frames ->
        any_loaded := true; cov.valid <- cov.valid + 1;
        List.iter (fun (orbit, doy, frame) ->
          if orbit = "ascending" then begin asc := frame :: !asc; asc_d := doy :: !asc_d end
          else begin desc := frame :: !desc; desc_d := doy :: !desc_d end) frames
      | S1_skipped -> any_loaded := true
      | S1_retry _ -> cov.read_failed <- cov.read_failed + 1
      | S1_unavailable -> cov.unavailable <- cov.unavailable + 1) results;
    printf "  S1 coverage: %d valid, %d read-failed, %d unavailable of %d dates\n%!"
      cov.valid cov.read_failed cov.unavailable cov.found;
    if not !any_loaded then printf "  no usable S1 scenes -> proceeding S2-only\n%!";
    (List.rev !asc, List.rev !asc_d, List.rev !desc, List.rev !desc_d, cov)
  end

(* ======================== Coverage policy ======================== *)

exception All_scenes_dropped of string   (* permanent: mark cell bad *)
exception Read_starved of string         (* transient: re-queue *)

let apply_coverage_policy ~grid_id ~s2_min_load_frac ~s1_min_load_frac cov_s2 cov_s1 =
  if cov_s2.found = 0 then
    raise (All_scenes_dropped (Printf.sprintf "%s: no S2 STAC items (out of coverage)" grid_id));
  if s2_min_load_frac > 0.0 && read_fail_frac cov_s2 > 1.0 -. s2_min_load_frac then
    raise (Read_starved (Printf.sprintf "%s: S2 read-starved: %d/%d dates unreadable (throttled); re-queue"
                           grid_id cov_s2.read_failed cov_s2.found));
  if cov_s2.valid = 0 && cov_s2.read_failed = 0 && cov_s2.cloud = 0 then
    raise (All_scenes_dropped (Printf.sprintf "%s: all %d S2 dates genuinely absent" grid_id cov_s2.unavailable));
  if s1_min_load_frac > 0.0 && read_fail_frac cov_s1 > 1.0 -. s1_min_load_frac then
    raise (Read_starved (Printf.sprintf "%s: S1 read-starved: %d/%d dates unreadable (throttled); re-queue"
                           grid_id cov_s1.read_failed cov_s1.found))

(* ======================== NPY output ======================== *)

(** Little-endian encoders for one frame. *)
let bytes_of_u16 (a : u16) =
  let n = Array1.dim a in
  let b = Bytes.create (2 * n) in
  for i = 0 to n - 1 do Bytes.set_uint16_le b (2 * i) (Array1.unsafe_get a i) done; b

let bytes_of_i16 (a : i16) =
  let n = Array1.dim a in
  let b = Bytes.create (2 * n) in
  for i = 0 to n - 1 do Bytes.set_int16_le b (2 * i) (Array1.unsafe_get a i) done; b

let bytes_of_u8 (a : u8) =
  let n = Array1.dim a in
  let b = Bytes.create n in
  for i = 0 to n - 1 do Bytes.set_uint8 b i (Array1.unsafe_get a i) done; b

(** Write frames as one C-order array of shape (n_frames :: frame_shape). *)
let save_frames path dtype frame_shape encode frames =
  let oc = open_out_bin path in
  Npy.write_header oc dtype (Array.append [| List.length frames |] frame_shape);
  List.iter (fun f -> output_bytes oc (encode f)) frames;
  close_out oc

let save_doys path dtype (doys : int list) =
  let arr = Array.of_list doys in
  Npy.save path (Npy.of_int_array dtype [| Array.length arr |] arr)

(* ======================== Main ======================== *)

let () =
  let grid_id_arg = ref "" in
  let window_arg = ref "" in
  let shard_arg = ref "" in
  let shard_px = ref 4096 in
  let subwindow = ref 1024 in
  let windows_arg = ref "" in
  let zone_grid_arg = ref "" in
  let output_dir = ref "" in
  let start_date = ref "2024-01-01" in
  let end_date = ref "2024-12-31" in
  let max_cloud = ref 100.0 in
  (* Per-instance concurrency of COG reads: the same lever as dask
     num_workers / --download-workers / DOWNLOAD_WORKERS in the Python stack
     (build_tile.py uses 4; the fleet notes keep DL=4 per worker so many
     instances do not trip MPC throttling). Total CPU threads per instance is
     about download_workers x GDAL_NUM_THREADS (GDAL_NUM_THREADS unset = 1). *)
  let download_workers = ref (env_int "DOWNLOAD_WORKERS" 4) in
  let s2_min_load_frac = ref (env_float "S2_MIN_LOAD_FRAC" 0.9) in
  let s1_min_load_frac = ref (env_float "S1_MIN_LOAD_FRAC" 0.9) in
  let no_research = ref false in
  let flat_output = ref false in
  let layout = ref "nested" in

  let speclist = [
    ("--grid_id", Arg.Set_string grid_id_arg, "Grid id, e.g. grid_51.05_10.35 (tile geometry is derived from it)");
    ("--window", Arg.Set_string window_arg, "Grid-aligned window ZONE:ROW:COL:HxW in zone-grid pixels (needs --zone_grid)");
    ("--shard", Arg.Set_string shard_arg, "Zarr shard ZONE:SR:SC: run every --subwindow sub-window of it in turn (needs --zone_grid)");
    ("--shard_px", Arg.Set_int shard_px, "Shard side in pixels (default 4096)");
    ("--subwindow", Arg.Set_int subwindow, "Sub-window side for --shard; must divide --shard_px (default 1024)");
    ("--windows", Arg.Set_string windows_arg, "With --shard: only these sub-windows, comma-separated indices, row-major 0..n*n-1");
    ("--zone_grid", Arg.Set_string zone_grid_arg, "Seeded zone grid: the store's base URL (…/zarr/<dataset>) or a zone_grids.json dump from tessera-shard");
    ("--output", Arg.Set_string output_dir, "Output directory for dpixel .npy files");
    ("--start", Arg.Set_string start_date, "Start date (YYYY-MM-DD)");
    ("--end", Arg.Set_string end_date, "End date (YYYY-MM-DD)");
    ("--max_cloud", Arg.Set_float max_cloud, "Max cloud cover % (default: 100)");
    ("--download_workers", Arg.Set_int download_workers, "Concurrent COG reads (domains); default $DOWNLOAD_WORKERS or 4");
    ("--s2_min_load_frac", Arg.Set_float s2_min_load_frac, "Min fraction of S2 dates that must load, else exit 3; default $S2_MIN_LOAD_FRAC or 0.9 (0 disables)");
    ("--s1_min_load_frac", Arg.Set_float s1_min_load_frac, "Min fraction of S1 dates that must load, else exit 3; default $S1_MIN_LOAD_FRAC or 0.9 (0 disables)");
    ("--no_research", Arg.Set no_research, "Do not re-search STAC for fresh signed URLs on read failures");
    ("--flat_output", Arg.Set flat_output, "Write into --output directly instead of --output/<grid_id>");
    ("--layout", Arg.Set_string layout, "nested: s2/ and s1/ subdirectories as dpixel.py (default); flat: all .npy in one directory");
  ] in
  Arg.parse speclist (fun _ -> ()) "Tessera dpixel download tool";

  let nested = match String.lowercase_ascii !layout with
    | "nested" -> true | "flat" -> false
    | s -> failwith (Printf.sprintf "Unknown layout: %s (expected nested or flat)" s) in
  let n_given = List.length (List.filter (fun r -> !r <> "") [ grid_id_arg; window_arg; shard_arg ]) in
  if n_given <> 1 then failwith "exactly one of --grid_id, --window or --shard is required";
  if (!window_arg <> "" || !shard_arg <> "") && !zone_grid_arg = "" then
    failwith "--window and --shard need --zone_grid";
  if !shard_px mod !subwindow <> 0 then failwith "--subwindow must divide --shard_px";
  if !output_dir = "" then failwith "--output is required";

  let date_range = !start_date ^ "/" ^ !end_date in

  Gdal.init ();
  (* GDAL HTTP tuning for remote COG access (stackstac's defaults plus retries);
     anything already set in the environment takes precedence. *)
  set_config_default "GDAL_DISABLE_READDIR_ON_OPEN" "EMPTY_DIR";
  set_config_default "GDAL_HTTP_MULTIRANGE" "YES";
  set_config_default "GDAL_HTTP_MERGE_CONSECUTIVE_RANGES" "YES";
  set_config_default "GDAL_HTTP_MAX_RETRY" "3";
  set_config_default "GDAL_HTTP_RETRY_DELAY" "1";

  let n_workers = !download_workers in
  if n_workers > max_domains then
    eprintf "  Note: --download_workers %d capped to %d (OCaml domain limit)\n%!" n_workers max_domains;
  printf "  download_workers=%d GDAL_NUM_THREADS=%s\n%!" (min n_workers max_domains)
    (Option.value (Sys.getenv_opt "GDAL_NUM_THREADS") ~default:"unset (1)");
  let client = Stac_client.make () in

  (* The units of work: a 0.1 degree tile, one zone-grid window, or every
     sub-window of a Zarr shard (the PoC's decomposition: the shard is the
     write unit, the sub-window the memory unit). Each is named as the
     uploader expects: grid_<lon>_<lat> or utmZZ/r<row>c<col>. *)
  let window_id zone row col = Printf.sprintf "utm%02d/r%dc%d" zone row col in
  let jobs : (string * roi) list =
    if !grid_id_arg <> "" then begin
      match parse_grid_id !grid_id_arg with
      | Some (lon, lat) -> [ (!grid_id_arg, roi_of_grid lon lat) ]
      | None -> failwith (Printf.sprintf "%s is not of the form grid_<lon>_<lat>" !grid_id_arg)
    end else if !window_arg <> "" then begin
      match parse_window !window_arg with
      | Some (zone, row, col, h, w) ->
        [ (window_id zone row col, roi_of_window (Zone_grid.load !zone_grid_arg zone) ~row ~col ~h ~w) ]
      | None -> failwith (Printf.sprintf "%s is not of the form ZONE:ROW:COL:HxW" !window_arg)
    end else begin
      match String.split_on_char ':' !shard_arg with
      | [ z; r; c ] ->
        let zone = int_of_string z and sr = int_of_string r and sc = int_of_string c in
        let g = Zone_grid.load !zone_grid_arg zone in
        let n = !subwindow and sp = !shard_px in
        let per_side = sp / n in
        (* Sub-window index = row-major position in the shard, independent of
           clipping at the grid edge. *)
        let wanted = match !windows_arg with
          | "" -> None
          | l -> Some (List.map (fun x -> int_of_string (String.trim x)) (String.split_on_char ',' l)) in
        let subs = List.concat_map (fun dr ->
          List.filter_map (fun dc ->
            let idx = dr * per_side + dc in
            let row = sr * sp + dr * n and col = sc * sp + dc * n in
            let h = min n (g.height_px - row) and w = min n (g.width_px - col) in
            if h <= 0 || w <= 0 then None
            else if (match wanted with Some l -> not (List.mem idx l) | None -> false) then None
            else Some (window_id zone row col, roi_of_window g ~row ~col ~h ~w))
            (List.init per_side Fun.id)) (List.init per_side Fun.id) in
        if subs = [] then failwith (Printf.sprintf "shard %s: no sub-windows selected inside the zone %02d grid" !shard_arg zone);
        printf "shard %s: %d sub-windows of %dx%d%s\n%!" !shard_arg (List.length subs) n n
          (match wanted with Some _ -> " (selected by --windows)" | None -> "");
        subs
      | _ -> failwith (Printf.sprintf "%s is not of the form ZONE:SR:SC" !shard_arg)
    end in

  let run_job grid_id (roi : roi) =
  let out_dir = if !flat_output then !output_dir else Filename.concat !output_dir grid_id in
  let s2_dir = if nested then Filename.concat out_dir "s2" else out_dir in
  let s1_dir = if nested then Filename.concat out_dir "s1" else out_dir in
  if Sys.file_exists (Filename.concat s2_dir "bands.npy") then
    printf "Output already exists: %s\nSkipping.\n%!" out_dir
  else begin
  let t_start = Unix.gettimeofday () in
  printf "\nDpixel download started: %s\n%!" grid_id;
  let (minx, miny, maxx, maxy) = roi.grid_bounds in
  printf "  ROI %dx%d (warp grid %dx%d) %s bounds=(%.0f %.0f %.0f %.0f) res=%.1f\n%!"
    roi.height roi.width roi.h_out roi.w_out roi.dst_srs minx miny maxx maxy roi.resolution;
  let (xmin, ymin, xmax, ymax) = roi.bbox in

  let sign items = with_retries ~label:"SAS signing" (fun () ->
    List.map (Stac_client.sign_planetary_computer client) items) in

  (* Sentinel-2 *)
  let t_s2_start = Unix.gettimeofday () in
  printf "\nSearching Sentinel-2 (%s)...\n%!" date_range;
  let s2_params : Stac_client.search_params = {
    collections = ["sentinel-2-l2a"];
    bbox = [xmin; ymin; xmax; ymax];
    datetime = date_range;
    query = Some (`Assoc ["eo:cloud_cover", `Assoc ["lt", `Float !max_cloud]]);
    limit = None;
  } in
  let search_s2 () = sign (with_retries ~label:"S2 STAC search"
                             (fun () -> Stac_client.search client ~base_url:stac_url s2_params)) in
  let s2_items = search_s2 () in
  printf "  Found %d scenes\n%!" (List.length s2_items);
  printf "Processing Sentinel-2 (workers=%d)...\n%!" n_workers;
  let research_s2 = memoize_research (if !no_research then None else Some search_s2) in
  let (s2_bands, s2_masks, s2_doys, cov_s2) =
    process_s2 ~roi ~n_workers ~research:research_s2 (List.map s_item_of s2_items) in
  printf "  Result: %d valid days (%.1fs)\n%!" (List.length s2_bands) (Unix.gettimeofday () -. t_s2_start);

  (* Sentinel-1 *)
  let t_s1_start = Unix.gettimeofday () in
  printf "\nSearching Sentinel-1 (%s)...\n%!" date_range;
  let s1_params : Stac_client.search_params = {
    collections = ["sentinel-1-rtc"];
    bbox = [xmin; ymin; xmax; ymax];
    datetime = date_range;
    query = None;
    limit = None;
  } in
  let search_s1 () = sign (with_retries ~label:"S1 STAC search"
                             (fun () -> Stac_client.search client ~base_url:stac_url s1_params)) in
  let s1_items = search_s1 () in
  printf "  Found %d scenes\n%!" (List.length s1_items);
  printf "Processing Sentinel-1 (workers=%d)...\n%!" n_workers;
  let research_s1 = memoize_research (if !no_research then None else Some search_s1) in
  let (s1a, s1ad, s1de, s1dd, cov_s1) =
    process_s1 ~roi ~n_workers ~research:research_s1 (List.map s_item_of s1_items) in
  printf "  Ascending: %d passes, Descending: %d passes (%.1fs)\n%!"
    (List.length s1a) (List.length s1de) (Unix.gettimeofday () -. t_s1_start);

  (* One coverage policy decides accept / re-queue / mark-bad *)
  apply_coverage_policy ~grid_id ~s2_min_load_frac:!s2_min_load_frac
    ~s1_min_load_frac:!s1_min_load_frac cov_s2 cov_s1;

  (* Save dpixel .npy files *)
  mkdir_p s2_dir; mkdir_p s1_dir;
  printf "\nSaving dpixel data to %s\n%!" out_dir;
  let h = roi.height and w = roi.width in
  save_frames (Filename.concat s2_dir "bands.npy") Npy.Uint16 [| h; w; 10 |] bytes_of_u16 s2_bands;
  save_frames (Filename.concat s2_dir "masks.npy") Npy.Uint8 [| h; w |] bytes_of_u8 s2_masks;
  save_doys (Filename.concat s2_dir "doys.npy") Npy.Uint16 s2_doys;
  save_frames (Filename.concat s1_dir "sar_ascending.npy") Npy.Int16 [| h; w; 2 |] bytes_of_i16 s1a;
  save_doys (Filename.concat s1_dir "sar_ascending_doy.npy") Npy.Int16 s1ad;
  save_frames (Filename.concat s1_dir "sar_descending.npy") Npy.Int16 [| h; w; 2 |] bytes_of_i16 s1de;
  save_doys (Filename.concat s1_dir "sar_descending_doy.npy") Npy.Int16 s1dd;
  printf "  Saved 7 .npy files\n%!";

  printf "\nDone: %s (%.1fs)\n%!" grid_id (Unix.gettimeofday () -. t_start)
  end in
  (* Exit codes follow dpixel.py's policy: 2 = permanent (mark the cell bad),
     3 = transient (re-queue). Over a shard's sub-windows a permanent failure
     is normal (open sea has no Sentinel-2 items): that sub-window is skipped,
     the uploader leaves it +inf, and only a transient failure fails the run. *)
  let multi = List.length jobs > 1 in
  let worst = List.fold_left (fun worst (grid_id, roi) ->
    try run_job grid_id roi; worst with
    | All_scenes_dropped msg ->
      eprintf "PERMANENT FAILURE: %s\n%!" msg;
      if multi then begin printf "  skipping %s\n%!" grid_id; worst end else 2
    | Read_starved msg ->
      eprintf "TRANSIENT FAILURE: %s\n%!" msg; max worst 3) 0 jobs in
  exit worst
