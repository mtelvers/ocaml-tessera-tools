(* tessera-zarr-upload: place encoder output (.npy tiles or windows) into the
   shards of a Zarr v3 store on S3.

   Input is what the Tessera encoders write for one 0.1 degree tile:
     <grid>.npy          int8    (H, W, 128)   quantised embedding codes
     <grid>_scales.npy   float32 (H, W)        per-pixel dequantisation scale
   or the same pair for a grid-aligned window produced from tessera-dpixel's
   --window mode, named r<ROW>c<COL> (zone-grid pixel of the top-left corner).

   The store is the one geotessera builds and the Zarr PoC writes to: per UTM
   zone a group utmZZ with arrays
     embeddings       int8    (T, 128, H, W)  shards (1,128,4096,4096)
     embeddings_d16   int8    (T,  16, H, W)  the first 16 bands
     embeddings_d4    int8    (T,   4, H, W)  the first 4 bands
     scales           float32 (T, H, W)       fill +inf = never produced
   Everything about the grid comes from the store itself: the group's
   spatial:transform gives the zone origin, the arrays give extent, codecs
   and fill values, so the tool cannot write against a different store's
   geometry than the one it is addressing.

   Placement follows geotessera's converter: a tile's pixel (0,0) is the
   stackstac-snapped origin floor(minx/10)*10, ceil(maxy/10)*10, which is where
   dpixel laid its pixels out (Tile_geom). Tiles overlap their neighbours by a
   few percent and may straddle up to four shards; a shard is assembled in
   memory from every input that touches it and written as one object per
   array, in the PoC's order: d4, d16, scales, then embeddings last, whose
   presence marks the shard complete.

   No-data: the encoders never emit NaN or inf. A pixel with no observations
   comes out as an all-zero code vector with the quantiser's floor scale
   1e-12/127, which passes the (0, 1) validity test used by geotessera and
   the PoC. Those pixels are written as NaN scales ("covered, no data");
   pixels no input covers keep the +inf fill. Valid pixels of a later input
   overwrite earlier ones; no-data never overwrites valid data.

   Shards are only as complete as the inputs given: by default every shard
   the inputs touch is written, so pass all the tiles that cover a shard (or
   restrict with --sr/--sc) or a complete shard will be replaced by a partial
   one. *)

open Bigarray
module Tile_geom = Tessera_common.Tile_geom

let shard_px = 4096
let n_bands = 128

(* Student quantiser: scale = max(|emb|, 1e-12) / 127, so an empty pixel has
   exactly this scale (and an all-zero vector). *)
let nodata_scale_ceiling = 1e-12 /. 127.0 *. (1.0 +. 1e-6)
let max_valid_scale = 1.0   (* geotessera MAX_VALID_SCALE *)

let printf fmt = Printf.printf fmt
let eprintf fmt = Printf.eprintf fmt

(* ======================== Inputs ======================== *)

type input = {
  name : string;              (* grid_<lon>_<lat> or r<row>c<col> *)
  emb_path : string;
  scales_path : string;
}

let strip_suffix s suf =
  let n = String.length s and m = String.length suf in
  if n >= m && String.sub s (n - m) m = suf then Some (String.sub s 0 (n - m)) else None

(** A path is a <name>.npy file, a <name>_scales.npy file (its partner is
    used) or a directory holding <basename>.npy, as the archive lays tiles
    out (<year>/<grid>/<grid>.npy). *)
let input_of_path path =
  let pair dir base =
    let emb = Filename.concat dir (base ^ ".npy") in
    let sc = Filename.concat dir (base ^ "_scales.npy") in
    if not (Sys.file_exists emb) then failwith ("missing " ^ emb);
    if not (Sys.file_exists sc) then failwith ("missing " ^ sc);
    { name = base; emb_path = emb; scales_path = sc } in
  if Sys.is_directory path then pair path (Filename.basename path)
  else
    let dir = Filename.dirname path and file = Filename.basename path in
    match strip_suffix file "_scales.npy" with
    | Some base -> pair dir base
    | None ->
      match strip_suffix file ".npy" with
      | Some base -> pair dir base
      | None -> failwith (path ^ ": not a .npy file or a tile directory")

(* ======================== Zone grid from the store ======================== *)

type zone_grid = {
  zone : int;
  epsg : int;              (* canonical northern code stamped on the group *)
  origin_x : float;
  origin_y : float;        (* canonical northing of the top-left corner *)
  pixel : float;
  height_px : int;
  width_px : int;
  n_time : int;
}

let group_path zone = Printf.sprintf "utm%02d" zone
let array_path zone a = Printf.sprintf "utm%02d/%s" zone a

let member k = function `Assoc l -> List.assoc_opt k l | _ -> None
let num = function `Float f -> f | `Int i -> Float.of_int i | _ -> failwith "expected a number"

let zone_grid_of_store store zone =
  let g = match Zarr_s3.Group.open_ store ~path:(group_path zone) with
    | Ok g -> g
    | Error _ -> failwith (Printf.sprintf "store has no group %s" (group_path zone)) in
  let attrs = Zarr_s3.Group.attrs g in
  let transform = match member "spatial:transform" attrs with
    | Some (`List l) -> Array.of_list (List.map num l)
    | _ -> failwith "group lacks spatial:transform" in
  let epsg = match member "proj:code" attrs with
    | Some (`String s) -> (match String.split_on_char ':' s with
        | [ _; code ] -> int_of_string code | _ -> failwith "bad proj:code")
    | _ -> 32600 + zone in
  let emb = match Zarr_s3.Array.open_ store ~path:(array_path zone "embeddings") with
    | Ok a -> a | Error _ -> failwith "store has no embeddings array" in
  let shape = (Zarr_s3.Array.metadata emb).shape in
  if Array.length shape <> 4 || shape.(1) <> n_bands then
    failwith "embeddings array is not (T, 128, H, W)";
  { zone; epsg; origin_x = transform.(2); origin_y = transform.(5); pixel = transform.(0);
    height_px = shape.(2); width_px = shape.(3); n_time = shape.(0) }

(* ======================== Placement ======================== *)

type placement = {
  inp : input;
  row : int; col : int;     (* zone-grid pixel of the input's top-left *)
  h : int; w : int;         (* input array size *)
}

let window_re_parse name =
  (* r<row>c<col> *)
  match String.index_opt name 'c' with
  | Some i when String.length name > 2 && name.[0] = 'r' ->
    (try Some (int_of_string (String.sub name 1 (i - 1)),
               int_of_string (String.sub name (i + 1) (String.length name - i - 1)))
     with _ -> None)
  | _ -> None

(** Zone an input belongs to: a tile's own zone, a window's --zone. *)
let input_zone ~zone_arg inp =
  match Tile_geom.parse_grid_id inp.name with
  | Some (lon, _) -> Tile_geom.zone_of_lon lon
  | None ->
    match window_re_parse inp.name, zone_arg with
    | Some _, Some z -> z
    | Some _, None -> failwith (inp.name ^ ": window inputs need --zone")
    | None, _ -> failwith (inp.name ^ ": neither grid_<lon>_<lat> nor r<row>c<col>")

let npy_shape path =
  match Npy.read_shape path with
  | Ok (_, _, shape) -> shape
  | Error e -> failwith (path ^ ": " ^ e)

let place (g : zone_grid) inp =
  let shape = npy_shape inp.emb_path in
  if Array.length shape <> 3 || shape.(2) <> n_bands then
    failwith (Printf.sprintf "%s: expected (H, W, 128) int8, got rank %d" inp.emb_path (Array.length shape));
  let h = shape.(0) and w = shape.(1) in
  match Tile_geom.parse_grid_id inp.name with
  | Some (lon, lat) ->
    let t = Tile_geom.of_centre lon lat in
    if t.zone <> g.zone then
      failwith (Printf.sprintf "%s is in zone %d, store group is zone %d" inp.name t.zone g.zone);
    let canon_top = Tile_geom.canonical_northing ~epsg:t.epsg t.maxy in
    (* geotessera _tile_pixel_offset: floor of the unsnapped origin == the
       snapped origin, which Tile_geom already holds. *)
    let col = Float.to_int (Float.round ((t.minx -. g.origin_x) /. g.pixel)) in
    let row = Float.to_int (Float.round ((g.origin_y -. canon_top) /. g.pixel)) in
    if h <> t.height || w <> t.width then
      eprintf "  warning: %s is %dx%d but its grid id implies %dx%d\n%!" inp.name h w t.height t.width;
    { inp; row; col; h; w }
  | None ->
    match window_re_parse inp.name with
    | Some (row, col) -> { inp; row; col; h; w }
    | None -> assert false

(* ======================== Shard assembly ======================== *)

type shard_buf = {
  sr : int; sc : int;
  r0 : int; c0 : int;       (* zone-grid pixel of the shard's top-left *)
  sh : int; sw : int;       (* shard size clipped to the grid *)
  emb : (int, int8_signed_elt, c_layout) Genarray.t;      (* (1, 128, sh, sw) *)
  scales : (float, float32_elt, c_layout) Genarray.t;     (* (1, sh, sw) *)
}

let new_shard (g : zone_grid) sr sc =
  let r0 = sr * shard_px and c0 = sc * shard_px in
  let sh = min shard_px (g.height_px - r0) and sw = min shard_px (g.width_px - c0) in
  let emb = Genarray.create int8_signed c_layout [| 1; n_bands; sh; sw |] in
  Genarray.fill emb 0;
  let scales = Genarray.create float32 c_layout [| 1; sh; sw |] in
  Genarray.fill scales Float.infinity;
  { sr; sc; r0; c0; sh; sw; emb; scales }

let shards_touched (g : zone_grid) (p : placement) =
  let clip lo hi n = (max 0 lo, min n hi) in
  let (r_lo, r_hi) = clip p.row (p.row + p.h) g.height_px in
  let (c_lo, c_hi) = clip p.col (p.col + p.w) g.width_px in
  if r_lo >= r_hi || c_lo >= c_hi then []
  else
    List.concat_map (fun sr ->
      List.init ((c_hi - 1) / shard_px - c_lo / shard_px + 1) (fun k -> (sr, c_lo / shard_px + k)))
      (List.init ((r_hi - 1) / shard_px - r_lo / shard_px + 1) (fun k -> r_lo / shard_px + k))

let load_npy path expect_dtype expect_shape =
  match Npy.load path with
  | Error e -> failwith (path ^ ": " ^ e)
  | Ok t ->
    if t.Npy.dtype <> expect_dtype then
      failwith (Printf.sprintf "%s: dtype %s, expected %s" path
                  (Npy.dtype_to_descr t.dtype) (Npy.dtype_to_descr expect_dtype));
    if t.order <> Npy.C then failwith (path ^ ": Fortran order not supported");
    if t.shape <> expect_shape then failwith (path ^ ": shape differs from the embeddings file");
    t.data

(** Copy the part of [p] that falls in [s]. Returns (valid, nodata) pixel counts. *)
let paste (s : shard_buf) (p : placement) =
  let emb = load_npy p.inp.emb_path Npy.Int8 [| p.h; p.w; n_bands |] in
  let sc = load_npy p.inp.scales_path Npy.Float32 [| p.h; p.w |] in
  let r_lo = max p.row s.r0 and r_hi = min (p.row + p.h) (s.r0 + s.sh) in
  let c_lo = max p.col s.c0 and c_hi = min (p.col + p.w) (s.c0 + s.sw) in
  let emb1 = reshape_1 s.emb (n_bands * s.sh * s.sw) in
  let sc1 = reshape_1 s.scales (s.sh * s.sw) in
  let plane = s.sh * s.sw in
  let valid = ref 0 and nodata = ref 0 in
  for r = r_lo to r_hi - 1 do
    let ti = r - p.row and si = r - s.r0 in
    for c = c_lo to c_hi - 1 do
      let tj = c - p.col and sj = c - s.c0 in
      let tp = ti * p.w + tj in
      let sp = si * s.sw + sj in
      let scale = Int32.float_of_bits (Bytes.get_int32_le sc (4 * tp)) in
      if Float.is_finite scale && scale > nodata_scale_ceiling && scale < max_valid_scale then begin
        incr valid;
        Array1.unsafe_set sc1 sp scale;
        let src = tp * n_bands in
        for b = 0 to n_bands - 1 do
          Array1.unsafe_set emb1 (b * plane + sp) (Bytes.get_int8 emb (src + b))
        done
      end else begin
        incr nodata;
        (* covered but empty: +inf (never produced) becomes NaN; valid data
           from an earlier input is left alone *)
        if Array1.unsafe_get sc1 sp = Float.infinity then Array1.unsafe_set sc1 sp Float.nan
      end
    done
  done;
  (!valid, !nodata)

(* ======================== Writing ======================== *)

(** The first [d] bands of the shard buffer as a (1, d, sh, sw) view. *)
let depth_view (s : shard_buf) d =
  let bands = Genarray.slice_left s.emb [| 0 |] in           (* (128, sh, sw) *)
  reshape (Genarray.sub_left bands 0 d) [| 1; d; s.sh; s.sw |]

let chunk_key zone array ~t ~sr ~sc =
  let band = if String.length array >= 10 && String.sub array 0 10 = "embeddings" then "/0" else "" in
  Printf.sprintf "%s/%s/c/%d%s/%d/%d" (group_path zone) array t band sr sc

let write_shard ~store ~(g : zone_grid) ~t ~domains ~dry_run (s : shard_buf) =
  let region_emb d = [ Zarr.Range (t, t + 1); Zarr.Range (0, d);
                       Zarr.Range (s.r0, s.r0 + s.sh); Zarr.Range (s.c0, s.c0 + s.sw) ] in
  let region_sc = [ Zarr.Range (t, t + 1); Zarr.Range (s.r0, s.r0 + s.sh); Zarr.Range (s.c0, s.c0 + s.sw) ] in
  let write name ~config data region =
    if dry_run then printf "    %-16s (dry run)\n%!" name
    else begin
      let t0 = Unix.gettimeofday () in
      let arr = match Zarr_s3.Array.open_ ~config store ~path:(array_path g.zone name) with
        | Ok a -> a | Error _ -> failwith ("store has no array " ^ name) in
      Zarr_s3.Array.set_slice arr region data;
      printf "    %-16s %6.1fs\n%!" name (Unix.gettimeofday () -. t0)
    end in
  let base = { Zarr.Codec.default_config with domains } in
  (* Drop any previous completion object first, so an interrupted rewrite can
     never look complete with old embeddings beside new scales. *)
  (if not dry_run then
     match Zarr_s3.Store.erase store (chunk_key g.zone "embeddings" ~t ~sr:s.sr ~sc:s.sc) with
     | Ok () -> () | Error e -> failwith (Format.asprintf "erase: %a" Zarr_s3.Store.pp_error e));
  let emb_arrays = [ ("embeddings_d4", 4); ("embeddings_d16", 16) ] in
  let write_depth (name, d) =
    let data = Zarr.Ndarray.Int8_signed (depth_view s d) in
    (* zarr omits all-fill shards; keep the object so the completion marker
       still exists for an all-zero shard, as the PoC does. *)
    let all_fill = Zarr.Ndarray.equals_fill data (Zarr.Ztypes.Fill_value.Int 0L) in
    write name ~config:{ base with write_empty_chunks = all_fill } data (region_emb d) in
  List.iter write_depth emb_arrays;
  write "scales" ~config:base (Zarr.Ndarray.Float32 s.scales) region_sc;
  write_depth ("embeddings", n_bands)

(* ======================== Main ======================== *)

let () =
  let endpoint = ref (Option.value (Sys.getenv_opt "S3_ENDPOINT") ~default:"") in
  let bucket = ref (Option.value (Sys.getenv_opt "S3_BUCKET") ~default:"") in
  let prefix = ref (Option.value (Sys.getenv_opt "S3_PREFIX") ~default:"") in
  let region = ref (Option.value (Sys.getenv_opt "AWS_DEFAULT_REGION") ~default:"us-east-1") in
  let year = ref 0 in
  let first_year = ref 2017 in
  let time_index = ref (-1) in
  let zone_arg = ref 0 in
  let sr = ref (-1) and sc = ref (-1) in
  let domains = ref 8 in
  let dry_run = ref false in
  let inputs = ref [] in
  let speclist = [
    ("--endpoint", Arg.Set_string endpoint, "S3 endpoint URL (default $S3_ENDPOINT)");
    ("--bucket", Arg.Set_string bucket, "Bucket (default $S3_BUCKET)");
    ("--prefix", Arg.Set_string prefix, "Key prefix of the Zarr store root, e.g. zarr/v2-world (default $S3_PREFIX)");
    ("--region", Arg.Set_string region, "Signing region (default $AWS_DEFAULT_REGION or us-east-1)");
    ("--year", Arg.Set_int year, "Year of the inputs (selects the time index)");
    ("--first_year", Arg.Set_int first_year, "Year of time index 0 (default 2017)");
    ("--time_index", Arg.Set_int time_index, "Time index to write (overrides --year/--first_year)");
    ("--zone", Arg.Set_int zone_arg, "UTM zone, required for r<row>c<col> window inputs");
    ("--sr", Arg.Set_int sr, "Only write this shard row");
    ("--sc", Arg.Set_int sc, "Only write this shard column");
    ("--domains", Arg.Set_int domains, "Domains used to compress inner chunks (default 8)");
    ("--dry_run", Arg.Set dry_run, "Place and assemble, but do not write");
  ] in
  Arg.parse speclist (fun p -> inputs := p :: !inputs)
    "tessera-zarr-upload [options] <tile.npy | tile dir> ...\nPlace encoder output into the shards of an S3 Zarr store.";
  let inputs = List.rev_map input_of_path !inputs in
  if inputs = [] then failwith "no inputs";
  if !endpoint = "" || !bucket = "" then failwith "--endpoint and --bucket are required";
  let t_idx = if !time_index >= 0 then !time_index
    else if !year > 0 then !year - !first_year
    else failwith "--year or --time_index is required" in
  if t_idx < 0 then failwith "time index is negative";
  Gdal.init ();
  Zarr_blosc.Blosc.register ();
  let zone_arg = if !zone_arg > 0 then Some !zone_arg else None in
  (* All inputs must address one zone group. *)
  let zones = List.sort_uniq compare (List.map (input_zone ~zone_arg) inputs) in
  let zone = match zones with
    | [ z ] -> z
    | zs -> failwith (Printf.sprintf "inputs span zones %s; run once per zone"
                        (String.concat "," (List.map string_of_int zs))) in

  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let credentials = match S3.Credentials.default_chain () with
    | Ok c -> c
    | Error m -> failwith ("no S3 credentials (AWS_* env or ~/.aws/credentials): " ^ m) in
  let cfg = S3.Client.make_config ~endpoint:!endpoint ~region:!region ~credentials ~path_style:true () in
  let client = S3.Client.create ~sw ~net:(Eio.Stdenv.net env) ~clock:(Eio.Stdenv.clock env) cfg in
  let store = Zarr_s3.Store.create client ~bucket:!bucket ~prefix:!prefix in
  let g = zone_grid_of_store store zone in
  printf "store s3://%s/%s  zone %02d EPSG:%d  origin (%.0f, %.0f)  %d x %d px  T=%d  time index %d\n%!"
    !bucket !prefix g.zone g.epsg g.origin_x g.origin_y g.width_px g.height_px g.n_time t_idx;
  if t_idx >= g.n_time then failwith (Printf.sprintf "time index %d outside T=%d" t_idx g.n_time);

  let placements = List.map (place g) inputs in
  List.iter (fun p -> printf "  %-22s %dx%d at row %d col %d\n%!" p.inp.name p.h p.w p.row p.col) placements;
  let wanted = List.sort_uniq compare (List.concat_map (shards_touched g) placements) in
  let wanted = List.filter (fun (r, c) -> (!sr < 0 || r = !sr) && (!sc < 0 || c = !sc)) wanted in
  printf "shards: %s\n%!" (String.concat " " (List.map (fun (r, c) -> Printf.sprintf "%d/%d" r c) wanted));
  List.iter (fun (r, c) ->
    let t0 = Unix.gettimeofday () in
    let s = new_shard g r c in
    let covering = List.filter (fun p -> List.mem (r, c) (shards_touched g p)) placements in
    printf "shard %02d/%d/%d/%d  %dx%d  from %d input(s)\n%!" zone t_idx r c s.sh s.sw (List.length covering);
    List.iter (fun p ->
      let (v, nd) = paste s p in
      printf "    %-22s valid %9d  nodata %7d\n%!" p.inp.name v nd) covering;
    write_shard ~store ~g ~t:t_idx ~domains:!domains ~dry_run:!dry_run s;
    printf "  done in %.0fs\n%!" (Unix.gettimeofday () -. t0)) wanted
