(* tessera-shard: which Zarr shards, and which sub-windows of each, a region
   covers.

   Reads region polygons from any OGR source (the World Bank GAD ADM0
   shapefile, features named in NAM_0), selects the requested countries, and
   tests them directly against a seeded zone grid: every --window px
   sub-window whose square overlaps land is live, and a shard is listed with
   the row-major indices of its live sub-windows, as tessera-dpixel --windows
   takes them.

   The projection is PROJ through GDAL; the rules:

   - Rings are clipped to the zone's 6 degree band with a 1.5 degree margin
     before projecting (transverse Mercator diverges far from its meridian),
     then densified to 0.05 degree edges so a straight lon/lat segment does
     not bow across a sub-window under the projection.
   - A sub-window belongs to exactly one zone, decided on its own centre's
     longitude, as the published store assigns tiles by centre longitude.
   - The request chooses the SHARDS; all land chooses the WINDOWS. A shard is
     written as one object and its existence means "finished", so a shard
     that holds the Isle of Man and the Mull of Galloway must be produced with
     both, whichever one was asked for.
   - Land outside the seeded grid (zones seeded short of the pole) is counted
     and reported, never folded onto the edge.

   Output, one shard per line, sorted:
     ZONE:SR:SC<TAB>i,j,k      sub-window indices, row-major 0..n*n-1
   which feeds tessera-dpixel --shard ZONE:SR:SC --windows i,j,k. *)

module Geo = Tessera_grid.Geo

let eprintf fmt = Printf.eprintf fmt

module Zone_grid = Tessera_common.Zone_grid

(* ======================== Regions from OGR ======================== *)

let vsi_path path =
  let lower = String.lowercase_ascii path in
  if String.starts_with ~prefix:"/vsi" path then path
  else if List.exists (fun s -> String.ends_with ~suffix:s lower) [ ".zip"; ".shz"; ".kmz" ]
  then "/vsizip/" ^ path
  else path

let name_fields = [ "NAM_0"; "NAME_0"; "name"; "NAME"; "Name"; "NAME_1" ]

let feature_name feat =
  let rec first = function
    | [] -> Printf.sprintf "feature %Ld" (Gdal.Vector.Feature.fid feat)
    | f :: rest ->
      (match Gdal.Vector.Feature.field_by_name feat f with
       | Some v when String.trim v <> "" -> String.trim v
       | _ -> first rest) in
  first name_fields

(** Every polygon feature of the first layer, as WGS84 lon/lat rings. *)
let load_regions path : Geo.polygon list =
  let ( let* ) = Result.bind in
  let r =
    Gdal.Vector.with_dataset (vsi_path path) (fun ds ->
      let* layer = Gdal.Vector.Layer.get ds 0 in
      let* wgs84 = Gdal.SpatialReference.of_epsg 4326 in
      Gdal.SpatialReference.set_axis_mapping_strategy wgs84 Gdal.oams_traditional_gis_order;
      let* transform =
        match Gdal.Vector.Layer.spatial_reference layer with
        | None -> Ok None
        | Some s when Gdal.SpatialReference.authority_code s = Some "4326" -> Ok None
        | Some s ->
          Gdal.SpatialReference.set_axis_mapping_strategy s Gdal.oams_traditional_gis_order;
          let* ct = Gdal.CoordinateTransformation.create s wgs84 in
          Ok (Some ct) in
      let polys =
        Gdal.Vector.Layer.fold layer ~init:[] ~f:(fun acc feat ->
          match Gdal.Vector.Feature.geometry feat with
          | None -> acc
          | Some g ->
            let rings = Gdal.Vector.Geometry.rings g in
            let rings = List.filter_map (fun r ->
              match transform with
              | None -> Some r
              | Some ct -> Result.to_option (Gdal.CoordinateTransformation.transform_points ct r)) rings in
            if rings = [] then acc
            else { Geo.name = feature_name feat; rings = Array.of_list rings } :: acc) in
      Ok (List.rev polys)) in
  match r with
  | Ok (Ok p) -> p
  | Ok (Error e) | Error e -> failwith (Printf.sprintf "%s: %s" path e)

(* ======================== Geometry ======================== *)

let max_edge_deg = 0.05
let clip_margin_deg = 1.5

let zone_band zone =
  let west = float_of_int ((zone - 1) * 6) -. 180.0 in
  (west, west +. 6.0)

let clip_band zone =
  let west, east = zone_band zone in
  (west -. clip_margin_deg, east +. clip_margin_deg)

(* Sutherland-Hodgman against one half-plane; rings are clipped independently
   so holes survive as holes (Geo's containment is even-odd over all rings). *)
let clip_ring_half ~inside ~intersect (ring : Geo.ring) : Geo.ring =
  let n = Array.length ring in
  if n = 0 then [||]
  else begin
    let out = ref [] in
    for i = 0 to n - 1 do
      let s = ring.(if i = 0 then n - 1 else i - 1) in
      let e = ring.(i) in
      match (inside s, inside e) with
      | true, true -> out := e :: !out
      | true, false -> out := intersect s e :: !out
      | false, true -> out := e :: intersect s e :: !out
      | false, false -> ()
    done;
    Array.of_list (List.rev !out)
  end

let clip_ring_lon ~west ~east ring =
  let cut_at c (x0, y0) (x1, y1) =
    let dx = x1 -. x0 in
    let t = if Float.abs dx < 1e-12 then 0.0 else (c -. x0) /. dx in
    (c, y0 +. (t *. (y1 -. y0))) in
  ring
  |> clip_ring_half ~inside:(fun (x, _) -> x >= west) ~intersect:(cut_at west)
  |> clip_ring_half ~inside:(fun (x, _) -> x <= east) ~intersect:(cut_at east)

let densify_ring (ring : Geo.ring) : Geo.ring =
  let n = Array.length ring in
  if n < 2 then ring
  else begin
    let out = ref [] in
    for i = 0 to n - 1 do
      let (x0, y0) = ring.(i) in
      let (x1, y1) = ring.((i + 1) mod n) in
      out := (x0, y0) :: !out;
      let steps = int_of_float (Float.ceil
          (Float.max (Float.abs (x1 -. x0)) (Float.abs (y1 -. y0)) /. max_edge_deg)) in
      for s = 1 to steps - 1 do
        let t = float_of_int s /. float_of_int steps in
        out := (x0 +. (t *. (x1 -. x0)), y0 +. (t *. (y1 -. y0))) :: !out
      done
    done;
    Array.of_list (List.rev !out)
  end

let ring_lon_span (ring : Geo.ring) =
  Array.fold_left (fun acc (lon, _) ->
    match acc with
    | None -> Some (lon, lon)
    | Some (a, b) -> Some (Float.min a lon, Float.max b lon)) None ring

let poly_reaches ~west ~east (p : Geo.polygon) =
  Array.exists (fun ring ->
    match ring_lon_span ring with
    | None -> false
    | Some (a, b) -> a <= east && b >= west) p.rings

(** PROJ transforms for one zone: lon/lat <-> the zone's northern UTM. Using
    the 326xx code for both hemispheres gives canonical northing directly
    (negative south of the equator, no false northing), as the store's groups
    are laid out. One pair per domain; a transformation object is not shared
    across threads. *)
type proj = { fwd : Gdal.CoordinateTransformation.t; inv : Gdal.CoordinateTransformation.t }

let make_proj zone =
  let wgs84 = Gdal.SpatialReference.of_epsg 4326 |> Result.get_ok in
  let utm = Gdal.SpatialReference.of_epsg (32600 + zone) |> Result.get_ok in
  Gdal.SpatialReference.set_axis_mapping_strategy wgs84 Gdal.oams_traditional_gis_order;
  Gdal.SpatialReference.set_axis_mapping_strategy utm Gdal.oams_traditional_gis_order;
  { fwd = Gdal.CoordinateTransformation.create wgs84 utm |> Result.get_ok;
    inv = Gdal.CoordinateTransformation.create utm wgs84 |> Result.get_ok }

let project_ring (pr : proj) (ring : Geo.ring) : Geo.ring =
  match Gdal.CoordinateTransformation.transform_points pr.fwd ring with
  | Ok r -> r
  | Error e -> failwith ("projection failed: " ^ e)

let prepare_for_zone (pr : proj) ~zone (polys : Geo.polygon list) : Geo.prepared =
  let west, east = clip_band zone in
  polys
  |> List.filter (poly_reaches ~west ~east)
  |> List.filter_map (fun (p : Geo.polygon) ->
       let rings =
         p.rings |> Array.to_list
         |> List.filter_map (fun ring ->
              let clipped = clip_ring_lon ~west ~east ring in
              if Array.length clipped < 3 then None
              else Some (project_ring pr (densify_ring clipped)))
         |> Array.of_list in
       if Array.length rings = 0 then None else Some { p with rings })
  |> Geo.prepare_polys

(* Positive-area overlap: an edge enters the rect, or none does and the
   centre is inside. Corners are deliberately not tested. *)
let rect_overlaps ~lo_x ~lo_y ~hi_x ~hi_y (preps : Geo.prepared) =
  let cx = (lo_x +. hi_x) /. 2.0 and cy = (lo_y +. hi_y) /. 2.0 in
  List.exists (fun rings ->
    Array.exists (fun (ring, rlo_x, rlo_y, rhi_x, rhi_y) ->
      rlo_x <= hi_x && rhi_x >= lo_x && rlo_y <= hi_y && rhi_y >= lo_y
      && Geo.ring_crosses_open_rect ~lo_x ~lo_y ~hi_x ~hi_y ring) rings
    || Geo.point_in_prepared (cx, cy) rings) preps

(** Live (shard row, shard col, sub-window bitmask) for one zone, and the
    number of land sub-windows that fall outside the seeded grid. *)
let live_windows (pr : proj) (g : Zone_grid.t) ~shard_px ~win (polys : Geo.polygon list) =
  let preps = prepare_for_zone pr ~zone:g.zone polys in
  if preps = [] then ([], 0)
  else begin
    let n = shard_px / win in
    let wins_x = g.shard_cols * n and wins_y = g.shard_rows * n in
    let span = float_of_int win *. g.pixel in
    let col_of x = int_of_float (Float.floor ((x -. g.origin_x) /. span)) in
    let row_of y = int_of_float (Float.floor ((g.origin_y -. y) /. span)) in
    let outside = ref 0 in
    let centre wy wx =
      (g.origin_x +. ((float_of_int wx +. 0.5) *. span),
       g.origin_y -. ((float_of_int wy +. 0.5) *. span)) in
    let west, east = zone_band g.zone in
    let in_band cx cy =
      match Gdal.CoordinateTransformation.transform_point pr.inv ~x:cx ~y:cy ~z:0.0 with
      | Ok (lon, _, _) -> lon >= west && lon < east
      | Error _ -> false in
    let cand : (int * int, unit) Hashtbl.t = Hashtbl.create 4096 in
    List.iter (fun rings ->
      Array.iter (fun (_, lo_x, lo_y, hi_x, hi_y) ->
        let c0 = col_of lo_x and c1 = col_of hi_x in
        let r0 = row_of hi_y and r1 = row_of lo_y in
        for wy = r0 to r1 do
          for wx = c0 to c1 do
            if wy >= 0 && wy < wins_y && wx >= 0 && wx < wins_x then Hashtbl.replace cand (wy, wx) ()
            else begin
              let cx, cy = centre wy wx in
              if in_band cx cy then incr outside
            end
          done
        done) rings) preps;
    let masks : (int * int, int) Hashtbl.t = Hashtbl.create 1024 in
    Hashtbl.iter (fun (wy, wx) () ->
      let lo_x = g.origin_x +. (float_of_int wx *. span) in
      let hi_x = lo_x +. span in
      let hi_y = g.origin_y -. (float_of_int wy *. span) in
      let lo_y = hi_y -. span in
      if in_band ((lo_x +. hi_x) /. 2.0) ((lo_y +. hi_y) /. 2.0)
         && rect_overlaps ~lo_x ~lo_y ~hi_x ~hi_y preps then begin
        let key = (wy / n, wx / n) in
        let bit = 1 lsl (((wy mod n) * n) + (wx mod n)) in
        let prev = Option.value ~default:0 (Hashtbl.find_opt masks key) in
        Hashtbl.replace masks key (prev lor bit)
      end) cand;
    (Hashtbl.fold (fun (sr, sc) m acc -> (sr, sc, m) :: acc) masks [], !outside)
  end

let zones_of_polys (polys : Geo.polygon list) =
  match polys with
  | [] -> []
  | _ ->
    let b = Geo.polygons_bbox polys in
    let lo = Tessera_common.Tile_geom.zone_of_lon b.lon_min
    and hi = Tessera_common.Tile_geom.zone_of_lon b.lon_max in
    List.init (max 0 (hi - lo + 1)) (fun i -> lo + i)

(* ======================== Parallel over zones ======================== *)

let parallel_map ~domains f items =
  let arr = Array.of_list items in
  let n = Array.length arr in
  if n = 0 then []
  else begin
    let out = Array.make n None in
    let next = Atomic.make 0 in
    let worker () =
      let rec loop () =
        let i = Atomic.fetch_and_add next 1 in
        if i < n then begin out.(i) <- Some (f arr.(i)); loop () end in
      loop () in
    let extra = max 0 (min domains n - 1) in
    let ds = List.init extra (fun _ -> Domain.spawn worker) in
    worker ();
    List.iter Domain.join ds;
    Array.to_list out |> List.filter_map Fun.id
  end

(* ======================== Main ======================== *)

let () =
  let shapefile = ref "" in
  let countries = ref [] in
  let all_regions = ref false in
  let zone_grid = ref "" in
  let shard_px = ref 4096 in
  let win = ref 1024 in
  let domains = ref (max 1 (min 32 (Domain.recommended_domain_count ()))) in
  let output = ref "" in
  let list_names = ref false in
  let dump_grid = ref "" in
  let speclist = [
    ("--shapefile", Arg.Set_string shapefile, "Region polygons: WB_GAD_ADM0_complete.shp or any OGR source with a NAM_0/name field");
    ("--country", Arg.String (fun c -> countries := c :: !countries), "Region name (NAM_0), case-insensitive; repeatable");
    ("--all", Arg.Set all_regions, "Every region in the file");
    ("--zone_grid", Arg.Set_string zone_grid, "Seeded zone grid: the store's base URL (…/zarr/<dataset>) or a zone_grids.json dump");
    ("--dump_zone_grid", Arg.Set_string dump_grid, "Write the zone grids read from --zone_grid to this JSON file (for offline use by the other tools)");
    ("--shard_px", Arg.Set_int shard_px, "Shard side in pixels (default 4096)");
    ("--window", Arg.Set_int win, "Sub-window side in pixels (default 1024)");
    ("--domains", Arg.Set_int domains, "Zones processed in parallel (default: cores, max 32)");
    ("--output", Arg.Set_string output, "Write the list here instead of stdout");
    ("--list", Arg.Set list_names, "List the region names in the file and exit");
  ] in
  Arg.parse speclist (fun _ -> ()) "tessera-shard: live Zarr shards and sub-windows of a region";
  if !shard_px mod !win <> 0 then failwith "--window must divide --shard_px";
  if !zone_grid = "" then failwith "--zone_grid is required";
  Gdal.init ();
  let grids = Zone_grid.load_all !zone_grid in
  eprintf "%s: %d zone grid(s)\n%!" !zone_grid (Hashtbl.length grids);
  if !dump_grid <> "" then begin
    let dataset = Filename.basename !zone_grid in
    let oc = open_out !dump_grid in
    Zone_grid.dump oc ~dataset grids;
    close_out oc;
    eprintf "wrote %s\n%!" !dump_grid;
    if !shapefile = "" then exit 0
  end;
  if !shapefile = "" then failwith "--shapefile is required";
  let records = load_regions !shapefile in
  if !list_names then begin
    List.iter (fun (p : Geo.polygon) -> print_endline p.name) records;
    exit 0
  end;
  if !countries = [] && not !all_regions then failwith "--country or --all is required";
  let lower = String.lowercase_ascii in
  let selected =
    if !all_regions then records
    else begin
      let want = List.map lower !countries in
      List.iter (fun c ->
        if not (List.exists (fun (p : Geo.polygon) -> lower p.name = lower c) records) then
          eprintf "warning: no region named %S in %s\n%!" c !shapefile) !countries;
      List.filter (fun (p : Geo.polygon) -> List.mem (lower p.name) want) records
    end in
  eprintf "%s: %d region(s) selected from %d record(s)\n%!" !shapefile (List.length selected) (List.length records);
  if selected = [] then failwith "no regions selected";

  let t0 = Unix.gettimeofday () in
  let per_zone = parallel_map ~domains:!domains (fun zone ->
    match Hashtbl.find_opt grids zone with
    | None -> (zone, [], 0, 0.0)
    | Some g ->
      let t = Unix.gettimeofday () in
      let pr = make_proj zone in
      let live ps = live_windows pr g ~shard_px:!shard_px ~win:!win ps in
      let roi_found, outside = live selected in
      (* The request chooses the shards; all land chooses the windows. *)
      let found =
        if !all_regions || roi_found = [] then roi_found
        else begin
          let want = Hashtbl.create 64 in
          List.iter (fun (sr, sc, _) -> Hashtbl.replace want (sr, sc) ()) roi_found;
          let b = Geo.polygons_bbox selected in
          let pad_lat = 1.0 in
          let clat = Float.max 0.05 (cos (Float.max (Float.abs b.lat_min) (Float.abs b.lat_max) *. Float.pi /. 180.0)) in
          let pad_lon = Float.min 30.0 (1.0 /. clat) in
          let near (p : Geo.polygon) =
            let pb = Geo.polygons_bbox [ p ] in
            pb.lon_max >= b.lon_min -. pad_lon && pb.lon_min <= b.lon_max +. pad_lon
            && pb.lat_max >= b.lat_min -. pad_lat && pb.lat_min <= b.lat_max +. pad_lat in
          let all_found, _ = live (List.filter near records) in
          List.filter (fun (sr, sc, _) -> Hashtbl.mem want (sr, sc)) all_found
        end in
      Gdal.CoordinateTransformation.destroy pr.fwd;
      Gdal.CoordinateTransformation.destroy pr.inv;
      (zone, found, outside, Unix.gettimeofday () -. t)) (zones_of_polys selected) in

  let n = !shard_px / !win in
  let rows = List.concat_map (fun (zone, found, outside, dt) ->
    if found <> [] || outside > 0 then
      eprintf "utm%02d: %d shard(s) in %.1fs%s\n%!" zone (List.length found) dt
        (if outside > 0 then Printf.sprintf " -- %d sub-window(s) of land outside the seeded grid" outside else "");
    List.map (fun (sr, sc, mask) -> (zone, sr, sc, mask)) found) per_zone in
  let rows = List.sort compare rows in
  let total_win = List.fold_left (fun acc (_, _, _, m) ->
    acc + List.length (List.filter (fun i -> m land (1 lsl i) <> 0) (List.init (n * n) Fun.id))) 0 rows in
  eprintf "%d shard(s), %d live sub-window(s) of %d (%.0f%% skipped), %.1fs\n%!"
    (List.length rows) total_win (List.length rows * n * n)
    (100.0 *. float_of_int (List.length rows * n * n - total_win) /. float_of_int (max 1 (List.length rows * n * n)))
    (Unix.gettimeofday () -. t0);
  let oc = if !output = "" then stdout else open_out !output in
  List.iter (fun (zone, sr, sc, mask) ->
    let idx = List.filter (fun i -> mask land (1 lsl i) <> 0) (List.init (n * n) Fun.id) in
    Printf.fprintf oc "%02d:%d:%d\t%s\n" zone sr sc (String.concat "," (List.map string_of_int idx))) rows;
  if !output <> "" then close_out oc
