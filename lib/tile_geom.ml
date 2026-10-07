(** Geometry of a Tessera 0.1 degree tile on its UTM pixel grid.

    This is dpixel.load_roi_from_grid_id followed by stackstac's snap_bounds,
    which is also the placement rule geotessera's Zarr converter uses
    (floor of the unsnapped origin, #429): the tile's pixel (0,0) sits at
    ([minx], [maxy]) and the tile is [height] x [width] pixels of 10 m. *)

type t = {
  lon : float;
  lat : float;
  zone : int;
  epsg : int;                 (* 326zz north, 327zz south *)
  minx : float;               (* snapped grid origin, real (false) northing *)
  maxy : float;
  w_out : int; h_out : int;   (* stackstac grid size, (width+1) x (height+1) *)
  height : int; width : int;  (* tile array size, dpixel's round() *)
  bounds_unsnapped : float * float * float * float;  (* left, bottom, right, top *)
}

let pixel = 10.0

(** Zone 1 is [-180,-174); lon = 180 clamps into zone 60, as geotessera does. *)
let zone_of_lon lon =
  max 1 (min 60 (Float.to_int (Float.floor ((lon +. 180.0) /. 6.0)) + 1))

(** "grid_<lon>_<lat>" -> (lon, lat). Scanf's %f would accept '_' as a digit
    separator and swallow both numbers, so split by hand. *)
let parse_grid_id s =
  match String.split_on_char '_' s with
  | [ "grid"; lon; lat ] -> (try Some (float_of_string lon, float_of_string lat) with _ -> None)
  | _ -> None

let grid_id lon lat = Printf.sprintf "grid_%.2f_%.2f" lon lat

(** stackstac.geom_utils.snapped_bounds *)
let snapped_bounds (minx, miny, maxx, maxy) res =
  (Float.floor (minx /. res) *. res, Float.floor (miny /. res) *. res,
   Float.ceil (maxx /. res) *. res, Float.ceil (maxy /. res) *. res)

(** Project the four lon/lat corners of the tile centred on (lon, lat) with
    PROJ (via GDAL), exactly as pyproj does in the Python. *)
let project_corners ~epsg lon lat =
  let src = Gdal.SpatialReference.of_epsg 4326 |> Result.get_ok in
  let dst = Gdal.SpatialReference.of_epsg epsg |> Result.get_ok in
  Gdal.SpatialReference.set_axis_mapping_strategy src Gdal.oams_traditional_gis_order;
  Gdal.SpatialReference.set_axis_mapping_strategy dst Gdal.oams_traditional_gis_order;
  let ct = Gdal.CoordinateTransformation.create src dst |> Result.get_ok in
  let corners = [| (lon -. 0.05, lat -. 0.05); (lon +. 0.05, lat -. 0.05);
                   (lon -. 0.05, lat +. 0.05); (lon +. 0.05, lat +. 0.05) |] in
  let pts = Gdal.CoordinateTransformation.transform_points ct corners |> Result.get_ok in
  Gdal.CoordinateTransformation.destroy ct;
  Gdal.SpatialReference.destroy src;
  Gdal.SpatialReference.destroy dst;
  pts

(** The tile grid for the tile centred on (lon, lat). Requires [Gdal.init]. *)
let of_centre lon lat =
  let zone = Float.to_int ((lon +. 180.0) /. 6.0) + 1 in
  let epsg = (if lat >= 0.0 then 32600 else 32700) + zone in
  let pts = project_corners ~epsg lon lat in
  let xs = Array.map fst pts and ys = Array.map snd pts in
  let fmin a = Array.fold_left Float.min a.(0) a and fmax a = Array.fold_left Float.max a.(0) a in
  let left = fmin xs and right = fmax xs and bot = fmin ys and top = fmax ys in
  let height = Float.to_int (Float.round ((top -. bot) /. pixel)) in
  let width = Float.to_int (Float.round ((right -. left) /. pixel)) in
  let bounds = (left, top -. pixel *. Float.of_int height, left +. pixel *. Float.of_int width, top) in
  let (minx, miny, maxx, maxy) = snapped_bounds bounds pixel in
  { lon; lat; zone; epsg; minx; maxy;
    w_out = Float.to_int (Float.round ((maxx -. minx) /. pixel));
    h_out = Float.to_int (Float.round ((maxy -. miny) /. pixel));
    height; width; bounds_unsnapped = (left, bot, right, top) }

let of_grid_id s =
  match parse_grid_id s with
  | Some (lon, lat) -> Some (of_centre lon lat)
  | None -> None

(** Canonical northing: geotessera drops the 10,000 km false northing so a
    zone group is one continuous grid across both hemispheres. *)
let canonical_northing ~epsg n = if epsg >= 32700 then n -. 10_000_000.0 else n
