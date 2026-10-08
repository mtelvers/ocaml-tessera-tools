(** The seeded zone grid of a Tessera Zarr store.

    A zone's grid is not arithmetic: its origin is the union extent of the
    tiles the store was seeded from, snapped to 10 m. So it is read, never
    recomputed, from the store's own `utmZZ/zarr.json` (`spatial:transform`,
    `spatial:shape`, `proj:code`), either over HTTP from the store's base URL
    or from a JSON dump written by {!dump} ({"zones": {"30": {...}}}).

    origin_y is the canonical northing: no false northing, negative south of
    the equator, so one grid is continuous across both hemispheres. *)

type t = {
  zone : int;
  epsg : int;            (* canonical northern code, 326zz *)
  origin_x : float;
  origin_y : float;
  pixel : float;
  height_px : int;
  width_px : int;
  shard_rows : int;
  shard_cols : int;
}

(** Shard side in pixels, fixed by the store format. *)
let shard_px = 4096

let is_url s = String.starts_with ~prefix:"http://" s || String.starts_with ~prefix:"https://" s

let member k = function `Assoc l -> List.assoc_opt k l | _ -> None
let num what = function
  | Some (`Float f) -> f | Some (`Int i) -> Float.of_int i
  | _ -> failwith ("zone grid: missing number " ^ what)
let int what = function
  | Some (`Int i) -> i | Some (`Float f) -> Float.to_int f
  | _ -> failwith ("zone grid: missing integer " ^ what)

let make ~zone ~epsg ~origin_x ~origin_y ~pixel ~height_px ~width_px =
  { zone; epsg; origin_x; origin_y; pixel; height_px; width_px;
    shard_rows = height_px / shard_px; shard_cols = width_px / shard_px }

(** From a zone group's zarr.json attributes. *)
let of_attrs ~zone attrs =
  let t = match member "spatial:transform" attrs with
    | Some (`List l) -> Array.of_list (List.map (fun v -> num "transform" (Some v)) l)
    | _ -> failwith "zone grid: zarr.json lacks spatial:transform" in
  let h, w = match member "spatial:shape" attrs with
    | Some (`List [ h; w ]) -> (int "shape" (Some h), int "shape" (Some w))
    | _ -> failwith "zone grid: zarr.json lacks spatial:shape" in
  let epsg = match member "proj:code" attrs with
    | Some (`String s) -> (match String.split_on_char ':' s with
        | [ _; c ] -> int_of_string c | _ -> failwith "zone grid: bad proj:code")
    | _ -> 32600 + zone in
  make ~zone ~epsg ~origin_x:t.(2) ~origin_y:t.(5) ~pixel:t.(0) ~height_px:h ~width_px:w

(** From a zone_grids.json entry. *)
let of_entry ~zone g =
  make ~zone
    ~epsg:(match member "epsg" g with Some _ as e -> int "epsg" e | None -> 32600 + zone)
    ~origin_x:(num "origin_x" (member "origin_x" g)) ~origin_y:(num "origin_y" (member "origin_y" g))
    ~pixel:(match member "pixel" g with Some _ as p -> num "pixel" p | None -> 10.0)
    ~height_px:(int "height_px" (member "height_px" g)) ~width_px:(int "width_px" (member "width_px" g))

let zone_url base zone = Printf.sprintf "%s/utm%02d/zarr.json" base zone

(** The zone's grid from the store at [base] (e.g.
    https://data.source.coop/tessera/tessera/zarr/v2-2B-L~beta1); None if the
    zone group does not exist. *)
let fetch ~client ~base zone =
  match Stac_client.http_get client (zone_url base zone) with
  | 200, body ->
    (match member "attributes" (Yojson.Safe.from_string body) with
     | Some attrs -> Some (of_attrs ~zone attrs)
     | None -> failwith (zone_url base zone ^ ": no attributes"))
  | 404, _ -> None
  | code, body -> failwith (Printf.sprintf "%s: HTTP %d %s" (zone_url base zone) code
                              (String.sub body 0 (min 120 (String.length body))))

(** One zone from a JSON dump or a store URL. *)
let load src zone =
  if is_url src then
    match fetch ~client:(Stac_client.make ()) ~base:src zone with
    | Some g -> g
    | None -> failwith (Printf.sprintf "%s has no zone %02d" src zone)
  else begin
    let json = Yojson.Safe.from_file src in
    match member "zones" json with
    | Some zones ->
      (match member (Printf.sprintf "%02d" zone) zones with
       | Some g -> of_entry ~zone g
       | None -> failwith (Printf.sprintf "%s has no zone %02d" src zone))
    | None -> failwith (src ^ ": no \"zones\" map")
  end

(** Every zone, from a dump file or by fetching all 60 from a store URL. *)
let load_all src =
  let tbl = Hashtbl.create 64 in
  if is_url src then begin
    let client = Stac_client.make () in
    for zone = 1 to 60 do
      match fetch ~client ~base:src zone with
      | Some g -> Hashtbl.replace tbl zone g
      | None -> ()
    done
  end else begin
    match member "zones" (Yojson.Safe.from_file src) with
    | Some (`Assoc zones) ->
      List.iter (fun (k, g) ->
        let zone = match member "zone" g with Some _ as z -> int "zone" z | None -> int_of_string k in
        Hashtbl.replace tbl zone (of_entry ~zone g)) zones
    | _ -> failwith (src ^ ": no \"zones\" map")
  end;
  tbl

(** Write the dump format: {"dataset", "shard", "zones": {"NN": {...}}}. *)
let dump oc ~dataset (grids : (int, t) Hashtbl.t) =
  let zones = Hashtbl.fold (fun _ g acc -> g :: acc) grids [] |> List.sort compare in
  let entry g = `Assoc [
    ("zone", `Int g.zone); ("epsg", `Int g.epsg);
    ("origin_x", `Float g.origin_x); ("origin_y", `Float g.origin_y); ("pixel", `Float g.pixel);
    ("height_px", `Int g.height_px); ("width_px", `Int g.width_px);
    ("shard_rows", `Int g.shard_rows); ("shard_cols", `Int g.shard_cols) ] in
  let doc = `Assoc [
    ("dataset", `String dataset); ("shard", `Int shard_px);
    ("zones", `Assoc (List.map (fun g -> (Printf.sprintf "%02d" g.zone, entry g)) zones)) ] in
  Yojson.Safe.pretty_to_channel oc doc;
  output_char oc '\n'
