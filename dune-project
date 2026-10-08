(lang dune 3.0)
(name tessera)

(generate_opam_files true)

(source (github mtelvers/ocaml-tessera-tools))
(license MIT)
(authors "Mark Elvers <mark.elvers@tunbury.org>")
(maintainers "Mark Elvers <mark.elvers@tunbury.org>")

(package
 (name tessera-dpixel)
 (synopsis "Tessera dpixel tool in OCaml")
 (description "Tessera dpixel tool in OCaml")
 (depends
  (ocaml (>= 4.14))
  (dune (>= 3.0))
  stac_client
  gdal
  npy
  yojson
  (cmdliner (>= 2.0))))

(package
 (name tessera-zarr-upload)
 (synopsis "Place Tessera encoder output into an S3 Zarr store")
 (description "Assembles Zarr v3 shards from .npy embedding tiles or windows and uploads them to the geotessera store layout on S3")
 (depends
  (ocaml (>= 5.1))
  (dune (>= 3.0))
  gdal
  npy
  zarr
  zarr-blosc
  zarr-s3
  s3
  (eio (>= 1.0))
  eio_main
  yojson))

(package
 (name tessera-shard)
 (synopsis "Live Zarr shards and sub-windows of a region")
 (description "tessera-tiles for the Zarr store: reads World Bank (or any OGR) region polygons and lists the shards and sub-windows of a seeded zone grid they cover")
 (depends
  (ocaml (>= 5.1))
  (dune (>= 3.0))
  tessera-grid
  gdal
  yojson))
