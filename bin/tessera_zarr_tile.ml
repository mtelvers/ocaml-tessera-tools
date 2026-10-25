(* tessera-zarr-tile: cut 0.1 degree tiles out of the Zarr store, in the
   archive's .npy layout. The inverse of tessera-zarr-upload.

   A tile named grid_<lon>_<lat> is the axis-aligned UTM rectangle around the
   projected 0.1 degree cell (Tile_geom.of_centre), which is exactly the
   rectangle the encoders write and geotessera's converter pastes into the
   zone grid at an integer pixel offset. So a tile is a pure integer window
   of its centre zone's store: no resampling, no curved cell boundary. Each
   window may straddle up to four shards; with the sharding codec's partial
   reads only the index and the inner chunks the window touches are fetched.

   Output, per tile, as the archive lays it out:
     <output>/<year>/grid_<lon>_<lat>/grid_<lon>_<lat>.npy         int8 (H, W, 128)
     <output>/<year>/grid_<lon>_<lat>/grid_<lon>_<lat>_scales.npy  float32 (H, W)
     <output>/<year>/grid_<lon>_<lat>/SHA256                       sha256sum format

   No-data: the store says NaN scale for "produced, no data" and +inf for
   "never produced". The archive has one signature, the encoder's: an
   all-zero code vector with scale 1e-12/127. NaN pixels are written as
   that. +inf pixels mean the store does not hold the whole tile; the tile
   is refused unless --allow_partial, which writes the signature there too.

   The time index comes from the store's own time array (int32 years). *)

open Bigarray
module Tile_geom = Tessera_common.Tile_geom

let shard_px = 4096
let n_bands = 128
let nodata_scale = 1e-12 /. 127.0

let printf fmt = Printf.printf fmt
let eprintf fmt = Printf.eprintf fmt

(* ======================== Zone grid from the store ======================== *)

type zone_grid = {
  zone : int;
  origin_x : float;
  origin_y : float;        (* canonical northing of the top-left corner *)
  pixel : float;
  height_px : int;
  width_px : int;
  years : int array;       (* the time axis *)
}

let group_path zone = Printf.sprintf "utm%02d" zone
let array_path zone a = Printf.sprintf "utm%02d/%s" zone a

let member k = function `Assoc l -> List.assoc_opt k l | _ -> None
let num = function `Float f -> f | `Int i -> Float.of_int i | _ -> failwith "expected a number"

let open_array ?config store zone name =
  match Zarr_s3.Array.open_ ?config store ~path:(array_path zone name) with
  | Ok a -> a
  | Error _ -> failwith (Printf.sprintf "store has no array %s" (array_path zone name))

let zone_grid_of_store store zone =
  let g = match Zarr_s3.Group.open_ store ~path:(group_path zone) with
    | Ok g -> g
    | Error _ -> failwith (Printf.sprintf "store has no group %s" (group_path zone)) in
  let attrs = Zarr_s3.Group.attrs g in
  let transform = match member "spatial:transform" attrs with
    | Some (`List l) -> Array.of_list (List.map num l)
    | _ -> failwith "group lacks spatial:transform" in
  let emb = open_array store zone "embeddings" in
  let shape = (Zarr_s3.Array.metadata emb).shape in
  if Array.length shape <> 4 || shape.(1) <> n_bands then
    failwith "embeddings array is not (T, 128, H, W)";
  let years =
    match Zarr_s3.Array.get_slice (open_array store zone "time") [ Zarr.All ] with
    | Zarr.Ndarray.Int32 a ->
      let a = reshape_1 a shape.(0) in
      Array.init shape.(0) (fun i -> Int32.to_int a.{i})
    | Zarr.Ndarray.Int64 a ->
      let a = reshape_1 a shape.(0) in
      Array.init shape.(0) (fun i -> Int64.to_int a.{i})
    | _ -> failwith "time array is not an integer array" in
  { zone; origin_x = transform.(2); origin_y = transform.(5); pixel = transform.(0);
    height_px = shape.(2); width_px = shape.(3); years }

(* ======================== Tiles ======================== *)

type tile = {
  name : string;
  geom : Tile_geom.t;
  row : int; col : int;     (* zone-grid pixel of the tile's top-left *)
  h : int; w : int;
}

(** Placement, as the uploader and geotessera do it: the snapped origin is
    an exact multiple of the pixel, so rounding is just float cleanup. *)
let place (g : zone_grid) name =
  let geom = match Tile_geom.of_grid_id name with
    | Some t -> t
    | None -> failwith (name ^ ": not a grid_<lon>_<lat> tile id") in
  if geom.zone <> g.zone then
    failwith (Printf.sprintf "%s is in zone %d, store group is zone %d" name geom.zone g.zone);
  let canon_top = Tile_geom.canonical_northing ~epsg:geom.epsg geom.maxy in
  let col = Float.to_int (Float.round ((geom.minx -. g.origin_x) /. g.pixel)) in
  let row = Float.to_int (Float.round ((g.origin_y -. canon_top) /. g.pixel)) in
  { name; geom; row; col; h = geom.height; w = geom.width }

(** Every tile whose centre projects into shard (sr, sc): the shard's lon/lat
    bbox is sampled, the 0.1 degree centres inside it enumerated and each one
    projected back. *)
let tiles_in_shard (g : zone_grid) sr sc =
  let left = g.origin_x +. Float.of_int (sc * shard_px) *. g.pixel in
  let right = left +. Float.of_int (min shard_px (g.width_px - sc * shard_px)) *. g.pixel in
  let top = g.origin_y -. Float.of_int (sr * shard_px) *. g.pixel in
  let bottom = top -. Float.of_int (min shard_px (g.height_px - sr * shard_px)) *. g.pixel in
  let to_lonlat ~epsg pts =
    let src = Gdal.SpatialReference.of_epsg epsg |> Result.get_ok in
    let dst = Gdal.SpatialReference.of_epsg 4326 |> Result.get_ok in
    Gdal.SpatialReference.set_axis_mapping_strategy src Gdal.oams_traditional_gis_order;
    Gdal.SpatialReference.set_axis_mapping_strategy dst Gdal.oams_traditional_gis_order;
    let ct = Gdal.CoordinateTransformation.create src dst |> Result.get_ok in
    let r = Gdal.CoordinateTransformation.transform_points ct pts |> Result.get_ok in
    Gdal.CoordinateTransformation.destroy ct;
    Gdal.SpatialReference.destroy src; Gdal.SpatialReference.destroy dst;
    r in
  (* Canonical northing is the real northing north of the equator; south of
     it the 327xx code and +10,000 km apply. Sample the boundary in whichever
     hemisphere each point lies. *)
  let real ~y = if y < 0.0 then (32700 + g.zone, y +. 10_000_000.0) else (32600 + g.zone, y) in
  let n = 16 in
  let boundary = List.concat_map (fun i ->
    let f = Float.of_int i /. Float.of_int n in
    [ (left +. (right -. left) *. f, top); (left +. (right -. left) *. f, bottom);
      (left, bottom +. (top -. bottom) *. f); (right, bottom +. (top -. bottom) *. f) ])
    (List.init (n + 1) Fun.id) in
  let north = List.filter (fun (_, y) -> y >= 0.0) boundary
  and south = List.filter (fun (_, y) -> y < 0.0) boundary in
  let ll = List.concat_map (fun pts -> match pts with
    | [] -> []
    | (_, y) :: _ ->
      let epsg, _ = real ~y in
      Array.to_list (to_lonlat ~epsg (Array.of_list (List.map (fun (x, y) -> (x, snd (real ~y))) pts))))
    [ north; south ] in
  let lons = List.map fst ll and lats = List.map snd ll in
  let fmin l = List.fold_left Float.min (List.hd l) l and fmax l = List.fold_left Float.max (List.hd l) l in
  let centre v = Float.of_int (Float.to_int (Float.floor (v *. 10.0))) /. 10.0 +. 0.05 in
  let lon0 = centre (fmin lons -. 0.1) and lon1 = centre (fmax lons +. 0.1) in
  let lat0 = centre (fmin lats -. 0.1) and lat1 = centre (fmax lats +. 0.1) in
  let tiles = ref [] in
  let lat = ref lat0 in
  while !lat <= lat1 +. 1e-9 do
    let lon = ref lon0 in
    while !lon <= lon1 +. 1e-9 do
      let lon' = Float.round (!lon *. 100.0) /. 100.0 and lat' = Float.round (!lat *. 100.0) /. 100.0 in
      if Tile_geom.zone_of_lon lon' = g.zone && Float.abs lat' < 84.0 then begin
        let t = Tile_geom.of_centre lon' lat' in
        let (l, b, r, tp) = t.bounds_unsnapped in
        let cx = (l +. r) /. 2.0 and cy = Tile_geom.canonical_northing ~epsg:t.epsg ((b +. tp) /. 2.0) in
        if cx >= left && cx < right && cy <= top && cy > bottom then
          tiles := Tile_geom.grid_id lon' lat' :: !tiles
      end;
      lon := !lon +. 0.1
    done;
    lat := !lat +. 0.1
  done;
  List.rev !tiles

(* ======================== Reading ======================== *)

type cut = {
  emb : bytes;              (* (h, w, 128) int8 *)
  scales : bytes;           (* (h, w) float32 LE *)
  valid : int; nodata : int; missing : int;
}

let read_tile ~store ~config ~(g : zone_grid) ~t ~allow_partial (tile : tile) =
  (* The part of the tile inside the grid; anything outside counts as never produced. *)
  let r0 = max 0 tile.row and r1 = min g.height_px (tile.row + tile.h) in
  let c0 = max 0 tile.col and c1 = min g.width_px (tile.col + tile.w) in
  if r0 >= r1 || c0 >= c1 then failwith (tile.name ^ ": lies entirely outside the zone grid");
  let rh = r1 - r0 and rw = c1 - c0 in
  let emb_arr = open_array ~config store g.zone "embeddings" in
  let sc_arr = open_array ~config store g.zone "scales" in
  let emb = match Zarr_s3.Array.get_slice emb_arr
      [ Zarr.Index t; Zarr.All; Zarr.Range (r0, r1); Zarr.Range (c0, c1) ] with
    | Zarr.Ndarray.Int8_signed a -> reshape_1 a (n_bands * rh * rw)
    | _ -> failwith "embeddings is not int8" in
  let sc = match Zarr_s3.Array.get_slice sc_arr
      [ Zarr.Index t; Zarr.Range (r0, r1); Zarr.Range (c0, c1) ] with
    | Zarr.Ndarray.Float32 a -> reshape_1 a (rh * rw)
    | _ -> failwith "scales is not float32" in
  let out_emb = Bytes.make (tile.h * tile.w * n_bands) '\000' in
  let out_sc = Bytes.create (tile.h * tile.w * 4) in
  let valid = ref 0 and nodata = ref 0 and missing = ref 0 in
  let plane = rh * rw in
  let signature p = Bytes.set_int32_le out_sc (4 * p) (Int32.bits_of_float nodata_scale) in
  for i = 0 to tile.h - 1 do
    for j = 0 to tile.w - 1 do
      let p = i * tile.w + j in
      let r = tile.row + i and c = tile.col + j in
      if r < r0 || r >= r1 || c < c0 || c >= c1 then begin incr missing; signature p end
      else begin
        let q = (r - r0) * rw + (c - c0) in
        let s = Array1.unsafe_get sc q in
        if Float.is_nan s then begin incr nodata; signature p end
        else if s = Float.infinity then begin incr missing; signature p end
        else begin
          incr valid;
          Bytes.set_int32_le out_sc (4 * p) (Int32.bits_of_float s);
          let dst = p * n_bands in
          for b = 0 to n_bands - 1 do
            Bytes.set_int8 out_emb (dst + b) (Array1.unsafe_get emb (b * plane + q))
          done
        end
      end
    done
  done;
  if !missing > 0 && not allow_partial then
    failwith (Printf.sprintf "%s: %d of %d pixels were never produced (use --allow_partial to write it anyway)"
                tile.name !missing (tile.h * tile.w));
  { emb = out_emb; scales = out_sc; valid = !valid; nodata = !nodata; missing = !missing }

(* ======================== Writing ======================== *)

let sha256_file path =
  let ic = open_in_bin path in
  let ctx = ref Digestif.SHA256.empty in
  let buf = Bytes.create 65536 in
  let rec go () =
    let n = input ic buf 0 (Bytes.length buf) in
    if n > 0 then begin ctx := Digestif.SHA256.feed_bytes !ctx ~off:0 ~len:n buf; go () end in
  go ();
  close_in ic;
  Digestif.SHA256.to_hex (Digestif.SHA256.get !ctx)

let rec mkdir_p d =
  if d <> "" && d <> "." && d <> "/" && not (Sys.file_exists d) then begin
    mkdir_p (Filename.dirname d);
    (try Unix.mkdir d 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ())
  end

let write_tile ~output ~year ~sha (tile : tile) (c : cut) =
  let dir = Filename.concat (Filename.concat output (string_of_int year)) tile.name in
  mkdir_p dir;
  let emb_path = Filename.concat dir (tile.name ^ ".npy") in
  let sc_path = Filename.concat dir (tile.name ^ "_scales.npy") in
  Npy.save emb_path { Npy.dtype = Npy.Int8; order = Npy.C; shape = [| tile.h; tile.w; n_bands |]; data = c.emb };
  Npy.save sc_path { Npy.dtype = Npy.Float32; order = Npy.C; shape = [| tile.h; tile.w |]; data = c.scales };
  if sha then begin
    let oc = open_out_bin (Filename.concat dir "SHA256") in
    List.iter (fun p -> Printf.fprintf oc "%s  %s\n" (sha256_file p) (Filename.basename p)) [ emb_path; sc_path ];
    close_out oc
  end;
  dir

(* ======================== Main ======================== *)

let () =
  let endpoint = ref (Option.value (Sys.getenv_opt "S3_ENDPOINT") ~default:"") in
  let bucket = ref (Option.value (Sys.getenv_opt "S3_BUCKET") ~default:"") in
  let prefix = ref (Option.value (Sys.getenv_opt "S3_PREFIX") ~default:"") in
  let region = ref (Option.value (Sys.getenv_opt "AWS_DEFAULT_REGION") ~default:"us-east-1") in
  let anonymous = ref false in
  let year = ref 0 in
  let time_index = ref (-1) in
  let shard = ref "" in
  let output = ref "." in
  let allow_partial = ref false in
  let no_sha = ref false in
  let domains = ref 8 in
  let list_only = ref false in
  let ids = ref [] in
  let speclist = [
    ("--endpoint", Arg.Set_string endpoint, "S3 endpoint URL (default $S3_ENDPOINT)");
    ("--bucket", Arg.Set_string bucket, "Bucket (default $S3_BUCKET)");
    ("--prefix", Arg.Set_string prefix, "Key prefix of the Zarr store root (default $S3_PREFIX)");
    ("--region", Arg.Set_string region, "Signing region (default $AWS_DEFAULT_REGION or us-east-1)");
    ("--anonymous", Arg.Set anonymous, "Unsigned requests (public bucket); also used when no credentials are found");
    ("--year", Arg.Set_int year, "Year to cut, looked up in the store's time array");
    ("--time_index", Arg.Set_int time_index, "Time index to cut (overrides --year)");
    ("--shard", Arg.Set_string shard, "ZONE:SR:SC: every tile whose centre falls in this shard");
    ("--output", Arg.Set_string output, "Output root; tiles go to <output>/<year>/<grid>/ (default .)");
    ("--allow_partial", Arg.Set allow_partial, "Write a tile the store has not fully produced, with no-data where it is missing");
    ("--no_sha256", Arg.Set no_sha, "Do not write the SHA256 sidecar");
    ("--domains", Arg.Set_int domains, "Domains used to decompress inner chunks (default 8)");
    ("--list", Arg.Set list_only, "Only list the tiles that would be cut");
  ] in
  Arg.parse speclist (fun p -> ids := p :: !ids)
    "tessera-zarr-tile [options] [grid_<lon>_<lat> ...]\nCut 0.1 degree .npy tiles out of an S3 Zarr store.";
  if !endpoint = "" || !bucket = "" then failwith "--endpoint and --bucket are required";
  let ids = List.rev !ids in
  let shard = if !shard = "" then None else
      match List.map int_of_string (String.split_on_char ':' !shard) with
      | [ z; sr; sc ] -> Some (z, sr, sc)
      | _ -> failwith "--shard expects ZONE:SR:SC" in
  if ids = [] && shard = None then failwith "give tile ids or --shard";
  Gdal.init ();
  Zarr_blosc.Blosc.register ();
  let zones = List.sort_uniq compare
      ((match shard with Some (z, _, _) -> [ z ] | None -> [])
       @ List.map (fun id -> match Tile_geom.parse_grid_id id with
           | Some (lon, _) -> Tile_geom.zone_of_lon lon
           | None -> failwith (id ^ ": not a grid_<lon>_<lat> tile id")) ids) in
  let zone = match zones with
    | [ z ] -> z
    | zs -> failwith (Printf.sprintf "tiles span zones %s; run once per zone"
                        (String.concat "," (List.map string_of_int zs))) in

  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let credentials =
    if !anonymous then None
    else match S3.Credentials.default_chain () with
      | Ok c -> Some c
      | Error _ -> eprintf "no S3 credentials found; reading anonymously\n%!"; None in
  let cfg = S3.Client.make_config ~endpoint:!endpoint ~region:!region ?credentials ~path_style:true
      ~max_connections:16 () in
  let client = S3.Client.create ~sw ~net:(Eio.Stdenv.net env) ~clock:(Eio.Stdenv.clock env) cfg in
  let store = Zarr_s3.Store.create ~read_concurrency:16 client ~bucket:!bucket ~prefix:!prefix in
  let g = zone_grid_of_store store zone in
  let t = if !time_index >= 0 then !time_index
    else if !year > 0 then
      (match List.find_opt (fun i -> g.years.(i) = !year) (List.init (Array.length g.years) Fun.id) with
       | Some i -> i
       | None -> failwith (Printf.sprintf "year %d is not on the store's time axis (%d..%d)"
                             !year g.years.(0) g.years.(Array.length g.years - 1)))
    else failwith "--year or --time_index is required" in
  if t >= Array.length g.years then failwith (Printf.sprintf "time index %d outside T=%d" t (Array.length g.years));
  let year = g.years.(t) in
  printf "store s3://%s/%s  zone %02d  origin (%.0f, %.0f)  %d x %d px  year %d (t=%d)\n%!"
    !bucket !prefix g.zone g.origin_x g.origin_y g.width_px g.height_px year t;
  let ids = match shard with
    | Some (_, sr, sc) ->
      let in_shard = tiles_in_shard g sr sc in
      printf "shard %02d:%d:%d holds the centres of %d tile(s)\n%!" zone sr sc (List.length in_shard);
      ids @ in_shard
    | None -> ids in
  let tiles = List.map (place g) ids in
  if !list_only then
    List.iter (fun (tile : tile) ->
      printf "%s  %dx%d at row %d col %d  shards %d-%d/%d-%d\n" tile.name tile.h tile.w tile.row tile.col
        (tile.row / shard_px) ((tile.row + tile.h - 1) / shard_px)
        (tile.col / shard_px) ((tile.col + tile.w - 1) / shard_px)) tiles
  else begin
    let config = { Zarr.Codec.default_config with domains = !domains } in
    let failures = ref 0 in
    List.iter (fun (tile : tile) ->
      let t0 = Unix.gettimeofday () in
      match read_tile ~store ~config ~g ~t ~allow_partial:!allow_partial tile with
      | c ->
        let dir = write_tile ~output:!output ~year ~sha:(not !no_sha) tile c in
        printf "%-22s %dx%d at row %d col %d  valid %8d  nodata %6d  missing %6d  %5.1fs  -> %s\n%!"
          tile.name tile.h tile.w tile.row tile.col c.valid c.nodata c.missing
          (Unix.gettimeofday () -. t0) dir
      | exception Failure msg -> incr failures; eprintf "%s\n%!" msg) tiles;
    if !failures > 0 then exit 1
  end
